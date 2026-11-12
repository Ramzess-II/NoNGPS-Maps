final class NavigationControlView: SolidTouchView {
  private enum Constants {
    static let buttonContentInset: CGFloat = 15
    static var metricFont: UIFont { .bold22.dynamic(maxSize: 26) }
    static var metricLegendFont: UIFont { .bold12.dynamic(maxSize: 16) }
    static var metricSubFont: UIFont { .regular13.dynamic(maxSize: 17) }
    /// A drag shorter than this is not meant to move the sheet.
    static let dragDistance = CGFloat(20)
  }

  @IBOutlet private var distanceWithLegendLabel: UILabel!
  @IBOutlet private var coveredLabel: UILabel!
  @IBOutlet private var progressView: UIView!
  @IBOutlet private var routingProgress: NSLayoutConstraint!
  @IBOutlet private var timeLabel: UILabel!
  @IBOutlet private var arrivalLabel: UILabel!
  @IBOutlet private var handleView: UIView!
  @IBOutlet private var handleBar: UIView!
  @IBOutlet private var extendedView: UIView!

  @IBOutlet private var settingsButton: MWMButton!
  @IBOutlet private var stopButton: UIButton!

  @IBOutlet private var ttsButton: MWMButton! {
    didSet {
      ttsButton.setImage(UIImage.icVoiceOff, for: .normal)
      ttsButton.setImage(UIImage.icVoiceOn, for: .selected)
      ttsButton.setImage(UIImage.icVoiceOn, for: [.selected, .highlighted])
      onTTSStatusUpdated()
    }
  }

  @IBOutlet private var trackRecordingButton: MWMButton!
  @IBOutlet private var searchButton: MWMButton!
  @IBOutlet private var sourceView: UIView!
  private let sourceButton = NavButton()

  private lazy var dimBackground: DimBackground = .init(mainView: self, tapAction: { [weak self] in
    self?.diminish()
  })

  weak var ownerView: UIView!
  weak var delegate: RouteNavigationControlsDelegate!

  private weak var navigationInfo: MWMNavigationDashboardEntity?
  private var extendedConstraint: NSLayoutConstraint!
  private var notExtendedConstraint: NSLayoutConstraint!
  private let diminishSelector = #selector(diminish)

  var isVisible = false {
    didSet {
      guard isVisible != oldValue else { return }
      if isVisible {
        addView()
      } else {
        removeView()
      }
    }
  }

  private var isExtended = false {
    didSet {
      guard isVisible, superview != nil, isExtended != oldValue else { return }

      dimBackground.setVisible(isExtended, completion: nil)
      extendedView.isHidden = !isExtended
      superview!.animateConstraints(animations: { [weak self] in
        guard let self else { return }
        if self.isExtended {
          self.notExtendedConstraint.isActive = false
          self.extendedConstraint.isActive = true
        } else {
          self.extendedConstraint.isActive = false
          self.notExtendedConstraint.isActive = true
        }
      })
    }
  }

  private var lastViewportHeight: CGFloat = 0

  override func awakeFromNib() {
    super.awakeFromNib()

    for label in [distanceWithLegendLabel, timeLabel] as [UILabel] {
      configureMetricLabel(label, font: Constants.metricFont)
    }
    for label in [coveredLabel, arrivalLabel] as [UILabel] {
      configureMetricLabel(label, font: Constants.metricSubFont)
    }
    configureHandle()

    configureButton(settingsButton)
    configureButton(ttsButton)
    configureButton(trackRecordingButton)
    configureButton(searchButton)
    searchButton.accessibilityLabel = L("search")
    configureStopButton(stopButton)
    configureSourceButton()

    MWMTextToSpeech.add(self)
  }

  private func configureMetricLabel(_ label: UILabel, font: UIFont) {
    label.font = font
    label.adjustsFontForContentSizeCategory = true
    label.clipsToBounds = true
    label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    label.configureSingleLineAutoScaling()
  }

  private func configureButton(_ button: UIButton) {
    button.imageView?.contentMode = .scaleAspectFit
    button.contentHorizontalAlignment = .fill
    button.contentVerticalAlignment = .fill
    button.contentEdgeInsets = UIEdgeInsets(top: Constants.buttonContentInset,
                                            left: Constants.buttonContentInset,
                                            bottom: Constants.buttonContentInset,
                                            right: Constants.buttonContentInset)
  }

  /// The handle opens and closes the buttons under the numbers by a tap, the whole sheet by a drag.
  private func configureHandle() {
    handleBar.layer.cornerRadius = handleBar.bounds.height / 2
    handleView.isAccessibilityElement = true
    handleView.accessibilityTraits = .button
    handleView.accessibilityLabel = L("placepage_more_button")
    handleView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(extendAction)))
    addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDragged)))
  }

  private func configureSourceButton() {
    sourceView.addSubview(sourceButton)
    NSLayoutConstraint.activate([
      sourceButton.leadingAnchor.constraint(equalTo: sourceView.leadingAnchor),
      sourceButton.trailingAnchor.constraint(equalTo: sourceView.trailingAnchor),
      sourceButton.centerYAnchor.constraint(equalTo: sourceView.centerYAnchor),
    ])
    sourceButton.addTarget(self, action: #selector(sourceButtonAction), for: .touchUpInside)
  }

  private func configureStopButton(_ button: UIButton) {
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.titleLabel?.numberOfLines = 1
    button.setContentCompressionResistancePriority(.required, for: .vertical)
    button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 22, bottom: 10, right: 22)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if let navigationInfo {
      onNavigationInfoUpdated(navigationInfo)
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard isVisible, superview != nil, frame.height != lastViewportHeight else { return }
    lastViewportHeight = frame.height
    updateVisibleViewportArea()
  }

  private func addView() {
    guard superview != ownerView, !ownerView.subviews.contains(self) else { return }
    ownerView.addSubview(self)
    NoGpsStatusBar.navSheetButton = sourceButton
    sourceButton.show(NoGps.status())

    let lg = ownerView.safeAreaLayoutGuide
    leadingAnchor.constraint(equalTo: lg.leadingAnchor).isActive = true
    trailingAnchor.constraint(equalTo: lg.trailingAnchor).isActive = true

    extendedConstraint = bottomAnchor.constraint(equalTo: ownerView.bottomAnchor)
    extendedConstraint.isActive = false

    notExtendedConstraint = progressView.bottomAnchor.constraint(equalTo: lg.bottomAnchor)
    notExtendedConstraint.isActive = true

    updateVisibleViewportArea()
  }

  private func removeView() {
    // Cancel diminish timer on remove, otherwise performSelector keeps the view alive ~5s after close, blocking deinit.
    cancelDiminishTimer()
    updateVisibleViewportArea(onClose: true)
    dimBackground.setVisible(false, completion: {
      self.removeFromSuperview()
    })
  }

  private func updateVisibleViewportArea(onClose: Bool = false) {
    let bottom = frame.height / 2
    let insets = UIEdgeInsets(top: 0, left: 0, bottom: onClose ? 0 : bottom, right: 0)
    MapViewController.shared()?.updateVisibleAreaInsets(for: self, insets: insets, updatingViewport: true)
  }

  func setTrackRecordingState(_ state: TrackRecordingState) {
    trackRecordingButton.coloring = state == .active ? .red : .black
  }

  func onNavigationInfoUpdated(_ info: MWMNavigationDashboardEntity) {
    navigationInfo = info
    guard isVisible else { return }
    let routingNumberAttributes: [NSAttributedString.Key: Any] =
      [
        NSAttributedString.Key.foregroundColor: UIColor.blackPrimaryText,
        NSAttributedString.Key.font: Constants.metricFont,
      ]
    let routingLegendAttributes: [NSAttributedString.Key: Any] =
      [
        NSAttributedString.Key.foregroundColor: UIColor.blackSecondaryText,
        NSAttributedString.Key.font: Constants.metricLegendFont,
      ]

    timeLabel.text = DurationFormatter.routingDurationString(from: TimeInterval(info.timeToTarget))
    arrivalLabel.text = info.arrival

    if let targetDistance = info.targetDistance {
      let distanceWithLegend = NSMutableAttributedString(string: targetDistance, attributes: routingNumberAttributes)
      if let targetUnits = info.targetUnits {
        distanceWithLegend.append(NSAttributedString(string: " " + targetUnits, attributes: routingLegendAttributes))
      }
      distanceWithLegendLabel.attributedText = distanceWithLegend
    }
    // Not known on a transit route.
    coveredLabel.text = info.distanceCovered.map { String(format: L("nogps_nav_covered"), $0) }

    routingProgress.constant = progressView.width * info.progress / 100
  }

  @objc
  private func extendAction() {
    isExtended = !isExtended
    refreshDiminishTimer()
  }

  /// Up opens the sheet, down closes it.
  @objc
  private func handleDragged(_ gesture: UIPanGestureRecognizer) {
    guard gesture.state == .ended else { return }
    let dy = gesture.translation(in: self).y
    guard abs(dy) >= Constants.dragDistance else { return }
    isExtended = dy < 0
    refreshDiminishTimer()
  }

  @IBAction
  private func ttsButtonAction(_: Any) {
    delegate.ttsButtonDidTap()
  }

  @IBAction
  private func settingsButtonAction(_: Any) {
    delegate.settingsButtonDidTap()
  }

  @IBAction
  private func stopRoutingButtonAction(_: Any) {
    delegate.stopRoutingButtonDidTap()
  }

  @IBAction
  private func trackRecordingButtonAction(_: Any) {
    delegate.trackRecordingButtonDidTap()
  }

  @IBAction
  private func searchButtonAction(_: Any) {
    isExtended = false
    delegate.searchButtonDidTap()
  }

  @objc
  private func sourceButtonAction() {
    NoGpsStatusBar.showNavSheet()
  }

  private func refreshDiminishTimer() {
    cancelDiminishTimer()
    perform(diminishSelector, with: self, afterDelay: 5)
  }

  private func cancelDiminishTimer() {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: diminishSelector, object: self)
  }

  @objc
  private func diminish() {
    isExtended = false
  }

  override func applyTheme() {
    super.applyTheme()
    onTTSStatusUpdated()
    setTrackRecordingState(TrackRecordingManager.shared.recordingState)
  }

  override var sideButtonsAreaAffectDirections: MWMAvailableAreaAffectDirections {
    .bottom
  }

  override var widgetsAreaAffectDirections: MWMAvailableAreaAffectDirections {
    alternative(iPhone: .bottom, iPad: [])
  }

  override var trackRecordingButtonAreaAffectDirections: MWMAvailableAreaAffectDirections {
    .bottom
  }
}

extension NavigationControlView: MWMTextToSpeechObserver {
  func onTTSStatusUpdated() {
    guard MWMRouter.isRoutingActive() else { return }
    ttsButton.isHidden = !MWMTextToSpeech.isTTSEnabled()
    if !ttsButton.isHidden {
      ttsButton.isSelected = MWMTextToSpeech.tts().active
    }
    refreshDiminishTimer()
  }
}
