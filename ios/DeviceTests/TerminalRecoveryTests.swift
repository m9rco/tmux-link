import UIKit
import WebKit
import XCTest

@testable import TmuxLink

extension RemoteSessionTests {
  func testRecoveryRecognizesTheSameTmuxSessionAcrossPaneChanges() {
    let original = RemoteSession(id: 2, name: "before", managedInstance: "10-123-%2-50")
    XCTAssertTrue(Screen.sameSession(original, RemoteSession(id: 2, name: "renamed", managedInstance: "10-123-%8-77")))
    for replacement in [
      RemoteSession(id: 3, name: "before", managedInstance: original.managedInstance),
      RemoteSession(id: 2, name: "before", managedInstance: "20-220-%2-50"),
      RemoteSession(id: 2, name: "before", managedInstance: "malformed"),
      RemoteSession(id: 2, name: "before")
    ] { XCTAssertFalse(Screen.sameSession(original, replacement)) }
  }

  @MainActor
  func testTerminalSurvivesBackgroundAndReattachesAfterDetach() async throws {
    let config = try configuration()
    guard let id = config.agentShortcutFixtureID else { throw XCTSkip("No isolated shell for reconnect") }
    let client = ClientProfile(name: "Reconnect fixture", host: config.host, port: config.port,
                               route: config.route ?? "", user: config.user, pin: config.fingerprint)
    let sessions = try await SessionDirectory.fetch(client)
    let fixture = try XCTUnwrap(sessions.first { $0.id == id && $0.name.hasPrefix("tmux-link-agent-keys-") })
    XCTAssertNotNil(fixture.managedInstance)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.windows.contains(where: \.isKeyWindow) })
    let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
    let previous = window.rootViewController
    let screen = Screen(client: client, session: fixture)
    window.rootViewController = screen
    screen.view.layoutIfNeeded()
    defer { screen.stop(); window.rootViewController = previous }
    func terminal(in view: UIView) -> TerminalWebView? {
      if let result = view as? TerminalWebView { return result }
      for child in view.subviews {
        if let result = terminal(in: child) { return result }
      }
      return nil
    }
    let web = try XCTUnwrap(terminal(in: screen.view))
    func waitFor(_ label: String, _ matches: () async throws -> Bool) async throws {
      let limit = Date().addingTimeInterval(35)
      while Date() < limit {
        if (try? await matches()) == true { return }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      XCTFail("Timed out waiting for " + label)
      throw RelayError("Timed out waiting for " + label)
    }
    func keys(_ text: String) async throws {
      _ = try await web.callAsyncJavaScript("pressTerminalKey(text); return true", arguments: ["text": text],
                                           in: nil, contentWorld: .page)
    }
    func visible() async throws -> String {
      try await web.evaluateJavaScript("decisionScreen().text") as? String ?? ""
    }
    func generation() async throws -> Int {
      let id = try await web.evaluateJavaScript("window.terminalConnectionID") as? Int
      return try XCTUnwrap(id)
    }
    func move(_ event: Notification.Name) {
      NotificationCenter.default.post(name: event, object: scene)
    }

    try await waitFor("first attach") { web.typingKeyboard.isUserInteractionEnabled }
    let before = try await generation()
    move(UIScene.didEnterBackgroundNotification)
    try await Task.sleep(nanoseconds: 250_000_000)
    move(UIScene.didActivateNotification)
    let afterShortSwitch = try await generation()
    XCTAssertEqual(afterShortSwitch, before)

    let mark = "\u{15}TL_RC=$((${TL_RC:-0}+1)); printf 'RC-%s\\n' ARMED"
    if ProcessInfo.processInfo.environment["TMUX_LINK_REAL_APP_SWITCH"] == "1" {
      // The device driver watches RC-ARMED, opens Settings, detaches only
      // this fixture's client, then launches this still-running app again.
      let down = expectation(forNotification: UIScene.didEnterBackgroundNotification, object: scene)
      let up = expectation(forNotification: UIScene.didActivateNotification, object: scene)
      try await keys(mark + "\r")
      await fulfillment(of: [down, up], timeout: 35, enforceOrder: true)
    } else {
      // The simulator suite drives the same lifecycle notifications and tmux
      // detach while retaining a single test-host process.
      try await keys(mark + "; sleep 2; tmux detach-client -s '$\(id)'\r")
      try await waitFor("armed detach") { try await visible().contains("RC-ARMED") }
      move(UIScene.didEnterBackgroundNotification)
      try await Task.sleep(nanoseconds: 3_000_000_000)
      let sleeping = try await generation()
      XCTAssertEqual(sleeping, before, "Do not reopen the transport in the background")
      move(UIScene.didActivateNotification)
    }
    try await waitFor("reattach to the original session") {
      let now = try await generation()
      return web.typingKeyboard.isUserInteractionEnabled && now > before
    }

    // A late reply from the old document must not write to the new stream.
    _ = try await web.callAsyncJavaScript(
      "window.webkit.messageHandlers.terminal.postMessage({connectionID: old, data: 'TL_RC=99\\r'}); return true",
      arguments: ["old": before], in: nil, contentWorld: .page)
    try await keys("printf 'RC-COUNT=%s\\n' \"$TL_RC\"; unset TL_RC\r")
    try await waitFor("same shell, single execution") { try await visible().contains("RC-COUNT=1") }
  }
}
