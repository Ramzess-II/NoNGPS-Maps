/// The controls of the navigation without GPS on the map: where the position comes from, the manual mode and the
/// buttons correcting the position of the car. They are laid out in the free area of the side buttons, the buttons on
/// a panel at the left edge of the screen.
@objc
final class NoGpsControls: NSObject {
  private enum Constants {
    static let buttonWidth = CGFloat(52)
    static let buttonHeight = CGFloat(48)
    static let statusTopOffset = CGFloat(8)
    static let statusMinHeight = CGFloat(36)
    static let statusMaxWidth = CGFloat(260)
    static let refreshInterval: TimeInterval = 1
    static let disabledAlpha = CGFloat(0.4)
    static let blinkKey = "blink"
    static let blinkDuration: CFTimeInterval = 0.4
    static let blinkOpacity = Float(0.2)
    static let noneColor = UIColor(red: 0xD3 / 255, green: 0x2F / 255, blue: 0x2F / 255, alpha: 1)
  }

  private weak static var shared: NoGpsControls?
  private static var availableArea = CGRect.zero

  private let statusButton = UIButton(type: .custom)
  private let panel = MapControlsPanel(edge: .left)
  private let buttons = UIStackView()
  // Of every button but the first one.
  private var dividers = [UIView: UIView]()
  private var isPanelShown = true
  private var hasButtons = true
  private var buttonsHidden = [UIView: Bool]()
  private let shiftForwardButton = NoGpsControls.makeButton("chevron.up")
  private let shiftStepButton = UIButton(type: .system)
  private let shiftBackButton = NoGpsControls.makeButton("chevron.down")
  private let reverseButton = NoGpsControls.makeButton("arrow.triangle.2.circlepath")
  private let switchMarkButton = NoGpsControls.makeButton("arrow.left.arrow.right")
  private let manualButton = NoGpsControls.makeButton("hand.point.up.left")
  private var statusTop = NSLayoutConstraint()
  private var statusCenterX = NSLayoutConstraint()
  private var buttonsLeading = NSLayoutConstraint()
  private var buttonsCenterY = NSLayoutConstraint()
  private var timer: Timer?
  private weak var calibrationAlert: UIAlertController?
  private weak var firmwareAlert: UIAlertController?

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

    shiftStepButton.translatesAutoresizingMaskIntoConstraints = false
    shiftStepButton.titleLabel?.font = .boldSystemFont(ofSize: 14)
    shiftStepButton.setTitleColor(.label, for: .normal)
    NSLayoutConstraint.activate([
      shiftStepButton.widthAnchor.constraint(equalToConstant: Constants.buttonWidth),
      shiftStepButton.heightAnchor.constraint(equalToConstant: Constants.buttonHeight),
    ])
    shiftStepButton.addTarget(self, action: #selector(cycleShiftStep), for: .touchUpInside)

    shiftForwardButton.addTarget(self, action: #selector(shiftForward), for: .touchUpInside)
    shiftBackButton.addTarget(self, action: #selector(shiftBack), for: .touchUpInside)
    reverseButton.addTarget(self, action: #selector(reverseDirection), for: .touchUpInside)
    switchMarkButton.addTarget(self, action: #selector(switchMark), for: .touchUpInside)
    manualButton.addTarget(self, action: #selector(toggleMarkByTap), for: .touchUpInside)
    shiftForwardButton.accessibilityLabel = L("nogps_shift_forward")
    shiftBackButton.accessibilityLabel = L("nogps_shift_back")
    reverseButton.accessibilityLabel = L("nogps_reverse_direction")
    switchMarkButton.accessibilityLabel = L("nogps_switch_mark")
    manualButton.accessibilityLabel = L("nogps_manual_position")

    buttons.axis = .vertical
    buttons.alignment = .center
    buttons.spacing = MapControlsPanel.groupGap
    buttons.translatesAutoresizingMaskIntoConstraints = false
    let items = [shiftForwardButton, shiftStepButton, shiftBackButton, reverseButton, switchMarkButton, manualButton]
    for item in items {
      buttons.addArrangedSubview(item)
    }
    for item in items.dropFirst() {
      dividers[item] = MapControlsPanel.addGroupDivider(above: item)
    }
    panel.translatesAutoresizingMaskIntoConstraints = false
    superview.addSubview(panel)
    superview.addSubview(buttons)

    statusTop = statusButton.topAnchor.constraint(equalTo: superview.topAnchor)
    statusCenterX = statusButton.centerXAnchor.constraint(equalTo: superview.leftAnchor)
    buttonsLeading = buttons.leftAnchor.constraint(equalTo: superview.leftAnchor)
    buttonsCenterY = buttons.centerYAnchor.constraint(equalTo: superview.topAnchor)
    NSLayoutConstraint.activate([
      statusTop, statusCenterX, buttonsLeading, buttonsCenterY,
      // The panel goes on to the edge of the screen, under the safe area too.
      panel.leftAnchor.constraint(equalTo: superview.leftAnchor),
      panel.rightAnchor.constraint(equalTo: buttons.rightAnchor),
      panel.topAnchor.constraint(equalTo: buttons.topAnchor),
      panel.bottomAnchor.constraint(equalTo: buttons.bottomAnchor),
      statusButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.statusMinHeight),
      statusButton.widthAnchor.constraint(lessThanOrEqualToConstant: Constants.statusMaxWidth),
    ])
    updateLayout()
  }

  /// \param animated moves the buttons as the side buttons on the right move, when a panel opens or closes.
  private func updateLayout(animated: Bool = false) {
    let area = Self.availableArea
    guard !area.isEmpty else { return }
    let place = {
      self.statusTop.constant = area.minY + Constants.statusTopOffset
      self.statusCenterX.constant = area.midX
      self.buttonsLeading.constant = area.minX
      // The side buttons on the right have the same center.
      self.buttonsCenterY.constant = area.midY
    }
    if animated, let superview = buttons.superview {
      superview.animateConstraints(animations: place)
    } else {
      place()
    }
    // A panel can leave no place for the buttons.
    let fits = buttons.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height <= area.height
    showPanel(hasButtons && fits)
  }

  private func applyButtonsHidden() {
    for (button, hidden) in buttonsHidden where button.isHidden != hidden {
      button.isHidden = hidden
    }
    let shown = buttons.arrangedSubviews.filter { !$0.isHidden }
    for (button, divider) in dividers {
      divider.isHidden = button === shown.first
    }
  }

  /// Slides the panel with its buttons in from the left edge of the screen, or out there.
  private func showPanel(_ show: Bool) {
    guard show != isPanelShown else { return }
    isPanelShown = show
    UIView.animate(withDuration: AppConstants.defaultAnimationDuration, delay: 0, options: [.beginFromCurrentState],
                   animations: {
                     let offset = show ? CGAffineTransform.identity
                       : CGAffineTransform(translationX: -self.panel.frame.maxX, y: 0)
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

    // The buttons moving the position along the road calibrate the speed, they are shown while the user calibrates it.
    let shifts = status.movedByHand && status.shiftButtonsShown
    shiftStepButton.setTitle(String(format: L("nogps_meters"), status.shiftStepM), for: .normal)
    // The position waits at a turn until the car leaves it, otherwise it would go to another street.
    shiftForwardButton.alpha = status.shiftForwardBlocked ? Constants.disabledAlpha : 1
    shiftBackButton.alpha = status.shiftBackBlocked ? Constants.disabledAlpha : 1
    // The car is marked by hand only while the position is not from GPS. The button is blue while the next tap on the
    // map shows where the car is, the tap is taken back when GPS is used again.
    let canMark = status.source != .gps && status.gpsDisabled
    if !canMark, status.markByTap {
      NoGps.setMarkByTap(false)
    }
    manualButton.tintColor = canMark && status.markByTap ? .linkBlue : .blackSecondaryText
    buttonsHidden = [shiftForwardButton: !shifts, shiftStepButton: !shifts, shiftBackButton: !shifts,
                     reverseButton: !status.movedByHand,
                     switchMarkButton: !(status.movedByHand && status.otherMarks > 0),
                     manualButton: !canMark]
    // The car is corrected by hand only while the box drives it: GPS does otherwise, see the GPS sheet.
    if !status.gpsDisabled {
      buttonsHidden = buttonsHidden.mapValues { _ in true }
    }
    hasButtons = buttonsHidden.values.contains(false)
    // Nothing to correct, e.g. with GPS: the panel slides out as it is, its buttons are hidden after that.
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

  /// Shows a sheet of the bottom bar: half of the screen over the map, pulled up for the rest. The sheets are refreshed
  /// every second, see UITableView.reloadData(keepingRows:_:).
  static func showSheet(_ root: UIViewController) {
    let navigation = UINavigationController(rootViewController: root)
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    UIViewController.topViewController().present(navigation, animated: true)
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
  private func cycleShiftStep() {
    NoGps.cycleShiftStep()
    refresh()
  }

  @objc
  private func shiftForward() {
    shift(forward: true)
  }

  @objc
  private func shiftBack() {
    shift(forward: false)
  }

  /// Moves the position along the road when it lags behind the car or has run ahead of it.
  private func shift(forward: Bool) {
    let status = NoGps.status()
    let distanceM = forward ? status.shiftStepM : -status.shiftStepM
    // The position stands at a crossing, it is moved that way after the car passes it.
    if forward ? status.shiftForwardBlocked : status.shiftBackBlocked {
      Toast.show(withText: L("nogps_shift_at_turn"))
      return
    }
    let applied = NoGps.shiftPosition(Double(distanceM))
    let after = NoGps.status()
    if applied == 0, forward ? after.shiftForwardBlocked : after.shiftBackBlocked {
      Toast.show(withText: L("nogps_shift_at_turn"))
    } else if Int(abs(applied).rounded()) < abs(distanceM) {
      // The position stops at the closest turn, so the user has to know when it was moved by less.
      let appliedM = Int(abs(applied).rounded())
      Toast.show(withText: appliedM == 0 ? L("nogps_shift_failed") : String(format: L("nogps_shift_limited"), appliedM))
    }
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
