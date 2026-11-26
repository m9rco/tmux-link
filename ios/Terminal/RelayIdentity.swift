import CryptoKit
import Darwin
import Foundation
import Security

struct RelayError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

struct RelayCredential: Codable {
  let host: String
  let certificate: Data
  let privateKey: Data  // PKCS#8 for rustls, stored only in the device Keychain.

  static func importPKCS12(_ data: Data, password: String, host: String) throws -> Self {
    let options = [kSecImportExportPassphrase as String: password]
    var result: CFArray?
    guard SecPKCS12Import(data as CFData, options as CFDictionary, &result) == errSecSuccess,
      let entries = result as? [[String: Any]], entries.count == 1,
      let value = entries[0][kSecImportItemIdentity as String]
    else {
      throw RelayError("无法导入，请检查证书文件和密码")
    }
    let identity = value as! SecIdentity
    var cert: SecCertificate?
    var secret: SecKey?
    guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
      SecIdentityCopyPrivateKey(identity, &secret) == errSecSuccess, let secret,
      let raw = SecKeyCopyExternalRepresentation(secret, nil) as Data?,
      let key = try? P256.Signing.PrivateKey(x963Representation: raw)
    else {
      throw RelayError("需要包含 P-256 私钥的客户端证书")
    }
    let der = SecCertificateCopyData(cert) as Data
    try RelayIdentity.validate(der, for: key)
    return Self(host: host, certificate: der, privateKey: key.derRepresentation)
  }
}

enum RelayIdentity {
  private static let service = "dev.tmuxlink.relay-identity"
  private static let enrolledHosts = "relay.enrolled.hosts.v1"
  private static let deviceKey = "enrollment.p256"

  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
  }

  private static func read(_ account: String) throws -> Data? {
    var q = query(account)
    q[kSecReturnData as String] = true
    var value: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return data
  }

  private static func write(_ data: Data, account: String) throws {
    let q = query(account)
    let attrs: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(q.merging(attrs) { _, v in v } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  static func validate(_ der: Data, for key: P256.Signing.PrivateKey) throws {
    guard let cert = SecCertificateCreateWithData(nil, der as CFData),
      let publicKey = SecCertificateCopyKey(cert),
      let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
      point == key.publicKey.x963Representation
    else {
      throw RelayError("客户端证书与本机私钥不匹配")
    }
  }

  // A paired Mac signs this public key and returns only a certificate. No private key is exported.
  static func processEnrollment() throws {
    let docs = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let key: P256.Signing.PrivateKey
    if let raw = try read(deviceKey) {
      key = try P256.Signing.PrivateKey(rawRepresentation: raw)
    } else {
      key = P256.Signing.PrivateKey()
      try write(key.rawRepresentation, account: deviceKey)
    }
    let publicFile = docs.appendingPathComponent("tmux-link-device-public.pem")
    let pem = Data((key.publicKey.pemRepresentation + "\n").utf8)
    if (try? Data(contentsOf: publicFile)) != pem {
      try pem.write(to: publicFile, options: .atomic)
    }
    let manifest = docs.appendingPathComponent("tmux-link-enrollment.json")
    guard FileManager.default.fileExists(atPath: manifest.path) else { return }
    struct Enrollment: Decodable {
      let host: String
      let certificate: Data
    }
    let item = try JSONDecoder().decode(Enrollment.self, from: limitedFile(manifest))
    let host = item.host.lowercased()
    guard !host.isEmpty, host.utf8.count <= 253,
      host.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45
      })
    else { throw RelayError("注册文件中的中转主机名无效") }
    try validate(item.certificate, for: key)
    try write(item.certificate, account: "host." + host)
    let known = UserDefaults.standard.stringArray(forKey: enrolledHosts) ?? []
    if !known.contains(host) { UserDefaults.standard.set(known + [host], forKey: enrolledHosts) }
    try FileManager.default.removeItem(at: manifest)
  }

  static func limitedFile(_ url: URL) throws -> Data {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard let size, size > 0, size <= 1_048_576 else { throw RelayError("证书文件大小无效") }
    return try Data(contentsOf: url)
  }

  static func save(_ credential: RelayCredential, for id: UUID) throws {
    try write(try PropertyListEncoder().encode(credential), account: "profile." + id.uuidString)
  }

  static func remove(_ id: UUID) {
    SecItemDelete(query("profile." + id.uuidString) as CFDictionary)
  }

  static func requiresDeviceCertificate(_ client: ClientProfile) -> Bool {
    client.requireMTLS == true || client.importedIdentity == true
      || (UserDefaults.standard.stringArray(forKey: enrolledHosts) ?? []).contains(client.relayHost)
  }

  static func resolve(_ client: ClientProfile) throws -> RelayCredential? {
    let host = client.relayHost
    if client.importedIdentity == true {
      guard let data = try read("profile." + client.id.uuidString) else {
        throw RelayError("请重新导入客户端证书")
      }
      let credential = try PropertyListDecoder().decode(RelayCredential.self, from: data)
      guard credential.host == host else { throw RelayError("服务器地址已更改，请为该地址重新导入证书") }
      return credential
    }
    if let cert = try read("host." + host), let raw = try read(deviceKey) {
      let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
      try validate(cert, for: key)
      return RelayCredential(host: host, certificate: cert, privateKey: key.derRepresentation)
    }
    guard !requiresDeviceCertificate(client)
    else { throw RelayError("此客户端需要 mTLS 设备证书，请在客户端配置中导入") }
    return nil
  }
}

struct PhoneAdviceExchange {
  let instance: String
  var ticket: String?
  var payload = Data()
}

private struct AgentPaneContext: Decodable {
  let version: Int
  let id: Int64
  let isAgent: Bool
  let instance: String
  let processInstance: String?

  var identity: String? {
    guard version == 1, isAgent, id >= 0, !instance.isEmpty,
          let processInstance, !processInstance.isEmpty else { return nil }
    return "\(id):\(instance):\(processInstance)"
  }
}

struct TerminalTransport {
  let endpoint: String
  let port: UInt16
  let user: String
  let pin: String
  let seed: Data
  let identity: RelayCredential?

  init(_ client: ClientProfile) throws {
    identity = try RelayIdentity.resolve(client)
    seed = try Identity.load().rawRepresentation
    port = client.port
    user = client.user
    pin = client.pin
    if identity != nil {
      guard !client.host.lowercased().hasPrefix("ws://") else {
        throw RelayError("mTLS 需要 WSS 加密入口")
      }
      if client.host.lowercased().hasPrefix("wss://") {
        endpoint = client.endpoint
      } else {
        var url = URLComponents()
        url.scheme = "wss"
        url.host = client.host
        url.port = Int(client.port)
        url.path = client.route.isEmpty ? "/tmux-link" : "/tmux-link/" + client.route
        guard let address = url.string else { throw RelayError("服务器地址无效") }
        endpoint = address
      }
    } else {
      endpoint = client.endpoint
    }
  }

  static func list(_ client: ClientProfile) async throws -> [RemoteSession] {
    let data = try await listData(client)
    return try JSONDecoder().decode([RemoteSession].self, from: data)
  }

  static func listData(_ client: ClientProfile) async throws -> Data {
    try await read(client, target: -2)
  }

  static func snapshot(_ client: ClientProfile, session: RemoteSession, version: PaneSnapshotVersion) async throws -> DecisionSnapshot {
    guard session.id >= 0 else { throw RelayError("无效的会话编号") }
    let target: Int64
    switch version {
    case .v1:
      let (encodedID, overflow) = Int64(-3).subtractingReportingOverflow(session.id)
      guard !overflow else { throw RelayError("无效的会话编号") }
      target = encodedID
    case .v2:
      target = session.id
    }
    let data = try await read(client, target: target, snapshotV2: version == .v2)
    return try version.decode(data, for: session)
  }

  static func managed(_ client: ClientProfile, sessionID: Int64, action: ManagedAction, instance: String? = nil) async throws -> ManagedStatus {
    guard sessionID >= 0 else { throw RelayError("无效的会话编号") }
    guard action == .status || instance != nil else { throw RelayError("请刷新会话列表后再调整托管。") }
    let request = action.wireValue + (instance.map { "@" + $0 } ?? "")
    let data = try await read(client, target: sessionID, managedAction: request)
    return try JSONDecoder().decode(ManagedStatus.self, from: data)
  }

  static func claim(_ client: ClientProfile, sessionID: Int64, instance: String) async throws -> ManagedClaimResponse {
    let data = try await read(client, target: sessionID, advice: PhoneAdviceExchange(instance: instance))
    return try JSONDecoder().decode(ManagedClaimResponse.self, from: data)
  }

  static func finish(_ client: ClientProfile, sessionID: Int64, instance: String, ticket: String, envelope: Data?) async throws -> ManagedStatus {
    let exchange = PhoneAdviceExchange(instance: instance, ticket: ticket, payload: envelope ?? Data("null".utf8))
    let data = try await read(client, target: sessionID, advice: exchange)
    return try JSONDecoder().decode(ManagedStatus.self, from: data)
  }

  static func agentIdentity(_ client: ClientProfile, sessionID: Int64, attachPID: UInt32) async throws -> String? {
    guard sessionID >= 0, attachPID > 0 else { return nil }
    let data = try await read(client, target: sessionID, contextPID: attachPID)
    return try JSONDecoder().decode(AgentPaneContext.self, from: data).identity
  }

  static func attachedPane(_ client: ClientProfile, sessionID: Int64, attachPID: UInt32) async throws -> (id: Int64, instance: String) {
    let data = try await read(client, target: sessionID, contextPID: attachPID)
    let pane = try JSONDecoder().decode(AgentPaneContext.self, from: data)
    guard pane.version == 1, pane.id >= 0, !pane.instance.isEmpty else { throw RelayError("无法核对此终端的目标窗格。") }
    return (pane.id, pane.instance)
  }

  private static func read(_ client: ClientProfile, target: Int64, snapshotV2: Bool = false, managedAction: String? = nil, advice: PhoneAdviceExchange? = nil, contextPID: UInt32? = nil) async throws -> Data {
    let connection = try TerminalTransport(client)
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let reader = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
    let worker = pair[1]
    // Both the FFI call and file read block. Drain concurrently outside the
    // cooperative executor, including on devices with a small thread pool.
    async let message: String? = withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: connection.run(worker, target: target, snapshotV2: snapshotV2, managedAction: managedAction, advice: advice, contextPID: contextPID))
      }
    }
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        defer { try? reader.close() }
        continuation.resume(with: Result { try reader.readToEnd() ?? Data() })
      }
    }
    if let error = await message {
      switch error {
      case "managed unsupported": throw RelayError("远端节点需要更新 tmux-link-agent 才能使用托管。")
      case "managed session changed": throw RelayError("当前会话或窗格已切换，请返回会话列表刷新。")
      case "managed unavailable": throw RelayError("节点未能完成托管请求。请刷新会话，并检查节点上的托管状态。")
      case "snapshot unsupported": throw RelayError("远端代理不支持读取窗格，请更新 tmux-link-agent。")
      case "snapshot pane in mode": throw RelayError("请先退出 tmux 的复制或选择模式，再读取当前窗格。")
      case "snapshot exceeds capture limit": throw RelayError("这个窗格的数据量超出节点读取上限。请进入会话，点「决策」读取当前画面。")
      case "snapshot unavailable": throw RelayError("无法读取所选窗格，会话可能已经关闭或切换。")
      default: throw RelayError(error)
      }
    }
    return data
  }

  // Rust owns the supplied descriptor until return, on both success and error.
  func run(_ fd: Int32, target: Int64, fitInitialGrid: Bool = false, snapshotV2: Bool = false, managedAction: String? = nil, advice: PhoneAdviceExchange? = nil, contextPID: UInt32? = nil) -> String? {
    let der = identity?.certificate ?? Data()
    let pkcs8 = identity?.privateKey ?? Data()
    let open = snapshotV2 ? tl_snapshot_v2_secure : (fitInitialGrid ? tl_open_secure_fitted : tl_open_secure)
    let error = seed.withUnsafeBytes { (seedBytes: UnsafeRawBufferPointer) in
      der.withUnsafeBytes { (cert: UnsafeRawBufferPointer) in
        pkcs8.withUnsafeBytes { (key: UnsafeRawBufferPointer) in
          let seedPointer = seedBytes.bindMemory(to: UInt8.self).baseAddress!
          let certificate = der.isEmpty ? nil : cert.bindMemory(to: UInt8.self).baseAddress
          let privateKey = pkcs8.isEmpty ? nil : key.bindMemory(to: UInt8.self).baseAddress
          if let contextPID {
            return tl_agent_context_secure(fd, endpoint, port, user, pin, seedPointer, target, contextPID,
                                           certificate, cert.count, privateKey, key.count)
          }
          if let advice {
            return advice.payload.withUnsafeBytes { (payload: UnsafeRawBufferPointer) in
              tl_advice_secure(fd, endpoint, port, user, pin, seedPointer, target, advice.instance, advice.ticket,
                               payload.isEmpty ? nil : payload.bindMemory(to: UInt8.self).baseAddress,
                               payload.count, certificate, cert.count, privateKey, key.count)
            }
          }
          if let managedAction {
            return tl_managed_secure(fd, endpoint, port, user, pin, seedPointer, target, managedAction,
                                     certificate, cert.count, privateKey, key.count)
          }
          return open(fd, endpoint, port, user, pin, seedPointer, target,
                      certificate, cert.count, privateKey, key.count)
        }
      }
    }
    guard let error else { return nil }
    defer { tl_free_error(error) }
    return String(cString: error)
  }
}
