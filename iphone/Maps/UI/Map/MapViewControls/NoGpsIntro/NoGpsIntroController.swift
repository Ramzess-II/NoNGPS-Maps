/// Runs the intro of the first start on the map: the modal, then a balloon at every panel. Started from
/// MapViewController after a short delay, as PlacePageHeaderViewController does for its educational popover, and shown
/// once, see NoGpsIntroSequence.
@objc
final class NoGpsIntroController: NSObject {
  private enum Constants {
    static let shownKey = "NoGpsIntroShown"
    /// The panels of the map are laid out by then and the balloons find them.
    static let startDelay: TimeInterval = 0.7
    /// A balloon is redrawn on it: the typewriter shows one or two characters, and the balloon follows a panel
    /// the user moves or a screen that turns.
    static let tick: TimeInterval = 0.05
  }

  private static var current: NoGpsIntroController?

  private let sequence = NoGpsIntroSequence()
  private let overlay = NoGpsIntroOverlay()
  private weak var owner: MapViewController?
  private var timer: Timer?
  private var stepStart = Date()

  /// Tells what the app is and what its panels do, once on the first start on the map.
  @objc
  static func startIfNeeded(in owner: MapViewController) {
    guard NoGpsIntroSequence.isNeeded(shown: UserDefaults.standard.bool(forKey: Constants.shownKey),
                                      navigating: MWMRouter.isRoutingActive())
    else { return }
    play(in: owner)
  }

  /// Plays the intro whatever the flag says: the How NonGPS works page ends here. Every play builds its own
  /// sequence, so it starts at the modal again.
  @objc
  static func play(in owner: MapViewController) {
    guard current == nil else { return }
    let controller = NoGpsIntroController(owner: owner)
    current = controller
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.startDelay) {
      guard current === controller else { return }
      controller.start()
    }
  }

  private init(owner: MapViewController) {
    self.owner = owner
    super.init()
  }

  private func start() {
    guard let owner, !MWMRouter.isRoutingActive() else { return end() }
    // As soon as the intro is shown: an app killed halfway through it does not show it again.
    UserDefaults.standard.set(true, forKey: Constants.shownKey)
    NoGpsControls.setIntroMode(true)
    overlay.frame = owner.controlsView.bounds
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.onTap = { [weak self] in self?.onTap() }
    owner.controlsView.addSubview(overlay)
    openStep()
  }

  private func openStep() {
    timer?.invalidate()
    timer = nil
    guard let step = sequence.step else { return end() }
    stepStart = Date()
    guard step != .modal else {
      overlay.isHidden = true
      showModal()
      return
    }
    guard let anchor = Self.anchor(for: step) else {
      // Nothing to point at: the step is skipped rather than shown with an arrow into the void.
      sequence.tap(0, 0)
      openStep()
      return
    }
    overlay.anchor = anchor
    overlay.text = step.text
    overlay.revealed = 0
    overlay.isHidden = false
    let timer = Timer(timeInterval: Constants.tick, repeats: true) { [weak self] _ in self?.onTick() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private static func anchor(for step: NoGpsIntroStep) -> UIView? {
    switch step {
    case .modal: nil
    case .bottom: BottomTabBarViewController.controller?.introAnchor
    case .right: MWMSideButtons.introAnchor
    case .left: NoGpsControls.introAnchor
    }
  }

  private func showModal() {
    guard let owner else { return end() }
    let modal = NoGpsIntroModalViewController(onClose: { [weak self] in
      guard let self else { return }
      sequence.tap(0, 0)
      openStep()
    })
    owner.present(modal, animated: true)
  }

  private var elapsedS: Double {
    -stepStart.timeIntervalSinceNow
  }

  private func onTick() {
    // The navigation starts: the intro is over and does not come back.
    guard !MWMRouter.isRoutingActive() else { return finish() }
    overlay.revealed = sequence.revealed(overlay.text.count, elapsedS)
    overlay.setNeedsLayout()
  }

  private func onTap() {
    let length = overlay.text.count
    let elapsed = elapsedS
    let typing = sequence.isTyping(length, elapsed)
    sequence.tap(length, elapsed)
    // The rest of the text at once, or the next step.
    if typing {
      overlay.revealed = length
    } else {
      openStep()
    }
  }

  private func finish() {
    sequence.finish()
    openStep()
  }

  /// The panels go back to their own rules.
  private func end() {
    timer?.invalidate()
    timer = nil
    overlay.removeFromSuperview()
    NoGpsControls.setIntroMode(false)
    if Self.current === self {
      Self.current = nil
    }
  }
}
