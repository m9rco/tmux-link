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

// WebKit's focused text control asks its WKWebView for this accessory.
// Keeping the same view for the lifetime of the session preserves the IME.
final class TerminalWebView: WKWebView {
  let shortcutBar = TerminalKeyboardBar()
  override var inputAccessoryView: UIView? { shortcutBar }
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
