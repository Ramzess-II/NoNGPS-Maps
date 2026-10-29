/// A horizontal strip of the first bookmark list, shown between the search field and the tabs.
final class SearchBookmarksStripView: UIView {
  private enum Constants {
    static let itemSize = CGSize(width: 72, height: 76)
    static let iconSize: CGFloat = 44
    static let iconToNameSpacing: CGFloat = 6
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 8
  }

  var didSelect: ((SearchBookmark) -> Void)?

  private var bookmarks: [SearchBookmark] = []
  private let collectionView: UICollectionView

  override init(frame: CGRect) {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.itemSize = Constants.itemSize
    layout.minimumLineSpacing = 0
    layout.sectionInset = UIEdgeInsets(top: 0, left: Constants.horizontalInset, bottom: 0, right: Constants.horizontalInset)
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(frame: frame)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setBookmarks(_ bookmarks: [SearchBookmark]) {
    self.bookmarks = bookmarks
    isHidden = bookmarks.isEmpty
    collectionView.reloadData()
  }

  private func setupViews() {
    setStyle(.background)
    collectionView.backgroundColor = .clear
    collectionView.showsHorizontalScrollIndicator = false
    collectionView.alwaysBounceHorizontal = true
    collectionView.register(cell: Cell.self)
    collectionView.dataSource = self
    collectionView.delegate = self

    addSubview(collectionView)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalInset),
      collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.verticalInset),
      collectionView.heightAnchor.constraint(equalToConstant: Constants.itemSize.height),
    ])
  }
}

extension SearchBookmarksStripView: UICollectionViewDataSource {
  func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
    bookmarks.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(cell: Cell.self, indexPath: indexPath)
    cell.configure(with: bookmarks[indexPath.item])
    return cell
  }
}

extension SearchBookmarksStripView: UICollectionViewDelegate {
  func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    didSelect?(bookmarks[indexPath.item])
  }
}

private extension SearchBookmarksStripView {
  final class Cell: UICollectionViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
      super.init(frame: frame)
      nameLabel.setFontStyle(.regular12, color: .blackPrimary)
      nameLabel.textAlignment = .center
      nameLabel.lineBreakMode = .byTruncatingTail

      contentView.addSubview(iconView)
      contentView.addSubview(nameLabel)
      iconView.translatesAutoresizingMaskIntoConstraints = false
      nameLabel.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        iconView.topAnchor.constraint(equalTo: contentView.topAnchor),
        iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        iconView.widthAnchor.constraint(equalToConstant: Constants.iconSize),
        iconView.heightAnchor.constraint(equalToConstant: Constants.iconSize),
        nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: Constants.iconToNameSpacing),
        nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
        nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
      ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
      didSet { contentView.alpha = isHighlighted ? 0.5 : 1 }
    }

    func configure(with bookmark: SearchBookmark) {
      iconView.image = bookmark.image(size: Constants.iconSize)
      nameLabel.text = bookmark.name
      accessibilityLabel = bookmark.name
      isAccessibilityElement = true
      accessibilityTraits = .button
    }
  }
}
