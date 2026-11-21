/// The controls of the navigation without GPS on the map: where the position comes from, the manual mode and the
/// buttons correcting the position of the car. They are laid out in the free area of the side buttons, the buttons on
/// a panel at the left edge of the screen, opposite the side buttons: at the right one in right-to-left languages. The
/// user can move the panel up and down.
@objc
final class NoGpsControls: NSObject {
  private enum Constants {
    // As the side buttons on the right in MWMSideButtonsView.xib: both panels are equally wide.
    static let buttonWidth = CGFloat(56)
    static let buttonHeight = CGFloat(48)
    static let statusTopOffset = CGFloat(8)
    static let turnsGap = CGFloat(8)
    static let statusMinHeight = CGFloat(36)
    static let statusMaxWidth = CGFloat(260)
    static let refreshInterval: TimeInterval = 1
    static let blinkKey = "blink"
    static let blinkDuration: CFTimeInterval = 0.4
    static let blinkOpacity = Float(0.2)
    // The calibration waits for a stop: its bar flashes slower and softer than the lost road.
    static let calibrationBlinkDuration: CFTimeInterval = 1.2
    static let calibrationBlinkOpacity = Float(0.5)
    static let noneColor = UIColor(red: 0xD3 / 255, green: 0x2F / 255, blue: 0x2F / 255, alpha: 1)
    static let panelPlaceKey = "NoGpsLeftPanelY"
    // Of the speed from the corner of the free area, and from the panel above it.
    static let speedMargin = CGFloat(10)
    /// Of a flag screenshot: the street names stay readable, the png stays small for the mail.
    static let screenshotScale = CGFloat(2)
    /// A thick line above the buttons of the testers: they stand apart from those correcting the car.
    static let testersGap = CGFloat(12)
    static let testersDividerHeight = CGFloat(4)
  }

  private weak static var shared: NoGpsControls?
  private static var logFlags = 0
  private static var lastFlag = ""
  private static var availableArea = CGRect.zero
  /// The bottom of the turns of the navigation in the window, 0 without them. They are at the edge of the panel.
  private static var turnsBottom = CGFloat(0)
  /// The intro of the first start points at the panels: they are held open while it runs.
  private static var isIntroMode = false

  private let statusButton = NoGpsPillButton(type: .custom)
  /// At the bottom of the map until the box is calibrated.
  private let calibrationButton = NoGpsPillButton(type: .custom)
  // The side buttons are on the left in right-to-left languages.
  private static let isRTL = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
  private let panel = MapControlsPanel(edge: NoGpsControls.isRTL ? .right : .left)
  private let buttons = NoGpsButtonStack()
  private var dragger: MapPanelDragger?
  // Of every button but the first one.
  private var dividers = [UIView: UIView]()
  private var isPanelShown = true
  private var hasButtons = true
  private var buttonsHidden = [UIView: Bool]()
  private let reverseButton = NoGpsControls.makeButton("arrow.triangle.2.circlepath")
  private let switchMarkButton = NoGpsControls.makeButton("arrow.left.arrow.right")
  private let manualButton = NoGpsControls.makeButton("hand.point.up.left")
  private let flagButton = NoGpsControls.makeButton("flag.fill")
  private let voiceFlagButton = NoGpsControls.makeButton("mic.fill")
  private var statusTop = NSLayoutConstraint()
  private var statusCenterX = NSLayoutConstraint()
  private var buttonsEdge = NSLayoutConstraint()
  private var buttonsCenterY = NSLayoutConstraint()
  private var timer: Timer?
  private weak var firmwareAlert: UIAlertController?
  private let flagRecorder = NoGpsFlagRecorder()
  private let speedView = NoGpsSpeedView()
  private let speedHint = NoGpsSpeedHintView()
  private let calibrationBar = NoGpsCalibrationBarView()
  private let sprintView = NoGpsSprintView()
  private var sprintBottom = NSLayoutConstraint()
  private var sprintCenterX = NSLayoutConstraint()
  private var speedEdge = NSLayoutConstraint()
  private var speedBottom = NSLayoutConstraint()
  private var calibrationBottom = NSLayoutConstraint()
  private var calibrationCenterX = NSLayoutConstraint()
  private var calibrationMaxWidth = NSLayoutConstraint()

  @objc
  init(owner: MapViewController) {
    super.init()
    Self.shared = self
    setupViews(in: owner.controlsView)
    refresh()
    let timer = Timer(timeInterval: Constants.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    NotificationCenter.default.addObserver(self, selector: #selector(onEvent), name: NoGps.eventNotification, object: nil)
    // As on Android: a voice note is not recorded in the background.
    NotificationCenter.default.addObserver(self, selector: #selector(stopVoiceFlag),
                                           name: UIApplication.didEnterBackgroundNotification, object: nil)
    NoGpsFlags.deleteExpired()
  }

  deinit {
    timer?.invalidate()
  }

  static func updateAvailableArea(_ frame: CGRect) {
    availableArea = frame
    DispatchQueue.main.async {
      shared?.updateLayout(animated: true)
    }
  }

  /// The panel the balloon of the intro of the first start points at, see NoGpsIntroController.
  static var introAnchor: UIView? {
    shared?.panel
  }

  /// Holds the panel of the car buttons open with the buttons the intro talks about, and gives it back to its own
  /// rules when the intro ends.
  static func setIntroMode(_ intro: Bool) {
    isIntroMode = intro
    shared?.refresh()
  }

  static func updateTurnsBottom(_ bottom: CGFloat) {
    guard bottom != turnsBottom else { return }
    turnsBottom = bottom
    DispatchQueue.main.async {
      shared?.updateLayout(animated: true)
    }
  }

  // MARK: - Views

  private static func makeButton(_ symbol: String) -> NoGpsPanelButton {
    let button = NoGpsPanelButton()
    button.setStyleAndApply(.mapPanelButton)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(systemName: symbol), for: .normal)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Constants.buttonWidth),
      button.heightAnchor.constraint(equalToConstant: Constants.buttonHeight),
    ])
    return button
  }

  private static func stylePill(_ button: UIButton, verticalInset: CGFloat = 3) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.layer.cornerRadius = Constants.statusMinHeight / 2
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.25
    button.layer.shadowOffset = CGSize(width: 0, height: 1)
    button.contentEdgeInsets = UIEdgeInsets(top: verticalInset, left: 14, bottom: verticalInset, right: 14)
    button.titleLabel?.numberOfLines = 3
    button.titleLabel?.textAlignment = .center
    button.titleLabel?.lineBreakMode = .byTruncatingTail
  }

  private func setupViews(in superview: UIView) {
    Self.stylePill(statusButton, verticalInset: 10)
    statusButton.setImage(UIImage(systemName: "location.viewfinder"), for: .normal)
    statusButton.tintColor = .white
    statusButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
    statusButton.addTarget(self, action: #selector(statusTapped), for: .touchUpInside)
    superview.addSubview(statusButton)
    Self.stylePill(calibrationButton)
    calibrationButton.backgroundColor = .systemOrange
    calibrationButton.setAttributedTitle(NSAttributedString(string: L("nogps_calibration_snackbar"), attributes: [
      .font: UIFont.boldSystemFont(ofSize: 15), .foregroundColor: UIColor.white,
    ]), for: .normal)
    calibrationButton.isHidden = true
    calibrationButton.addTarget(self, action: #selector(calibrationTapped), for: .touchUpInside)
    superview.addSubview(calibrationButton)

    reverseButton.addTarget(self, action: #selector(reverseDirection), for: .touchUpInside)
    switchMarkButton.addTarget(self, action: #selector(switchMark), for: .touchUpInside)
    manualButton.addTarget(self, action: #selector(toggleMarkByTap), for: .touchUpInside)
    flagButton.addTarget(self, action: #selector(flagLog), for: .touchUpInside)
    voiceFlagButton.addTarget(self, action: #selector(voiceFlag), for: .touchUpInside)
    flagRecorder.onFinish = { [weak self] seconds in
      self?.refresh()
      if seconds > 0 {
        Toast.show(withText: String(format: L("nogps_flag_voice_saved"), seconds))
      }
    }
    reverseButton.accessibilityLabel = L("nogps_reverse_direction")
    switchMarkButton.accessibilityLabel = L("nogps_switch_mark")
    manualButton.accessibilityLabel = L("nogps_manual_position")
    // For the testers only, no strings for them.
    flagButton.isAccessibilityElement = false
    voiceFlagButton.isAccessibilityElement = false

    buttons.axis = .vertical
    buttons.alignment = .center
    buttons.spacing = MapControlsPanel.groupGap
    buttons.translatesAutoresizingMaskIntoConstraints = false
    let items = [reverseButton, switchMarkButton, manualButton, flagButton, voiceFlagButton]
    for item in items {
      buttons.addArrangedSubview(item)
    }
    for item in items.dropFirst() {
      dividers[item] = item === flagButton
        ? MapControlsPanel.addGroupDivider(above: item, gap: Constants.testersGap, height: Constants.testersDividerHeight)
        : MapControlsPanel.addGroupDivider(above: item)
    }
    panel.translatesAutoresizingMaskIntoConstraints = false
    superview.addSubview(panel)
    superview.addSubview(buttons)
    // Under the speed: it slides out of it.
    speedHint.addTarget(self, action: #selector(speedHintTapped), for: .touchUpInside)
    superview.addSubview(speedHint)
    calibrationBar.addTarget(self, action: #selector(calibrationBarTapped), for: .touchUpInside)
    superview.addSubview(calibrationBar)
    superview.addSubview(speedView)
    superview.addSubview(sprintView)
    speedEdge = Self.isRTL ? speedView.rightAnchor.constraint(equalTo: superview.leftAnchor)
      : speedView.leftAnchor.constraint(equalTo: superview.leftAnchor)
    speedBottom = speedView.bottomAnchor.constraint(equalTo: superview.topAnchor)

    statusTop = statusButton.topAnchor.constraint(equalTo: superview.topAnchor)
    statusCenterX = statusButton.centerXAnchor.constraint(equalTo: superview.leftAnchor)
    buttonsEdge = Self.isRTL ? buttons.rightAnchor.constraint(equalTo: superview.leftAnchor)
      : buttons.leftAnchor.constraint(equalTo: superview.leftAnchor)
    buttonsCenterY = buttons.centerYAnchor.constraint(equalTo: superview.topAnchor)
    sprintBottom = sprintView.bottomAnchor.constraint(equalTo: superview.topAnchor)
    sprintCenterX = sprintView.centerXAnchor.constraint(equalTo: superview.leftAnchor)
    calibrationBottom = calibrationButton.bottomAnchor.constraint(equalTo: superview.topAnchor)
    calibrationCenterX = calibrationButton.centerXAnchor.constraint(equalTo: superview.leftAnchor)
    calibrationMaxWidth = calibrationButton.widthAnchor.constraint(lessThanOrEqualToConstant: Constants.statusMaxWidth)
    NSLayoutConstraint.activate([
      statusTop, statusCenterX, buttonsEdge, buttonsCenterY, speedEdge, speedBottom,
      Self.isRTL ? speedHint.rightAnchor.constraint(equalTo: speedView.centerXAnchor)
        : speedHint.leftAnchor.constraint(equalTo: speedView.centerXAnchor),
      speedHint.bottomAnchor.constraint(equalTo: speedView.bottomAnchor),
      Self.isRTL ? calibrationBar.rightAnchor.constraint(equalTo: speedView.centerXAnchor)
        : calibrationBar.leftAnchor.constraint(equalTo: speedView.centerXAnchor),
      calibrationBar.bottomAnchor.constraint(equalTo: speedView.bottomAnchor),
      calibrationBottom, calibrationCenterX, calibrationMaxWidth, sprintBottom, sprintCenterX,
      calibrationButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.statusMinHeight),
      // The panel goes on to the edge of the screen, under the safe area too.
      Self.isRTL ? panel.rightAnchor.constraint(equalTo: superview.rightAnchor)
        : panel.leftAnchor.constraint(equalTo: superview.leftAnchor),
      Self.isRTL ? panel.leftAnchor.constraint(equalTo: buttons.leftAnchor)
        : panel.rightAnchor.constraint(equalTo: buttons.rightAnchor),
      panel.topAnchor.constraint(equalTo: buttons.topAnchor),
      panel.bottomAnchor.constraint(equalTo: buttons.bottomAnchor),
      statusButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.statusMinHeight),
      statusButton.widthAnchor.constraint(lessThanOrEqualToConstant: Constants.statusMaxWidth),
    ])
    dragger = MapPanelDragger(view: buttons, key: Constants.panelPlaceKey,
                              travel: { [weak self] in self?.panelTravel ?? 0 },
                              onLift: { [weak self] in self?.panel.isLifted = $0 },
                              onMove: { [weak self] in self?.updateLayout() })
    updateLayout()
  }

  /// \param animated moves the buttons as the side buttons on the right move, when a panel opens or closes.
  private func updateLayout(animated: Bool = false) {
    let area = Self.availableArea
    guard !area.isEmpty else { return }
    let height = buttonsHeight
    let fraction = dragger?.fraction ?? MapPanelDragger.Constants.defaultFraction
    let panelTop = panelTop
    let panelArea = panelAreaHeight
    let place = {
      self.statusTop.constant = area.minY + Constants.statusTopOffset
      self.statusCenterX.constant = area.midX
      self.buttonsEdge.constant = Self.isRTL ? area.maxX : area.minX
      // The side buttons on the right have the same center by default.
      self.buttonsCenterY.constant = panelTop + height / 2 + fraction * max(0, panelArea - height)
      self.speedEdge.constant = Self.isRTL ? area.maxX - Constants.speedMargin : area.minX + Constants.speedMargin
      self.speedBottom.constant = area.maxY - Constants.speedMargin
      // From the middle of the speed to the other edge of the free area.
      self.speedHint.setFullWidth(area.width - 2 * Constants.speedMargin - NoGpsSpeedView.side / 2)
      self.calibrationBar.setFullWidth(area.width - 2 * Constants.speedMargin - NoGpsSpeedView.side / 2)
      // In the middle at the bottom, clear of the speed in the corner.
      let speedWidth = self.speedView.isHidden ? 0 : NoGpsSpeedView.side + 2 * Constants.speedMargin
      self.calibrationBottom.constant = area.maxY - Constants.speedMargin
      self.calibrationCenterX.constant = area.midX
      self.calibrationMaxWidth.constant = min(Constants.statusMaxWidth, max(0, area.width - 2 * speedWidth))
      // In the bottom third, above the speed and the bar of its calibration: the mark and the road ahead stay seen.
      self.sprintBottom.constant = area.maxY - Constants.speedMargin - speedWidth
      self.sprintCenterX.constant = area.midX
      self.sprintView.setMaxWidth(area.width - 2 * Constants.speedMargin)
    }
    if animated, let superview = buttons.superview {
      superview.animateConstraints(animations: place)
    } else {
      place()
    }
    // A panel can leave no place for the buttons.
    showPanel(hasButtons && height <= panelArea)
  }

  /// The panel moves above the speed.
  private var panelBottom: CGFloat {
    let speed = speedView.isHidden ? 0 : NoGpsSpeedView.side + 2 * Constants.speedMargin
    return Self.availableArea.maxY - speed
  }

  /// The panel moves under the turns of the navigation, unless it doesn't fit there: then it can cover them, as in
  /// landscape on a phone.
  private var panelTop: CGFloat {
    let area = Self.availableArea
    guard Self.turnsBottom > 0, let superview = buttons.superview else { return area.minY }
    let turns = superview.convert(CGPoint(x: 0, y: Self.turnsBottom), from: nil).y + Constants.turnsGap
    return turns > area.minY && panelBottom - turns >= buttonsHeight ? turns : area.minY
  }

  private var panelAreaHeight: CGFloat {
    panelBottom - panelTop
  }

  private var buttonsHeight: CGFloat {
    buttons.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
  }

  private var panelTravel: CGFloat {
    max(0, panelAreaHeight - buttonsHeight)
  }

  private func gap(above button: UIView) -> CGFloat {
    button === flagButton ? Constants.testersGap : MapControlsPanel.groupGap
  }

  private func applyButtonsHidden() {
    for (button, hidden) in buttonsHidden where button.isHidden != hidden {
      button.isHidden = hidden
    }
    let shown = buttons.arrangedSubviews.filter { !$0.isHidden }
    for (button, divider) in dividers {
      divider.isHidden = button === shown.first
    }
    // The gap is set after the button shown above: a hidden one takes no spacing.
    for (above, below) in zip(shown, shown.dropFirst()) {
      buttons.setCustomSpacing(gap(above: below), after: above)
    }
  }

  /// Slides the panel with its buttons in from its edge of the screen, or out there.
  private func showPanel(_ show: Bool) {
    guard show != isPanelShown else { return }
    isPanelShown = show
    dragger?.isEnabled = show
    UIView.animate(withDuration: AppConstants.defaultAnimationDuration, delay: 0, options: [.beginFromCurrentState],
                   animations: {
                     let away = Self.isRTL ? (self.panel.superview?.bounds.width ?? 0) - self.panel.frame.minX
                       : -self.panel.frame.maxX
                     let offset = show ? CGAffineTransform.identity : CGAffineTransform(translationX: away, y: 0)
                     for view in [self.panel, self.buttons] as [UIView] {
                       view.alpha = show ? 1 : 0
                       view.transform = offset
                     }
                   }, completion: { _ in
                     if !self.isPanelShown {
                       self.applyButtonsHidden()
                     }
                   })
  }

  // MARK: - State

  private func refresh() {
    let status = NoGps.status()
    // Once a second: the status is too heavy for every position.
    speedView.update(status: status, location: LocationManager.lastLocation())
    calibrationBar.update(status: status, speedShown: !speedView.isHidden)
    // The calibration bar of the box comes first: both slide out of the speed.
    speedHint.update(status: status, speedShown: !speedView.isHidden && !calibrationBar.isShown)
    // The event came when the app was not active: the offer waits for the user.
    if status.firmwareOfferPending {
      offerFirmwareUpdate()
    }
    // The mark stands and waits for the user: a toast about it is easy to miss while driving. The bottom bar tells the
    // source and the accuracy.
    statusButton.isHidden = !status.roadLost
    let title = NSMutableAttributedString(string: L("nogps_status_road_lost"),
                                          attributes: [.font: UIFont.boldSystemFont(ofSize: 15),
                                                       .foregroundColor: UIColor.white])
    title.append(NSAttributedString(string: "\n" + L("nogps_status_road_lost_gps_hint"),
                                    attributes: [.font: UIFont.boldSystemFont(ofSize: 12),
                                                 .foregroundColor: UIColor.white]))
    statusButton.setAttributedTitle(title, for: .normal)
    statusButton.backgroundColor = Constants.noneColor
    Self.blink(statusButton, status.roadLost)
    // It replaces the offer to calibrate: an alert is easy to dismiss and forget.
    let needsCalibration = NoGpsBoxPage.needsCalibration(status)
    // The bar next to the speed is the calibration now, the warning comes back when it ends without a calibration.
    let warn = needsCalibration && !calibrationBar.isShown
    calibrationButton.isHidden = !warn
    Self.blink(calibrationButton, warn, duration: Constants.calibrationBlinkDuration,
               opacity: Constants.calibrationBlinkOpacity)

    // The car is marked by hand only while the position is not from GPS. The button is blue while the next tap on the
    // map shows where the car is, the tap is taken back when GPS is used again.
    let canMark = status.source != .gps
    if !canMark, status.markByTap {
      NoGps.setMarkByTap(false)
    }
    manualButton.stateTint = canMark && status.markByTap ? .linkBlue : .blackSecondaryText
    voiceFlagButton.stateTint = flagRecorder.isRecording ? Constants.noneColor : .blackSecondaryText
    let logging = Settings.isFileLoggingEnabled()
    buttonsHidden = [reverseButton: !status.movedByHand,
                     switchMarkButton: !(status.movedByHand && status.otherMarks > 0),
                     manualButton: !canMark,
                     flagButton: !logging,
                     voiceFlagButton: !logging]
    if Self.isIntroMode {
      // The panel is slid out on a fresh install, and the balloon of the intro would point at nothing. The buttons it
      // talks about are held visible; the flags of the testers keep their own rule.
      buttonsHidden[reverseButton] = false
      buttonsHidden[manualButton] = false
    }
    hasButtons = buttonsHidden.values.contains(false)
    // Nothing to correct: the panel slides out as it is, its buttons are hidden after that.
    if hasButtons || !isPanelShown {
      applyButtonsHidden()
    }
    updateLayout()
    NoGpsStatusBar.update(status)
  }

  private static func blink(_ button: UIButton, _ blink: Bool, duration: CFTimeInterval = Constants.blinkDuration,
                            opacity: Float = Constants.blinkOpacity) {
    // The system removes the animation in the background, the next refresh adds it again.
    let layer = button.layer
    guard blink != (layer.animation(forKey: Constants.blinkKey) != nil) else { return }
    guard blink else {
      layer.removeAnimation(forKey: Constants.blinkKey)
      return
    }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1
    animation.toValue = opacity
    animation.duration = duration
    animation.autoreverses = true
    animation.repeatCount = .infinity
    layer.add(animation, forKey: Constants.blinkKey)
  }

  static func formatAccuracy(_ meters: Double) -> String {
    if meters < 1000 {
      return String(format: L("nogps_meters"), Int(meters.rounded()))
    }
    return String(format: L("nogps_kilometers"), meters / 1000)
  }

  // MARK: - Actions

  @objc
  private func statusTapped() {
    guard !NoGps.placeMarkByGps() else { return }
    NoGps.setMarkByTap(true)
    Toast.show(withText: L("nogps_gps_mark_failed"))
    refresh()
  }

  @objc
  private func calibrationTapped() {
    // The bar slides out of the speed: without it the user calibrates on the page.
    guard !speedView.isHidden else {
      NoGpsBoxSheet.show(.calibration)
      return
    }
    NoGps.calibrateWhenStill()
    refresh()
  }

  @objc
  private func calibrationBarTapped() {
    NoGps.cancelCalibrateWhenStill()
    calibrationBar.cancel()
    refresh()
    NoGpsBoxSheet.show(.calibration)
  }

  @objc
  private func speedHintTapped() {
    NoGpsBoxSheet.show(.speedCalibration)
  }

  /// The box works with another firmware than the app is tested with: asks the user to install the one of the app.
  private func offerFirmwareUpdate() {
    // Not asked in the background: the core keeps the offer pending and refresh() asks when the app is active again.
    let status = NoGps.status()
    guard UIApplication.shared.applicationState == .active, firmwareAlert == nil, !status.bundledFirmware.isEmpty
    else { return }
    NoGps.firmwareOfferShown()
    let alert = UIAlertController(title: L("nogps_firmware_title"),
                                  message: String(format: L("nogps_firmware_offer"), status.boxFirmware,
                                                  status.bundledFirmware),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("later"), style: .cancel))
    alert.addAction(UIAlertAction(title: String(format: L("nogps_firmware_install"), status.bundledFirmware),
                                  style: .default) { _ in
        NoGps.startFirmwareUpdate()
        // It shows how the update goes.
        NoGpsBoxSheet.show(.box(firmware: true))
      })
    UIViewController.topViewController().present(alert, animated: true)
    firmwareAlert = alert
  }

  private func firmwareErrorText(_ code: String) -> String {
    switch code {
    case "MOVING": return L("nogps_firmware_error_moving")
    case "LOW_VOLTAGE": return L("nogps_firmware_error_voltage")
    case "LINK": return L("nogps_firmware_error_link")
    case "CANCELED", "ABORTED": return L("nogps_firmware_error_canceled")
    case "ROLLBACK": return L("nogps_firmware_error_rollback")
    case "PENDING": return L("nogps_firmware_error_pending")
    default: return String(format: L("nogps_firmware_error_code"), code)
    }
  }

  /// The log of a test drive is analysed afterwards: the tester marks the moments the car was shown wrong at. The flag
  /// is kept with a screenshot to be sent from the settings, see NoGpsFlags.
  @objc
  private func flagLog() {
    saveFlag(toast: true)
  }

  /// Saves a flag and records a voice note to it up to kFlagVoiceMaxS, a second tap stops earlier.
  @objc
  private func voiceFlag() {
    guard !flagRecorder.isRecording else {
      flagRecorder.stop()
      return
    }
    switch NoGpsFlagRecorder.checkPermission() {
    case .granted:
      if flagRecorder.start(saveFlag(toast: false)) {
        Toast.show(withText: L("nogps_flag_voice_recording"))
      }
    case .denied:
      saveFlag(toast: false)
      Toast.show(withText: L("nogps_flag_mic_denied"))
    case .asked:
      saveFlag(toast: true)
    }
    refresh()
  }

  @objc
  private func stopVoiceFlag() {
    flagRecorder.stop()
  }

  @discardableResult
  private func saveFlag(toast: Bool) -> String {
    // The files of a flag are named by the second: a second flag in it, a voice flag too, is the same moment.
    let name = NoGpsFlags.name(of: Date())
    guard name != Self.lastFlag else { return name }
    Self.lastFlag = name
    // Before the toast covers the map.
    let screenshot = takeScreenshot()
    Self.logFlags += 1
    LOG(.info, "FLAG \(Self.logFlags)")
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    let location = LocationManager.lastLocation()
    let flag = NoGpsFlag(name: name, number: Self.logFlags,
                         lat: location?.coordinate.latitude, lon: location?.coordinate.longitude)
    NoGpsFlags.add(flag, screenshot: screenshot)
    if toast {
      Toast.show(withText: String(format: L("nogps_log_flag"), Self.logFlags, NoGpsFlags.time(of: flag.name)))
    }
    return flag.name
  }

  /// The app as the tester sees it. The map is a Metal layer: drawHierarchy takes it, a layer render would not.
  private func takeScreenshot() -> UIImage? {
    guard let window = buttons.window else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = min(window.screen.scale, Constants.screenshotScale)
    return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
    }
  }

  @objc
  private func toggleMarkByTap() {
    let armed = !NoGps.status().markByTap
    NoGps.setMarkByTap(armed)
    if armed {
      Toast.show(withText: L("nogps_mark_by_tap"))
    }
    refresh()
  }

  @objc
  private func reverseDirection() {
    NoGps.reverseDirection()
  }

  @objc
  private func switchMark() {
    NoGps.switchMark()
    refresh()
  }

  @objc
  private func onEvent(_ notification: Notification) {
    guard let raw = notification.userInfo?[NoGps.eventKey] as? Int, let event = NoGpsEvent(rawValue: raw) else { return }
    let text: String?
    switch event {
    // The buttons show the mode.
    case .manualModeChanged: text = nil
    case .gpsBack: text = L("nogps_gps_back_auto")
    case .gpsLost: text = L("nogps_gps_lost_auto")
    case .gpsSpoofed: text = L("nogps_gps_spoofed")
    case .gpsRestored: text = L("nogps_gps_restored")
    case .roadLost: text = L("nogps_road_lost")
    case .turnsReversed: text = L("nogps_turns_reversed")
    // The box is the only source of the car movement on iOS.
    case .motionSourceStopped: text = L("nogps_box_stopped")
    // The car is always on a road.
    case .markNoRoad: text = L("nogps_mark_no_road")
    case .notCalibrated:
      if NoGps.status().calibration == .mountMoved {
        text = L("nogps_box_moved_stopped")
      } else {
        text = L("nogps_box_uncalibrated_stopped")
      }
    // The bar at the bottom of the map asks for it.
    case .boxCalibrationAdvised: text = nil
    case .speedRangeCalibrated:
      if !speedView.isHidden {
        speedHint.celebrate(status: NoGps.status(), speed: speedView)
      }
      text = nil
    case .sprintMeasured:
      sprintView.show(status: NoGps.status())
      text = nil
    // The bridge has started a new file of the trip log.
    case .tripStarted: text = nil
    case .firmwareUpdateAvailable:
      offerFirmwareUpdate()
      text = nil
    case .firmwareUpdateDone: text = String(format: L("nogps_firmware_done"), NoGps.status().boxFirmware)
    case .firmwareUpdateFailed:
      text = String(format: L("nogps_firmware_failed"), firmwareErrorText(NoGps.status().firmwareUpdateError))
    // The box doesn't take this phone any more: its car is forgotten as by the user. The old system pairing of the box
    // only blocks the next connection, and an app can't remove it: the user is told to.
    case .thisPhoneRemoved:
      let carId = NoGps.status().carId
      if carId.isEmpty {
        text = nil
      } else {
        NoGps.forgetCar(carId)
        text = String(format: L("nogps_phone_removed_forget"), carId)
      }
    @unknown default: text = nil
    }
    if let text {
      Toast.show(withText: text)
    }
    refresh()
  }
}

extension UITableView {
  /// Reloads the table when its rows change, otherwise updates the rows in place: a full reload would take a tap or a
  /// switch from under the finger of the user.
  func reloadData<Row: Equatable>(keepingRows rows: [[Row]], _ shown: inout [[Row]]) {
    if rows == shown, let visible = indexPathsForVisibleRows {
      reconfigureRows(at: visible)
    } else {
      shown = rows
      reloadData()
    }
  }
}
