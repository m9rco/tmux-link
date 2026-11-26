import Foundation
import XCTest

@testable import TmuxLink

final class SessionUploadTests: XCTestCase {
  func testUploadToCurrentDirectoryPreservesBinaryAndRefusesReplacement() async throws {
    let config = try RemoteSessionTests.Connection.load()
    guard let id = config.uploadFixtureID, let name = config.uploadFixtureName,
          name.hasPrefix("tmux-link-upload-") else { throw XCTSkip("No isolated file transfer fixture") }
    let client = ClientProfile(name: "Upload fixture", host: config.host, port: config.port,
                               route: config.route ?? "", user: config.user, pin: config.fingerprint)
    let sessions = try await SessionDirectory.fetch(client)
    let session = try XCTUnwrap(sessions.first { $0.id == id && $0.name == name })
    let remote = try XCTUnwrap(session.directory)
    XCTAssertEqual((remote as NSString).lastPathComponent, name)
    XCTAssertEqual(session.uploadVersion, 1)

    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: folder) }
    let file = folder.appendingPathComponent("会话 upload '数据'.bin")
    let block = Data(0...UInt8.max)
    var contents = Data()
    for _ in 0..<1025 { contents.append(block) }
    try contents.write(to: file)
    let receipt = try await TerminalTransport.upload(client, session: session, file: file)
    XCTAssertEqual(receipt.bytes, UInt64(contents.count))
    XCTAssertEqual(receipt.path, (remote as NSString).appendingPathComponent(file.lastPathComponent))

    try Data("different content".utf8).write(to: file)
    do {
      _ = try await TerminalTransport.upload(client, session: session, file: file)
      XCTFail("Overwrote an existing file")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("同名"), error.localizedDescription)
    }

    let empty = folder.appendingPathComponent("empty.txt")
    try Data().write(to: empty)
    var stale = session
    stale.directory = remote + "/previous-folder"
    do {
      _ = try await TerminalTransport.upload(client, session: stale, file: empty)
      XCTFail("Accepted a directory that no longer matches the pane")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("变化"), error.localizedDescription)
    }
    let emptyReceipt = try await TerminalTransport.upload(client, session: session, file: empty)
    XCTAssertEqual(emptyReceipt.bytes, 0)
    XCTAssertEqual(emptyReceipt.path, (remote as NSString).appendingPathComponent(empty.lastPathComponent))
  }
}
