import Foundation
import SwiftUI

struct ManagedClaimResponse: Decodable {
  let enabled: Bool
  let claim: ManagedClaim?
}

struct ManagedClaim: Decodable {
  let ticket: String
  let mode: ManagedMode
  let style: ManagedStyle
  let request: ManagedChatBody
}

struct ManagedChatBody: Decodable {
  struct Message: Decodable {
    let role: String
    let content: String
  }
  let messages: [Message]
  let max_tokens: Int
}

enum ManagedPhoneModel {
  static let limit = 64 * 1024

  // Re-encode only the fields that the node's decision parser consumes. Provider
  // metadata, tool calls, reasoning text and error bodies stay off the relay.
  private struct Suggestion: Codable {
    let choice: Int?
    let choices: [Int]?
    let reason: String
    let draft: String?
  }

  static func sanitizedResponse(_ data: Data, key: String) throws -> Data {
    guard data.count <= limit,
          let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let first = (envelope["choices"] as? [[String: Any]])?.first,
          let finish = first["finish_reason"] as? String,
          let usage = envelope["usage"] as? [String: Any],
          let tokens = usage["total_tokens"] as? Int, (1...1_000_000).contains(tokens)
    else { throw SessionAdvisorError.invalidResponse }
    // An incomplete or filtered answer still incurred these tokens. Return
    // usage without a selectable answer so the node can reconcile its budget.
    var result: [String: Any] = ["finish_reason": finish == "length" ? "length" : "filtered"]
    if finish == "stop", let message = first["message"] as? [String: Any], let content = message["content"] as? String,
       !content.contains(key), let suggestion = try? JSONDecoder().decode(Suggestion.self, from: Data(content.utf8)),
       !suggestion.reason.contains(key), suggestion.draft?.contains(key) != true {
      let clean = try JSONEncoder().encode(suggestion)
      result = ["finish_reason": "stop", "message": ["content": String(decoding: clean, as: UTF8.self)]]
    }
    let resultData = try JSONSerialization.data(withJSONObject: [
      "choices": [result], "usage": ["total_tokens": tokens]
    ])
    guard resultData.count <= limit else { throw SessionAdvisorError.invalidResponse }
    return resultData
  }

  static func complete(_ claim: ManagedClaim, key: String, session: URLSession = SessionAdvisor.transport) async throws -> Data {
    let token = try SessionAdvisor.validatedKey(key)
    let chat = claim.request
    guard chat.messages.map(\.role) == ["system", "user"], (1...384).contains(chat.max_tokens),
          chat.messages.allSatisfy({ !$0.content.isEmpty && $0.content.utf8.count <= 16 * 1024 })
    else { throw SessionAdvisorError.invalidResponse }
    guard chat.messages.allSatisfy({ !$0.content.contains(token) }) else { throw SessionAdvisorError.credentialInSnapshot }
    let request = try SessionAdvisor.chatRequest(instructions: chat.messages[0].content, userMessage: chat.messages[1].content,
                                                 key: token, maxTokens: chat.max_tokens)
    try Task.checkCancellation()
    let (bytes, response) = try await session.bytes(for: request, delegate: SessionAdvisor.RedirectBlocker())
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse else { throw SessionAdvisorError.invalidResponse }
    switch http.statusCode {
    case 200..<300: break
    case 401, 403: throw SessionAdvisorError.authentication
    case 402: throw SessionAdvisorError.quota
    case 429: throw SessionAdvisorError.rateLimited
    default: throw SessionAdvisorError.serviceUnavailable
    }
    guard response.expectedContentLength <= Int64(limit) else { throw SessionAdvisorError.invalidResponse }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw SessionAdvisorError.invalidResponse }
      data.append(byte)
    }
    try Task.checkCancellation()
    return try sanitizedResponse(data, key: token)
  }
}

@MainActor
final class ManagedSessionController: ObservableObject {
  struct Target: Codable, Hashable {
    let clientID: UUID
    let sessionID: Int64
    let name: String
    let instance: String
  }

  struct Services {
    var key: () throws -> String? = AdvisorCredential.load
    var claim: (ClientProfile, Int64, String) async throws -> ManagedClaimResponse = { client, id, instance in
      try await TerminalTransport.claim(client, sessionID: id, instance: instance)
    }
    var model: (ManagedClaim, String) async throws -> Data = { try await ManagedPhoneModel.complete($0, key: $1) }
    var finish: (ClientProfile, Int64, String, String, Data?) async throws -> Void = { client, id, instance, ticket, envelope in
      _ = try await TerminalTransport.finish(client, sessionID: id, instance: instance, ticket: ticket, envelope: envelope)
    }
  }

  private static let settingsKey = "managed.foreground.targets.v2"
  @Published private(set) var targets: [Target]
  @Published private(set) var notices: [Target: String] = [:]
  private let defaults: UserDefaults
  private let services: Services
  private var profiles: [UUID: ClientProfile] = [:]
  private var deadlines: [Target: Date] = [:]
  private var failures: [Target: Int] = [:]
  private var active = false
  private var task: Task<Void, Never>?
  private var current: Target?
  // Keep an unacknowledged reply only in RAM. A reconnect retries the same
  // ticket before claiming another one, without spending more model tokens.
  private struct PendingReply {
    let ticket: String
    let envelope: Data?
    let created: Date
  }
  private var replies: [Target: PendingReply] = [:]

  init(defaults: UserDefaults = .standard, services: Services = Services()) {
    self.defaults = defaults
    self.services = services
    targets = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode([Target].self, from: $0) } ?? []
  }

  func updateClients(_ clients: [ClientProfile]) {
    let next = Dictionary(clients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let stale = targets.filter { target in
      guard let new = next[target.clientID] else { return true }
      guard var old = profiles[target.clientID] else { return false }
      old.name = new.name
      return old != new
    }
    profiles = next
    for target in stale { remove(target) }
    start()
  }

  func updateSessions(_ sessions: [RemoteSession], client: ClientProfile) {
    for target in targets where target.clientID == client.id {
      if !sessions.contains(where: {
        $0.id == target.sessionID && $0.name == target.name && $0.managedVersion == 2 && $0.managedInstance == target.instance
      }) {
        remove(target)
      }
    }
  }

  func credentialChanged() {
    replies.removeAll()
    for target in targets {
      failures[target] = nil
      deadlines[target] = nil
      notices[target] = nil
    }
    task?.cancel()
    start()
  }

  func setActive(_ value: Bool) {
    guard value != active else { return }
    active = value
    if value {
      deadlines.removeAll()
      start()
    } else { task?.cancel() }
  }

  func enable(_ target: Target) {
    guard profiles[target.clientID] != nil else { return }
    for old in targets where old.clientID == target.clientID && old.sessionID == target.sessionID && old != target {
      remove(old)
    }
    if !targets.contains(target) {
      targets.append(target)
      persist()
    }
    reset(target)
    start()
  }

  func remove(_ target: Target) {
    guard targets.contains(target) else { return }
    targets.removeAll { $0 == target }
    reset(target)
    persist()
    if targets.isEmpty { task?.cancel() }
  }

  private func reset(_ target: Target) {
    replies[target] = nil
    notices[target] = nil
    failures[target] = nil
    deadlines[target] = nil
    if current == target { task?.cancel() }
  }

  private func persist() { defaults.set(try? JSONEncoder().encode(targets), forKey: Self.settingsKey) }

  private func start() {
    guard active, task == nil, targets.contains(where: { profiles[$0.clientID] != nil }) else { return }
    task = Task { [weak self] in await self?.run() }
  }

  private func run() async {
    defer {
      current = nil
      task = nil
      start()
    }
    while active && !Task.isCancelled {
      let available = targets.filter { profiles[$0.clientID] != nil }
      guard !available.isEmpty else { return }
      let now = Date()
      guard let target = available.min(by: { (deadlines[$0] ?? .distantPast) < (deadlines[$1] ?? .distantPast) }),
            let client = profiles[target.clientID] else { return }
      let wait = deadlines[target]?.timeIntervalSince(now) ?? 0
      if wait > 0 {
        // New sessions become eligible without interrupting an outstanding claim.
        do { try await Task.sleep(for: .seconds(min(wait, 2))) } catch { return }
        continue
      }
      current = target
      do {
        try await process(target, client: client)
        guard !Task.isCancelled else { return }
        failures[target] = nil
        if targets.contains(target) { deadlines[target] = Date().addingTimeInterval(15) }
      } catch {
        guard !Task.isCancelled else { return }
        let tries = min(4, (failures[target] ?? 0) + 1)
        failures[target] = tries
        deadlines[target] = Date().addingTimeInterval(min(120, 8 * pow(2, Double(tries))))
        notices[target] = (error as? SessionAdvisorError)?.localizedDescription ?? "暂时无法处理，稍后自动重试。"
      }
      current = nil
    }
  }

  private func process(_ target: Target, client: ClientProfile) async throws {
    if let reply = replies[target], Date().timeIntervalSince(reply.created) < 90 {
      try await deliver(reply, target: target, client: client)
      return
    }
    replies[target] = nil
    guard let key = try services.key(), !key.isEmpty else { throw SessionAdvisorError.invalidKey }
    let result = try await services.claim(client, target.sessionID, target.instance)
    try Task.checkCancellation()
    guard result.enabled else { remove(target); return }
    guard let claim = result.claim else { notices[target] = nil; return }
    guard claim.ticket.utf8.count == 16, claim.ticket.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw SessionAdvisorError.invalidResponse }
    var envelope: Data?
    var modelError: Error?
    do { envelope = try await services.model(claim, key) }
    catch { modelError = error }
    // An in-flight provider call can outlive the active scene or be revoked.
    // Only an active, still-enabled session may return its recommendation.
    guard targets.contains(target), !Task.isCancelled else { return }
    let reply = PendingReply(ticket: claim.ticket, envelope: envelope, created: Date())
    replies[target] = reply
    try await deliver(reply, target: target, client: client)
    if let modelError { throw modelError }
  }

  private func deliver(_ reply: PendingReply, target: Target, client: ClientProfile) async throws {
    try Task.checkCancellation()
    try await services.finish(client, target.sessionID, target.instance, reply.ticket, reply.envelope)
    try Task.checkCancellation()
    replies[target] = nil
    notices[target] = nil
  }
}
