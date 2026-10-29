protocol SearchTabViewControllerDelegate: UIScrollViewDelegate {
  func searchTabController(_ viewController: SearchTabViewController, didSearch: SearchQuery)
  func searchTabController(_ viewController: SearchTabViewController, didSelect bookmark: SearchBookmark)
}

@objc
final class SearchTabViewController: TabViewController {
  private enum Tab: Int {
    case history
    case categories
    case bookmarks
  }

  private static let selectedIndexKey = "SearchTabViewController_selectedIndexKey"
  weak var delegate: SearchTabViewControllerDelegate?

  private var frameworkHelper = MWMSearchFrameworkHelper.self
  private var tabs: [Tab] = []

  private var activeTab: Tab = .init(rawValue:
    UserDefaults.standard.integer(forKey: SearchTabViewController.selectedIndexKey)) ?? .categories {
    didSet {
      UserDefaults.standard.set(activeTab.rawValue, forKey: SearchTabViewController.selectedIndexKey)
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    tabs = Settings.searchHistoryEnabled() ? [.history, .categories, .bookmarks] : [.categories, .bookmarks]
    viewControllers = tabs.map { viewController(for: $0) }

    let selectedTab: Tab
    if !tabs.contains(activeTab) || (activeTab == .history && frameworkHelper.isSearchHistoryEmpty()) {
      selectedTab = .categories
    } else {
      selectedTab = activeTab
    }
    tabView.selectedIndex = tabs.firstIndex(of: selectedTab) ?? 0
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard let selectedIndex = tabView.selectedIndex,
          tabs.indices.contains(selectedIndex) else { return }
    activeTab = tabs[selectedIndex]
  }

  func reloadSearchHistory() {
    guard let historyIndex = tabs.firstIndex(of: .history) else { return }
    (viewControllers[historyIndex] as? SearchHistoryViewController)?.reload()
  }

  func reloadBookmarks() {
    guard let bookmarksIndex = tabs.firstIndex(of: .bookmarks) else { return }
    (viewControllers[bookmarksIndex] as? SearchBookmarksViewController)?.reload()
  }

  private func viewController(for tab: Tab) -> UIViewController {
    switch tab {
    case .history:
      let history = SearchHistoryViewController(frameworkHelper: frameworkHelper,
                                                delegate: self)
      history.title = L("history")
      return history
    case .categories:
      let categories = SearchCategoriesViewController(frameworkHelper: frameworkHelper,
                                                      delegate: self)
      categories.title = L("categories")
      return categories
    case .bookmarks:
      let bookmarks = SearchBookmarksViewController(delegate: self)
      bookmarks.title = L("bookmarks")
      return bookmarks
    }
  }
}

extension SearchTabViewController: ModallyPresentedViewController {
  func presentationFrameDidChange(_ frame: CGRect) {
    viewControllers.forEach { ($0 as? ModallyPresentedViewController)?.presentationFrameDidChange(frame) }
  }
}

extension SearchTabViewController: UIScrollViewDelegate {
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    delegate?.scrollViewDidScroll?(scrollView)
  }

  func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
    delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
  }
}

extension SearchTabViewController: SearchCategoriesViewControllerDelegate {
  func categoriesViewController(_: SearchCategoriesViewController,
                                didSelect category: String) {
    let preferredLang = AppInfo.shared().languageId
    let supportedBySearchLang = MWMSearchFrameworkHelper.isLanguageSupported(preferredLang) ? preferredLang : "en"
    let searchText = L(category, languageCode: supportedBySearchLang) + " "
    let query = SearchQuery(searchText, locale: supportedBySearchLang, source: .category)
    delegate?.searchTabController(self, didSearch: query)
  }
}

extension SearchTabViewController: SearchHistoryViewControllerDelegate {
  func searchHistoryViewController(_: SearchHistoryViewController,
                                   didSelect query: String) {
    let query = SearchQuery(query.trimmingCharacters(in: .whitespacesAndNewlines) + " ", source: .history)
    delegate?.searchTabController(self, didSearch: query)
  }
}

extension SearchTabViewController: SearchBookmarksViewControllerDelegate {
  func searchBookmarksViewController(_: SearchBookmarksViewController,
                                     didSelect bookmark: SearchBookmark) {
    delegate?.searchTabController(self, didSelect: bookmark)
  }
}
