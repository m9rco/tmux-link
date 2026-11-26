import CoreTransferable
import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct ClientProfile: Codable, Hashable, Identifiable {
  var id = UUID()
  var name = ""
  var host = "center.example.com"
  var port: UInt16 = 443
  var route = ""
  var user = ""
  var pin = ""
  var requireMTLS: Bool?
  var importedIdentity: Bool?

  var relayHost: String {
    if host.contains("://") { return URLComponents(string: host)?.host?.lowercased() ?? "" }
    return host.lowercased()
  }

  var endpoint: String {
    guard !route.isEmpty else { return host }
    var url = URLComponents()
    url.scheme = "wss"
    url.host = host
    url.port = Int(port)
    url.path = "/tmux-link/" + route
    return url.string ?? ""
  }
  var valid: Bool {
    guard !name.isEmpty, !user.isEmpty, pin.hasPrefix("SHA256:"), port > 0, !host.isEmpty else {
      return false
    }
    // Preserve legacy explicit WebSocket URLs. Named routes use a host without a scheme.
    if host.hasPrefix("wss://") || host.hasPrefix("ws://") {
      return route.isEmpty && URLComponents(string: host)?.host != nil
    }
    return !host.contains(where: { $0.isWhitespace || "/?#@".contains($0) })
      && route.utf8.count <= 64
      && route.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
          || $0 == 95
      }
  }
}

enum SessionDirectory {
  static func fetch(_ client: ClientProfile) async throws -> [RemoteSession] {
    try await TerminalTransport.list(client)
  }

  static func snapshot(_ candidate: RemoteSession, client: ClientProfile) async throws -> DecisionSnapshot {
    guard let version = candidate.negotiatedSnapshotVersion else {
      throw RelayError("请升级这台机器的 agent 以批量读取。也可进入会话，在右侧快捷栏点「决策」。")
    }
    return try await TerminalTransport.snapshot(client, session: candidate, version: version)
  }
}

final class ProfileStore: ObservableObject {
  @Published private(set) var clients: [ClientProfile]
  private let defaults: UserDefaults
  init(_ defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: "clients.v1") {
      clients = (try? JSONDecoder().decode([ClientProfile].self, from: data)) ?? []
    } else if let pin = defaults.string(forKey: "内网 SSH 主机指纹 SHA256:…"),
      let user = defaults.string(forKey: "远程用户名") ?? defaults.string(forKey: "Linux 用户名")
    {
      let host = defaults.string(forKey: "公网中心地址") ?? "center.example.com"
      clients = [
        ClientProfile(
          name: user + " @ " + host, host: host,
          port: UInt16(defaults.string(forKey: "端口") ?? "") ?? 443, user: user, pin: pin)
      ]
      persist()
    } else {
      clients = []
    }
  }
  private func persist() { defaults.set(try? JSONEncoder().encode(clients), forKey: "clients.v1") }
  func save(_ client: ClientProfile) {
    if let i = clients.firstIndex(where: { $0.id == client.id }) {
      clients[i] = client
    } else {
      clients.append(client)
    }
    persist()
  }
  func remove(_ id: UUID) {
    RelayIdentity.remove(id)
    clients.removeAll { $0.id == id }
    persist()
  }
}

private let mint = Color(red: 0.47, green: 0.91, blue: 0.79)
private let ink = Color(red: 0.045, green: 0.08, blue: 0.10)
private let panel = Color(red: 0.08, green: 0.13, blue: 0.15)

final class WorkspaceActivity: ObservableObject {
  @Published var isActive = false
}

private enum SessionListAvailable: EnvironmentKey {
  static let defaultValue = true
}

private extension EnvironmentValues {
  var sessionListAvailable: Bool {
    get { self[SessionListAvailable.self] }
    set { self[SessionListAvailable.self] = newValue }
  }
}

final class EnrollmentStatus: ObservableObject {
  @Published var error: String?
}

struct PastedClientConfiguration: Transferable {
  let text: String

  static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation(importing: { (text: String) in Self(text: text) })
    ProxyRepresentation(importing: { (url: URL) in Self(text: url.absoluteString) })
  }
}

final class ClientImportLinks: ObservableObject {
  enum Request {
    case review(ClientProfile)
    case pair(HostPairing)
    case invalid(String)
  }

  @Published private(set) var requests: [Request] = []

  func open(_ url: URL) {
    guard url.scheme?.lowercased() == "tmuxlink" else { return }
    do {
      if url.host == "pair" { requests.append(.pair(try HostPairing.parse(url.absoluteString))) }
      else { requests.append(.review(try ClientTransfer.parse(url.absoluteString))) }
    } catch {
      requests.append(.invalid(error.localizedDescription))
    }
  }

  func takeNext() -> Request? {
    requests.isEmpty ? nil : requests.removeFirst()
  }
}

struct Workspace: View {
  @ObservedObject var enrollment = EnrollmentStatus()
  @ObservedObject var clientLinks = ClientImportLinks()
  @ObservedObject var activity = WorkspaceActivity()
  @StateObject private var store = ProfileStore()
  @StateObject private var managed = ManagedSessionController()
  @State private var path: [ClientProfile] = []
  @State private var editor: ClientProfile?
  @State private var pairing: HostPairing?
  @State private var showingProviders = false
  @State private var importedID: UUID?
  @State private var message: String?
  var body: some View {
    NavigationStack(path: $path) {
      clientList
        .scrollContentBackground(.hidden).background(ink).navigationTitle("Tmux Link")
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
              Button { showingProviders = true } label: { Label("模型服务", systemImage: "slider.horizontal.3") }
              Button(action: copyKey) { Label("复制手机 SSH 公钥", systemImage: "key") }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("工作区设置")
          }
        }
        .navigationDestination(for: ClientProfile.self) { Sessions(client: $0).id($0) }
    }
    .tint(mint).preferredColorScheme(.dark)
    .environment(\.sessionListAvailable, activity.isActive && editor == nil && pairing == nil && !showingProviders && message == nil)
    .environmentObject(managed)
    .onReceive(store.$clients) { managed.updateClients($0) }
    .onReceive(activity.$isActive) {
      if $0 { managed.setActive(UIApplication.shared.isProtectedDataAvailable) } else { managed.leaveForeground() }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
      managed.setActive(false)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
      if activity.isActive { managed.setActive(true) }
    }
    .onReceive(NotificationCenter.default.publisher(for: AdvisorCredential.changed)) { _ in managed.credentialChanged() }
    .onReceive(enrollment.$error) { if let error = $0 { message = error } }
    .task(id: clientLinks.requests.count) { reviewNextLink() }
    .onChange(of: message) { if $0 == nil { reviewNextLink() } }
    .sheet(
      item: $editor,
      onDismiss: {
        importedID = nil
        reviewNextLink()
      }
    ) { draft in
      ProfileEditor(client: draft) { client in
        store.save(client)
        if client.id == importedID { path = [client] }
      }
    }
    .sheet(item: $pairing, onDismiss: { reviewNextLink() }) { offer in
      HostPairingReview(pairing: offer) { client in
        store.save(client)
        path = [client]
      }
    }
    .sheet(isPresented: $showingProviders, onDismiss: { reviewNextLink() }) { AdvisorProviderSettings() }
    .alert(
      message ?? "",
      isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    ) { Button("好") {} }
  }

  private var clientList: some View {
    List {
      Section {
        ForEach(store.clients) { client in
          NavigationLink(value: client) { ClientRow(client: client) }
            .swipeActions(allowsFullSwipe: false) {
              Button("删除", role: .destructive) { store.remove(client.id) }
              Button("编辑") { editor = client }.tint(.blue)
            }
            .contextMenu {
              Button("编辑客户端") { editor = client }
              Button("复制客户端配置") { copyConfiguration(client) }
                .accessibilityIdentifier("clients.copy.configuration")
            }
        }
        Button {
          editor = ClientProfile()
        } label: {
          Label("添加客户端", systemImage: "plus")
        }
        LabeledContent("导入客户端配置") {
          PasteButton(payloadType: PastedClientConfiguration.self, onPaste: importConfiguration)
            .accessibilityLabel("粘贴导入客户端配置")
            .accessibilityIdentifier("clients.import.paste")
        }
      } header: {
        Text("客户端  ·  \(store.clients.count)").font(.caption.monospaced())
      }
      .listRowBackground(panel)
    }
  }

  private func importConfiguration(_ items: [PastedClientConfiguration]) {
    guard items.count == 1, let item = items.first else {
      message = "请每次粘贴一个客户端配置"
      return
    }
    do {
      if let url = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)),
        url.scheme == "tmuxlink", url.host == "pair" {
        pairing = try HostPairing.parse(url.absoluteString)
      } else {
        review(try ClientTransfer.parse(item.text))
      }
    } catch {
      message = error.localizedDescription
    }
  }

  private func review(_ draft: ClientProfile) {
    importedID = draft.id
    editor = draft
  }

  private func reviewNextLink() {
    guard editor == nil, pairing == nil, !showingProviders, message == nil, let request = clientLinks.takeNext() else { return }
    switch request {
    case .review(let draft): review(draft)
    case .pair(let offer): pairing = offer
    case .invalid(let error): message = error
    }
  }

  private func copyConfiguration(_ client: ClientProfile) {
    do {
      var share = client
      if RelayIdentity.requiresDeviceCertificate(client) { share.requireMTLS = true }
      UIPasteboard.general.string = try ClientTransfer.link(for: share)
      message = "客户端配置已复制"
    } catch { message = error.localizedDescription }
  }

  private func copyKey() {
    do {
      UIPasteboard.general.string = try Identity.publicLine()
      message = "SSH 公钥已复制"
    } catch { message = error.localizedDescription }
  }
}

private struct ClientRow: View {
  let client: ClientProfile
  private var address: String {
    let suffix = client.route.isEmpty ? "" : " / " + client.route
    return "\(client.user) · \(client.host)\(suffix)"
  }
  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "server.rack").font(.title2).foregroundStyle(mint)
      VStack(alignment: .leading, spacing: 5) {
        Text(client.name).font(.headline)
        Text(address).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
      }
    }.padding(.vertical, 8)
  }
}

private struct ProfileEditor: View {
  @Environment(\.dismiss) var dismiss
  @State var client: ClientProfile
  @State private var pickingCertificate = false
  @State private var certificateFile: Data?
  @State private var passphrase = ""
  @State private var imported: RelayCredential?
  @State private var certificateError: String?
  @State private var port: String
  let save: (ClientProfile) -> Void
  init(client: ClientProfile, save: @escaping (ClientProfile) -> Void) {
    _client = State(initialValue: client)
    _port = State(initialValue: String(client.port))
    self.save = save
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("客户端") {
          TextField("名称", text: $client.name)
          TextField("远程用户名", text: $client.user)
        }
        Section("中转入口") {
          TextField("服务器地址", text: $client.host).keyboardType(.URL)
          TextField("端口", text: $port).keyboardType(.numberPad)
          TextField("客户端路由（默认留空）", text: $client.route)
        }
        Section("设备认证") {
          Toggle(
            "要求 mTLS",
            isOn: Binding(
              get: { client.requireMTLS == true },
              set: { client.requireMTLS = $0 }))
          Button(client.importedIdentity == true ? "更换客户端证书" : "导入客户端证书 (.p12)") {
            pickingCertificate = true
          }
          if client.importedIdentity == true {
            Button("移除导入的证书", role: .destructive) {
              client.importedIdentity = nil
              imported = nil
            }
          }
        }
        Section("内网 SSH 主机指纹") {
          TextField("SHA256:…", text: $client.pin, axis: .vertical).font(.body.monospaced())
        }
      }.textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("客户端配置").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") {
              guard let value = UInt16(port) else { return }
              client.port = value
              do {
                if let imported {
                  guard imported.host == client.relayHost else {
                    throw RelayError("服务器地址已更改，请重新导入证书")
                  }
                  try RelayIdentity.save(imported, for: client.id)
                } else if client.importedIdentity != true {
                  RelayIdentity.remove(client.id)
                }
                save(client)
                dismiss()
              } catch { certificateError = error.localizedDescription }
            }.disabled(!client.valid || (UInt16(port) ?? 0) == 0)
          }
        }
    }.preferredColorScheme(.dark).tint(mint)
      .fileImporter(
        isPresented: $pickingCertificate,
        allowedContentTypes: [
          UTType(filenameExtension: "p12") ?? .data,
          UTType(filenameExtension: "pfx") ?? .data,
        ]
      ) { result in
        do {
          let url = try result.get()
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          certificateFile = try RelayIdentity.limitedFile(url)
        } catch { certificateError = error.localizedDescription }
      }
      .alert("证书密码", isPresented: Binding(get: { certificateFile != nil }, set: { _ in })) {
        SecureField("PKCS#12 密码", text: $passphrase)
        Button("取消", role: .cancel) {
          certificateFile = nil
          passphrase = ""
        }
        Button("导入") {
          defer {
            certificateFile = nil
            passphrase = ""
          }
          guard let file = certificateFile else { return }
          do {
            imported = try RelayCredential.importPKCS12(
              file, password: passphrase, host: client.relayHost)
            client.importedIdentity = true
            client.requireMTLS = true
          } catch { certificateError = error.localizedDescription }
        }
      }
      .alert(
        certificateError ?? "",
        isPresented: Binding(
          get: { certificateError != nil },
          set: { if !$0 { certificateError = nil } })
      ) { Button("好") {} }
  }
}

@MainActor
final class SessionListModel: ObservableObject {
  enum Activity: Equatable {
    case running, waiting
    var title: String { self == .running ? "正在处理或输出" : "正在等待输入" }
  }
  private struct Sample {
    let instance: String
    let value: String
  }
  @Published private(set) var sessions: [RemoteSession] = []
  @Published private(set) var indicators: [Int64: Activity] = [:]
  @Published private(set) var failure: String?
  @Published private(set) var loading = true
  private var revision = 0
  private var fetching = false
  private var samples: [Int64: Sample] = [:]
  private let fetch: (ClientProfile) async throws -> [RemoteSession]

  init(fetch: @escaping (ClientProfile) async throws -> [RemoteSession] = SessionDirectory.fetch) {
    self.fetch = fetch
  }

  func refresh(_ client: ClientProfile, quietly: Bool = false) async -> [RemoteSession]? {
    if quietly && fetching { return nil }
    revision &+= 1
    let request = revision
    fetching = true
    if !quietly && !loading { loading = true }
    defer {
      if request == revision {
        fetching = false
        if loading { loading = false }
      }
    }
    do {
      let items = try await fetch(client)
      guard request == revision, !Task.isCancelled else { return nil }
      recordActivity(items)
      // Samples are transient. Publishing a new list for every changing token
      // would redraw rows even while their visible running state stays the same.
      var sorted = items.map { item -> RemoteSession in
        var row = item
        row.activitySample = nil
        return row
      }
      sorted.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      if sessions != sorted { sessions = sorted }
      if failure != nil { failure = nil }
      return sessions
    } catch {
      if request == revision, !Task.isCancelled {
        clearActivity()
        failure = error.localizedDescription
      }
      return nil
    }
  }

  func clearActivity() {
    samples.removeAll()
    if !indicators.isEmpty { indicators = [:] }
  }

  private func recordActivity(_ sessions: [RemoteSession]) {
    var observed: [Int64: Sample] = [:]
    var next: [Int64: Activity] = [:]
    for session in sessions {
      switch session.activitySignal {
      case .running: next[session.id] = .running
      case .waiting: next[session.id] = .waiting
      case .observing:
        guard let instance = session.managedInstance, !instance.isEmpty,
              let sample = session.activitySample, !sample.isEmpty else { continue }
        observed[session.id] = Sample(instance: instance, value: sample)
        if let previous = samples[session.id], previous.instance == instance, previous.value != sample {
          next[session.id] = .running
        }
      case .idle, nil: break
      }
    }
    samples = observed
    if indicators != next { indicators = next }
  }

  var activityPollInterval: Duration? {
    guard sessions.contains(where: { $0.activitySignal != nil })
    else { return nil }
    if failure != nil { return .seconds(20) }
    return sessions.contains(where: { $0.activitySignal == .observing || $0.activitySignal == .running }) ? .seconds(4) : .seconds(8)
  }

  func matching(_ query: String) -> [RemoteSession] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return sessions }
    return sessions.filter {
      $0.name.localizedCaseInsensitiveContains(term) || $0.directory?.localizedCaseInsensitiveContains(term) == true
    }
  }
}

private struct Sessions: View {
  @EnvironmentObject private var managed: ManagedSessionController
  @Environment(\.sessionListAvailable) private var workspaceAvailable
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let client: ClientProfile
  @StateObject private var directory = SessionListModel()
  @State private var search = ""
  @State private var showingAdvisor = false
  @State private var managedSession: RemoteSession?
  @State private var pendingSelection: AdvisorSelection?
  @State private var advisorDestination: AdvisorSelection?
  @State private var onScreen = false

  private var observing: Bool {
    onScreen && workspaceAvailable && !showingAdvisor && managedSession == nil && pendingSelection == nil && advisorDestination == nil
  }
  private var polling: Bool { observing && directory.activityPollInterval != nil }

  private var advisorNotice: String? {
    if directory.loading && directory.sessions.isEmpty { return "正在读取会话…" }
    if directory.failure != nil && directory.sessions.isEmpty { return "会话列表读取失败，请返回列表刷新。" }
    return directory.sessions.isEmpty ? "这个客户端暂无会话。" : nil
  }

  var body: some View {
    let visibleSessions = directory.matching(search)
    List {
      Section {
        Button { showingAdvisor = true } label: {
          Label("查看待答问题", systemImage: "bubble.left.and.text.bubble.right")
        }
        .accessibilityIdentifier("sessions.advisor")
      }.listRowBackground(panel)
      Section {
        if directory.loading && directory.sessions.isEmpty {
          ProgressView("正在读取会话…")
        } else if let failure = directory.failure {
          Text(failure).font(.callout).textSelection(.enabled)
          if directory.sessions.isEmpty {
            NavigationLink("打开兼容终端") { TerminalView(client: client, session: nil) }
          } else {
            Text("显示上次读取的会话").font(.caption).foregroundStyle(.secondary)
          }
        } else if directory.sessions.isEmpty {
          Text("暂无会话").foregroundStyle(.secondary)
        } else if visibleSessions.isEmpty {
          Text("没有匹配的会话").foregroundStyle(.secondary)
        }
        ForEach(visibleSessions) { session in
          let activity = observing ? directory.indicators[session.id] : nil
          HStack(spacing: 12) {
            NavigationLink {
              TerminalView(client: client, session: session)
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 4) {
                  Text(session.name).font(.body.monospaced())
                  if let directory = session.directory, !directory.isEmpty {
                    Text(directory).font(.caption.monospaced()).foregroundStyle(.secondary)
                      .lineLimit(1).truncationMode(.middle)
                  }
                }.padding(.vertical, 7)
              } icon: {
                Group {
                  if activity == .running && !reduceMotion {
                    ProgressView().progressViewStyle(.circular).controlSize(.small).tint(mint)
                  } else {
                    Image(systemName: activity == .running ? "hourglass" : activity == .waiting ? "text.bubble" : "rectangle.split.2x1")
                      .foregroundStyle(activity == .waiting ? Color.secondary : mint)
                  }
                }.frame(width: 22, height: 22).accessibilityHidden(true)
              }
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(activity?.title ?? "").contextMenu {
              Button("复制会话名称") { UIPasteboard.general.string = session.name }
              if let directory = session.directory, !directory.isEmpty {
                Button("复制工作目录") { UIPasteboard.general.string = directory }
              }
            }
            Button { managedSession = session } label: {
              Text(isManaged(session) ? "托管中" : "托管").font(.subheadline.weight(.medium)).fixedSize()
                .frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.borderless)
              .accessibilityLabel((isManaged(session) ? "正在托管会话 " : "托管会话 ") + session.name)
              .accessibilityIdentifier("sessions.managed.\(session.id)")
          }
        }
      } header: {
        Text("tmux 会话").font(.caption.monospaced())
      }.listRowBackground(panel)
    }.scrollContentBackground(.hidden).background(ink).navigationTitle(client.name)
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "名称或工作目录")
      .refreshable { await refresh() }
      .toolbar {
        Button { Task { await refresh() } } label: {
          Image(systemName: "arrow.clockwise")
        }.disabled(directory.loading).accessibilityLabel("刷新会话")
      }
      .sheet(isPresented: $showingAdvisor, onDismiss: {
        if let pendingSelection {
          advisorDestination = pendingSelection
          self.pendingSelection = nil
        }
      }) {
        SessionAdvisorView(
          sessions: directory.sessions, notice: advisorNotice,
          capture: { try await SessionDirectory.snapshot($0, client: client) }, open: openFromAdvisor)
          .preferredColorScheme(.dark).tint(mint)
      }
      .sheet(item: $managedSession) { session in
        ManagedSessionView(client: client, session: session)
          .preferredColorScheme(.dark).tint(mint)
      }
      .navigationDestination(isPresented: Binding(
        get: { advisorDestination != nil }, set: { if !$0 { advisorDestination = nil } })
      ) {
        advisorDestination?.terminal
      }
      .onAppear { onScreen = true }
      .onDisappear { onScreen = false }
      .task(id: observing) {
        directory.clearActivity()
        if observing { await refresh() }
      }
      .task(id: polling) {
        guard polling else { return }
        while !Task.isCancelled, let interval = directory.activityPollInterval {
          do { try await Task.sleep(for: interval) } catch { return }
          guard !Task.isCancelled else { return }
          await refresh(quietly: true)
        }
      }
  }

  private func isManaged(_ session: RemoteSession) -> Bool {
    managed.targets.contains { $0.clientID == client.id && $0.sessionID == session.id && $0.instance == session.managedInstance }
  }

  @MainActor private func refresh(quietly: Bool = false) async {
    if let items = await directory.refresh(client, quietly: quietly) { managed.updateSessions(items, client: client) }
  }

  @MainActor
  private func openFromAdvisor(_ candidate: RemoteSession) async throws -> Bool {
    guard let current = await directory.refresh(client) else {
      try Task.checkCancellation()
      throw RelayError(directory.failure ?? "会话列表已刷新，请重试。")
    }
    try Task.checkCancellation()
    guard showingAdvisor else { throw CancellationError() }
    managed.updateSessions(current, client: client)
    guard let selection = AdvisorSelection(candidate, in: current, client: client) else { return false }
    pendingSelection = selection
    showingAdvisor = false
    return true
  }
}

@MainActor
final class TerminalNavigationStatus: ObservableObject {
  @Published private(set) var reading: TerminalActivityState?

  func update(_ reading: TerminalActivityState?) {
    if self.reading != reading { self.reading = reading }
  }
}

struct TerminalView: View {
  let client: ClientProfile
  let session: RemoteSession?
  @StateObject private var status: TerminalNavigationStatus
  @State private var detail: String?
  @Environment(\.dismiss) private var dismiss

  init(client: ClientProfile, session: RemoteSession?, status: TerminalNavigationStatus? = nil) {
    self.client = client
    self.session = session
    _status = StateObject(wrappedValue: status ?? TerminalNavigationStatus())
  }

  var body: some View {
    GeometryReader { geometry in
      let top = geometry.safeAreaInsets.top
      let inCutout = UIDevice.current.userInterfaceIdiom == .phone && top >= 44
      let cornerInset = inCutout ? top / 2 : 0
      TerminalController(client: client, session: session, status: status, leave: { dismiss() })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
          Text(session?.name ?? client.name)
            .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: inCutout ? geometry.size.width * 0.20 : max(0, geometry.size.width - 160),
                   alignment: inCutout ? .leading : .center)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: inCutout ? .leading : .center)
            .padding(.horizontal, cornerInset).padding(.top, 1)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
        }
        .overlay {
          if let reading = status.reading {
            TerminalStatusOverlay(reading: reading, value: accessibilityValue(reading)) {
              var lines = [reading.phase.title]
              if reading.phase == .ready {
                lines.append(reading.mtls ? "mTLS · SSH" : "SSH")
                lines.append("RTT " + reading.latencyText)
              }
              detail = lines.joined(separator: "\n")
            }
          }
        }
        .ignoresSafeArea(.container, edges: .vertical)
    }
      .ignoresSafeArea(.keyboard, edges: .bottom)
      .background(Color(uiColor: Screen.surface).ignoresSafeArea())
      .toolbar(.hidden, for: .navigationBar)
      .statusBarHidden(true)
      .persistentSystemOverlays(.hidden)
      .alert(
        "连接状态",
        isPresented: Binding(
          get: { detail != nil }, set: { if !$0 { detail = nil } })
      ) {
        Button("好") {}
      } message: {
        Text(detail ?? "")
      }
  }

  private func accessibilityValue(_ reading: TerminalActivityState) -> String {
    guard reading.phase == .ready else { return reading.phase.title }
    let description: String
    if reading.timedOut {
      description = "延迟测量超时"
    } else if let ms = reading.milliseconds {
      description = "会话往返延迟 " + String(ms) + " 毫秒"
    } else {
      description = "正在测量会话往返延迟"
    }
    return reading.phase.title + "，" + description
  }
}

// Keep the control above the terminal while letting all touches outside its bounds reach WebKit.
private struct TerminalStatusOverlay: UIViewRepresentable {
  let reading: TerminalActivityState
  let value: String
  let showDetails: () -> Void

  func makeUIView(context: Context) -> TerminalStatusControls { TerminalStatusControls() }

  func updateUIView(_ view: TerminalStatusControls, context: Context) {
    view.showDetails = showDetails
    view.update(reading, accessibilityValue: value)
  }
}

final class TerminalStatusControls: UIView {
  let button = UIButton(type: .system)
  var showDetails: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    button.accessibilityIdentifier = "terminal.status.details"
    button.accessibilityLabel = "连接详情"
    button.addTarget(self, action: #selector(open), for: .touchUpInside)
    addSubview(button)
  }

  required init?(coder: NSCoder) { nil }

  @objc private func open() { showDetails?() }

  func update(_ reading: TerminalActivityState, accessibilityValue: String) {
    var config = UIButton.Configuration.plain()
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
    config.baseForegroundColor = .secondaryLabel
    config.title = reading.phase == .ready ? reading.latencyText : reading.phase.title
    config.titleLineBreakMode = .byTruncatingTail
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var result = incoming
      result.font = UIFont.monospacedDigitSystemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
      return result
    }
    let tint: UIColor = reading.phase == .ready && !reading.timedOut ? .systemMint : .systemOrange
    config.image = UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 6))?
      .withTintColor(tint, renderingMode: .alwaysOriginal)
    config.imagePadding = 4
    button.configuration = config
    button.accessibilityValue = accessibilityValue
    setNeedsLayout()
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The SwiftUI navigation container may consume the top safe area. Position the touch
    // target using the window inset expressed in the overlay's own coordinate space.
    let top = window.map { convert(CGPoint(x: 0, y: $0.safeAreaInsets.top), from: $0).y - bounds.minY }
      ?? safeAreaInsets.top
    let available = bounds.inset(by: UIEdgeInsets(top: 0, left: safeAreaInsets.left,
                                                 bottom: 0, right: safeAreaInsets.right))
    button.frame = Self.buttonFrame(in: available, topInset: max(0, top),
                                    isPhone: traitCollection.userInterfaceIdiom == .phone,
                                    island: IslandHardware.supportedDevice, width: button.intrinsicContentSize.width)
  }

  static func buttonFrame(in bounds: CGRect, topInset: CGFloat, isPhone: Bool,
                          island: Bool, width: CGFloat) -> CGRect {
    let alongside = isPhone && island && bounds.width < bounds.height
    let top = alongside ? max(44, topInset) : topInset
    let corner = isPhone && top >= 44 ? top / 2 : 0
    let right = bounds.maxX - corner
    let left = alongside ? bounds.midX + max(64, top + 4) : bounds.minX
    let w = min(max(44, width), max(0, right - left))
    return CGRect(x: alongside ? left : right - w, y: bounds.minY + (alongside ? (top - 44) / 2 : 1),
                  width: w, height: 44)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    button.frame.contains(point)
  }
}

private struct TerminalController: UIViewControllerRepresentable {
  let client: ClientProfile
  let session: RemoteSession?
  let status: TerminalNavigationStatus
  let leave: () -> Void
  func makeUIViewController(context: Context) -> Screen {
    Screen(client: client, session: session, navigationStatus: status, leave: leave)
  }
  func updateUIViewController(_ controller: Screen, context: Context) {}
  static func dismantleUIViewController(_ controller: Screen, coordinator: ()) { controller.stop() }
}
