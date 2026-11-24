import Foundation

struct RemoteSession: Codable, Hashable, Identifiable {
  let id: Int64
  let name: String
  var touchPaging: Bool? = nil
  var directory: String? = nil
  var snapshot: Bool? = nil
  var snapshotVersion: Int? = nil

  var negotiatedSnapshotVersion: PaneSnapshotVersion? {
    guard snapshot == true else { return nil }
    return snapshotVersion == 2 ? .v2 : .v1
  }
}

struct DecisionSnapshot: Codable, Equatable {
  let id: Int64
  let name: String
  let text: String
  var context: String? = nil
  var capture: NativePaneCapture? = nil

  private enum CodingKeys: String, CodingKey { case id, name, text, context }
}

struct NativePaneCapture: Decodable, Equatable {
  let version: Int
  let paneId: UInt64
  let columns: Int
  let rows: Int
  let alternate: Bool
  let screenTruncated: Bool
  let historyTruncated: Bool
  let historyRowsScanned: Int
  let historyCompacted: Bool
}

enum PaneSnapshotVersion {
  case v1, v2

  private struct V2Payload: Decodable {
    let snapshot: DecisionSnapshot
    let capture: NativePaneCapture
    private enum Key: CodingKey { case context }

    init(from decoder: Decoder) throws {
      // The v2 contract requires the context field even when history is unavailable.
      let fields = try decoder.container(keyedBy: Key.self)
      guard fields.contains(.context) else { throw SnapshotError.invalid }
      var value = try DecisionSnapshot(from: decoder)
      capture = try NativePaneCapture(from: decoder)
      let historyAbsent = value.context == nil && !capture.historyTruncated && !capture.historyCompacted
      guard capture.version == 2, capture.columns > 0, capture.rows > 0,
            (0...5000).contains(capture.historyRowsScanned),
            capture.historyRowsScanned > 0 || historyAbsent,
            !capture.alternate || capture.historyRowsScanned == 0 else { throw SnapshotError.invalid }
      value.capture = capture
      snapshot = value
    }
  }

  func decode(_ data: Data, for session: RemoteSession) throws -> DecisionSnapshot {
    let decoder = JSONDecoder()
    let pane: DecisionSnapshot
    let maxScreenBytes: Int, maxScreenLines: Int, maxHistoryBytes: Int, maxHistoryLines: Int
    switch self {
    case .v1:
      guard let result = try? decoder.decode(DecisionSnapshot.self, from: data) else { throw SnapshotError.invalid }
      pane = result
      (maxScreenBytes, maxScreenLines, maxHistoryBytes, maxHistoryLines) = (6000, 40, 16 * 1024, 120)
    case .v2:
      guard let result = try? decoder.decode(V2Payload.self, from: data) else { throw SnapshotError.invalid }
      pane = result.snapshot
      (maxScreenBytes, maxScreenLines, maxHistoryBytes, maxHistoryLines) = (32 * 1024, min(256, result.capture.rows), 32 * 1024, 320)
    }
    guard session.id >= 0, pane.id == session.id, pane.name == session.name else { throw SnapshotError.sessionChanged }
    func fits(_ text: String, bytes: Int, lines: Int) -> Bool {
      text.utf8.count <= bytes && text.utf8.split(separator: 10, omittingEmptySubsequences: false).count <= lines
    }
    guard fits(pane.text, bytes: maxScreenBytes, lines: maxScreenLines),
          fits(pane.context ?? "", bytes: maxHistoryBytes, lines: maxHistoryLines) else { throw SnapshotError.invalid }
    return pane
  }

  private enum SnapshotError: LocalizedError {
    case invalid, sessionChanged

    var errorDescription: String? {
      switch self {
      case .invalid: return "窗格快照格式无效，请刷新后重试。"
      case .sessionChanged: return "会话已更名或关闭，请刷新列表。"
      }
    }
  }
}
