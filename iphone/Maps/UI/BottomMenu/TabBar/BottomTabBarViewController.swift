class BottomTabBarViewController: UIViewController {
  private enum Constants {
    static let panelTopInset = CGFloat(6)
    static let statusBarWidth = CGFloat(260)
    static let statusBarSpacing = CGFloat(4)
  }

  var presenter: BottomTabBarPresenterProtocol!

  @IBOutlet var searchButton: MWMButton!
  @IBOutlet var moreButton: MWMButton!
  @IBOutlet var downloadBadge: UIView!

  private let panel = MapControlsPanel(edge: .bottom)
  private let statusBar = NoGpsStatusBar()
  private var avaliableArea = CGRect.zero
  @objc var isHidden: Bool = false {
    didSet {
      updateFrame(animated: true)
    }
  }

  @objc var isApplicationBadgeHidden: Bool = true {
    didSet {
      updateBadge()
    }
  }

  @objc static var controller: BottomTabBarViewController? { MWMMapViewControlsManager.manager()?.tabBarController }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.alpha = 0 // Hide the view until it receives a first available area update.
    view.insertSubview(panel, at: 0)
    setupStatusBar()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The panel goes on to the edges of the screen, under the home indicator and the safe area too.
    let top = (searchButton.superview?.frame.minY ?? 0) - Constants.panelTopInset
    let screenWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
    panel.frame = CGRect(x: -view.frame.minX, y: top, width: screenWidth, height: view.bounds.height - top)
  }

  private func setupStatusBar() {
    guard let container = searchButton.superview else { return }
    NoGpsStatusBar.styleButton(searchButton)
    NoGpsStatusBar.styleButton(moreButton)
    statusBar.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(statusBar)
    // Search and the menu are placed symmetrically, so the bar keeps away from both.
    let width = statusBar.widthAnchor.constraint(equalToConstant: Constants.statusBarWidth)
    width.priority = .defaultHigh
    NSLayoutConstraint.activate([
      width,
      statusBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      statusBar.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      statusBar.leadingAnchor.constraint(greaterThanOrEqualTo: searchButton.trailingAnchor,
                                         constant: Constants.statusBarSpacing),
    ])
  }

  static func updateAvailableArea(_ frame: CGRect) {
    BottomTabBarViewController.controller?.updateAvailableArea(frame)
  }

  @IBAction func onSearchButtonPressed(_: Any) {
    presenter.onSearchButtonPressed()
  }

  @IBAction func onMenuButtonPressed(_: Any) {
    presenter.onMenuButtonPressed()
  }

  private func updateAvailableArea(_ frame: CGRect) {
    avaliableArea = frame
    updateFrame(animated: false)
    view.layoutIfNeeded()
  }

  private func updateFrame(animated: Bool) {
    if avaliableArea == .zero {
      return
    }
    let newFrame = CGRect(x: avaliableArea.minX,
                          y: isHidden ? avaliableArea.minY + avaliableArea.height : avaliableArea.minY,
                          width: avaliableArea.width,
                          height: avaliableArea.height)
    let alpha: CGFloat = isHidden ? 0 : 1
    if animated {
      UIView.animate(withDuration: AppConstants.defaultAnimationDuration,
                     delay: 0,
                     options: [.beginFromCurrentState],
                     animations: {
                       self.view.frame = newFrame
                       self.view.alpha = alpha
                     }, completion: nil)
    } else {
      view.frame = newFrame
      view.alpha = alpha
    }
  }

  private func updateBadge() {
    downloadBadge.isHidden = isApplicationBadgeHidden
  }
}
