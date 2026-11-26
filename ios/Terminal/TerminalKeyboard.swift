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

final class TerminalWebView: WKWebView {
  let shortcutBar = TerminalKeyboardBar()
  var englishKeyboard: TerminalEnglishKeyboard { shortcutBar.englishKeyboard }
  override var inputAccessoryView: UIView? { nil }
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

final class TerminalKeyboardBar: UIView {
  var press: ((String) -> Void)?
  var hideKeyboard: (() -> Void)?
  var changeMode: (() -> Void)?
  var onPaste: (([NSItemProvider]) -> Void)?
  var onAgentReply: ((String) -> Void)? {
    get { agentButton.onInsert }
    set { agentButton.onInsert = newValue }
  }

  private let agentButton = AgentReplyButton(identifier: "terminal.typing.agent")
  let englishKeyboard = TerminalEnglishKeyboard()
  private(set) var isEnglishMode = false
  private let modeButton = UIButton(type: .system)
  private let rows = UIStackView()
  private var windowBottomLimit: NSLayoutConstraint?
  private let pasteControl: UIPasteControl
  private var remoteButtons: [UIButton] = []
  private(set) var isReady = false

  init() {
    let config = UIPasteControl.Configuration()
    config.displayMode = .iconAndLabel
    config.baseForegroundColor = .systemMint
    config.baseBackgroundColor = UIColor.systemMint.withAlphaComponent(0.15)
    pasteControl = UIPasteControl(configuration: config)
    super.init(frame: .zero)
    accessibilityIdentifier = "terminal.keyboard"
    overrideUserInterfaceStyle = .dark
    backgroundColor = Screen.surface
    pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
    pasteControl.accessibilityIdentifier = "terminal.keyboard.paste"
    let hide = UIButton(type: .system)
    hide.tintColor = .secondaryLabel
    hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
    hide.accessibilityIdentifier = "terminal.keyboard.hide"
    hide.accessibilityLabel = "收起键盘"
    hide.addAction(UIAction { [weak self] _ in self?.hideKeyboard?() }, for: .touchUpInside)

    modeButton.accessibilityIdentifier = "terminal.keyboard.mode"
    modeButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    modeButton.tintColor = .secondaryLabel
    modeButton.addAction(UIAction { [weak self] _ in
      guard let self, isReady else { return }
      changeMode?()
    }, for: .touchUpInside)
    setEnglishMode(false)

    let enter = keyButton(.enter)
    enter.setTitle("回车 ↵", for: .normal)
    enter.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    enter.backgroundColor = UIColor.white.withAlphaComponent(0.09)
    enter.layer.cornerRadius = 10

    // The flexible gap grows on iPad. Paste stays by the left thumb and
    // Enter and the keyboard switch keep their positions when Agent appears.
    let actionGap = UIView()
    let actions = UIStackView(arrangedSubviews: [hide, pasteControl, actionGap, agentButton, modeButton, enter])
    actions.spacing = 2
    let agentWidth = agentButton.widthAnchor.constraint(equalToConstant: 50)
    agentWidth.priority = UILayoutPriority(999) // An inactive Agent is hidden by the stack.
    let pasteWidth = pasteControl.widthAnchor.constraint(equalToConstant: 166)
    pasteWidth.priority = .defaultHigh

    let commands = keyGroup([.escape, .tab, .interrupt])
    let arrows = keyGroup([.left, .up, .down, .right])
    arrows.backgroundColor = UIColor.white.withAlphaComponent(0.045)
    arrows.layer.cornerRadius = 10
    let keyGap = UIView()
    let keys = UIStackView(arrangedSubviews: [commands, keyGap, arrows])
    let preferredCommands = commands.widthAnchor.constraint(equalToConstant: 156)
    preferredCommands.priority = .defaultHigh

    rows.axis = .vertical
    [keys, englishKeyboard, actions].forEach(rows.addArrangedSubview)
    rows.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rows)
    let nearBottom = rows.bottomAnchor.constraint(equalTo: bottomAnchor)
    nearBottom.priority = .defaultHigh
    let insideSafeArea = rows.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor)
    insideSafeArea.priority = UILayoutPriority(998)
    let topHeight = keys.heightAnchor.constraint(equalToConstant: 44)
    let bottomHeight = actions.heightAnchor.constraint(equalToConstant: 44)
    // An enclosing UIStackView can collapse the entire panel to zero height.
    [topHeight, bottomHeight].forEach { $0.priority = UILayoutPriority(999) }
    NSLayoutConstraint.activate([
      hide.widthAnchor.constraint(equalToConstant: 44), modeButton.widthAnchor.constraint(equalToConstant: 46),
      enter.widthAnchor.constraint(equalToConstant: 70), agentWidth, pasteWidth,
      preferredCommands, arrows.widthAnchor.constraint(equalTo: commands.widthAnchor, multiplier: 4 / 3),
      keyGap.widthAnchor.constraint(greaterThanOrEqualToConstant: 4),
      topHeight, bottomHeight, nearBottom, insideSafeArea,
      rows.topAnchor.constraint(equalTo: topAnchor),
      rows.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      rows.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
      rows.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4)
    ])
    setReady(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    windowBottomLimit?.isActive = false
    windowBottomLimit = nil
    // The terminal extends under SwiftUI's safe area. Keep the keys above the
    // actual home indicator even if the hosting view has zero bottom insets.
    if let window {
      let limit = rows.bottomAnchor.constraint(lessThanOrEqualTo: window.safeAreaLayoutGuide.bottomAnchor)
      limit.priority = UILayoutPriority(998)
      limit.isActive = true
      windowBottomLimit = limit
    }
  }

  private func keyGroup(_ group: [TerminalKey]) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: group.map(keyButton))
    stack.distribution = .fillEqually
    return stack
  }

  func setEnglishMode(_ english: Bool) {
    isEnglishMode = english
    modeButton.setTitle(english ? "快捷" : "ABC", for: .normal)
    modeButton.accessibilityLabel = english ? "切换到快捷键" : "切换到英文键盘"
    englishKeyboard.setExpanded(english)
  }

  private func keyButton(_ key: TerminalKey) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(key.title, for: .normal)
    button.titleLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
    button.tintColor = key == .escape ? .systemOrange : .label
    button.accessibilityIdentifier = "terminal.keyboard." + key.title
    switch key {
    case .interrupt: button.accessibilityLabel = "Control C"
    case .left: button.accessibilityLabel = "方向左"
    case .up: button.accessibilityLabel = "方向上"
    case .down: button.accessibilityLabel = "方向下"
    case .right: button.accessibilityLabel = "方向右"
    case .enter: button.accessibilityLabel = "回车"
    default: break
    }
    button.addAction(UIAction { [weak self] _ in
      guard let self, isReady else { return }
      press?(key.rawValue)
    }, for: .touchUpInside)
    remoteButtons.append(button)
    return button
  }

  func setReady(_ ready: Bool) {
    isReady = ready
    remoteButtons.forEach { $0.isEnabled = ready }
    agentButton.isEnabled = ready
    modeButton.isEnabled = ready
    englishKeyboard.isUserInteractionEnabled = ready
    pasteControl.target = ready ? self : nil
    pasteControl.isUserInteractionEnabled = ready
  }

  func setAgentContext(_ identity: String?) { agentButton.setAgentContext(identity) }

  override func paste(itemProviders: [NSItemProvider]) {
    guard isReady, !itemProviders.isEmpty else { return }
    onPaste?(itemProviders)
  }
}
