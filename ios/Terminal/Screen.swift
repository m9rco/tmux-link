import Darwin
import Foundation
import UIKit
import WebKit

final class Screen: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
  let host: String, user: String, pin: String
  let port: UInt16
  let target: Int64
  private let heading: String
  private let status = UILabel()
  private let keys = UIStackView()
  private let input = DispatchQueue(label: "dev.tmuxlink.terminal-input")
  private var pendingBytes = 0
  private var ready = false
  private var web: WKWebView!
  private var fd: Int32 = -1
  private var started = false
  private var active = true
  private var dimensions = (UInt16(80), UInt16(24))
  init(client: ClientProfile, session: RemoteSession?) {
    host = client.endpoint
    port = client.port
    user = client.user
    pin = client.pin
    target = session?.id ?? -1
    heading = session?.name ?? client.name
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    title = heading
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(self, name: "terminal")
    web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    web.isOpaque = false
    web.scrollView.isScrollEnabled = false
    view.backgroundColor = UIColor(red: 0.04, green: 0.08, blue: 0.10, alpha: 1)
    let accent = UIColor(red: 0.47, green: 0.91, blue: 0.79, alpha: 1)
    status.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    status.textColor = accent
    status.numberOfLines = 2
    status.text = "  ◌  正在连接 · " + heading
    let scroll = UIScrollView()
    scroll.showsHorizontalScrollIndicator = false
    keys.spacing = 5
    keys.isUserInteractionEnabled = false
    keys.alpha = 0.45
    for (label, key) in [
      ("Esc", "\u{1b}"), ("Tab", "\t"), ("⌃C", "\u{03}"), ("⌃B", "\u{02}"),
      ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C"), ("↵", "\r"),
    ] {
      var style = UIButton.Configuration.tinted()
      style.title = label
      style.baseForegroundColor = label == "Esc" ? .systemOrange : accent
      style.contentInsets = .init(top: 3, leading: 8, bottom: 3, trailing: 8)
      let button = UIButton(configuration: style)
      button.accessibilityIdentifier = "terminal.key." + label
      button.addAction(UIAction { [weak self] _ in self?.press(key) }, for: .touchUpInside)
      keys.addArrangedSubview(button)
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }
    scroll.addSubview(keys)
    keys.translatesAutoresizingMaskIntoConstraints = false
    let stack = UIStackView(arrangedSubviews: [status, web, scroll])
    stack.axis = .vertical
    stack.spacing = 4
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -6),
      scroll.heightAnchor.constraint(equalToConstant: 44),
      keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
    let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets")!
    web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(
      action.request.url
        == Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets")
        ? .allow : .cancel)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard active && !started else { return }
    started = true
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      finish("本地连接失败")
      return
    }
    fd = pair[0]
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let reader = dup(fd)
    let worker = pair[1]
    guard reader >= 0 else {
      close(worker)
      finish("本地连接失败")
      return
    }
    let seed: Data
    do { seed = try Identity.load().rawRepresentation } catch {
      close(reader)
      close(worker)
      finish(error.localizedDescription)
      return
    }
    resize()
    DispatchQueue.global(qos: .userInitiated).async {
      [host, port, user, pin, seed, target, weak self] in
      let error = seed.withUnsafeBytes { buffer in
        tl_open(
          worker, host, port, user, pin, buffer.bindMemory(to: UInt8.self).baseAddress!, target)
      }
      let message = error.map { String(cString: $0) } ?? "会话已断开"
      if let error { tl_free_error(error) }
      DispatchQueue.main.async { self?.finish(message) }
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      defer { close(reader) }
      var buffer = [UInt8](repeating: 0, count: 32768)
      while true {
        let count = read(reader, &buffer, 32768)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { break }
        let bytes = Data(buffer.prefix(count)).base64EncodedString()
        let rendered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
          guard let self, active else {
            rendered.signal()
            return
          }
          if !ready && fd >= 0 {
            ready = true
            keys.isUserInteractionEnabled = true
            keys.alpha = 1
            status.text = "  ●  " + heading + "  /  " + user
          }
          web.callAsyncJavaScript(
            "await window.display(bytes)", arguments: ["bytes": bytes], in: nil, in: .page
          ) { _ in rendered.signal() }
        }
        if rendered.wait(timeout: .now() + 30) == .timedOut {
          DispatchQueue.main.async { self?.finish("终端显示超时，请重新连接") }
          break
        }
      }
      DispatchQueue.main.async { self?.disconnect() }
    }
  }
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard active, message.frameInfo.isMainFrame, let obj = message.body as? [String: Any] else {
      return
    }
    if let str = obj["data"] as? String {
      let bytes = Data(str.utf8)
      for offset in stride(from: 0, to: bytes.count, by: 16384) {
        send(0, bytes.subdata(in: offset..<min(offset + 16384, bytes.count)))
      }
    }
    if let cols = obj["cols"] as? Int, let rows = obj["rows"] as? Int, cols > 0, rows > 0 {
      dimensions = (UInt16(clamping: cols), UInt16(clamping: rows))
      resize()
    }
  }
  private func resize() {
    let (c, r) = dimensions
    send(
      1,
      Data([
        UInt8(c >> 8), UInt8(truncatingIfNeeded: c), UInt8(r >> 8), UInt8(truncatingIfNeeded: r),
      ]))
  }
  private func send(_ kind: UInt8, _ bytes: Data) {
    guard fd >= 0 else { return }
    var frame = Data([kind])
    var size = UInt32(bytes.count).bigEndian
    frame.append(Data(bytes: &size, count: 4))
    frame.append(bytes)
    guard pendingBytes + frame.count <= 1_048_576 else {
      finish("输入过多，请重新连接")
      return
    }
    let output = dup(fd)
    guard output >= 0 else {
      finish("输入通道不可用")
      return
    }
    let packet = frame
    pendingBytes += packet.count
    input.async { [weak self] in
      defer { close(output) }
      let ok = packet.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
          let n = Darwin.send(output, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
          if n < 0 && errno == EINTR { continue }
          guard n > 0 else { return false }
          offset += n
        }
        return true
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.pendingBytes -= packet.count
        if !ok && self.fd >= 0 { self.finish("输入通道已断开") }
      }
    }
  }
  private func finish(_ message: String) {
    status.text = "  " + message
    disconnect()
  }
  private func disconnect() {
    ready = false
    keys.isUserInteractionEnabled = false
    keys.alpha = 0.45
    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      close(fd)
      fd = -1
    }
  }
  private func press(_ key: String) {
    guard ready else { return }
    send(0, Data(key.utf8))
    UISelectionFeedbackGenerator().selectionChanged()
  }
  override var keyCommands: [UIKeyCommand]? {
    let escape = UIKeyCommand(
      input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey))
    escape.wantsPriorityOverSystemBehavior = true
    return [escape]
  }
  @objc private func escapeKey() { press("\u{1b}") }
  func stop() {
    active = false
    disconnect()
    web?.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
  }
}
