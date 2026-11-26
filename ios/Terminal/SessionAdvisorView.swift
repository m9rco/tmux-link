import SwiftUI
import UniformTypeIdentifiers

struct AdvisorSelection {
  let client: ClientProfile
  let session: RemoteSession

  init?(_ candidate: RemoteSession, in sessions: [RemoteSession], client: ClientProfile) {
    guard candidate.id >= 0, let current = sessions.first(where: {
      $0.id == candidate.id && $0.name == candidate.name
    }) else { return nil }
    self.client = client
    self.session = current
  }

  @MainActor var terminal: TerminalView { TerminalView(client: client, session: session) }
}

private struct PaneReading: Identifiable {
  let brief: DecisionBrief
  let readAt: Date
  let capture: NativePaneCapture?
  let sourceNotice: String?

  init(snapshot: DecisionSnapshot, readAt: Date, sourceNotice: String? = nil) {
    brief = snapshot.prepared()
    self.readAt = readAt
    capture = snapshot.capture
    self.sourceNotice = sourceNotice
  }

  var id: Int64 { brief.id }
}

@MainActor
struct SessionAdvisorView: View {
  let sessions: [RemoteSession]
  let notice: String?
  let capture: @MainActor (RemoteSession) async throws -> DecisionSnapshot
  let open: @MainActor (RemoteSession) async throws -> Bool

  private struct Preview {
    let sources: [RemoteSession]
    let readings: [PaneReading]
    let failures: [String]
  }

  @Environment(\.dismiss) private var dismiss
  @State private var selected: [Int64: String] = [:]
  @State private var reading: Task<Void, Never>?
  @State private var preview: Preview?
  @State private var readErrors: [String] = []
  @StateObject private var keyStatus = AdvisorKeyStatus()
  @State private var editingKey = false

  private var candidates: [RemoteSession] {
    var seen = Set<Int64>()
    return sessions.filter { $0.id >= 0 && seen.insert($0.id).inserted }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let notice { Text(notice).foregroundStyle(.secondary) }
          ForEach(candidates) { candidate in
            let included = selected[candidate.id] == candidate.name
            Button {
              readErrors = []
              if included { selected.removeValue(forKey: candidate.id) }
              else { selected[candidate.id] = candidate.name }
            } label: {
              HStack {
                Text(verbatim: candidate.name).font(.body.monospaced()).foregroundStyle(.primary)
                Spacer()
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
              }
            }
            .disabled(reading != nil || (!included && selected.count >= SessionAdvisor.maxDecisionSessions))
            .accessibilityAddTraits(included ? .isSelected : [])
            .accessibilityIdentifier("advisor.select.\(candidate.id)")
          }
        } header: {
          Text("选择会话")
        } footer: {
          Text("最多选择 \(SessionAdvisor.maxDecisionSessions) 个会话。预览会读取各会话当前活动窗格中的文字。")
        }
        if !readErrors.isEmpty { failureSection(readErrors) }
        AdvisorKeySection(editing: $editingKey).disabled(reading != nil)
      }
      .navigationTitle("待答问题").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { cancelRead(); dismiss() }.accessibilityIdentifier("advisor.close")
        }
        ToolbarItem(placement: .confirmationAction) {
          if reading != nil {
            Button(action: cancelRead) {
              HStack { ProgressView().controlSize(.small); Text("取消读取") }
            }.accessibilityIdentifier("advisor.cancel")
          } else {
            Button("预览（\(selected.count)）", action: readSelection)
              .disabled(selected.isEmpty || notice != nil || editingKey)
              .accessibilityIdentifier("advisor.preview")
          }
        }
      }
      .navigationDestination(isPresented: Binding(
        get: { preview != nil }, set: { if !$0 { preview = nil } })
      ) {
        if let preview {
          DecisionReviewContent(
            readings: preview.readings, failures: preview.failures, openLabel: "打开原会话",
            open: { id in
              guard let source = preview.sources.first(where: { $0.id == id }) else { return false }
              return try await open(source)
            }, close: { dismiss() })
        }
      }
    }
    .environmentObject(keyStatus)
    .onChange(of: sessions) { current in
      let valid = selected.filter { id, name in current.contains { $0.id == id && $0.name == name } }
      guard valid.count != selected.count else { return }
      cancelRead()
      selected = valid
      preview = nil
      readErrors = ["所选会话已关闭或更名，请重新选择并预览。"]
    }
    .onDisappear { cancelRead() }
  }

  private func cancelRead() {
    reading?.cancel()
    reading = nil
  }

  private func readSelection() {
    let sources = candidates.filter { selected[$0.id] == $0.name }
    guard reading == nil, (1...SessionAdvisor.maxDecisionSessions).contains(sources.count) else { return }
    readErrors = []
    reading = Task {
      var readings: [PaneReading] = []
      var failures: [String] = []
      for source in sources {
        guard !Task.isCancelled else { return }
        do {
          let snapshot = try await capture(source)
          guard snapshot.id == source.id else { throw RelayError("会话已更改，请刷新列表。") }
          guard !Task.isCancelled else { return }
          let readAt = Date()
          let prepared = await Task.detached(priority: .userInitiated) {
            PaneReading(snapshot: snapshot, readAt: readAt)
          }.value
          guard !Task.isCancelled else { return }
          readings.append(prepared)
        } catch {
          failures.append("\(source.name) · \(error.localizedDescription)")
        }
      }
      guard !Task.isCancelled else { return }
      reading = nil
      if readings.isEmpty { readErrors = failures }
      else { preview = Preview(sources: sources, readings: readings, failures: failures) }
    }
  }
}

// Entry point for a terminal that is already open. Only dismissing the review returns to it.
@MainActor
struct DecisionReviewView: View {
  private let local: DecisionSnapshot
  private let readAt: Date
  private let hostRead: (() async throws -> DecisionSnapshot)?
  @State private var reading: PaneReading?
  let onClose: () -> Void
  @StateObject private var keyStatus = AdvisorKeyStatus()

  init(snapshot: DecisionSnapshot, readAt: Date = Date(), alternate: Bool = false,
       hostRead: (() async throws -> DecisionSnapshot)? = nil, onClose: @escaping () -> Void) {
    local = snapshot
    self.readAt = readAt
    self.hostRead = hostRead
    let notice = alternate ? "来源为手机当前画面，此连接未提供应用对话记录。" : nil
    _reading = State(initialValue: hostRead == nil ? PaneReading(snapshot: snapshot, readAt: readAt, sourceNotice: notice) : nil)
    self.onClose = onClose
  }

  var body: some View {
    NavigationStack {
      if let reading {
        DecisionReviewContent(readings: [reading], failures: [], openLabel: "返回原终端",
                              open: { _ in onClose(); return true }, close: onClose)
      } else {
        ProgressView("正在读取主机活动窗格…")
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: onClose) } }
          .task {
            guard let hostRead else { return }
            let snapshot: DecisionSnapshot, time: Date, notice: String?
            do {
              let host = try await hostRead()
              if host.capture?.alternate == true {
                snapshot = host
                time = Date()
                notice = "来源为主机读取时的活动窗格。"
              } else {
                // tmux itself can occupy xterm's alternate buffer even for an ordinary shell pane.
                snapshot = local
                time = readAt
                notice = nil
              }
            } catch {
              snapshot = local
              time = readAt
              notice = "主机活动窗格读取失败（\(error.localizedDescription)）。当前显示点击「决策」时的手机画面。"
            }
            guard !Task.isCancelled else { return }
            let prepared = await Task.detached(priority: .userInitiated) {
              PaneReading(snapshot: snapshot, readAt: time, sourceNotice: notice)
            }.value
            if !Task.isCancelled { reading = prepared }
          }
      }
    }.environmentObject(keyStatus)
  }
}

struct DecisionReviewResults {
  private(set) var decisions: [SessionDecision]
  private(set) var emptyRetries: Set<Int64> = []

  init(_ decisions: [SessionDecision]) { self.decisions = decisions }

  func isMissing(_ id: Int64) -> Bool { !decisions.contains { $0.sessionID == id } }

  mutating func mergeRetry(_ response: [SessionDecision], for id: Int64) {
    guard isMissing(id), !emptyRetries.contains(id) else { return }
    let matches = response.filter { $0.sessionID == id }
    if matches.isEmpty { emptyRetries.insert(id) }
    else { decisions.append(contentsOf: matches) }
  }
}

@MainActor
private struct DecisionReviewContent: View {
  let readings: [PaneReading]
  let failures: [String]
  let openLabel: String
  let open: @MainActor (Int64) async throws -> Bool
  let close: () -> Void

  private enum Operation: Equatable { case analyzing, retrying(Int64), opening }
  @State private var excluded: Set<Int64> = []
  @EnvironmentObject private var keyStatus: AdvisorKeyStatus
  @State private var editingKey = false
  @State private var results: DecisionReviewResults?
  @State private var retryErrors: [Int64: String] = [:]
  @State private var errorMessage: String?
  @State private var copied: IndexPath?
  @State private var operation: Operation?
  @State private var task: Task<Void, Never>?

  private var included: [PaneReading] {
    readings.filter { !excluded.contains($0.id) && $0.brief.canAnalyze }
  }

  var body: some View {
    Form {
      if let results {
        if results.decisions.isEmpty {
          Section {
            Label("模型本次未返回候选答复。", systemImage: "text.bubble")
              .accessibilityIdentifier("advisor.none")
          }
        }
        ForEach(results.decisions.indices, id: \.self) { index in
          decisionSection(results.decisions[index], index: index)
        }
        ForEach(included.filter { results.isMissing($0.id) }) { reading in
          unansweredSection(reading, retried: results.emptyRetries.contains(reading.id))
        }
        Button("返回上下文预览") {
          self.results = nil
          retryErrors = [:]
          copied = nil
          errorMessage = nil
        }.disabled(operation != nil).accessibilityIdentifier("advisor.backToPreview")
      } else {
        ForEach(readings) { reading in
          previewSection(reading)
        }
        Section {
          Button { analyze(included.map(\.brief)) } label: {
            Label(included.isEmpty ? "分析所选会话" : "分析 \(included.count) 个会话", systemImage: "sparkles")
          }
          .disabled(included.isEmpty || !keyStatus.saved || editingKey || operation != nil)
          .accessibilityIdentifier("advisor.submit")
        } footer: {
          Text("\(keyStatus.provider.name) 将收到所选会话的编号、名称和这里展示的上下文。")
        }
      }
      if operation == .analyzing || operation == .opening {
        Section {
          cancelButton(operation == .analyzing ? "正在分析待答问题…" : "正在核对原会话…")
        }
      }
      if let errorMessage {
        Section {
          Text(verbatim: errorMessage).foregroundStyle(.orange).accessibilityIdentifier("advisor.error")
        }
      }
      if !failures.isEmpty { failureSection(failures) }
      if results == nil {
        AdvisorKeySection(editing: $editingKey).disabled(operation != nil)
      }
    }
    .id(results == nil)
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(results == nil ? "决策上下文" : "待答问题").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("关闭") { cancel(); close() }.accessibilityIdentifier("advisor.close")
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: AdvisorCredential.changed)) { _ in
      if operation != .opening { cancel() }
      results = nil
      retryErrors = [:]
      keyStatus.refresh()
    }
    .onDisappear { cancel() }
  }

  private func previewSection(_ reading: PaneReading) -> some View {
    return Section {
      if let notice = reading.sourceNotice { Text(verbatim: notice).font(.footnote).foregroundStyle(.secondary) }
      if let capture = reading.capture {
        if capture.alternate {
          if capture.reportsRunning {
            Label("全屏程序正在执行任务", systemImage: "hourglass")
              .accessibilityIdentifier("advisor.running.\(reading.id)")
          }
          if let app = capture.applicationContext {
            Text(app.messages.isEmpty
                 ? "已绑定的应用对话 · \(app.sessionID) · 暂无可显示的对话文字。"
                 : "已绑定的应用对话 · \(app.sessionID) · 最近 \(app.messages.count) 条消息，从新到旧摘录。")
              .font(.footnote).foregroundStyle(.secondary)
            if reading.brief.blocks.contains(where: { $0.source == .latestAssistant }) {
              Text("提问来自已绑定对话的最新助手消息，是否仍待答可回原终端核对。")
                .font(.footnote).foregroundStyle(.secondary)
            }
          } else {
            Text("全屏程序使用备用屏幕，tmux 无法读取它的滚动历史。\(capture.missingTranscriptReason)")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        if capture.screenTruncated {
          Text("当前屏幕较长，快照仅保留了末尾部分。").font(.footnote).foregroundStyle(.secondary)
        }
        if capture.historyCompacted {
          Text("主机已筛选 \(capture.historyRowsScanned.formatted()) 行历史，仅返回相关片段。")
            .font(.footnote).foregroundStyle(.secondary)
        }
        if capture.historyTruncated {
          Text("更早的历史超出读取范围。").font(.footnote).foregroundStyle(.secondary)
        }
      }
      if !reading.brief.canAnalyze {
        Text(reading.capture?.alternate == true ? "此次快照没有可确认的待答问题，已跳过分析。" : "过滤界面元素后，当前屏幕没有可分析的正文。").foregroundStyle(.secondary)
          .accessibilityIdentifier("advisor.empty.\(reading.id)")
      } else {
        Toggle("纳入分析", isOn: Binding(
          get: { !excluded.contains(reading.id) },
          set: { include in
            if include { excluded.remove(reading.id) } else { excluded.insert(reading.id) }
            errorMessage = nil
          }))
          .disabled(operation != nil)
          .accessibilityIdentifier("advisor.include.\(reading.id)")
      }
      if !reading.brief.blocks.isEmpty, reading.brief.canAnalyze || reading.capture?.alternate == true {
        BriefPreview(brief: reading.brief)
      }
      if let menu = reading.brief.menu {
        TerminalMenuPreview(menu: menu)
        openButton(reading.id, identifier: "advisor.open.menu.\(reading.id)")
      } else if reading.capture?.alternate == true {
        openButton(reading.id, identifier: "advisor.open.\(reading.id)")
      }
    } header: {
      readingHeader(reading)
    }
  }

  private func decisionSection(_ decision: SessionDecision, index: Int) -> some View {
    let source = readings.first { $0.id == decision.sessionID }
    return Section {
      Text(verbatim: decision.question).font(.headline).textSelection(.enabled)
        .accessibilityIdentifier("advisor.question.\(index)")
      VStack(alignment: .leading, spacing: 6) {
        let fromTranscript = source?.brief.blocks.contains {
          $0.source == .latestAssistant && $0.text.contains(decision.evidence)
        } == true
        Label(fromTranscript ? "已绑定的应用对话摘录 · 待核实" : "屏幕摘录", systemImage: "quote.opening")
          .font(.caption).foregroundStyle(.secondary)
        Text(verbatim: decision.evidence).font(.callout.monospaced()).textSelection(.enabled)
      }.privacySensitive()
      ForEach(decision.options.indices, id: \.self) { optionIndex in
        let option = decision.options[optionIndex]
        let recommended = decision.recommendedIndex == optionIndex
        let position = IndexPath(row: optionIndex, section: index)
        VStack(alignment: .leading, spacing: 6) {
          if recommended {
            Label("推荐回复", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(.mint)
          }
          Text(verbatim: option.reply).font(.body.weight(.medium)).textSelection(.enabled)
          Text(verbatim: option.tradeoff).font(.subheadline).foregroundStyle(.secondary)
          if recommended && !decision.reason.isEmpty {
            Text(verbatim: "推荐理由 · " + decision.reason).font(.subheadline)
          }
          if source?.brief.menu == nil {
            Button {
              UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: option.reply]], options: [.localOnly: true])
              copied = position
            } label: {
              Label(copied == position ? "已复制" : "复制回复", systemImage: copied == position ? "checkmark" : "doc.on.doc")
                .font(.subheadline)
            }.buttonStyle(.borderless)
              .accessibilityIdentifier("advisor.copy.\(index).\(optionIndex)")
          }
        }.padding(.vertical, 3).privacySensitive()
      }
      if decision.recommendedIndex == nil && !decision.reason.isEmpty {
        Text(verbatim: decision.reason).font(.subheadline)
      }
      if let menu = source?.brief.menu, results?.decisions.firstIndex(where: { $0.sessionID == decision.sessionID }) == index {
        DisclosureGroup("查看终端菜单") { TerminalMenuPreview(menu: menu) }
      }
      openButton(decision.sessionID, identifier: "advisor.open.\(decision.sessionID).\(index)")
        .disabled(source == nil)
    } header: {
      if let source { readingHeader(source) }
    }
  }

  private func unansweredSection(_ reading: PaneReading, retried: Bool) -> some View {
    let focused = reading.brief.focusedForRetry
    let menu = reading.brief.menu
    let status: String
    if retried {
      status = "单独分析后，模型仍未给出候选答复。"
    } else if let menu, menu.items.isEmpty {
      status = "当前画面只有提交提示，可回原终端核对。"
    } else if menu != nil {
      status = "终端显示了选择菜单，模型未给出选择建议。"
    } else if focused != nil {
      status = "原文中有提问，模型未给出这道题的候选答复。"
    } else {
      status = "模型未识别出此会话当前有待答的问题。"
    }

    return Section {
      Text(verbatim: status).foregroundStyle(.secondary)
        .accessibilityIdentifier("advisor.unanswered.\(reading.id)")
      if let focused { BriefPreview(brief: focused) }
      if let menu { TerminalMenuPreview(menu: menu) }
      if let focused, !retried {
        if operation == .retrying(reading.id) {
          cancelButton(menu == nil ? "正在分析这道题…" : "正在分析这个菜单…")
        } else {
          Button(menu == nil ? "只分析这道题" : "只分析这个菜单") {
            analyze([focused], retrying: reading.id)
          }
          .disabled(operation != nil || !keyStatus.saved)
          .accessibilityIdentifier("advisor.retry.\(reading.id)")
        }
      }
      if let error = retryErrors[reading.id] {
        Text(verbatim: error).foregroundStyle(.orange)
          .accessibilityIdentifier("advisor.retry.error.\(reading.id)")
      }
      openButton(reading.id, identifier: menu == nil ? "advisor.open.\(reading.id)" : "advisor.open.menu.\(reading.id)")
    } header: {
      readingHeader(reading)
    } footer: {
      if focused != nil, !retried {
        Text("单独分析只会向 \(keyStatus.provider.name) 发送本会话的编号、名称和本节展示的摘录。")
      }
    }
  }

  private func cancelButton(_ label: String) -> some View {
    Button(action: cancel) {
      HStack {
        ProgressView()
        Text(verbatim: label)
        Spacer()
        Text("取消")
      }
    }.accessibilityIdentifier("advisor.cancel")
  }

  private func openButton(_ id: Int64, identifier: String) -> some View {
    Button {
      run(.opening) {
        let opened = try await open(id)
        try Task.checkCancellation()
        if !opened { errorMessage = "原会话已关闭或更名，请返回会话列表重新预览。" }
      }
    } label: { Label(openLabel, systemImage: "terminal") }
    .disabled(operation != nil)
    .accessibilityIdentifier(identifier)
  }

  private func readingHeader(_ reading: PaneReading) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: "\(reading.brief.name) · #\(reading.id)").textCase(nil)
      Text("读取于 \(reading.readAt.formatted(date: .omitted, time: .standard))")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func analyze(_ approved: [DecisionBrief], retrying id: Int64? = nil) {
    guard !approved.isEmpty else { return }
    if let id {
      guard let results, results.isMissing(id), !results.emptyRetries.contains(id) else { return }
    }
    let disclosedProvider = keyStatus.provider
    run(id.map(Operation.retrying) ?? .analyzing) {
      if let id { retryErrors[id] = nil }
      guard let access = try AdvisorCredential.current() else {
        keyStatus.saved = false
        if let id { retryErrors[id] = "请返回上下文预览保存模型服务的 API Key。" }
        else { errorMessage = "请先保存模型服务的 API Key。" }
        return
      }
      guard access.provider == disclosedProvider else {
        keyStatus.refresh()
        throw RelayError("模型服务已切换，请确认服务后重新分析。")
      }
      let result = try await SessionAdvisor.analyzePrepared(approved, key: access.key, provider: access.provider)
      try Task.checkCancellation()
      if let id { results?.mergeRetry(result, for: id) }
      else { results = DecisionReviewResults(result) }
    }
  }

  private func cancel() {
    task?.cancel()
    task = nil
    operation = nil
  }

  private func run(_ next: Operation, action: @escaping @MainActor () async throws -> Void) {
    guard operation == nil else { return }
    errorMessage = nil
    operation = next
    task = Task {
      do {
        try Task.checkCancellation()
        try await action()
      } catch {
        guard !Task.isCancelled else { return }
        if case .retrying(let id) = next { retryErrors[id] = error.localizedDescription }
        else { errorMessage = error.localizedDescription }
      }
      guard !Task.isCancelled else { return }
      operation = nil
      task = nil
    }
  }
}

private struct BriefPreview: View {
  let brief: DecisionBrief

  var body: some View {
    let questions = brief.blocks.filter { ($0.source == .current || $0.source == .latestAssistant) && $0.kind == .question }
    let context = brief.blocks.filter { !questions.contains($0) }
    // Lead with the live question. Keep the original order within the supporting excerpts.
    blockRows(questions)
    if context.contains(where: { $0.source == .transcriptAssistant || $0.source == .transcriptUser }) {
      // Keep transcript turns in the same newest-first order the model receives.
      let shown = context.filter { $0.source == .current } + context.filter { $0.source != .current }
      blockRows(Array(shown.prefix(4)))
      if shown.count > 4 {
        DisclosureGroup("更多上下文（\(shown.count - 4)）") { blockRows(Array(shown.dropFirst(4))) }
          .font(.subheadline)
      }
    } else if context.count > 4 {
      let priority: [DecisionBrief.Kind] = [.rationale, .goal, .constraint, .plan, .choice]
      let primary = priority.compactMap { kind in
        context.firstIndex { $0.kind == kind && $0.source == .current } ?? context.firstIndex { $0.kind == kind }
      }
      let other = context.indices.filter { !primary.contains($0) }
      let featured = Set((primary + other).prefix(4))
      let shown = context.indices.filter(featured.contains).map { context[$0] }
      let remaining = context.indices.filter { !featured.contains($0) }.map { context[$0] }
      blockRows(shown)
      if !remaining.isEmpty {
        DisclosureGroup("更多上下文（\(remaining.count)）") { blockRows(remaining) }
          .font(.subheadline)
      }
    } else {
      blockRows(context)
    }
  }

  private func blockRows(_ blocks: [DecisionBrief.Block]) -> some View {
    ForEach(blocks.indices, id: \.self) { index in
      let block = blocks[index]
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: title(block.kind) + " · " + sourceTitle(block.source))
          .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Text(verbatim: block.text).font(block.kind == .question ? .headline : .subheadline)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
      .privacySensitive()
    }
  }

  private func sourceTitle(_ source: DecisionBrief.Source) -> String {
    switch source {
    case .current: return "当前屏幕"
    case .history: return "tmux 历史"
    case .transcriptUser: return "应用对话 · 用户"
    case .transcriptAssistant: return "应用对话 · 助手"
    case .latestAssistant: return "应用对话 · 最新助手消息"
    }
  }

  private func title(_ kind: DecisionBrief.Kind) -> String {
    switch kind {
    case .question: return "提问"
    case .rationale: return "原因"
    case .goal: return "目标"
    case .constraint: return "约束"
    case .fact: return "相关信息"
    case .plan: return "计划步骤"
    case .choice: return "可选项"
    case .state: return "进展"
    }
  }
}

private struct TerminalMenuPreview: View {
  let menu: TerminalChoiceMenu

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.subheadline.weight(.semibold))
      ForEach(menu.items.indices, id: \.self) { index in
        let item = menu.items[index]
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if let selected = item.selected {
            let shape = menu.mode == .multiple ? "square" : "circle"
            Image(systemName: selected ? "checkmark.\(shape).fill" : shape)
              .foregroundStyle(selected ? Color.accentColor : .secondary)
              .accessibilityLabel(selected ? "已选中" : "未选中")
          }
          Text(verbatim: item.label).textSelection(.enabled)
          if item.focused {
            Text("焦点").font(.caption).foregroundStyle(.secondary)
          }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
      }
      if menu.truncated {
        Text("其余选项可在原终端查看。").font(.caption).foregroundStyle(.secondary)
      }
      if let selection = menu.selectionHint, selection == menu.submitHint {
        hintRow("操作方式", selection)
      } else {
        if let hint = menu.selectionHint { hintRow("选择", hint) }
        if let hint = menu.submitHint { hintRow("提交", hint) }
      }
      if menu.submitHint == nil {
        Text("当前画面未显示提交方式。").font(.caption).foregroundStyle(.secondary)
      }
      if menu.submitFocused {
        Text("焦点位于提交项").font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .privacySensitive()
  }

  private var title: String {
    switch menu.mode {
    case .single: return "终端菜单 · 单选"
    case .multiple: return "终端菜单 · 多选"
    case .unspecified: return menu.items.isEmpty ? "终端提交" : "终端菜单 · 选择类型未标明"
    }
  }

  private func hintRow(_ title: String, _ hint: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
      Text(verbatim: hint).font(.footnote.monospaced()).textSelection(.enabled)
    }
  }
}

private func failureSection(_ errors: [String]) -> some View {
  Section("以下会话未能读取") {
    ForEach(errors.indices, id: \.self) { index in
      Text(verbatim: errors[index]).font(.callout).foregroundStyle(.orange)
    }
  }
}

@MainActor
final class AdvisorKeyStatus: ObservableObject {
  @Published var saved = false
  @Published var provider = AdvisorProvider.deepSeek
  @Published var errorMessage: String?

  init() { refresh() }

  func refresh() {
    do {
      let catalog = try AdvisorProviders.load()
      guard let selected = catalog.selected else { throw RelayError("请选择模型服务。") }
      provider = selected
      saved = try AdvisorCredential.load(for: selected) != nil
      errorMessage = nil
    } catch {
      saved = false
      errorMessage = error.localizedDescription
    }
  }
}

struct AdvisorKeySection: View {
  @EnvironmentObject private var keyStatus: AdvisorKeyStatus
  @Binding var editing: Bool

  var body: some View {
    Section("模型服务") {
      Button { editing = true } label: {
        LabeledContent(keyStatus.provider.name, value: keyStatus.saved ? keyStatus.provider.model : "配置密钥")
      }
      .accessibilityIdentifier("advisor.provider.settings")
      if let error = keyStatus.errorMessage { Text(verbatim: error).foregroundStyle(.orange) }
    }
    .sheet(isPresented: $editing, onDismiss: keyStatus.refresh) { AdvisorProviderSettings() }
    .onReceive(NotificationCenter.default.publisher(for: AdvisorCredential.changed)) { _ in keyStatus.refresh() }
  }
}

struct AdvisorProviderSettings: View {
  @Environment(\.dismiss) private var dismiss
  @State private var catalog = AdvisorProviders()
  @State private var editing: AdvisorProvider?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(catalog.profiles) { provider in
            Button {
              do {
                var next = try AdvisorProviders.load()
                guard next.profiles.contains(provider) else { refresh(); return }
                if next.selectedID != provider.id {
                  next.selectedID = provider.id
                  try next.save()
                }
                catalog = next
                errorMessage = nil
              } catch { errorMessage = error.localizedDescription }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(verbatim: provider.name).foregroundStyle(.primary)
                  Text(verbatim: provider.model).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if provider.id == catalog.selectedID { Image(systemName: "checkmark") }
              }
            }
            .accessibilityAddTraits(provider.id == catalog.selectedID ? .isSelected : [])
            .accessibilityIdentifier("advisor.provider." + provider.id)
          }
        } header: { Text("当前服务") } footer: {
          Text("托管和手动分析都通过所选服务处理。切换后，新请求将使用该服务的模型和密钥。")
        }
        Section {
          if let selected = catalog.selected {
            Button { editing = selected } label: { Label("配置 \(selected.name)", systemImage: "slider.horizontal.3") }
          }
          Button {
            editing = AdvisorProvider(id: UUID().uuidString, name: "", baseURL: "", model: "")
          } label: { Label("添加兼容服务或中转站", systemImage: "plus") }
        }
        if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.orange) }
      }
      .navigationTitle("模型服务").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
      .onAppear(perform: refresh)
      .onReceive(NotificationCenter.default.publisher(for: AdvisorCredential.changed)) { _ in refresh() }
      .sheet(item: $editing, onDismiss: refresh) { profile in
        AdvisorProviderEditor(original: profile, isNew: !catalog.profiles.contains { $0.id == profile.id })
      }
    }
  }

  private func refresh() {
    do { catalog = try AdvisorProviders.load(); errorMessage = nil }
    catch { errorMessage = error.localizedDescription }
  }
}

private struct AdvisorProviderEditor: View {
  let original: AdvisorProvider
  let isNew: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var address: String
  @State private var model: String
  @State private var key = ""
  @State private var savedKey = false
  @State private var errorMessage: String?
  @State private var removingKey = false
  @State private var deletingProfile = false

  init(original: AdvisorProvider, isNew: Bool) {
    self.original = original
    self.isNew = isNew
    _name = State(initialValue: original.name)
    _address = State(initialValue: original.baseURL)
    _model = State(initialValue: original.model)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if original.builtin {
            LabeledContent("服务", value: name)
            LabeledContent("地址", value: address)
          } else {
            TextField("服务名称", text: $name)
            TextField("HTTPS Base URL", text: $address)
              .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          }
          TextField("模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("服务配置") } footer: {
          if !original.builtin { Text("填写兼容 Chat Completions 的服务地址，保留服务商要求的 /v1 或其他路径。") }
        }
        Section {
          SecureField(savedKey ? "输入新密钥以更换" : "API Key", text: $key)
            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            .accessibilityIdentifier("advisor.key.input")
          if savedKey {
            Button("移除已保存的密钥", role: .destructive) { removingKey = true }
          }
        } header: { Text("本机钥匙串") } footer: {
          Text("密钥只用于此服务地址。更改地址时需要重新输入。")
        }
        if !isNew && !original.builtin {
          Section { Button("删除服务", role: .destructive) { deletingProfile = true } }
        }
        if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.orange) }
      }
      .navigationTitle(isNew ? "添加模型服务" : original.name).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(isNew ? "保存并使用" : "保存", action: save).accessibilityIdentifier("advisor.key.save")
        }
      }
      .onAppear {
        guard !isNew else { return }
        do { savedKey = try AdvisorCredential.load(for: original) != nil }
        catch { errorMessage = error.localizedDescription }
      }
      .confirmationDialog("移除本机保存的 API Key？", isPresented: $removingKey) {
        Button("移除密钥", role: .destructive) {
          do { try AdvisorCredential.remove(for: original); savedKey = false; key = ""; errorMessage = nil }
          catch { errorMessage = error.localizedDescription }
        }
      }
      .confirmationDialog("删除服务及其密钥，并使用 DeepSeek？", isPresented: $deletingProfile) {
        Button("删除并切换到 DeepSeek", role: .destructive) {
          do {
            var catalog = try AdvisorProviders.load()
            guard catalog.profiles.contains(original) else { throw RelayError("配置已更改，请重新打开此服务。") }
            try AdvisorCredential.remove(for: original)
            catalog.profiles.removeAll { $0.id == original.id }
            if catalog.selectedID == original.id { catalog.selectedID = AdvisorProvider.deepSeek.id }
            try catalog.save()
            dismiss()
          } catch { errorMessage = error.localizedDescription }
        }
      }
    }
  }

  private func save() {
    do {
      let provider = try AdvisorProvider(id: original.id, name: name, baseURL: address, model: model).validated()
      var catalog = try AdvisorProviders.load()
      guard isNew || catalog.profiles.contains(original) else { throw RelayError("配置已更改，请重新打开此服务。") }
      let changedAddress = !isNew && provider.baseURL != original.baseURL
      if isNew && key.isEmpty { throw RelayError("请输入此服务的 API Key。") }
      if changedAddress && key.isEmpty { throw RelayError("地址已更改，请输入该地址的 API Key。") }
      if !key.isEmpty { try AdvisorCredential.save(key, for: provider) }
      if changedAddress { try AdvisorCredential.remove(for: original) }
      if let index = catalog.profiles.firstIndex(where: { $0.id == provider.id }) { catalog.profiles[index] = provider }
      else { catalog.profiles.append(provider) }
      if isNew { catalog.selectedID = provider.id }
      try catalog.save()
      key = ""
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}
