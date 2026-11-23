/// About NonGPS Maps: what the app is, which build it is and where it comes from. The about screen of Organic Maps,
/// the project it is based on, is AboutController.
final class AboutNoGpsController: MWMViewController {
  private enum Constants {
    static let logoSize: CGFloat = 64
    static let versionSpacing: CGFloat = 4
    static let stackSpacing: CGFloat = 15
    static let stackInset: CGFloat = 20
    static let hintSpacing: CGFloat = 2
    static let osmCopyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
  }

  private let scrollView = UIScrollView()
  private let stackView = UIStackView()
  private let logoImageView = UIImageView()
  private let appNameLabel = UILabel()
  private let versionLabel = UILabel()
  private let upstreamVersionLabel = UILabel()
  private let headlineLabel = UILabel()
  private let globeView = GlobeSceneView()
  private let globeHintLabel = UILabel()
  private let globeCountLabel = UILabel()
  private let globeJammedLabel = UILabel()
  private let descriptionLabel = UILabel()
  /// A text view, not a label: both names of the credit are links of their own.
  private let mapDataTextView = UITextView()
  private let linksView = ButtonsStackView()

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    setupViews()
    arrangeViews()
    layoutViews()
  }
}

// MARK: - Private

private extension AboutNoGpsController {
  func setupViews() {
    title = L("nogps_about_title")
    view.setStyle(.pressBackground)

    scrollView.delaysContentTouches = false
    scrollView.contentInset = UIEdgeInsets(top: Constants.stackInset, left: 0, bottom: Constants.stackInset, right: 0)

    stackView.axis = .vertical
    stackView.distribution = .fill
    stackView.alignment = .center
    stackView.spacing = Constants.stackSpacing

    logoImageView.contentMode = .scaleAspectFit
    logoImageView.image = UIImage(named: "logo")

    // NonGPS Maps and its version first, the Organic Maps it is based on below with less accent.
    appNameLabel.setFontStyle(.bold22, color: .blackPrimary)
    appNameLabel.text = "NonGPS Maps"
    appNameLabel.textAlignment = .center

    // Strong left-to-right unicode direction characters keep the versions readable in RTL languages.
    versionLabel.setFontStyle(.regular16, color: .blackPrimary)
    versionLabel.text = String(format: L("nogps_version"), "\u{2066}\(AppInfo.shared().appVersion)\u{2069}")
    versionLabel.textAlignment = .center
    versionLabel.numberOfLines = 0
    versionLabel.isUserInteractionEnabled = true
    versionLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(versionTapped)))

    upstreamVersionLabel.setFontStyle(.regular13, color: .blackSecondary)
    upstreamVersionLabel.text = String(format: L("nogps_based_on"),
                                       "\u{2066}\(AppInfo.shared().upstreamVersion)\u{2069}")
    upstreamVersionLabel.textAlignment = .center
    upstreamVersionLabel.numberOfLines = 0
    upstreamVersionLabel.isUserInteractionEnabled = true
    upstreamVersionLabel
      .addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(upstreamVersionTapped)))

    headlineLabel.setFontStyle(.semibold18, color: .blackPrimary)
    headlineLabel.text = L("nogps_about_headline")
    headlineLabel.textAlignment = .center
    headlineLabel.numberOfLines = 0

    setupGlobe()

    descriptionLabel.setFontStyle(.regular16, color: .blackPrimary)
    descriptionLabel.text = L("nogps_about_description")
    descriptionLabel.numberOfLines = 0

    setupMapData()

    linksView.addButton(title: L("nogps_source_code")) {
      UIApplication.shared.open(NoGpsLinks.sourceCode)
    }
    linksView.addButton(title: L("nogps_box_buy")) {
      UIApplication.shared.open(NoGpsLinks.shop)
    }
    linksView.addButton(title: L("report_a_bug")) {
      MailComposer.sendBugReportWith(title: "NonGPS Maps Bug Report")
    }
  }

  /// The Earth and the GPS constellation the finger can spin, with what is left of them under it.
  func setupGlobe() {
    globeHintLabel.setFontStyle(.regular13, color: .blackSecondary)
    globeHintLabel.text = L("nogps_about_globe_hint")
    globeCountLabel.setFontStyle(.semibold14, color: .blackPrimary)
    globeJammedLabel.setFontStyle(.regular13, color: .blackSecondary)
    globeJammedLabel.text = L("nogps_about_globe_jammed")
    for label in [globeHintLabel, globeCountLabel, globeJammedLabel] {
      label.textAlignment = .center
      label.numberOfLines = 0
    }
    globeView.onSatellitesChanged = { [weak self] on, total in
      self?.globeCountLabel.text = String(format: L("nogps_about_globe_sats"), on, total)
    }
  }

  /// The map data is credited with clickable names, as Organic Maps and OpenStreetMap ask.
  func setupMapData() {
    mapDataTextView.isEditable = false
    mapDataTextView.isScrollEnabled = false
    mapDataTextView.backgroundColor = .clear
    mapDataTextView.textContainerInset = .zero
    mapDataTextView.textContainer.lineFragmentPadding = 0
    mapDataTextView.linkTextAttributes = [.foregroundColor: UIColor.linkBlue]

    let text = NSMutableAttributedString(string: L("nogps_map_data"),
                                         attributes: [.font: UIFont.regular16.dynamic,
                                                      .foregroundColor: UIColor.blackPrimaryText])
    link(in: text, "OpenStreetMap", Constants.osmCopyrightURL)
    link(in: text, "Organic Maps", NoGpsLinks.organicMaps)
    mapDataTextView.attributedText = text
  }

  func link(in text: NSMutableAttributedString, _ name: String, _ url: URL) {
    let range = text.mutableString.range(of: name)
    guard range.location != NSNotFound else { return }
    text.addAttribute(.link, value: url, range: range)
  }

  func arrangeViews() {
    view.addSubview(scrollView)
    scrollView.addSubview(stackView)
    stackView.addArrangedSubview(logoImageView)
    stackView.addArrangedSubview(appNameLabel)
    stackView.addArrangedSubview(versionLabel)
    stackView.addArrangedSubview(upstreamVersionLabel)
    stackView.setCustomSpacing(Constants.versionSpacing, after: appNameLabel)
    stackView.setCustomSpacing(Constants.versionSpacing, after: versionLabel)
    stackView.addArrangedSubview(headlineLabel)
    stackView.addArrangedSubview(globeView)
    stackView.addArrangedSubview(globeHintLabel)
    stackView.addArrangedSubview(globeCountLabel)
    stackView.addArrangedSubview(globeJammedLabel)
    stackView.setCustomSpacing(Constants.hintSpacing, after: globeView)
    stackView.setCustomSpacing(Constants.hintSpacing, after: globeHintLabel)
    stackView.addArrangedSubview(descriptionLabel)
    stackView.addArrangedSubview(mapDataTextView)
    stackView.addArrangedSubview(linksView)
  }

  func layoutViews() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stackView.translatesAutoresizingMaskIntoConstraints = false
    logoImageView.translatesAutoresizingMaskIntoConstraints = false
    headlineLabel.translatesAutoresizingMaskIntoConstraints = false
    globeView.translatesAutoresizingMaskIntoConstraints = false
    globeHintLabel.translatesAutoresizingMaskIntoConstraints = false
    globeCountLabel.translatesAutoresizingMaskIntoConstraints = false
    globeJammedLabel.translatesAutoresizingMaskIntoConstraints = false
    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    mapDataTextView.translatesAutoresizingMaskIntoConstraints = false
    linksView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                                         constant: Constants.stackInset),
      stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                                          constant: -Constants.stackInset),
      stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

      logoImageView.heightAnchor.constraint(equalToConstant: Constants.logoSize),
      logoImageView.widthAnchor.constraint(equalTo: logoImageView.heightAnchor),

      headlineLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor),
      globeView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
      globeView.heightAnchor.constraint(equalToConstant: GlobeScene.sceneHeightPt),
      globeHintLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor),
      globeCountLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor),
      globeJammedLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor),
      descriptionLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor),
      mapDataTextView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
      linksView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
    ])
  }

  func copyToClipboard(_ content: String) {
    UIPasteboard.general.string = content
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    Toast.show(withText: String(format: L("copied_to_clipboard"), content), alignment: .bottom, pinToSafeArea: false)
  }
}

// MARK: - Actions

private extension AboutNoGpsController {
  /// With the commit of the build and the Organic Maps version: the line tells which build was tested.
  @objc func versionTapped() {
    copyToClipboard("NonGPS Maps \u{2066}\(AppInfo.shared().fullVersion)\u{2069}")
  }

  @objc func upstreamVersionTapped() {
    UIApplication.shared.open(NoGpsLinks.organicMaps)
  }
}
