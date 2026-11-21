import Darwin
import Foundation
import UIKit
import WebKit

final class Screen: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
  let host: String, user: String, pin: String
  let port: UInt16
  private let seed: Data
  private var web: WKWebView!
  private var fd: Int32 = -1
  private var started = false
  private var active = true
  private var dimensions = (UInt16(80), UInt16(24))
  init(host: String, port: UInt16, user: String, pin: String) throws {
    self.host = host
    self.port = port
    self.user = user
    self.pin = pin
    self.seed = try Identity.load().rawRepresentation
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    title = host
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(self, name: "terminal")
    web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    let bar = UIStackView()
    bar.distribution = .fillEqually
    for (title, key) in [
      ("Esc", "\u{1b}"), ("Tab", "\t"), ("Ctrl-C", "\u{03}"), ("Ctrl-B", "\u{02}"),
      ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("↵", "\r"),
    ] {
      let button = UIButton(type: .system)
      button.setTitle(title, for: .normal)
      button.addAction(
        UIAction { [weak self] _ in self?.send(0, Data(key.utf8)) }, for: .touchUpInside)
      bar.addArrangedSubview(button)
    }
    let stack = UIStackView(arrangedSubviews: [web, bar])
    stack.axis = .vertical
    view.backgroundColor = .systemBackground
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bar.heightAnchor.constraint(equalToConstant: 42),
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
    resize()
    DispatchQueue.global(qos: .userInitiated).async { [host, port, user, pin, seed, weak self] in
      let error = seed.withUnsafeBytes { buffer in
        tl_connect(worker, host, port, user, pin, buffer.bindMemory(to: UInt8.self).baseAddress!)
      }
      let message = error.map { String(cString: $0) } ?? "会话已断开"
      if let error { tl_free_error(error) }
      DispatchQueue.main.async { self?.navigationItem.prompt = message }
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
    let written = frame.withUnsafeBytes {
      Darwin.send(fd, $0.baseAddress, frame.count, MSG_DONTWAIT)
    }
    if written != frame.count { finish("输入通道已断开，请重新连接") }
  }
  private func finish(_ message: String) {
    navigationItem.prompt = message
    disconnect()
  }
  private func disconnect() {
    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      close(fd)
      fd = -1
    }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || navigationController == nil {
      active = false
      disconnect()
      web.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
    }
  }
}
