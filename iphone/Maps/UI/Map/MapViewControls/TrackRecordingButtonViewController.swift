final class TrackRecordingButtonViewController: MWMViewController {
  private enum Constants {
    static let buttonWidth = CGFloat(56)
    static let buttonHeight = CGFloat(48)
    static let topOffset = CGFloat(6)
    static let blinkingDuration = 1.0
    static let color: (lighter: UIColor, darker: UIColor) = (.red, .red.darker(percent: 0.3))
  }

  private let button = BottomTabBarButton()
  private let panel = MapControlsPanel(edge: UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? .left : .right)
  private var blinkingTimer: Timer?
  private var topConstraint = NSLayoutConstraint()
  private var widthConstraint = NSLayoutConstraint()
  private var state: TrackRecordingButtonState = .hidden

  private static var availableArea: CGRect = .zero
  private static var topConstraintValue: CGFloat {
    availableArea.origin.y + Constants.topOffset
  }

  /// The panel goes on to the edge of the screen, under the safe area too.
  private static var widthConstraintValue: CGFloat {
    let edgeGap = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
      ? availableArea.minX
      // The window may be narrower than the screen, e.g. in Split View.
      : (MapViewController.shared()?.view.bounds.maxX ?? UIScreen.main.bounds.maxX) - availableArea.maxX
    return Constants.buttonWidth + max(edgeGap, 0)
  }

  @objc
  init() {
    super.init(nibName: nil, bundle: nil)
    let ownerViewController = MapViewController.shared()
    ownerViewController?.addChild(self)
    ownerViewController?.controlsView.addSubview(view)
    setupView()
    layout()
    startTimer()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setState(state, completion: nil)
  }

  // MARK: - Public methods

  @objc
  func setState(_ state: TrackRecordingButtonState, completion: (() -> Void)?) {
    self.state = state
    switch state {
    case .visible:
      panel.setHidden(false, completion: nil)
      button.setHidden(false, completion: nil)
    case .hidden:
      panel.setHidden(true, completion: nil)
      button.setHidden(true, completion: completion)
    case .closed:
      close(completion: completion)
    @unknown default:
      fatalError()
    }
  }

  // MARK: - Private methods

  private func setupView() {
    view.translatesAutoresizingMaskIntoConstraints = false
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.isHidden = true
    view.addSubview(panel)
    view.addSubview(button)

    button.setStyleAndApply(.trackRecordingWidgetButton)
    button.tintColor = Constants.color.darker
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(resource: .icMenuTrackRecording), for: .normal)
    button.addTarget(self, action: #selector(didTap), for: .touchUpInside)
    button.isHidden = true
  }

  private func layout() {
    guard let superview = view.superview else { return }
    topConstraint = view.topAnchor.constraint(equalTo: superview.topAnchor, constant: Self.topConstraintValue)
    widthConstraint = view.widthAnchor.constraint(equalToConstant: Self.widthConstraintValue)
    NSLayoutConstraint.activate([
      topConstraint,
      widthConstraint,
      view.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
      view.heightAnchor.constraint(equalToConstant: Constants.buttonHeight),

      panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      panel.topAnchor.constraint(equalTo: view.topAnchor),
      panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      button.widthAnchor.constraint(equalToConstant: Constants.buttonWidth),
      button.topAnchor.constraint(equalTo: view.topAnchor),
      button.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func updateLayout() {
    guard let superview = view.superview else { return }
    superview.animateConstraints {
      self.topConstraint.constant = Self.topConstraintValue
      self.widthConstraint.constant = Self.widthConstraintValue
    }
  }

  private func startTimer() {
    guard blinkingTimer == nil else { return }
    var lighter = false
    let timer = Timer.scheduledTimer(withTimeInterval: Constants.blinkingDuration, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      UIView.animate(withDuration: Constants.blinkingDuration, animations: {
        self.button.tintColor = lighter ? Constants.color.lighter : Constants.color.darker
        lighter.toggle()
      })
    }
    blinkingTimer = timer
    RunLoop.current.add(timer, forMode: .common)
  }

  private func stopTimer() {
    blinkingTimer?.invalidate()
    blinkingTimer = nil
  }

  private func close(completion: (() -> Void)?) {
    stopTimer()
    panel.setHidden(true)
    button.setHidden(true) { [weak self] in
      guard let self else { return }
      self.removeFromParent()
      self.view.removeFromSuperview()
      completion?()
    }
  }

  static func updateAvailableArea(_ frame: CGRect) {
    availableArea = frame
    guard let button = MapViewController.shared()?.controlsManager.trackRecordingButton else { return }
    DispatchQueue.main.async {
      button.updateLayout()
    }
  }

  // MARK: - Actions

  @objc
  private func didTap(_: Any) {
    MapViewController.shared()?.showTrackRecordingPlacePage()
  }
}
