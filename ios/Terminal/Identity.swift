import CryptoKit
import Foundation
import Security

enum Identity {
  static func load() throws -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.tmuxlink.identity", kSecAttrAccount as String: "ssh-ed25519",
    ]
    var item: CFTypeRef?
    var lookup = query
    lookup[kSecReturnData as String] = true
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      return try .init(rawRepresentation: data)
    }
    guard status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    let key = Curve25519.Signing.PrivateKey()
    var record = query
    record[kSecValueData as String] = key.rawRepresentation
    record[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let saved = SecItemAdd(record as CFDictionary, nil)
    guard saved == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved))
    }
    return key
  }

  static func publicLine() throws -> String {
    var wire = Data()
    for part in [Data("ssh-ed25519".utf8), try load().publicKey.rawRepresentation] {
      var size = UInt32(part.count).bigEndian
      wire.append(Data(bytes: &size, count: 4))
      wire.append(part)
    }
    return "ssh-ed25519 " + wire.base64EncodedString() + " tmux-link-ios"
  }
}
