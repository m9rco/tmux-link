import Foundation

/// An extractive brief. Source order is significant: a later response may settle an earlier question.
struct DecisionBrief: Codable, Equatable {
  enum Source: String, Codable { case current, history }
  enum Kind: String, Codable { case question, rationale, goal, constraint, fact, plan, choice, state }
  struct Block: Codable, Equatable {
    let source: Source
    let kind: Kind
    let text: String
  }

  let id: Int64
  let name: String
  let blocks: [Block]
  var menu: TerminalChoiceMenu? = nil

  static let maxEncodedBytes = 4096
  static let maxHistoryBytes = 1152
}

// The three strings have a fixed wire order shared by the prompt and byte-budget calculation.
extension DecisionBrief.Block {
  func encode(to encoder: Encoder) throws {
    var fields = encoder.unkeyedContainer()
    try fields.encode(source)
    try fields.encode(kind)
    try fields.encode(text)
  }

  init(from decoder: Decoder) throws {
    var fields = try decoder.unkeyedContainer()
    source = try fields.decode(DecisionBrief.Source.self)
    kind = try fields.decode(DecisionBrief.Kind.self)
    text = try fields.decode(String.self)
    guard fields.isAtEnd else {
      throw DecodingError.dataCorruptedError(in: fields, debugDescription: "Unexpected trailing decision block fields")
    }
  }
}

extension DecisionBrief {
  init(snapshot: DecisionSnapshot) {
    let label = Self.boundedExcerpt(DecisionSnapshot.redacted(snapshot.name), cap: 192, tail: false)
    func clean(_ raw: String) -> [String] {
      let rows = DecisionSnapshot.redacted(Rules.escapes.replace(in: raw, with: ""))
        .components(separatedBy: "\n")
      let hidden = Self.decorationRows(rows)
      // Empty separators prevent prose on opposite sides of a removed widget from joining.
      return rows.indices.map { hidden.contains($0) ? "" : rows[$0] }
    }
    let screen = clean(snapshot.text)
    let widget = TerminalChoiceMenu.read(rows: screen)
    let menu = widget?.menu
    let logicalLines = snapshot.capture != nil
    let history = Self.extract(clean(snapshot.context ?? ""), source: .history, logicalLines: logicalLines)
    let current = Self.extract(screen, source: .current, logicalLines: logicalLines, skip: widget?.occupied ?? [])
    var candidates = history + current

    // When a question names a specific plan item, other items in that plan are not answers.
    // Leave actual choice menus and independent questions intact.
    let questions = current.filter { $0.block.kind == .question }
    var preferred = Set<Int>()
    var omitted = Set<Int>()
    if questions.count == 1, menu == nil, !Rules.alternative.test(questions[0].block.text),
       Rules.step.matches(in: questions[0].block.text) == 1,
       let number = Rules.step.capture(questions[0].block.text).flatMap(Int.init),
       let target = candidates.indices.last(where: {
         candidates[$0].number == number && [.plan, .fact].contains(candidates[$0].block.kind) &&
           ($0 < history.count || candidates[$0].order < questions[0].order)
       }) {
      let item = candidates[target]
      // The plan heading can scroll offscreen while the question still explicitly names its step.
      if item.block.kind == .fact {
        candidates[target] = Candidate(block: Block(source: item.block.source, kind: .plan, text: item.block.text),
                                       order: item.order, group: item.group, number: item.number)
      }
      preferred.insert(target)
      if let group = item.group {
        for (index, other) in candidates.enumerated() where other.block.source == item.block.source &&
          other.group == group && other.number != nil && other.number != number {
          if let limit = Self.scopeLimit(in: other.block.text) {
            candidates[index] = Candidate(block: Block(source: other.block.source, kind: .constraint, text: limit),
                                          order: other.order, group: nil, number: nil)
          } else {
            omitted.insert(index)
          }
        }
      }
    }

    // Keep the latest instance of repeated rows, including a redraw copied from history into the live pane.
    var latest = [String: Int]()
    for (index, item) in candidates.enumerated() where !omitted.contains(index) {
      let key = Rules.progress.test(item.block.text) ? Rules.number.replace(in: item.block.text, with: "#") : item.block.text
      latest[key] = index
    }
    let currentIndices = latest.values.filter { candidates[$0].block.source == .current }
    let lastCurrent = currentIndices.max()
    let lastState = currentIndices.filter { candidates[$0].block.kind == .state }.max()
    var support = [Int: Int]()
    if snapshot.capture != nil, !history.isEmpty, !questions.isEmpty || menu != nil {
      let prompt = questions.map { $0.block.text } + (menu?.visibleTexts ?? [])
      let references = Self.references(in: prompt.joined(separator: "\n"))
      // Choose one representative of each supporting kind. Prefer the same file, ticket, or revision
      // as the current prompt, then the later row. Unrelated history facts stay at their usual priority.
      let matches = latest.values.compactMap { index -> (index: Int, matches: Int)? in
        let block = candidates[index].block
        guard block.source == .history, block.kind != .question, block.kind != .choice else { return nil }
        let overlap = references.isEmpty ? 0 : Self.references(in: block.text).intersection(references).count
        guard overlap > 0 || [.rationale, .goal, .constraint].contains(block.kind) else { return nil }
        return (index, overlap)
      }.sorted { a, b in a.matches == b.matches ? a.index > b.index : a.matches > b.matches }
      var kinds = Set<Kind>()
      for (index, _) in matches where support.count < 4 && kinds.insert(candidates[index].block.kind).inserted {
        support[index] = support.count
      }
    }
    func priority(_ i: Int) -> Int {
      let item = candidates[i]
      let current = item.block.source == .current
      if i == lastCurrent { return 125 }
      if preferred.contains(i) { return 110 }
      if let rank = support[i] { return 99 - rank }
      switch item.block.kind {
      case .question: return current ? 120 : 25
      case .choice: return current ? 105 : 25
      case .rationale, .goal, .constraint: return current ? 95 : 88
      case .state:
        guard current else { return 65 }
        return support.isEmpty || i == lastState ? 100 : 94
      case .plan: return current ? 75 : 55
      case .fact: return current ? 70 : 35
      }
    }
    let ranked = latest.values.sorted {
      let a = priority($0), b = priority($1)
      return a == b ? $0 > $1 : a > b
    }
    let encoder = JSONEncoder()
    let header = DecisionBrief(id: snapshot.id, name: label, blocks: [], menu: menu)
    var bytes = (try? encoder.encode(header).count) ?? 640
    var historyBytes = 0
    var selected = Set<Int>()
    for i in ranked where selected.count < 24 {
      let block = candidates[i].block
      guard let size = try? encoder.encode(block).count else { continue }
      let cost = size + (selected.isEmpty ? 0 : 1)
      guard bytes + cost <= Self.maxEncodedBytes else { continue }
      if block.source == .history {
        guard historyBytes + cost <= Self.maxHistoryBytes else { continue }
        historyBytes += cost
      }
      bytes += cost
      selected.insert(i)
    }
    self.init(id: snapshot.id, name: label, blocks: selected.sorted().map { candidates[$0].block }, menu: menu)
  }

  private struct Candidate {
    let block: Block
    let order: Int
    let group: Int?
    let number: Int?
  }

  private static func references(in text: String) -> Set<String> {
    let punctuation = CharacterSet(charactersIn: "._/-")
    let words = text.split { !($0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0))) }
    var references = Set<String>()
    for word in words {
      let literal = word.trimmingCharacters(in: punctuation)
      guard (3...128).contains(literal.utf8.count), literal.contains(where: \.isLetter),
            literal.contains(where: \.isNumber) || literal.rangeOfCharacter(from: punctuation) != nil else { continue }
      references.insert(literal)
      // A question may name a file while earlier output included its directory.
      if let name = literal.split(separator: "/").last, name.contains(".") { references.insert(String(name)) }
    }
    return references
  }

  private static func scopeLimit(in text: String) -> String? {
    // A later plan item can still set an important ownership or safety boundary.
    let clauses = text.components(separatedBy: CharacterSet(charactersIn: "（();；。"))
    guard let limit = clauses.first(where: { Rules.constraint.test($0) }) else { return nil }
    return limit.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "），,.")))
  }

  private static func extract(_ rows: [String], source: Source, logicalLines: Bool, skip: Set<Int> = []) -> [Candidate] {
    var paragraphs = [String]()
    var pending = ""
    func flush() {
      if !pending.isEmpty { paragraphs.append(DecisionSnapshot.redacted(pending)); pending = "" }
    }
    for (index, rawLine) in rows.enumerated() {
      let line = content(rawLine)
      if line.isEmpty || Rules.rule.test(line) || skip.contains(index) {
        flush(); continue
      }
      if pending.hasSuffix("[REDACTED]") && Rules.keyContinuation.test(line) { continue }
      let indent = rawLine.prefix(while: { $0.isWhitespace }).count
      if !pending.isEmpty && isContinuation(line, indent: indent, after: pending, logicalLines: logicalLines) {
        // tmux v2 joins its own soft wraps. An application may indent the next
        // line in the same paragraph, but its explicit newline is part of the evidence.
        pending += (logicalLines ? "\n" : separator(after: pending, before: line)) + line
      } else {
        flush()
        pending = line
      }
    }
    flush()

    var result = [Candidate]()
    var listKind: Kind?, group = 0, lastNumber = 0
    for text in paragraphs {
      if Rules.bareHeading.test(text) { continue }
      let number = Rules.item.capture(text).flatMap(Int.init)
      var kind: Kind
      if let number {
        if number <= lastNumber { group += 1 }
        lastNumber = number
        kind = listKind ?? .fact
      } else if Rules.planHeading.test(text) && !text.hasSuffix("?") && !text.hasSuffix("？") {
        group += 1; lastNumber = 0; listKind = .plan
        // The heading itself may carry a boundary such as “wait for confirmation; do not publish”.
        guard Rules.constraint.test(text) else { continue }
        kind = .constraint
      } else {
        kind = classify(text)
        if kind == .question || Rules.choiceHeading.test(text) {
          group += 1; lastNumber = 0; listKind = .choice
        } else if kind == .state {
          listKind = nil
        }
      }
      func append(_ kind: Kind, _ text: String) {
        let excerpt = boundedExcerpt(text, cap: kind == .question ? 1024 : 768, tail: kind == .question)
        guard !excerpt.isEmpty, excerpt != "[REDACTED]" else { return }
        result.append(Candidate(block: Block(source: source, kind: kind, text: excerpt), order: result.count,
                                group: number == nil ? nil : group, number: number))
      }
      if kind == .plan, let clause = Rules.planGoal.capture(text), text.hasSuffix(clause) {
        let action = text.dropLast(clause.count).trimmingCharacters(in: CharacterSet(charactersIn: " ，,；;"))
        append(.plan, action)
        append(.goal, clause)
      } else {
        append(kind, text)
      }
    }
    return result
  }

  private static func classify(_ text: String) -> Kind {
    // A transcript often shows the answered question immediately above the reply and a running spinner.
    if Rules.response.test(text) { return .state }
    if text.hasSuffix("?") || text.hasSuffix("？") || Rules.prompt.test(text) { return .question }
    if Rules.rationale.test(text) { return .rationale }
    if Rules.goal.test(text) { return .goal }
    if Rules.constraint.test(text) && !Rules.factQualifier.test(text) { return .constraint }
    if Rules.state.test(text) { return .state }
    return .fact
  }

  private static func content(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Unicode frames are common around input boxes. ASCII pipes belong to the command itself.
    while let c = text.first, "│┃▏".contains(c) { text.removeFirst() }
    while let c = text.last, "│┃".contains(c) { text.removeLast() }
    return text.trimmingCharacters(in: .whitespaces)
  }

  private static func decorationRows(_ rows: [String]) -> Set<Int> {
    let lines = rows.map(content)
    var hidden = Set<Int>()
    var processTable = false
    for (i, line) in lines.enumerated() {
      if Rules.processHeading.test(line) { processTable = true; hidden.insert(i); continue }
      if processTable && Rules.processRow.test(line) { hidden.insert(i); continue }
      if !line.isEmpty { processTable = false }
      if Rules.meter.test(line) || Rules.shortcuts.test(line) {
        hidden.insert(i)
      }
      if Rules.model.test(line) {
        let end = min(lines.count, i + 7)
        let footer = lines[i+1..<end].contains { Rules.usage.test($0) || Rules.shortcuts.test($0) }
        if footer || (i >= lines.count - 5 && Rules.provider.test(line)) {
          hidden.insert(i)
          if i + 1 < end && Rules.identifier.test(lines[i+1]) { hidden.insert(i+1) }
        }
      }
      if Rules.usage.test(line) {
        hidden.insert(i)
        if i > 0 && Rules.pathOnly.test(lines[i-1]),
           lines[max(0, i-6)..<i].contains(where: Rules.model.test) { hidden.insert(i-1) }
        if i + 1 < lines.count && Rules.footerWrap.test(lines[i+1]) { hidden.insert(i+1) }
      }
      if i >= lines.count - 3 && Rules.tmuxStatus.test(line) { hidden.insert(i) }
    }
    return hidden
  }

  private static func isContinuation(_ line: String, indent: Int, after previous: String, logicalLines: Bool) -> Bool {
    if logicalLines && (Rules.questionLead.test(line) || (indent == 0 && !Rules.questionLead.test(previous))) {
      return false
    }
    guard !Rules.start.test(line), !Rules.prompt.test(line), !Rules.label.test(line),
          !Rules.response.test(line), !Rules.planHeading.test(line), !Rules.state.test(line),
          previous.last.map({ !".。?？!！:：".contains($0) }) == true else { return false }
    if Rules.start.test(previous) && indent > 0 { return true }
    if previous.hasSuffix("-") || previous.hasSuffix("/") || previous.hasSuffix("_") ||
         previous.hasSuffix("，") || previous.hasSuffix(",") { return true }
    if Rules.questionLead.test(previous) && (indent > 0 || line.hasSuffix("?") || line.hasSuffix("？") ||
                                              line.first.map({ "步项（(".contains($0) }) == true) { return true }
    if indent > 0 && (Rules.label.test(previous) || Rules.questionLead.test(previous)) { return true }
    // An unindented wrap from a narrow TUI can end exactly at a token boundary.
    return indent == 0 && previous.count >= 18 && line.prefix(1).range(of: "^[a-z]", options: .regularExpression) != nil &&
      (Rules.start.test(previous) || previous.last == "（" || previous.last == "(")
  }

  private static func separator(after left: String, before right: String) -> String {
    guard let last = left.last, let first = right.first else { return "" }
    if last == "/", left.dropLast().last?.isWhitespace == true { return " " }
    if "-_/（(".contains(last) || "，。？！、,.;:!?）)]/".contains(first) { return "" }
    // CJK wraps do not imply word separators. Preserve the original characters of IDs, versions and ratios.
    if last.isIdeographic && first.isIdeographic { return "" }
    if last.isIdeographic || first.isIdeographic {
      return last.isASCII && (last.isLetter || last.isNumber) || first.isASCII && (first.isLetter || first.isNumber) ? " " : ""
    }
    return " "
  }

  private static func boundedExcerpt(_ text: String, cap: Int, tail: Bool) -> String {
    var bytes = tail ? text.utf8.suffix(cap)[...] : text.utf8.prefix(cap)[...]
    while !bytes.isEmpty {
      if let value = String(bytes: bytes, encoding: .utf8) { return value }
      if tail { bytes = bytes.dropFirst() } else { bytes = bytes.dropLast() }
    }
    return ""
  }

  private enum Rules {
    static let escapes = Rule(#"\x1B(?:\][^\x07\x1B]*(?:\x07|\x1B\\|$)|\[[0-?]*[ -/]*[@-~])"#)
    static let rule = Rule(#"^[\s|\u2500-\u259f\u2800-\u28ff]+$|^\+[-=+| ]{2,}\+$|^(?:[-=_*·•]\s*){3,}$"#)
    static let start = Rule(#"^(?:[>*❯›●•▪-]\s+|\d{1,3}[.)、]\s*)"#)
    static let item = Rule(#"^(?:[❯›>]\s*)?(\d{1,3})[.)、]\s*"#)
    static let step = Rule(#"(?i)(?:第\s*|\bstep\s*#?\s*)(\d+)\s*(?:步|项|\b)"#)
    static let alternative = Rule(#"(?i)还是|或者|第\s*\d+\s*(?:、|和|或|及)\s*\d+|\b(?:or|instead|versus)\b|\d\s*(?:and|[,/&])\s*\d"#)
    static let prompt = Rule(#"(?i)^(?:(?:please\s+)?(?:choose|select|confirm|enter|pick)\b|请选择|请确认|请问|是否要)|\[(?:y/n|yes/no)\]\s*[:：]?\s*$"#)
    static let questionLead = Rule(#"(?i)^(?:要我|要先|要不要|我们要|需要我|可以先|是否|你想|你希望|请|should|shall|would|which|what|can I|do you|how|why)"#)
    static let response = Rule(#"(?i)^(?:[>❯›]\s+|(?:user|you|answer|reply|回答|用户|已选择|已确认)\s*[:：])"#)
    static let bareHeading = Rule(#"(?i)^(?:[●•#-]\s*)?(?:当前(?:线上)?状态|背景|现状|current status|background)\s*[:：]?$"#)
    static let planGoal = Rule(#"(?i)[,，;；]\s*((?:以便|目标[为是：:]|希望|验证[^，,；;。]*[0-9]|so that\b|aiming (?:for|to)\b).+)$"#)
    static let planHeading = Rule(#"(?i)^(?:[●•#-]\s*)?(?:建议的下一步|下一步(?:计划|建议)|后续(?:安排|计划|步骤)|(?:建议|执行|实施)步骤|(?:proposed |suggested )?next steps\b|(?:implementation |proposed |execution )?plan(?:\s*[:：(（]|$))"#)
    static let choiceHeading = Rule(#"(?i)^(?:可选项|选项|可选方案|choices|options)\s*[:：]?$"#)
    static let label = Rule(#"(?i)^(?:原因|背景|根因|目标|目的|希望|约束|限制|要求|结果|建议|当前[线上]*状态|cause|reason|goal|objective|constraint|status|result|error|warning|build)\s*[:：]"#)
    static let rationale = Rule(#"(?i)原因|根因|因为|由于|以免|避免再|\b(?:reason|cause|because|due to|to avoid)\b"#)
    static let goal = Rule(#"(?i)目标|验收|期望|预期|希望|目的|为了|\b(?:goal|objective|aim|success criteria|desired)\b"#)
    static let constraint = Rule(#"(?i)约束|限制|要求|不要|不得|不再|禁止|必须|不能|不动|不重启|勿动|仅限|只标记|\b(?:constraint|must|never|only|cannot|avoid|requires?|deadline)\b"#)
    static let factQualifier = Rule(#"已(?:经|完成|修复)|不再(?:误报|报错|失败)|\b(?:had to|previously required)\b"#)
    static let state = Rule(#"(?i)^(?:[●•-]\s*)?(?:已(?:完成|回答|决定|选择|修复)|正在|运行中|等待输入|成功|失败|错误|(?:running|working|waiting|error|blocked|completed|finished|decided|tests? (?:passed|failed)|build (?:failed|succeeded|finished)))"#)
    static let number = Rule(#"\d+(?:[.,]\d+)*"#)
    static let progress = Rule(#"(?i)^(?:building|compiling|downloading|processing|loading|progress|下载中|编译中|正在加载)\b.*\d(?:%|\s*/\s*\d)"#)
    static let keyContinuation = Rule(#"^(?=[A-Za-z0-9_+/=-]*[0-9_+/=-])[A-Za-z0-9_+/=-]{8,}$"#)
    static let model = Rule(#"(?i)^(?:build|plan|ask|agent|chat|debug|edit)\s*[·•]\s*\S"#)
    static let provider = Rule(#"(?i)\b(?:deepseek|claude|gpt[- ]?\d|gemini|sonnet|opus|haiku|qwen)\b"#)
    static let identifier = Rule(#"^[\p{L}\d_.\-/]{1,48}$"#)
    static let pathOnly = Rule(#"^(?:/|~/|\.\.?/)[^\s]+$"#)
    static let usage = Rule(#"(?i)^(?:(?:[/~.][^\n]*?|[\w.\-/]+)\s+)?\d+(?:[.,]\d+)?[kmg]\s*\(\d+(?:\.\d+)?%\)(?:\s+(?:ctrl|cmd|alt|⌘)[+ -]\S+(?:\s+\w+)?)?$"#)
    static let shortcuts = Rule(#"(?i)^(?:(?:ctrl|cmd|alt)[+-][\w/]+\s+(?:commands?|shortcuts?|menu)|\?\s+(?:for|show)\s+(?:commands?|shortcuts?))$"#)
    static let footerWrap = Rule(#"(?i)^(?:[\w./~-]+\s+)?(?:commands?|shortcuts?)$"#)
    static let tmuxStatus = Rule(#"^(?:\[\d+\]\s+\d+:\S+|\d+\s+\S+\s+(?:[A-Z]{1,4}\s+)?[│|]\s+\S)"#)
    static let processHeading = Rule(#"(?i)^PID\s+USER\s+.*\b(?:RES|VIRT|CPU%)"#)
    static let processRow = Rule(#"^\d+\s+\S+\s+(?:-?\d+|RT)\s+-?\d+\s+"#)
    static let meter = Rule(#"(?i)^(?:(?:\d+|mem|swp)\s*\[[|!# ▏▎▍▌▋▊▉█.]+(?:\d|\])|(?:[█▉▊▋▌▍▎▏░▒▓━─#=]{2,}\s*)+\d+(?:\.\d+)?%\s*$)"#)
  }

  private struct Rule {
    let regex: NSRegularExpression
    init(_ expression: String) { regex = try! NSRegularExpression(pattern: expression) }
    func test(_ s: String) -> Bool {
      regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    func matches(in s: String) -> Int { regex.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
    func capture(_ s: String) -> String? {
      guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let r = Range(m.range(at: 1), in: s) else { return nil }
      return String(s[r])
    }
    func replace(in s: String, with value: String) -> String {
      regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: value)
    }
  }
}

private extension Character {
  var isIdeographic: Bool { unicodeScalars.contains { $0.properties.isIdeographic || (0x3000...0x303F).contains($0.value) } }
}
