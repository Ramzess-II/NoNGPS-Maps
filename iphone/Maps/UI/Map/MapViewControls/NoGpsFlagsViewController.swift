import AVFoundation

/// The flags of the test drives by day, newest first, see NoGpsFlags. The tester ticks some and sends them by email
/// with the logs of their days. A tap plays the voice note of a flag.
final class NoGpsFlagsViewController: MWMTableViewController {
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
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Constants.cellId)
    reload()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    player?.stop()
    player = nil
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
    let cell = tableView.dequeueReusableCell(withIdentifier: Constants.cellId, for: indexPath)
    let flag = days[indexPath.section][indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = "FLAG \(flag.number) · \(NoGpsFlags.time(of: flag.name))"
    var details = [String]()
    if flag.voiceS > 0 {
      details.append(String(format: L("nogps_flag_voice"), flag.voiceS))
    }
    if flag.sent {
      details.append(L("nogps_flag_sent"))
    }
    content.secondaryText = details.isEmpty ? nil : details.joined(separator: " · ")
    content.secondaryTextProperties.color = .blackSecondaryText
    content.image = thumbnail(flag.name)
    content.imageProperties.maximumSize = Constants.thumbnailSize
    content.imageProperties.reservedLayoutSize = Constants.thumbnailSize
    cell.contentConfiguration = content

    let check = UIButton(type: .system)
    check.setImage(UIImage(systemName: selected.contains(flag.name) ? "checkmark.circle.fill" : "circle"), for: .normal)
    check.sizeToFit()
    check.addAction(UIAction { [weak self] _ in self?.toggle(flag.name) }, for: .touchUpInside)
    cell.accessoryView = check
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let flag = days[indexPath.section][indexPath.row]
    if flag.voiceS > 0 {
      play(flag.name)
    } else {
      toggle(flag.name)
    }
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
    let again = player?.isPlaying == true && playing == name
    player?.stop()
    player = nil
    guard !again else { return }
    do {
      let player = try AVAudioPlayer(contentsOf: NoGpsFlags.url(name, NoGpsFlags.Constants.voice))
      player.play()
      self.player = player
      playing = name
    } catch {
      LOG(.error, "Failed to play the voice of flag \(name): \(error)")
    }
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
