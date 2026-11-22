import UIKit

// A snapshot keeps the system selection handles stable while the remote process redraws.
final class TerminalTextSelection: UIViewController {
  let textView = UITextView()
  private let text: String
  private let offset: Int
  private let writeSelection: (String) -> Void

  init(text: String, offset: Int, writeSelection: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) {
    self.writeSelection = writeSelection
    self.text = text
    self.offset = offset
    super.init(nibName: nil, bundle: nil)
    title = "选取会话文字"
  }

  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    view = textView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    textView.isEditable = false
    textView.isSelectable = true
    textView.backgroundColor = Screen.surface
    textView.textColor = .white
    textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    textView.accessibilityIdentifier = "terminal.selection"
    textView.text = text
    selectTouchedWord()
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .plain, target: self,
                                                       action: #selector(close))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "复制", style: .done, target: self,
                                                        action: #selector(copySelection))
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    textView.becomeFirstResponder()
    selectTouchedWord()
  }

  private func selectTouchedWord() {
    let string = text as NSString
    guard string.length > 0 else { return }
    let index = min(max(0, offset), string.length - 1)
    let character = string.rangeOfComposedCharacterSequence(at: index)
    var selected = character
    string.enumerateSubstrings(in: string.lineRange(for: character), options: [.byWords, .localized]) {
      _, range, _, stop in
      if NSLocationInRange(index, range) { selected = range; stop.pointee = true }
    }
    textView.selectedRange = selected
    textView.scrollRangeToVisible(selected)
  }

  @objc private func close() { dismiss(animated: true) }

  @objc func copySelection() {
    guard let range = textView.selectedTextRange, let selection = textView.text(in: range),
          !selection.isEmpty else { return }
    writeSelection(selection)
    close()
  }
}
