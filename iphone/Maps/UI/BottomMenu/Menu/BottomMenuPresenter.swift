protocol BottomMenuPresenterProtocol: UITableViewDelegate, UITableViewDataSource {
  func onClosePressed()
  func cellToHighlightIndexPath() -> IndexPath?
}

class BottomMenuPresenter: NSObject {
  /// In the order the sheet shows them, see groups below.
  enum CellType: Int, CaseIterable {
    case profile
    case settings
    case share
    case bookmarks
    case downloadMaps
    case recordTrack
    case addPlace
    case about
    case aboutOrganicMaps
    case buyBox
    case donate
  }

  /// What the driver taps on a trip stays apart from what is set up once. The map styles cell above is the first
  /// group; the first cell of every other group draws a line above itself. Mirrors MainMenuItems on Android.
  private static let groups: [[CellType]] = [
    [.profile, .settings, .share],
    [.bookmarks, .downloadMaps, .recordTrack, .addPlace],
    [.about, .aboutOrganicMaps, .buyBox, .donate],
  ]

  enum Sections: Int {
    case layers
    case items
  }

  private weak var view: BottomMenuViewProtocol?
  private let interactor: BottomMenuInteractorProtocol
  private let sections: [Sections]
  /// Internal, not private, so BottomMenuPresenterTests can check the order of the rows.
  let menuCells: [CellType]
  /// The rows of menuCells that start a group.
  let groupStarts: Set<Int>
  private let trackRecorder = TrackRecordingManager.shared
  private let mapsStorage: Storage
  private let countryId: String?
  private let shouldUpdateMapToContribute: Bool

  init(view: BottomMenuViewProtocol,
       interactor: BottomMenuInteractorProtocol,
       sections: [Sections]) {
    self.view = view
    self.interactor = interactor
    self.sections = sections
    let disableDonate = Settings.donateUrl() == nil
    var cells: [CellType] = []
    var starts: Set<Int> = []
    for (index, group) in Self.groups.enumerated() {
      let rows = disableDonate ? group.filter { $0 != .donate } : group
      guard !rows.isEmpty else { continue }
      // The map styles cell draws a line under itself, so the first group needs none of its own.
      if index > 0 {
        starts.insert(cells.count)
      }
      cells.append(contentsOf: rows)
    }
    menuCells = cells
    groupStarts = starts
    let mapsStorage = Storage.shared()
    self.mapsStorage = mapsStorage
    countryId = mapsStorage.countryForViewportCenter()
    shouldUpdateMapToContribute =
      !(MWMNavigationDashboardManager.shared().state == .closed &&
        FrameworkHelper.canEditMapAtViewportCenter() &&
        countryId != nil)
    super.init()
  }

  private static func getCellToHighlight() -> CellType? {
    let featureToHighlightData = DeepLinkHandler.shared.getInAppFeatureHighlightData()
    guard let featureToHighlightData, featureToHighlightData.urlType == .menu else { return nil }
    switch featureToHighlightData.feature {
    case .trackRecorder: return .recordTrack
    default: return nil
    }
  }
}

extension BottomMenuPresenter: BottomMenuPresenterProtocol {
  func onClosePressed() {
    interactor.close()
  }

  func cellToHighlightIndexPath() -> IndexPath? {
    // Highlighting is enabled only for the .items section.
    guard let sectionIndex = sections.firstIndex(of: .items),
          let cellToHighlight = Self.getCellToHighlight(),
          let cellIndex = menuCells.firstIndex(of: cellToHighlight) else { return nil }
    return IndexPath(row: cellIndex, section: sectionIndex)
  }
}

// MARK: - - UITableViewDataSource

extension BottomMenuPresenter {
  func numberOfSections(in _: UITableView) -> Int {
    sections.count
  }

  func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch sections[section] {
    case .layers:
      return 1
    case .items:
      return menuCells.count
    }
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    switch sections[indexPath.section] {
    case .layers:
      let cell = tableView.dequeueReusableCell(cell: BottomMenuLayersCell.self)!
      cell.onClose = { [weak self] in self?.onClosePressed() }
      if sections.count > 1 {
        cell.addSeparator(.bottom)
      }
      return cell
    case .items:
      let cell = tableView.dequeueReusableCell(cell: BottomMenuItemCell.self)!
      cell.setStartsGroup(groupStarts.contains(indexPath.row))
      switch menuCells[indexPath.row] {
      case .profile:
        cell.configure(image: UIImage(systemName: "person.crop.circle")!, title: L("nogps_menu_profile"))
      case .bookmarks:
        cell.configure(image: UIImage(resource: .icMenuBookmarkList), title: L("bookmarks"))
      case .addPlace:
        cell.configure(image: shouldUpdateMapToContribute ? UIImage(resource: .icMenuAddPlaceExclamation) : UIImage(resource: .icMenuAddPlace),
                       title: L("placepage_add_place_button"),
                       enabled: countryId != nil)
      case .recordTrack:
        switch trackRecorder.recordingState {
        case .inactive:
          cell.configure(image: UIImage(resource: .icMenuTrackRecording), title: L("start_track_recording"))
        case .active:
          cell.configure(image: UIImage(resource: .icMenuTrackRecording), title: L("stop_track_recording"), imageStyle: .red)
        }
        return cell
      case .downloadMaps:
        cell.configure(image: UIImage(resource: .icMenuDownload),
                       title: L("download_maps"),
                       badgeCount: MapsAppDelegate.theApp().badgeNumber())
      case .donate:
        cell.configure(image: Settings.isNY() ? UIImage(resource: .icChristmasTree) : UIImage(resource: .icMenuDonate),
                       title: L("donate"))
      case .settings:
        cell.configure(image: UIImage(resource: .icMenuSettings),
                       title: L("settings"))
      case .share:
        cell.configure(image: UIImage(resource: .icMenuShare),
                       title: L("share_my_location"))
      case .about:
        cell.configure(image: UIImage(systemName: "info.circle")!, title: L("nogps_about_title"))
      case .aboutOrganicMaps:
        cell.configure(image: UIImage(resource: .icMenuQuestion), title: L("nogps_about_om_menu"))
      case .buyBox:
        cell.configure(image: UIImage(systemName: "cart")!, title: L("nogps_box_buy"))
      }
      return cell
    }
  }
}

// MARK: - - UITableViewDelegate

extension BottomMenuPresenter {
  func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
    if let cell = tableView.cellForRow(at: indexPath) as? BottomMenuItemCell {
      return cell.isEnabled ? indexPath : nil
    }
    return indexPath
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch sections[indexPath.section] {
    case .layers:
      return;
    case .items:
      switch menuCells[indexPath.row] {
      case .profile:
        interactor.openProfile()
      case .bookmarks:
        interactor.openBookmarks()
      case .addPlace:
        if shouldUpdateMapToContribute {
          guard let countryId else {
            fatalError("Add place button should be disabled when there is no country")
          }
          let countryName = mapsStorage.name(forCountry: countryId)
          MWMAlertViewController.activeAlert().presentDefaultAlert(
            withTitle: L("contribute_to_osm_update_map"),
            message: String(format: L("contribute_to_osm_update_map_description"), countryName),
            rightButtonTitle: L("download"),
            leftButtonTitle: L("cancel")
          ) { [weak self] in
            self?.interactor.startDownloadingMapForCountry(countryId)
          }
        } else {
          interactor.addPlace()
        }
      case .recordTrack:
        interactor.toggleTrackRecording()
      case .downloadMaps:
        interactor.downloadMaps()
      case .donate:
        interactor.donate()
      case .settings:
        interactor.openSettings()
      case .share:
        if let cell = tableView.cellForRow(at: indexPath) as? BottomMenuItemCell {
          interactor.shareLocation(cell: cell)
        }
      case .about:
        interactor.openAbout()
      case .aboutOrganicMaps:
        interactor.openAboutOrganicMaps()
      case .buyBox:
        interactor.buyBox()
      }
    }
  }
}
