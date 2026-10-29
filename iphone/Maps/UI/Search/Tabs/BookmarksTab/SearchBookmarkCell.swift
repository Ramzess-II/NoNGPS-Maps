final class SearchBookmarkCell: MWMTableViewCell {
  private enum Constants {
    static let iconSize: CGFloat = 28
  }

  override init(style _: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    setStyle(.defaultTableViewCell)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with bookmark: SearchBookmark) {
    imageView?.image = bookmark.image(size: Constants.iconSize)
    textLabel?.text = bookmark.name
    textLabel?.setFontStyleAndApply(.regular17, color: .blackPrimary)
    let distance = bookmark.distance.map { DistanceFormatter.distanceString(fromMeters: $0) }
    detailTextLabel?.text = [distance, bookmark.listName].compactMap { $0 }.joined(separator: " • ")
    detailTextLabel?.setFontStyleAndApply(.regular14, color: .blackSecondary)
  }
}
