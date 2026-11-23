import UIKit

// The drawer overlays the terminal. Its position never participates in PTY sizing.
final class ShortcutDrawer: UIView, UIGestureRecognizerDelegate {
  private let panel = UIScrollView()
  private let dismiss = UIButton(type: .custom)
  private let reveal = UIButton(type: .custom)
  private let keys = UIStackView()
  private var isOpen = false
  private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))

  init(in viewport: UIView, accent: UIColor, leave: (() -> Void)? = nil,
       review: (() -> Void)? = nil, press: @escaping (String) -> Void) {
    super.init(frame: viewport.bounds)
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    viewport.addSubview(self)
    clipsToBounds = true
    pan.maximumNumberOfTouches = 1
    pan.delegate = self
    // Recognize on the viewport so a drag may start on the terminal text.
    viewport.addGestureRecognizer(pan)
    panel.panGestureRecognizer.require(toFail: pan)

    dismiss.accessibilityIdentifier = "terminal.shortcuts.close"
    dismiss.accessibilityLabel = "收起快捷键"
    dismiss.addAction(UIAction { [weak self] _ in self?.settle(open: false) }, for: .touchUpInside)
    dismiss.isHidden = true
    dismiss.frame = bounds
    dismiss.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(dismiss)

    // VoiceOver can activate this button directly, even with the shortcuts offscreen.
    reveal.accessibilityIdentifier = "terminal.shortcuts.open"
    reveal.accessibilityLabel = "展开终端快捷键"
    reveal.addAction(UIAction { [weak self] _ in self?.settle(open: true) }, for: .touchUpInside)
    addSubview(reveal)

    panel.accessibilityIdentifier = "terminal.shortcuts"
    panel.backgroundColor = Screen.surface.withAlphaComponent(0.96)
    panel.layer.cornerRadius = 12
    panel.layer.cornerCurve = .continuous
    panel.layer.borderWidth = 0.5
    panel.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
    panel.showsHorizontalScrollIndicator = false
    panel.indicatorStyle = .white
    panel.contentInsetAdjustmentBehavior = .never
    panel.isHidden = true
    addSubview(panel)
    keys.axis = .vertical
    keys.spacing = 2
    if let leave {
      let back = UIButton(type: .system)
      back.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
      back.tintColor = accent
      back.accessibilityLabel = "返回会话列表"
      back.accessibilityIdentifier = "terminal.leave"
      back.addAction(UIAction { _ in leave() }, for: .touchUpInside)
      keys.addArrangedSubview(back)
      back.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }
    if let review {
      let button = UIButton(type: .system)
      button.setTitle("决策", for: .normal)
      button.tintColor = accent
      button.accessibilityLabel = "分析当前会话的待决问题"
      button.accessibilityIdentifier = "terminal.review"
      button.addAction(UIAction { [weak self] _ in
        self?.settle(open: false)
        review()
      }, for: .touchUpInside)
      keys.addArrangedSubview(button)
      button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }
    for key in TerminalKey.allCases {
      let label = key.title
      var style = UIButton.Configuration.tinted()
      style.title = label
      style.baseForegroundColor = label == "Esc" ? .systemOrange : accent
      style.contentInsets = .init(top: 3, leading: 8, bottom: 3, trailing: 8)
      let button = UIButton(configuration: style)
      button.accessibilityIdentifier = "terminal.key." + label
      button.addAction(UIAction { _ in press(key.rawValue) }, for: .touchUpInside)
      keys.addArrangedSubview(button)
      button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }
    setReady(false)
    panel.addSubview(keys)
    [panel, keys, reveal].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
    let fitContent = panel.heightAnchor.constraint(equalTo: panel.contentLayoutGuide.heightAnchor)
    fitContent.priority = .defaultHigh
    NSLayoutConstraint.activate([
      reveal.rightAnchor.constraint(equalTo: rightAnchor),
      reveal.centerYAnchor.constraint(equalTo: centerYAnchor),
      reveal.widthAnchor.constraint(equalToConstant: 12),
      reveal.heightAnchor.constraint(equalToConstant: 44),
      panel.rightAnchor.constraint(equalTo: rightAnchor),
      panel.centerYAnchor.constraint(equalTo: centerYAnchor),
      panel.widthAnchor.constraint(equalToConstant: 72),
      panel.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor), fitContent,
      keys.widthAnchor.constraint(equalTo: panel.frameLayoutGuide.widthAnchor, constant: -8),
      keys.leftAnchor.constraint(equalTo: panel.contentLayoutGuide.leftAnchor, constant: 4),
      keys.rightAnchor.constraint(equalTo: panel.contentLayoutGuide.rightAnchor, constant: -4),
      keys.topAnchor.constraint(equalTo: panel.contentLayoutGuide.topAnchor, constant: 4),
      keys.bottomAnchor.constraint(equalTo: panel.contentLayoutGuide.bottomAnchor, constant: -4),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    if hit === reveal && !UIAccessibility.isVoiceOverRunning { return nil }
    return hit === self ? nil : hit
  }

  func setReady(_ ready: Bool) {
    for case let button as UIButton in keys.arrangedSubviews where button.accessibilityIdentifier != "terminal.leave" {
      button.isEnabled = ready
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    let point = touch.location(in: self)
    return isOpen ? panel.frame.contains(point) : point.x >= bounds.maxX - 22
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === pan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
    let velocity = pan.velocity(in: self)
    return abs(velocity.x) > abs(velocity.y) && (isOpen ? velocity.x > 0 : velocity.x < 0)
  }

  @objc private func drag(_ pan: UIPanGestureRecognizer) {
    let width = panel.bounds.width
    let dx = pan.translation(in: self).x
    switch pan.state {
    case .began, .changed:
      panel.isHidden = false
      let offset = min(width, max(0, (isOpen ? 0 : width) + dx))
      panel.transform = CGAffineTransform(translationX: offset, y: 0)
    case .ended:
      let projected = dx + pan.velocity(in: self).x * 0.12
      settle(open: isOpen ? projected < width / 2 : projected < -width / 2)
    case .cancelled, .failed: settle(open: isOpen)
    default: break
    }
  }

  private func settle(open: Bool) {
    let offscreen = CGAffineTransform(translationX: panel.bounds.width, y: 0)
    if panel.isHidden { panel.transform = offscreen }
    isOpen = open
    panel.isHidden = false
    dismiss.isHidden = !open
    reveal.isHidden = open
    accessibilityViewIsModal = open
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
                   delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
      self.panel.transform = open ? .identity : offscreen
    } completion: { finished in
      guard finished, self.isOpen == open else { return }
      self.panel.isHidden = !open
      if UIAccessibility.isVoiceOverRunning {
        UIAccessibility.post(notification: .layoutChanged,
                             argument: open ? self.keys.arrangedSubviews.first : self.reveal)
      }
    }
  }

  override func accessibilityPerformEscape() -> Bool {
    guard isOpen else { return false }
    settle(open: false)
    return true
  }
}
