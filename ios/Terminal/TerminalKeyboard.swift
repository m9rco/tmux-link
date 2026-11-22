import UIKit
import WebKit

enum TerminalKey: String, CaseIterable {
  case escape = "\u{1b}", pageUp = "\u{1b}[5~", pageDown = "\u{1b}[6~"
  case tab = "\t", interrupt = "\u{03}", prefix = "\u{02}"
  case up = "\u{1b}[A", down = "\u{1b}[B", left = "\u{1b}[D", right = "\u{1b}[C", enter = "\r"

  var title: String {
    switch self {
    case .escape: return "Esc"
    case .pageUp: return "PgUp"
    case .pageDown: return "PgDn"
    case .tab: return "Tab"
    case .interrupt: return "⌃C"
    case .prefix: return "⌃B"
    case .up: return "↑"
    case .down: return "↓"
    case .left: return "←"
    case .right: return "→"
    case .enter: return "↵"
    }
  }
}

// WebKit forwards its focused text control's input views to the host web view.
final class TerminalWebView: WKWebView {
  let shortcutBar = TerminalKeyboardBar()
  let typingKeyboard = TerminalTypingKeyboard()
  override var inputView: UIView? { typingKeyboard }
  override var inputAccessoryView: UIView? { shortcutBar }
}

private final class KeyboardSurface: WKWebView {
  // A tap on a key must leave the terminal as first responder.
  override var canBecomeFirstResponder: Bool { false }
}

private final class TypingBridge: NSObject, WKScriptMessageHandler {
  static let languagePreference = "terminal.typing.language"
  var onText: ((String) -> Void)?

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
    if let language = body["language"], ["en", "zh"].contains(language) {
      UserDefaults.standard.set(language, forKey: Self.languagePreference)
    } else if let text = body["text"], !text.isEmpty, text.utf8.count <= 512 {
      onText?(text)
    }
  }
}

final class TerminalTypingKeyboard: UIInputView {
  private let bridge = TypingBridge()
  let surface: WKWebView
  var onText: ((String) -> Void)? {
    get { bridge.onText }
    set { bridge.onText = newValue }
  }

  init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(bridge, name: "typingKeyboard")
    let chinese = UserDefaults.standard.string(forKey: TypingBridge.languagePreference) == "zh"
    config.userContentController.addUserScript(WKUserScript(
      source: chinese ? "window.initialLanguage = 'zh'" : "window.initialLanguage = 'en'",
      injectionTime: .atDocumentStart, forMainFrameOnly: true))
    surface = KeyboardSurface(frame: .zero, configuration: config)
    super.init(frame: CGRect(x: 0, y: 0, width: 375, height: 216), inputViewStyle: .keyboard)
    allowsSelfSizing = true
    backgroundColor = Screen.surface
    surface.isOpaque = false
    surface.backgroundColor = Screen.surface
    surface.underPageBackgroundColor = Screen.surface
    surface.scrollView.isScrollEnabled = false
    surface.scrollView.contentInsetAdjustmentBehavior = .never
    surface.accessibilityIdentifier = "terminal.typing"
    surface.translatesAutoresizingMaskIntoConstraints = false
    addSubview(surface)
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      surface.topAnchor.constraint(equalTo: topAnchor),
      surface.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
    ])
    let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets/keyboard")!
    surface.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    NotificationCenter.default.addObserver(self, selector: #selector(clearComposition),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: traitCollection.verticalSizeClass == .compact ? 150 : 216)
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if previous?.verticalSizeClass != traitCollection.verticalSizeClass { invalidateIntrinsicContentSize() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { clearComposition() }
  }

  @objc func clearComposition() {
    surface.evaluateJavaScript("window.resetComposition?.()", completionHandler: nil)
  }

  func handleShortcut(_ key: String) {
    surface.callAsyncJavaScript("handleShortcut(key)", arguments: ["key": key], in: nil, in: .page) {
      [weak self] result in
      // The native shortcut row can become available before the layout has loaded.
      if case .failure = result { self?.onText?(key) }
    }
  }
}

final class TerminalKeyboardBar: UIInputView {
  var press: ((String) -> Void)?
  var hideKeyboard: (() -> Void)?
  private var remoteButtons: [UIButton] = []

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 375, height: 44), inputViewStyle: .keyboard)
    overrideUserInterfaceStyle = .dark
    backgroundColor = Screen.surface
    autoresizingMask = .flexibleWidth
    accessibilityIdentifier = "terminal.keyboard"
    let row = UIStackView()
    row.distribution = .fillEqually
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    for key: TerminalKey in [.escape, .tab, .interrupt, .prefix, .left, .right] {
      let button = UIButton(type: .system)
      button.setTitle(key.title, for: .normal)
      button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
      button.tintColor = key == .escape ? .systemOrange : .label
      button.accessibilityIdentifier = "terminal.keyboard." + key.title
      switch key {
      case .interrupt: button.accessibilityLabel = "Control C"
      case .prefix: button.accessibilityLabel = "Control B"
      case .left: button.accessibilityLabel = "方向左"
      case .right: button.accessibilityLabel = "方向右"
      default: break
      }
      button.addAction(UIAction { [weak self] _ in self?.press?(key.rawValue) }, for: .touchUpInside)
      row.addArrangedSubview(button)
      remoteButtons.append(button)
    }
    let hide = UIButton(type: .system)
    hide.tintColor = .secondaryLabel
    hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
    hide.accessibilityIdentifier = "terminal.keyboard.hide"
    hide.accessibilityLabel = "收起键盘"
    hide.addAction(UIAction { [weak self] _ in self?.hideKeyboard?() }, for: .touchUpInside)
    row.addArrangedSubview(hide)
    setReady(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  func setReady(_ ready: Bool) {
    remoteButtons.forEach { $0.isEnabled = ready }
  }
}
