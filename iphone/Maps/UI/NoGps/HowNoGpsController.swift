import WebKit

/// How NonGPS works: the guide page data/nogps_guide.html in a WKWebView. Its "Show the intro again" link plays the
/// intro of the first start. The intro itself is NoGpsIntroController; the about screen of the app is
/// AboutNoGpsController. The same page is on Android, see nogps.HowNoGpsFragment.
final class HowNoGpsController: MWMViewController {
  /// What the page's links do.
  enum LinkAction: Equatable {
    case intro
    case browser(URL)
    case load
  }

  static let introURL = "nogps-guide://intro"

  /// Ukrainian for the uk and ru locales, English for the others, as the page expects.
  static func pageLang(_ language: String?) -> String {
    switch language?.lowercased() {
    case "uk", "ru": return "uk"
    default: return "en"
    }
  }

  static func action(for url: URL) -> LinkAction {
    if url.absoluteString == introURL {
      return .intro
    }
    if url.scheme == "http" || url.scheme == "https" {
      return .browser(url)
    }
    return .load
  }

  private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("nogps_how_title")
    view.setStyle(.pressBackground)

    webView.navigationDelegate = self
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: view.topAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    loadGuide()
  }

  private func loadGuide() {
    guard let file = Bundle.main.url(forResource: "nogps_guide", withExtension: "html"),
          var components = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return }
    components.queryItems = [URLQueryItem(name: "lang", value: Self.pageLang(Locale.current.languageCode))]
    guard let url = components.url else { return }
    // The folder of the bundle is the base, so the screenshots of the page can be relative files.
    webView.loadFileURL(url, allowingReadAccessTo: Bundle.main.resourceURL ?? file.deletingLastPathComponent())
  }

  /// Back to the map, where the intro runs as it does on the first start.
  private func playIntro() {
    guard let map = MapViewController.shared() else { return }
    navigationController?.popToViewController(map, animated: true)
    NoGpsIntroController.play(in: map)
  }
}

// MARK: - WKNavigationDelegate

extension HowNoGpsController: WKNavigationDelegate {
  func webView(_: WKWebView,
               decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }
    switch Self.action(for: url) {
    case .intro:
      decisionHandler(.cancel)
      playIntro()
    case .browser(let link):
      decisionHandler(.cancel)
      UIApplication.shared.open(link)
    case .load:
      decisionHandler(.allow)
    }
  }
}
