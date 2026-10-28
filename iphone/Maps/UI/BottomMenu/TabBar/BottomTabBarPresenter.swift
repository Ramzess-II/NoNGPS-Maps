protocol BottomTabBarPresenterProtocol: AnyObject {
  func onSearchButtonPressed()
  func onMenuButtonPressed()
}

class BottomTabBarPresenter: NSObject {
  private let interactor: BottomTabBarInteractorProtocol

  init(interactor: BottomTabBarInteractorProtocol) {
    self.interactor = interactor
  }
}

extension BottomTabBarPresenter: BottomTabBarPresenterProtocol {
  func onSearchButtonPressed() {
    interactor.openSearch()
  }

  func onMenuButtonPressed() {
    interactor.openMenu()
  }
}
