/// The frosted background of a group of map buttons. It is docked to an edge of the screen: the corners at the edge
/// are square, the others are rounded. Touches go through it to the buttons and the map.
@objc
final class MapControlsPanel: UIView {
  @objc(MapControlsPanelEdge)
  enum Edge: Int {
    case left
    case right
    case bottom
  }

  private enum Constants {
    static let cornerRadius = CGFloat(14)
    static let bottomCornerRadius = CGFloat(16)
    static let dividerInset = CGFloat(10)
  }

  private let edge: Edge
  private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))

  @objc
  init(edge: Edge) {
    self.edge = edge
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    setStyleAndApply(.mapControlsPanel)
    material.frame = bounds
    material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    material.clipsToBounds = true
    material.layer.cornerRadius = radius
    material.layer.cornerCurve = .continuous
    material.layer.maskedCorners = maskedCorners
    addSubview(material)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowPath = UIBezierPath(roundedRect: bounds,
                                    byRoundingCorners: roundedCorners,
                                    cornerRadii: CGSize(width: radius, height: radius)).cgPath
  }

  /// The gap between buttons that holds a group divider, see addGroupDivider(above:).
  @objc static let groupGap = CGFloat(8)
  @objc static let groupDividerHeight = CGFloat(2)
  @objc static let groupDividerMargin = CGFloat(10)

  /// A line in the middle of the gap of groupGap above a button, with margins on every side.
  @discardableResult
  static func addGroupDivider(above view: UIView) -> UIView {
    let divider = UIView()
    divider.setStyleAndApply(.solidDivider)
    divider.isUserInteractionEnabled = false
    divider.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(divider)
    NSLayoutConstraint.activate([
      divider.centerYAnchor.constraint(equalTo: view.topAnchor, constant: -groupGap / 2),
      divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: groupDividerMargin),
      divider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -groupDividerMargin),
      divider.heightAnchor.constraint(equalToConstant: groupDividerHeight),
    ])
    return divider
  }

  /// A hairline at the top of a button that follows another one in a panel.
  @objc @discardableResult
  static func addDivider(above view: UIView) -> UIView {
    let divider = UIView()
    divider.setStyleAndApply(.divider)
    divider.isUserInteractionEnabled = false
    divider.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(divider)
    NSLayoutConstraint.activate([
      divider.topAnchor.constraint(equalTo: view.topAnchor),
      divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Constants.dividerInset),
      divider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Constants.dividerInset),
      divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
    ])
    return divider
  }

  private var radius: CGFloat {
    edge == .bottom ? Constants.bottomCornerRadius : Constants.cornerRadius
  }

  private var roundedCorners: UIRectCorner {
    switch edge {
    case .left: return [.topRight, .bottomRight]
    case .right: return [.topLeft, .bottomLeft]
    case .bottom: return [.topLeft, .topRight]
    }
  }

  private var maskedCorners: CACornerMask {
    switch edge {
    case .left: return [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    case .right: return [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    case .bottom: return [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }
  }
}
