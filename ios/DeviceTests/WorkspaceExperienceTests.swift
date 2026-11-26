import XCTest
@testable import TmuxLink

@MainActor
final class WorkspaceExperienceTests: XCTestCase {
  func testDirectoryKeepsLastSuccessfulListAndRejectsLateResults() async throws {
    let client = ClientProfile()
    let input = [RemoteSession(id: 10, name: "10", directory: "/work/Router"),
                 RemoteSession(id: 2, name: "2", directory: "/work/app")]
    var request = 0
    let started = expectation(description: "first fetch suspended")
    var first: CheckedContinuation<[RemoteSession], Never>?
    let model = SessionListModel { _ in
      request += 1
      if request == 1 {
        return await withCheckedContinuation { first = $0; started.fulfill() }
      }
      if request == 2 { return input }
      throw URLError(.networkConnectionLost)
    }
    let late = Task { await model.refresh(client) }
    await fulfillment(of: [started], timeout: 2)
    _ = await model.refresh(client)
    first?.resume(returning: [])
    let ignored = await late.value
    XCTAssertNil(ignored)
    XCTAssertEqual(model.sessions.map(\.id), [2, 10])
    XCTAssertEqual(model.matching("ROUTER").map(\.id), [10])
    XCTAssertEqual(model.matching(" 2 ").map(\.id), [2])
    _ = await model.refresh(client)
    XCTAssertNotNil(model.failure)
    XCTAssertEqual(model.sessions.map(\.id), [2, 10])
    XCTAssertFalse(model.loading)
  }

  func testBackgroundCompletionWaitsForForegroundAndUsesOneModelCall() async throws {
    let suite = "background-advice-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let client = ClientProfile()
    let target = ManagedSessionController.Target(clientID: client.id, sessionID: 1, name: "1", instance: "fixture")
    let claim = ManagedClaim(ticket: "0123456789abcdef", mode: .observe, style: .balanced,
                             request: .init(messages: [.init(role: "system", content: "Give a choice."),
                                                       .init(role: "user", content: "Which format?")], max_tokens: 128))
    let began = expectation(description: "model began in foreground")
    let ended = expectation(description: "background time ended")
    let delivered = expectation(description: "original ticket delivered")
    var finishModel: CheckedContinuation<Data, Never>?
    var claims = 0
    var submissions = 0
    var services = ManagedSessionController.Services()
    services.beginModelTime = { _ in .init(rawValue: 123) }
    services.endModelTime = { _ in ended.fulfill() }
    services.access = { AdvisorAccess(provider: .deepSeek, key: "fixture") }
    services.claim = { _, _, _ in claims += 1; return .init(enabled: true, claim: claim) }
    services.model = { _, _ in await withCheckedContinuation { finishModel = $0; began.fulfill() } }
    services.finish = { _, _, _, ticket, data in
      submissions += 1
      XCTAssertEqual(ticket, claim.ticket)
      XCTAssertEqual(data, Data("answer".utf8))
      delivered.fulfill()
    }
    let controller = ManagedSessionController(defaults: defaults, services: services)
    controller.updateClients([client])
    controller.enable(target)
    controller.setActive(true)
    await fulfillment(of: [began], timeout: 2)
    controller.leaveForeground()
    finishModel?.resume(returning: Data("answer".utf8))
    await fulfillment(of: [ended], timeout: 2)
    XCTAssertEqual(submissions, 0)
    controller.setActive(true)
    await fulfillment(of: [delivered], timeout: 2)
    controller.setActive(false)
    XCTAssertEqual(claims, 1)
    XCTAssertEqual(submissions, 1)
  }

  func testSystemExpiryCancelsInFlightAdviceAndEndsBackgroundTimeOnce() async throws {
    let suite = "advice-expiry-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let client = ClientProfile()
    let target = ManagedSessionController.Target(clientID: client.id, sessionID: 1, name: "1", instance: "fixture")
    let claim = ManagedClaim(ticket: "0123456789abcdef", mode: .observe, style: .balanced,
                             request: .init(messages: [], max_tokens: 64))
    let started = expectation(description: "request started")
    let cancelled = expectation(description: "request cancelled")
    var expire: (@MainActor @Sendable () -> Void)?
    var ended = 0
    var services = ManagedSessionController.Services()
    services.beginModelTime = { expire = $0; return .init(rawValue: 321) }
    services.endModelTime = { _ in ended += 1 }
    services.access = { AdvisorAccess(provider: .deepSeek, key: "fixture") }
    services.claim = { _, _, _ in .init(enabled: true, claim: claim) }
    services.model = { _, _ in
      started.fulfill()
      defer { cancelled.fulfill() }
      try await Task.sleep(for: .seconds(30))
      return Data()
    }
    services.finish = { _, _, _, _, _ in XCTFail("Expired work was submitted") }
    let controller = ManagedSessionController(defaults: defaults, services: services)
    controller.updateClients([client])
    controller.enable(target)
    controller.setActive(true)
    await fulfillment(of: [started], timeout: 2)
    controller.leaveForeground()
    try XCTUnwrap(expire)()
    await fulfillment(of: [cancelled], timeout: 2)
    XCTAssertEqual(ended, 1)
  }
}
