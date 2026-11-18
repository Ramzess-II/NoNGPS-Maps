import StoreKit

@objcMembers
final class RateUsManager: NSObject {
  static let shared = RateUsManager()

  func showAppStoreReviewRequest() {
    UIApplication.shared.rateApp()
  }

  func showSKStoreReviewRequest() {
    guard MapViewController.shared()!.isMapFullyVisible(),
          !CarPlayService.shared.isCarplayActivated,
          FrameworkHelper.canShowRateUsRequest(),
          SKStoreReviewController.requestReviewInCurrentScene() else { return }
    FrameworkHelper.didShowRateUsRequest()
  }
}

private extension SKStoreReviewController {
  /// Returns false when there is no active scene to show the request in.
  static func requestReviewInCurrentScene() -> Bool {
    guard let scene = UIApplication.shared.foregroundActiveScene else {
      LOG(.warning, "Attempt to display SKStoreReviewController in a non-active scene.")
      return false
    }
    requestReview(in: scene)
    return true
  }
}
