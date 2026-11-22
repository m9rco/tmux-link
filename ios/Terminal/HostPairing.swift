import Foundation
import SwiftUI

struct HostPairing: Identifiable {
  let id: String
  let code: String
  let client: ClientProfile
  let approvalURL: String

  static func parse(_ text: String) throws -> Self {
    guard text.utf8.count <= 8192, let url = URLComponents(string: text),
      url.scheme == "tmuxlink", url.host == "pair", url.fragment == nil,
      url.user == nil, url.password == nil, (url.path.isEmpty || url.path == "/"),
      let items = url.queryItems, items.count == 7,
      Set(items.map(\.name)) == Set(["center", "port", "id", "code", "name", "user", "pin"])
    else { throw RelayError("配对链接格式无效") }
    let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    guard let id = fields["id"], let code = fields["code"],
      id.count == 32, code.count == 64,
      (id + code).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw RelayError("配对凭据无效") }
    let payload: [String: Any] = [
      "host": fields["center"] ?? "", "port": Int(fields["port"] ?? "") ?? 0,
      "name": fields["name"] ?? "", "user": fields["user"] ?? "",
      "pin": fields["pin"] ?? "", "requireMTLS": true,
    ]
    let json = try JSONSerialization.data(withJSONObject: payload)
    var client = try ClientTransfer.parse(String(decoding: json, as: UTF8.self))
    guard client.valid, !client.host.contains(":"), !client.host.contains("/") else {
      throw RelayError("配对链接中的服务器或主机配置无效")
    }
    var endpoint = URLComponents()
    endpoint.scheme = "wss"
    endpoint.host = client.host
    endpoint.port = Int(client.port)
    endpoint.path = "/tmux-link/pair"
    let approval = try endpoint.url.unwrap("配对入口无效").absoluteString
    endpoint.path = "/tmux-link/session/" + id
    client.host = try endpoint.url.unwrap("会话入口无效").absoluteString
    return Self(id: id, code: code, client: client, approvalURL: approval)
  }

  func approve() async throws -> ClientProfile {
    let key = try Identity.publicLine()
    guard let identity = try RelayIdentity.resolve(client) else {
      throw RelayError("请先给这台 iPhone 登记中心的设备证书，再确认配对")
    }
    let request = try JSONSerialization.data(withJSONObject: [
      "action": "approve", "code": code, "pin": client.pin, "phone_key": key,
    ])
    let json = String(decoding: request, as: UTF8.self)
    try await Task.detached(priority: .userInitiated) {
      let failure = approvalURL.withCString { url in
        id.withCString { id in
          json.withCString { message in
            identity.certificate.withUnsafeBytes { cert in
              identity.privateKey.withUnsafeBytes { secret in
                tl_approve_pairing(
                  url, id, message,
                  cert.bindMemory(to: UInt8.self).baseAddress, cert.count,
                  secret.bindMemory(to: UInt8.self).baseAddress, secret.count)
              }
            }
          }
        }
      }
      if let failure {
        let error = String(cString: failure)
        tl_free_error(failure)
        throw RelayError(error)
      }
    }.value
    return client
  }
}

private extension Optional {
  func unwrap(_ message: String) throws -> Wrapped {
    guard let self else { throw RelayError(message) }
    return self
  }
}

struct HostPairingReview: View {
  @Environment(\.dismiss) private var dismiss
  let pairing: HostPairing
  let save: (ClientProfile) -> Void
  @State private var working = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("接入这台机器") {
          LabeledContent("名称", value: pairing.client.name)
          LabeledContent("账号", value: pairing.client.user)
          LabeledContent("中心", value: pairing.client.relayHost)
        }
        Section("核对机器上显示的 SSH 指纹") {
          Text(pairing.client.pin).font(.footnote.monospaced()).textSelection(.enabled)
          Text("确认后，这台机器将允许当前 iPhone 访问你的 tmux 会话。")
        }
        Section {
          Button {
            working = true
            error = nil
            Task {
              do {
                let client = try await pairing.approve()
                save(client)
                dismiss()
              } catch { self.error = error.localizedDescription }
              working = false
            }
          } label: {
            HStack {
              Text(working ? "正在配对并连接…" : "确认配对并连接")
              if working { Spacer(); ProgressView() }
            }
          }
          .disabled(working)
          .accessibilityIdentifier("clients.pair.confirm")
          if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }
      }
      .navigationTitle("配对内网机器")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }.disabled(working)
        }
      }
      .interactiveDismissDisabled(working)
    }.preferredColorScheme(.dark)
  }
}
