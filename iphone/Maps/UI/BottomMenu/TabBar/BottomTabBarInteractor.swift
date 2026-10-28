protocol BottomTabBarInteractorProtocol: AnyObject {
  func openSearch()
  func openMenu()
}

class BottomTabBarInteractor {
  private weak var viewController: BottomTabBarViewController?
  private weak var mapViewController: MapViewController?
  private weak var controlsManager: MWMMapViewControlsManager?
  private let searchManager: SearchOnMapManager

  init(viewController: BottomTabBarViewController, mapViewController: MapViewController, controlsManager: MWMMapViewControlsManager) {
    self.viewController = viewController
    self.mapViewController = mapViewController
    self.controlsManager = controlsManager
    searchManager = mapViewController.searchManager
  }
}

extension BottomTabBarInteractor: BottomTabBarInteractorProtocol {
  func openSearch() {
    searchManager.isSearching ? searchManager.close() : searchManager.startSearching(isRouting: false)
  }

  func openMenu() {
    guard let state = controlsManager?.menuState else {
      fatalError("ERROR: Failed to retrieve the current MapViewControlsManager's state.")
    }
    switch state {
    case .inactive: controlsManager?.menuState = .active
    case .active: controlsManager?.menuState = .inactive
    case .hidden:
      // When the current controls manager's state is hidden, accidental taps on the menu button during the hiding animation should be skipped.
      break
    case .layers: fallthrough
    @unknown default: fatalError("ERROR: Unexpected MapViewControlsManager's state: \(state)")
    }
  }
}
