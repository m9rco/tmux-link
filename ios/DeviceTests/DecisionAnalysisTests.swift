import Foundation
import XCTest

@testable import TmuxLink

final class DecisionAnalysisTests: XCTestCase {
  private static let question = "Choose the report format: 1) CSV 2) JSON"
  private static let key = "fixture-header-only"
  private static var example: DecisionSnapshot {
    let progress = (1...125).map { "Building fixture part \($0) (\($0)%)" }
    let history = [
      "Constraint: report must support nested fields.",
      "export API_TOKEN=history-private-123",
      "Which editor should we use?",
      "Decided to use the existing editor.",
    ] + progress + ["Tests passed.", "Completed the first draft."]
    return DecisionSnapshot(id: 37, name: "report", text: "password='screen-private 123'\n" + question,
                            context: history.joined(separator: "\n"))
  }

  func testLocalCompressionRedactsBeforeRankingAndKeepsEarlyConstraint() throws {
    let preview = Self.example.sanitized()
    XCTAssertEqual(preview, preview.sanitized())
    let context = try XCTUnwrap(preview.context)
    XCTAssertLessThanOrEqual(context.utf8.count, DecisionSnapshot.maxContextBytes)
    let lines = context.components(separatedBy: .newlines)
    XCTAssertLessThanOrEqual(lines.count, DecisionSnapshot.maxContextLines)
    XCTAssertEqual(lines.filter { $0.contains("Building fixture") }, ["Building fixture part 125 (125%)"])
    XCTAssertTrue(context.contains("Constraint: report must support nested fields."))
    XCTAssertTrue(context.contains("Decided to use the existing editor."))
    XCTAssertTrue(context.contains("Tests passed."))
    XCTAssertFalse(context.contains("history-private"))
    XCTAssertFalse(preview.text.contains("screen-private"))
    XCTAssertTrue(preview.text.contains(Self.question))
  }

  func testVisibleUnicodeBoundsAndCommonSecrets() throws {
    let secrets = [
      "Authorization: Bearer fixture-header-value",
      #"{"api_key":"fixture-json-value"}"#,
      "curl --password 'fixture-flag value'",
      "https://user:fixture-url-value@sample.invalid/path",
      "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture-key-block\n-----END OPENSSH PRIVATE KEY-----",
      "ghp_fixtureprovider123456789abc",
    ]
    let content = String(repeating: "文", count: 4000) + "\n" + secrets.joined(separator: "\n") + "\n请选格式"
    let snapshot = DecisionSnapshot(id: 1, name: "API_TOKEN=fixture-name-value", text: content, context: "\n  ")
    let preview = snapshot.sanitized()
    XCTAssertLessThanOrEqual(preview.text.utf8.count, DecisionSnapshot.maxScreenBytes)
    XCTAssertFalse(preview.text.contains("fixture"))
    XCTAssertFalse(preview.text.contains("�"))
    XCTAssertFalse(preview.name.contains("fixture"))
    XCTAssertTrue(preview.text.hasSuffix("请选格式"))
    XCTAssertNil(preview.context)
    XCTAssertEqual(preview, preview.sanitized())
  }

  func testSendsExactlyPreviewedFieldsAndParsesActionableOptions() async throws {
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + DecisionAnalysisTests.key)
        let data = try requestBody()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.compactMap { $0["role"] }, ["system", "user"])
        let content = try XCTUnwrap(messages.last?["content"])
        for excluded in ["screen-private", "history-private", DecisionAnalysisTests.key] {
          XCTAssertFalse(content.contains(excluded))
        }
        let sent = try JSONDecoder().decode([DecisionSnapshot].self, from: Data(content.utf8))
        XCTAssertEqual(sent, [DecisionAnalysisTests.example.sanitized()])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(rows.first).keys), ["id", "name", "text", "context"])
        return (200, try completion("""
          {"decisions":[{"session_id":37,"question":"选哪种报告格式？","evidence":"\(DecisionAnalysisTests.question)",
          "options":[{"reply":"1) CSV","tradeoff":"表格工具可以直接打开，但嵌套字段需要平铺。"},
          {"reply":"2) JSON","tradeoff":"能保留嵌套字段。"}],"recommended_index":1,"reason":"历史要求保留嵌套字段。"}]}
          """))
      }
    }
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    let result = try await SessionAdvisor.analyze([Self.example.sanitized()], key: Self.key, session: session)
    let decision = try XCTUnwrap(result.first)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(decision.sessionID, Self.example.id)
    XCTAssertEqual(decision.evidence, Self.question)
    XCTAssertEqual(decision.recommendedIndex, 1)
    XCTAssertEqual(decision.options.map(\.reply), ["1) CSV", "2) JSON"])
    XCTAssertTrue(decision.reason.contains("嵌套"))
  }

  func testOnlyGroundedDistinctChoicesAreAccepted() throws {
    let screen = Self.example.sanitized()
    let csv = DecisionOption(reply: "CSV", tradeoff: "Tabular shape.")
    let json = DecisionOption(reply: "JSON", tradeoff: "Retains nested fields.")
    func decision(id: Int64 = 37, quote: String = DecisionAnalysisTests.question,
                  options: [DecisionOption]? = nil, index: Int? = nil, reason: String = "") -> SessionDecision {
      SessionDecision(sessionID: id, question: "Which format?", evidence: quote, options: options ?? [csv, json],
                      recommendedIndex: index, reason: reason)
    }
    for invalid in [
      [decision(id: -1)], [decision(id: 21)], [decision(), decision()],
      [decision(quote: "Which editor should we use?")], // Appears only in history.
      [decision(quote: "CSV or XML?")], [decision(quote: "")], [decision(quote: " ")],
      [decision(options: [csv])], [decision(options: [csv, csv])],
      [decision(options: [csv, DecisionOption(reply: "JSON", tradeoff: "")])],
      [decision(index: 2, reason: "out of bounds")], [decision(index: 0)],
    ] {
      XCTAssertThrowsError(try SessionAdvisor.validatedDecisions(invalid, screens: [screen])) {
        guard case SessionAdvisorError.invalidResponse = $0 else { return XCTFail("Unexpected validation error") }
      }
    }
    XCTAssertTrue(try SessionAdvisor.validatedDecisions([], screens: [screen]).isEmpty)
    XCTAssertNil(try SessionAdvisor.validatedDecisions([decision()], screens: [screen]).first?.recommendedIndex)

    let quotes = ["Which format?", "Which language?", "Which audience?", "Which timezone?"]
    let multi = DecisionSnapshot(id: 37, name: "report", text: quotes.joined(separator: "\n"))
    let questions = quotes.map { decision(quote: $0) }
    XCTAssertEqual(try SessionAdvisor.validatedDecisions(Array(questions.prefix(3)), screens: [multi]).count, 3)
    XCTAssertThrowsError(try SessionAdvisor.validatedDecisions(questions, screens: [multi]))
  }

  func testBadSelectionsAndEmptyScreensNeverReachNetwork() async throws {
    final class NoRequests: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) { XCTFail("Unexpected network request"); return (500, Data()) }
    }
    let session = NoRequests.session()
    defer { session.invalidateAndCancel() }
    func screen(_ id: Int64) -> DecisionSnapshot { DecisionSnapshot(id: id, name: "test", text: " ") }
    for invalid in [[], [screen(-1)], [screen(1), screen(1)], (0..<7).map { screen(Int64($0)) }] {
      do {
        _ = try await SessionAdvisor.analyze(invalid, key: Self.key, session: session)
        XCTFail("Invalid selection was accepted")
      } catch SessionAdvisorError.invalidDecisionSelection {}
    }
    let empty = try await SessionAdvisor.analyze((0..<6).map { screen(Int64($0)) }, key: Self.key, session: session)
    XCTAssertTrue(empty.isEmpty)
    do {
      let accidental = DecisionSnapshot(id: 1, name: "test", text: "notes \(Self.key)")
      _ = try await SessionAdvisor.analyze([accidental], key: Self.key, session: session)
      XCTFail("API credential was sent as screen data")
    } catch SessionAdvisorError.credentialInSnapshot {}
  }

  func testLiveDecisionsFromSyntheticSSHScreens() async throws {
    #if os(iOS) && !targetEnvironment(simulator)
      struct Enable: Decodable { let enabled: Bool }
      let files = FileManager.default
      let flag = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        .appendingPathComponent("tmux-link-decision-live.json")
      guard files.fileExists(atPath: flag.path) else { throw XCTSkip("No one-time DeepSeek decision test flag.") }
      let data = try Data(contentsOf: flag)
      try files.removeItem(at: flag)
      guard try JSONDecoder().decode(Enable.self, from: data).enabled else { throw XCTSkip("Live check disabled.") }
      let key = try XCTUnwrap(AdvisorCredential.load(), "Set a DeepSeek key in the app before enabling the live test.")
      let labels = ["format", "tests", "idle"]
      let lines = [Self.question, "Which test suite should run: quick or full?", "Build finished successfully."]
      var screens = zip(labels, lines).enumerated().map { idx, item in
        DecisionSnapshot(id: Int64(idx), name: item.0, text: item.1)
      }
      var usedSSH = false
      let configFile = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        .appendingPathComponent("tmux-link-e2e.json")
      if files.fileExists(atPath: configFile.path) {
        let config = try JSONDecoder().decode(RemoteSessionTests.Connection.self, from: Data(contentsOf: configFile))
        if let ids = config.decisionFixtureIDs {
          guard config.sessionName.hasPrefix("tmux-link-device-e2e-"), ids.count == 3, Set(ids).count == 3,
                ids.allSatisfy({ $0 >= 0 }) else { return XCTFail("Invalid synthetic SSH fixture configuration") }
          let client: ClientProfile
          if let link = config.importLink { client = try ClientTransfer.parse(link) }
          else {
            client = ClientProfile(name: "Decision fixture", host: config.host, port: config.port,
                                   route: config.route ?? "", user: config.user, pin: config.fingerprint)
          }
          let directory = try await SessionDirectory.fetch(client)
          screens.removeAll()
          for i in ids.indices {
            let expectedName = config.sessionName + "-" + labels[i]
            let candidate = try XCTUnwrap(directory.first { $0.id == ids[i] && $0.name == expectedName },
                                          "Missing named synthetic SSH fixture")
            let capture = try await SessionDirectory.snapshot(candidate, client: client)
            guard capture.id == ids[i], capture.name == expectedName,
                  capture.text.trimmingCharacters(in: .whitespacesAndNewlines) == lines[i],
                  capture.context?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            else { return XCTFail("Unexpected SSH content. No snapshots were submitted.") }
            screens.append(capture.sanitized())
          }
          usedSSH = true
        }
      }
      let result = try await SessionAdvisor.analyze(screens, key: key)
      XCTAssertEqual(Set(result.map(\.sessionID)), Set(screens.prefix(2).map(\.id)))
      XCTAssertEqual(result.count, 2)
      let checks = [[["csv", "1"], ["json", "2"]], [["quick", "快速"], ["full", "完整", "全量"]]]
      for i in 0..<2 {
        let decision = try XCTUnwrap(result.first { $0.sessionID == screens[i].id })
        XCTAssertTrue(screens[i].text.contains(decision.evidence))
        XCTAssertTrue((2...4).contains(decision.options.count))
        let replies = decision.options.map { $0.reply.lowercased() }
        for aliases in checks[i] {
          XCTAssertTrue(replies.contains { reply in aliases.contains { reply.contains($0) } },
                        "Missing an available fixture option")
        }
      }
      let samples = result.map { value -> [String: Any] in
        ["session": screens.first { $0.id == value.sessionID }?.name ?? "", "question": value.question,
         "evidence": value.evidence, "options": value.options.map { ["reply": $0.reply, "tradeoff": $0.tradeoff] },
         "recommendedIndex": value.recommendedIndex.map { $0 as Any } ?? NSNull(), "reason": value.reason]
      }
      let receipt = try JSONSerialization.data(withJSONObject: ["capturedViaSSH": usedSSH, "decisions": samples],
                                               options: [.prettyPrinted, .sortedKeys])
      let attachment = XCTAttachment(data: receipt, uniformTypeIdentifier: "public.json")
      attachment.name = "decision-analysis-synthetic.json"
      attachment.lifetime = .keepAlways
      add(attachment)
    #else
      throw XCTSkip("This opt-in check uses the app's Keychain on a physical device.")
    #endif
  }
}
