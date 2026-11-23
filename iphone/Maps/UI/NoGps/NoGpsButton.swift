/// The two buttons of the NonGPS screens: the accented one, filled in the link colour, and the quiet one, a label in
/// the link colour. The intro and About NonGPS Maps use the same ones.
enum NoGpsButton {
  private enum Constants {
    static let height = CGFloat(44)
    static let padding = CGFloat(10)
    static let radius = CGFloat(10)
    static let imagePadding = CGFloat(8)
    static let iconSide = CGFloat(24)
  }

  static func filled(title: String, action: @escaping () -> Void) -> UIButton {
    make(title: title, icon: nil, background: .linkBlue, foreground: .white,
         font: .systemFont(ofSize: 16, weight: .semibold), action: action)
  }

  /// `background` is the card colour behind a quiet button of the intro, clear on a plain screen.
  static func outlined(title: String, icon: UIImage? = nil, background: UIColor = .blackOpaque,
                       action: @escaping () -> Void) -> UIButton {
    make(title: title, icon: icon, background: background, foreground: .linkBlue,
         font: .systemFont(ofSize: 15), action: action)
  }

  private static func make(title: String, icon: UIImage?, background: UIColor, foreground: UIColor, font: UIFont,
                           action: @escaping () -> Void) -> UIButton {
    var config = UIButton.Configuration.filled()
    config.title = title
    config.image = icon.map { scaled($0, to: Constants.iconSide) }
    config.imagePadding = Constants.imagePadding
    config.titleAlignment = .center
    config.baseBackgroundColor = background
    config.baseForegroundColor = foreground
    config.cornerStyle = .fixed
    config.background.cornerRadius = Constants.radius
    config.contentInsets = NSDirectionalEdgeInsets(top: Constants.padding, leading: Constants.padding,
                                                   bottom: Constants.padding, trailing: Constants.padding)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = font
      return attributes
    }
    let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.height).isActive = true
    return button
  }

  /// A button configuration draws a non-symbol image at its natural size, and the GitHub glyph is 54 pt, so it is
  /// redrawn to the icon side the label sits next to. The aspect ratio is kept.
  private static func scaled(_ image: UIImage, to side: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > 0 else { return image.withRenderingMode(.alwaysTemplate) }
    let size = CGSize(width: image.size.width * side / longest, height: image.size.height * side / longest)
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format)
      .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
      .withRenderingMode(.alwaysTemplate)
  }
}
