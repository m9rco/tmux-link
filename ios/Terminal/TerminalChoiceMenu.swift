import Foundation

/// A read-only description of the last visible choice widget. Hints are taken from the widget itself.
struct TerminalChoiceMenu: Codable, Equatable {
  enum Mode: String, Codable { case single, multiple, unspecified }
  struct Item: Codable, Equatable {
    let label: String
    let selected: Bool?
    let focused: Bool
  }

  let mode: Mode
  let items: [Item]
  let selectionHint: String?
  let submitHint: String?
  let submitFocused: Bool
  let truncated: Bool

  var visibleTexts: [String] { items.map(\.label) + [selectionHint, submitHint].compactMap { $0 } }

  private enum Marker { case checkbox, radio, number, cursor, plain }
  private struct Row {
    let marker: Marker
    let item: Item
    let body: String
  }

  private static let edges = CharacterSet(charactersIn: " \t│┃║┆")
  private static let focus = try! NSRegularExpression(pattern: #"^[›❯➤➜▸▶→>]\s*"#)
  private static let mark = try! NSRegularExpression(
    pattern: #"^(\[[ xX*✓✔×]\]|\([ xX*●•]\)|[☐☑☒□▣◉◎◯○●◌🔘])\s*"#)
  private static let number = try! NSRegularExpression(pattern: #"^\(?\d{1,2}[.)、）]\s*"#)
  private static let multi = #"(?i)多选|可选多[个项]|选择多[个项]|复选|select (?:all that apply|multiple|one or more)|multi[- ]?select|space(?:bar)?\s+(?:to\s+)?toggle|空格.{0,5}(?:切换|勾选|选中)"#
  private static let single = #"(?i)单选|选一项|选择一[个项]|选其一|select (?:one|a single)|choose (?:one|a single)|pick one"#
  private static let keys = #"(?i)\b(?:enter|return|space(?:bar)?|tab|esc|arrow keys)\b|回车|空格|方向键|↑|↓|↵|⏎|␣"#
  private static let submitAction = #"(?i)\b(?:submit|confirm|accept|finish)\b|提交|确认|確定|确定|完成选择"#
  private static let selectionAction = #"(?i)\b(?:select|choose|toggle|navigate|move|cycle|check|uncheck|next)\b|选择|选中|切换|勾选|移动|导航|下一[项题步]|↑|↓"#
  private static let submitButton = #"(?i)^(?:(?:submit|confirm)(?: (?:answers?|selections?|choices?))?|finish|提交(?:答[案复]|选择|选项)?|确认(?:选择|提交)?|确定)[ ✓✔]*$"#

  private static func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }

  private static func prefix(_ regex: NSRegularExpression, from line: inout String) -> String? {
    guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let range = Range(m.range, in: line) else { return nil }
    let prefix = String(line[range]).trimmingCharacters(in: .whitespaces)
    line = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    return prefix
  }

  private static func parseRow(_ value: String) -> Row? {
    var label = value
    let selectedCursor = prefix(focus, from: &label) != nil
    var numberLabel = prefix(number, from: &label)
    var marker: Marker = numberLabel != nil ? .number : selectedCursor ? .cursor : .plain
    var selected: Bool?
    if let glyph = prefix(mark, from: &label) {
      let box = glyph.hasPrefix("[") || ["☐", "☑", "☒", "□", "▣"].contains(glyph)
      marker = box ? .checkbox : .radio
      selected = !["[ ]", "( )", "☐", "□", "◯", "○", "◌", "◎"].contains(glyph)
      if label.first?.unicodeScalars.first?.value == 0xFE0F { label.removeFirst() }
      if numberLabel == nil { numberLabel = prefix(number, from: &label) }
    }
    guard !label.isEmpty else { return nil }
    let visible = numberLabel.map { $0 + " " + label } ?? label
    return Row(marker: marker, item: Item(label: visible, selected: selected, focused: selectedCursor), body: label)
  }

  private static func fragments(_ line: String) -> [String] {
    line.replacingOccurrences(of: #"\s*[·•|；;]\s*|\s{2,}|[,，]\s*(?=(?i:enter|space|return|tab|回车|空格|↑|↓))"#,
                              with: "\n", options: .regularExpression)
      .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  private static func visual(_ line: String) -> Bool {
    line.isEmpty || line.unicodeScalars.allSatisfy {
      (0x2500...0x259F).contains($0.value) || "-_=─".unicodeScalars.contains($0)
    }
  }

  static func detect(in text: String) -> Self? {
    read(rows: text.components(separatedBy: .newlines))?.menu
  }

  static func read(rows input: [String]) -> (menu: Self, occupied: Set<Int>)? {
    var occupied = Set<Int>()
    var itemIndent = 0
    var rows: [Row] = []
    var header = ""
    var selection: [String] = []
    var submission: [String] = []
    var submitFocused = false
    var endOfGroup = false
    var lastContent = ""
    // Cursor-style pickers mark only one row; text rows before that cursor are also choices.
    var pendingHeader: String?
    var pendingRows: [(index: Int, row: Row)] = []
    func reset() {
      occupied.removeAll(); rows.removeAll(); header = ""
      selection.removeAll(); submission.removeAll()
      submitFocused = false; endOfGroup = false
      pendingHeader = nil; pendingRows.removeAll()
    }
    for (index, raw) in input.enumerated() {
      let line = raw.trimmingCharacters(in: edges)
      if visual(line) { continue }
      let indent = raw.prefix { $0.isWhitespace || "│┃║┆".contains($0) }.count
      if let row = parseRow(line) {
        let title = row.body.trimmingCharacters(in: CharacterSet(charactersIn: "[]【】 "))
        if matches(title, submitButton) && (!rows.isEmpty || row.item.focused || line.hasPrefix("[")) {
          if !submission.contains(title) { submission.append(title) }
          occupied.insert(index)
          submitFocused = row.item.focused
          endOfGroup = true
          continue
        }
        if row.marker != .plain, !matches(row.item.label, #"^[-─━█ ]+$"#) {
          if endOfGroup { reset() }
          if rows.isEmpty {
            header = pendingHeader ?? lastContent
            if row.marker == .cursor {
              rows.append(contentsOf: pendingRows.map(\.row))
              occupied.formUnion(pendingRows.map(\.index))
            }
            pendingHeader = nil
            pendingRows.removeAll()
          }
          rows.append(row)
          occupied.insert(index)
          itemIndent = indent
          continue
        }
      }
      let hints = fragments(line).filter { matches($0, keys) && (matches($0, submitAction) || matches($0, selectionAction)) }
      if !hints.isEmpty && (!rows.isEmpty || !submission.isEmpty) {
        occupied.insert(index)
        for hint in hints {
          if matches(hint, submitAction) && !submission.contains(hint) { submission.append(hint) }
          if matches(hint, selectionAction) && !selection.contains(hint) { selection.append(hint) }
        }
        endOfGroup = true
        continue
      }
      if endOfGroup && (!rows.isEmpty || !submission.isEmpty) {
        // Ignore known interface footers. New conversation or shell output supersedes this widget.
        if matches(line, #"(?i)^(?:build|plan|agent)\s*[·•]|\d+(?:\.\d+)?[kKmM]\s*\(\d+%\)|^(?:esc|tab|ctrl[+-].+)\s+(?:dismiss|cancel|commands?)|^\d+\s+\S+\s+(?:[A-Z]+\s+)?[│|]"#) { continue }
        reset()
      }
      if rows.isEmpty && submission.isEmpty {
        if matches(line, single) || matches(line, multi) || matches(line, #"(?i)^(?:please )?(?:select|choose|pick)\b|^请选择"#) {
          pendingHeader = line
          pendingRows.removeAll()
        } else if pendingHeader != nil, let plain = parseRow(line), plain.marker == .plain {
          pendingRows.append((index, plain))
        }
      }
      // A hanging indentation after a checkbox, radio or number belongs to that option.
      if !endOfGroup, let last = rows.last, [.number, .checkbox, .radio].contains(last.marker),
         indent > itemIndent, !matches(line, #"(?i)^(?:user:|you:|用户[：:])"#) {
        let label = DecisionSnapshot.redacted(last.item.label + "\n" + line)
        let item = Item(label: label, selected: last.item.selected, focused: last.item.focused)
        rows[rows.count - 1] = Row(marker: last.marker, item: item, body: last.body)
        occupied.insert(index)
        continue
      }
      // A common terminal list shows a cursor on the focused row and plain indented siblings.
      if !endOfGroup, rows.last?.marker == .cursor || rows.last?.marker == .plain,
         !line.contains("?"), !line.contains("？"), !matches(line, #"[:：。.!！]$"#),
         let plain = parseRow(line), plain.marker == .plain {
        rows.append(plain)
        occupied.insert(index)
        itemIndent = indent
        continue
      }
      if !rows.isEmpty && (matches(line, #"(?i)^(?:user:|you:|用户[：:]|已选择|已提交|selected:|submitted\b|running\b|executing\b)"#)
        || line.hasSuffix("?") || line.hasSuffix("？")) { reset() }
      else if !rows.isEmpty { endOfGroup = true }
      lastContent = line
    }

    guard !rows.isEmpty || !submission.isEmpty else { return nil }
    let hints = ([header] + selection + submission).joined(separator: " ")
    let checks = rows.contains { $0.marker == .checkbox }
    let radios = rows.contains { $0.marker == .radio }
    let focused = rows.contains { $0.item.focused } || submitFocused
    let explicitMulti = matches(hints, multi), explicitSingle = matches(hints, single)
    // Plain numbered plans and Markdown checklists also occur in transcripts.
    // Require a visible interaction cue before treating them as an active choice widget.
    let hasHints = !selection.isEmpty || !submission.isEmpty
    let markedRadioGroup = radios && rows.count >= 2 && rows.contains { $0.item.selected == true }
      && rows.contains { $0.item.selected == false }
    guard hasHints || explicitMulti || explicitSingle || markedRadioGroup
            || (focused && rows.count >= 2 && (checks || radios || rows.contains { $0.marker == .number }))
    else { return nil }
    let mode: Mode
    if explicitMulti { mode = .multiple }
    else if explicitSingle { mode = .single }
    else if checks { mode = .multiple }
    else if radios || (focused && hasHints && rows.contains(where: { $0.marker == .number || $0.marker == .cursor })) { mode = .single }
    else { mode = .unspecified }
    func boundedText(_ value: String, bytes: Int) -> String {
      var prefix = value.utf8.prefix(bytes)
      while !prefix.isEmpty {
        if let result = String(bytes: prefix, encoding: .utf8) { return result }
        prefix = prefix.dropLast()
      }
      return ""
    }
    func joined(_ hints: [String]) -> String? {
      hints.isEmpty ? nil : boundedText(hints.joined(separator: " · "), bytes: 200)
    }
    var kept = [Int: Item]()
    var shortened = false
    let selectHint = joined(selection), sendHint = joined(submission)
    func result() -> Self {
      Self(mode: mode, items: kept.keys.sorted().compactMap { kept[$0] },
           selectionHint: selectHint, submitHint: sendHint, submitFocused: submitFocused,
           truncated: shortened || kept.count < rows.count)
    }
    // Preserve focused and checked rows first, then fill the remaining budget in screen order.
    let priority = rows.indices.filter { rows[$0].item.focused || rows[$0].item.selected == true }
    let rest = rows.indices.filter { !rows[$0].item.focused && rows[$0].item.selected != true }
    let encoder = JSONEncoder()
    for index in priority + rest where kept.count < 20 {
      let item = rows[index].item
      let label = boundedText(item.label, bytes: 300)
      shortened = shortened || label != item.label
      kept[index] = Item(label: label, selected: item.selected, focused: item.focused)
      if (try? encoder.encode(result()).count) ?? Int.max > 2300 { kept[index] = nil }
    }
    return (result(), occupied)
  }
}
