final class NavigationTurnsView: UIView {
  override var placePageAreaAffectDirections: MWMAvailableAreaAffectDirections { alternative(iPhone: [], iPad: .left) }

  /// The panel of buttons at the same edge doesn't go under the turns.
  override var isHidden: Bool {
    didSet { reportBottom() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    reportBottom()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    reportBottom()
  }

  private func reportBottom() {
    NoGpsControls.updateTurnsBottom(window == nil || isHidden ? 0 : convert(bounds, to: nil).maxY)
  }
}
