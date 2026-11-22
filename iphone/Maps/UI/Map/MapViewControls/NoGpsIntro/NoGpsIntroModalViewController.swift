/// The first step of the intro of the first start: what the app is and that it needs the sensor box. The secondary
/// buttons open the shop and the video and leave the modal open; the accent button closes it and the balloons follow,
/// see NoGpsIntroController.
final class NoGpsIntroModalViewController: UIViewController {
  private enum Constants {
    static let cardMaxWidth = CGFloat(380)
    static let cardRadius = CGFloat(16)
    static let cardInset = CGFloat(20)
    static let cardPadding = CGFloat(20)
    static let dimAlpha = CGFloat(0.5)
    static let spacing = CGFloat(10)
    static let buttonHeight = CGFloat(44)
    static let buttonPadding = CGFloat(10)
    static let buttonRadius = CGFloat(10)
  }

  private let onClose: () -> Void
  private let card = UIView()
  private let scroll = UIScrollView()
  private let stack = UIStackView()

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(Constants.dimAlpha)
    setupCard()
    setupContent()
  }

  private func setupCard() {
    card.backgroundColor = .systemBackground
    card.layer.cornerRadius = Constants.cardRadius
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(scroll)
    stack.axis = .vertical
    stack.spacing = Constants.spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    let width = card.widthAnchor.constraint(equalToConstant: Constants.cardMaxWidth)
    width.priority = .defaultHigh
    // The card wraps its content, and the scroll view takes over when it doesn't fit on the screen.
    let fit = scroll.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor)
    fit.priority = .defaultHigh
    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      width,
      card.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                                    constant: Constants.cardInset),
      card.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                                     constant: -Constants.cardInset),
      card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                                constant: Constants.cardInset),
      card.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor,
                                   constant: -Constants.cardInset),
      scroll.topAnchor.constraint(equalTo: card.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      fit,
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Constants.cardPadding),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Constants.cardPadding),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor,
                                     constant: Constants.cardPadding),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor,
                                      constant: -Constants.cardPadding),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor,
                                   constant: -2 * Constants.cardPadding),
    ])
  }

  private func setupContent() {
    let title = UILabel()
    title.text = L("nogps_intro_title")
    title.font = .systemFont(ofSize: 19, weight: .semibold)
    title.textColor = .label
    title.numberOfLines = 0
    // Nobody reads a wall of text: the detail belongs to the video and the help, this stays short and quiet.
    let text = UILabel()
    text.text = L("nogps_intro_text")
    text.font = .systemFont(ofSize: 13)
    text.textColor = .secondaryLabel
    text.numberOfLines = 0
    stack.addArrangedSubview(title)
    stack.addArrangedSubview(text)
    // The shop and the video are secondary and do not close the modal: the user comes back to it.
    stack.addArrangedSubview(button(L("nogps_box_buy"), filled: false, action: #selector(buyTapped)))
    stack.addArrangedSubview(button(L("nogps_intro_video"), filled: false, action: #selector(videoTapped)))
    stack.addArrangedSubview(button(L("nogps_intro_understand"), filled: true,
                                    action: #selector(understandTapped)))
  }

  /// The filled button is the only way out of the modal, the rest are quiet.
  private func button(_ title: String, filled: Bool, action: Selector) -> UIButton {
    var config = UIButton.Configuration.filled()
    config.title = title
    config.titleAlignment = .center
    config.baseBackgroundColor = filled ? .linkBlue : .blackOpaque
    config.baseForegroundColor = filled ? .white : .linkBlue
    config.cornerStyle = .fixed
    config.background.cornerRadius = Constants.buttonRadius
    config.contentInsets = NSDirectionalEdgeInsets(top: Constants.buttonPadding,
                                                   leading: Constants.buttonPadding,
                                                   bottom: Constants.buttonPadding,
                                                   trailing: Constants.buttonPadding)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = filled ? .systemFont(ofSize: 16, weight: .semibold) : .systemFont(ofSize: 15)
      return attributes
    }
    let button = UIButton(configuration: config)
    button.addTarget(self, action: action, for: .touchUpInside)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.buttonHeight).isActive = true
    return button
  }

  @objc
  private func buyTapped() {
    UIApplication.shared.open(NoGpsLinks.shop)
  }

  @objc
  private func videoTapped() {
    UIApplication.shared.open(NoGpsLinks.video)
  }

  @objc
  private func understandTapped() {
    dismiss(animated: true) { [onClose] in onClose() }
  }
}
