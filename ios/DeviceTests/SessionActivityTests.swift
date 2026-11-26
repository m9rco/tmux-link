import Foundation
import XCTest

@testable import TmuxLink

final class SessionActivityTests: XCTestCase {
  func testListFollowsForegroundStateWithoutExportingPaneText() async throws {
    let config = try RemoteSessionTests.Connection.load()
    guard let id = config.activityFixtureID, let name = config.activityFixtureName,
          name.hasPrefix("tmux-link-activity-") else { throw XCTSkip("No isolated activity fixture configured") }
    let client = ClientProfile(name: "Activity fixture", host: config.host, port: config.port,
                               route: config.route ?? "", user: config.user, pin: config.fingerprint)
    let initial = try await SessionDirectory.fetch(client)
    let agent = try XCTUnwrap(initial.first { $0.id == id && $0.name == name })
    let shell = try XCTUnwrap(initial.first { $0.name == name + "-idle" })
    XCTAssertEqual(shell.activity, "idle")
    // Only the explicitly provisioned synthetic pane is ever opened for a snapshot.
    // Check the source frame on both sides of list so a redraw cannot race the assertion.
    for (state, marker) in [("running", "TL-SYNTHETIC-PHASE-RUN"), ("waiting", "TL-SYNTHETIC-PHASE-WAIT")] {
      let deadline = ProcessInfo.processInfo.systemUptime + 30
      var witnessed = false
      while ProcessInfo.processInfo.systemUptime < deadline {
        let before = try await SessionDirectory.snapshot(agent, client: client)
        if before.text.contains(marker) {
          let raw = try await TerminalTransport.listData(client)
          let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
          let row = try XCTUnwrap(rows.first { $0["id"] as? Int64 == id && $0["name"] as? String == name })
          let wire = try JSONSerialization.data(withJSONObject: row)
          for fragment in ["TL-SYNTHETIC-PHASE", "Do you want to proceed?", "Press Enter to confirm", "esc to interrupt"] {
            XCTAssertNil(wire.range(of: Data(fragment.utf8)), "List returned fixture screen content")
          }
          XCTAssertTrue(Set(row.keys).isDisjoint(with: ["text", "context", "screen", "history", "applicationContext"]))
          let directory = try JSONDecoder().decode([RemoteSession].self, from: raw)
          let current = try XCTUnwrap(directory.first { $0.id == id && $0.name == name })
          let after = try await SessionDirectory.snapshot(agent, client: client)
          if after.text.contains(marker) {
            XCTAssertEqual(current.activity, state)
            witnessed = true
            break
          }
        }
        try await Task.sleep(for: .milliseconds(450))
      }
      XCTAssertTrue(witnessed, "The synthetic foreground did not remain in the expected \(state) phase")
    }
  }
}
