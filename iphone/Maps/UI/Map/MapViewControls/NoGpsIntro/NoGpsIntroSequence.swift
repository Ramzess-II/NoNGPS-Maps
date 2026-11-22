/// The steps of the intro of the first start, in their order: the modal telling what the app is, then a balloon at
/// every panel of the map. See NoGpsIntroSequence.
enum NoGpsIntroStep: CaseIterable {
  case modal
  case bottom
  case right
  case left

  var text: String {
    switch self {
    case .modal: L("nogps_intro_text")
    case .bottom: L("nogps_intro_bottom")
    // The zoom buttons of iOS also take a slide, see MWMSideButtons; Android has no such gesture.
    case .right: L("nogps_intro_right") + " " + L("nogps_intro_right_swipe")
    case .left: L("nogps_intro_left")
    }
  }

  /// The text of a balloon is typed out to draw the eye; the text of the modal is too long for that.
  var isTyped: Bool {
    self != .modal
  }
}

/// The intro of the first start: which step is shown, how much of its text is typed out and what a tap does. It holds
/// no view, so a test drives it like the real app does. The same machine runs on Android, see nogps.intro.
/// IntroSequence.
final class NoGpsIntroSequence {
  /// The text of a balloon appears at this speed, characters per second: about as fast as it is read, so the eye goes
  /// to the panel without waiting for the text. The longest balloon, the right panel with the slide line, takes about
  /// four seconds.
  static let typeCharsPerS = 20.0

  private static let steps = NoGpsIntroStep.allCases

  private var index = 0
  /// A tap while the text was typing showed the rest of it at once.
  private var isTyped = false

  /// The intro is shown once, on the map: not again after it was shown, and not over the navigation.
  static func isNeeded(shown: Bool, navigating: Bool) -> Bool {
    !shown && !navigating
  }

  /// The step shown now, nil when the intro is over.
  var step: NoGpsIntroStep? {
    index < Self.steps.count ? Self.steps[index] : nil
  }

  var isOver: Bool {
    step == nil
  }

  /// How many characters of a text of this length are shown after elapsed seconds on the step.
  func revealed(_ length: Int, _ elapsedS: Double) -> Int {
    guard let step else { return 0 }
    guard !isTyped, step.isTyped else { return length }
    return min(length, Int(elapsedS * Self.typeCharsPerS))
  }

  func isTyping(_ length: Int, _ elapsedS: Double) -> Bool {
    revealed(length, elapsedS) < length
  }

  /// A tap while the text types shows the rest of it, the next tap opens the next step.
  func tap(_ length: Int, _ elapsedS: Double) {
    guard !isOver else { return }
    if isTyping(length, elapsedS) {
      isTyped = true
      return
    }
    index += 1
    isTyped = false
  }

  /// The navigation starts: the intro is over and does not come back.
  func finish() {
    index = Self.steps.count
    isTyped = false
  }
}
