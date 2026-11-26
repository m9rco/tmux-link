import Foundation
import XCTest
@testable import TmuxLink

final class PersonalDecisionMemoryTests: XCTestCase {
  private let client = UUID()
  private var profile: ClientProfile { .init(id: client, name: "fixture", host: "example.invalid") }
  private var node: String { PersonalDecisionMemory.scope(for: profile) }
  private let question = "Choose an export format"

  private func makeRecord(_ answer: String, draft: Bool = false) -> ManagedStatus.Record {
    .init(at: 10, question: question, choice: draft ? nil : answer, reason: "Unconfirmed model inference",
          outcome: "observed", mode: "observe", style: "cautious", draft: draft ? answer : nil)
  }

  private func makeClaim(_ text: String, options: [String], multiple: Bool = false) throws -> ManagedClaim {
    let json = try JSONSerialization.data(withJSONObject: [
      "question": text, "options": options, "navigation": ["multiple": multiple], "memory": "Node history"
    ])
    return .init(ticket: "0123456789ab1234", mode: .observe, style: .cautious,
                 request: .init(messages: [.init(role: "system", content: "Existing constraints"),
                                           .init(role: "user", content: String(decoding: json, as: UTF8.self))],
                                max_tokens: 270))
  }

  private func preferences(_ claim: ManagedClaim) throws -> [String: Any]? {
    let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(claim.request.messages[1].content.utf8)) as? [String: Any])
    return input["personal_preferences"] as? [String: Any]
  }

  func testFeedbackMatchesOnlyThisClientQuestionAndVisibleAnswer() throws {
    let first = try makeClaim(question, options: ["CSV", "JSON"])
    var memory = PersonalDecisionMemory()
    XCTAssertEqual(memory.personalizing(first, for: node).request.messages[1].content, first.request.messages[1].content)
    let sample = try XCTUnwrap(PersonalDecisionMemory.example(for: makeRecord("CSV"), node: node, vote: .prefer))
    memory.record(sample)
    let new = memory.personalizing(first, for: node)
    let prefs = try XCTUnwrap(preferences(new))
    let votes = try XCTUnwrap(prefs["feedback"] as? [[String: String]])
    XCTAssertEqual(votes, [["vote": "prefer", "answer": "CSV"]])
    XCTAssertEqual(new.ticket, first.ticket)
    XCTAssertEqual(new.mode, first.mode)
    XCTAssertEqual(new.style, first.style)
    XCTAssertEqual(new.request.max_tokens, first.request.max_tokens)
    XCTAssertTrue(new.request.messages[0].content.hasPrefix(first.request.messages[0].content))
    XCTAssertFalse(new.request.messages[1].content.contains("Unconfirmed model inference"))
    var renamed = profile
    renamed.name = "New label"
    XCTAssertEqual(PersonalDecisionMemory.scope(for: renamed), node)
    renamed.pin = "a different SSH host"
    XCTAssertNil(try preferences(memory.personalizing(first, for: PersonalDecisionMemory.scope(for: renamed))))
    XCTAssertNil(try preferences(memory.personalizing(makeClaim(question, options: ["XML"]), for: node)))
    XCTAssertNil(try preferences(memory.personalizing(makeClaim("Share credentials?", options: ["CSV"]), for: node)))
    memory.record(try XCTUnwrap(PersonalDecisionMemory.example(for: makeRecord("CSV"), node: node, vote: .avoid)))
    XCTAssertEqual(memory.examples.map(\.vote), [.avoid])
    memory.examples.removeAll()
    XCTAssertNil(try preferences(memory.personalizing(first, for: node)))
  }

  func testUserPrincipleTransfersAcrossQuestionsAndFeedbackNeedsNoAdditionalModelCall() throws {
    let text = "Verify a small sample first because full runs are expensive."
    var memory = try PersonalDecisionMemory().addingPrinciple(text)
    memory = try memory.addingPrinciple(text)
    let other = try makeClaim("How should we check the new importer?", options: ["Pilot", "Full run"])
    XCTAssertEqual(try preferences(memory.personalizing(other, for: UUID().uuidString))?["principles"] as? String, text)
    memory = try memory.setGuidance("")
    XCTAssertNil(try preferences(memory.personalizing(other, for: node)))
    XCTAssertThrowsError(try memory.setGuidance("token=example-secret-credential"))
    XCTAssertThrowsError(try memory.setGuidance(String(repeating: "x", count: PersonalDecisionMemory.maxGuidanceBytes + 1)))
  }

  func testMultipleSelectionAndDraftRemainGrounded() throws {
    var memory = PersonalDecisionMemory()
    memory.record(try XCTUnwrap(PersonalDecisionMemory.example(for: makeRecord("CSV、JSON"), node: node, vote: .prefer)))
    XCTAssertNotNil(try preferences(memory.personalizing(makeClaim(question, options: ["CSV", "JSON"], multiple: true), for: node)))
    XCTAssertNil(try preferences(memory.personalizing(makeClaim(question, options: ["CSV", "XML"], multiple: true), for: node)))
    memory.record(try XCTUnwrap(PersonalDecisionMemory.example(for: makeRecord("Plain text please", draft: true), node: node, vote: .prefer)))
    XCTAssertNotNil(try preferences(memory.personalizing(makeClaim(question, options: []), for: node)))
    XCTAssertNil(try preferences(memory.personalizing(makeClaim(question, options: ["Plain text please"]), for: node)))
    XCTAssertNil(PersonalDecisionMemory.example(for: makeRecord("Authorization: Bearer secret"), node: node, vote: .avoid))
  }

  @MainActor
  func testControllerSendsConfirmedFeedbackInOneOrdinaryModelCall() async throws {
    let suite = "personal-memory-test-" + UUID().uuidString
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
    let target = ManagedSessionController.Target(clientID: client, sessionID: 4, name: "work", instance: "current")
    let claim = try makeClaim(question, options: ["CSV", "JSON"])
    let receipt = expectation(description: "node receives the original ticket")
    var services = ManagedSessionController.Services()
    var calls = 0
    services.access = { AdvisorAccess(provider: .deepSeek, key: "fixture-only") }
    services.claim = { _, _, _ in .init(enabled: true, claim: claim) }
    services.model = { enriched, _ in
      calls += 1
      let feedback = try self.preferences(enriched)?["feedback"] as? [[String: String]]
      XCTAssertEqual(feedback, [["answer": "JSON", "vote": "prefer"]])
      return Data("receipt".utf8)
    }
    services.finish = { _, _, _, ticket, envelope in
      XCTAssertEqual(ticket, claim.ticket)
      XCTAssertEqual(envelope, Data("receipt".utf8))
      receipt.fulfill()
    }
    let controller = ManagedSessionController(defaults: defaults, services: services, memoryFile: .init(directory: dir))
    try controller.updatePersonalMemory {
      $0.record(try XCTUnwrap(PersonalDecisionMemory.example(for: makeRecord("JSON"), node: node, vote: .prefer)))
    }
    controller.updateClients([profile])
    controller.enable(target)
    controller.setActive(true)
    defer { controller.setActive(false) }
    await fulfillment(of: [receipt], timeout: 4)
    XCTAssertEqual(calls, 1)
  }

  @MainActor
  func testSavedPreferencesSurviveRelaunchAndCanBeRevoked() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = PersonalMemoryFile(directory: dir)
    let controller = ManagedSessionController(memoryFile: file)
    XCTAssertFalse(controller.personalMemoryUnavailable)
    try controller.updatePersonalMemory { memory in
      memory = try memory.addingPrinciple("Prefer a short summary.")
      for index in 0...PersonalDecisionMemory.maxExamples {
        memory.record(try XCTUnwrap(PersonalDecisionMemory.example(for: makeRecord("Answer \(index)"), node: node, vote: .avoid)))
      }
    }
    let restored = ManagedSessionController(memoryFile: file)
    XCTAssertEqual(restored.personalMemory.examples.count, PersonalDecisionMemory.maxExamples)
    XCTAssertFalse(restored.personalMemory.examples.contains { $0.answer == "Answer 0" })
    XCTAssertEqual(restored.personalMemory.guidance, "Prefer a short summary.")
    try restored.updatePersonalMemory { $0 = PersonalDecisionMemory() }
    controller.reloadPersonalMemory()
    XCTAssertEqual(controller.personalMemory, PersonalDecisionMemory())
    let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }
}
