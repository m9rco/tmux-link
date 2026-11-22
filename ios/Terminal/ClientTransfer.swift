import CoreFoundation
import Darwin
import Foundation

enum ClientTransfer {
  private static let prefix = "tmuxlink://client?"
  private static let fields: Set<String> = [
    "name", "host", "port", "route", "user", "pin", "requireMTLS",
  ]
  private static let unreserved = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
  private static let maxBytes = 8192

  struct TransferError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  static func parse(_ text: String) throws -> ClientProfile {
    guard text.utf8.count <= maxBytes else { throw TransferError("客户端配置文本过长") }
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.hasPrefix("{") {
      return try profile(from: jsonFields(input))
    }
    if input.hasPrefix(prefix) {
      let query = input.dropFirst(prefix.count)
      guard !query.contains("#") else { throw TransferError("客户端分享链接不能包含片段") }
      var values: [String: String] = [:]
      for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let key = String(parts[0]).removingPercentEncoding,
          fields.contains(key), values[key] == nil,
          let value = String(parts[1]).removingPercentEncoding
        else { throw TransferError("客户端分享链接包含重复、未知或无效的字段") }
        values[key] = value
      }
      return try profile(from: values)
    }
    if input.hasPrefix("wss://") {
      return try profile(from: ["host": input])
    }
    throw TransferError("请粘贴 Tmux Link 客户端分享链接、JSON 配置或 WSS 地址")
  }

  static func link(for client: ClientProfile) throws -> String {
    var values = [
      "name": client.name, "host": client.host, "port": String(client.port),
      "route": client.route, "user": client.user, "pin": client.pin,
      "requireMTLS": (client.requireMTLS == true || client.importedIdentity == true)
        ? "true" : "false",
    ]
    let checked = try profile(from: values)
    guard checked.valid, !client.name.isEmpty else { throw TransferError("请先补全客户端配置") }
    values["pin"] = checked.pin
    let query = try ["host", "port", "route", "user", "pin", "name", "requireMTLS"].map { key in
      guard let value = values[key]?.addingPercentEncoding(withAllowedCharacters: unreserved) else {
        throw TransferError("客户端配置无法编码")
      }
      return key + "=" + value
    }.joined(separator: "&")
    let link = prefix + query
    guard link.utf8.count <= maxBytes else { throw TransferError("客户端分享链接过长") }
    return link
  }

  private static func jsonFields(_ text: String) throws -> [String: String] {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      Set(object.keys).isSubset(of: fields)
    else { throw TransferError("JSON 配置无效或包含非公开字段") }
    var values: [String: String] = [:]
    for (key, value) in object {
      switch key {
      case "port":
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else {
          throw TransferError("JSON 端口须为整数")
        }
        values[key] = number.stringValue
      case "requireMTLS":
        guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
          throw TransferError("JSON 的 requireMTLS 须为布尔值")
        }
        values[key] = flag.boolValue ? "true" : "false"
      default:
        guard let string = value as? String else { throw TransferError("JSON 配置字段须为文本") }
        values[key] = string
      }
    }
    return values
  }

  private static func profile(from values: [String: String]) throws -> ClientProfile {
    guard values.values.allSatisfy({ !hasUnsafeCharacters($0) }),
      let host = values["host"], !host.isEmpty, host.utf8.count <= 2048
    else { throw TransferError("配置缺少服务器地址或包含控制字符") }
    let route = values["route"] ?? ""
    var defaultPort = 443
    var defaultName = host
    if host.hasPrefix("wss://") || host.hasPrefix("ws://") {
      guard route.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "\\" }),
        let decoded = host.removingPercentEncoding, !hasUnsafeCharacters(decoded),
        !decoded.contains("\\"), let url = URLComponents(string: host),
        let hostname = url.host, validHost(hostname), url.user == nil, url.password == nil,
        url.query == nil, url.fragment == nil
      else { throw TransferError("WebSocket 地址无效，或包含登录信息、查询参数或片段") }
      // Reject encoded delimiters in the authority that URL parsers can interpret differently.
      let authority = host.dropFirst(host.hasPrefix("wss://") ? 6 : 5).prefix { $0 != "/" }
      let hasPort = authority.contains(":") && !authority.hasSuffix("]")
      guard !authority.contains("%"), !hasPort || url.port != nil,
        url.port.map({ (1...65535).contains($0) }) ?? true
      else { throw TransferError("WebSocket 服务器地址或端口无效") }
      defaultName = hostname
      defaultPort = url.port ?? (url.scheme == "ws" ? 80 : 443)
    } else {
      guard validHost(host) else { throw TransferError("服务器地址无效") }
    }
    let portText = values["port"] ?? String(defaultPort)
    guard portText.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(portText),
      port > 0
    else { throw TransferError("端口必须在 1 到 65535 之间") }
    let flag = values["requireMTLS"] ?? "false"
    guard let requireMTLS = Bool(flag), !(requireMTLS && host.hasPrefix("ws://")) else {
      throw TransferError("mTLS 设置无效，请使用加密的 WSS 入口")
    }
    let name = values["name"] ?? defaultName
    let user = values["user"] ?? ""
    guard !name.isEmpty, name.utf8.count <= 512, user.utf8.count <= 256, route.utf8.count <= 64,
      route.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0)
          || (48...57).contains($0) || $0 == 45 || $0 == 95
      })
    else { throw TransferError("名称、用户名或客户端路由无效") }
    return ClientProfile(
      name: name, host: host, port: port, route: route, user: user,
      pin: try fingerprint(values["pin"] ?? ""), requireMTLS: requireMTLS)
  }

  private static func fingerprint(_ pin: String) throws -> String {
    if pin.isEmpty { return "" }
    guard pin.hasPrefix("SHA256:") else { throw TransferError("主机指纹须以 SHA256: 开头") }
    let body = String(pin.dropFirst(7))
    let padded = body.count == 43 ? body + "=" : body
    guard padded.utf8.count == 44, let digest = Data(base64Encoded: padded), digest.count == 32,
      digest.base64EncodedString() == padded
    else { throw TransferError("主机指纹须为完整的 SHA256 指纹") }
    return "SHA256:" + padded.dropLast()
  }

  private static func validHost(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.count <= 254 else { return false }
    if host.contains(":") {
      let ip =
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
      var address = in6_addr()
      return inet_pton(AF_INET6, ip, &address) == 1
    }
    let name = host.hasSuffix(".") ? host.dropLast() : host[...]
    return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      !label.isEmpty && label.utf8.count <= 63
        && label.unicodeScalars.allSatisfy {
          CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
  }

  private static func hasUnsafeCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains {
      $0.properties.generalCategory == .control || $0 == "\u{061C}" || $0 == "\u{200E}"
        || $0 == "\u{200F}" || (0x2028...0x202E).contains($0.value)
        || (0x2066...0x2069).contains($0.value)
    }
  }
}
