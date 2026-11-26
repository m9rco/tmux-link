import Foundation
import Security

struct AdvisorProvider: Codable, Identifiable, Equatable {
  let id: String
  let name: String
  let baseURL: String
  let model: String

  static let deepSeek = AdvisorProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com",
                                        model: "deepseek-flash")
  static let openAI = AdvisorProvider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                                     model: "gpt-4.1-mini")
  var builtin: Bool { id == Self.deepSeek.id || id == Self.openAI.id }

  func validated() throws -> Self {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 64, name.rangeOfCharacter(from: .controlCharacters) == nil,
          (1...200).contains(model.utf8.count), model.utf8.allSatisfy({ (33...126).contains($0) }) else {
      throw RelayError("请填写服务名称和模型 ID。")
    }
    let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard input.utf8.count <= 2048, input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !input.contains("\\"),
          var parts = URLComponents(string: input), parts.scheme?.lowercased() == "https",
          let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
          parts.query == nil, parts.fragment == nil, parts.port.map({ (1...65535).contains($0) }) ?? true,
          !parts.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
      throw RelayError("请输入 HTTPS 服务地址，可包含 /v1 等路径，不能包含密钥、查询参数或片段。")
    }
    parts.scheme = "https"
    parts.host = host.lowercased()
    if parts.port == 443 { parts.port = nil }
    while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
    let suffix = "/chat/completions"
    if parts.percentEncodedPath.hasSuffix(suffix) { parts.percentEncodedPath.removeLast(suffix.count) }
    guard let normalized = parts.url?.absoluteString,
          id != Self.deepSeek.id || normalized == Self.deepSeek.baseURL,
          id != Self.openAI.id || normalized == Self.openAI.baseURL,
          builtin || UUID(uuidString: id) != nil else { throw RelayError("模型服务地址无效。") }
    return Self(id: id, name: name, baseURL: normalized, model: model)
  }

  var keychainAccount: String {
    // Keep the existing DeepSeek account so an app update retains its key.
    id == Self.deepSeek.id && baseURL == Self.deepSeek.baseURL ? "deepseek" : "\(id)|\(baseURL)"
  }
}

struct AdvisorProviders: Codable {
  var profiles = [AdvisorProvider.deepSeek, .openAI]
  var selectedID = AdvisorProvider.deepSeek.id
  var selected: AdvisorProvider? { profiles.first { $0.id == selectedID } }
  private static let settings = "advisor.providers.v1"

  static func load(from defaults: UserDefaults = .standard) throws -> Self {
    guard let data = defaults.data(forKey: settings) else { return Self() }
    let stored = try JSONDecoder().decode(Self.self, from: data)
    guard stored.selected != nil, Set(stored.profiles.map(\.id)).count == stored.profiles.count,
          try stored.profiles.allSatisfy({ try $0.validated() == $0 }) else {
      throw RelayError("无法读取模型服务配置。")
    }
    return stored
  }

  func save(to defaults: UserDefaults = .standard) throws {
    defaults.set(try JSONEncoder().encode(self), forKey: Self.settings)
    NotificationCenter.default.post(name: AdvisorCredential.changed, object: nil)
  }
}

struct AdvisorAccess {
  let provider: AdvisorProvider
  let key: String
}

enum AdvisorCredential {
  static let changed = Notification.Name("TmuxLinkAdvisorCredentialChanged")
  private static func query(for profile: AdvisorProvider) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "dev.tmuxlink.session-advisor",
     kSecAttrAccount as String: profile.keychainAccount]
  }

  static func current(from defaults: UserDefaults = .standard) throws -> AdvisorAccess? {
    guard let profile = try AdvisorProviders.load(from: defaults).selected,
          let key = try load(for: profile) else { return nil }
    return AdvisorAccess(provider: profile, key: key)
  }

  static func load(for profile: AdvisorProvider = .deepSeek) throws -> String? {
    var lookup = query(for: try profile.validated())
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

  static func save(_ key: String, for profile: AdvisorProvider = .deepSeek) throws {
    let token = try SessionAdvisor.validatedKey(key)
    let query = query(for: try profile.validated())
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

  static func remove(for profile: AdvisorProvider = .deepSeek) throws {
    let status = SecItemDelete(query(for: try profile.validated()) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RelayError("无法移除本机的 API Key。")
    }
    NotificationCenter.default.post(name: changed, object: nil)
  }
}
