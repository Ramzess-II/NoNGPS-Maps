import AVFoundation

/// The flags of the test drives by day, newest first, see NoGpsFlags. The tester ticks some and sends them by email
/// with the logs of their days. A tap on a row ticks it, the play button plays the voice note of a flag and a tap on the
/// screenshot opens it full screen.
final class NoGpsFlagsViewController: MWMTableViewController, AVAudioPlayerDelegate {
  private enum Constants {
    static let cellId = "flag"
    static let thumbnailSize = CGSize(width: 48, height: 64)
    static let emptyTop: CGFloat = 20
  }

  private var days = [[NoGpsFlag]]()
  private var selected = Set<String>()
  private var thumbnails = [String: UIImage]()
  private var player: AVAudioPlayer?
  private var playing = ""

  init() {
    super.init(style: .grouped)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_flags_send_title")
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("nogps_flags_send"), style: .done, target: self,
                                                        action: #selector(send))
    tableView.register(NoGpsFlagCell.self, forCellReuseIdentifier: Constants.cellId)
    reload()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopPlaying()
  }

  private func reload() {
    // After the flags still being saved.
    let flags = NoGpsFlags.queue.sync { NoGpsFlags.load() }
    days = []
    for flag in flags {
      if let last = days.last?.last, NoGpsFlags.logDay(of: last.name) == NoGpsFlags.logDay(of: flag.name) {
        days[days.count - 1].append(flag)
      } else {
        days.append([flag])
      }
    }
    selected.formIntersection(flags.map(\.name))
    if flags.isEmpty {
      let label = UILabel()
      label.text = L("nogps_flags_empty")
      label.numberOfLines = 0
      label.textColor = .blackSecondaryText
      label.translatesAutoresizingMaskIntoConstraints = false
      let background = UIView()
      background.addSubview(label)
      NSLayoutConstraint.activate([
        label.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: Constants.emptyTop),
        label.leadingAnchor.constraint(equalTo: background.readableContentGuide.leadingAnchor),
        label.trailingAnchor.constraint(equalTo: background.readableContentGuide.trailingAnchor),
      ])
      tableView.backgroundView = background
    } else {
      tableView.backgroundView = nil
    }
    tableView.reloadData()
    navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
  }

  private func thumbnail(_ name: String) -> UIImage? {
    if let image = thumbnails[name] {
      return image
    }
    let image = UIImage(contentsOfFile: NoGpsFlags.url(name, NoGpsFlags.Constants.png).path)?
      .preparingThumbnail(of: Constants.thumbnailSize)
    thumbnails[name] = image
    return image
  }

  // MARK: - Table

  override func numberOfSections(in _: UITableView) -> Int {
    days.count
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    days[section].count
  }

  override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
    NoGpsFlags.mailDay(of: days[section][0].name)
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath) as! NoGpsFlagCell
    let flag = days[indexPath.section][indexPath.row]
    var details = [String]()
    if flag.voiceS > 0 {
      details.append(String(format: L("nogps_flag_voice"), flag.voiceS))
    }
    if flag.sent {
      details.append(L("nogps_flag_sent"))
    }
    let thumbnail = thumbnail(flag.name)
    cell.configure(title: "FLAG \(flag.number) · \(NoGpsFlags.time(of: flag.name))",
                   details: details.isEmpty ? nil : details.joined(separator: " · "),
                   checked: selected.contains(flag.name),
                   thumbnail: thumbnail,
                   hasVoice: flag.voiceS > 0,
                   isPlaying: playing == flag.name,
                   onPreview: thumbnail == nil ? nil : { [weak self] in self?.showScreenshot(flag.name) },
                   onPlay: { [weak self] in self?.play(flag.name) })
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    toggle(days[indexPath.section][indexPath.row].name)
  }

  private func showScreenshot(_ name: String) {
    guard let image = UIImage(contentsOfFile: NoGpsFlags.url(name, NoGpsFlags.Constants.png).path) else { return }
    let controller = NoGpsFlagScreenshotViewController(image: image)
    controller.modalPresentationStyle = .fullScreen
    present(controller, animated: true)
  }

  private func toggle(_ name: String) {
    if selected.remove(name) == nil {
      selected.insert(name)
    }
    tableView.reloadData()
    navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
  }

  /// A second tap stops the voice.
  private func play(_ name: String) {
    let again = playing == name
    stopPlaying()
    guard !again else { return }
    do {
      let player = try AVAudioPlayer(contentsOf: NoGpsFlags.url(name, NoGpsFlags.Constants.voice))
      player.delegate = self
      player.play()
      self.player = player
      playing = name
    } catch {
      LOG(.error, "Failed to play the voice of flag \(name): \(error)")
    }
    tableView.reloadData()
  }

  private func stopPlaying() {
    player?.stop()
    player = nil
    playing = ""
    tableView.reloadData()
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
    guard player === self.player else { return }
    stopPlaying()
  }

  // MARK: - Send

  @objc
  private func send() {
    let flags = days.joined().filter { selected.contains($0.name) }
    guard !flags.isEmpty else { return }
    let logDays = Set(flags.map { NoGpsFlags.logDay(of: $0.name) })
    UIApplication.shared.showLoadingOverlay {
      let logs = Logger.zipLogFiles { !NoGpsFlags.logFiles([$0], days: logDays).isEmpty }
      let files = NoGpsFlags.attachments(flags) + [logs].compactMap { $0 }
      UIApplication.shared.hideLoadingOverlay {
        self.confirmSize(files) { self.compose(flags, files) }
      }
    }
  }

  /// A mail server may refuse big attachments.
  private func confirmSize(_ files: [URL], then send: @escaping () -> Void) {
    let size = files.reduce(UInt64(0)) { total, file in
      total + UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    guard size > UInt64(NoGpsFlags.Constants.mailMaxMB) * 1_000_000 else {
      send()
      return
    }
    let alert = UIAlertController(title: nil,
                                  message: String(format: L("nogps_flags_too_big"), formattedSize(size),
                                                  NoGpsFlags.Constants.mailMaxMB),
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("nogps_flags_send"), style: .default) { _ in send() })
    present(alert, animated: true)
  }

  private func compose(_ flags: [NoGpsFlag], _ files: [URL]) {
    let appInfo = AppInfo.shared()
    let names = flags.map(\.name)
    MailComposer.sendEmail(subject: NoGpsFlags.mailSubject(version: "\(appInfo.bundleVersion)-\(appInfo.buildNumber) iOS",
                                                           flags: flags),
                           body: NoGpsFlags.mailBody(flags),
                           toRecipients: [AppConstants.contactEmail],
                           attachments: files) { [weak self] in
      NoGpsFlags.queue.async {
        for name in names {
          NoGpsFlags.update(name) { $0.sent = true }
        }
        DispatchQueue.main.async { self?.reload() }
      }
    }
  }
}

/// A row of the list: check, screenshot, texts and the play button. The table toggles the check on a tap on the row.
private final class NoGpsFlagCell: UITableViewCell {
  private enum Constants {
    static let thumbnailSize = CGSize(width: 48, height: 64)
    static let checkSize: CGFloat = 24
    static let playSize: CGFloat = 44
    static let spacing: CGFloat = 12
    static let margin: CGFloat = 16
  }

  private let check = UIImageView()
  private let thumbnailButton = UIButton(type: .custom)
  private let titleLabel = UILabel()
  private let detailsLabel = UILabel()
  private let playButton = UIButton(type: .system)
  private var onPreview: (() -> Void)?
  private var onPlay: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    check.tintColor = .linkBlue
    check.contentMode = .scaleAspectFit
    thumbnailButton.imageView?.contentMode = .scaleAspectFit
    thumbnailButton.accessibilityLabel = L("nogps_flag_screenshot")
    thumbnailButton.addAction(UIAction { [weak self] _ in self?.onPreview?() }, for: .touchUpInside)
    titleLabel.font = .regular17
    titleLabel.textColor = .blackPrimaryText
    detailsLabel.font = .regular14
    detailsLabel.textColor = .blackSecondaryText
    playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)

    let texts = UIStackView(arrangedSubviews: [titleLabel, detailsLabel])
    texts.axis = .vertical
    let row = UIStackView(arrangedSubviews: [check, thumbnailButton, texts, playButton])
    row.alignment = .center
    row.spacing = Constants.spacing
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      check.widthAnchor.constraint(equalToConstant: Constants.checkSize),
      check.heightAnchor.constraint(equalToConstant: Constants.checkSize),
      thumbnailButton.widthAnchor.constraint(equalToConstant: Constants.thumbnailSize.width),
      thumbnailButton.heightAnchor.constraint(equalToConstant: Constants.thumbnailSize.height),
      playButton.widthAnchor.constraint(equalToConstant: Constants.playSize),
      playButton.heightAnchor.constraint(equalToConstant: Constants.playSize),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
      row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Constants.margin),
      row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Constants.margin / 2),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String, details: String?, checked: Bool, thumbnail: UIImage?, hasVoice: Bool,
                 isPlaying: Bool, onPreview: (() -> Void)?, onPlay: @escaping () -> Void) {
    titleLabel.text = title
    detailsLabel.text = details
    detailsLabel.isHidden = details == nil
    check.image = UIImage(systemName: checked ? "checkmark.circle.fill" : "circle")
    thumbnailButton.setImage(thumbnail, for: .normal)
    thumbnailButton.isUserInteractionEnabled = thumbnail != nil
    thumbnailButton.isAccessibilityElement = thumbnail != nil
    playButton.isHidden = !hasVoice
    playButton.setImage(UIImage(systemName: isPlaying ? "stop.fill" : "play.fill"), for: .normal)
    playButton.accessibilityLabel = L(isPlaying ? "nogps_flag_stop" : "nogps_flag_play")
    self.onPreview = onPreview
    self.onPlay = onPlay
  }
}

/// A screenshot of a flag, fit to the screen on a dark background. A swipe down or the close button dismisses it.
private final class NoGpsFlagScreenshotViewController: UIViewController {
  private let image: UIImage

  init(image: UIImage) {
    self.image = image
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.accessibilityLabel = L("nogps_flag_screenshot")
    imageView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(imageView)
    let close = UIButton(type: .close)
    close.accessibilityLabel = L("close")
    close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    close.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(close)
    let swipe = UISwipeGestureRecognizer(target: self, action: #selector(dismissByGesture))
    swipe.direction = .down
    view.addGestureRecognizer(swipe)
    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      imageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
    ])
  }

  @objc
  private func dismissByGesture() {
    dismiss(animated: true)
  }
}
