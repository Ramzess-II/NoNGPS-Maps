final class TransportTransitStepsView: SolidTouchView {
  private enum Constants {
    static let contentInsets = UIEdgeInsets(top: 8, left: 0, bottom: -8, right: 0)
  }

  private var stepsCollectionView: TransportTransitStepsCollectionView!
  private var stepsCollectionViewHeight: NSLayoutConstraint!

  init() {
    super.init(frame: .zero)
    setupViews()
    layout()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
  }

  private func setupViews() {
    let layout = TransportTransitFlowLayout()
    stepsCollectionView = TransportTransitStepsCollectionView(layout: layout)
    stepsCollectionView.backgroundColor = .clear
  }

  private func layout() {
    addSubview(stepsCollectionView)
    stepsCollectionView.translatesAutoresizingMaskIntoConstraints = false

    stepsCollectionViewHeight = stepsCollectionView.heightAnchor.constraint(equalToConstant: 0).withPriority(.defaultHigh)

    NSLayoutConstraint.activate([
      stepsCollectionView.topAnchor.constraint(equalTo: topAnchor, constant: Constants.contentInsets.top),
      stepsCollectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.contentInsets.left),
      stepsCollectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Constants.contentInsets.right),
      stepsCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: Constants.contentInsets.bottom)
        .withPriority(.defaultHigh),
      stepsCollectionViewHeight,
    ])
  }

  func setNavigationInfo(_ navigationInfo: MWMNavigationDashboardEntity?) {
    if let steps = navigationInfo?.transitSteps {
      if stepsCollectionView.steps != steps {
        stepsCollectionView.steps = steps
      }
      isHidden = steps.isEmpty
    } else {
      isHidden = true
    }
    updateHeight()
  }

  private func updateHeight() {
    layoutIfNeeded()
    let height = stepsCollectionView.collectionViewLayout.collectionViewContentSize.height
    // The steps take no touches while animated, and the route preview renders often.
    guard stepsCollectionViewHeight.constant != height else { return }
    animateConstraints(animations: {
      self.stepsCollectionViewHeight.constant = height
    })
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    layoutIfNeeded()
  }
}
