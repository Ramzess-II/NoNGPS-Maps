/// The intro of the first start over the whole map: the screen is dimmed but for the panel the step points at, and a
/// balloon with an arrow at that panel tells what it does. The text is typed into it, see NoGpsIntroSequence; the
/// overlay only shows what the step machine tells it to.
final class NoGpsIntroOverlay: UIView {
  enum Constants {
    static let dimOpacity = Float(0.69)
    static let holePadding = CGFloat(4)
    static let holeRadius = CGFloat(16)
    /// Between the tip of the arrow and the panel.
    static let balloonGap = CGFloat(6)
    static let balloonPadding = CGFloat(14)
    /// Of the balloon from the edges of the screen.
    static let balloonMargin = CGFloat(12)
    static let balloonMaxWidth = CGFloat(320)
    static let balloonRadius = CGFloat(12)
    static let arrowSize = CGSize(width: 20, height: 10)
    static let fontSize = CGFloat(16)
  }

  var onTap: (() -> Void)?
  /// The panel the balloon points at.
  weak var anchor: UIView?
  /// The whole text: the balloon is measured on it and does not grow while the text is typed into it.
  var text = "" {
    didSet {
      label.text = text
      setNeedsLayout()
    }
  }

  /// How many characters of the text are shown.
  var revealed = 0 {
    didSet {
      guard revealed != oldValue else { return }
      label.text = String(text.prefix(revealed))
      // The label keeps the place of the whole text, see layoutSubviews().
      setNeedsLayout()
    }
  }

  private let dimLayer = CAShapeLayer()
  private let balloonLayer = CAShapeLayer()
  private let label = UILabel()

  init() {
    super.init(frame: .zero)
    dimLayer.fillRule = .evenOdd
    dimLayer.fillColor = UIColor.black.cgColor
    dimLayer.opacity = Constants.dimOpacity
    layer.addSublayer(dimLayer)
    balloonLayer.shadowColor = UIColor.black.cgColor
    balloonLayer.shadowOpacity = 0.3
    balloonLayer.shadowRadius = 6
    balloonLayer.shadowOffset = CGSize(width: 0, height: 2)
    layer.addSublayer(balloonLayer)
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: Constants.fontSize)
    label.textColor = .label
    addSubview(label)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    isAccessibilityElement = true
    accessibilityTraits = [.button, .staticText]
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc
  private func tapped() {
    onTap?()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    accessibilityLabel = text
    guard let anchor, anchor.window != nil else {
      dimLayer.path = nil
      balloonLayer.path = nil
      label.isHidden = true
      return
    }
    label.isHidden = false
    // Resolved here: a layer keeps a plain color, and the theme can change under the intro.
    balloonLayer.fillColor = UIColor.systemBackground.cgColor
    let hole = convert(anchor.bounds, from: anchor).insetBy(dx: -Constants.holePadding, dy: -Constants.holePadding)
    layoutDim(hole: hole)
    layoutBalloon(hole: hole)
  }

  private func layoutDim(hole: CGRect) {
    let path = UIBezierPath(rect: bounds)
    path.append(UIBezierPath(roundedRect: hole, cornerRadius: Constants.holeRadius))
    dimLayer.frame = bounds
    dimLayer.path = path.cgPath
  }

  private func layoutBalloon(hole: CGRect) {
    let padding = Constants.balloonPadding
    let margin = Constants.balloonMargin
    let maxTextWidth = min(Constants.balloonMaxWidth, bounds.width - 2 * margin) - 2 * padding
    guard maxTextWidth > 0 else { return }
    // Of the whole text, so that the balloon stands still while it is typed in.
    let textSize = (text as NSString).boundingRect(with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: label.font as Any], context: nil).size
    let size = CGSize(width: ceil(textSize.width) + 2 * padding,
                      height: ceil(textSize.height) + 2 * padding + Constants.arrowSize.height)
    // Above the panel where it fits, else below it.
    let below = hole.minY - Constants.balloonGap - size.height < margin
    let top = below ? hole.maxY + Constants.balloonGap : hole.minY - Constants.balloonGap - size.height
    let tip = min(max(hole.midX, margin + Constants.holeRadius), bounds.width - margin - Constants.holeRadius)
    let left = min(max(tip - size.width / 2, margin), max(margin, bounds.width - margin - size.width))
    let frame = CGRect(origin: CGPoint(x: left, y: top), size: size)
    balloonLayer.frame = bounds
    balloonLayer.path = Self.balloonPath(in: frame, tipX: tip, arrowOnTop: below).cgPath
    balloonLayer.shadowPath = balloonLayer.path
    label.frame = CGRect(x: frame.minX + padding,
                         y: frame.minY + padding + (below ? Constants.arrowSize.height : 0),
                         width: ceil(textSize.width), height: ceil(textSize.height))
  }

  /// A rounded rectangle with a triangle at the tip of the arrow, which stands at the edge the panel is on.
  static func balloonPath(in frame: CGRect, tipX: CGFloat, arrowOnTop: Bool) -> UIBezierPath {
    let arrow = Constants.arrowSize
    let body = arrowOnTop ? CGRect(x: frame.minX, y: frame.minY + arrow.height, width: frame.width,
                                   height: frame.height - arrow.height)
      : CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - arrow.height)
    let path = UIBezierPath(roundedRect: body, cornerRadius: Constants.balloonRadius)
    let base = arrowOnTop ? body.minY : body.maxY
    let tipY = arrowOnTop ? frame.minY : frame.maxY
    // Kept inside the rounded corners of the body.
    let cx = min(max(tipX, body.minX + Constants.balloonRadius + arrow.width / 2),
                 body.maxX - Constants.balloonRadius - arrow.width / 2)
    let triangle = UIBezierPath()
    triangle.move(to: CGPoint(x: cx - arrow.width / 2, y: base))
    triangle.addLine(to: CGPoint(x: cx, y: tipY))
    triangle.addLine(to: CGPoint(x: cx + arrow.width / 2, y: base))
    triangle.close()
    path.append(triangle)
    return path
  }
}
