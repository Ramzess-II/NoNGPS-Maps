import AppIntents
import SwiftUI
import WidgetKit

/// The icon of the position source: its symbol in the color of the look, a badge at the corner.
struct NavigationSourceIcon: View {
  let source: NavigationLiveActivityAttributes.ContentState.Source
  var side: CGFloat = 24

  var body: some View {
    icon
      .foregroundColor(source.color.color)
      .frame(width: side, height: side)
      .overlay(alignment: .topTrailing) {
        if source.hasBadge {
          badge.offset(x: side * 0.2, y: -side * 0.2)
        }
      }
  }

  @ViewBuilder
  private var icon: some View {
    if source.symbol.isAsset {
      Image(source.symbol.name).renderingMode(.template).resizable().scaledToFit()
    } else {
      Image(systemName: source.symbol.name).resizable().scaledToFit()
    }
  }

  private var badge: some View {
    let badgeSide = source.badgeSymbol == nil ? side * 0.4 : side * 0.55
    return ZStack {
      Circle().fill(source.badgeColor.color)
      if let symbol = source.badgeSymbol {
        Image(systemName: symbol)
          .font(.system(size: badgeSide * 0.6, weight: .black))
          .foregroundColor(.white)
      }
    }
    .frame(width: badgeSide, height: badgeSide)
  }
}

struct StopNavigationButton: View {
  let title: String

  var body: some View {
    if #available(iOS 17.0, *) {
      Button(intent: StopNavigationIntent()) {
        Text(title).font(.subheadline.weight(.semibold))
      }
      .tint(.red)
    }
    // Before iOS 17 a tap opens the app.
  }
}

/// The details of the navigation: the turn, what is left and the arrival.
struct NavigationDetails: View {
  let state: NavigationLiveActivityAttributes.ContentState

  var body: some View {
    HStack(spacing: 8) {
      Text(state.distanceLeft)
      Text("·")
      Text(state.timeLeft)
      Text("·")
      Text(state.arrival, style: .time)
    }
    .font(.subheadline)
    .lineLimit(1)
    .minimumScaleFactor(0.7)
  }
}

/// The lock screen and the banner.
struct NavigationLiveActivityView: View {
  let state: NavigationLiveActivityAttributes.ContentState
  /// The app doesn't update the activity: it is killed.
  let isStale: Bool

  var body: some View {
    HStack(spacing: 14) {
      NavigationSourceIcon(source: state.source, side: 32)
      Image(systemName: state.turnSymbol)
        .font(.title.weight(.semibold))
        .frame(width: 36)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(state.distanceToTurn).font(.title3.weight(.bold))
          if !state.street.isEmpty {
            Text(state.street).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
          }
        }
        NavigationDetails(state: state)
      }
      Spacer(minLength: 0)
      StopNavigationButton(title: state.stopTitle)
    }
    .padding(16)
    .opacity(isStale ? 0.5 : 1)
    .activityBackgroundTint(.black.opacity(0.2))
  }
}
