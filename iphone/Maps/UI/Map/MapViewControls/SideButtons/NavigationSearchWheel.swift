/// The quick search of the navigation: the categories on a half circle beside the right map panel, its flat side at the
/// panel. A category is searched on the map, the button of the panel then shows it and clears it. The wheel closes by
/// itself after a while.
@objc
final class NavigationSearchWheel: UIView {
  enum Category: Int, CaseIterable {
    case fuel
    case parking
    case eat
    case food
    case atm

    var query: String {
      switch self {
      case .fuel: return L("category_fuel")
      case .parking: return L("category_parking")
      case .eat: return L("category_eat")
      case .food: return L("category_food")
      case .atm: return L("category_atm")
      }
    }

    var image: UIImage? { UIImage(named: "ic_routing_\(name)_on") }
    /// The button of the panel with it: a tap clears the search.
    var offImage: UIImage? { UIImage(named: "ic_routing_\(name)_off") }

    private var name: String {
      switch self {
      case .fuel: return "fuel"
      case .parking: return "parking"
      case .eat: return "eat"
      case .food: return "food"
      case .atm: return "atm"
      }
    }
  }

  struct State: Equatable {
    private(set) var isOpen = false
    private(set) var category: Category?

    /// Closes an open wheel, else clears the searched category, else opens the wheel.
    /// - Returns: whether the search of the category is to be cleared.
    mutating func tapButton() -> Bool {
      if isOpen {
        isOpen = false
        return false
      }
      if category != nil {
        category = nil
        return true
      }
      isOpen = true
      return false
    }

    mutating func pick(_ category: Category) {
      self.category = category
      isOpen = false
    }

    mutating func close() {
      isOpen = false
    }
  }

  enum Constants {
    /// Of the half circle.
    static let radius = CGFloat(96)
    /// Of the circle the buttons are on, about the middle of the flat side.
    static let buttonsRadius = CGFloat(68)
    static let buttonSize = CGFloat(40)
    static let collapseTimeout: TimeInterval = 5
  }

  /// The center of the button of a category from the middle of the flat side: x away from the panel, y down. The
  /// buttons go from the top to the bottom at equal angles, the first and the last apart from the panel.
  static func offset(of category: Category) -> CGPoint {
    let step = CGFloat.pi / CGFloat(Category.allCases.count)
    let angle = step / 2 + step * CGFloat(category.rawValue)
    return CGPoint(x: Constants.buttonsRadius * sin(angle), y: -Constants.buttonsRadius * cos(angle))
  }

  /// In the panel.
  @objc let button = MWMButton()
  /// The wheel is opened or closed: the panel lays it out.
  @objc var onChange: (() -> Void)?
  @objc var isOpen: Bool { state.isOpen }

  private var state = State() {
    didSet {
      guard state != oldValue else { return }
      update(animated: true)
    }
  }

  private let isRTL = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
  private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
  private let border = CAShapeLayer()
  private var categoryButtons = [MWMButton]()

  @objc init() {
    super.init(frame: CGRect(x: 0, y: 0, width: Constants.radius, height: 2 * Constants.radius))
    button.setStyleAndApply(.mapPanelButton)
    button.accessibilityLabel = L("search")
    button.addTarget(self, action: #selector(buttonTap), for: .touchUpInside)

    setStyleAndApply(.mapControlsPanel)
    let path = halfCircle().cgPath
    layer.shadowPath = path
    let mask = CAShapeLayer()
    mask.path = path
    material.frame = bounds
    material.layer.mask = mask
    material.contentView.backgroundColor = MapControlsPanel.Constants.tintColor
    addSubview(material)
    border.path = path
    border.fillColor = nil
    border.lineWidth = MapControlsPanel.Constants.borderWidth
    layer.addSublayer(border)
    updateBorderColor()

    let flatSideX = isRTL ? 0 : Constants.radius
    for category in Category.allCases {
      let categoryButton = MWMButton(type: .custom)
      categoryButton.setStyleAndApply(.mapPanelButton)
      categoryButton.setImage(category.image, for: .normal)
      categoryButton.accessibilityLabel = category.query
      categoryButton.tag = category.rawValue
      categoryButton.addTarget(self, action: #selector(categoryTap(_:)), for: .touchUpInside)
      let offset = Self.offset(of: category)
      categoryButton.bounds = CGRect(x: 0, y: 0, width: Constants.buttonSize, height: Constants.buttonSize)
      categoryButton.center = CGPoint(x: flatSideX + (isRTL ? offset.x : -offset.x), y: Constants.radius + offset.y)
      addSubview(categoryButton)
      categoryButtons.append(categoryButton)
    }
    update(animated: false)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      updateBorderColor()
    }
  }

  /// The search was changed elsewhere, e.g. in the search of the navigation sheet.
  @objc func reset() {
    state = State()
  }

  /// Out of the navigation the button is gone: its search is cleared.
  @objc func clear() {
    if state.category != nil {
      Search.clear()
    }
    state = State()
  }

  @objc private func buttonTap() {
    if state.tapButton() {
      Search.clear()
      MapViewController.shared()?.searchManager.hide()
    }
  }

  @objc private func categoryTap(_ sender: UIButton) {
    guard let category = Category(rawValue: sender.tag) else { return }
    Search.setSearchMode(.viewport)
    Search.searchQuery(SearchQuery(category.query + " ", source: .category))
    state.pick(category)
  }

  @objc private func closeOnTimer() {
    state.close()
  }

  private func update(animated: Bool) {
    button.setImage(state.category?.offImage ?? MWMSideButtons.symbol("magnifyingglass"), for: .normal)
    button.isSelected = state.category != nil

    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closeOnTimer), object: nil)
    if state.isOpen {
      perform(#selector(closeOnTimer), with: nil, afterDelay: Constants.collapseTimeout)
      isHidden = false
    }
    UIView.animate(withDuration: animated ? AppConstants.defaultAnimationDuration : 0,
                   animations: { self.alpha = self.state.isOpen ? 1 : 0 },
                   completion: { _ in self.isHidden = !self.state.isOpen })
    onChange?()
  }

  private func updateBorderColor() {
    border.strokeColor = MapControlsPanel.Constants.borderColor.resolvedColor(with: traitCollection).cgColor
  }

  /// The flat side is at the panel.
  private func halfCircle() -> UIBezierPath {
    let r = Constants.radius
    let center = CGPoint(x: isRTL ? 0 : r, y: r)
    let path = UIBezierPath(arcCenter: center, radius: r, startAngle: -.pi / 2, endAngle: .pi / 2,
                            clockwise: isRTL)
    path.close()
    return path
  }
}
