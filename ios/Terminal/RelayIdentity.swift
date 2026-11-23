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

  // Rust owns the supplied descriptor until return, on both success and error.
  func run(_ fd: Int32, target: Int64, fitInitialGrid: Bool = false) -> String? {
    let der = identity?.certificate ?? Data()
    let pkcs8 = identity?.privateKey ?? Data()
    let open = fitInitialGrid ? tl_open_secure_fitted : tl_open_secure
    let error = seed.withUnsafeBytes { (seedBytes: UnsafeRawBufferPointer) in
      der.withUnsafeBytes { (cert: UnsafeRawBufferPointer) in
        pkcs8.withUnsafeBytes { (key: UnsafeRawBufferPointer) in
          open(
            fd, endpoint, port, user, pin, seedBytes.bindMemory(to: UInt8.self).baseAddress!,
            target, der.isEmpty ? nil : cert.bindMemory(to: UInt8.self).baseAddress, cert.count,
            pkcs8.isEmpty ? nil : key.bindMemory(to: UInt8.self).baseAddress, key.count)
        }
      }
    }
    guard let error else { return nil }
    defer { tl_free_error(error) }
    return String(cString: error)
  }
}
