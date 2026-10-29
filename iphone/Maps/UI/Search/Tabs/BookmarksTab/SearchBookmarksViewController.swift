protocol SearchBookmarksViewControllerDelegate: UIScrollViewDelegate {
  func searchBookmarksViewController(_ viewController: SearchBookmarksViewController,
                                     didSelect bookmark: SearchBookmark)
}

final class SearchBookmarksViewController: MWMViewController {
  private weak var delegate: SearchBookmarksViewControllerDelegate?
  private var bookmarks: [SearchBookmark] = []
  private let emptyView = PlaceholderView(title: L("bookmarks_empty_list_title"),
                                          subtitle: L("bookmarks_empty_list_message"))

  private let tableView = UITableView()

  // MARK: - Init

  init(delegate: SearchBookmarksViewControllerDelegate?) {
    self.delegate = delegate
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    setupTableView()
    setupEmptyView()
    reload()
  }

  // MARK: - Private methods

  private func setupTableView() {
    tableView.setStyle(.background)
    tableView.register(cell: SearchBookmarkCell.self)
    tableView.keyboardDismissMode = .onDrag
    tableView.delegate = self
    tableView.dataSource = self
    tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 1))

    view.addSubview(tableView)
    tableView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setupEmptyView() {
    view.addSubview(emptyView)
    emptyView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      emptyView.topAnchor.constraint(equalTo: view.topAnchor),
      emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  // MARK: - Public methods

  func reload() {
    guard isViewLoaded else { return }
    bookmarks = SearchBookmarks.all()
    emptyView.isHidden = !bookmarks.isEmpty
    tableView.reloadData()
  }
}

extension SearchBookmarksViewController: UITableViewDataSource {
  func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
    bookmarks.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(cell: SearchBookmarkCell.self, indexPath: indexPath)
    cell.configure(with: bookmarks[indexPath.row])
    return cell
  }
}

extension SearchBookmarksViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    delegate?.searchBookmarksViewController(self, didSelect: bookmarks[indexPath.row])
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    delegate?.scrollViewDidScroll?(scrollView)
  }
}

extension SearchBookmarksViewController: ModallyPresentedViewController {
  func presentationFrameDidChange(_ frame: CGRect) {
    guard isViewLoaded else { return }
    tableView.contentInset.bottom = frame.origin.y
    emptyView.presentationFrameDidChange(frame)
  }
}
