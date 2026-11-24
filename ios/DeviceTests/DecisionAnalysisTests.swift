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

  // Synthetic narrow-screen transcript: a proposed sequence and a single confirmation.
  private static let review = DecisionSnapshot(id: 41, name: "catalog-review", text: """
    当前状态
    原因：上次刷新索引打断了正在校对的批次。
    目标：样本通过数从 2/5 提高到 5/5。
    约束：校对期间不得刷新索引。

    建议的下一步（等你确认）
    1. 在当前版本 a1b2c3d 验证一份样本。
    2. 整理过期标签。
    3. 补充周报模板。

    要先执行第 1
       步（只验证样本，
       保留现有索引）吗？

    │ ▏
    │ Build · Deepseek Flash demo-
    │             writer
    ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
       /example/lab/      89.2K (21%) ctrl+p
       archive                  commands
    """)

  func testConfirmationRetainsReasonGoalAndReferencedStep() throws {
    let brief = Self.review.prepared()
    let blocks = brief.blocks
    XCTAssertEqual(brief, Self.review.prepared())
    let encoder = JSONEncoder()
    XCTAssertLessThan(try encoder.encode(brief).count, try encoder.encode(Self.review).count)
    let current = blocks.filter { $0.source == .current }
    let question = try XCTUnwrap(current.first { $0.kind == .question })
    XCTAssertTrue(question.text.contains("只验证样本"))
    XCTAssertTrue(question.text.contains("保留现有索引"))
    XCTAssertTrue(question.text.contains("吗？"))
    XCTAssertTrue(current.contains { $0.kind == .rationale && $0.text.contains("打断了正在校对的批次") })
    XCTAssertTrue(current.contains { $0.kind == .goal && $0.text.contains("2/5") && $0.text.contains("5/5") })
    XCTAssertTrue(current.contains { $0.kind == .constraint && $0.text.contains("不得刷新索引") })
    XCTAssertTrue(current.contains { $0.kind == .plan && $0.text.contains("a1b2c3d") && $0.text.contains("验证一份样本") })
    XCTAssertFalse(current.contains { $0.kind == .choice })
    let transmitted = blocks.map(\.text).joined(separator: "\n")
    for noise in ["Deepseek Flash", "demo-", "writer", "▄", "│", "▏", "/example", "89.2K", "ctrl+p", "commands", "archive"] {
      XCTAssertFalse(transmitted.contains(noise), "Chrome survived: \(noise)")
    }
  }

  func testUnrelatedPlanActionCanStillCarryARelevantBoundary() {
    let text = Self.review.text.replacingOccurrences(of: "2. 整理过期标签。",
      with: "2. 整理过期标签（其他部门的条目先不动）。")
    let brief = DecisionSnapshot(id: 1, name: "catalog", text: text).prepared()
    XCTAssertTrue(brief.blocks.contains { $0.kind == .constraint && $0.text.contains("其他部门的条目先不动") })
    XCTAssertFalse(brief.blocks.contains { $0.text.contains("整理过期标签") })
  }

  private static let checksMenu = DecisionSnapshot(id: 3, name: "chapters", text: """
    请选择要导出的章节（可多选）
    ❯ [ ] 摘要
      [x] 图表
      [ ] 附录
      提交
    空格切换，回车提交
    """)

  func testExplicitSingleSelectMenuDoesNotInferACheckFromFocus() throws {
    let snapshot = DecisionSnapshot(id: 1, name: "export", text: """
      Choose one export format:
      ❯ 1. CSV
        2. JSON
      Enter to confirm
      """, context: "Which format should be archived?")
    let brief = snapshot.prepared()
    let menu = try XCTUnwrap(brief.menu)
    XCTAssertEqual(menu.mode, .single)
    XCTAssertEqual(menu.items.count, 2)
    XCTAssertTrue(menu.items[0].label.contains("CSV"))
    XCTAssertTrue(menu.items[0].focused)
    XCTAssertNotEqual(menu.items[0].selected, true)
    XCTAssertTrue(menu.items[1].label.contains("JSON"))
    XCTAssertFalse(menu.items[1].focused)
    XCTAssertTrue(try XCTUnwrap(menu.submitHint).contains("Enter"))
    XCTAssertFalse(menu.submitFocused)
    XCTAssertFalse(menu.truncated)
    XCTAssertFalse(brief.blocks.contains { $0.source == .current && $0.text.contains("archived") })
  }

  func testReadOnlyMenusKeepNumericKeysAndSeparateSubmitFromAnswers() throws {
    let middle = """
      Choose one region:
        East
      ❯ West
        North
      ↑↓ navigate · Enter to confirm
      """
    let menu = try XCTUnwrap(TerminalChoiceMenu.detect(in: middle))
    XCTAssertEqual(menu.items.map(\.label), ["East", "West", "North"])
    XCTAssertEqual(menu.items.map(\.focused), [false, true, false])
    XCTAssertTrue(menu.items.allSatisfy { $0.selected == nil })
    XCTAssertNil(TerminalChoiceMenu.detect(in: middle + "\nSubmitted.\nBuild complete."))

    let numbered = try XCTUnwrap(TerminalChoiceMenu.detect(in: "Choose one region:\n❯ 2. East\n  4. West\nEnter to confirm"))
    XCTAssertEqual(numbered.items.map(\.label), ["2. East", "4. West"])
    let wrapped = DecisionSnapshot(id: 1, name: "test", text: """
      Select one or more:
      ❯ [x] Preserve the snapshot
            and its metadata
        [ ] Discard the draft
      Space to toggle · Enter to submit
      """).prepared()
    XCTAssertEqual(wrapped.menu?.items.count, 2)
    XCTAssertEqual(wrapped.menu?.items.first?.label, "Preserve the snapshot\nand its metadata")
    XCTAssertFalse(wrapped.blocks.contains { $0.text.contains("metadata") })
    let submit = try XCTUnwrap(TerminalChoiceMenu.detect(in: "❯ Submit answers\nEnter to submit"))
    XCTAssertTrue(submit.items.isEmpty)
    XCTAssertTrue(submit.submitFocused)
    XCTAssertTrue(try XCTUnwrap(submit.submitHint).contains("Enter"))
  }

  func testMultipleSelectionSeparatesCheckedRowsFocusAndSubmit() throws {
    let brief = Self.checksMenu.prepared()
    let menu = try XCTUnwrap(brief.menu)
    XCTAssertEqual(menu.mode, .multiple)
    XCTAssertEqual(menu.items.map(\.label), ["摘要", "图表", "附录"])
    XCTAssertEqual(menu.items.map(\.selected), [false, true, false])
    XCTAssertEqual(menu.items.map(\.focused), [true, false, false])
    XCTAssertTrue(try XCTUnwrap(menu.selectionHint).contains("空格"))
    XCTAssertTrue(try XCTUnwrap(menu.submitHint).contains("回车"))
    XCTAssertFalse(menu.submitFocused)
    XCTAssertFalse(menu.truncated)

    let submit = DecisionSnapshot(id: 3, name: "chapters", text: """
      Select one or more chapters:
        [x] Introduction
        [ ] References
      ❯ Submit
      Space to select · Enter to submit
      """)
    let selected = try XCTUnwrap(submit.prepared().menu)
    XCTAssertEqual(selected.items.map(\.label), ["Introduction", "References"])
    XCTAssertEqual(selected.items.map(\.selected), [true, false])
    XCTAssertFalse(selected.items.contains { $0.focused })
    XCTAssertTrue(selected.submitFocused)
    XCTAssertTrue(try XCTUnwrap(selected.selectionHint).contains("Space"))
    XCTAssertTrue(try XCTUnwrap(selected.submitHint).contains("Enter"))
  }

  func testMenuCannotInferSubmitKeysOrTransferFromHistory() throws {
    let previous = DecisionSnapshot(id: 4, name: "preview", text: "Export complete.", context: Self.checksMenu.text)
    XCTAssertNil(previous.prepared().menu)
    XCTAssertNil(Self.review.prepared().menu)
    let noKeys = DecisionSnapshot(id: 5, name: "preview", text: """
      Choose one export format:
      1) CSV
      2) JSON
      """)
    let noHints = try XCTUnwrap(noKeys.prepared().menu)
    XCTAssertNil(noHints.submitHint)
    XCTAssertFalse(noHints.submitFocused)
    XCTAssertEqual(noHints.items.count, 2)
  }

  func testLongMenuIsMarkedIncompleteAndLeavesRoomForItsQuestion() throws {
    let labels = (1...30).map { i in
      "[ ] 章节 \(i) " + String(repeating: "长", count: 48)
    }
    let snapshot = DecisionSnapshot(id: 5, name: "long-menu",
      text: (["请选择要导出的章节（可多选）"] + labels + ["Space to select · Enter to submit"]).joined(separator: "\n"))
    let brief = snapshot.prepared()
    let menu = try XCTUnwrap(brief.menu)
    XCTAssertTrue(menu.truncated)
    XCTAssertFalse(menu.items.isEmpty)
    XCTAssertLessThan(menu.items.count, labels.count)
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(brief).count, DecisionBrief.maxEncodedBytes)
    XCTAssertTrue(brief.blocks.contains { $0.source == .current && $0.text.contains("请选择要导出的章节") })
  }

  func testStatusLookingValuesStayWhenTheyExplainADecision() {
    let snapshot = DecisionSnapshot(id: 2, name: "usage-review", text: """
      原因：历史记录显示转换阶段的 CPU 占用达 92%。
      目标：保留 /example/archives 输入，输出快照。
      是否把批次减半？
      """)
    let brief = snapshot.prepared()
    XCTAssertTrue(brief.blocks.contains { $0.kind == .rationale && $0.text.contains("92%") })
    XCTAssertTrue(brief.blocks.contains { $0.kind == .goal && $0.text.contains("/example/archives") })
    XCTAssertTrue(brief.blocks.contains { $0.kind == .question && $0.text.contains("批次减半") })
  }

  func testLocalCompressionRedactsBeforeRankingAndKeepsEarlyConstraint() throws {
    let preview = Self.example.prepared()
    let history = preview.blocks.filter { $0.source == .history }
    let context = history.map(\.text).joined(separator: "\n")
    XCTAssertLessThanOrEqual(history.filter { $0.text.contains("Building fixture") }.count, 1)
    XCTAssertTrue(context.contains("Constraint: report must support nested fields."))
    XCTAssertTrue(context.contains("Decided to use the existing editor."))
    XCTAssertTrue(context.contains("Tests passed."))
    XCTAssertFalse(context.contains("history-private"))
    let current = preview.blocks.filter { $0.source == .current }.map(\.text)
    XCTAssertFalse(current.contains { $0.contains("screen-private") })
    XCTAssertTrue(current.contains(Self.question))
  }

  func testEncodedBudgetPrioritizesTheQuestionAndItsEarlierConstraints() throws {
    let old = (1...100).map { "Diagnostic row \($0): " + String(repeating: "旧", count: 48) }
    let history = (["Constraint: use the signed manifest."] + old).joined(separator: "\n")
    let status = (1...80).map { "Analyzing catalog page \($0) of 80..." }
    let snapshot = DecisionSnapshot(id: 7, name: "unicode-example",
      text: (status + [Self.review.text]).joined(separator: "\n"), context: history)
    let preview = snapshot.prepared()
    let encoded = try JSONEncoder().encode(preview)
    XCTAssertLessThanOrEqual(encoded.count, DecisionBrief.maxEncodedBytes)
    XCTAssertTrue(preview.blocks.contains { $0.source == .history && $0.text.contains("signed manifest") })
    XCTAssertTrue(preview.blocks.contains { $0.source == .current && $0.kind == .question && $0.text.contains("只验证样本") })
    XCTAssertTrue(preview.blocks.contains { $0.source == .current && $0.kind == .plan && $0.text.contains("a1b2c3d") })
  }

  func testNegotiatesHostExcerptAndRejectsInconsistentMetadata() throws {
    var remote = RemoteSession(id: 4, name: "review")
    XCTAssertNil(remote.negotiatedSnapshotVersion)
    remote.snapshot = true
    XCTAssertEqual(remote.negotiatedSnapshotVersion, .v1)
    let legacy: [String: Any] = ["id": 4, "name": "review", "text": "Done.", "context": NSNull()]
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    XCTAssertNil(try PaneSnapshotVersion.v1.decode(legacyData, for: remote).capture)
    remote.snapshotVersion = 2
    XCTAssertEqual(remote.negotiatedSnapshotVersion, .v2)
    XCTAssertThrowsError(try PaneSnapshotVersion.v2.decode(legacyData, for: remote))

    let screen = (1...80).map { "Sample \($0) ready." }.joined(separator: "\n") + "\n是否提交？"
    var payload: [String: Any] = [
      "id": 4, "name": "review", "version": 2, "paneId": 17, "columns": 80, "rows": 85,
      "alternate": false, "text": screen, "context": "原因：验证结果已通过。",
      "screenTruncated": false, "historyTruncated": true,
      "historyRowsScanned": 5000, "historyCompacted": true
    ]
    func decode() throws -> DecisionSnapshot {
      try PaneSnapshotVersion.v2.decode(JSONSerialization.data(withJSONObject: payload), for: remote)
    }
    let result = try decode()
    XCTAssertEqual(result.text, screen)
    XCTAssertEqual(result.capture?.paneId, 17)
    XCTAssertEqual(result.capture?.historyTruncated, true)
    XCTAssertEqual(result.capture?.historyRowsScanned, 5000)
    XCTAssertEqual(result.capture?.historyCompacted, true)
    let wire = try JSONEncoder().encode(result.prepared())
    let brief = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
    XCTAssertNil(brief["capture"])
    XCTAssertNil(brief["paneId"])
    XCTAssertLessThanOrEqual(wire.count, DecisionBrief.maxEncodedBytes)
    payload["alternate"] = true
    XCTAssertThrowsError(try decode())
    payload["context"] = NSNull()
    XCTAssertThrowsError(try decode())
    payload["alternate"] = false
    payload["rows"] = 1
    XCTAssertThrowsError(try decode())
    payload["rows"] = 85
    payload["historyRowsScanned"] = 5001
    XCTAssertThrowsError(try decode())
    payload["historyRowsScanned"] = 5000
    payload["context"] = nil
    XCTAssertThrowsError(try decode())
    payload["context"] = NSNull()
    payload["text"] = String(repeating: "界", count: 11_000)
    XCTAssertThrowsError(try decode())
    payload["text"] = "Done."
    payload["id"] = 5
    XCTAssertThrowsError(try decode())
  }

  func testCompactedHistorySupportsTheLiveQuestionThroughRepeatedStatusRows() throws {
    let screen = (0..<255).map { "Tests passed for shard \($0)." } + ["Should I publish catalog-r42.json?"]
    let archive = [
      "Constraint: retain the signed catalog-r42.json.",
      "Reason: config/catalog-r42.json is the rollback copy.",
      "Goal: publish catalog-r42.json after review.",
      "The digest for catalog-r42.json is ab47f2.",
    ] + (0..<200).map { "Constraint: avoid touching unrelated-\($0).json." }
    let metadata = NativePaneCapture(version: 2, paneId: 2, columns: 80, rows: 256, alternate: false,
                                     screenTruncated: false, historyTruncated: false,
                                     historyRowsScanned: 4820, historyCompacted: true)
    let input = DecisionSnapshot(id: 37, name: "catalog", text: screen.joined(separator: "\n"),
                                 context: archive.joined(separator: "\n"), capture: metadata)
    let brief = input.prepared()
    XCTAssertTrue(brief.blocks.contains { $0.source == .current && $0.kind == .question && $0.text == screen.last })
    XCTAssertTrue(brief.blocks.contains { $0.source == .current && $0.text == "Tests passed for shard 254." })
    let support = brief.blocks.filter { $0.source == .history }
    for kind: DecisionBrief.Kind in [.constraint, .rationale, .goal, .fact] {
      XCTAssertTrue(support.contains { $0.kind == kind && $0.text.contains("catalog-r42.json") })
    }
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(brief).count, DecisionBrief.maxEncodedBytes)
  }

  private func alternate(_ screen: String = "", activity: String? = nil, messages: [[String: String]]? = nil,
                         latestIsDisplayed: Bool = true) throws -> DecisionSnapshot {
    var payload: [String: Any] = [
      "id": 4, "name": "review", "version": 2, "paneId": 17, "columns": 100, "rows": 24,
      "alternate": true, "text": screen, "context": NSNull(), "screenTruncated": false,
      "historyTruncated": false, "historyRowsScanned": 0, "historyCompacted": false,
    ]
    payload["activity"] = activity
    if let messages {
      payload["applicationContext"] = ["source": "transcript", "sessionID": "ses_fixture", "order": "newestFirst",
                                       "latestIsDisplayed": latestIsDisplayed, "messages": messages] as [String: Any]
    }
    return try PaneSnapshotVersion.v2.decode(JSONSerialization.data(withJSONObject: payload),
                                             for: RemoteSession(id: 4, name: "review"))
  }

  func testRunningAlternatePaneStaysInPreviewAndOutOfMixedRequests() async throws {
    let fragment = "done' 2>&1 | tail -30"
    let messages = [["role": "assistant", "text": "Which color for the chart?"]]
    let snapshot = try alternate(fragment, activity: "running", messages: messages)
    let brief = snapshot.prepared()
    XCTAssertEqual(snapshot.capture?.reportsRunning, true)
    XCTAssertNil(snapshot.context)
    XCTAssertTrue(brief.blocks.contains(.init(source: .current, kind: .fact, text: fragment)))
    XCTAssertTrue(brief.blocks.contains { $0.source == .transcriptAssistant })
    XCTAssertFalse(brief.canAnalyze)
    XCTAssertFalse(try alternate("echo $?", activity: "running").prepared().canAnalyze)
    XCTAssertFalse(try alternate("Which chart?\n> Use the bar chart.\n" + fragment, activity: "running").prepared().canAnalyze)
    XCTAssertTrue(try alternate("Overwrite the report? [y/n]", activity: "running").prepared().canAnalyze)
    let menu = try alternate(Self.checksMenu.text, activity: "running").prepared()
    XCTAssertTrue(menu.canAnalyze)
    XCTAssertEqual(menu.menu?.items.count, 3)
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody()) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let content = try XCTUnwrap(messages.last?["content"])
        let sent = try JSONDecoder().decode([DecisionBrief].self, from: Data(content.utf8))
        XCTAssertEqual(sent.map(\.id), [37])
        return (200, try completion(#"{"decisions":[]}"#))
      }
    }
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    let skipped = try await SessionAdvisor.analyze([snapshot], key: Self.key, session: session)
    XCTAssertTrue(skipped.isEmpty)
    _ = try await SessionAdvisor.analyze([snapshot, Self.example], key: Self.key, session: session)
  }

  func testTranscriptRolesRecencyAndDecisionEvidence() throws {
    let newest = "Should we publish report-r42.json?"
    let messages = [["role": "assistant", "text": newest],
                    ["role": "user", "text": "Constraint: retain report-r42.json.\nAPI_KEY=test-secret"],
                    ["role": "assistant", "text": "Use the old layout?"]]
    let brief = try alternate(messages: messages).prepared()
    XCTAssertTrue(brief.canAnalyze)
    XCTAssertEqual(brief.blocks.first?.source, .latestAssistant)
    XCTAssertEqual(brief.blocks.last?.source, .transcriptAssistant)
    XCTAssertTrue(brief.blocks.contains { $0.source == .transcriptUser && $0.text.contains("report-r42") })
    let wire = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    XCTAssertFalse(wire.contains("test-secret"))
    XCTAssertFalse(wire.contains("ses_fixture"))
    XCTAssertLessThanOrEqual(wire.utf8.count, DecisionBrief.maxEncodedBytes)
    func answer(_ quote: String) -> SessionDecision {
      SessionDecision(sessionID: 4, question: "是否发出报告？", evidence: quote,
                      options: [.init(reply: "发布", tradeoff: "立即发布"), .init(reply: "暂缓", tradeoff: "保留复核时间")],
                      recommendedIndex: nil, reason: "")
    }
    XCTAssertEqual(try SessionAdvisor.validatedDecisions([answer(newest)], screens: [brief]).count, 1)
    XCTAssertThrowsError(try SessionAdvisor.validatedDecisions([answer("Use the old layout?")], screens: [brief]))
    XCTAssertFalse(try alternate(messages: messages, latestIsDisplayed: false).prepared().canAnalyze)
    XCTAssertFalse(try alternate("Build finished.", messages: messages).prepared().canAnalyze)
    XCTAssertFalse(try alternate(messages: [["role": "user", "text": "Yes, publish it."]] + messages).prepared().canAnalyze)
    XCTAssertFalse(try alternate(messages: [], latestIsDisplayed: false).prepared().canAnalyze)
    XCTAssertThrowsError(try alternate(messages: [["role": "tool", "text": "sample"]]))
    XCTAssertThrowsError(try alternate(messages: [["role": "user", "text": String(repeating: "界", count: 1400)]]))
    XCTAssertThrowsError(try alternate(messages: Array(repeating: messages[0], count: 33)))
  }

  func testTranscriptDedupKeepsTheNewestTurnAndItsRole() throws {
    let repeated = "Which catalog should I publish?"
    let turns = [["role": "assistant", "text": repeated],
                 ["role": "user", "text": "Retain both copies for review."],
                 ["role": "assistant", "text": "Earlier export completed.\n" + repeated]]
    let blocks = try alternate(messages: turns).prepared().blocks
    XCTAssertEqual(blocks.map(\.text), [repeated, "Retain both copies for review.", "Earlier export completed."])
    XCTAssertEqual(blocks.map(\.source), [.latestAssistant, .transcriptUser, .transcriptAssistant])
    let echoed = try alternate(messages: [["role": "user", "text": repeated]] + turns).prepared()
    XCTAssertFalse(echoed.canAnalyze)
    XCTAssertEqual(echoed.blocks.filter { $0.text == repeated }.map(\.source), [.transcriptUser])
  }

  func testFocusedRetryKeepsOnlyPreviewedEvidenceForAnOpenPrompt() throws {
    let latest = "Should we publish report-r42.json?"
    let turns = [["role": "assistant", "text": latest],
                 ["role": "user", "text": "Constraint: retain the original."],
                 ["role": "assistant", "text": "Should we use the archived format?"]]
    let checks = Self.checksMenu.prepared()
    let current = DecisionSnapshot(id: 6, name: "reports", text: "Which language?\n" + latest,
                                   context: "Should we use the archived format?").prepared()
    let transcript = try alternate(messages: turns).prepared()
    for preview in [checks, current, transcript] {
      let focus = try XCTUnwrap(preview.focusedForRetry)
      XCTAssertEqual(focus.id, preview.id)
      XCTAssertEqual(focus.name, preview.name)
      XCTAssertEqual(focus.menu, preview.menu)
      XCTAssertTrue(focus.blocks.allSatisfy { preview.blocks.contains($0) })
      if preview.menu == nil {
        let questions = focus.blocks.filter { $0.kind == .question }
        XCTAssertEqual(questions.map(\.text), [latest])
        XCTAssertEqual(questions.first?.source, preview.id == current.id ? .current : .latestAssistant)
      }
    }
    let answered = try alternate("Which chart?\n> Use the bar chart.\nWorking...", activity: "running")
    let idle = DecisionSnapshot(id: 1, name: "idle", text: "Build finished.", context: latest)
    let oldTurn = try alternate(messages: turns, latestIsDisplayed: false)
    let userReplied = try alternate(messages: [["role": "user", "text": "Yes, publish it."]] + turns)
    let submitted = DecisionSnapshot(id: 2, name: "submitted", text: "❯ Submit answers\nEnter to submit")
    XCTAssertEqual(submitted.prepared().menu?.items.count, 0)
    for snapshot in [answered, idle, oldTurn, userReplied, submitted] {
      XCTAssertNil(snapshot.prepared().focusedForRetry)
    }
  }

  func testNativeLongIdentifierKeepsSeparateQuestionAndRedactsAssignmentsAndURLs() throws {
    let longName = String(repeating: "build-system.v3-", count: 2_000)
    let question = "Should I change the data/\nstore?"
    let screen = longName + "\nShould I change the data/\n  store?\n--api-key=fixture-value\nhttps://demo:fixture-url@host"
    let metadata = NativePaneCapture(version: 2, paneId: 1, columns: 80, rows: 256, alternate: false,
                                     screenTruncated: false, historyTruncated: false,
                                     historyRowsScanned: 0, historyCompacted: false)
    let start = Date()
    let result = DecisionSnapshot(id: 7, name: "test", text: screen, capture: metadata).prepared()
    // A word-boundary search previously rescanned this entire dotted name at each hyphen.
    XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    XCTAssertTrue(result.blocks.contains { $0.kind == .question && $0.text == question })
    let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    XCTAssertFalse(wire.contains("fixture-value"))
    XCTAssertFalse(wire.contains("fixture-url"))
    XCTAssertLessThanOrEqual(wire.utf8.count, DecisionBrief.maxEncodedBytes)
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
    let preview = snapshot.prepared()
    let current = preview.blocks.filter { $0.source == .current }.map(\.text).joined(separator: "\n")
    XCTAssertLessThanOrEqual(current.utf8.count, 4096)
    XCTAssertFalse(current.contains("fixture"))
    XCTAssertFalse(current.contains("�"))
    XCTAssertFalse(preview.name.contains("fixture"))
    XCTAssertTrue(current.contains("请选格式"))
    XCTAssertFalse(preview.blocks.contains { $0.source == .history })
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
        for excluded in ["screen-private", "history-private", DecisionAnalysisTests.key, "Deepseek Flash", "89.2K"] {
          XCTAssertFalse(content.contains(excluded))
        }
        let sent = try JSONDecoder().decode([DecisionBrief].self, from: Data(content.utf8))
        XCTAssertEqual(sent, [DecisionAnalysisTests.example.prepared(), DecisionAnalysisTests.review.prepared(),
                              DecisionAnalysisTests.checksMenu.prepared()])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [[String: Any]])
        for (row, brief) in zip(rows, sent) {
          let keys = brief.menu == nil ? ["id", "name", "blocks"] : ["id", "name", "blocks", "menu"]
          XCTAssertEqual(Set(row.keys), Set(keys))
          let blocks = try XCTUnwrap(row["blocks"] as? [[String]])
          XCTAssertEqual(blocks, brief.blocks.map { [$0.source.rawValue, $0.kind.rawValue, $0.text] })
        }
        let chapters = try XCTUnwrap(sent.first { $0.id == DecisionAnalysisTests.checksMenu.id })
        let chapterLabels = try XCTUnwrap(chapters.menu).items.map(\.label)
        XCTAssertEqual(chapterLabels, ["摘要", "图表", "附录"])
        for option in chapterLabels {
          XCTAssertFalse(chapters.blocks.contains { $0.text.contains(option) }, "Duplicated menu item: \(option)")
        }
        return (200, try completion("""
          {"decisions":[{"session_id":37,"question":"选哪种报告格式？","evidence":"\(DecisionAnalysisTests.question)",
          "options":[{"reply":"1) CSV","tradeoff":"表格工具可以直接打开，但嵌套字段需要平铺。"},
          {"reply":"2) JSON","tradeoff":"能保留嵌套字段。"}],"recommended_index":1,"reason":"历史要求保留嵌套字段。"}]}
          """))
      }
    }
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    let result = try await SessionAdvisor.analyzePrepared([Self.example.prepared(), Self.review.prepared(), Self.checksMenu.prepared()],
                                                         key: Self.key, session: session)
    let decision = try XCTUnwrap(result.first)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(decision.sessionID, Self.example.id)
    XCTAssertEqual(decision.evidence, Self.question)
    XCTAssertEqual(decision.recommendedIndex, 1)
    XCTAssertEqual(decision.options.map(\.reply), ["1) CSV", "2) JSON"])
    XCTAssertTrue(decision.reason.contains("嵌套"))
  }

  func testDecisionResponseSeparatesNoQuestionsFromUnusableOutputAndOversizedInput() async throws {
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer fixture-none": return (200, try completion(#"{"decisions":[]}"#))
        case "Bearer fixture-length": return (200, try completion(#"{"decisions":[]}"#, finishReason: "length"))
        case "Bearer fixture-length-blank": return (200, try completion("", finishReason: "length"))
        case "Bearer fixture-blank": return (200, try completion(" \n\t "))
        case "Bearer fixture-missing": return (200, Data())
        case "Bearer fixture-limit": return (413, Data())
        case "Bearer fixture-context":
          return (400, Data(#"{"error":{"code":"context_length_exceeded","message":"request too large"}}"#.utf8))
        case "Bearer fixture-requested":
          return (400, Data(#"{"error":{"message":"This model's maximum context length is 128000 tokens. However, you requested 131000 tokens."}}"#.utf8))
        case "Bearer fixture-other": return (400, Data(#"{"error":{"message":"invalid parameter"}}"#.utf8))
        default: throw URLError(.badURL)
        }
      }
    }
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    let cases: [(String, SessionAdvisorError?)] = [
      ("none", nil), ("length", .outputTruncated), ("length-blank", .outputTruncated), ("blank", .emptyContent),
      ("missing", .invalidResponse), ("limit", .inputTooLong), ("context", .inputTooLong),
      ("requested", .inputTooLong), ("other", .requestRejected),
    ]
    for (fixture, expected) in cases {
      do {
        let result = try await SessionAdvisor.analyzePrepared(
          [Self.review.prepared()], key: "fixture-" + fixture, session: session)
        XCTAssertNil(expected, fixture)
        XCTAssertTrue(result.isEmpty, fixture)
      } catch let actual as SessionAdvisorError {
        XCTAssertEqual(actual, expected, fixture)
      }
    }
  }

  private static let longPreviews = (1...6).map { id in
    let rows = (1...24).map {
      "Constraint: keep report-\(id).json section \($0) intact. " + String(repeating: "样本", count: 40)
    }
    return DecisionSnapshot(id: Int64(id), name: "report-\(id)",
      text: (rows + ["Should we export report-\(id).json?"]).joined(separator: "\n")).prepared()
  }

  func testSixLongSessionsThenSingleFocusedRetryPreservesOtherResults() async throws {
    final class Endpoint: AdvisorHTTPFixture, @unchecked Sendable {
      override func reply() throws -> (Int, Data) {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody()) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let content = try XCTUnwrap(messages.last?["content"])
        let sent = try JSONDecoder().decode([DecisionBrief].self, from: Data(content.utf8))
        let previews = DecisionAnalysisTests.longPreviews
        let id: Int64
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-batch" {
          XCTAssertEqual(sent, previews)
          XCTAssertGreaterThan(content.utf8.count, 6 * 3000)
          XCTAssertLessThanOrEqual(content.utf8.count, 6 * DecisionBrief.maxEncodedBytes + 7)
          id = 1
        } else {
          let selected = try XCTUnwrap(previews.last)
          let focus = try XCTUnwrap(selected.focusedForRetry)
          XCTAssertEqual(sent.map(\.id), [selected.id])
          XCTAssertEqual(sent.first?.blocks, focus.blocks)
          XCTAssertEqual(sent.first?.menu, focus.menu)
          XCTAssertLessThan(content.utf8.count, try JSONEncoder().encode(selected).count)
          id = selected.id
        }
        return (200, try completion("""
          {"decisions":[{"session_id":\(id),"question":"Export report?","evidence":"Should we export report-\(id).json?",
          "options":[{"reply":"Export","tradeoff":"Available now"},{"reply":"Wait","tradeoff":"Time to review"}],
          "recommended_index":null,"reason":""}]}
          """))
      }
    }
    let session = Endpoint.session()
    defer { session.invalidateAndCancel() }
    let batch = try await SessionAdvisor.analyzePrepared(Self.longPreviews, key: "fixture-batch", session: session)
    XCTAssertEqual(batch.map(\.sessionID), [1])
    let focus = try XCTUnwrap(Self.longPreviews.last?.focusedForRetry)
    let retry = try await SessionAdvisor.analyzePrepared([focus], key: "fixture-focused", session: session)
    var result = DecisionReviewResults(batch)
    result.mergeRetry(retry, for: focus.id)
    XCTAssertEqual(result.decisions.map(\.sessionID), [1, 6])
    XCTAssertEqual(result.decisions.first?.evidence, batch.first?.evidence)
    result.mergeRetry([], for: 3)
    XCTAssertEqual(result.emptyRetries, [3])
    XCTAssertEqual(result.decisions.map(\.sessionID), [1, 6])
  }

  func testOnlyGroundedDistinctChoicesAreAccepted() throws {
    let screen = Self.example.prepared()
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
      [decision(quote: "Constraint: report must support nested fields.")],
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
    XCTAssertEqual(try SessionAdvisor.validatedDecisions(Array(questions.prefix(3)), screens: [multi.prepared()]).count, 3)
    XCTAssertThrowsError(try SessionAdvisor.validatedDecisions(questions, screens: [multi.prepared()]))
  }

  func testScopedConfirmationCannotOfferFollowUpPlanItemsAsReplies() throws {
    let source = Self.review.prepared()
    let quote = try XCTUnwrap(source.blocks.first { $0.kind == .question && $0.source == .current }).text
    let approve = DecisionOption(reply: "先整理过期标签", tradeoff: "先取得样本结果。", intent: .approve)
    let hold = DecisionOption(reply: "直接修改周报模板", tradeoff: "等待更多样本再判断。", intent: .hold)
    let unrelated = DecisionOption(reply: "新建周报", tradeoff: "影响周报。")
    func decision(_ options: [DecisionOption], recommend: Int? = nil) -> SessionDecision {
      SessionDecision(sessionID: source.id, question: "是否先验证样本？", evidence: quote, options: options,
                      recommendedIndex: recommend, reason: recommend == nil ? "" : "先验证可以检查当前样本。")
    }
    let response = decision([unrelated, hold, approve], recommend: 2)
    let scoped = try XCTUnwrap(SessionAdvisor.validatedDecisions([response], screens: [source]).first)
    XCTAssertEqual(scoped.options.count, 2)
    XCTAssertTrue(scoped.options.contains { $0.intent == .approve })
    XCTAssertTrue(scoped.options.contains { $0.intent == .hold })
    let selected = try XCTUnwrap(scoped.recommendedIndex)
    XCTAssertEqual(scoped.options[selected].intent, .approve)
    for option in scoped.options {
      XCTAssertFalse(option.reply.contains("标签") || option.reply.contains("周报"))
    }
    let removed = decision([unrelated, hold, approve], recommend: 0)
    let noRecommendation = try XCTUnwrap(SessionAdvisor.validatedDecisions([removed], screens: [source]).first)
    XCTAssertNil(noRecommendation.recommendedIndex)
    for invalid in [[unrelated, approve], [unrelated, hold], [approve, approve, hold]] {
      XCTAssertThrowsError(try SessionAdvisor.validatedDecisions([decision(invalid)], screens: [source]))
    }
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
    let footer = DecisionSnapshot(id: 3, name: "idle", text: "│ ▏\n━━━━━━\n│ Build · Deepseek Flash",
                                  context: "Which report format do you want?")
    let historyOnly = try await SessionAdvisor.analyze([footer], key: Self.key, session: session)
    XCTAssertTrue(historyOnly.isEmpty)
    do {
      let accidental = DecisionSnapshot(id: 1, name: "test", text: "notes \(Self.key)")
      _ = try await SessionAdvisor.analyze([accidental], key: Self.key, session: session)
      XCTFail("API credential was sent as screen data")
    } catch SessionAdvisorError.credentialInSnapshot {}
    let keyedMenu = DecisionSnapshot(id: 1, name: "test", text: """
      Choose one profile:
      ❯ 1. \(Self.key)
        2. Other
      Enter to confirm
      """)
    XCTAssertEqual(keyedMenu.prepared().menu?.items.first?.label, "1. " + Self.key)
    do {
      _ = try await SessionAdvisor.analyze([keyedMenu], key: Self.key, session: session)
      XCTFail("Credential in a menu label reached the network")
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
            screens.append(capture)
          }
          usedSSH = true
        }
      }
      // This fourth fixture is generated in memory and never reads a user's pane.
      let reviewID = try XCTUnwrap((0...Int64(screens.count)).first { id in !screens.contains { $0.id == id } })
      let review = DecisionSnapshot(id: reviewID, name: Self.review.name, text: Self.review.text)
      let sshIDs = usedSSH ? Set(screens.map(\.id)) : []
      screens.append(review)
      let result = try await SessionAdvisor.analyze(screens, key: key)
      XCTAssertEqual(Set(result.map(\.sessionID)), [screens[0].id, screens[1].id, reviewID])
      XCTAssertEqual(result.count, 3)
      let confirmation = try XCTUnwrap(result.first { $0.sessionID == reviewID })
      XCTAssertTrue(confirmation.options.contains { $0.intent == .approve })
      XCTAssertTrue(confirmation.options.contains { $0.intent == .hold })
      for option in confirmation.options {
        XCTAssertFalse(option.reply.contains("周报") || option.reply.contains("过期标签"))
      }
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
        ["session": screens.first { $0.id == value.sessionID }?.name ?? "",
         "source": sshIDs.contains(value.sessionID) ? "synthetic-ssh" : "synthetic-local", "question": value.question,
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
