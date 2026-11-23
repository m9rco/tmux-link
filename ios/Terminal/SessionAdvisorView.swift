import SwiftUI

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

@MainActor
struct SessionAdvisorView: View {
  let sessions: [RemoteSession]
  let notice: String?
  let open: @MainActor (RemoteSession) async throws -> Bool

  private struct Reply {
    let message: String
    let choices: [RemoteSession]
  }

  private enum Work: Equatable { case asking, opening(Int64) }
  private enum Field { case question, key }
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focus: Field?
  @State private var question = ""
  @State private var autoOpen = false
  @State private var hasKey = false
  @State private var editingKey = false
  @State private var draftKey = ""
  @State private var keyError: String?
  @State private var reply: Reply?
  @State private var requestError: String?
  @State private var work: Work?
  @State private var task: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("例如：我想回到写 iOS 应用的会话", text: $question, axis: .vertical)
            .lineLimit(2...4).focused($focus, equals: .question).disabled(work != nil)
            .accessibilityIdentifier("advisor.question")
          Toggle("本次自动打开首选会话", isOn: $autoOpen)
            .disabled(work != nil).accessibilityIdentifier("advisor.autoOpen")
          if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
          if work != nil {
            Button(action: cancel) {
              HStack {
                ProgressView().controlSize(.small)
                Text(work == .asking ? "正在查找会话…" : "正在核对会话…")
                Spacer()
                Text("取消")
              }
            }.accessibilityLabel("取消请求").accessibilityIdentifier("advisor.cancel")
          } else {
            Button(action: ask) { Label("查找会话", systemImage: "magnifyingglass") }
              .disabled(!hasKey || editingKey || notice != nil || trimmedQuestion.isEmpty)
              .accessibilityIdentifier("advisor.submit")
          }
        } header: {
          Text("你想找哪个会话？")
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text("提交时，DeepSeek 会收到你的问题，以及此客户端的会话编号、名称和工作目录末级名称。")
            if sessions.count > SessionAdvisor.maxCandidates {
              Text("本次最多比较列表中的前 \(SessionAdvisor.maxCandidates) 个有效会话。")
            }
          }
        }

        if reply != nil || requestError != nil {
          Section("会话建议") {
            if let reply {
              Text(verbatim: reply.message).textSelection(.enabled)
                .accessibilityIdentifier("advisor.answer")
              ForEach(reply.choices) { candidate in
                if sessions.contains(where: { $0.id == candidate.id && $0.name == candidate.name }) {
                  Button { choose(candidate) } label: {
                    HStack {
                      Text(verbatim: candidate.name).font(.body.monospaced()).foregroundStyle(.primary)
                      Spacer()
                      if work == .opening(candidate.id) { ProgressView().controlSize(.small) }
                      else { Label("打开", systemImage: "arrow.up.right").font(.subheadline).fixedSize() }
                    }
                  }
                  .disabled(work != nil)
                  .accessibilityLabel("打开会话 " + candidate.name)
                  .accessibilityIdentifier("advisor.open." + String(candidate.id))
                }
              }
            }
            if let requestError {
              Text(verbatim: requestError).font(.callout).foregroundStyle(.orange)
                .accessibilityIdentifier("advisor.error")
            }
          }
        }
        keySection
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("会话助手").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            cancel()
            dismiss()
          }.accessibilityIdentifier("advisor.close")
        }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("完成") { focus = nil }
        }
      }
    }
    .onAppear {
      do { hasKey = try AdvisorCredential.load() != nil }
      catch { keyError = error.localizedDescription }
    }
    .onChange(of: question) { _ in
      reply = nil
      requestError = nil
    }
    .onDisappear {
      cancel()
      draftKey = ""
    }
  }

  private var keySection: some View {
    Section {
      if hasKey && !editingKey {
        Label("已保存 API Key", systemImage: "key.fill")
          .accessibilityIdentifier("advisor.key.saved")
        Button("更换密钥") {
          editingKey = true
          focus = .key
          keyError = nil
        }.accessibilityIdentifier("advisor.key.replace")
        Button("移除密钥", role: .destructive, action: removeKey)
          .accessibilityIdentifier("advisor.key.remove")
      } else {
        SecureField("DeepSeek API Key", text: $draftKey)
          .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
          .focused($focus, equals: .key).accessibilityIdentifier("advisor.key.input")
        Button("保存密钥", action: saveKey)
          .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("advisor.key.save")
        if editingKey {
          Button("取消更换") {
            editingKey = false
            draftKey = ""
            keyError = nil
            focus = nil
          }.accessibilityIdentifier("advisor.key.cancel")
        }
      }
      if let keyError {
        Text(verbatim: keyError).font(.callout).foregroundStyle(.orange)
          .accessibilityIdentifier("advisor.key.error")
      }
    } header: {
      Text("DeepSeek")
    } footer: {
      Text("API Key 保存在这台设备的钥匙串中。")
    }
    .disabled(work != nil)
  }

  private var trimmedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func saveKey() {
    do {
      try AdvisorCredential.save(draftKey.trimmingCharacters(in: .whitespacesAndNewlines))
      draftKey = ""
      editingKey = false
      hasKey = true
      keyError = nil
      requestError = nil
      focus = nil
    } catch { keyError = error.localizedDescription }
  }

  private func removeKey() {
    do {
      try AdvisorCredential.remove()
      hasKey = false
      keyError = nil
      reply = nil
      requestError = nil
    } catch { keyError = error.localizedDescription }
  }

  private func cancel() {
    task?.cancel()
    task = nil
    work = nil
  }

  private func run(_ operation: Work, action: @escaping @MainActor () async throws -> Void) {
    cancel()
    requestError = nil
    focus = nil
    work = operation
    task = Task {
      do {
        try Task.checkCancellation()
        try await action()
      } catch {
        guard !Task.isCancelled else { return }
        requestError = error.localizedDescription
      }
      guard !Task.isCancelled else { return }
      work = nil
      task = nil
    }
  }

  private func ask() {
    let prompt = trimmedQuestion
    let snapshot = sessions
    guard work == nil, !prompt.isEmpty, !snapshot.isEmpty else { return }
    let openFirst = autoOpen
    autoOpen = false
    reply = nil
    run(.asking) {
      guard let key = try AdvisorCredential.load() else {
        hasKey = false
        keyError = "请先保存 DeepSeek API Key。"
        return
      }
      let advice = try await SessionAdvisor.advise(prompt, sessions: snapshot, key: key)
      try Task.checkCancellation()
      let choices = advice.sessionIDs.compactMap { id in snapshot.first { $0.id == id } }
      reply = Reply(message: advice.message, choices: choices)
      if openFirst, let first = choices.first {
        work = .opening(first.id)
        try await openVerified(first)
      }
    }
  }

  private func choose(_ candidate: RemoteSession) {
    guard work == nil else { return }
    run(.opening(candidate.id)) { try await openVerified(candidate) }
  }

  private func openVerified(_ candidate: RemoteSession) async throws {
    let opened = try await open(candidate)
    try Task.checkCancellation()
    if !opened { requestError = "这个会话已关闭或更名。请重新查找，或打开其他建议。" }
  }
}
