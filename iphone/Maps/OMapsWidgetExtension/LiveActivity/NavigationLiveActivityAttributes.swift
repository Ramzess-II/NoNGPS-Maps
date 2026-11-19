import ActivityKit
import SwiftUI

/// The colors of the position sources, the same in the app and in the Live Activity. The extension can't see the
/// look of the status bar, so a look is sent as symbol names and a color key.
enum NavigationLiveActivityColor: String, Codable {
  case good, inertial, blue, orange, red, gray, secondary

  /// GPS moves the mark.
  static let goodColor = UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255, alpha: 1)
    : UIColor(red: 0x1E / 255, green: 0x8E / 255, blue: 0x3E / 255, alpha: 1)
  }

  /// The box moves the mark.
  static let inertialColor = UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255, alpha: 1)
    : UIColor(red: 0x8E / 255, green: 0x44 / 255, blue: 0xC4 / 255, alpha: 1)
  }

  var uiColor: UIColor {
    switch self {
    case .good: return Self.goodColor
    case .inertial: return Self.inertialColor
    case .blue: return .systemBlue
    case .orange: return .systemOrange
    case .red: return .systemRed
    case .gray: return .systemGray
    case .secondary: return .secondaryLabel
    }
  }

  var color: Color { Color(uiColor) }

  init(_ uiColor: UIColor) {
    let all: [Self] = [.good, .inertial, .blue, .orange, .red, .gray]
    self = all.first { $0.uiColor == uiColor } ?? .secondary
  }
}

/// An icon by name: a system symbol, or an image of the asset catalog.
struct NavigationLiveActivitySymbol: Codable, Hashable {
  let name: String
  let isAsset: Bool

  static func system(_ name: String) -> Self { Self(name: name, isAsset: false) }
  static func asset(_ name: String) -> Self { Self(name: name, isAsset: true) }

  var image: UIImage? { isAsset ? UIImage(named: name) : UIImage(systemName: name) }
}

struct NavigationLiveActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// The look of the position source as in the bottom sheet: the icon, its color and a badge.
    struct Source: Codable, Hashable {
      let symbol: NavigationLiveActivitySymbol
      let color: NavigationLiveActivityColor
      /// A badge without a symbol is a dot.
      let hasBadge: Bool
      let badgeSymbol: String?
      let badgeColor: NavigationLiveActivityColor
    }

    let source: Source
    /// An SF Symbol of the next turn.
    let turnSymbol: String
    let distanceToTurn: String
    let street: String
    let distanceLeft: String
    let timeLeft: String
    /// The arrival time, to the minute.
    let arrival: Date
    let stopTitle: String
  }
}
