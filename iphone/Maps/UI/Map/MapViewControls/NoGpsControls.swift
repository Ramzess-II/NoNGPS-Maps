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

  private let statusButton = UIButton(type: .custom)
  // The side buttons are on the left in right-to-left languages.
  private static let isRTL = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
  private let panel = MapControlsPanel(edge: NoGpsControls.isRTL ? .right : .left)
  private let buttons = UIStackView()
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
  private weak var calibrationAlert: UIAlertController?
  private weak var firmwareAlert: UIAlertController?
  private let flagRecorder = NoGpsFlagRecorder()
  private let speedView = NoGpsSpeedView()
  private var speedEdge = NSLayoutConstraint()
  private var speedBottom = NSLayoutConstraint()

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

  static func updateTurnsBottom(_ bottom: CGFloat) {
    guard bottom != turnsBottom else { return }
    turnsBottom = bottom
    DispatchQueue.main.async {
      shared?.updateLayout(animated: true)
    }
  }

  // MARK: - Views

  private static func makeButton(_ symbol: String) -> BottomTabBarButton {
    let button = BottomTabBarButton()
    button.setStyleAndApply(.mapPanelButton)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(systemName: symbol), for: .normal)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Constants.buttonWidth),
      button.heightAnchor.constraint(equalToConstant: Constants.buttonHeight),
    ])
    return button
  }

  private func setupViews(in superview: UIView) {
    statusButton.translatesAutoresizingMaskIntoConstraints = false
    statusButton.layer.cornerRadius = Constants.statusMinHeight / 2
    statusButton.layer.shadowColor = UIColor.black.cgColor
    statusButton.layer.shadowOpacity = 0.25
    statusButton.layer.shadowOffset = CGSize(width: 0, height: 1)
    statusButton.contentEdgeInsets = UIEdgeInsets(top: 3, left: 14, bottom: 3, right: 14)
    statusButton.titleLabel?.numberOfLines = 3
    statusButton.titleLabel?.textAlignment = .center
    statusButton.titleLabel?.lineBreakMode = .byTruncatingTail
    statusButton.addTarget(self, action: #selector(statusTapped), for: .touchUpInside)
    superview.addSubview(statusButton)

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
    superview.addSubview(speedView)
    speedEdge = Self.isRTL ? speedView.rightAnchor.constraint(equalTo: superview.leftAnchor)
      : speedView.leftAnchor.constraint(equalTo: superview.leftAnchor)
    speedBottom = speedView.bottomAnchor.constraint(equalTo: superview.topAnchor)

    statusTop = statusButton.topAnchor.constraint(equalTo: superview.topAnchor)
    statusCenterX = statusButton.centerXAnchor.constraint(equalTo: superview.leftAnchor)
    buttonsEdge = Self.isRTL ? buttons.rightAnchor.constraint(equalTo: superview.leftAnchor)
      : buttons.leftAnchor.constraint(equalTo: superview.leftAnchor)
    buttonsCenterY = buttons.centerYAnchor.constraint(equalTo: superview.topAnchor)
    NSLayoutConstraint.activate([
      statusTop, statusCenterX, buttonsEdge, buttonsCenterY, speedEdge, speedBottom,
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
    // The mark stands and waits for the user: a toast about it is easy to miss while driving. The bottom bar tells the
    // source and the accuracy.
    statusButton.isHidden = !status.roadLost
    let title = NSMutableAttributedString(string: L("nogps_status_road_lost"),
                                          attributes: [.font: UIFont.boldSystemFont(ofSize: 15),
                                                       .foregroundColor: UIColor.white])
    title.append(NSAttributedString(string: "\n" + L("nogps_status_road_lost_hint"),
                                    attributes: [.font: UIFont.boldSystemFont(ofSize: 12),
                                                 .foregroundColor: UIColor.white]))
    statusButton.setAttributedTitle(title, for: .normal)
    statusButton.backgroundColor = Constants.noneColor
    blinkStatus(status.roadLost)

    // The car is marked by hand only while the position is not from GPS. The button is blue while the next tap on the
    // map shows where the car is, the tap is taken back when GPS is used again.
    let canMark = status.source != .gps
    if !canMark, status.markByTap {
      NoGps.setMarkByTap(false)
    }
    manualButton.tintColor = canMark && status.markByTap ? .linkBlue : .blackSecondaryText
    voiceFlagButton.tintColor = flagRecorder.isRecording ? Constants.noneColor : .blackSecondaryText
    let logging = Settings.isFileLoggingEnabled()
    buttonsHidden = [reverseButton: !status.movedByHand,
                     switchMarkButton: !(status.movedByHand && status.otherMarks > 0),
                     manualButton: !canMark,
                     flagButton: !logging,
                     voiceFlagButton: !logging]
    hasButtons = buttonsHidden.values.contains(false)
    // Nothing to correct: the panel slides out as it is, its buttons are hidden after that.
    if hasButtons || !isPanelShown {
      applyButtonsHidden()
    }
    updateLayout()
    NoGpsStatusBar.update(status)
  }

  private func blinkStatus(_ blink: Bool) {
    // The system removes the animation in the background, the next refresh adds it again.
    let layer = statusButton.layer
    guard blink != (layer.animation(forKey: Constants.blinkKey) != nil) else { return }
    guard blink else {
      layer.removeAnimation(forKey: Constants.blinkKey)
      return
    }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1
    animation.toValue = Constants.blinkOpacity
    animation.duration = Constants.blinkDuration
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
    Self.showSensors()
  }

  /// \param onClose is called when the screen is closed.
  static func showSensors(onClose: (() -> Void)? = nil) {
    // The calibration alert may come while the screen is open, under another alert too.
    let top = UIViewController.topViewController()
    var shown: UIViewController? = top
    while let controller = shown {
      if let sensors = (controller as? UINavigationController)?.viewControllers.first as? NoGpsSensorsViewController {
        // Shown already, e.g. under the calibration alert: its closing is told as well.
        if let onClose {
          sensors.onClose = onClose
        }
        return
      }
      shown = controller.presentingViewController
    }
    let sensors = NoGpsSensorsViewController()
    sensors.onClose = onClose
    top.present(UINavigationController(rootViewController: sensors), animated: true)
  }

  /// The sensor box has been plugged in: asks the user to calibrate it, the car should stand on a level place.
  private func offerBoxCalibration() {
    // As on Android, not asked in the background: the car may be driving when the user comes back. The sensors
    // screen still tells to calibrate the box. The box may be powered on again before the user answers.
    guard UIApplication.shared.applicationState == .active, calibrationAlert == nil else { return }
    let alert = UIAlertController(title: L("nogps_box_calibration"),
                                  message: L("nogps_box_calibration_offer"),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("later"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("nogps_sensors_calibrate_box"), style: .default) { _ in
      NoGps.calibrate()
      // It shows how the calibration goes.
      Self.showSensors()
    })
    UIViewController.topViewController().present(alert, animated: true)
    calibrationAlert = alert
  }

  /// The box works with another firmware than the app is tested with: asks the user to install the one of the app.
  private func offerFirmwareUpdate() {
    // As the calibration, not asked in the background: the car may be driving when the user comes back. The sensors
    // screen still offers the firmware.
    let status = NoGps.status()
    guard UIApplication.shared.applicationState == .active, firmwareAlert == nil, !status.bundledFirmware.isEmpty
    else { return }
    let alert = UIAlertController(title: L("nogps_firmware_title"),
                                  message: String(format: L("nogps_firmware_offer"), status.boxFirmware,
                                                  status.bundledFirmware),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("later"), style: .cancel))
    alert.addAction(UIAlertAction(title: String(format: L("nogps_firmware_install"), status.bundledFirmware),
                                  style: .default) { _ in
        NoGps.startFirmwareUpdate()
        // It shows how the update goes.
        Self.showSensors()
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
    case .boxCalibrationAdvised:
      offerBoxCalibration()
      text = nil
    case .firmwareUpdateAvailable:
      offerFirmwareUpdate()
      text = nil
    case .firmwareUpdateDone: text = String(format: L("nogps_firmware_done"), NoGps.status().boxFirmware)
    case .firmwareUpdateFailed:
      text = String(format: L("nogps_firmware_failed"), firmwareErrorText(NoGps.status().firmwareUpdateError))
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
