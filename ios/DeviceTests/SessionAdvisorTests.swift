import Foundation
import SwiftUI
import WebKit
import XCTest

@testable import TmuxLink

private class AdvisorHTTPFixture: URLProtocol, @unchecked Sendable {
  class func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  func reply() throws -> (Int, Data) { throw URLError(.badServerResponse) }

  func completion(_ content: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": content]]]
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
