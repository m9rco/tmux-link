import Darwin
import Foundation
import SwiftUI
import UIKit
import WebKit

// FitAddon requests whole rows and columns. Stretch just the remaining fraction
// of a cell over the grid; UIKit maps touches through the same transform.
private final class TerminalViewport: UIView {
  let web: WKWebView
  private var measuredArea = CGSize.zero
  private var grid = CGSize.zero
  private var cursor: (row: Int, rows: Int)?
  private var offset: CGFloat = 0
  private var previousTravel: CGFloat = 0

  init(web: WKWebView) {
    self.web = web
    super.init(frame: .zero)
    clipsToBounds = true
    web.layer.anchorPoint = .zero
    addSubview(web)
  }

  required init?(coder: NSCoder) { fatalError() }

  func setCursor(row: Int, rows: Int) {
    cursor = (0..<rows).contains(row) ? (row, rows) : nil
    positionCanvas()
  }

  func setMeasurement(area: CGSize, grid: CGSize) {
    guard measuredArea != area || self.grid != grid else { return }
    measuredArea = area
    self.grid = grid
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0 else { return }
    // The keyboard clips this viewport. Only a change to the session's full
    // bounds (such as rotation) should change the web page or send a PTY resize.
    let fullHeight = superview.map { convert($0.bounds, from: $0).maxY } ?? bounds.height
    let canvas = CGSize(width: bounds.width, height: max(fullHeight, bounds.height))
    UIView.performWithoutAnimation {
      if web.bounds.size != canvas { web.bounds = CGRect(origin: .zero, size: canvas) }
      if grid.width > 0, grid.height > 0,
         abs(measuredArea.width - canvas.width) < 1, abs(measuredArea.height - canvas.height) < 1 {
        web.transform = CGAffineTransform(scaleX: canvas.width / grid.width, y: canvas.height / grid.height)
      }
      positionCanvas()
    }
  }

  private func positionCanvas() {
    let height = web.bounds.height
    let travel = max(0, height - bounds.height)
    // TUI composers draw their border, extra input lines and footer below the
    // caret. Show the bottom of the grid on open, including for a software caret.
    if offset == previousTravel { offset = travel }
    if travel > 0, let cursor {
      let rowHeight = height / CGFloat(cursor.rows)
      let top = CGFloat(cursor.row) * rowHeight
      if top < offset {
        offset = max(0, top - 2 * rowHeight)
      } else if top + rowHeight > offset + bounds.height {
        // Return to the bottom when it fits with the caret. In a short window
        // center an intermediate caret until the bottom becomes reachable.
        offset = top >= travel ? travel : top + (rowHeight - bounds.height) / 2
      }
    }
    offset = min(travel, max(0, offset))
    previousTravel = travel
    UIView.performWithoutAnimation {
      web.layer.position = CGPoint(x: bounds.minX, y: bounds.minY - offset)
    }
  }

  func relativeGridPoint(_ point: CGPoint) -> CGPoint {
    let local = web.convert(point, from: self)
    return CGPoint(x: local.x / max(1, grid.width), y: local.y / max(1, grid.height))
  }
}

final class Screen: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
  static let surface = UIColor(red: 10 / 255, green: 20 / 255, blue: 26 / 255, alpha: 1)
  let client: ClientProfile
  let target: Int64
  private let session: RemoteSession?
  private let touchPaging: Bool
  private let heading: String
  private let status = UILabel()
  private let latency = UILabel()
  private let statusBar = UIStackView()
  private let reconnectButton = UIButton(type: .system)
  private weak var navigationStatus: TerminalNavigationStatus?
  private var island: IslandReporting?
  private var activityState = TerminalActivityState()
  private var backgrounded = false
  private var expiry: Timer?
  private var completed = false
  private var generation = 0
  private var navigation: WKNavigation?
  private var recoveryEnabled = false
  private var retryCount = 0
  private var retryTask: Task<Void, Never>?
  private var resumeCheck: Task<Void, Never>?
  private var resumedAt: Date?
  private var verifyingConnection = false
  private var previouslyConnected = false
  // The worker holds at most one frame while WebKit is suspended. Socket
  // backpressure keeps further output on the transport until the view resumes.
  private final class DisplayFrame {
    let bytes: Data
    let delivered = DispatchSemaphore(value: 0)
    var submitted = false
    init(_ bytes: Data) { self.bytes = bytes }
  }
  private var displayFrame: DisplayFrame?
  private var displayDeadline: Timer?
  private var displayStartedAt = Date()
  private var attachedClientPID: UInt32?
  private var drawerOpen = false
  private var agentIdentity: String?
  private var contextPoll: Task<Void, Never>?
  private var pendingReply: Task<Void, Never>?
  private let transportBadge = UILabel()
  private var shortcuts: ShortcutDrawer!
  private weak var uploadFlow: SessionUploadFlow?
  private weak var uploadController: UIViewController?
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
  private var web: TerminalWebView!
  private var viewport: TerminalViewport!
  private var fd: Int32 = -1
  private var started = false
  private var active = true
  private var dimensions: (UInt16, UInt16)?
  private var sentDimensions: (UInt16, UInt16)?
  init(
    client: ClientProfile, session: RemoteSession?,
    navigationStatus: TerminalNavigationStatus? = nil, leave: (() -> Void)? = nil
  ) {
    self.leave = leave
    self.client = client
    self.session = session
    self.navigationStatus = navigationStatus
    touchPaging = session?.touchPaging == true
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
    web = TerminalWebView(frame: .zero, configuration: config)
    web.typingKeyboard.isUserInteractionEnabled = false
    web.typingKeyboard.onText = { [weak self] text in self?.sendTerminalKey(text) }
    web.shortcutBar.press = { [weak self] key in self?.press(key) }
    web.shortcutBar.hideKeyboard = { [weak self] in self?.setKeyboardVisible(false) }
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
    reconnectButton.configuration = .plain()
    reconnectButton.configuration?.title = "重连"
    reconnectButton.accessibilityIdentifier = "terminal.reconnect"
    reconnectButton.accessibilityLabel = "重新连接此会话"
    reconnectButton.addTarget(self, action: #selector(retryManually), for: .touchUpInside)
    reconnectButton.isHidden = true
    reconnectButton.configuration?.contentInsets = .init(top: 12, leading: 10, bottom: 12, trailing: 10)
    [status, transportBadge, latency, reconnectButton].forEach(bar.addArrangedSubview)
    bar.alignment = .center
    bar.spacing = 10
    bar.isLayoutMarginsRelativeArrangement = true
    bar.directionalLayoutMargins = .init(top: 5, leading: 7, bottom: 5, trailing: 7)
    status.setContentHuggingPriority(.defaultLow, for: .horizontal)
    transportBadge.setContentHuggingPriority(.required, for: .horizontal)
    latency.setContentHuggingPriority(.required, for: .horizontal)
    latency.setContentCompressionResistancePriority(.required, for: .horizontal)
    web.shortcutBar.isHidden = true
    web.typingKeyboard.isHidden = true
    let stack = UIStackView(arrangedSubviews: [bar, viewport!, web.shortcutBar, web.typingKeyboard])
    stack.axis = .vertical
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
    ])
    shortcuts = ShortcutDrawer(in: viewport, accent: accent, leave: leave,
                               review: { [weak self] in self?.reviewDecisions() },
                               upload: { [weak self] in self?.chooseUpload() }) { [weak self] key in self?.press(key) }
    web.typingKeyboard.onAgentReply = { [weak self] text in self?.insertAgentReply(text) }
    shortcuts.onAgentReply = web.typingKeyboard.onAgentReply
    shortcuts.onVisibilityChange = { [weak self] open in
      self?.drawerOpen = open
      self?.updateAgentMonitoring()
    }
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
    loadTerminalPage()
    NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)),
                                          name: UIScene.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)),
                                          name: UIScene.didActivateNotification, object: nil)
  }

  @objc private func sceneChanged(_ notification: Notification) {
    guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
    if notification.name == UIScene.didEnterBackgroundNotification { pauseStatus() }
    else { resumeStatus() }
  }
  private func chooseUpload() {
    guard active, ready, !backgrounded, !verifyingConnection, presentedViewController == nil else { return }
    let flow = SessionUploadFlow(client: client) { [weak self] in
      guard let self else { throw CancellationError() }
      return try await self.uploadTarget()
    }
    let host = UIHostingController(rootView: SessionUploadView(flow: flow))
    host.modalPresentationStyle = .pageSheet
    host.sheetPresentationController?.detents = [.medium(), .large()]
    uploadFlow = flow
    uploadController = host
    present(host, animated: true) { [weak self, weak host, weak flow] in
      guard let host, self?.presentedViewController === host else { return }
      flow?.begin()
    }
  }

  private func uploadTarget() async throws -> RemoteSession {
    guard let session, session.id >= 0 else { throw RelayError("请从会话列表打开一个具名会话后再上传。") }
    guard active, ready, !backgrounded, !verifyingConnection else { throw RelayError("请等待终端恢复连接后再上传。") }
    let attempt = generation
    let rows = try await SessionDirectory.fetch(client)
    try Task.checkCancellation()
    guard let current = rows.first(where: { Self.sameSession(session, $0) }) else {
      throw RelayError("会话已变化，请返回会话列表重新打开。")
    }
    guard current.uploadVersion == 1 else { throw RelayError("请更新节点上的 tmux-link-agent 后再上传。") }
    guard let pid = attachedClientPID, let instance = current.managedInstance, !instance.isEmpty,
          let directory = current.directory, directory.hasPrefix("/") else {
      throw RelayError("无法核对当前窗格与目录，请返回会话列表重新进入。")
    }
    let pane = try await TerminalTransport.attachedPane(client, sessionID: session.id, attachPID: pid)
    try Task.checkCancellation()
    guard isCurrent(attempt), ready, !backgrounded, !verifyingConnection, attachedClientPID == pid,
          session.id == pane.id, instance == pane.instance else {
      throw RelayError("终端当前显示的窗格已切换，请从列表重新进入目标会话。")
    }
    return current
  }

  private func reviewDecisions() {
    guard active, ready, presentedViewController == nil else { return }
    web.evaluateJavaScript("decisionScreen()") { [weak self] value, error in
      guard let self, self.active, self.ready, self.view.window != nil,
            self.presentedViewController == nil else { return }
      guard error == nil, let lines = value as? [String: String], let text = lines["text"] else {
        let alert = UIAlertController(title: "无法读取当前画面", message: "请稍后重新打开决策助手。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        self.present(alert, animated: true)
        return
      }
      // Legacy interactive connections have one visible terminal, without a numeric session ID.
      let snapshot = DecisionSnapshot(id: max(0, self.target), name: self.heading,
                                      text: text, context: lines["context"])
      let alternate = lines["bufferType"] == "alternate"
      var hostRead: (() async throws -> DecisionSnapshot)?
      if alternate, let session = self.session, session.negotiatedSnapshotVersion == .v2 {
        let client = self.client
        hostRead = { try await SessionDirectory.snapshot(session, client: client) }
      }
      let review = DecisionReviewView(snapshot: snapshot, alternate: alternate, hostRead: hostRead) { [weak self] in
        self?.dismiss(animated: true)
      }
      self.present(UIHostingController(rootView: review.preferredColorScheme(.dark)), animated: true)
    }
  }

  private func showAgentIdentity(_ identity: String?) {
    agentIdentity = identity
    web?.typingKeyboard.setAgentContext(identity)
    shortcuts?.setAgentContext(identity)
  }

  private func updateAgentMonitoring() {
    guard active, ready, !verifyingConnection, !backgrounded, let pid = attachedClientPID,
          drawerOpen || !web.typingKeyboard.isHidden else {
      contextPoll?.cancel()
      contextPoll = nil
      showAgentIdentity(nil)
      return
    }
    guard contextPoll == nil else { return }
    contextPoll = Task { [weak self, client, target] in
      while !Task.isCancelled {
        let identity = try? await TerminalTransport.agentIdentity(client, sessionID: target, attachPID: pid)
        guard !Task.isCancelled else { return }
        self?.showAgentIdentity(identity)
        do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
      }
    }
  }

  private func insertAgentReply(_ text: String) {
    guard active, ready, !backgrounded, let expected = agentIdentity, let pid = attachedClientPID else { return }
    pendingReply?.cancel()
    pendingReply = Task { [weak self, client, target] in
      let current = try? await TerminalTransport.agentIdentity(client, sessionID: target, attachPID: pid)
      guard !Task.isCancelled, let self, active, ready, !backgrounded, attachedClientPID == pid else { return }
      pendingReply = nil
      guard current == expected else {
        showAgentIdentity(nil)
        return
      }
      sendTerminalKey(text)
    }
  }

  private func setKeyboardVisible(_ visible: Bool) {
    guard web.typingKeyboard.isHidden == visible else { return }
    UIView.performWithoutAnimation {
      web.shortcutBar.isHidden = !visible
      web.typingKeyboard.isHidden = !visible
      view.layoutIfNeeded()
    }
    updateAgentMonitoring()
    web.evaluateJavaScript(visible ? "trackKeyboardCursor(true)" : "trackKeyboardCursor(false); term.blur()",
                           completionHandler: nil)
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
    let attempt = generation
    var actions: [UIMenuElement] = []
    if !snapshot.selected.isEmpty {
      actions.append(UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
        UIPasteboard.general.string = snapshot.selected
      })
    }
    actions += [
      UIAction(title: "粘贴", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
        guard let self, isCurrent(attempt), ready, !verifyingConnection, !backgrounded,
              let text = UIPasteboard.general.string, !text.isEmpty else { return }
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
    let dy = pan.translation(in: viewport).y
    switch pan.state {
    case .began:
      let point = pan.location(in: viewport)
      scrollOrigin = viewport.relativeGridPoint(CGPoint(x: point.x, y: point.y - dy))
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
    guard active, !backgrounded else { return }
    backgrounded = true
    uploadFlow?.enteredBackground()
    if !completed && session?.managedInstance != nil {
      recoveryEnabled = true
    }
    resumeCheck?.cancel()
    if let retryTask {
      retryTask.cancel()
      self.retryTask = nil
      retryCount = max(0, retryCount - 1)
      reconnectButton.isHidden = false
    }
    displayDeadline?.invalidate()
    displayDeadline = nil
    pendingReply?.cancel()
    updateAgentMonitoring()
    // Flush any coalesced reading with its original deadline before suspension.
    if !completed { refreshStatus(immediately: true) }
  }

  @objc private func resumeStatus() {
    guard active, backgrounded else { return }
    backgrounded = false
    if completed {
      scheduleRecovery()
      return
    }
    if !started, navigation == nil {
      loadTerminalPage()
    }
    displayStartedAt = Date()
    displayIfVisible()
    if recoveryEnabled && ready { checkResumedConnection() }
    updateAgentMonitoring()
    refreshStatus(immediately: true)
    startIslandIfAvailable()
  }

  private func checkResumedConnection() {
    // A suspended TCP connection may look writable until the next SSH ping.
    // Once its last reading is stale, enable typing only after a new reading.
    resumedAt = Date()
    verifyingConnection = activityState.staleDate <= Date()
    setInputEnabled(!verifyingConnection)
    let attempt = generation
    resumeCheck?.cancel()
    resumeCheck = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
      guard let self, isCurrent(attempt), !backgrounded, resumedAt != nil else { return }
      finish("原连接未响应")
    }
  }

  private func setInputEnabled(_ enabled: Bool) {
    shortcuts?.setReady(enabled)
    web?.shortcutBar.setReady(enabled)
    web?.typingKeyboard.isUserInteractionEnabled = enabled
  }

  private func loadTerminalPage() {
    let bridge = web.configuration.userContentController
    bridge.removeAllUserScripts()
    let paging = touchPaging ? "agent" : target >= 0 ? "tmux" : "keys"
    bridge.addUserScript(WKUserScript(
      source: "window.touchPaging = '\(paging)'; window.terminalConnectionID = \(generation)",
      injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets")!
    navigation = web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
  }

  private func isCurrent(_ attempt: Int) -> Bool {
    active && !completed && generation == attempt
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard active, !completed else { return }
    recoveryEnabled = previouslyConnected && session?.managedInstance != nil
    finish("终端画面已暂停")
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation failed: WKNavigation!, withError error: Error) {
    guard let failed, navigation === failed else { return }
    finish("终端页面加载失败")
  }

  func webView(_ webView: WKWebView, didFail failed: WKNavigation!, withError error: Error) {
    guard let failed, navigation === failed else { return }
    finish("终端页面加载失败")
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
    guard active, !completed, !started, self.navigation === navigation else { return }
    self.navigation = nil
    guard !backgrounded else { return }
    started = true
    let attempt = generation
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
      recoveryEnabled = false
      finish(error.localizedDescription)
      return
    }
    let hasIdentity = connection.identity != nil
    let trackAgent = session?.agentContextVersion == 1 && target >= 0
    let result = Task.detached(priority: .userInitiated) { [target] in
      connection.run(worker, target: target, fitInitialGrid: true, contextPID: trackAgent ? 0 : nil)
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let stream = FileHandle(fileDescriptor: reader, closeOnDealloc: true)
      do {
        while let (kind, payload) = try Self.readFrame(from: stream) {
          if kind == 1 {
            let stage = String(decoding: payload, as: UTF8.self)
            let observedAt = Date()
            DispatchQueue.main.async { [weak self] in
              guard let self, isCurrent(attempt) else { return }
              self.stage(stage, hasIdentity: hasIdentity, observedAt: observedAt)
            }
          } else if kind == 2 {
            guard payload.count == 4 else { throw RelayError("延迟数据格式错误") }
            let ms = payload.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let observedAt = Date()
            DispatchQueue.main.async { [weak self] in
              guard let self, isCurrent(attempt) else { return }
              updateLatency(ms, observedAt: observedAt)
            }
          } else if kind == 3 && payload.isEmpty {
            DispatchQueue.main.async { [weak self] in
              guard let self, isCurrent(attempt), !backgrounded, view.window != nil, presentedViewController == nil else { return }
              let alert = UIAlertController(title: "暂时无法翻页", message: "会话仍已连接，请稍后再滑动一次。", preferredStyle: .alert)
              alert.addAction(UIAlertAction(title: "好", style: .default))
              present(alert, animated: true)
            }
          } else if kind == 4 && trackAgent && payload.count == 4 {
            let pid = payload.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            DispatchQueue.main.async { [weak self] in
              guard let self, isCurrent(attempt), attachedClientPID == nil, pid > 0 else { return }
              attachedClientPID = pid
              updateAgentMonitoring()
            }
          } else if kind == 0 {
            let frame = DisplayFrame(payload)
            DispatchQueue.main.async { [weak self] in
              guard let self, isCurrent(attempt) else {
                frame.delivered.signal()
                return
              }
              displayFrame = frame
              displayStartedAt = Date()
              displayIfVisible()
            }
            frame.delivered.wait()
          } else {
            throw RelayError("终端数据格式错误")
          }
        }
        Task { @MainActor [weak self] in
          let error = await result.value
          guard let self, isCurrent(attempt) else { return }
          finish(error ?? "会话已断开")
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, isCurrent(attempt) else { return }
          finish(error.localizedDescription)
        }
      }
    }
  }

  private func displayIfVisible() {
    guard !backgrounded, let frame = displayFrame else { return }
    watchDisplay()
    guard !frame.submitted else { return }
    frame.submitted = true
    web.callAsyncJavaScript("await window.display(bytes)", arguments: ["bytes": frame.bytes.base64EncodedString()],
                            in: nil, in: .page) { [weak self] result in
      guard let self, displayFrame === frame else { return }
      if case .failure = result {
        finish("终端画面未能恢复")
      } else {
        releaseDisplayFrame()
      }
    }
  }

  private func watchDisplay() {
    guard !backgrounded, displayFrame != nil, displayDeadline == nil else { return }
    let remaining = displayStartedAt.addingTimeInterval(30).timeIntervalSinceNow
    guard remaining > 0 else { finish("终端显示超时"); return }
    // Recheck the age of whichever frame is outstanding. A continuous stream
    // of output uses one timer per 30s, not one timer per render.
    displayDeadline = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
      self?.displayDeadline = nil
      self?.watchDisplay()
    }
  }

  private func releaseDisplayFrame() {
    displayFrame?.delivered.signal()
    displayFrame = nil
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
      previouslyConnected = true
      if recoveryEnabled, !backgrounded { checkResumedConnection() }
      updateAgentMonitoring()
      statusBar.isHidden = navigationStatus != nil
      setInputEnabled(!verifyingConnection)
      if !web.typingKeyboard.isHidden {
        web.evaluateJavaScript("trackKeyboardCursor(true)", completionHandler: nil)
      }
      transportBadge.text = hasIdentity ? "mTLS · SSH" : "SSH"
    }
    if phase == .attaching || phase == .ready { resize() }
    refreshStatus()
  }

  private func updateLatency(_ ms: UInt32, observedAt: Date) {
    guard active, ready else { return }
    activityState.observedAt = observedAt
    activityState.milliseconds = ms == .max ? nil : ms
    activityState.timedOut = ms == .max
    if !backgrounded, ms != .max, resumedAt.map({ observedAt >= $0 }) ?? true {
      if verifyingConnection {
        verifyingConnection = false
        setInputEnabled(true)
        updateAgentMonitoring()
      }
      resumeCheck?.cancel()
      resumeCheck = nil
      // After suspension the first frame may contain a ping sampled before
      // sleep, immediately followed by EOF. Keep recovery armed through two
      // fresh five-second heartbeat intervals.
      if resumedAt.map({ observedAt.timeIntervalSince($0) >= 12 }) ?? true {
        resumedAt = nil
        retryCount = 0
        recoveryEnabled = false
      }
    }
    refreshStatus()
  }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard active, !completed, message.frameInfo.isMainFrame, let obj = message.body as? [String: Any],
          obj["connectionID"] as? Int == generation else {
      return
    }
    if ready, !verifyingConnection, !backgrounded, touchPaging, let direction = obj["page"] as? String, ["up", "down"].contains(direction) {
      send(2, Data([direction == "up" ? 1 : 0]))
    }
    if let cursor = obj["cursor"] as? [String: Int], let row = cursor["row"], let rows = cursor["rows"],
       rows > 0, rows <= Int(UInt16.max) {
      viewport.setCursor(row: row, rows: rows)
    }
    if obj["showKeyboard"] as? Bool == true, ready, !verifyingConnection, !backgrounded { setKeyboardVisible(true) }
    if let metrics = obj["layout"] as? [String: Double],
      let w = metrics["width"], let h = metrics["height"],
      let gw = metrics["gridWidth"], let gh = metrics["gridHeight"] {
      viewport.setMeasurement(area: CGSize(width: w, height: h), grid: CGSize(width: gw, height: gh))
    }
    let bytes = (obj["data"] as? String).map { Data($0.utf8) }
      ?? (obj["binary"] as? String).flatMap { Data(base64Encoded: $0) }
    if ready, !verifyingConnection, !backgrounded, let bytes {
      pendingReply?.cancel()
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
    guard let (c, r) = dimensions,
          ready || (activityState.phase == .attaching && sentDimensions == nil) else { return }
    if let sentDimensions, sentDimensions == (c, r) { return }
    sentDimensions = (c, r)
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
    let attempt = generation
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
        guard let self, self.isCurrent(attempt) else { return }
        self.pendingBytes -= packet.count
        if !ok && self.fd >= 0 { self.finish("输入通道已断开") }
      }
    }
  }
  private func finish(_ message: String) {
    guard active, !completed else { return }
    generation += 1
    completed = true
    navigation = nil
    resumeCheck?.cancel()
    resumeCheck = nil
    resumedAt = nil
    statusBar.directionalLayoutMargins.top = 5 + max(view.safeAreaInsets.top, 20)
    statusBar.isHidden = false
    reconnectButton.isHidden = false
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
    scheduleRecovery()
  }

  nonisolated static func sameSession(_ original: RemoteSession, _ current: RemoteSession) -> Bool {
    guard original.id == current.id else { return false }
    // A pane switch and a session rename are both legitimate. The tmux server
    // PID and session creation time remain stable across both operations.
    if let originalInstance = original.managedInstance {
      let parts = originalInstance.split(separator: "-")
      guard parts.count == 4, let other = current.managedInstance?.split(separator: "-"),
            other.count == 4 else { return false }
      return parts.prefix(2).elementsEqual(other.prefix(2))
    }
    return original.name == current.name
  }

  @objc private func retryManually() {
    retryCount = 0
    recoveryEnabled = false
    scheduleRecovery(manual: true)
  }

  private func scheduleRecovery(manual: Bool = false) {
    let delays: [UInt64] = [0, 1, 3]
    guard active, completed, !backgrounded, retryTask == nil,
          manual || (recoveryEnabled && retryCount < delays.count) else { return }
    let attempt = generation
    let delay = manual ? 0 : delays[retryCount]
    if !manual { retryCount += 1 }
    status.text = "◌  正在恢复会话"
    reconnectButton.isHidden = true
    retryTask = Task { [weak self, client, session] in
      do {
        try await Task.sleep(nanoseconds: delay * 1_000_000_000)
        if let session {
          let sessions = try await SessionDirectory.fetch(client)
          try Task.checkCancellation()
          guard sessions.contains(where: { Self.sameSession(session, $0) }) else {
            self?.retryTask = nil
            self?.recoveryEnabled = false
            self?.status.text = "原会话已结束或已更换，请返回会话列表"
            return
          }
        }
      } catch {
        guard let self, !Task.isCancelled, active, generation == attempt else { return }
        retryTask = nil
        reconnectButton.isHidden = false
        status.text = "○  " + error.localizedDescription
        scheduleRecovery()
        return
      }
      guard let self, !Task.isCancelled, active, !backgrounded, generation == attempt else { return }
      retryTask = nil
      completed = false
      started = false
      dimensions = nil
      sentDimensions = nil
      activityState = TerminalActivityState()
      status.textColor = .secondaryLabel
      statusBar.directionalLayoutMargins.top = 5
      statusBar.isHidden = navigationStatus != nil
      startIslandIfAvailable()
      refreshStatus(immediately: true)
      loadTerminalPage()
    }
  }

  private func disconnect() {
    uploadFlow?.cancel()
    if let uploadController, presentedViewController === uploadController { dismiss(animated: false) }
    uploadFlow = nil
    uploadController = nil
    ready = false
    verifyingConnection = false
    pendingBytes = 0
    displayDeadline?.invalidate()
    displayDeadline = nil
    releaseDisplayFrame()
    pendingReply?.cancel()
    attachedClientPID = nil
    updateAgentMonitoring()
    setInputEnabled(false)
    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      close(fd)
      fd = -1
    }
  }
  private func press(_ key: String) {
    guard ready else { return }
    sendTerminalKey(key)
    UISelectionFeedbackGenerator().selectionChanged()
  }

  private func sendTerminalKey(_ key: String) {
    guard ready, !verifyingConnection, !backgrounded else { return }
    web.callAsyncJavaScript("pressTerminalKey(key)", arguments: ["key": key], in: nil, in: .page, completionHandler: nil)
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
    retryTask?.cancel()
    resumeCheck?.cancel()
    expiry?.invalidate()
    island?.end()
    island = nil
    NotificationCenter.default.removeObserver(self)
    disconnect()
    web?.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
  }
}
