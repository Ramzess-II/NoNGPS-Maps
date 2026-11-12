class BottomTabBarViewController: UIViewController {
  private enum Constants {
    /// Of the panel above the buttons: as the top of the buttons in the xib.
    static let panelTopInset = CGFloat(6)
    static let statusBarSpacing = CGFloat(6)
    static let statusBarMaxWidth = CGFloat(360)
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
    let screenWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
    panel.frame = CGRect(x: -view.frame.minX, y: 0, width: screenWidth, height: view.bounds.height)
  }

  private func setupStatusBar() {
    guard let container = searchButton.superview else { return }
    NoGpsStatusBar.styleButton(searchButton)
    NoGpsStatusBar.styleButton(moreButton)
    statusBar.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(statusBar)
    // The navigation button takes the place between Search and the menu, they are placed symmetrically. A wide
    // screen leaves the rest of it empty.
    let fill = statusBar.widthAnchor.constraint(equalTo: container.widthAnchor)
    fill.priority = .defaultLow
    NSLayoutConstraint.activate([
      fill,
      statusBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      statusBar.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      statusBar.leadingAnchor.constraint(greaterThanOrEqualTo: searchButton.trailingAnchor,
                                         constant: Constants.statusBarSpacing),
      statusBar.widthAnchor.constraint(lessThanOrEqualToConstant: Constants.statusBarMaxWidth),
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
    // The view takes the panel above the buttons too, as the xib puts them under its top: the speed, the ruler and the
    // side buttons keep their margins from the panel.
    let inset = Constants.panelTopInset
    let newFrame = CGRect(x: avaliableArea.minX,
                          y: isHidden ? avaliableArea.maxY : avaliableArea.minY - inset,
                          width: avaliableArea.width,
                          height: avaliableArea.height + inset)
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
