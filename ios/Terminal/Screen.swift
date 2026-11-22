import Darwin
import Foundation
import UIKit
import WebKit

// FitAddon requests whole rows and columns. Stretch just the remaining fraction
// of a cell over the grid; UIKit maps touches through the same transform.
private final class TerminalViewport: UIView {
  let web: WKWebView
  private var measuredArea = CGSize.zero
  private var grid = CGSize.zero

  init(web: WKWebView) {
    self.web = web
    super.init(frame: .zero)
    clipsToBounds = true
    web.layer.anchorPoint = .zero
    addSubview(web)
  }

  required init?(coder: NSCoder) { fatalError() }

  func setMeasurement(area: CGSize, grid: CGSize) {
    guard measuredArea != area || self.grid != grid else { return }
    measuredArea = area
    self.grid = grid
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The CSS viewport must keep its unscaled size when the keyboard or device rotates.
    web.bounds = CGRect(origin: .zero, size: bounds.size)
    web.layer.position = bounds.origin
    guard grid.width > 0, grid.height > 0,
      abs(measuredArea.width - bounds.width) < 1, abs(measuredArea.height - bounds.height) < 1
    else {
      web.transform = .identity
      return
    }
    web.transform = CGAffineTransform(scaleX: bounds.width / grid.width, y: bounds.height / grid.height)
  }
}

final class Screen: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
  static let surface = UIColor(red: 10 / 255, green: 20 / 255, blue: 26 / 255, alpha: 1)
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
  private var shortcuts: ShortcutDrawer!
  private let leave: (() -> Void)?
  private weak var edgeBackSwipe: UISwipeGestureRecognizer?
  private weak var contentBackSwipe: UISwipeGestureRecognizer?
  private lazy var editMenu = UIEditMenuInteraction(delegate: self)
  private var menuSnapshot: (text: String, offset: Int, selected: String)?
  private var scrollOrigin = CGPoint.zero
  private var lastScrollDistance: CGFloat = 0
  private var firstScrollStep = true
  private let input = DispatchQueue(label: "dev.tmuxlink.terminal-input")
  private var pendingBytes = 0
  private var ready = false
  private var web: WKWebView!
  private var viewport: TerminalViewport!
  private var fd: Int32 = -1
  private var started = false
  private var active = true
  private var dimensions = (UInt16(80), UInt16(24))
  init(
    client: ClientProfile, session: RemoteSession?,
    navigationStatus: TerminalNavigationStatus? = nil, leave: (() -> Void)? = nil
  ) {
    self.leave = leave
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
    web.underPageBackgroundColor = Self.surface
    web.scrollView.contentInsetAdjustmentBehavior = .never
    web.scrollView.isScrollEnabled = false
    viewport = TerminalViewport(web: web)
    viewport.accessibilityIdentifier = "terminal.viewport"
    view.backgroundColor = Self.surface
    statusBar.isHidden = navigationStatus != nil
    let accent = UIColor(red: 0.47, green: 0.91, blue: 0.79, alpha: 1)
    let pan = UIPanGestureRecognizer(target: self, action: #selector(scrollTerminal(_:)))
    pan.maximumNumberOfTouches = 1
    pan.delegate = self
    web.addGestureRecognizer(pan)
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(selectText(_:)))
    hold.minimumPressDuration = 0.45
    web.addGestureRecognizer(hold)
    web.addInteraction(editMenu)
    pan.require(toFail: hold)
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
    let stack = UIStackView(arrangedSubviews: [bar, viewport!])
    stack.axis = .vertical
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
    ])
    shortcuts = ShortcutDrawer(in: viewport, accent: accent, leave: leave) { [weak self] key in self?.press(key) }
    if leave != nil {
      let edge = UISwipeGestureRecognizer(target: self, action: #selector(leaveSession))
      edge.direction = .right
      edge.delegate = self
      web.addGestureRecognizer(edge)
      edgeBackSwipe = edge
      let left = UISwipeGestureRecognizer(target: self, action: #selector(leaveSession))
      left.direction = .left
      left.delegate = self
      web.addGestureRecognizer(left)
      contentBackSwipe = left
    }
    let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets")!
    web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    NotificationCenter.default.addObserver(
      self, selector: #selector(pauseStatus),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(resumeStatus),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }
  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
    let velocity = pan.velocity(in: web)
    return ready && abs(velocity.y) > abs(velocity.x)
  }

  func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // A left swipe starting at the right edge belongs exclusively to the shortcut drawer.
    let x = touch.location(in: viewport).x
    if recognizer === edgeBackSwipe { return x <= 28 }
    return recognizer !== contentBackSwipe || x < viewport.bounds.maxX - 32
  }

  @objc private func leaveSession() { leave?() }

  @objc private func selectText(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }
    let point = gesture.location(in: web)
    web.callAsyncJavaScript("return selectionSnapshot(x, y)", arguments: ["x": point.x, "y": point.y],
                            in: nil, in: .page) { [weak self] result in
      guard let self, active, view.window != nil, presentedViewController == nil,
            case .success(let value) = result, let snapshot = value as? [String: Any],
            let text = snapshot["text"] as? String, let offset = snapshot["offset"] as? Int
      else { return }
      if snapshot["atCursor"] as? Bool == true && ready {
        menuSnapshot = (text, offset, snapshot["selected"] as? String ?? "")
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
      } else { showSelection(text, offset) }
    }
  }

  private func showSelection(_ text: String, _ offset: Int) {
    let sheet = UINavigationController(rootViewController: TerminalTextSelection(text: text, offset: offset))
    sheet.overrideUserInterfaceStyle = .dark
    sheet.sheetPresentationController?.prefersGrabberVisible = true
    present(sheet, animated: true)
  }

  func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                           suggestedActions: [UIMenuElement]) -> UIMenu? {
    guard let snapshot = menuSnapshot else { return nil }
    var actions: [UIMenuElement] = []
    if !snapshot.selected.isEmpty {
      actions.append(UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
        UIPasteboard.general.string = snapshot.selected
      })
    }
    actions += [
      UIAction(title: "粘贴", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
        guard let self, ready, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        web.callAsyncJavaScript("pasteTerminal(text)", arguments: ["text": text], in: nil, in: .page,
                                completionHandler: nil)
      },
      UIAction(title: "选取并复制", image: UIImage(systemName: "text.cursor")) { [weak self] _ in
        self?.showSelection(snapshot.text, snapshot.offset)
      }
    ]
    return UIMenu(children: actions)
  }

  func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                           animator: UIEditMenuInteractionAnimating) {
    menuSnapshot = nil
  }

  @objc private func scrollTerminal(_ pan: UIPanGestureRecognizer) {
    guard ready else { return }
    let dy = pan.translation(in: web).y
    switch pan.state {
    case .began:
      let point = pan.location(in: web)
      scrollOrigin = CGPoint(x: point.x / max(1, web.bounds.width),
                             y: (point.y - dy) / max(1, web.bounds.height))
      lastScrollDistance = 0
      firstScrollStep = true
    case .changed, .ended: break
    default: return
    }
    let steps = Int((dy - lastScrollDistance) / 20)
    guard steps != 0 else { return }
    lastScrollDistance += CGFloat(steps) * 20
    web.callAsyncJavaScript("scrollRemote(x, y, steps, first)", arguments: [
      "x": scrollOrigin.x, "y": scrollOrigin.y, "steps": steps, "first": firstScrollStep
    ], in: nil, in: .page, completionHandler: nil)
    firstScrollStep = false
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startIslandIfAvailable()
  }

  private func startIslandIfAvailable() {
    guard #available(iOS 16.1, *), island == nil, active, !completed, viewIfLoaded?.window != nil
    else { return }
    island = TerminalIsland(activityState) { [weak self] _ in self?.renderStatus() }
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
    navigationStatus?.update(state)
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
      statusBar.isHidden = navigationStatus != nil
      shortcuts.setReady(true)
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
    if let metrics = obj["layout"] as? [String: Double],
      let w = metrics["width"], let h = metrics["height"],
      let gw = metrics["gridWidth"], let gh = metrics["gridHeight"] {
      viewport.setMeasurement(area: CGSize(width: w, height: h), grid: CGSize(width: gw, height: gh))
    }
    let bytes = (obj["data"] as? String).map { Data($0.utf8) }
      ?? (obj["binary"] as? String).flatMap { Data(base64Encoded: $0) }
    if ready, let bytes {
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
    statusBar.isHidden = false
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
    shortcuts?.setReady(false)
    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      close(fd)
      fd = -1
    }
  }
  private func press(_ key: String) {
    guard ready else { return }
    web.callAsyncJavaScript("term.input(key, true)", arguments: ["key": key], in: nil, in: .page, completionHandler: nil)
    UISelectionFeedbackGenerator().selectionChanged()
  }
  override func accessibilityPerformEscape() -> Bool {
    guard let leave else { return super.accessibilityPerformEscape() }
    leave()
    return true
  }
  override var keyCommands: [UIKeyCommand]? {
    let escape = UIKeyCommand(
      input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey))
    escape.wantsPriorityOverSystemBehavior = true
    return [escape]
  }
  @objc private func escapeKey() {
    press("\u{1b}")
  }
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
