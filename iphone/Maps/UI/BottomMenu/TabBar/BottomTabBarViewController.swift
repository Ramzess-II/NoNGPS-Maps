class BottomTabBarViewController: UIViewController {
  private enum Constants {
    static let panelTopInset = CGFloat(6)
    static let sourceSelectorWidth = CGFloat(220)
    static let sourceSelectorSpacing = CGFloat(12)
  }

  var presenter: BottomTabBarPresenterProtocol!

  @IBOutlet var searchButton: MWMButton!
  @IBOutlet var moreButton: MWMButton!
  @IBOutlet var downloadBadge: UIView!

  private let panel = MapControlsPanel(edge: .bottom)
  private let sourceSelector = NoGpsSourceSelector()
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
    setupSourceSelector()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The panel goes on to the edges of the screen, under the home indicator and the safe area too.
    let top = (searchButton.superview?.frame.minY ?? 0) - Constants.panelTopInset
    let screenWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
    panel.frame = CGRect(x: -view.frame.minX, y: top, width: screenWidth, height: view.bounds.height - top)
  }

  private func setupSourceSelector() {
    guard let container = searchButton.superview else { return }
    sourceSelector.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(sourceSelector)
    // Search and the menu are placed symmetrically, so the selector keeps away from both.
    let width = sourceSelector.widthAnchor.constraint(equalToConstant: Constants.sourceSelectorWidth)
    width.priority = .defaultHigh
    NSLayoutConstraint.activate([
      width,
      sourceSelector.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      sourceSelector.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      sourceSelector.leadingAnchor.constraint(greaterThanOrEqualTo: searchButton.trailingAnchor,
                                              constant: Constants.sourceSelectorSpacing),
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
