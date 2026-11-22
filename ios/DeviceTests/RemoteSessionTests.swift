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

  @MainActor private var rootController: UIViewController? {
    UIApplication.shared.connectedScenes.compactMap {
      ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.rootViewController
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
  private func verifyKeyboardLayout(_ web: WKWebView) async throws {
    let initial = try await web.evaluateJavaScript("[term.cols, term.rows]") as? [Int]
    let full = try XCTUnwrap(initial)
    let canvas = web.bounds.size
    _ = try await web.evaluateJavaScript("""
      window.keyboardSizes = [];
      window.watchGrid = term.onResize(({cols, rows}) => keyboardSizes.push([cols, rows]));
      true
      """)
    // Exercise the real keyboard guide and animation in the isolated fullscreen tmux fixture.
    let responder = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    web.superview?.addSubview(responder)
    defer {
      responder.removeFromSuperview()
      web.evaluateJavaScript("watchGrid.dispose(); delete window.watchGrid; delete window.keyboardSizes",
                             completionHandler: nil)
    }
    XCTAssertTrue(responder.becomeFirstResponder())
    try await Task.sleep(nanoseconds: 950_000_000)
    let opening = try await web.evaluateJavaScript("keyboardSizes.splice(0)") as? [[Int]]
    let focused = try await web.evaluateJavaScript("[term.cols, term.rows]") as? [Int]
    let compact = try XCTUnwrap(focused)
    XCTAssertEqual(compact.first, full.first)
    XCTAssertLessThan(try XCTUnwrap(compact.last), try XCTUnwrap(full.last))
    XCTAssertEqual(opening, [compact])
    XCTAssertEqual(web.bounds.size, canvas)
    XCTAssertTrue(responder.resignFirstResponder())
    try await Task.sleep(nanoseconds: 950_000_000)
    let closing = try await web.evaluateJavaScript("keyboardSizes") as? [[Int]]
    let restored = try await web.evaluateJavaScript("[term.cols, term.rows]") as? [Int]
    XCTAssertEqual(closing, [full])
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
    let suffixes = config.hasHistoryFixture == true ? ["-messages", "-other", ""] : ["-other", ""]
    for suffix in suffixes {
      let selected = try XCTUnwrap(sessions.first { $0.name == config.sessionName + suffix })
      let previousActivities = Set(Activity<TerminalActivity>.activities.map(\.id))
      let status = TerminalNavigationStatus()
      let host = UIHostingController(rootView: NavigationStack {
        TerminalView(client: client, session: selected, status: status)
      })
      host.modalPresentationStyle = .fullScreen
      root.present(host, animated: false)
      defer { host.dismiss(animated: false) }
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
        let keyboardTop = screen.view.convert(screen.view.keyboardLayoutGuide.layoutFrame, to: host.view).minY
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
          XCTAssertEqual(drawn.minY, terminalFrame.minY, accuracy: pixel)
          XCTAssertEqual(drawn.maxY, keyboardTop, accuracy: pixel)
          let topInset = try XCTUnwrap(host.view.window).safeAreaInsets.top
          if topInset >= 44 && host.view.bounds.width < host.view.bounds.height {
            XCTAssertEqual(terminalFrame.minY, topInset, accuracy: 1, "Title must share the cutout band")
          }
          print("Terminal grid: \(Int(grid[0])) columns × \(Int(grid[1])) rows")
        }
        XCTAssertEqual(terminalFrame.maxY, keyboardTop, accuracy: 1)
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
        try await waitFor("RECENT-ROW-45")
        try await toggle(reveal)
        for key in ["⌃B", "PgUp"] {
          let button = try XCTUnwrap(descendants(screen.view).first {
            $0.accessibilityIdentifier == "terminal.key." + key
          } as? UIButton)
          button.sendActions(for: .touchUpInside)
        }
        try await waitFor("PAST-ROW-100")
        try await toggle(dismiss)
        // Mouse tracking is off. Drag up toward the latest output, then down toward older rows.
        _ = try await web.evaluateJavaScript("scrollRemote(0.5, 0.4, -4, true)")
        try await waitFor("RECENT-ROW-45")
        _ = try await web.evaluateJavaScript("scrollRemote(0.5, 0.4, 4, true)")
        try await waitFor("PAST-ROW-100")
        _ = try await web.evaluateJavaScript("term.input('q', true)")
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
      }
    }
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
