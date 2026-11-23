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

struct RemoteSession: Codable, Hashable, Identifiable {
  let id: Int64
  let name: String
  var touchPaging: Bool? = nil
  var directory: String? = nil
  var snapshot: Bool? = nil
}

enum SessionDirectory {
  static func fetch(_ client: ClientProfile) async throws -> [RemoteSession] {
    try await TerminalTransport.list(client)
  }

  static func snapshot(_ candidate: RemoteSession, client: ClientProfile) async throws -> DecisionSnapshot {
    guard candidate.snapshot == true else {
      throw RelayError("请升级这台机器的 agent 以批量读取。也可进入会话，在右侧快捷栏点「决策」。")
    }
    let pane = try await TerminalTransport.snapshot(client, sessionID: candidate.id)
    guard pane.id == candidate.id, pane.name == candidate.name else {
      throw RelayError("会话已更名或关闭，请刷新列表。")
    }
    return DecisionSnapshot(id: pane.id, name: pane.name, text: pane.text, context: pane.context)
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
  @StateObject private var store = ProfileStore()
  @State private var path: [ClientProfile] = []
  @State private var editor: ClientProfile?
  @State private var pairing: HostPairing?
  @State private var importedID: UUID?
  @State private var message: String?
  var body: some View {
    NavigationStack(path: $path) {
      clientList
        .scrollContentBackground(.hidden).background(ink).navigationTitle("Tmux Link")
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: copyKey) { Image(systemName: "key") }
              .accessibilityLabel("复制手机 SSH 公钥")
          }
        }
        .navigationDestination(for: ClientProfile.self) { Sessions(client: $0) }
    }
    .tint(mint).preferredColorScheme(.dark)
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
    guard editor == nil, pairing == nil, message == nil, let request = clientLinks.takeNext() else { return }
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

private struct Sessions: View {
  let client: ClientProfile
  @State private var sessions: [RemoteSession] = []
  @State private var failure: String?
  @State private var loading = true
  @State private var revision = 0
  @State private var showingAdvisor = false
  @State private var pendingSelection: AdvisorSelection?
  @State private var advisorDestination: AdvisorSelection?

  private var advisorNotice: String? {
    if loading { return "正在读取会话…" }
    if failure != nil { return "会话列表读取失败，请返回列表刷新。" }
    return sessions.isEmpty ? "这个客户端暂无会话。" : nil
  }

  var body: some View {
    List {
      Section {
        Button { showingAdvisor = true } label: {
          Label("查看待答问题", systemImage: "bubble.left.and.text.bubble.right")
        }
        .accessibilityIdentifier("sessions.advisor")
      }.listRowBackground(panel)
      Section {
        if loading {
          ProgressView("正在读取会话…")
        } else if let failure {
          Text(failure).font(.callout).textSelection(.enabled)
          NavigationLink("打开兼容终端") { TerminalView(client: client, session: nil) }
        } else if sessions.isEmpty {
          Text("暂无会话").foregroundStyle(.secondary)
        }
        ForEach(sessions) { session in
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
              Image(systemName: "rectangle.split.2x1").foregroundStyle(mint)
            }
          }.contextMenu {
            Button("复制会话名称") { UIPasteboard.general.string = session.name }
            if let directory = session.directory, !directory.isEmpty {
              Button("复制工作目录") { UIPasteboard.general.string = directory }
            }
          }
        }
      } header: {
        Text("tmux 会话").font(.caption.monospaced())
      }.listRowBackground(panel)
    }.scrollContentBackground(.hidden).background(ink).navigationTitle(client.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        Button {
          revision += 1
        } label: {
          Image(systemName: "arrow.clockwise")
        }.accessibilityLabel("刷新会话")
      }
      .sheet(isPresented: $showingAdvisor, onDismiss: {
        if let pendingSelection {
          advisorDestination = pendingSelection
          self.pendingSelection = nil
        }
      }) {
        SessionAdvisorView(
          sessions: sessions, notice: advisorNotice,
          capture: { try await SessionDirectory.snapshot($0, client: client) }, open: openFromAdvisor)
          .preferredColorScheme(.dark).tint(mint)
      }
      .navigationDestination(isPresented: Binding(
        get: { advisorDestination != nil }, set: { if !$0 { advisorDestination = nil } })
      ) {
        advisorDestination?.terminal
      }
      .task(id: revision) {
        loading = true
        failure = nil
        sessions = []
        do {
          let items = try await SessionDirectory.fetch(client)
          try Task.checkCancellation()
          sessions = items
        } catch {
          guard !Task.isCancelled else { return }
          failure = error.localizedDescription
        }
        loading = false
      }
  }

  @MainActor
  private func openFromAdvisor(_ candidate: RemoteSession) async throws -> Bool {
    let current = try await SessionDirectory.fetch(client)
    try Task.checkCancellation()
    guard showingAdvisor else { throw CancellationError() }
    sessions = current
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
      let besideIsland = inCutout && geometry.size.width < geometry.size.height && IslandHardware.supportedDevice
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
        .overlay(alignment: besideIsland ? .topLeading : .topTrailing) {
          if let reading = status.reading {
            // iOS exposes the top inset but no frame for the camera housing.
            // Reserve its center and anchor the status at the inner edge of the free space.
            statusButton(reading, besideIsland: besideIsland)
              .padding(.leading, besideIsland ? geometry.size.width / 2 + max(64, top + 4) : 0)
              .padding(.trailing, cornerInset)
              .padding(.top, besideIsland ? max(0, (top - 44) / 2) : 1)
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

  private func statusButton(_ reading: TerminalActivityState, besideIsland: Bool) -> some View {
    Button {
      var lines = [reading.phase.title]
      if reading.phase == .ready {
        lines.append(reading.mtls ? "mTLS · SSH" : "SSH")
        lines.append("RTT " + reading.latencyText)
      }
      detail = lines.joined(separator: "\n")
    } label: {
      HStack(spacing: 4) {
        Circle().fill(reading.phase == .ready && !reading.timedOut ? mint : .orange)
          .frame(width: 6, height: 6)
        Text(reading.phase == .ready ? reading.latencyText : reading.phase.title)
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .padding(.horizontal, besideIsland ? 4 : 8)
      .frame(minWidth: 44, minHeight: 44, alignment: besideIsland ? .leading : .top)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).accessibilityLabel("连接详情")
    .accessibilityValue(accessibilityValue(reading)).accessibilityIdentifier("terminal.status.details")
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
