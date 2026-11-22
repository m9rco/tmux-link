import Darwin
import Foundation
import UIKit
import WebKit

final class Screen: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
  let client: ClientProfile
  let target: Int64
  private let heading: String
  private let status = UILabel()
  private let latency = UILabel()
  private let statusBar = UIStackView()
  private weak var navigationStatus: TerminalNavigationStatus?
  private var island: IslandReporting?
  private var activityState = TerminalActivityState()
  private var backgrounded = false
  private var expiry: Timer?
  private var completed = false
  private let transportBadge = UILabel()
  private let keys = UIStackView()
  private let input = DispatchQueue(label: "dev.tmuxlink.terminal-input")
  private var pendingBytes = 0
  private var ready = false
  private var web: WKWebView!
  private var fd: Int32 = -1
  private var started = false
  private var active = true
  private var dimensions = (UInt16(80), UInt16(24))
  init(
    client: ClientProfile, session: RemoteSession?,
    navigationStatus: TerminalNavigationStatus? = nil
  ) {
    self.client = client
    self.navigationStatus = navigationStatus
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
    status.font = .preferredFont(forTextStyle: .caption1)
    status.adjustsFontForContentSizeCategory = true
    status.textColor = accent
    status.numberOfLines = 2
    status.accessibilityIdentifier = "terminal.connection"
    status.text = "◌  正在连接"
    latency.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    latency.textColor = .secondaryLabel
    latency.accessibilityIdentifier = "terminal.latency"
    transportBadge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
    transportBadge.textColor = .secondaryLabel
    let bar = statusBar
    [status, transportBadge, latency].forEach(bar.addArrangedSubview)
    bar.alignment = .center
    bar.spacing = 10
    bar.isLayoutMarginsRelativeArrangement = true
    bar.directionalLayoutMargins = .init(top: 5, leading: 7, bottom: 5, trailing: 7)
    status.setContentHuggingPriority(.defaultLow, for: .horizontal)
    transportBadge.setContentHuggingPriority(.required, for: .horizontal)
    latency.setContentHuggingPriority(.required, for: .horizontal)
    latency.setContentCompressionResistancePriority(.required, for: .horizontal)
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
    let stack = UIStackView(arrangedSubviews: [bar, web, scroll])
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
    NotificationCenter.default.addObserver(
      self, selector: #selector(pauseStatus),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(resumeStatus),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startIslandIfAvailable()
  }

  private func startIslandIfAvailable() {
    guard #available(iOS 16.1, *), island == nil, active, !completed, viewIfLoaded?.window != nil
    else { return }
    island = TerminalIsland(activityState) { [weak self] shown in
      guard let self else { return }
      statusBar.isHidden = shown && navigationStatus != nil
      renderStatus()
    }
  }

  private func renderStatus() {
    guard active, !completed else { return }
    let state = activityState.display(at: Date())
    if state.phase == .paused {
      status.text = "◌  等待更新"
      latency.text = "RTT —"
      latency.accessibilityLabel = "等待新的延迟测量"
      latency.textColor = .secondaryLabel
    } else {
      status.text = (state.phase == .ready ? "●  " : "◌  ") + state.phase.title
      if state.phase == .ready {
        latency.text = "RTT " + state.latencyText
        latency.textColor = state.timedOut ? .systemOrange : .secondaryLabel
        if state.timedOut {
          latency.accessibilityLabel = "会话延迟测量超时"
        } else if let ms = state.milliseconds {
          latency.accessibilityLabel = "会话往返延迟 " + String(ms) + " 毫秒"
        } else {
          latency.accessibilityLabel = "正在测量会话往返延迟"
        }
      }
    }
    navigationStatus?.update(statusBar.isHidden ? state : nil)
  }

  private func refreshStatus(immediately: Bool = false) {
    renderStatus()
    expiry?.invalidate()
    let remaining = activityState.staleDate.timeIntervalSinceNow
    if remaining > 0 && !backgrounded {
      expiry = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
        self?.renderStatus()
      }
    }
    if #unavailable(iOS 16.2) { activityState.historical = backgrounded }
    island?.publish(activityState, immediately: immediately || backgrounded)
  }

  @objc private func pauseStatus() {
    guard active, !completed else { return }
    backgrounded = true
    // Flush any coalesced reading with its original deadline before suspension.
    refreshStatus(immediately: true)
  }

  @objc private func resumeStatus() {
    guard active, !completed else { return }
    backgrounded = false
    refreshStatus(immediately: true)
    startIslandIfAvailable()
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
    let connection: TerminalTransport
    do { connection = try TerminalTransport(client) } catch {
      close(reader)
      close(worker)
      finish(error.localizedDescription)
      return
    }
    resize()
    let hasIdentity = connection.identity != nil
    let result = Task.detached(priority: .userInitiated) { [target] in
      connection.run(worker, target: target)
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let stream = FileHandle(fileDescriptor: reader, closeOnDealloc: true)
      do {
        while let (kind, payload) = try Self.readFrame(from: stream) {
          if kind == 1 {
            let stage = String(decoding: payload, as: UTF8.self)
            let observedAt = Date()
            DispatchQueue.main.async {
              self?.stage(stage, hasIdentity: hasIdentity, observedAt: observedAt)
            }
          } else if kind == 2 {
            guard payload.count == 4 else { throw RelayError("延迟数据格式错误") }
            let ms = payload.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let observedAt = Date()
            DispatchQueue.main.async { self?.updateLatency(ms, observedAt: observedAt) }
          } else if kind == 0 {
            let rendered = DispatchSemaphore(value: 0)
            let bytes = payload.base64EncodedString()
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
              throw RelayError("终端显示超时，请重新连接")
            }
          } else {
            throw RelayError("终端数据格式错误")
          }
        }
        Task { @MainActor [weak self] in
          let error = await result.value
          self?.finish(error ?? "会话已断开")
        }
      } catch {
        DispatchQueue.main.async { self?.finish(error.localizedDescription) }
      }
    }
  }

  nonisolated static func readFrame(from stream: FileHandle) throws -> (UInt8, Data)? {
    func bytes(_ count: Int, allowEOF: Bool = false) throws -> Data? {
      var data = Data()
      while data.count < count {
        guard let next = try stream.read(upToCount: count - data.count), !next.isEmpty else {
          if allowEOF && data.isEmpty { return nil }
          throw RelayError("终端数据提前结束")
        }
        data.append(next)
      }
      return data
    }
    guard let header = try bytes(5, allowEOF: true) else { return nil }
    let size = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
    guard size <= 65536, let payload = try bytes(size) else { throw RelayError("终端数据过长") }
    return (header[0], payload)
  }

  private func stage(_ stage: String, hasIdentity: Bool, observedAt: Date) {
    guard active, fd >= 0 else { return }
    guard let phase = TerminalActivityState.Phase(rawValue: stage) else { return }
    activityState.phase = phase
    activityState.mtls = hasIdentity
    activityState.observedAt = observedAt
    if phase == .ready {
      ready = true
      keys.isUserInteractionEnabled = true
      keys.alpha = 1
      transportBadge.text = hasIdentity ? "mTLS · SSH" : "SSH"
    }
    refreshStatus()
  }

  private func updateLatency(_ ms: UInt32, observedAt: Date) {
    guard active, ready else { return }
    activityState.observedAt = observedAt
    activityState.milliseconds = ms == .max ? nil : ms
    activityState.timedOut = ms == .max
    refreshStatus()
  }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard active, message.frameInfo.isMainFrame, let obj = message.body as? [String: Any] else {
      return
    }
    if ready, let str = obj["data"] as? String {
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
    guard active, !completed else { return }
    completed = true
    navigationStatus?.update(nil)
    expiry?.invalidate()
    island?.end()
    island = nil
    status.textColor = .systemOrange
    status.text = "○  " + message
    latency.text = nil
    latency.accessibilityLabel = nil
    transportBadge.text = nil
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
    expiry?.invalidate()
    island?.end()
    island = nil
    NotificationCenter.default.removeObserver(self)
    disconnect()
    web?.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
  }
}
