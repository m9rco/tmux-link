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

// Draw both keyboard surfaces in the session window. Remote keyboard windows
// cannot reliably composite a child WKWebView.
final class TerminalWebView: WKWebView {
  let shortcutBar = TerminalKeyboardBar()
  let typingKeyboard = TerminalTypingKeyboard()
  override var inputAccessoryView: UIView? { nil }
}

private final class KeyboardSurface: WKWebView {
  // A tap on a key must leave the terminal as first responder.
  override var canBecomeFirstResponder: Bool { false }
}

private final class TypingBridge: NSObject, WKScriptMessageHandler {
  var onText: ((String) -> Void)?

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: String],
          let text = body["text"], !text.isEmpty, text.utf8.count <= 512 else { return }
    onText?(text)
  }
}

final class AgentReplyButton: UIButton {
  var onInsert: ((String) -> Void)?
  private var context: String?
  private var generation: UInt64 = 0

  init(identifier: String) {
    super.init(frame: .zero)
    setTitle("Agent", for: .normal)
    titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    setTitleColor(.systemMint, for: .normal)
    accessibilityIdentifier = identifier
    accessibilityLabel = "Agent 快捷回复"
    accessibilityHint = "选择一条短语或命令插入当前输入位置"
    showsMenuAsPrimaryAction = true
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  func setAgentContext(_ identity: String?) {
    guard context != identity else { return }
    context = identity
    generation &+= 1
    contextMenuInteraction?.dismissMenu()
    isHidden = identity == nil
    guard identity != nil else {
      menu = nil
      return
    }

    let revision = generation
    func group(_ title: String, _ phrases: [String]) -> UIMenu {
      let actions = phrases.map { phrase in
        UIAction(title: phrase, identifier: UIAction.Identifier("terminal.agent." + phrase)) { [weak self] _ in
          guard let self, generation == revision, !isHidden, isEnabled else { return }
          onInsert?(phrase)
        }
      }
      return UIMenu(title: title, options: .displayInline, children: actions)
    }
    menu = UIMenu(children: [
      group("常用回复", ["Proceed", "Keep going", "Follow up on this", "Ack", "Summarize progress", "Run the tests"]),
      group("斜杠命令", ["/compact", "/models", "/help"])
    ])
  }
}

final class TerminalTypingKeyboard: UIView, WKNavigationDelegate {
  private let bridge = TypingBridge()
  private let agentButton = AgentReplyButton(identifier: "terminal.typing.agent")
  private let agentButtonWidth: CGFloat = 60
  let surface: WKWebView
  private var panelHeight: NSLayoutConstraint!
  var onText: ((String) -> Void)? {
    get { bridge.onText }
    set { bridge.onText = newValue }
  }
  var onAgentReply: ((String) -> Void)? {
    get { agentButton.onInsert }
    set { agentButton.onInsert = newValue }
  }

  init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(bridge, name: "typingKeyboard")
    surface = KeyboardSurface(frame: .zero, configuration: config)
    super.init(frame: .zero)
    panelHeight = heightAnchor.constraint(equalToConstant: preferredHeight)
    panelHeight.priority = UILayoutPriority(999)
    panelHeight.isActive = true
    backgroundColor = Screen.surface
    surface.isOpaque = false
    surface.backgroundColor = Screen.surface
    surface.underPageBackgroundColor = Screen.surface
    surface.scrollView.isScrollEnabled = false
    surface.scrollView.contentInsetAdjustmentBehavior = .never
    surface.accessibilityIdentifier = "terminal.typing"
    surface.navigationDelegate = self
    surface.translatesAutoresizingMaskIntoConstraints = false
    agentButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(surface)
    addSubview(agentButton)
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      surface.topAnchor.constraint(equalTo: topAnchor),
      surface.bottomAnchor.constraint(equalTo: bottomAnchor),
      agentButton.leftAnchor.constraint(equalTo: surface.leftAnchor),
      agentButton.topAnchor.constraint(equalTo: surface.topAnchor),
      agentButton.widthAnchor.constraint(equalToConstant: agentButtonWidth),
      agentButton.heightAnchor.constraint(equalToConstant: 30)
    ])
    let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets/keyboard")!
    surface.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
  }

  required init?(coder: NSCoder) { fatalError() }

  private var preferredHeight: CGFloat { traitCollection.verticalSizeClass == .compact ? 150 : 216 }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if previous?.verticalSizeClass != traitCollection.verticalSizeClass { panelHeight?.constant = preferredHeight }
  }

  func setAgentContext(_ identity: String?) {
    let wasHidden = agentButton.isHidden
    agentButton.setAgentContext(identity)
    if wasHidden != agentButton.isHidden { updatePunctuationInset() }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    updatePunctuationInset()
  }

  private func updatePunctuationInset() {
    let width = agentButton.isHidden ? 0 : agentButtonWidth
    surface.evaluateJavaScript("document.getElementById('punctuation').style.marginLeft = '\(width)px'", completionHandler: nil)
  }

  func resetLayout() {
    surface.evaluateJavaScript("window.resetLayout?.()", completionHandler: nil)
  }
}

final class TerminalKeyboardBar: UIView {
  var press: ((String) -> Void)?
  var hideKeyboard: (() -> Void)?
  private var remoteButtons: [UIButton] = []

  init() {
    super.init(frame: .zero)
    let height = heightAnchor.constraint(equalToConstant: 44)
    height.priority = UILayoutPriority(999)
    height.isActive = true
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
    for key: TerminalKey in [.escape, .tab, .interrupt, .prefix, .left, .up, .down, .right] {
      let button = UIButton(type: .system)
      button.setTitle(key.title, for: .normal)
      button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
      button.tintColor = key == .escape ? .systemOrange : .label
      button.accessibilityIdentifier = "terminal.keyboard." + key.title
      switch key {
      case .interrupt: button.accessibilityLabel = "Control C"
      case .prefix: button.accessibilityLabel = "Control B"
      case .left: button.accessibilityLabel = "方向左"
      case .up: button.accessibilityLabel = "方向上"
      case .down: button.accessibilityLabel = "方向下"
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
