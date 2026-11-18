import AppIntents

/// The Stop button of the navigation Live Activity. It runs in the app, which sets `handler`.
@available(iOS 17.0, *)
struct StopNavigationIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop"

  static var handler: (() -> Void)?

  func perform() async throws -> some IntentResult {
    await MainActor.run { Self.handler?() }
    return .result()
  }
}
