/// The first step of the intro of the first start: what the app is and that it needs the sensor box. The buttons open
/// the shop and the video and leave the modal open; the checkbox closes it and the balloons follow, see
/// NoGpsIntroController.
final class NoGpsIntroModalViewController: UIViewController {
  private enum Constants {
    static let cardMaxWidth = CGFloat(380)
    static let cardRadius = CGFloat(16)
    static let cardInset = CGFloat(20)
    static let cardPadding = CGFloat(20)
    static let dimAlpha = CGFloat(0.5)
    static let spacing = CGFloat(12)
    static let buttonHeight = CGFloat(44)
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
    title.font = .boldSystemFont(ofSize: 22)
    title.textColor = .label
    title.numberOfLines = 0
    let text = UILabel()
    text.text = L("nogps_intro_text")
    text.font = .systemFont(ofSize: 15)
    text.textColor = .label
    text.numberOfLines = 0
    stack.addArrangedSubview(title)
    stack.addArrangedSubview(text)
    // The buttons do not close the modal: the user comes back to it from the shop or the video.
    stack.addArrangedSubview(button(L("nogps_box_buy"), filled: true, action: #selector(buyTapped)))
    stack.addArrangedSubview(button(L("nogps_intro_video"), filled: false, action: #selector(videoTapped)))
    stack.addArrangedSubview(makeCheckbox())
  }

  private func button(_ title: String, filled: Bool, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
    button.layer.cornerRadius = Constants.buttonRadius
    if filled {
      button.backgroundColor = .linkBlue
      button.setTitleColor(.white, for: .normal)
    } else {
      button.layer.borderWidth = 1
      button.layer.borderColor = UIColor.linkBlue.cgColor
      button.setTitleColor(.linkBlue, for: .normal)
    }
    button.addTarget(self, action: action, for: .touchUpInside)
    button.heightAnchor.constraint(equalToConstant: Constants.buttonHeight).isActive = true
    return button
  }

  /// A checkmark and the text beside it: the only way out of the modal.
  private func makeCheckbox() -> UIButton {
    let checkbox = UIButton(type: .system)
    checkbox.setImage(UIImage(systemName: "square"), for: .normal)
    checkbox.setTitle(" " + L("nogps_intro_understand"), for: .normal)
    checkbox.titleLabel?.font = .systemFont(ofSize: 16)
    checkbox.titleLabel?.numberOfLines = 0
    checkbox.contentHorizontalAlignment = .leading
    checkbox.tintColor = .linkBlue
    checkbox.setTitleColor(.label, for: .normal)
    checkbox.addTarget(self, action: #selector(understandTapped(_:)), for: .touchUpInside)
    return checkbox
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
  private func understandTapped(_ sender: UIButton) {
    sender.setImage(UIImage(systemName: "checkmark.square.fill"), for: .normal)
    dismiss(animated: true) { [onClose] in onClose() }
  }
}
