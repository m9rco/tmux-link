import Foundation
import Security

enum AdvisorCredential {
  static let changed = Notification.Name("TmuxLinkAdvisorCredentialChanged")
  private static let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "dev.tmuxlink.session-advisor",
    kSecAttrAccount as String: "deepseek"
  ]

  static func load() throws -> String? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    var value: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data,
          let key = String(data: data, encoding: .utf8), !key.isEmpty else {
      throw RelayError("无法读取 API Key，请解锁 iPhone 后再试。")
    }
    return key
  }

  static func save(_ key: String) throws {
    let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...512).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
      throw RelayError("请输入有效的 DeepSeek API Key。")
    }
    let attributes: [String: Any] = [
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData as String: Data(token.utf8)
    ]
    var status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    if status == errSecDuplicateItem {
      status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    guard status == errSecSuccess else { throw RelayError("无法将 API Key 保存到本机钥匙串。") }
    NotificationCenter.default.post(name: changed, object: nil)
  }

  static func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RelayError("无法移除本机的 API Key。")
    }
    NotificationCenter.default.post(name: changed, object: nil)
  }
}
