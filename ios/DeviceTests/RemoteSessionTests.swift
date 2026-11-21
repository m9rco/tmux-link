import Darwin
import Foundation
import UIKit
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
    let worker = pair[1]
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(view, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(view, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let seed = try Identity.load().rawRepresentation
    let finished = expectation(description: "SSH transport closed")
    let lock = NSLock()
    var transportError: String?
    DispatchQueue.global(qos: .userInitiated).async {
      let error = seed.withUnsafeBytes { bytes in
        tl_connect(
          worker, config.host, config.port, config.user, config.fingerprint,
          bytes.bindMemory(to: UInt8.self).baseAddress!)
      }
      if let error {
        lock.lock()
        transportError = String(cString: error)
        lock.unlock()
        tl_free_error(error)
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
    var buffer = [UInt8](repeating: 0, count: 16384)
    var sent = false
    var selected = false
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      let count = read(view, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else {
        throw NSError(
          domain: "TmuxLinkE2E", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "Terminal closed or timed out before the expected output."
          ])
      }
      received.append(buffer, count: count)
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

  @MainActor
  func testConnectionFormIsVisible() {
    let navigation = UIApplication.shared.connectedScenes.compactMap { scene in
      (scene as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.rootViewController
        as? UINavigationController
    }.first
    XCTAssertTrue(navigation?.topViewController is Connect)
  }

  func testBJCommandAndReconnect() throws {
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
