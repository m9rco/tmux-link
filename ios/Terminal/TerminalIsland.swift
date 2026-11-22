import ActivityKit
import Darwin
import UIKit

enum IslandHardware {
  // Unknown models, iPads, notch and Home-button iPhones keep the inline bar.
  static func supported(_ identifier: String) -> Bool {
    switch identifier {
    case "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5",
      "iPhone16,1", "iPhone16,2",
      "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4",
      "iPhone18,1", "iPhone18,2", "iPhone18,3", "iPhone18,4",
      "iPhone19,2", "iPhone19,3", "iPhone19,4":
      return true
    default: return false
    }
  }

  static var supportedDevice: Bool {
    #if targetEnvironment(simulator)
      return supported(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "")
    #else
      var system = utsname()
      guard uname(&system) == 0 else { return false }
      let identifier = withUnsafeBytes(of: &system.machine) {
        String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
      }
      return supported(identifier)
    #endif
  }
}

@MainActor
protocol IslandReporting: AnyObject {
  func publish(_ state: TerminalActivityState, immediately: Bool)
  func end()
}

@MainActor
@available(iOS 16.1, *)
final class TerminalIsland: IslandReporting {
  private let activity: Activity<TerminalActivity>
  private let presentationChanged: (Bool) -> Void
  private var watch: Task<Void, Never>?
  private var updates: Task<Void, Never>?
  private var last: TerminalActivityState
  private var lastUpdate = Date()
  private var pending: TerminalActivityState?
  private var finished = false

  init?(_ initial: TerminalActivityState, presentationChanged: @escaping (Bool) -> Void) {
    guard IslandHardware.supportedDevice, ActivityAuthorizationInfo().areActivitiesEnabled,
      UIApplication.shared.applicationState == .active
    else { return nil }
    do {
      if #available(iOS 16.2, *) {
        activity = try .request(
          attributes: TerminalActivity(), content: Self.content(initial), pushType: nil)
      } else {
        activity = try .request(
          attributes: TerminalActivity(), contentState: initial, pushType: nil)
      }
    } catch { return nil }
    self.presentationChanged = presentationChanged
    self.last = initial
    let activity = self.activity
    presentationChanged(activity.activityState == .active)
    watch = Task { [weak self] in
      for await state in activity.activityStateUpdates {
        guard !Task.isCancelled, let self, !finished else { return }
        switch state {
        case .ended, .dismissed:
          finished = true
          updates?.cancel()
          presentationChanged(false)
          return
        case .active: presentationChanged(true)
        case .stale: presentationChanged(false)
        default: break
        }
      }
    }
  }

  @available(iOS 16.2, *)
  private static func content(_ state: TerminalActivityState) -> ActivityContent<
    TerminalActivityState
  > {
    ActivityContent(state: state, staleDate: state.staleDate)
  }

  func publish(_ state: TerminalActivityState, immediately: Bool) {
    guard !finished else { return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      end()
      return
    }
    // Publish transitions immediately. Coalesce normal five-second SSH samples.
    let transition =
      last.phase != state.phase || last.timedOut != state.timedOut
      || (last.milliseconds == nil && state.milliseconds != nil)
    guard state != last, immediately || transition || Date().timeIntervalSince(lastUpdate) >= 12
    else { return }
    lastUpdate = Date()
    last = state
    pending = state
    guard updates == nil else { return }
    updates = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, !finished, let next = pending {
        pending = nil
        if #available(iOS 16.2, *) {
          await activity.update(Self.content(next))
        } else {
          await activity.update(using: next)
        }
      }
      updates = nil
    }
  }

  func end() {
    guard !finished else { return }
    finished = true
    pending = nil
    watch?.cancel()
    updates?.cancel()
    presentationChanged(false)
    Self.end(activity)
  }

  private static func end(_ activity: Activity<TerminalActivity>) {
    Task {
      let ended = TerminalActivityState(phase: .ended)
      if #available(iOS 16.2, *) {
        await activity.end(
          ActivityContent(state: ended, staleDate: nil), dismissalPolicy: .immediate)
      } else {
        await activity.end(using: ended, dismissalPolicy: .immediate)
      }
    }
  }

  static func clearPreviousLaunch() {
    for activity in Activity<TerminalActivity>.activities { end(activity) }
  }
}
