/// A modal card over the app while the sensor box takes a new firmware: the stage, the progress and, at the end, the
/// result. It can't be dismissed while the update runs. It reads everything from the status.
final class NoGpsFirmwareUpdateAlert: UIViewController {
  private enum Constants {
    static let refreshInterval: TimeInterval = 0.5
    static let cardWidth = CGFloat(300)
    static let padding = CGFloat(20)
  }

  private let stageLabel = UILabel()
  private let progressView = UIProgressView(progressViewStyle: .default)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let noteLabel = UILabel()
  private let button = UIButton(type: .system)
  private var timer: Timer?

  /// Opens the card if the update runs and it isn't open yet. A start that the core refused leaves nothing to show.
  static func show() {
    guard !isShown, NoGpsBoxPage.isFirmwareUpdating(NoGps.status()) else { return }
    UIViewController.topViewController().present(NoGpsFirmwareUpdateAlert(), animated: true)
  }

  static var isShown: Bool {
    UIViewController.topViewController() is NoGpsFirmwareUpdateAlert
  }

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
    isModalInPresentation = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

    let title = UILabel()
    title.text = L("nogps_firmware_title")
    title.font = .preferredFont(forTextStyle: .headline)
    title.textAlignment = .center
    title.numberOfLines = 0

    stageLabel.font = .preferredFont(forTextStyle: .body)
    stageLabel.textAlignment = .center
    stageLabel.numberOfLines = 0

    spinner.hidesWhenStopped = true

    noteLabel.text = L("nogps_firmware_keep_still")
    noteLabel.font = .preferredFont(forTextStyle: .footnote)
    noteLabel.textColor = .secondaryLabel
    noteLabel.textAlignment = .center
    noteLabel.numberOfLines = 0

    button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [title, stageLabel, progressView, spinner, noteLabel, button])
    stack.axis = .vertical
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false

    let card = UIView()
    card.backgroundColor = .secondarySystemGroupedBackground
    card.layer.cornerRadius = 14
    card.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    view.addSubview(card)
    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.widthAnchor.constraint(equalToConstant: Constants.cardWidth),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Constants.padding),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Constants.padding),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Constants.padding),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Constants.padding),
    ])
    refresh()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refresh()
    let timer = Timer(timeInterval: Constants.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    timer?.invalidate()
    timer = nil
  }

  @objc
  private func buttonTapped() {
    if NoGpsBoxPage.canCancelFirmware(NoGps.status()) {
      // The result takes the place of the card in a moment.
      NoGps.cancelFirmwareUpdate()
      refresh()
    } else if !NoGpsBoxPage.isFirmwareUpdating(NoGps.status()) {
      dismiss(animated: true)
    }
  }

  private func refresh() {
    let status = NoGps.status()
    let updating = NoGpsBoxPage.isFirmwareUpdating(status)
    switch status.firmwareUpdate {
    case .done:
      stageLabel.text = String(format: L("nogps_firmware_done"), status.boxFirmware)
    case .failed:
      stageLabel.text = String(format: L("nogps_firmware_failed"),
                               NoGpsBoxPage.firmwareErrorText(status.firmwareUpdateError))
    case .none:
      // Nothing runs and nothing ended.
      dismiss(animated: true)
      timer?.invalidate()
      return
    default:
      stageLabel.text = NoGpsBoxPage.firmwareText(status).capitalizedFirst
    }
    let sending = status.firmwareUpdate == .sending
    progressView.isHidden = !sending
    progressView.progress = Float(status.firmwareUpdateProgress) / 100
    updating && !sending ? spinner.startAnimating() : spinner.stopAnimating()
    noteLabel.isHidden = !updating
    // Cancel only while the box can still stop it; verifying and restarting have no button.
    let cancel = NoGpsBoxPage.canCancelFirmware(status)
    button.isHidden = updating && !cancel
    button.setTitle(cancel ? L("cancel") : L("ok"), for: .normal)
  }
}

private extension String {
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
