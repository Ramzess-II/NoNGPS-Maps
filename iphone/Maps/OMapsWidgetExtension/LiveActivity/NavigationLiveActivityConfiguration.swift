import SwiftUI
import WidgetKit

struct NavigationLiveActivityConfiguration: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: NavigationLiveActivityAttributes.self) { context in
      NavigationLiveActivityView(state: context.state, isStale: context.isStale)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          NavigationSourceIcon(source: context.state.source, side: 30)
        }
        DynamicIslandExpandedRegion(.trailing) {
          HStack(spacing: 6) {
            Image(systemName: context.state.turnSymbol).font(.title3.weight(.semibold))
            Text(context.state.distanceToTurn).font(.title3.weight(.bold))
          }
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.street).font(.subheadline).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            NavigationDetails(state: context.state)
            Spacer(minLength: 0)
            StopNavigationButton(title: context.state.stopTitle)
          }
        }
      } compactLeading: {
        NavigationSourceIcon(source: context.state.source, side: 20)
      } compactTrailing: {
        Text(context.state.distanceToTurn).font(.subheadline.weight(.semibold)).lineLimit(1)
      } minimal: {
        NavigationSourceIcon(source: context.state.source, side: 20)
      }
    }
  }
}
