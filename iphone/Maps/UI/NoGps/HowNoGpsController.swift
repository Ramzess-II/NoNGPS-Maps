/// How NonGPS works: what the app is and what the three panels of the map do, with a button that plays the intro of
/// the first start again. The intro itself is NoGpsIntroController; the about screen of the app is
/// AboutNoGpsController.
final class HowNoGpsController: MWMViewController {
  private enum Constants {
    static let stackSpacing: CGFloat = 12
    static let groupSpacing: CGFloat = 24
    static let stackInset: CGFloat = 20
  }

  private let scrollView = UIScrollView()
  private let stackView = UIStackView()
  private let leadLabel = UILabel()
  private let panelsLabel = UILabel()
  private let bottomLabel = UILabel()
  private let rightLabel = UILabel()
  private let leftLabel = UILabel()
  private let introAgainView = ButtonsStackView()

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    setupViews()
    arrangeViews()
    layoutViews()
  }
}

// MARK: - Private

private extension HowNoGpsController {
  func setupViews() {
    title = L("nogps_how_title")
    view.setStyle(.pressBackground)

    scrollView.delaysContentTouches = false
    scrollView.contentInset = UIEdgeInsets(top: Constants.stackInset, left: 0, bottom: Constants.stackInset, right: 0)

    stackView.axis = .vertical
    stackView.distribution = .fill
    stackView.alignment = .fill
    stackView.spacing = Constants.stackSpacing

    // The same text the modal of the intro shows.
    setupBody(leadLabel, L("nogps_intro_text"))

    panelsLabel.setFontStyle(.semibold18, color: .blackPrimary)
    panelsLabel.text = L("nogps_how_panels")
    panelsLabel.numberOfLines = 0

    setupBody(bottomLabel, L("nogps_how_bottom"))
    // The slide of the zoom buttons is an iOS gesture only, as in the balloon of the right panel.
    setupBody(rightLabel, L("nogps_how_right") + " " + L("nogps_intro_right_swipe"))
    setupBody(leftLabel, L("nogps_how_left"))

    introAgainView.addButton(title: L("nogps_how_intro_again")) { [weak self] in
      self?.playIntro()
    }
  }

  func setupBody(_ label: UILabel, _ text: String) {
    label.setFontStyle(.regular16, color: .blackPrimary)
    label.text = text
    label.numberOfLines = 0
  }

  func arrangeViews() {
    view.addSubview(scrollView)
    scrollView.addSubview(stackView)
    stackView.addArrangedSubview(leadLabel)
    stackView.addArrangedSubview(panelsLabel)
    stackView.addArrangedSubview(bottomLabel)
    stackView.addArrangedSubview(rightLabel)
    stackView.addArrangedSubview(leftLabel)
    stackView.addArrangedSubview(introAgainView)
    stackView.setCustomSpacing(Constants.groupSpacing, after: leadLabel)
    stackView.setCustomSpacing(Constants.groupSpacing, after: leftLabel)
  }

  func layoutViews() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stackView.translatesAutoresizingMaskIntoConstraints = false

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
    ])
  }

  /// Back to the map, where the intro runs as it does on the first start.
  func playIntro() {
    guard let map = MapViewController.shared() else { return }
    navigationController?.popToViewController(map, animated: true)
    NoGpsIntroController.play(in: map)
  }
}
