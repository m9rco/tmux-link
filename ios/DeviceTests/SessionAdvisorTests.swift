import Foundation
import SwiftUI
import WebKit
import XCTest

@testable import TmuxLink

class AdvisorHTTPFixture: URLProtocol, @unchecked Sendable {
  class func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  func reply() throws -> (Int, Data) { throw URLError(.badServerResponse) }

  func completion(_ content: String, finishReason: String = "stop") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "choices": [["finish_reason": finishReason, "message": ["role": "assistant", "content": content]]]
    ])
  }

  func requestBody() throws -> Data {
    if let data = request.httpBody { return data }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = stream.read(&chunk, maxLength: chunk.count)
      if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
      if count == 0 { return data }
      data.append(contentsOf: chunk.prefix(count))
    }
  }

  override func startLoading() {
    do {
      let (status, data) = try reply()
      let url = try XCTUnwrap(request.url)
      let response = try XCTUnwrap(HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}

final class SessionAdvisorTests: XCTestCase {
  func testManagedSessionCapabilityActionsAndNodeStatus() throws {
    let decoder = JSONDecoder()
    let old = try decoder.decode(RemoteSession.self, from: Data(#"{"id":7,"name":"work"}"#.utf8))
    XCTAssertNil(old.managedVersion)
    let current = try decoder.decode(RemoteSession.self, from: Data(#"{"id":7,"name":"work","managedVersion":2}"#.utf8))
    XCTAssertEqual(current.managedVersion, 2)
    XCTAssertEqual(ManagedAction.status.wireValue, "status")
    XCTAssertEqual(ManagedAction.disable.wireValue, "disable")
    XCTAssertEqual(ManagedAction.forget.wireValue, "forget")
    for mode in ManagedMode.allCases {
      for style in ManagedStyle.allCases {
        XCTAssertEqual(ManagedAction.enable(mode, style).wireValue, "enable-\(mode.rawValue)-\(style.rawValue)")
      }
    }
    let payload = """
      {"enabled":true,"state":"needsConfirmation","mode":"assist","style":"concise",
       "callsToday":2,"tokensToday":700,"memory":"Prefer short replies","records":[
         {"at":100,"question":"Language?","choice":null,"reason":"Needs keyboard input",
          "outcome":"needsConfirmation","mode":"assist","style":"concise","draft":"English"},
         {"at":99,"question":"Pick a layout","choice":"Compact","reason":"Fits the screen","outcome":"applied"}]}
      """
    let status = try decoder.decode(ManagedStatus.self, from: Data(payload.utf8))
    XCTAssertTrue(status.enabled)
    XCTAssertEqual(status.callsToday, 2)
    XCTAssertEqual(status.tokensToday, 700)
    XCTAssertEqual(status.records.map(\.at), [100, 99])
    XCTAssertNil(status.records[0].choice)
    XCTAssertEqual(status.records[0].draft, "English")
    XCTAssertEqual(status.records[1].choice, "Compact")
    XCTAssertNil(status.records[1].draft)
  }

  private func foregroundClaim() throws -> ManagedClaim {
    let body = #"""
      {"ticket":"0123456789abcdef","mode":"assist","style":"concise","request":{
        "model":"untrusted","url":"https://invalid.example","headers":{"Authorization":"node-value"},
        "max_tokens":384,"messages":[{"role":"system","content":"Return JSON."},{"role":"user","content":"Choose A or B."}]}}
      """#
    return try JSONDecoder().decode(ManagedClaim.self, from: Data(body.utf8))
  }

  func testManagedPhoneUsesOnlyTheConfiguredRelayAndModel() async throws {
    let relay = AdvisorProvider(id: UUID().uuidString, name: "Private gateway",
                                baseURL: "https://GATEWAY.example:443/company/v1/chat/completions/", model: "team/fast")
    final class Gateway: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/company/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer relay-fixture-only")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "team/fast")
        XCTAssertEqual(body["max_tokens"] as? Int, 384)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["headers"])
        XCTAssertNil(body["url"])
        return (200, Data(#"{"usage":{"total_tokens":7},"choices":[{"finish_reason":"stop","message":{"content":"{\"reason\":\"Matches the request\"}"}}]}"#.utf8))
      }
    }
    let session = Gateway.session()
    defer { session.invalidateAndCancel() }
    let reply = try await ManagedPhoneModel.complete(foregroundClaim(), key: "relay-fixture-only",
                                                     provider: relay, session: session)
    XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("Matches the request"))
    XCTAssertFalse(String(decoding: reply, as: UTF8.self).contains("relay-fixture-only"))
    let builtIn = try SessionAdvisor.chatRequest(instructions: "Return JSON", userMessage: "Test", key: "fixture",
                                                  maxTokens: 160, provider: .openAI)
    XCTAssertEqual(builtIn.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(builtIn.httpBody)) as? [String: Any])
    XCTAssertEqual(body["max_completion_tokens"] as? Int, 160)
    XCTAssertNil(body["thinking"])
  }

  func testManualDecisionPostsToReviewedProviderAndRejectsRedirects() async throws {
    let relay = AdvisorProvider(id: UUID().uuidString, name: "Review", baseURL: "https://review.example/v1", model: "review-model")
    final class Gateway: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        XCTAssertEqual(request.url?.absoluteString, "https://review.example/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "review-model")
        return (200, try completion(#"{"decisions":[]}"#))
      }
    }
    let session = Gateway.session()
    defer { session.invalidateAndCancel() }
    let brief = DecisionSnapshot(id: 7, name: "review", text: "Which format should be archived?").prepared()
    XCTAssertTrue(brief.canAnalyze)
    let decisions = try await SessionAdvisor.analyzePrepared([brief], key: "fixture-manual", provider: relay, session: session)
    XCTAssertTrue(decisions.isEmpty)

    let source = try XCTUnwrap(URL(string: relay.baseURL))
    let redirected = try XCTUnwrap(URL(string: "https://another.example/chat/completions"))
    let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil,
                                                headerFields: ["Location": redirected.absoluteString]))
    let redirect = SessionAdvisor.RedirectBlocker()
    var called = false
    redirect.urlSession(session, task: session.dataTask(with: source), willPerformHTTPRedirection: response,
                        newRequest: URLRequest(url: redirected)) { next in
      called = true
      XCTAssertNil(next)
    }
    XCTAssertTrue(called)
  }

  func testProviderSelectionPersistsAndKeychainStaysBoundToTheEndpoint() throws {
    let suite = "provider-fixture-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let id = UUID().uuidString
    let a = AdvisorProvider(id: id, name: "Gateway", baseURL: "https://a.example/proxy/v1", model: "m1")
    let b = AdvisorProvider(id: id, name: "Gateway", baseURL: "https://b.example/proxy/v1", model: "m2")
    var catalog = try AdvisorProviders.load(from: defaults)
    XCTAssertEqual(catalog.selected, .deepSeek)
    XCTAssertEqual(AdvisorProvider.deepSeek.keychainAccount, "deepseek")
    try AdvisorCredential.save("fixture-key-one", for: a)
    defer { try? AdvisorCredential.remove(for: a) }
    XCTAssertNil(try AdvisorCredential.load(for: b))
    catalog.profiles.append(a)
    catalog.selectedID = id
    try catalog.save(to: defaults)
    let active = try XCTUnwrap(AdvisorCredential.current(from: defaults))
    XCTAssertEqual(active.provider, a)
    XCTAssertEqual(active.key, "fixture-key-one")
    let metadata = try JSONEncoder().encode(try AdvisorProviders.load(from: defaults))
    XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("fixture-key-one"))
    for url in ["http://local.example/v1", "https://user:password@a.example", "https://a.example/?key=fixture",
                "https://a.example/#fragment", "https://a.example/../v1"] {
      XCTAssertThrowsError(try AdvisorProvider(id: id, name: "test", baseURL: url, model: "m").validated())
    }
    let redirectedDefault = AdvisorProvider(id: "deepseek", name: "DeepSeek", baseURL: b.baseURL, model: "m")
    XCTAssertThrowsError(try AdvisorCredential.load(for: redirectedDefault))
  }

  func testManagedPhonePinsModelAndReturnsOnlyDecisionAndUsage() async throws {
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-phone-secret")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["max_tokens"] as? Int, 384)
        XCTAssertNil(body["headers"])
        XCTAssertNil(body["url"])
        return (200, Data(#"""
          {"id":"provider-metadata","usage":{"total_tokens":90},"choices":[{"finish_reason":"stop","message":{
            "reasoning_content":"private-thought","content":"{\"choice\":1,\"reason\":\"Matches the requested format.\",\"action\":\"Enter\"}"}}]}
          """#.utf8))
      }
    }
    let data = try await ManagedPhoneModel.complete(foregroundClaim(), key: "fixture-phone-secret", session: Endpoint.session())
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(text.contains("Matches the requested format."))
    XCTAssertTrue(text.contains("total_tokens"))
    for forbidden in ["fixture-phone-secret", "provider-metadata", "private-thought", "action", "Enter"] {
      XCTAssertFalse(text.contains(forbidden))
    }
  }

  func testManagedPhoneAccountsForSplitUsageAndRejectsMissingCounts() throws {
    func receipt(_ usage: [String: Any]) throws -> Data {
      let data = try JSONSerialization.data(withJSONObject: [
        "choices": [["finish_reason": "length"]], "usage": usage
      ])
      return try ManagedPhoneModel.sanitizedResponse(data, key: "fixture")
    }
    let data = try receipt(["prompt_tokens": 7, "completion_tokens": 4])
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual((root["usage"] as? [String: Int])?["total_tokens"], 11)
    for invalid: [String: Any] in [[:], ["prompt_tokens": 7], ["total_tokens": true],
                                    ["prompt_tokens": -1, "completion_tokens": 3], ["total_tokens": 0.1]] {
      XCTAssertThrowsError(try receipt(invalid)) { error in
        guard case SessionAdvisorError.missingUsage = error else { return XCTFail("Expected a usage error") }
      }
    }
  }

  func testManagedPhoneFiltersCredentialEchoAndRejectsOversizedResponses() throws {
    let raw = Data(#"""
      {"usage":{"total_tokens":8},"choices":[{"finish_reason":"stop","message":{"content":"{\"reason\":\"fixture-phone-secret\"}"}}]}
      """#.utf8)
    let filtered = try ManagedPhoneModel.sanitizedResponse(raw, key: "fixture-phone-secret")
    let text = String(decoding: filtered, as: UTF8.self)
    XCTAssertTrue(text.contains("total_tokens"))
    XCTAssertFalse(text.contains("fixture-phone-secret"))
    XCTAssertFalse(text.contains("message"))
    XCTAssertThrowsError(try ManagedPhoneModel.sanitizedResponse(Data(repeating: 32, count: 65537), key: "fixture"))
  }

  @MainActor
  func testManagedControllerRequiresActiveSceneAndKeyAndPrunesRemovedClients() async throws {
    let suite = "managed-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let target = ManagedSessionController.Target(clientID: UUID(), sessionID: 7, name: "work", instance: "instance")
    let client = ClientProfile(id: target.clientID, name: "node", host: "private.example")
    let keyMissing = expectation(description: "checked local credential")
    let delivered = expectation(description: "returned ticket")
    let fixture = try foregroundClaim()
    var services = ManagedSessionController.Services()
    var key: String?
    var claims = 0
    var decisions = 0
    services.access = {
      if key == nil { keyMissing.fulfill() }
      return key.map { AdvisorAccess(provider: .deepSeek, key: $0) }
    }
    services.claim = { profile, id, instance in
      XCTAssertEqual(profile.id, target.clientID)
      XCTAssertEqual(id, target.sessionID)
      XCTAssertEqual(instance, target.instance)
      claims += 1
      return ManagedClaimResponse(enabled: true, claim: fixture)
    }
    services.model = { _, secret in
      XCTAssertEqual(secret.key, "phone-only-value")
      decisions += 1
      return Data("decision".utf8)
    }
    services.finish = { _, _, _, ticket, data in
      XCTAssertEqual(ticket, fixture.ticket)
      XCTAssertEqual(data, Data("decision".utf8))
      delivered.fulfill()
    }
    let controller = ManagedSessionController(defaults: defaults, services: services)
    controller.updateClients([client])
    controller.enable(target)
    controller.enable(target)
    XCTAssertEqual(controller.targets.count, 1)
    await Task.yield()
    XCTAssertEqual(claims, 0)
    controller.setActive(true)
    await fulfillment(of: [keyMissing], timeout: 2)
    XCTAssertEqual(claims, 0)
    key = "phone-only-value"
    controller.credentialChanged()
    await fulfillment(of: [delivered], timeout: 2)
    controller.setActive(false)
    XCTAssertEqual(claims, 1)
    XCTAssertEqual(decisions, 1)
    let persisted = try XCTUnwrap(defaults.data(forKey: "managed.foreground.targets.v2"))
    let stored = try XCTUnwrap((try JSONSerialization.jsonObject(with: persisted) as? [[String: Any]])?.first)
    XCTAssertEqual(Set(stored.keys), ["clientID", "sessionID", "name", "instance"])
    let resumed = ManagedSessionController(defaults: defaults, services: services)
    XCTAssertEqual(resumed.targets, [target])
    resumed.updateClients([])
    XCTAssertTrue(resumed.targets.isEmpty)
    XCTAssertTrue(ManagedSessionController(defaults: defaults, services: services).targets.isEmpty)
  }

  @MainActor
  func testManagedControllerRetriesReceiptWithoutAnotherModelCall() async throws {
    let suite = "managed-retry-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let target = ManagedSessionController.Target(clientID: UUID(), sessionID: 4, name: "work", instance: "instance")
    let lost = expectation(description: "first receipt lost")
    let received = expectation(description: "same receipt retried")
    let fixture = try foregroundClaim()
    var claims = 0
    var decisions = 0
    var attempts = 0
    var services = ManagedSessionController.Services()
    services.access = { AdvisorAccess(provider: .deepSeek, key: "fixture") }
    services.claim = { _, _, _ in
      claims += 1
      return ManagedClaimResponse(enabled: true, claim: fixture)
    }
    services.model = { _, _ in decisions += 1; return Data("answer".utf8) }
    services.finish = { _, _, _, ticket, data in
      attempts += 1
      XCTAssertEqual(ticket, fixture.ticket)
      XCTAssertEqual(data, Data("answer".utf8))
      if attempts == 1 {
        lost.fulfill()
        throw URLError(.networkConnectionLost)
      }
      received.fulfill()
    }
    let controller = ManagedSessionController(defaults: defaults, services: services)
    controller.updateClients([ClientProfile(id: target.clientID)])
    controller.enable(target)
    controller.setActive(true)
    await fulfillment(of: [lost], timeout: 2)
    controller.setActive(false)
    controller.setActive(true)
    await fulfillment(of: [received], timeout: 3)
    controller.setActive(false)
    XCTAssertEqual(claims, 1)
    XCTAssertEqual(decisions, 1)
    XCTAssertEqual(attempts, 2)
  }

  @MainActor
  func testManagedControllerDropsPendingDecisionWhenPhoneLocks() async throws {
    let suite = "managed-pause-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let target = ManagedSessionController.Target(clientID: UUID(), sessionID: 4, name: "work", instance: "instance")
    let started = expectation(description: "began model request")
    let stopped = expectation(description: "cancelled request on lock")
    let claim = try foregroundClaim()
    var services = ManagedSessionController.Services()
    services.access = { AdvisorAccess(provider: .deepSeek, key: "fixture") }
    services.claim = { _, _, _ in ManagedClaimResponse(enabled: true, claim: claim) }
    services.model = { _, _ in
      started.fulfill()
      defer { stopped.fulfill() }
      try await Task.sleep(for: .seconds(30))
      return Data()
    }
    services.finish = { _, _, _, _, _ in XCTFail("must not return a decision while inactive") }
    let controller = ManagedSessionController(defaults: defaults, services: services)
    controller.updateClients([ClientProfile(id: target.clientID)])
    controller.enable(target)
    controller.setActive(true)
    await fulfillment(of: [started], timeout: 2)
    controller.setActive(false)
    await fulfillment(of: [stopped], timeout: 2)
    XCTAssertEqual(controller.targets, [target])
  }

  func testRequestSendsOnlySessionLabelsAndRanksKnownIDsOnce() async throws {
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-credential")
        let data = try requestBody()
        let text = String(decoding: data, as: UTF8.self)
        for excluded in ["private-owner", "private-team", "touchPaging", "test-credential", "omitted-name"] {
          XCTAssertFalse(text.contains(excluded))
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let userMessages = messages.filter { $0["role"] == "user" }
        XCTAssertEqual(userMessages.count, 1)
        let user = try XCTUnwrap(userMessages.first)
        let content = try XCTUnwrap(user["content"])
        let query = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(Set(query.keys), ["question", "sessions"])
        XCTAssertEqual(query["question"] as? String, "Find the build")
        let labels = try XCTUnwrap(query["sessions"] as? [NSDictionary])
        XCTAssertEqual(labels, [
          ["id": 7, "name": "build", "directory": "ios"],
          ["id": 8, "name": "notes", "directory": "design"],
          ["id": 9, "name": "empty"],
        ])
        return (200, try completion(#"{"message":"Build is ready","session_ids":[8,99,8,-1,7,7]}"#))
      }
    }

    let candidates = [
      RemoteSession(id: 7, name: "build", touchPaging: true, directory: "/Users/private-owner/ios/"),
      RemoteSession(id: 8, name: "notes", directory: #"C:\private-team\design"#),
      RemoteSession(id: 9, name: "empty"),
      RemoteSession(id: 7, name: "omitted-name"),
      RemoteSession(id: -1, name: "omitted-name"),
    ]
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    let result = try await SessionAdvisor.advise(
      "Find the build", sessions: candidates, key: "test-credential", session: session)
    XCTAssertEqual(result.message, "Build is ready")
    XCTAssertEqual(result.sessionIDs, [8, 7])
  }

  func testCannotRecommendAnExistingIDThatWasOutsideTheRequestLimit() async throws {
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        (200, try completion(#"{"message":"Match","session_ids":[65,64,1,64]}"#))
      }
    }
    let candidates = (1...65).map { RemoteSession(id: Int64($0), name: "fixture-\($0)") }
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    let result = try await SessionAdvisor.advise(
      "Find a match", sessions: candidates, key: "fixture-key", session: session)
    XCTAssertEqual(result.sessionIDs, [64, 1])
  }

  func testMalformedModelResponseRaisesReadableError() async throws {
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        (200, try completion(#"{"message":"Match","session_ids":["not-a-session-id"]}"#))
      }
    }
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    do {
      _ = try await SessionAdvisor.advise(
        "Find build", sessions: [RemoteSession(id: 7, name: "build")], key: "test", session: session)
      XCTFail("Malformed session IDs must reject the response")
    } catch SessionAdvisorError.invalidResponse {
      XCTAssertFalse(SessionAdvisorError.invalidResponse.localizedDescription.isEmpty)
    }
  }

  func testUnauthorizedResponseIdentifiesCredentialProblemWithoutEchoingBody() async throws {
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        (401, Data(#"{"error":{"message":"echoed-secret-fixture"}}"#.utf8))
      }
    }
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    do {
      _ = try await SessionAdvisor.advise(
        "Find build", sessions: [RemoteSession(id: 7, name: "build")], key: "test", session: session)
      XCTFail("Unauthorized responses must reject the request")
    } catch SessionAdvisorError.authentication {
      let message = SessionAdvisorError.authentication.localizedDescription
      XCTAssertTrue(message.contains("密钥"))
      XCTAssertFalse(message.contains("echoed-secret-fixture"))
    }
  }

  @MainActor
  func testSelectingRecommendationOpensCurrentTerminalForOriginalClient() throws {
    let client = ClientProfile(name: "Fixture", host: "fixture.invalid", user: "fixture")
    let candidate = RemoteSession(id: 8, name: "build", directory: "/old/ios")
    let current = RemoteSession(id: 8, name: "build", touchPaging: true, directory: "/new/ios")
    let other = RemoteSession(id: 42, name: "build")
    let selection = try XCTUnwrap(AdvisorSelection(candidate, in: [other, current], client: client))
    XCTAssertEqual(selection.terminal.client, client)
    XCTAssertEqual(selection.terminal.session, current)

    XCTAssertNil(AdvisorSelection(candidate, in: [other], client: client))
    XCTAssertNil(AdvisorSelection(candidate, in: [RemoteSession(id: 8, name: "new")], client: client))
    let invalid = RemoteSession(id: -1, name: "fallback")
    XCTAssertNil(AdvisorSelection(invalid, in: [invalid], client: client))
  }

  private func isolatedBuildFixture() throws -> (client: ClientProfile, session: RemoteSession)? {
    let files = FileManager.default
    let file = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      .appendingPathComponent("tmux-link-e2e.json")
    guard files.fileExists(atPath: file.path) else { return nil }
    let config = try JSONDecoder().decode(RemoteSessionTests.Connection.self, from: Data(contentsOf: file))
    guard config.sessionName.hasPrefix("tmux-link-device-e2e-"), let id = config.benchmarkSessionID, id >= 0
    else { return nil }
    let client: ClientProfile
    if let link = config.importLink {
      client = try ClientTransfer.parse(link)
    } else {
      client = ClientProfile(
        name: "Advisor fixture", host: config.host, port: config.port, route: config.route ?? "",
        user: config.user, pin: config.fingerprint)
    }
    return (client, RemoteSession(id: id, name: config.sessionName + "-latency"))
  }

  @MainActor
  private func requireFixtureMarker(in terminal: TerminalView) async throws {
    let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {
      ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)
    }.first)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let host = UIHostingController(rootView: NavigationStack { terminal })
    window.rootViewController = host
    host.view.layoutIfNeeded()

    func terminalWebView(in view: UIView) -> TerminalWebView? {
      if let terminal = view as? TerminalWebView { return terminal }
      for child in view.subviews {
        if let terminal = terminalWebView(in: child) { return terminal }
      }
      return nil
    }
    // Other device tests can already have changed the fixture's first visible line.
    // Inspect rows in the renderer and return only the boolean to XCTest.
    let markerPresent = #"""
      (() => {
        if (typeof term === 'undefined' || !term.buffer?.active) return false;
        const b = term.buffer.active;
        for (let i = 0; i < term.rows; i++) {
          const row = b.getLine(b.viewportY + i)?.translateToString(true).trim();
          if (/^TL-(READY|WARM|\d{3}-[a-y]|TOP|BOTTOM|PTY[<>]\d+,\d+,\d+|FOOTER-(HIDDEN|VISIBLE))$/.test(row)) return true;
        }
        return false;
      })()
      """#
    let deadline = ProcessInfo.processInfo.systemUptime + 35
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let web = terminalWebView(in: host.view),
         (try? await web.evaluateJavaScript(markerPresent)) as? Bool == true { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RelayError("Timed out waiting for the isolated tmux fixture to render in the recommended terminal")
  }

  @MainActor
  func testLiveDeepSeekSessionRecommendation() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("This opt-in check runs on a physical device.")
    #else
      struct Configuration: Decodable {
        let key: String
        let saveAfterSuccess: Bool?
      }
      let files = FileManager.default
      let file = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        .appendingPathComponent("tmux-link-advisor-e2e.json")
      guard files.fileExists(atPath: file.path) else {
        throw XCTSkip("No one-time DeepSeek test configuration in the app cache.")
      }
      let settings = try { () -> Configuration in
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // Unlink first so cancellations and malformed input also consume the one-time file.
        try files.removeItem(at: file)
        return try JSONDecoder().decode(Configuration.self, from: handle.readToEnd() ?? Data())
      }()
      let key = settings.key.trimmingCharacters(in: .whitespacesAndNewlines)
      let fixture = try isolatedBuildFixture()
      let build = RemoteSession(id: fixture?.session.id ?? 73, name: "ios-build", directory: "/fictional/ios-build")
      let notes = RemoteSession(
        id: build.id == 19 ? 20 : 19, name: "garden-notes", directory: "/fictional/garden-notes")
      let advice = try await SessionAdvisor.advise(
        "我要进入名称恰好为 ios-build 的会话，请只推荐这个会话。", sessions: [notes, build], key: key)
      guard advice.sessionIDs == [build.id], !advice.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return XCTFail("DeepSeek did not identify the named synthetic build session") }
      if let fixture {
        let id = try XCTUnwrap(advice.sessionIDs.first)
        let recommended = RemoteSession(id: id, name: fixture.session.name)
        let current = try await SessionDirectory.fetch(fixture.client)
        let selection = try XCTUnwrap(AdvisorSelection(recommended, in: current, client: fixture.client),
                                      "The script's isolated tmux fixture is no longer available")
        try await requireFixtureMarker(in: selection.terminal)
        let receipt = XCTAttachment(string: "DeepSeek selected the synthetic build candidate and the app rendered the isolated tmux fixture.")
        receipt.name = "advisor-terminal-result"
        receipt.lifetime = .keepAlways
        add(receipt)
      }
      if settings.saveAfterSuccess == true {
        try AdvisorCredential.save(key)
        XCTAssertTrue(try AdvisorCredential.load() == key, "Saved advisor credential could not be read back")
      }
    #endif
  }
}
