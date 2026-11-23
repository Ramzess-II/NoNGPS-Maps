/// The two buttons of the NonGPS screens: the accented one, filled in the link colour, and the quiet one, a label in
/// the link colour. The intro and About NonGPS Maps use the same ones.
enum NoGpsButton {
  private enum Constants {
    static let height = CGFloat(44)
    static let padding = CGFloat(10)
    static let radius = CGFloat(10)
    static let imagePadding = CGFloat(8)
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
    config.image = icon?.withRenderingMode(.alwaysTemplate)
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
}
