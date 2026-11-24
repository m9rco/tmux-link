import ActivityKit
import CoreTransferable
import Darwin
import Foundation
import SwiftUI
import WebKit
import XCTest

@testable import TmuxLink

final class RemoteSessionTests: XCTestCase {
  struct Connection: Decodable {
    let host: String
    let port: UInt16
    let user: String
    let fingerprint: String
    let sessionName: String
    let importLink: String?
    let route: String?
    let hasHistoryFixture: Bool?
    let benchmarkSessionID: Int64?
    let decisionFixtureIDs: [Int64]?
    let snapshotFixtureID: Int64?
    let managedQuestionFixtureID: Int64?
    let conversationFixtureID: Int64?
    let conversationFixturePane: UInt64?
  }

  func configuration() throws -> Connection {
    let file = try XCTUnwrap(
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    ).appendingPathComponent("tmux-link-e2e.json")
    guard FileManager.default.fileExists(atPath: file.path) else {
      throw XCTSkip("Copy tmux-link-e2e.json to the app Documents folder to run the live test.")
    }
    return try JSONDecoder().decode(Connection.self, from: Data(contentsOf: file))
  }

  func testHostSnapshotRetainsEarlierConstraint() async throws {
    let config = try configuration()
    guard let id = config.snapshotFixtureID else { throw XCTSkip("No isolated decision pane configured") }
    let client = ClientProfile(name: "Snapshot fixture", host: config.host, port: config.port,
                               user: config.user, pin: config.fingerprint)
    let directory = try await SessionDirectory.fetch(client)
    let session = try XCTUnwrap(directory.first { $0.id == id && $0.name == "ios-decision-fixture" })
    XCTAssertEqual(session.negotiatedSnapshotVersion, .v2)
    let snapshot = try await SessionDirectory.snapshot(session, client: client)
    let metadata = try XCTUnwrap(snapshot.capture)
    XCTAssertEqual(metadata.columns, 32)
    XCTAssertEqual(metadata.rows, 24)
    XCTAssertEqual(metadata.historyRowsScanned, 5000)
    XCTAssertTrue(metadata.historyTruncated)
    XCTAssertTrue(metadata.historyCompacted)
    XCTAssertFalse(snapshot.context?.contains("Outside the scan window.") == true)
    let brief = snapshot.prepared()
    XCTAssertTrue(brief.blocks.contains {
      $0.source == .current && $0.kind == .question && $0.text == "Should we publish the validated catalog for review?"
    })
    XCTAssertTrue(brief.blocks.contains {
      $0.source == .history && $0.kind == .constraint && $0.text.contains("retain the signed catalog")
    })
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(brief).count, DecisionBrief.maxEncodedBytes)
  }

  private func managedConfiguration() throws -> Connection {
    if let fixture = ProcessInfo.processInfo.environment["TMUX_LINK_MANAGED_TEST_FIXTURE"] {
      return try JSONDecoder().decode(Connection.self, from: Data(fixture.utf8))
    }
    return try configuration()
  }

  func testManagedStatusUsesPinnedSessionWithoutEnablingIt() async throws {
    let config = try managedConfiguration()
    guard let id = config.snapshotFixtureID else { throw XCTSkip("No isolated decision pane configured") }
    let client = ClientProfile(name: "Managed fixture", host: config.host, port: config.port,
                               user: config.user, pin: config.fingerprint)
    let directory = try await SessionDirectory.fetch(client)
    let fixture = config.sessionName.hasPrefix("tmux-link-managed-e2e-") ? config.sessionName : "ios-decision-fixture"
    let session = try XCTUnwrap(directory.first { $0.id == id && $0.name == fixture })
    XCTAssertEqual(session.managedVersion, 2)
    let instance = try XCTUnwrap(session.managedInstance)
    let status = try await TerminalTransport.managed(client, sessionID: id, action: .status, instance: instance)
    XCTAssertFalse(status.enabled)
    let idle = try await TerminalTransport.claim(client, sessionID: id, instance: instance)
    XCTAssertFalse(idle.enabled)
    XCTAssertNil(idle.claim)
    XCTAssertTrue(status.records.isEmpty)
    XCTAssertEqual(status.callsToday, 0)
    XCTAssertEqual(status.tokensToday, 0)
  }

  func testForegroundPhoneCompletesAnIsolatedQuestion() async throws {
    let config = try managedConfiguration()
    guard let id = config.managedQuestionFixtureID else { throw XCTSkip("No managed question fixture configured") }
    let client = ClientProfile(name: "Phone advice fixture", host: config.host, port: config.port,
                               user: config.user, pin: config.fingerprint)
    let directory = try await SessionDirectory.fetch(client)
    let session = try XCTUnwrap(directory.first {
      $0.id == id && $0.name.hasPrefix("tmux-link-managed-question-") && $0.managedVersion == 2
    })
    let instance = try XCTUnwrap(session.managedInstance)
    let enabled = try await TerminalTransport.managed(client, sessionID: id, action: .enable(.observe, .balanced), instance: instance)
    XCTAssertTrue(enabled.enabled)
    do {
      let result = try await TerminalTransport.claim(client, sessionID: id, instance: instance)
      let claim = try XCTUnwrap(result.claim)
      let question = "What audience should the draft address?"
      XCTAssertTrue(claim.request.messages.last?.content.contains(question) == true)
      let provider = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"reason\":\"The audience determines the wording.\",\"draft\":\"Write for new contributors.\"}"}}],"usage":{"total_tokens":31}}"#.utf8)
      let envelope = try ManagedPhoneModel.sanitizedResponse(provider, key: "fixture-only-secret")
      let done = try await TerminalTransport.finish(client, sessionID: id, instance: instance, ticket: claim.ticket, envelope: envelope)
      XCTAssertEqual(done.callsToday, 1)
      XCTAssertEqual(done.tokensToday, 31)
      XCTAssertEqual(done.records.first?.question, question)
      XCTAssertEqual(done.records.first?.outcome, "observed")
      XCTAssertEqual(done.records.first?.draft, "Write for new contributors.")
      XCTAssertFalse(done.memory.isEmpty)
      let unchanged = try await TerminalTransport.claim(client, sessionID: id, instance: instance)
      XCTAssertNil(unchanged.claim)
    } catch {
      _ = try? await TerminalTransport.managed(client, sessionID: id, action: .disable, instance: instance)
      throw error
    }
    let paused = try await TerminalTransport.managed(client, sessionID: id, action: .disable, instance: instance)
    XCTAssertFalse(paused.enabled)
  }

  func testBoundConversationUsesLatestReply() async throws {
    let config = try configuration()
    guard let id = config.conversationFixtureID, let pane = config.conversationFixturePane else {
      throw XCTSkip("No isolated CodeMaker conversation configured")
    }
    let client = ClientProfile(name: "Bound conversation", host: config.host, port: config.port,
                               user: config.user, pin: config.fingerprint)
    let directory = try await SessionDirectory.fetch(client)
    let session = try XCTUnwrap(directory.first { $0.id == id && $0.name == "ios-bound-conversation" })
    XCTAssertEqual(session.negotiatedSnapshotVersion, .v2)
    let snapshot = try await SessionDirectory.snapshot(session, client: client)
    let capture = try XCTUnwrap(snapshot.capture)
    XCTAssertEqual(capture.paneId, pane)
    XCTAssertTrue(capture.alternate)
    XCTAssertEqual(capture.historyRowsScanned, 0)
    XCTAssertNil(snapshot.context)
    XCTAssertTrue(snapshot.text.isEmpty)
    let app = try XCTUnwrap(capture.applicationContext)
    XCTAssertEqual(app.source, "transcript")
    XCTAssertEqual(app.sessionID, "ses_simulator_catalog")
    XCTAssertEqual(app.order, "newestFirst")
    XCTAssertTrue(app.latestIsDisplayed)
    let question = "Should I publish the signed catalog?"
    let reply = "Yes, publish the signed catalog."
    XCTAssertEqual(app.messages.map(\.role), [.user, .assistant, .user])
    XCTAssertEqual(app.messages.map(\.text), [reply, question, "Keep the signed catalog."])
    let brief = snapshot.prepared()
    XCTAssertTrue(brief.blocks.contains { $0.source == .transcriptUser && $0.text == reply })
    XCTAssertTrue(brief.blocks.contains { $0.source == .transcriptAssistant && $0.text == question })
    XCTAssertFalse(brief.canAnalyze)
    let encoded = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    for marker in ["PRIVATE-TOOL-FIXTURE", "PRIVATE-METADATA-FIXTURE", "PRIVATE-HISTORY-FIXTURE"] {
      XCTAssertFalse(encoded.contains(marker))
    }
  }

  func roundtrip(_ config: Connection, command: String, expected: String) throws {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let view = pair[0]
    let stream = FileHandle(fileDescriptor: view, closeOnDealloc: false)
    let worker = pair[1]
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(view, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(view, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let client = ClientProfile(
      name: "E2E", host: config.host, port: config.port, user: config.user, pin: config.fingerprint)
    let connection = try TerminalTransport(client)
    let finished = expectation(description: "SSH transport closed")
    let lock = NSLock()
    var transportError: String?
    DispatchQueue.global(qos: .userInitiated).async {
      if let error = connection.run(worker, target: -1) {
        lock.lock()
        transportError = error
        lock.unlock()
      }
      finished.fulfill()
    }
    defer {
      shutdown(view, SHUT_RDWR)
      close(view)
      wait(for: [finished], timeout: 15)
      lock.lock()
      let failure = transportError
      lock.unlock()
      XCTAssertNil(failure, failure ?? "")
    }

    func send(_ text: String) throws {
      let bytes = Data(text.utf8)
      var frame = Data([0])
      var size = UInt32(bytes.count).bigEndian
      frame.append(Data(bytes: &size, count: 4))
      frame.append(bytes)
      try frame.withUnsafeBytes { raw in
        var written = 0
        while written < raw.count {
          let count = Darwin.send(
            view, raw.baseAddress!.advanced(by: written), raw.count - written, 0)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
          written += count
        }
      }
    }

    var received = Data()
    var sent = false
    var selected = false
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      guard let (kind, payload) = try Screen.readFrame(from: stream) else {
        throw RelayError("Terminal closed before expected output")
      }
      guard kind == 0 else { continue }
      received.append(payload)
      guard received.count < 1_048_576 else {
        throw NSError(domain: "TmuxLinkE2E", code: 2)
      }
      let screen = String(decoding: received, as: UTF8.self)
      if !selected && screen.contains("Session number:") {
        let choice = screen.components(separatedBy: .newlines).compactMap { line -> Int? in
          let columns = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
          guard columns.count == 2,
            columns[1].trimmingCharacters(in: .whitespacesAndNewlines) == config.sessionName
          else { return nil }
          return Int(columns[0])
        }.first
        try send("\(try XCTUnwrap(choice, "Requested test session is missing"))\r")
        selected = true
        received.removeAll(keepingCapacity: true)
        continue
      }
      if !sent && (screen.contains("\u{1b}[?1049h") || (selected && screen.contains(config.sessionName))) {
        try send(command + "\r")
        sent = true
        received.removeAll(keepingCapacity: true)
        continue
      }
      if sent && screen.contains(expected) { return }
    }
    XCTFail("Expected remote output did not arrive.")
  }

  func testIslandRoutingAndPrivateActivityPayload() throws {
    for model in ["iPhone15,2", "iPhone18,1", "iPhone19,2"] {
      XCTAssertTrue(IslandHardware.supported(model))
    }
    for model in ["iPhone14,7", "iPhone17,5", "iPad14,3", "unknown"] {
      XCTAssertFalse(IslandHardware.supported(model))
    }
    let measured = Date(timeIntervalSince1970: 123456)
    let online = TerminalActivityState(
      phase: .ready, mtls: true, milliseconds: 24, observedAt: measured)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(online)) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      Set(["phase", "mtls", "milliseconds", "timedOut", "observedAt", "historical"]))
    XCTAssertEqual(online.latencyText, "24 ms")
    XCTAssertEqual(online.display(at: measured.addingTimeInterval(29)).phase, .ready)
    let stale = online.display(at: measured.addingTimeInterval(30))
    XCTAssertEqual(stale.phase, .paused)
    XCTAssertEqual(stale.sampleText, "上次 24 ms")
    XCTAssertEqual(stale.observedAt, measured)
    XCTAssertEqual(online.display(at: measured, systemStale: true).phase, .paused)
    XCTAssertEqual(TerminalActivityState(phase: .paused).latencyText, "—")
    XCTAssertEqual(TerminalActivityState(phase: .ready, timedOut: true).latencyText, "超时")
  }

  func testRequiredCertificateAndProfileBinding() throws {
    var client = ClientProfile(
      name: "Test", host: "example.invalid", user: "tester", pin: "SHA256:test")
    client.requireMTLS = true
    XCTAssertThrowsError(try RelayIdentity.resolve(client))
    client.importedIdentity = true
    let expected = RelayCredential(
      host: "example.invalid", certificate: Data([42]), privateKey: Data([7]))
    try RelayIdentity.save(expected, for: client.id)
    defer { RelayIdentity.remove(client.id) }
    XCTAssertEqual(try RelayIdentity.resolve(client)?.certificate, expected.certificate)
    client.host = "wss://other.invalid/tmux-link"
    XCTAssertThrowsError(try RelayIdentity.resolve(client))
  }

  @MainActor
  func testStatusButtonFitsIslandAndInlineLayouts() {
    let portrait = CGRect(x: 0, y: 0, width: 402, height: 874)
    let surface = UIView(frame: portrait)
    let terminal = UIView(frame: portrait)
    let controls = TerminalStatusControls(frame: portrait)
    surface.addSubview(terminal)
    surface.addSubview(controls)
    func verifyTouches(_ frame: CGRect, line: UInt = #line) {
      controls.button.frame = frame
      let center = CGPoint(x: frame.midX, y: frame.midY)
      let below = CGPoint(x: frame.midX, y: frame.maxY + 8)
      XCTAssertTrue(surface.hitTest(center, with: nil)?.isDescendant(of: controls.button) == true, line: line)
      XCTAssertIdentical(surface.hitTest(below, with: nil), terminal, line: line)
    }
    let island = TerminalStatusControls.buttonFrame(in: portrait, topInset: 62, isPhone: true,
                                                   island: true, width: 38)
    verifyTouches(island)
    XCTAssertEqual(island.size, CGSize(width: 44, height: 44))
    XCTAssertGreaterThan(island.minX, portrait.midX + 60)
    XCTAssertEqual(island.midY, 31)
    XCTAssertLessThanOrEqual(island.maxY, 62)
    // A hidden status bar can yield no top inset even on an island-capable window.
    let hidden = TerminalStatusControls.buttonFrame(in: portrait, topInset: 0, isPhone: true,
                                                   island: true, width: 50)
    verifyTouches(hidden)
    XCTAssertGreaterThan(hidden.minX, portrait.midX + 60)
    XCTAssertEqual(hidden.minY, 0)
    for top: CGFloat in [0, 20, 47] {
      let inline = TerminalStatusControls.buttonFrame(in: portrait, topInset: top, isPhone: true,
                                                     island: false, width: 38)
      verifyTouches(inline)
      XCTAssertEqual(inline.maxX, portrait.maxX - (top >= 44 ? top / 2 : 0))
      XCTAssertEqual(inline.minY, 1)
      XCTAssertEqual(inline.size, CGSize(width: 44, height: 44))
    }
  }

  func testStatusFramesRejectTruncationAndOversize() throws {
    let pipe = Pipe()
    let stream = pipe.fileHandleForReading
    try pipe.fileHandleForWriting.write(
      contentsOf: Data([2, 0, 0, 0, 4, 0, 0, 0, 37, 0, 1, 0, 1, 0]))
    try pipe.fileHandleForWriting.close()
    let (kind, bytes) = try XCTUnwrap(Screen.readFrame(from: stream))
    XCTAssertEqual(kind, 2)
    XCTAssertEqual(bytes, Data([0, 0, 0, 37]))
    XCTAssertThrowsError(try Screen.readFrame(from: stream))
    let truncated = Pipe()
    try truncated.fileHandleForWriting.write(contentsOf: Data([0, 0, 0, 0, 4, 1]))
    try truncated.fileHandleForWriting.close()
    XCTAssertThrowsError(try Screen.readFrame(from: truncated.fileHandleForReading))
  }

  func testSavedClientsMigrateAndStayIndependent() throws {
    let suite = "dev.tmuxlink.test." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("alice", forKey: "Linux 用户名")
    defaults.set("SHA256:test-a", forKey: "内网 SSH 主机指纹 SHA256:…")
    let store = ProfileStore(defaults)
    let first = try XCTUnwrap(store.clients.first)
    XCTAssertEqual(first.endpoint, "center.example.com")
    let second = ClientProfile(
      name: "Build", port: 8443, route: "build", user: "bob", pin: "SHA256:test-b")
    store.save(second)
    XCTAssertEqual(ProfileStore(defaults).clients, [first, second])
    XCTAssertEqual(second.endpoint, "wss://center.example.com:8443/tmux-link/build")
    store.remove(first.id)
    XCTAssertEqual(ProfileStore(defaults).clients, [second])
    store.remove(second.id)
    XCTAssertTrue(ProfileStore(defaults).clients.isEmpty)
  }

  func testClientLinkRoundTripsPublicFieldsAndPreservesMTLSRequirement() throws {
    let pin = "SHA256:" + Data(repeating: 0xfb, count: 32).base64EncodedString()
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    let source = ClientProfile(
      name: "杭州 & QA + #1", host: "relay.example.com", port: 8443,
      route: "mac_2", user: "build-user", pin: pin, requireMTLS: false, importedIdentity: true)
    let link = try ClientTransfer.link(for: source)
    let url = try XCTUnwrap(URLComponents(string: link))
    XCTAssertEqual(url.scheme, "tmuxlink")
    XCTAssertEqual(url.host, "client")
    let fields = try XCTUnwrap(url.queryItems)
    XCTAssertEqual(
      Set(fields.map(\.name)), ["name", "host", "port", "route", "user", "pin", "requireMTLS"])
    XCTAssertTrue(link.contains("%2B"))
    XCTAssertFalse(link.contains(source.id.uuidString))
    let restored = try ClientTransfer.parse(link)
    var expected = source
    expected.id = restored.id
    expected.requireMTLS = true
    expected.importedIdentity = nil
    XCTAssertEqual(restored, expected)
    XCTAssertNotEqual(restored.id, source.id)
    XCTAssertNotEqual(try ClientTransfer.parse(link).id, restored.id)
    XCTAssertTrue(restored.valid)
  }

  func testClientPasteAcceptsSystemTextAndURLProviders() async throws {
    let text = #"{"host":"relay.example.com","name":"剪贴板","port":8443,"requireMTLS":true}"#
    let endpoint = try XCTUnwrap(URL(string: "wss://relay.example.com:8443/tmux-link/build"))
    for (provider, expected) in [
      (NSItemProvider(object: text as NSString), text),
      (NSItemProvider(object: endpoint as NSURL), endpoint.absoluteString),
    ] {
      let item: PastedClientConfiguration = try await withCheckedThrowingContinuation {
        continuation in
        _ = provider.loadTransferable(type: PastedClientConfiguration.self) {
          continuation.resume(with: $0)
        }
      }
      XCTAssertEqual(item.text, expected)
      let draft = try ClientTransfer.parse(item.text)
      XCTAssertEqual(draft.relayHost, "relay.example.com")
      XCTAssertTrue(draft.user.isEmpty)
      XCTAssertTrue(draft.pin.isEmpty)
      XCTAssertFalse(draft.valid)
      if expected == text {
        XCTAssertEqual(draft.name, "剪贴板")
        XCTAssertEqual(draft.port, 8443)
        XCTAssertEqual(draft.requireMTLS, true)
      } else {
        XCTAssertEqual(draft.endpoint, endpoint.absoluteString)
      }
    }
  }

  func testOutboundPairingLinkKeepsTheHostFingerprint() throws {
    var url = URLComponents()
    url.scheme = "tmuxlink"
    url.host = "pair"
    url.queryItems = [
      URLQueryItem(name: "center", value: "center.example.com"),
      URLQueryItem(name: "port", value: "443"),
      URLQueryItem(name: "id", value: String(repeating: "a", count: 32)),
      URLQueryItem(name: "code", value: String(repeating: "b", count: 64)),
      URLQueryItem(name: "name", value: "内网机器"),
      URLQueryItem(name: "user", value: "alice"),
      URLQueryItem(name: "pin", value: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
    ]
    let offer = try HostPairing.parse(try XCTUnwrap(url.string))
    XCTAssertEqual(offer.client.name, "内网机器")
    XCTAssertEqual(offer.client.user, "alice")
    XCTAssertEqual(offer.client.requireMTLS, true)
    XCTAssertEqual(offer.client.host, "wss://center.example.com:443/tmux-link/session/" + String(repeating: "a", count: 32))
    XCTAssertEqual(offer.approvalURL, "wss://center.example.com:443/tmux-link/pair")
    url.queryItems?.append(URLQueryItem(name: "code", value: "duplicate"))
    XCTAssertThrowsError(try HostPairing.parse(try XCTUnwrap(url.string)))
  }

  func testClientPasteRejectsCredentialFieldsAndUnsupportedAddresses() {
    let inputs = [
      "https://relay.example.com/", "ssh://user@relay.example.com/", "ws://relay.example.com/",
      "wss://person:password@relay.example.com/tmux-link",
      "tmuxlink://client?host=one.example&host=two.example",
      "tmuxlink://client?host=one.example&privateKey=fixture",
      #"{"host":"one.example","id":"00000000-0000-0000-0000-000000000000"}"#,
      #"{"host":"one.example","importedIdentity":true}"#,
      #"{"host":"one.example","privateKey":"test-only"}"#,
      #"{"host":"one.example","pin":"SHA256:不是指纹"}"#,
    ]
    for input in inputs { XCTAssertThrowsError(try ClientTransfer.parse(input), input) }
  }

  func testDiscardedClientImportLeavesExistingProfileIntact() throws {
    let suite = "dev.tmuxlink.test." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ProfileStore(defaults)
    let saved = ClientProfile(name: "Original", host: "one.example")
    store.save(saved)
    let text = #"{"host":"one.example","name":"Imported"}"#
    var discarded = try ClientTransfer.parse(text)
    discarded.name = "Cancelled edit"
    XCTAssertNotEqual(discarded.id, saved.id)
    XCTAssertEqual(store.clients, [saved])
    XCTAssertEqual(ProfileStore(defaults).clients, [saved])
  }

  @MainActor
  func testWorkspaceIsVisible() {
    XCTAssertNotNil(rootController as? UIHostingController<Workspace>)
  }

  @MainActor private var rootController: UIViewController? { appWindow?.rootViewController }

  @MainActor private var appWindow: UIWindow? {
    UIApplication.shared.connectedScenes.compactMap {
      ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)
    }.first
  }

  @MainActor private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  @MainActor
  private func loadBundledTerminal() async throws -> (WKWebView, UIViewController) {
    final class OfflineBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
      let loaded = XCTestExpectation(description: "Bundled terminal page loaded")
      func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
      func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
      ) {}
    }
    let bridge = OfflineBridge()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(bridge, name: "terminal")
    let web = WKWebView(frame: .zero, configuration: configuration)
    web.navigationDelegate = bridge
    let controller = UIViewController()
    controller.view = web
    controller.modalPresentationStyle = .fullScreen
    try XCTUnwrap(rootController).present(controller, animated: false)
    let index = try XCTUnwrap(
      Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets"))
    web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    await fulfillment(of: [bridge.loaded], timeout: 10)

    return (web, controller)
  }

  @MainActor
  func testDecisionScreenSeparatesLivePromptFromHistoryAndConcealedCells() async throws {
    let (web, controller) = try await loadBundledTerminal()
    defer { controller.dismiss(animated: false) }
    let checks = try await web.callAsyncJavaScript(#"""
      await ready;
      const write = s => new Promise(r => term.write(s, r));
      await write("EARLIER-GOAL\r\n" + "checking\r\n".repeat(term.rows + 2));
      await write("Proceed? [y/n] \x1b[8mhidden-cell\x1b[28m");
      term.scrollToTop();
      const normal = decisionScreen();
      await write("\x1b[?1049h\x1b[HChoose format: CSV or JSON?");
      const alternate = decisionScreen();
      term.resize(24, 52);
      await write("\x1b[2J\x1b[H" + "WHY-KEEP-THIS-" + "X".repeat(30) + "\r\n" + "status\r\n".repeat(45) + "Approve?");
      const tall = decisionScreen();
      return [normal.text.includes('Proceed? [y/n]'), !normal.text.includes('EARLIER-GOAL'),
              normal.context.includes('EARLIER-GOAL'), !normal.text.includes('hidden-cell'),
              alternate.text.includes('Choose format'), alternate.context === '',
              normal.bufferType === 'normal', alternate.bufferType === 'alternate',
              tall.text.includes('WHY-KEEP-THIS-' + 'X'.repeat(30)), tall.text.includes('Approve?')];
      """#, arguments: [:], in: nil, contentWorld: .page) as? [Bool]
    XCTAssertEqual(checks, Array(repeating: true, count: 10))
  }

  @MainActor
  func testSplitPaneRedrawKeepsPreviousTextVisible() async throws {
    let (web, controller) = try await loadBundledTerminal()
    defer { controller.dismiss(animated: false) }
    let script = #"""
      await ready;
      const write = text => window.display(btoa(text));
      const painted = () => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
      await painted();
      const body = document.querySelector('.xterm-rows');
      const visible = () => document.querySelector('.terminal-redraw') || body;
      const region = Math.min(12, term.rows - 2);
      function screenText(prefix) {
        return Array.from({length: region}, (_, i) => '\x1b[' + (i + 1) + ';1H' + prefix + i).join('');
      }
      await write(screenText('OLD') + '\x1b[' + (region + 1) + ';1HSTATUS');
      await painted();
      // tmux scrolls the entire pane away but leaves its status line on screen.
      // Feed the CSI itself in two packets and give WebKit time to paint the gap.
      const erase = '\x1b[1;' + region + 'r\x1b[' + region + 'S\x1b[r';
      await write(erase.slice(0, 2));
      await write(erase.slice(2));
      await painted();
      const cleared = !body.textContent.includes('OLD') && body.textContent.includes('STATUS');
      const retained = visible().textContent.includes('OLD0');
      await write(screenText('NEW'));
      await painted();
      const replaced = visible() === body && body.textContent.includes('NEW0');
      await write(erase);
      await new Promise(done => setTimeout(done, 300));
      const clearedForGood = visible() === body && !body.textContent.includes('NEW');
      await write(screenText('NEXT'));
      await painted();
      await write('\x1b[1;' + region + 'r\x1b[S\x1b[r');
      await painted();
      const ordinaryScroll = visible() === body && !body.textContent.includes('NEXT0') && body.textContent.includes('NEXT1');
      return [cleared, retained, replaced, clearedForGood, ordinaryScroll];
      """#
    let checks = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [Bool]
    XCTAssertEqual(checks, [true, true, true, true, true],
                   "Split repaint, eventual clear and single-line scrolling must stay distinct")
  }

  @MainActor
  func testBundledTerminalUnicodeCellWidths() async throws {
    let (web, controller) = try await loadBundledTerminal()
    defer { controller.dismiss(animated: false) }

    // The one-cell ASCII control calibrates the rendered width on this device.
    // These widths, including the split ZWJ sequence, match cursor_x in tmux 3.4.
    let glyphs = ["A", "中", "e\u{301}", "🦊", "🫠", "👩‍💻", "\u{e0b0}", "\u{f07c}"]
    let widths = [1, 2, 1, 2, 2, 2, 1, 1]
    let script = #"""
      const marker = '\x1b[31m|\x1b[0m';
      const encode = new TextEncoder();
      const send = bytes => window.display(btoa(String.fromCharCode(...bytes)));
      await send(encode.encode(marker));
      const cursors = [];
      for (const glyph of glyphs) {
        // Exercise the native byte bridge with UTF-8 split inside every multibyte code point.
        for (const byte of encode.encode(glyph)) await send([byte]);
        await send(encode.encode(marker));
        cursors.push(term.buffer.active.cursorX);
      }
      const symbolFaces = await document.fonts.load('14px "Terminal Symbols"', '\ue0b0\uf07c');
      await document.fonts.ready;
      await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
      const row = document.querySelector('.xterm-rows > div');
      const positions = [...row.querySelectorAll('span')]
        .filter(element => element.textContent === '|')
        .map(element => element.getBoundingClientRect().left);
      const buffer = term.buffer.active;
      return {
        cursors, positions, line: buffer.getLine(buffer.baseY).translateToString(true),
        symbolFont: symbolFaces.some(face => face.status === 'loaded')
          && getComputedStyle(row).fontFamily.includes('Terminal Symbols')
      };
      """#
    let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript(script, arguments: ["glyphs": glyphs], in: nil, in: .page) { value in
        continuation.resume(with: Result { try XCTUnwrap(value.get() as? [String: Any]) })
      }
    }
    let cursors = try XCTUnwrap(result["cursors"] as? [Int])
    let positions = try XCTUnwrap(result["positions"] as? [Double])
    XCTAssertEqual(result["symbolFont"] as? Bool, true, "Prompt icons need the bundled symbol font")
    XCTAssertEqual(result["line"] as? String, "|" + glyphs.joined(separator: "|") + "|")
    guard cursors.count == glyphs.count else {
      return XCTFail("Missing terminal cursor samples: \(cursors)")
    }
    guard positions.count == glyphs.count + 1 else {
      return XCTFail("Expected a visible boundary around each glyph, got \(positions)")
    }
    let cell = (positions[1] - positions[0]) / 2
    XCTAssertGreaterThan(cell, 0)
    var cursor = 1
    for (i, glyph) in glyphs.enumerated() {
      cursor += widths[i] + 1
      XCTAssertEqual(cursors[i], cursor, "Cursor after \(glyph)")
      let distance = positions[i + 1] - positions[i]
      XCTAssertEqual(distance, Double(widths[i] + 1) * cell, accuracy: 1, "Rendered \(glyph)")
    }
    let snapshotScript = #"""
      term.reset();
      await new Promise(done => term.write('A中👩‍💻 sample\r\n\x1b[8mhidden\x1b[0m', done));
      const box = document.querySelector('.xterm-screen').getBoundingClientRect();
      return selectionSnapshot(box.left + (3.5 / term.cols) * box.width, box.top + box.height / term.rows / 2);
      """#
    let snapshot: [String: Any] = try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript(snapshotScript, arguments: [:], in: nil, in: .page) { result in
        continuation.resume(with: Result { try XCTUnwrap(result.get() as? [String: Any]) })
      }
    }
    let frozen = try XCTUnwrap(snapshot["text"] as? String)
    XCTAssertTrue(frozen.hasPrefix("A中👩‍💻 sample"))
    XCTAssertFalse(frozen.contains("hidden"))
    XCTAssertEqual(snapshot["offset"] as? Int, "A中".utf16.count)
    XCTAssertEqual(snapshot["atCursor"] as? Bool, false)
    var copied: String?
    let selection = TerminalTextSelection(text: frozen, offset: try XCTUnwrap(snapshot["offset"] as? Int)) {
      copied = $0
    }
    selection.loadViewIfNeeded()
    selection.copySelection()
    XCTAssertEqual(copied, "👩‍💻")
    let echoScript = #"""
      resetInput();
      term.reset();
      const write = s => new Promise(done => term.write(s, done));
      await write('$ ');
      terminalData('echo 中文');
      await write('echo 中文\x1b7\x1b[90m old suggestion\x1b[0m\x1b8');
      const atEnd = inputSpan().text;
      terminalData('\x1b[D');
      await write('\x1b[2D');
      return [atEnd, inputSpan().text];
      """#
    let echoed: [String] = try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript(echoScript, arguments: [:], in: nil, in: .page) { result in
        continuation.resume(with: Result { try XCTUnwrap(result.get() as? [String]) })
      }
    }
    XCTAssertEqual(echoed, ["echo 中文", "echo 中文"])


  }

  @MainActor
  func testKeyboardRowAndCursorModes() async throws {
    let (web, controller) = try await loadBundledTerminal()
    defer { controller.dismiss(animated: false) }
    let bar = TerminalKeyboardBar()
    let buttons = descendants(bar).compactMap { $0 as? UIButton }
    let shortcuts = buttons.filter { $0.accessibilityIdentifier != "terminal.keyboard.hide" }
    XCTAssertEqual(shortcuts.compactMap { $0.title(for: .normal) }, ["Esc", "Tab", "⌃C", "⌃B", "←", "→"])
    XCTAssertTrue(shortcuts.allSatisfy { !$0.isEnabled })
    bar.setReady(true)
    var keys: [String] = []
    bar.press = { keys.append($0) }
    for button in shortcuts { button.sendActions(for: .touchUpInside) }
    XCTAssertEqual(keys, ["\u{1b}", "\t", "\u{03}", "\u{02}", "\u{1b}[D", "\u{1b}[C"])
    let script = #"""
      await ready;
      const output = [];
      const watch = term.onData(s => output.push(s));
      pressTerminalKey(left);
      await new Promise(done => term.write('\x1b[?1h', done));
      pressTerminalKey(left);
      watch.dispose();
      return output;
      """#
    let output = try await web.callAsyncJavaScript(script, arguments: ["left": TerminalKey.left.rawValue],
                                                   in: nil, contentWorld: .page) as? [String]
    XCTAssertEqual(output, ["\u{1b}[D", "\u{1b}OD"])
  }

  @MainActor
  func testOfflineEnglishAndPinyinKeyboard() async throws {
    let saved = UserDefaults.standard.string(forKey: "terminal.typing.language")
    defer { UserDefaults.standard.set(saved, forKey: "terminal.typing.language") }
    // An installation upgraded from a release that remembered Chinese must also start in English.
    UserDefaults.standard.set("zh", forKey: "terminal.typing.language")
    let board = TerminalTypingKeyboard()
    let page = board.surface
    var committed: [String] = []
    board.onText = { committed.append($0) }
    for _ in 0..<100 {
      if (try? await page.evaluateJavaScript("typeof keyboard === 'object'")) as? Bool == true { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let script = #"""
      const initialSpace = keyboard.getButtonElement('{space}').textContent;
      const key = k => keyboard.handleButtonClicked(k);
      key('a'); key('{shift}'); key('B'); key('{symbols}'); key('7'); key('{symbols}');
      key('{lang}');
      for (const c of 'nihaoshijie') key(c);
      const phrase = options[0].text;
      key('{space}');
      for (const c of 'shijie') key(c);
      const alternative = options.findIndex(x => x.text === '师姐');
      choose(alternative);
      for (const c of "xi'an") key(c);
      const disambiguated = options[0].text;
      key('{bksp}'); handleShortcut('\x1b');
      key('n'); key('i'); key('{enter}'); key('{enter}'); key('{bksp}');
      return [initialSpace, phrase, disambiguated, pending, keyboard.getInput()];
      """#
    let result = try await page.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String]
    XCTAssertEqual(result, ["space", "你好世界", "西安", "", ""])
    for _ in 0..<30 where committed.count < 8 { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertEqual(committed, ["a", "B", "7", "你好世界", "师姐", "你", "\r", "\u{7f}"])
  }

  @MainActor
  func testMixedPinyinDraftEditing() async throws {
    let board = TerminalTypingKeyboard()
    var committed = ""
    board.onText = { committed += $0 }
    for _ in 0..<100 {
      if (try? await board.surface.evaluateJavaScript("typeof keyboard === 'object'")) as? Bool == true { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let script = #"""
      const key = k => keyboard.handleButtonClicked(k);
      key('{lang}');
      const type = s => { for (const c of s) key(c); };
      const snapshots = [];
      type("nihao'shijie");
      choose(options.findIndex(x => x.text === '你好'));
      snapshots.push(spelling.textContent);
      key('{lang}'); key('{lang}'); key('{bksp}');
      snapshots.push(spelling.textContent);
      choose(options.findIndex(x => x.text === '你好'));
      type('x'); key('{bksp}'); snapshots.push(spelling.textContent);
      choose(options.findIndex(x => x.text === '师姐'));
      type('git'); key('{lang}'); key('{space}');
      key('{lang}'); type('ni'); key('{lang}'); key('{enter}');
      key('{lang}'); type('sh'); spelling.click();
      type('nihao'); handleShortcut('\t'); snapshots.push(spelling.textContent);
      key('{space}');
      for (const phrase of ['qingjianchazheduandaima', 'womeiyouwenti', 'qingbangwoxiufuzhegewenti']) {
        type(phrase); snapshots.push(options[0].text); key('{space}');
      }
      type('z'.repeat(160)); spelling.click();
      return snapshots;
      """#
    let result = try await board.surface.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String]
    XCTAssertEqual(result, ["你好shijie", "nihao'shijie", "你好shijie", "nihao",
                            "请检查这段代码", "我没有问题", "请帮我修复这个问题"])
    let expected = "你好师姐git nish\t你好请检查这段代码我没有问题请帮我修复这个问题" + String(repeating: "z", count: 160)
    for _ in 0..<50 where committed.utf8.count < expected.utf8.count {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(committed, expected)
  }

  @MainActor
  func testShortcutDrawerInShortViewport() throws {
    let viewport = UIView(frame: CGRect(x: 0, y: 0, width: 640, height: 180))
    var sent: [String] = []
    let drawer = ShortcutDrawer(in: viewport, accent: .systemMint) { sent.append($0) }
    drawer.setReady(true)
    viewport.layoutIfNeeded()
    let panel = try XCTUnwrap(descendants(drawer).first {
      $0.accessibilityIdentifier == "terminal.shortcuts"
    } as? UIScrollView)
    let reveal = try XCTUnwrap(descendants(drawer).first {
      $0.accessibilityIdentifier == "terminal.shortcuts.open"
    } as? UIButton)
    let enter = try XCTUnwrap(descendants(panel).first {
      $0.accessibilityIdentifier == "terminal.key.↵"
    } as? UIButton)
    XCTAssertTrue(panel.isHidden)
    XCTAssertTrue(viewport.hitTest(CGPoint(x: 300, y: 90), with: nil) === viewport)
    UIView.performWithoutAnimation { reveal.sendActions(for: .touchUpInside) }
    viewport.layoutIfNeeded()
    XCTAssertEqual(panel.frame.height, viewport.bounds.height, accuracy: 1)
    XCTAssertGreaterThan(panel.contentSize.height, panel.bounds.height)
    let lastRow = enter.convert(enter.bounds, to: panel)
    panel.scrollRectToVisible(lastRow, animated: false)
    XCTAssertTrue(panel.bounds.contains(lastRow))
    XCTAssertTrue(viewport.hitTest(enter.convert(CGPoint(x: 20, y: 20), to: viewport),
                                   with: nil)?.isDescendant(of: enter) == true)
    enter.sendActions(for: .touchUpInside)
    XCTAssertEqual(sent, ["\r"])
    XCTAssertFalse(panel.isHidden)
  }

  @MainActor
  private func verifyKeyboardLayout(_ web: WKWebView, checkRemoteCursor: Bool = false) async throws {
    let terminal = try XCTUnwrap(web as? TerminalWebView)
    let window = try XCTUnwrap(terminal.window)
    let viewport = try XCTUnwrap(web.superview)
    let hide = try XCTUnwrap(descendants(terminal.shortcutBar).first {
      $0.accessibilityIdentifier == "terminal.keyboard.hide"
    } as? UIButton)
    let pixel = 1 / window.screen.scale
    func sampleGrid() async throws -> CGRect {
      let result = try await web.callAsyncJavaScript("""
        await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
        const r = term.element.querySelector('.xterm-screen').getBoundingClientRect();
        return [r.left, r.top, r.width, r.height];
        """, arguments: [:], in: nil, contentWorld: .page) as? [Double]
      let rect = try XCTUnwrap(result)
      return web.convert(CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), to: window)
    }
    func open() async throws {
      _ = try await web.evaluateJavaScript("term.textarea.click(); true")
      for _ in 0..<100 where terminal.typingKeyboard.isHidden {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertFalse(terminal.typingKeyboard.isHidden)
      XCTAssertFalse(terminal.shortcutBar.isHidden)
    }
    func fixtureReply(key: String, marker: String) async throws -> (row: Int, suffix: String) {
      _ = try await web.callAsyncJavaScript("pressTerminalKey(key); return true",
        arguments: ["key": key], in: nil, contentWorld: .page)
      for _ in 0..<150 {
        let result = try await web.callAsyncJavaScript("""
          const b = term.buffer.active;
          const line = b.getLine(b.baseY + b.cursorY)?.translateToString(true);
          return line?.startsWith(marker) ? [b.baseY + b.cursorY - b.viewportY, line.slice(marker.length)] : [];
          """, arguments: ["marker": marker], in: nil, contentWorld: .page) as? [Any]
        if let result, result.count == 2, let row = result[0] as? Int, let suffix = result[1] as? String {
          return (row, suffix)
        }
        try await Task.sleep(for: .milliseconds(30))
      }
      throw NSError(domain: "TerminalTest", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Remote fixture did not draw " + marker])
    }

    let initial = try await web.evaluateJavaScript("[term.cols, term.rows]") as? [Int]
    let full = try XCTUnwrap(initial)
    let canvas = web.bounds.size
    let fullGrid = try await sampleGrid()
    _ = try await web.evaluateJavaScript("""
      window.keyboardSizes = [];
      window.watchGrid = term.onResize(({cols, rows}) => keyboardSizes.push([cols, rows]));
      true
      """)
    defer { web.evaluateJavaScript("watchGrid.dispose()", completionHandler: nil) }
    // Initial attach may legitimately resize the PTY; compare counter and dimensions from this point.
    let before = checkRemoteCursor ? try await fixtureReply(key: "<", marker: "TL-PTY<").suffix : nil
    func checkCaret(row: Int, in drawn: CGRect) {
      let visible = viewport.convert(viewport.bounds, to: window)
      let cell = drawn.height / CGFloat(full[1])
      let top = drawn.minY + CGFloat(row) * cell
      XCTAssertGreaterThanOrEqual(top, visible.minY - pixel)
      XCTAssertLessThanOrEqual(top + cell, visible.maxY + pixel)
    }
    func checkBottomEditor(hiddenCursor: Bool) async throws {
      _ = try await web.callAsyncJavaScript("pressTerminalKey(key); return true",
        arguments: ["key": hiddenCursor ? "}" : "{"], in: nil, contentWorld: .page)
      let footer = hiddenCursor ? "TL-FOOTER-HIDDEN" : "TL-FOOTER-VISIBLE"
      var rows: [Int]?
      for _ in 0..<150 {
        let result = try await web.callAsyncJavaScript("""
          const b = term.buffer.active;
          const lines = Array.from({length: term.rows}, (_, y) =>
            b.getLine(b.viewportY + y)?.translateToString(true) || '');
          const footerRow = lines.indexOf(footer);
          if (footerRow < 0) return [];
          const caretRow = b.baseY + b.cursorY - b.viewportY;
          const drawn = term.element.querySelector('.xterm-rows .xterm-cursor');
          if (hidden ? drawn : !drawn) return [];
          return [lines.findIndex(line => line.includes('TL-EDITOR-TOP')),
                  lines.findIndex(line => line.includes(hidden ? 'prompt_' : '> prompt')),
                  lines.findIndex(line => line.includes('TL-EDITOR-END')), footerRow, caretRow];
          """, arguments: ["footer": footer, "hidden": hiddenCursor], in: nil, contentWorld: .page) as? [Int]
        if let result, result.count == 5 { rows = result; break }
        try await Task.sleep(for: .milliseconds(30))
      }
      let recorded = try XCTUnwrap(rows, "Incomplete multi-line TUI fixture: " + footer)
      let first = recorded[0], input = recorded[1], edge = recorded[2], last = recorded[3]
      XCTAssertGreaterThanOrEqual(first, 0)
      XCTAssertEqual(input, first + 1)
      XCTAssertEqual(edge, first + 4)
      XCTAssertEqual(last, input + 4)
      if !hiddenCursor { XCTAssertEqual(recorded[4], input) }
      // An accessibility click has no touch coordinates, also exercising the hidden-caret default.
      try await open()
      let drawn = try await sampleGrid()
      for row in [first, input, edge, last] { checkCaret(row: row, in: drawn) }
      hide.sendActions(for: .touchUpInside)
      let restored = try await sampleGrid()
      XCTAssertEqual(restored.minY, fullGrid.minY, accuracy: pixel)
      XCTAssertEqual(restored.maxY, fullGrid.maxY, accuracy: pixel)
    }
    for bottom in [true, false, true] {
      let row = checkRemoteCursor ? try await fixtureReply(
        key: bottom ? "$" : "^", marker: bottom ? "TL-BOTTOM" : "TL-TOP").row : nil
      try await open()
      let drawn = try await sampleGrid()
      XCTAssertEqual(drawn.width, fullGrid.width, accuracy: pixel)
      XCTAssertEqual(drawn.height, fullGrid.height, accuracy: pixel)
      XCTAssertEqual(web.bounds.size, canvas)
      if let row {
        checkCaret(row: row, in: drawn)
        if bottom {
          XCTAssertGreaterThanOrEqual(row, full[1] - 3)
          // Moving to the opposite end while typing brings the caret into view once.
          let top = try await fixtureReply(key: "^", marker: "TL-TOP")
          let shifted = try await sampleGrid()
          checkCaret(row: top.row, in: shifted)
          XCTAssertGreaterThan(shifted.minY, drawn.minY)
          // The next reply stays within that visible region and must leave its origin alone.
          let near = try await fixtureReply(key: "z", marker: "TL-WARM")
          let still = try await sampleGrid()
          checkCaret(row: near.row, in: still)
          XCTAssertEqual(still.minY, shifted.minY, accuracy: pixel)
        } else {
          XCTAssertLessThanOrEqual(row, 1)
        }
      }
      hide.sendActions(for: .touchUpInside)
      let restored = try await sampleGrid()
      XCTAssertEqual(restored.minY, fullGrid.minY, accuracy: pixel)
      XCTAssertEqual(restored.maxY, fullGrid.maxY, accuracy: pixel)
      XCTAssertTrue(terminal.typingKeyboard.isHidden)
    }
    if checkRemoteCursor {
      try await checkBottomEditor(hiddenCursor: false)
      try await checkBottomEditor(hiddenCursor: true)
    }
    try await open()
    XCTAssertTrue(terminal.typingKeyboard.window === terminal.window)
    let statusButton = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first {
      $0.accessibilityIdentifier == "terminal.status.details"
    })
    let frame = statusButton.convert(statusButton.bounds, to: window)
    XCTAssertGreaterThanOrEqual(frame.width, 44)
    XCTAssertEqual(frame.height, 44)
    let statusHit = try XCTUnwrap(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil))
    XCTAssertTrue(statusHit.isDescendant(of: statusButton),
                  "Status tap hit \(type(of: statusHit)), button \(frame), safe insets \(window.safeAreaInsets)")
    let terminalHit = try XCTUnwrap(window.hitTest(CGPoint(x: frame.midX, y: frame.maxY + 8), with: nil))
    XCTAssertTrue(terminalHit.isDescendant(of: web), "The row below the status button must accept terminal taps")
    let keys = terminal.typingKeyboard.surface
    let keyFrame = keys.convert(keys.bounds, to: window)
    XCTAssertEqual(keyFrame.maxY, window.bounds.maxY, accuracy: pixel)
    let bottomEdges = try await keys.evaluateJavaScript("""
      ['{lang}', '{space}', '{enter}'].map(k => keyboard.getButtonElement(k).getBoundingClientRect().bottom)
      """) as? [Double]
    let edges = try XCTUnwrap(bottomEdges)
    XCTAssertEqual(edges.count, 3)
    for edge in edges {
      let point = keys.convert(CGPoint(x: keys.bounds.midX, y: CGFloat(edge)), to: window)
      XCTAssertEqual(point.y, window.bounds.maxY, accuracy: pixel)
    }
    XCTAssertEqual(viewport.convert(viewport.bounds, to: window).maxY,
                   terminal.shortcutBar.convert(terminal.shortcutBar.bounds, to: window).minY, accuracy: 1)
    hide.sendActions(for: .touchUpInside)
    _ = try await sampleGrid()
    let sizes = try await web.evaluateJavaScript("keyboardSizes")
    let events = try XCTUnwrap(sizes as? [[Int]])
    XCTAssertTrue(events.isEmpty, "Keyboard toggles resized the terminal grid: \(events)")
    if let before {
      let after = try await fixtureReply(key: ">", marker: "TL-PTY>").suffix
      XCTAssertEqual(after, before, "Keyboard visibility changed the remote tmux pane SIGWINCH count or size")
      print("Keyboard open/close cycles:", 6, "grid resizes:", events.count,
            "remote SIGWINCH,cols,rows:", before, "→", after)
    }
    let restored = try await web.evaluateJavaScript("[term.cols, term.rows]") as? [Int]
    XCTAssertEqual(restored, full)
    XCTAssertEqual(web.bounds.size, canvas)
  }

  @MainActor
  func testNamedSessionsAndEscapeButton() async throws {
    let config = try configuration()
    let client: ClientProfile
    if let link = config.importLink {
      let suite = "dev.tmuxlink.e2e." + UUID().uuidString
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let store = ProfileStore(defaults)
      let draft = try ClientTransfer.parse(link)
      XCTAssertEqual(draft.name, "Clipboard-E2E")
      XCTAssertEqual(draft.relayHost, ClientProfile(host: config.host).relayHost)
      XCTAssertEqual(draft.port, config.port)
      XCTAssertEqual(draft.user, config.user)
      XCTAssertEqual(draft.route, config.route ?? "primary")
      XCTAssertEqual(draft.pin, config.fingerprint)
      XCTAssertEqual(draft.requireMTLS, true)
      XCTAssertNil(draft.importedIdentity)
      XCTAssertTrue(draft.valid)
      XCTAssertTrue(store.clients.isEmpty)
      store.save(draft)
      let saved = try XCTUnwrap(ProfileStore(defaults).clients.first)
      XCTAssertEqual(saved, draft)
      XCTAssertNotNil(try RelayIdentity.resolve(saved))
      client = saved
    } else {
      // Device fixtures created by earlier releases can still run the session tests.
      client = ClientProfile(
        name: "Test", host: config.host, port: config.port, route: config.route ?? "primary",
        user: config.user, pin: config.fingerprint)
    }
    let sessions = try await SessionDirectory.fetch(client)
    let root = try XCTUnwrap(rootController)
    let window = try XCTUnwrap(root.view.window)
    defer { window.rootViewController = root }
    let suffixes = config.hasHistoryFixture == true ? ["-messages", "-other", ""] : ["-other", ""]
    for suffix in suffixes {
      let selected = try XCTUnwrap(sessions.first { $0.name == config.sessionName + suffix })
      let previousActivities = Set(Activity<TerminalActivity>.activities.map(\.id))
      let status = TerminalNavigationStatus()
      let host = UIHostingController(rootView: NavigationStack {
        TerminalView(client: client, session: selected, status: status)
      })
      // Match the app's root NavigationStack without racing a previous modal dismissal.
      window.rootViewController = host
      host.view.layoutIfNeeded()
      for _ in 0..<50 {
        if descendants(host.view).contains(where: { $0 is WKWebView }) { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      let web = try XCTUnwrap(descendants(host.view).compactMap { $0 as? WKWebView }.first)
      let screen = try XCTUnwrap(
        sequence(first: web as UIResponder, next: { $0.next }).compactMap { $0 as? Screen }.first)
      defer { screen.stop() }
      let escape = try XCTUnwrap(
        descendants(screen.view).first { $0.accessibilityIdentifier == "terminal.key.Esc" }
          as? UIButton)
      let panel = try XCTUnwrap(descendants(screen.view).first {
        $0.accessibilityIdentifier == "terminal.shortcuts"
      } as? UIScrollView)
      let reveal = try XCTUnwrap(descendants(screen.view).first {
        $0.accessibilityIdentifier == "terminal.shortcuts.open"
      } as? UIButton)
      let dismiss = try XCTUnwrap(descendants(screen.view).first {
        $0.accessibilityIdentifier == "terminal.shortcuts.close"
      } as? UIButton)
      XCTAssertTrue(panel.isHidden)
      XCTAssertTrue(dismiss.isHidden)
      @MainActor func toggle(_ button: UIButton) async throws {
        button.sendActions(for: .touchUpInside)
        let closing = button === dismiss
        for _ in 0..<50 {
          if panel.isHidden == closing && panel.layer.animationKeys()?.isEmpty != false { break }
          try await Task.sleep(nanoseconds: 20_000_000)
        }
        host.view.layoutIfNeeded()
      }
      func waitFor(_ marker: String) async throws {
        for _ in 0..<100 {
          let value = try? await web.evaluateJavaScript(
            "Array.from({length:term.rows}, (_,i)=>term.buffer.active.getLine(term.buffer.active.viewportY+i)?.translateToString(true)).join('\\n')"
          )
          if let output = value as? String, output.contains(marker) { return }
          try await Task.sleep(nanoseconds: 150_000_000)
        }
        print("Missing terminal marker", marker, "in fixture", suffix)
        throw NSError(
          domain: "TerminalTest", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Missing terminal output " + marker])
      }
      // Wait for the actual PTY, then verify the shell belongs to the chosen tmux session.
      for _ in 0..<100 where !escape.isEnabled {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      let connection = try XCTUnwrap(
        descendants(screen.view).first { $0.accessibilityIdentifier == "terminal.connection" }
          as? UILabel)
      XCTAssertEqual(connection.text, "●  已连接")
      if suffix == "-messages" {
        // The real fullscreen viewer was already on its last page before attach.
        try await waitFor("Message 200")
        let tracking = try await web.evaluateJavaScript("term.modes.mouseTrackingMode")
        XCTAssertNotEqual(tracking as? String, "none")
        for _ in 0..<2 {
          _ = try await web.evaluateJavaScript("scrollRemote(0.5, 0.4, 8, true)")
        }
        try await waitFor("Message 140")
        for _ in 0..<2 {
          _ = try await web.evaluateJavaScript("scrollRemote(0.5, 0.4, -8, true)")
        }
        try await waitFor("Message 200")
        try await verifyKeyboardLayout(web)
        continue
      }
      if suffix.isEmpty {
        let latency = try XCTUnwrap(
          descendants(screen.view).first { $0.accessibilityIdentifier == "terminal.latency" }
            as? UILabel)
        for _ in 0..<100 where latency.text?.contains(" ms") != true {
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(latency.text?.contains(" ms") == true, "Expected a live SSH round trip")
        host.view.layoutIfNeeded()
        XCTAssertFalse(descendants(host.view).contains { $0 is UINavigationBar && !$0.isHidden })
        XCTAssertNotNil(descendants(screen.view).first { $0.accessibilityIdentifier == "terminal.leave" })
        let viewport = try XCTUnwrap(web.superview)
        let terminalFrame = viewport.convert(viewport.bounds, to: host.view)
        let display = host.view.convert(window.bounds, from: window)
        let measurement = try await web.evaluateJavaScript("""
          (() => {
            const area = document.querySelector('#term').getBoundingClientRect();
            const screen = document.querySelector('.xterm-screen').getBoundingClientRect();
            return [term.cols, term.rows, screen.left - area.left, screen.top - area.top,
                    screen.width, screen.height];
          })()
          """)
        let grid = try XCTUnwrap(measurement as? [Double])
        XCTAssertEqual(grid.count, 6)
        if grid.count == 6 {
          let drawn = web.convert(CGRect(x: grid[2], y: grid[3], width: grid[4], height: grid[5]), to: host.view)
          let pixel = 1 / host.traitCollection.displayScale
          XCTAssertEqual(drawn.minX, host.view.safeAreaLayoutGuide.layoutFrame.minX, accuracy: pixel)
          XCTAssertEqual(drawn.maxX, host.view.safeAreaLayoutGuide.layoutFrame.maxX, accuracy: pixel)
          XCTAssertEqual(drawn.minY, display.minY, accuracy: pixel)
          XCTAssertEqual(drawn.maxY, display.maxY, accuracy: pixel)
          print("Terminal grid: \(Int(grid[0])) columns × \(Int(grid[1])) rows")
        }
        XCTAssertEqual(terminalFrame.minY, display.minY, accuracy: 1)
        XCTAssertEqual(terminalFrame.maxY, display.maxY, accuracy: 1)
        try await toggle(reveal)
        XCTAssertFalse(panel.isHidden)
        XCTAssertFalse(dismiss.isHidden)
        let panelFrame = panel.convert(panel.bounds, to: host.view)
        XCTAssertEqual(panelFrame.maxX, terminalFrame.maxX, accuracy: 1)
        XCTAssertTrue(terminalFrame.insetBy(dx: -1, dy: -1).contains(panelFrame))
        let keys = descendants(panel).compactMap { $0 as? UIButton }.sorted { a, b in
          a.convert(a.bounds, to: panel).minY < b.convert(b.bounds, to: panel).minY
        }
        XCTAssertEqual(keys.compactMap { $0.configuration?.title },
                       ["Esc", "PgUp", "PgDn", "Tab", "⌃C", "⌃B", "↑", "↓", "←", "→", "↵"])
        for key in keys {
          XCTAssertGreaterThanOrEqual(key.bounds.height, 44)
          XCTAssertEqual(key.convert(key.bounds, to: panel).midX, panel.bounds.midX, accuracy: 1)
        }
        let size = try await web.evaluateJavaScript("[term.cols, term.rows]") as? [Double]
        XCTAssertEqual(size, Array(grid.prefix(2)))
        XCTAssertEqual(viewport.convert(viewport.bounds, to: host.view), terminalFrame)
        try await toggle(dismiss)
        XCTAssertTrue(panel.isHidden)
        XCTAssertTrue(dismiss.isHidden)
        let sizeAfterClose = try await web.evaluateJavaScript("[term.cols, term.rows]") as? [Double]
        XCTAssertEqual(sizeAfterClose, size)
        XCTAssertEqual(viewport.convert(viewport.bounds, to: host.view), terminalFrame)
        XCTAssertFalse(descendants(screen.view).contains {
          $0.accessibilityIdentifier == "terminal.status.details"
        }, "A compact connection indicator still occupies terminal or keyboard space")
        XCTAssertTrue(connection.superview?.isHidden == true)
        let reading = try XCTUnwrap(status.reading)
        XCTAssertEqual(reading.phase, .ready)
        XCTAssertNotNil(reading.milliseconds)
        if let activity = Activity<TerminalActivity>.activities.first(where: {
          !previousActivities.contains($0.id) && $0.activityState == .active
        }) {
          for _ in 0..<30 where activity.content.state.phase != .ready {
            try await Task.sleep(nanoseconds: 100_000_000)
          }
          XCTAssertEqual(activity.content.state.phase, .ready)
        }
      }
      func type(_ command: String) async throws {
        let sent: Bool = try await withCheckedThrowingContinuation { continuation in
          web.callAsyncJavaScript(
            "term.input(command, true); return true", arguments: ["command": command + "\r"],
            in: nil, in: .page
          ) { result in
            continuation.resume(with: result.map { $0 as? Bool == true })
          }
        }
        XCTAssertTrue(sent)
      }
      if suffix == "-other", config.hasHistoryFixture == true {
        try await waitFor("status-file-150")
        // These files scrolled out before the phone attached. Drag directly
        // from the live shell without opening the drawer or sending a prefix.
        let board = try XCTUnwrap(web as? TerminalWebView)
        _ = try await web.evaluateJavaScript("bridge.postMessage({showKeyboard:true});true")
        for _ in 0..<50 where board.typingKeyboard.isHidden { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(board.typingKeyboard.isHidden)
        if selected.touchPaging == true {
          try await type("tmux set-option prefix C-a && git status && printf '__GIT_%s__\\n' READY")
          try await waitFor("__GIT_READY__")
          try await waitFor("status-file-150")
        }
        let rowValue = try await web.evaluateJavaScript("term.rows") as? Int
        let rows = try XCTUnwrap(rowValue)
        let earlier = String(format: "status-file-%03d", 150 - rows)
        _ = try await web.evaluateJavaScript("scrollRemote(0.5, 0.4, 6, true)")
        try await waitFor(earlier)
        _ = try await web.evaluateJavaScript("scrollRemote(0.5, 0.4, -6, true)")
        try await waitFor("status-file-150")
        if selected.touchPaging != true { _ = try await web.evaluateJavaScript("term.input('q', true)") }
        try await type("printf '__AFTER_%s__\\n' SCROLL")
        try await waitFor("__AFTER_SCROLL__")
        print("Verified git status scrollback with", selected.touchPaging == true ? "agent paging" : "legacy paging")
        board.shortcutBar.hideKeyboard?()
      }
      try await type("printf '__ID_%s__\\n' \"$(tmux display-message -p '#{session_id}')\"")
      try await waitFor("__ID_$" + String(selected.id) + "__")
      if suffix.isEmpty {
        // Shell echo confirms editing takes place in the existing PTY line before Return.
        _ = try await web.evaluateJavaScript(#"term.input('echo old draft', true); true"#)
        try await waitFor("echo old draft")
        let selectedInput = try await web.evaluateJavaScript("""
          (() => {
            const box = document.querySelector('.xterm-screen').getBoundingClientRect();
            const b = term.buffer.active;
            const y = box.top + (b.baseY + b.cursorY - b.viewportY + 0.5) * box.height / term.rows;
            selectTerminalInput(box.left + 2, y);
            return term.getSelection();
          })()
          """)
        XCTAssertEqual(selectedInput as? String, "echo old draft")
        _ = try await web.evaluateJavaScript(#"pasteTerminal("printf '__EDIT_%s__' INLINE"); true"#)
        try await waitFor("printf '__EDIT_%s__' INLINE")
        _ = try await web.evaluateJavaScript(#"term.input('\r', true); true"#)
        try await waitFor("__EDIT_INLINE__")
        try await type(
          "saved=$(stty -g); stty raw -echo; printf '__REA%s__\\r\\n' DY; "
            + "b=$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d '[:space:]'); "
            + "stty \"$saved\"; printf '__BYTE_%s__\\n' \"$b\""
        )
        try await waitFor("__READY__")
        try await toggle(reveal)
        escape.sendActions(for: .touchUpInside)
        try await waitFor("__BYTE_27__")
        try await toggle(dismiss)
        let bar = try XCTUnwrap((web as? TerminalWebView)?.shortcutBar)
        try await type(
          "saved=$(stty -g); stty raw -echo; printf '__BAR_%s__\\r\\n' READY; "
            + "b=$(dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -d '[:space:]'); "
            + "stty \"$saved\"; printf '__BAR_%s__\\n' \"$b\""
        )
        try await waitFor("__BAR_READY__")
        for label in ["Esc", "Tab", "⌃C"] {
          let button = try XCTUnwrap(descendants(bar).first {
            $0.accessibilityIdentifier == "terminal.keyboard." + label
          } as? UIButton)
          XCTAssertTrue(button.isEnabled)
          button.sendActions(for: .touchUpInside)
        }
        try await waitFor("__BAR_1b0903__")
        try await type(
          "saved=$(stty -g); stty raw -echo; printf '__IME_%s__\\r\\n' READY; "
            + "b=$(dd bs=1 count=13 2>/dev/null | od -An -tx1 | tr -d '[:space:]'); "
            + "stty \"$saved\"; printf '__IME_%s__\\n' \"$b\""
        )
        try await waitFor("__IME_READY__")
        let terminal = try XCTUnwrap(web as? TerminalWebView)
        let board = terminal.typingKeyboard.surface
        func showKeyboard() async throws {
          _ = try await web.evaluateJavaScript("bridge.postMessage({showKeyboard:true});true")
          for _ in 0..<50 where terminal.typingKeyboard.isHidden {
            try await Task.sleep(nanoseconds: 20_000_000)
          }
          XCTAssertFalse(terminal.typingKeyboard.isHidden)
        }
        try await showKeyboard()
        _ = try await board.evaluateJavaScript("""
          window.tapKey = k => keyboard.handleButtonClicked(k);
          tapKey('x'); tapKey('{lang}');
          for (const c of 'nihaoz') tapKey(c);
          tapKey('{bksp}'); true
          """)
        bar.hideKeyboard?()
        XCTAssertTrue(terminal.typingKeyboard.isHidden)
        try await showKeyboard()
        let resumed = try await board.evaluateJavaScript("[language, spelling.textContent]") as? [String]
        XCTAssertEqual(resumed, ["zh", "nihao"])
        let didRepeat = try await board.callAsyncJavaScript(#"""
          document.querySelector('#candidates button').click();
          for (const c of 'git') tapKey(c);
          tapKey('{lang}'); tapKey('{space}'); tapKey('{lang}');
          tapKey('n'); tapKey('i');
          const del = keyboard.getButtonElement('{bksp}');
          const pointer = type => del.dispatchEvent(new PointerEvent(type, {
            bubbles:true, pointerType:'touch', pointerId:1, isPrimary:true
          }));
          pointer('pointerdown');
          await new Promise(done => setTimeout(done, 1000));
          pointer('pointerup');
          const repeated = !hasDraft();
          pointer('pointerdown'); pointer('pointerup'); tapKey('.');
          return repeated;
          """#, arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(didRepeat, true)
        try await waitFor("__IME_78e4bda0e5a5bd676974207f2e__")
      }
    }
  }

  @MainActor
  private final class RenderReceipt: NSObject, WKScriptMessageHandler {
    private var expected = ""
    private var pending: XCTestExpectation?
    private(set) var arrival: TimeInterval = 0

    func expect(_ marker: String) -> XCTestExpectation {
      expected = marker
      let event = XCTestExpectation(description: "Remote fixture rendered its reply")
      pending = event
      return event
    }

    func isPending(_ event: XCTestExpectation) -> Bool { pending === event }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.frameInfo.isMainFrame, let marker = message.body as? String,
            marker == expected, let event = pending else { return }
      arrival = ProcessInfo.processInfo.systemUptime
      pending = nil
      event.fulfill()
    }
  }

  @MainActor
  func testTerminalPerformanceBaseline() async throws {
    let config = try configuration()
    guard let id = config.benchmarkSessionID else { throw XCTSkip("No isolated latency fixture configured") }
    let client: ClientProfile
    if let link = config.importLink { client = try ClientTransfer.parse(link) }
    else {
      client = ClientProfile(name: "Benchmark", host: config.host, port: config.port,
                             route: config.route ?? "", user: config.user, pin: config.fingerprint)
    }
    // Connecting by the fixture's known ID avoids warming SSH by fetching the directory.
    let session = RemoteSession(id: id, name: config.sessionName + "-latency")
    let window = try XCTUnwrap(appWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let open = ProcessInfo.processInfo.systemUptime
    let status = TerminalNavigationStatus()
    let host = UIHostingController(rootView: NavigationStack {
      TerminalView(client: client, session: session, status: status)
    })
    window.rootViewController = host
    host.view.layoutIfNeeded()
    let until = open + 30
    var terminal: TerminalWebView?
    repeat {
      terminal = descendants(host.view).compactMap { $0 as? TerminalWebView }.first
      if terminal != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ProcessInfo.processInfo.systemUptime < until
    let web = try XCTUnwrap(terminal)
    let receipt = RenderReceipt()
    let bridge = web.configuration.userContentController
    bridge.add(receipt, name: "benchmarkRender")
    defer { bridge.removeScriptMessageHandler(forName: "benchmarkRender") }

    let first = receipt.expect("TL-READY")
    // Listen on xterm's renderer in the actual app view. Only test markers leave JS.
    // WebKit exposes the #term DOM element by name before the terminal scripts finish loading.
    while (try? await web.evaluateJavaScript("typeof window.display === 'function' && typeof term.onRender === 'function'")) as? Bool != true {
      guard ProcessInfo.processInfo.systemUptime < until else { return XCTFail("Terminal page did not load") }
      try await Task.sleep(for: .milliseconds(10))
    }
    _ = try await web.callAsyncJavaScript(#"""
      await ready;
      let lastReply, sentReady = false;
      function report() {
        const b = term.buffer.active;
        for (let i = 0; i < term.rows; i++) {
          const row = b.getLine(b.viewportY + i)?.translateToString(true).trim();
          if (row === 'TL-READY' && !sentReady) sentReady = true;
          else if (row && /^TL-(WARM|\d{3}-[a-y])$/.test(row) && row !== lastReply) lastReply = row;
          else continue;
          window.webkit.messageHandlers.benchmarkRender.postMessage(row);
        }
      }
      term.onRender(report);
      requestAnimationFrame(report);
      return true;
      """#, arguments: [:], in: nil, contentWorld: .page)
    var coldMs: Double?
    var warmupAttempts = 0
    var warmupMs: Double?
    var samples: [Double] = []
    var timeouts = 0
    let sampleCount = 100
    var phase = "coldOpen"
    defer {
      let ordered = samples.sorted()
      func percentile(_ fraction: Double) -> Double? {
        guard !ordered.isEmpty else { return nil }
        return ordered[Int(ceil(Double(ordered.count) * fraction)) - 1]
      }
      var report: [String: Any] = [
        "phase": phase, "requested": sampleCount, "completed": samples.count,
        "warmSamplesMs": samples, "timeouts": timeouts, "warmupAttempts": warmupAttempts
      ]
      report["openToFirstRenderMs"] = coldMs
      report["warmupMs"] = warmupMs
      report["warmP50Ms"] = percentile(0.5)
      report["warmP95Ms"] = percentile(0.95)
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "terminal-performance.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("TMUX_LINK_PERF", String(decoding: data, as: UTF8.self))
      }
    }
    guard await XCTWaiter.fulfillment(of: [first], timeout: max(0.1, until - ProcessInfo.processInfo.systemUptime)) == .completed
    else {
      timeouts += 1
      return XCTFail("Cold-open remote marker timed out; phase = \(status.reading?.phase.rawValue ?? "unavailable")")
    }
    coldMs = (receipt.arrival - open) * 1000
    phase = "warmup"
    let board = web.typingKeyboard.surface
    let keyboardDeadline = ProcessInfo.processInfo.systemUptime + 5
    while true {
      let loaded = (try? await board.evaluateJavaScript("typeof keyboard === 'object'")) as? Bool
      if loaded == true && web.typingKeyboard.isUserInteractionEnabled { break }
      guard ProcessInfo.processInfo.systemUptime < keyboardDeadline else { return XCTFail("Keyboard did not become ready") }
      try await Task.sleep(for: .milliseconds(20))
    }
    _ = try await web.evaluateJavaScript("bridge.postMessage({showKeyboard:true});true")
    while web.typingKeyboard.isHidden {
      guard ProcessInfo.processInfo.systemUptime < keyboardDeadline else { return XCTFail("Keyboard did not open") }
      try await Task.sleep(for: .milliseconds(20))
    }
    func press(_ key: String) async throws {
      _ = try await board.callAsyncJavaScript("keyboard.handleButtonClicked(key); return true",
                                              arguments: ["key": key], in: nil, contentWorld: .page)
    }

    // The first key crosses two just-opened WebKit views. The fixture accepts z to reset
    // its sequence before sampling. Keep listening for the first reply across the retry.
    let warm = receipt.expect("TL-WARM")
    let warmStart = ProcessInfo.processInfo.systemUptime
    warmupAttempts = 1
    try await press("z")
    while receipt.isPending(warm) {
      let elapsed = ProcessInfo.processInfo.systemUptime - warmStart
      if elapsed >= 20 { break }
      if elapsed >= 10 && warmupAttempts == 1 {
        warmupAttempts += 1
        try await press("z")
      } else {
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    guard !receipt.isPending(warm), receipt.arrival - warmStart <= 20 else {
      timeouts += 1
      return XCTFail("No remote warm-up echo within 20 s (\(warmupAttempts) fixture probes)")
    }
    warmupMs = (receipt.arrival - warmStart) * 1000

    // Every numbered sample dispatches a single key and requires its matching remote render.
    func tap(_ key: String, expect marker: String) async throws -> Double? {
      let event = receipt.expect(marker)
      let start = ProcessInfo.processInfo.systemUptime
      try await press(key)
      guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else { return nil }
      return (receipt.arrival - start) * 1000
    }
    let keys = Array("abcdefghijklmnopqrstuvwxy")
    phase = "typing"
    for n in 1...sampleCount {
      let key = String(keys[(n - 1) % keys.count])
      guard let ms = try await tap(key, expect: String(format: "TL-%03d-", n) + key) else {
        timeouts += 1; return XCTFail("Missing remote render at sample \(n)")
      }
      samples.append(ms)
    }
    phase = "keyboardLayout"
    web.shortcutBar.hideKeyboard?()
    try await verifyKeyboardLayout(web, checkRemoteCursor: true)
    phase = "complete"
  }

  func testCommandAndReconnect() throws {
    let config = try configuration()
    try roundtrip(
      config,
      command: "export TMUX_LINK_PHONE_E2E=retained; printf '__PHONE_%s__\\n' ROUNDTRIP",
      expected: "__PHONE_ROUNDTRIP__")
    try roundtrip(
      config,
      command: "printf '__RESUME_%s__\\n' \"$TMUX_LINK_PHONE_E2E\"",
      expected: "__RESUME_retained__")
  }
}
