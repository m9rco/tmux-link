import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TerminalStatusWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TerminalActivity.self) { context in
      let state = displayState(context)
      HStack(spacing: 12) {
        Image(systemName: "terminal").foregroundStyle(.mint)
        VStack(alignment: .leading, spacing: 3) {
          Text("Tmux Link").font(.headline)
          Text(state.phase.title).font(.subheadline)
        }
        Spacer()
        reading(state)
      }
      .padding()
      .activityBackgroundTint(.black)
      .activitySystemActionForegroundColor(.mint)
      .foregroundStyle(.white)
      .accessibilityElement(children: .combine)
    } dynamicIsland: { context in
      let state = displayState(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(state.phase.title, systemImage: stateSymbol(state))
            .font(.headline).foregroundStyle(tint(state))
        }
        DynamicIslandExpandedRegion(.trailing) {
          reading(state)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            Label("Tmux Link", systemImage: "terminal")
            Spacer()
            if state.phase == .ready { Text(state.mtls ? "mTLS · SSH" : "SSH") }
          }.font(.caption).foregroundStyle(.secondary)
        }
      } compactLeading: {
        Image(systemName: stateSymbol(state)).foregroundStyle(tint(state))
          .accessibilityLabel(state.phase.title)
      } compactTrailing: {
        Text(state.phase == .ready ? state.sampleText : compactText(state))
          .font(.caption2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
      } minimal: {
        Image(systemName: stateSymbol(state)).foregroundStyle(tint(state))
          .accessibilityLabel(state.phase.title)
      }
      .keylineTint(tint(state))
    }
  }

  private func displayState(_ context: ActivityViewContext<TerminalActivity>)
    -> TerminalActivityState
  {
    if #available(iOSApplicationExtension 16.2, *) {
      return context.state.display(at: Date(), systemStale: context.isStale)
    }
    return context.state.display(at: Date())
  }

  @ViewBuilder
  private func reading(_ state: TerminalActivityState) -> some View {
    if state.phase == .ready || state.historical && (state.milliseconds != nil || state.timedOut) {
      VStack(alignment: .trailing, spacing: 2) {
        Text(state.sampleText).font(.headline.monospacedDigit())
          .accessibilityLabel("会话往返延迟 " + state.sampleText)
        if state.historical {
          Text(state.observedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func stateSymbol(_ state: TerminalActivityState) -> String {
    switch state.phase {
    case .ready: return state.timedOut ? "exclamationmark.circle.fill" : "circle.fill"
    case .paused, .ended: return "circle"
    default: return "ellipsis.circle"
    }
  }

  private func compactText(_ state: TerminalActivityState) -> String {
    switch state.phase {
    case .paused: return "待更新"
    case .ended: return "断开"
    default: return "连接中"
    }
  }

  private func tint(_ state: TerminalActivityState) -> Color {
    state.phase == .ready && !state.timedOut ? .mint : .orange
  }
}
