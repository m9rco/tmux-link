import UIKit
import WebKit

// The terminal keeps first responder status while the user taps the optional keyboard.
private final class EnglishKeySurface: WKWebView {
  override var canBecomeFirstResponder: Bool { false }
}

private final class EnglishKeyBridge: NSObject, WKScriptMessageHandler {
  var pressed: ((String) -> Void)?

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: String],
          let key = body["text"], !key.isEmpty, key.utf8.count <= 512 else { return }
    pressed?(key)
  }
}

final class TerminalEnglishKeyboard: UIView {
  var onText: ((String) -> Void)?
  private(set) var surface: WKWebView?
  private var height: NSLayoutConstraint!

  init() {
    super.init(frame: .zero)
    isHidden = true
    height = heightAnchor.constraint(equalToConstant: preferredHeight)
    height.priority = UILayoutPriority(999)
    height.isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }

  private var preferredHeight: CGFloat { traitCollection.verticalSizeClass == .compact ? 150 : 216 }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if previous?.verticalSizeClass != traitCollection.verticalSizeClass { height?.constant = preferredHeight }
  }

  func setExpanded(_ expanded: Bool) {
    if expanded && surface == nil {
      let bridge = EnglishKeyBridge()
      bridge.pressed = { [weak self] key in
        guard let self, !isHidden, window != nil else { return }
        onText?(key)
      }
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.userContentController.add(bridge, name: "typingKeyboard")
      let web = EnglishKeySurface(frame: bounds, configuration: config)
      web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      web.isOpaque = false
      web.backgroundColor = Screen.surface
      web.underPageBackgroundColor = Screen.surface
      web.scrollView.isScrollEnabled = false
      web.scrollView.contentInsetAdjustmentBehavior = .never
      web.accessibilityIdentifier = "terminal.typing"
      addSubview(web)
      surface = web
      let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets/keyboard")!
      web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }
    isHidden = !expanded
  }
}
