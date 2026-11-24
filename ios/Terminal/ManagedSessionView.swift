import SwiftUI
import UniformTypeIdentifiers

enum ManagedMode: String, CaseIterable, Codable {
  case observe, menu, assist

  var title: String {
    switch self {
    case .observe: return "仅记录"
    case .menu: return "低风险菜单"
    case .assist: return "协助回复"
    }
  }

  var explanation: String {
    switch self {
    case .observe: return "记录待答问题和建议，交给你在终端处理。"
    case .menu: return "自动选择并提交明确的低风险数字菜单项。其他问题留待你确认。"
    case .assist: return "自动处理低风险菜单。语言、格式或详略有可单键提交的选项时，节点可代选。需要输入文字时，提供草稿供你复制并提交。"
    }
  }
}

enum ManagedStyle: String, CaseIterable, Codable {
  case cautious, balanced, concise

  var title: String {
    switch self {
    case .cautious: return "谨慎"
    case .balanced: return "均衡"
    case .concise: return "简洁"
    }
  }

  var explanation: String {
    switch self {
    case .cautious: return "优先保守、可逆的选择。"
    case .balanced: return "结合当前目标和风险权衡选项。"
    case .concise: return "简短说明理由，尽量精简草稿。"
    }
  }
}

enum ManagedAction: Equatable {
  case status, enable(ManagedMode, ManagedStyle), disable, forget

  var wireValue: String {
    switch self {
    case .status: return "status"
    case let .enable(mode, style): return "enable-\(mode.rawValue)-\(style.rawValue)"
    case .disable: return "disable"
    case .forget: return "forget"
    }
  }
}

struct ManagedStatus: Codable {
  struct Record: Codable {
    let at: Int
    let question: String
    let choice: String?
    let reason: String
    let outcome: String
    let mode: String?
    let style: String?
    let draft: String?
  }

  let enabled: Bool
  let state: String
  let mode: String
  let style: String
  let callsToday: Int
  let tokensToday: Int
  let memory: String
  let records: [Record]
}

@MainActor
struct ManagedSessionView: View {
  let client: ClientProfile
  let session: RemoteSession
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var controller: ManagedSessionController
  @StateObject private var keyStatus = AdvisorKeyStatus()
  @State private var editingKey = false
  @State private var status: ManagedStatus?
  @State private var mode = ManagedMode.menu
  @State private var style = ManagedStyle.balanced
  @State private var pending: ManagedAction?
  @State private var task: Task<Void, Never>?
  @State private var refreshPending = false
  @State private var errorMessage: String?
  @State private var confirmForget = false
  @State private var copiedDraft: String?

  private var polling: Bool { scenePhase == .active && status?.enabled == true }
  private var changing: Bool { pending != nil && pending != .status }

  private var target: ManagedSessionController.Target {
    .init(clientID: client.id, sessionID: session.id, name: session.name, instance: session.managedInstance ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        if session.managedVersion != 2 {
          Section {
            Text((session.managedVersion ?? 0) < 2 ? "手机托管需要节点协议 v2。请更新节点上的 tmux-link-agent，再刷新会话列表。" : "请更新手机 App 以使用此节点的托管协议。")
              .accessibilityIdentifier("managed.unsupported")
          }
        } else {
          AdvisorKeySection(editing: $editingKey).environmentObject(keyStatus)
          if let errorMessage {
            Section {
              Text(verbatim: errorMessage).foregroundStyle(.orange).textSelection(.enabled)
                .accessibilityIdentifier("managed.error")
              Button("重新读取节点状态") { request(.status) }.disabled(pending != nil)
            }
          }
          if let status {
            controls(status)
            usage(status)
            history(status.records)
            memory(status)
          } else if pending != nil {
            ProgressView("正在读取节点状态…")
          }
        }
      }
      .navigationTitle("托管 · " + session.name).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }.accessibilityIdentifier("managed.close")
        }
        if session.managedVersion == 2 {
          ToolbarItem(placement: .confirmationAction) {
            Button { request(.status) } label: { Image(systemName: "arrow.clockwise") }
              .disabled(pending != nil).accessibilityLabel("刷新托管状态")
              .accessibilityIdentifier("managed.refresh")
          }
        }
      }
      .confirmationDialog("清空本会话的记忆和最近记录？", isPresented: $confirmForget, titleVisibility: .visible) {
        Button("清空记忆和记录", role: .destructive) { request(.forget) }
        Button("取消", role: .cancel) {}
      } message: {
        Text("节点会保留过去 24 小时的用量。")
      }
    }
    .onAppear { request(.status) }
    .onChange(of: scenePhase) { if $0 == .active { request(.status) } }
    .task(id: polling) {
      guard polling else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(15)) }
        catch { return }
        if !Task.isCancelled, pending == nil { request(.status) }
      }
    }
    .onDisappear {
      refreshPending = false
      if pending == .status {
        task?.cancel()
        task = nil
        pending = nil
      }
    }
  }

  @ViewBuilder
  private func controls(_ status: ManagedStatus) -> some View {
    Section {
      LabeledContent("本会话托管", value: !status.enabled ? "已关闭" : (controller.targets.contains(target) ? "本机已启用" : "本机未接管"))
        .accessibilityIdentifier("managed.enabled")
      if status.state != "disabled" {
        LabeledContent("节点状态", value: stateTitle(status.state)).accessibilityIdentifier("managed.state")
      }
      if let notice = controller.notices[target] {
        Text(notice).font(.footnote).foregroundStyle(.orange)
      }
      if let pending {
        ProgressView(pending == .status ? "正在读取节点状态…" : "正在更新节点…")
          .accessibilityIdentifier("managed.pending")
      }
      if status.enabled {
        LabeledContent("当前配置", value: configuration(mode: status.mode, style: status.style))
        Button("暂停托管") { request(.disable) }
          .disabled(changing).accessibilityIdentifier("managed.disable")
      }
    } footer: {
      Text("打开 Tmux Link 时，iPhone 会处理本机启用的会话。锁屏或切到其他 App 时暂停，返回后继续。")
    }

    Section {
      Picker("模式", selection: $mode) {
        ForEach(ManagedMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }.accessibilityIdentifier("managed.mode")
      Text(mode.explanation).font(.footnote).foregroundStyle(.secondary)
      Picker("风格", selection: $style) {
        ForEach(ManagedStyle.allCases, id: \.self) { Text($0.title).tag($0) }
      }.accessibilityIdentifier("managed.style")
      Text(style.explanation).font(.footnote).foregroundStyle(.secondary)
      Button(status.enabled ? (controller.targets.contains(target) ? "保存调整" : "在这部 iPhone 接管") : "启用本会话托管") {
        request(.enable(mode, style))
      }
        .disabled(!keyStatus.saved || errorMessage != nil ||
                  (status.enabled && controller.targets.contains(target) && !hasChanges(status)))
        .accessibilityIdentifier(status.enabled ? "managed.save" : "managed.enable")
    } header: {
      Text("托管设置")
    } footer: {
      Text("iPhone 将当前问题、选项与简短记忆发送给 DeepSeek，密钥保存在本机钥匙串。节点记录选择与理由，并按所选模式处理。")
    }
    .disabled(changing)
  }

  private func usage(_ status: ManagedStatus) -> some View {
    Section("本会话 · 过去 24 小时") {
      LabeledContent("模型请求", value: "\(status.callsToday.formatted()) / 12").accessibilityIdentifier("managed.calls")
      LabeledContent("已上报 Token 用量", value: status.tokensToday.formatted()).accessibilityIdentifier("managed.tokens")
    }.monospacedDigit()
  }

  private func history(_ records: [ManagedStatus.Record]) -> some View {
    Section("最近记录") {
      if let newest = records.first {
        recordRow(newest, index: 0)
        if records.count > 1 {
          DisclosureGroup("更早的 \(records.count - 1) 条记录") {
            ForEach(records.indices.dropFirst(), id: \.self) { index in
              recordRow(records[index], index: index)
            }
          }
        }
      } else {
        Text("暂无托管记录").foregroundStyle(.secondary)
      }
    }
  }

  private func recordRow(_ record: ManagedStatus.Record, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(outcomeTitle(record.outcome)).font(.headline)
        Spacer()
        Text(Date(timeIntervalSince1970: TimeInterval(record.at)), format: .dateTime.month().day().hour().minute())
          .font(.caption).foregroundStyle(.secondary)
      }
      if !record.question.isEmpty { Text(verbatim: record.question).textSelection(.enabled) }
      if let choice = record.choice, !choice.isEmpty { Text(verbatim: "选择 · " + choice).font(.subheadline.weight(.medium)) }
      if !record.reason.isEmpty { Text(verbatim: record.reason).font(.subheadline).foregroundStyle(.secondary) }
      if let mode = record.mode, let style = record.style {
        Text(configuration(mode: mode, style: style)).font(.caption).foregroundStyle(.secondary)
      }
      if let draft = record.draft, !draft.isEmpty {
        Text("供手动使用的草稿").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Text(verbatim: draft).textSelection(.enabled)
        Button {
          UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: draft]], options: [.localOnly: true])
          copiedDraft = draft
        } label: {
          Label(copiedDraft == draft ? "已复制草稿" : "复制草稿", systemImage: "doc.on.doc")
        }.buttonStyle(.borderless).accessibilityIdentifier("managed.draft.copy.\(index)")
      }
    }.padding(.vertical, 3).privacySensitive()
  }

  private func memory(_ status: ManagedStatus) -> some View {
    Section("托管记忆") {
      if status.memory.isEmpty {
        Text("此会话暂无记忆").foregroundStyle(.secondary)
      } else {
        Text(verbatim: status.memory).textSelection(.enabled).privacySensitive().accessibilityIdentifier("managed.memory")
      }
      Button("清空记忆和记录", role: .destructive) { confirmForget = true }
        .disabled(changing || errorMessage != nil || (status.memory.isEmpty && status.records.isEmpty))
        .accessibilityIdentifier("managed.forget")
    }
  }

  private func hasChanges(_ status: ManagedStatus) -> Bool {
    mode.rawValue != status.mode || style.rawValue != status.style
  }

  private func request(_ action: ManagedAction) {
    guard session.managedVersion == 2 else { return }
    guard let instance = session.managedInstance, !instance.isEmpty else {
      errorMessage = "缺少会话实例标识，请返回会话列表刷新。"
      return
    }
    // A manual change takes precedence over a read-only poll.
    if pending == .status, action != .status {
      task?.cancel()
      pending = nil
    }
    guard pending == nil else {
      if action == .status { refreshPending = true }
      return
    }
    if action == .disable { controller.remove(target) }
    pending = action
    errorMessage = nil
    task = Task {
      do {
        if action != .status {
          let current = try await SessionDirectory.fetch(client)
          guard current.contains(where: {
            $0.id == session.id && $0.name == session.name && $0.managedVersion == 2 && $0.managedInstance == instance
          }) else {
            throw RelayError("此会话已关闭、更名或实例已更换，请返回会话列表刷新。")
          }
        }
        try Task.checkCancellation()
        let fresh = try await TerminalTransport.managed(client, sessionID: session.id, action: action, instance: instance)
        try Task.checkCancellation()
        if action != .status || status.map(hasChanges) != true {
          mode = ManagedMode(rawValue: fresh.mode) ?? .menu
          style = ManagedStyle(rawValue: fresh.style) ?? .balanced
        }
        status = fresh
        if fresh.enabled {
          if case .enable = action { controller.enable(target) }
        } else { controller.remove(target) }
        if action == .forget { copiedDraft = nil }
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = error.localizedDescription
      }
      guard !Task.isCancelled else { return }
      pending = nil
      task = nil
      if refreshPending {
        refreshPending = false
        request(.status)
      }
    }
  }

  private func configuration(mode: String, style: String) -> String {
    (ManagedMode(rawValue: mode)?.title ?? mode) + " · " + (ManagedStyle(rawValue: style)?.title ?? style)
  }

  private func stateTitle(_ state: String) -> String {
    switch state {
    case "disabled": return "已关闭"
    case "watching": return "等待新问题"
    case "analyzing": return "正在分析"
    case "needsConfirmation": return "待人工确认"
    case "budgetReached": return "已达用量上限"
    case "error": return "节点出错"
    default: return state
    }
  }

  private func outcomeTitle(_ outcome: String) -> String {
    switch outcome {
    case "applied": return "已提交"
    case "observed": return "已记录"
    case "needsConfirmation": return "待人工确认"
    case "failed": return "未成功"
    case "interrupted": return "已中断"
    default: return outcome
    }
  }
}
