import ActivityKit
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
      if !sent && (screen.contains("\u{1b}[?1049h") || screen.contains(config.sessionName)) {
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

  @MainActor
  func testWorkspaceIsVisible() {
    XCTAssertNotNil(rootController as? UIHostingController<Workspace>)
  }

  @MainActor private var rootController: UIViewController? {
    UIApplication.shared.connectedScenes.compactMap {
      ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.rootViewController
    }.first
  }

  @MainActor
  func testBundledTerminalUnicodeCellWidths() async throws {
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
    defer { controller.dismiss(animated: false) }
    let index = try XCTUnwrap(
      Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets"))
    web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    await fulfillment(of: [bridge.loaded], timeout: 10)

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
  }

  @MainActor
  func testNamedSessionsAndEscapeButton() async throws {
    let config = try configuration()
    let client = ClientProfile(
      name: "Test", host: config.host, port: config.port, route: "primary",
      user: config.user, pin: config.fingerprint)
    let sessions = try await SessionDirectory.fetch(client)
    let root = try XCTUnwrap(rootController)
    for suffix in ["-other", ""] {
      let selected = try XCTUnwrap(sessions.first { $0.name == config.sessionName + suffix })
      let previousActivities = Set(Activity<TerminalActivity>.activities.map(\.id))
      let status = TerminalNavigationStatus()
      let host = UIHostingController(rootView: NavigationStack {
        TerminalView(client: client, session: selected, status: status)
      })
      host.modalPresentationStyle = .fullScreen
      root.present(host, animated: false)
      defer { host.dismiss(animated: false) }
      func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
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
      for _ in 0..<100 where escape.superview?.isUserInteractionEnabled == false {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      let connection = try XCTUnwrap(
        descendants(screen.view).first { $0.accessibilityIdentifier == "terminal.connection" }
          as? UILabel)
      XCTAssertEqual(connection.text, "●  已连接")
      if suffix.isEmpty {
        let latency = try XCTUnwrap(
          descendants(screen.view).first { $0.accessibilityIdentifier == "terminal.latency" }
            as? UILabel)
        for _ in 0..<100 where latency.text?.contains(" ms") != true {
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(latency.text?.contains(" ms") == true, "Expected a live SSH round trip")
        host.view.layoutIfNeeded()
        let navigation = try XCTUnwrap(
          descendants(host.view).compactMap { $0 as? UINavigationBar }.first { !$0.isHidden })
        let item = try XCTUnwrap(navigation.topItem)
        let terminalFrame = web.convert(web.bounds, to: host.view)
        XCTAssertLessThanOrEqual(
          navigation.convert(navigation.bounds, to: host.view).maxY, terminalFrame.minY + 1)
        XCTAssertLessThanOrEqual(
          terminalFrame.maxY, escape.convert(escape.bounds, to: host.view).minY + 1)
        XCTAssertFalse(descendants(screen.view).contains {
          $0.accessibilityIdentifier == "terminal.status.details"
        }, "A compact connection indicator still occupies terminal or keyboard space")
        let trailing = (item.rightBarButtonItems ?? [])
          + item.trailingItemGroups.flatMap(\.barButtonItems)
        let activity = Activity<TerminalActivity>.activities.first {
          !previousActivities.contains($0.id) && $0.activityState == .active
        }
        if let activity {
          XCTAssertTrue(connection.superview?.isHidden == true)
          XCTAssertEqual(activity.content.state.phase, .ready)
          let reading = try XCTUnwrap(status.reading)
          XCTAssertEqual(reading.phase, .ready)
          XCTAssertNotNil(reading.milliseconds)
          XCTAssertEqual("RTT " + reading.latencyText, latency.text)
          XCTAssertFalse(trailing.isEmpty, "The measured RTT needs a trailing navigation item")
        } else {
          XCTAssertNil(status.reading)
          XCTAssertFalse(connection.superview?.isHidden == true)
          XCTAssertTrue(trailing.isEmpty, "The inline fallback must not duplicate its status")
          XCTAssertLessThanOrEqual(
            latency.convert(latency.bounds, to: host.view).maxY, terminalFrame.minY + 1)
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
      try await type("printf '__ID_%s__\\n' \"$(tmux display-message -p '#{session_id}')\"")
      try await waitFor("__ID_$" + String(selected.id) + "__")
      if suffix.isEmpty {
        try await type(
          "python3 -c 'import os,tty,termios; t=termios.tcgetattr(0); tty.setraw(0); print(\"__READ\"+\"Y__\",flush=True); b=os.read(0,1); termios.tcsetattr(0,termios.TCSANOW,t); print(\"__BYTE_%d__\"%b[0],flush=True)'"
        )
        try await waitFor("__READY__")
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
    // Populate the normal app form only after the live transport has passed.
    for (key, value) in [
      "公网中心地址": config.host, "端口": String(config.port),
      "远程用户名": config.user, "内网 SSH 主机指纹 SHA256:…": config.fingerprint,
    ] {
      UserDefaults.standard.set(value, forKey: key)
    }
  }
}
