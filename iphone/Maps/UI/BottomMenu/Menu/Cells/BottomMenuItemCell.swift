final class BottomMenuItemCell: UITableViewCell {
  @IBOutlet private var label: UILabel!
  @IBOutlet private var badgeBackground: UIView!
  @IBOutlet private var badgeCountLabel: UILabel!
  @IBOutlet private var icon: UIImageView!
  var anchorView: UIView {
    icon
  }

  private(set) var isEnabled: Bool = true
  /// The full-width line above the first cell of a group; the rows inside a group draw none.
  private var groupSeparator: UIView?

  func configure(image: UIImage,
                 title: String,
                 badgeCount: UInt = .zero,
                 imageStyle: GlobalStyleSheet = .black,
                 enabled: Bool = true) {
    isEnabled = enabled
    icon.setStyleAndApply(enabled ? imageStyle : .gray)
    icon.image = image
    label.text = title
    label.setFontStyleAndApply(.regular16, color: enabled ? .blackPrimary : .blackHint)
    badgeBackground.isHidden = badgeCount == 0
    badgeCountLabel.text = "\(badgeCount)"
    badgeCountLabel.setFontStyleAndApply(.medium14, color: .whitePrimary)
  }

  func setStartsGroup(_ startsGroup: Bool) {
    if groupSeparator == nil, startsGroup {
      groupSeparator = addSeparator(.top)
    }
    groupSeparator?.isHidden = !startsGroup
  }
}
