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
    // The edge keeps the panel apart from a dark map, where the shadow is not seen.
    static let borderWidth = CGFloat(1)
    static let borderColor = UIColor { $0.userInterfaceStyle == .dark
      ? UIColor(white: 1, alpha: 0.18)
      : UIColor(white: 0, alpha: 0.06)
    }

    /// A dark panel lighter than the dark map.
    static let tintColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.06) : .clear }
  }

  private let edge: Edge
  private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
  private let border = CAShapeLayer()

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
    material.contentView.backgroundColor = Constants.tintColor
    addSubview(material)
    border.fillColor = nil
    border.lineWidth = Constants.borderWidth
    layer.addSublayer(border)
    updateBorderColor()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      updateBorderColor()
    }
  }

  private func updateBorderColor() {
    border.strokeColor = Constants.borderColor.resolvedColor(with: traitCollection).cgColor
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
    border.path = borderPath().cgPath
  }

  /// The edge along the sides away from the edge of the screen: none is drawn at the screen.
  private func borderPath() -> UIBezierPath {
    let inset = Constants.borderWidth / 2
    let (w, h, r) = (bounds.width, bounds.height, radius)
    let arc = r - inset
    let path = UIBezierPath()
    switch edge {
    case .right:
      path.move(to: CGPoint(x: w, y: inset))
      path.addLine(to: CGPoint(x: r, y: inset))
      path.addArc(withCenter: CGPoint(x: r, y: r), radius: arc, startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
      path.addLine(to: CGPoint(x: inset, y: h - r))
      path.addArc(withCenter: CGPoint(x: r, y: h - r), radius: arc, startAngle: .pi, endAngle: .pi / 2, clockwise: false)
      path.addLine(to: CGPoint(x: w, y: h - inset))
    case .left:
      path.move(to: CGPoint(x: 0, y: inset))
      path.addLine(to: CGPoint(x: w - r, y: inset))
      path.addArc(withCenter: CGPoint(x: w - r, y: r), radius: arc, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
      path.addLine(to: CGPoint(x: w - inset, y: h - r))
      path.addArc(withCenter: CGPoint(x: w - r, y: h - r), radius: arc, startAngle: 0, endAngle: .pi / 2, clockwise: true)
      path.addLine(to: CGPoint(x: 0, y: h - inset))
    case .bottom:
      path.move(to: CGPoint(x: inset, y: r))
      path.addArc(withCenter: CGPoint(x: r, y: r), radius: arc, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
      path.addLine(to: CGPoint(x: w - r, y: inset))
      path.addArc(withCenter: CGPoint(x: w - r, y: r), radius: arc, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
    }
    return path
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
