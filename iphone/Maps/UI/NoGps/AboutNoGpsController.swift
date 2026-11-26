/// About NonGPS Maps: what the app is, which build it is and where it comes from. The about screen of Organic Maps,
/// the project it is based on, is AboutController.
final class AboutNoGpsController: MWMViewController {
  private enum Constants {
    static let logoSize: CGFloat = 64
    static let versionSpacing: CGFloat = 4
    static let globeMinHeight: CGFloat = 200
    static let stackSpacing: CGFloat = 15
    static let stackInset: CGFloat = 20
    static let actionsSpacing: CGFloat = 12
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
  /// A text view, not a label: both names of the credit are links of their own.
  private let mapDataTextView = UITextView()
  /// Buy the box, accented, and the source code under it: the full width of the text above.
  private let actionsView = UIStackView()
  /// The documents and the bug report, as on About Organic Maps.
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

    setupMapData()

    actionsView.axis = .vertical
    actionsView.spacing = Constants.actionsSpacing
    actionsView.distribution = .fill
    actionsView.alignment = .fill
    actionsView.addArrangedSubview(NoGpsButton.filled(title: L("nogps_box_buy")) {
      UIApplication.shared.open(NoGpsLinks.shop)
    })
    actionsView.addArrangedSubview(NoGpsButton.outlined(title: L("nogps_source_code"),
                                                        icon: UIImage(named: "ic_social_media_github"),
                                                        background: .clear) {
        UIApplication.shared.open(NoGpsLinks.sourceCode)
      })
    linksView.addButton(title: L("report_a_bug")) {
      MailComposer.sendBugReportWith(title: "NonGPS Maps Bug Report")
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
    stackView.addArrangedSubview(mapDataTextView)
    stackView.addArrangedSubview(actionsView)
    stackView.addArrangedSubview(linksView)
  }

  func layoutViews() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stackView.translatesAutoresizingMaskIntoConstraints = false
    logoImageView.translatesAutoresizingMaskIntoConstraints = false
    headlineLabel.translatesAutoresizingMaskIntoConstraints = false
    globeView.translatesAutoresizingMaskIntoConstraints = false
    mapDataTextView.translatesAutoresizingMaskIntoConstraints = false
    actionsView.translatesAutoresizingMaskIntoConstraints = false
    linksView.translatesAutoresizingMaskIntoConstraints = false

    // The globe is what grows, up to the screen; a taller page gives way and scrolls.
    globeView.setContentHuggingPriority(.init(1), for: .vertical)
    let fitsScreen = stackView.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor,
                                                       constant: -2 * Constants.stackInset)
    fitsScreen.priority = .defaultHigh

    NSLayoutConstraint.activate([
      fitsScreen,
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
      // Past the insets of the text: the orbits set the size of the Earth, so every point of width makes it larger.
      globeView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      globeView.heightAnchor.constraint(lessThanOrEqualToConstant: GlobeScene.sceneHeightPt),
      globeView.heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.globeMinHeight),
      mapDataTextView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
      actionsView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
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
