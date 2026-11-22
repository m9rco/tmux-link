import ActivityKit
import Foundation

// This payload can appear on the Lock Screen and paired devices.
struct TerminalActivityState: Codable, Hashable {
  enum Phase: String, Codable {
    case connecting, ssh, auth, attaching, ready, paused, ended

    var title: String {
      switch self {
      case .connecting: return "连接中转"
      case .ssh: return "校验 SSH 主机"
      case .auth: return "验证 SSH 身份"
      case .attaching: return "接入 tmux"
      case .ready: return "已连接"
      case .paused: return "等待更新"
      case .ended: return "已断开"
      }
    }
  }

  var phase: Phase = .connecting
  var mtls = false
  var milliseconds: UInt32?
  var timedOut = false
  var observedAt = Date()
  // iOS 16.1 cannot schedule staleness. Its background view dates every reading.
  var historical = false

  var staleDate: Date { observedAt.addingTimeInterval(30) }

  func display(at now: Date, systemStale: Bool = false) -> Self {
    guard phase != .ended, systemStale || now >= staleDate else { return self }
    var stale = self
    stale.phase = .paused
    stale.historical = true
    return stale
  }

  var latencyText: String {
    if timedOut { return "超时" }
    if let milliseconds { return "\(milliseconds) ms" }
    return "—"
  }

  var sampleText: String {
    historical && (milliseconds != nil || timedOut) ? "上次 " + latencyText : latencyText
  }
}

@available(iOS 16.1, *)
struct TerminalActivity: ActivityAttributes {
  typealias ContentState = TerminalActivityState
}
