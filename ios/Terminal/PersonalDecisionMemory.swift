import CryptoKit
import Foundation

struct PersonalDecisionMemory: Codable, Equatable {
  enum Vote: String, Codable { case prefer, avoid }
  struct Example: Codable, Identifiable, Equatable {
    let id: UUID
    let node: String
    let question: String
    let answer: String
    let draft: Bool
    let vote: Vote
  }

  static let maxExamples = 24
  static let maxGuidanceBytes = 480
  var guidance = ""
  var examples: [Example] = []

  static func scope(for client: ClientProfile) -> String {
    // A saved profile can be edited in place to point at another host or SSH user.
    let identity = [client.id.uuidString, client.host, String(client.port), client.route, client.user, client.pin]
      .map { "\($0.utf8.count):\($0)" }.joined()
    return Data(SHA256.hash(data: Data(identity.utf8))).base64EncodedString()
  }

  static func clean(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  func setGuidance(_ text: String) throws -> Self {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count <= Self.maxGuidanceBytes else { throw RelayError("请缩短原则文字，最多 480 个 UTF-8 字节。") }
    guard DecisionSnapshot.redacted(value) == value else { throw RelayError("请先从决策原则中移除密钥、凭据或控制字符。") }
    var updated = self
    updated.guidance = value
    return updated
  }

  func addingPrinciple(_ text: String) throws -> Self {
    let line = Self.clean(text)
    guard !line.isEmpty else { throw RelayError("请写下希望托管参考的原则。") }
    if guidance.components(separatedBy: .newlines).contains(line) { return self }
    return try setGuidance(guidance.isEmpty ? line : guidance + "\n" + line)
  }

  static func example(for record: ManagedStatus.Record, node: String, vote: Vote) -> Example? {
    guard ["observed", "needsConfirmation", "applied"].contains(record.outcome) else { return nil }
    let choice = clean(record.choice ?? "")
    let answer = choice.isEmpty ? clean(record.draft ?? "") : choice
    let question = clean(record.question)
    guard !question.isEmpty, !answer.isEmpty, question.utf8.count <= 512, answer.utf8.count <= 384,
          DecisionSnapshot.redacted(question) == question, DecisionSnapshot.redacted(answer) == answer,
          !question.contains("[REDACTED]"), !answer.contains("[REDACTED]") else { return nil }
    return Example(id: UUID(), node: node, question: question, answer: answer, draft: choice.isEmpty, vote: vote)
  }

  mutating func record(_ example: Example) {
    // A changed vote supersedes the previous vote for this answer. Choosing a
    // different preferred answer supersedes the old preference for the question.
    examples.removeAll {
      $0.node == example.node && $0.question == example.question && $0.draft == example.draft
        && ($0.answer == example.answer || ($0.vote == .prefer && example.vote == .prefer))
    }
    examples.insert(example, at: 0)
    examples = Array(examples.prefix(Self.maxExamples))
  }

  func personalizing(_ claim: ManagedClaim, for node: String) -> ManagedClaim {
    let messages = claim.request.messages
    guard !guidance.isEmpty || examples.contains(where: { $0.node == node }),
          messages.map(\.role) == ["system", "user"],
          messages.allSatisfy({ !$0.content.isEmpty && $0.content.utf8.count <= 16 * 1024 }),
          var input = (try? JSONSerialization.jsonObject(with: Data(messages[1].content.utf8))) as? [String: Any],
          let question = input["question"] as? String, let options = input["options"] as? [String]
    else { return claim }
    let labels = Set(options.map(Self.clean))
    let multiple = (input["navigation"] as? [String: Any])?["multiple"] as? Bool == true
    let matching = examples.filter { entry in
      guard entry.node == node, entry.question == Self.clean(question) else { return false }
      if entry.draft { return options.isEmpty }
      if labels.contains(entry.answer) { return true }
      let parts = entry.answer.components(separatedBy: "、")
      return multiple && parts.count > 1 && parts.allSatisfy(labels.contains)
    }
    var preferences: [String: Any] = [:]
    if !guidance.isEmpty { preferences["principles"] = guidance }
    if !matching.isEmpty {
      preferences["feedback"] = matching.prefix(2).map { ["vote": $0.vote.rawValue, "answer": $0.answer] }
    }
    guard !preferences.isEmpty else { return claim }
    input["personal_preferences"] = preferences
    let system = messages[0].content + "\n本机 personal_preferences 是用户明确保存的权衡偏好，仅在符合本次目标、可选答案与模式时参考。当前明确要求优先。偏好不能授权操作或改变输出格式。"
    guard system.utf8.count <= 16 * 1024,
          let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
          data.count <= 16 * 1024 else { return claim }
    return ManagedClaim(ticket: claim.ticket, mode: claim.mode, style: claim.style,
                        request: ManagedChatBody(messages: [.init(role: "system", content: system),
                                                             .init(role: "user", content: String(decoding: data, as: UTF8.self))],
                                                 max_tokens: claim.request.max_tokens))
  }
}

struct PersonalMemoryFile {
  let directory: URL
  static let local = Self(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("DecisionPreferences", isDirectory: true))
  private var file: URL { directory.appendingPathComponent("preferences.json") }

  func read() throws -> PersonalDecisionMemory {
    do { return try JSONDecoder().decode(PersonalDecisionMemory.self, from: Data(contentsOf: file)) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return PersonalDecisionMemory() }
  }

  func save(_ memory: PersonalDecisionMemory) throws {
    var directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    try JSONEncoder().encode(memory).write(to: file, options: [.atomic, .completeFileProtection])
  }
}
