import Darwin
import SwiftUI

struct ClientProfile: Codable, Hashable, Identifiable {
  var id = UUID()
  var name = ""
  var host = "bj.lander.work"
  var port: UInt16 = 443
  var route = ""
  var user = ""
  var pin = ""

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
}

enum SessionDirectory {
  static func fetch(_ client: ClientProfile) async throws -> [RemoteSession] {
    try await Task.detached(priority: .userInitiated) {
      let seed = try Identity.load().rawRepresentation
      var pair: [Int32] = [-1, -1]
      guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      let reader = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
      let worker = pair[1]
      let transport = Task.detached { () -> String? in
        let error = seed.withUnsafeBytes {
          tl_open(
            worker, client.endpoint, client.port, client.user, client.pin,
            $0.bindMemory(to: UInt8.self).baseAddress!, -2)
        }
        guard let error else { return nil }
        defer { tl_free_error(error) }
        return String(cString: error)
      }
      let data = try reader.readToEnd() ?? Data()
      if let message = await transport.value {
        throw NSError(domain: "SSH", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
      }
      return try JSONDecoder().decode([RemoteSession].self, from: data)
    }.value
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
      let host = defaults.string(forKey: "公网中心地址") ?? "bj.lander.work"
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
    clients.removeAll { $0.id == id }
    persist()
  }
}

private let mint = Color(red: 0.47, green: 0.91, blue: 0.79)
private let ink = Color(red: 0.045, green: 0.08, blue: 0.10)
private let panel = Color(red: 0.08, green: 0.13, blue: 0.15)

struct Workspace: View {
  @StateObject private var store = ProfileStore()
  @State private var editor: ClientProfile?
  @State private var message: String?
  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(store.clients) { client in
            NavigationLink(value: client) {
              HStack(spacing: 14) {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 5) {
                  Text(client.name).font(.headline)
                  Text(
                    client.user + " · " + client.host
                      + (client.route.isEmpty ? "" : " / " + client.route)
                  )
                  .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
              }.padding(.vertical, 8)
            }.swipeActions(allowsFullSwipe: false) {
              Button("删除", role: .destructive) { store.remove(client.id) }
              Button("编辑") { editor = client }.tint(.blue)
            }.contextMenu { Button("编辑客户端") { editor = client } }
          }
          Button {
            editor = ClientProfile()
          } label: {
            Label("添加客户端", systemImage: "plus")
          }
        } header: {
          Text("客户端  ·  " + String(store.clients.count)).font(.caption.monospaced())
        }
        .listRowBackground(panel)
      }
      .scrollContentBackground(.hidden).background(ink).navigationTitle("Tmux Link")
      .toolbar {
        Button {
          do {
            UIPasteboard.general.string = try Identity.publicLine()
            message = "SSH 公钥已复制"
          } catch { message = error.localizedDescription }
        } label: {
          Image(systemName: "key")
        }.accessibilityLabel("复制手机 SSH 公钥")
      }
      .navigationDestination(for: ClientProfile.self) { Sessions(client: $0) }
    }
    .tint(mint).preferredColorScheme(.dark)
    .sheet(item: $editor) { client in ProfileEditor(client: client, save: store.save) }
    .alert(
      message ?? "",
      isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    ) { Button("好") {} }
  }
}

private struct ProfileEditor: View {
  @Environment(\.dismiss) var dismiss
  @State var client: ClientProfile
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
              save(client)
              dismiss()
            }.disabled(!client.valid || (UInt16(port) ?? 0) == 0)
          }
        }
    }.preferredColorScheme(.dark).tint(mint)
  }
}

private struct Sessions: View {
  let client: ClientProfile
  @State private var sessions: [RemoteSession] = []
  @State private var failure: String?
  @State private var loading = true
  @State private var revision = 0
  var body: some View {
    List {
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
            TerminalView(client: client, session: session).navigationTitle(session.name)
          } label: {
            Label {
              Text(session.name).font(.body.monospaced()).padding(.vertical, 7)
            } icon: {
              Image(systemName: "rectangle.split.2x1").foregroundStyle(mint)
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
}

private struct TerminalView: UIViewControllerRepresentable {
  let client: ClientProfile
  let session: RemoteSession?
  func makeUIViewController(context: Context) -> Screen {
    Screen(client: client, session: session)
  }
  func updateUIViewController(_ controller: Screen, context: Context) {}
  static func dismantleUIViewController(_ controller: Screen, coordinator: ()) { controller.stop() }
}
