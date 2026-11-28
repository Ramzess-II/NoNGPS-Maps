@testable import Organic_Maps__Debug_
import XCTest

final class BottomMenuPresenterTests: XCTestCase {
  private final class MockBottomMenuView: BottomMenuViewProtocol {
    var presenter: BottomMenuPresenterProtocol?
  }

  private final class MockBottomMenuInteractor: BottomMenuInteractorProtocol {
    func close() {}
    func addPlace() {}
    func downloadMaps() {}
    func startDownloadingMapForCountry(_: String) {}
    func donate() {}
    func openSettings() {}
    func openBookmarks() {}
    func openProfile() {}
    func openMapTools() {}
    func openHowItWorks() {}
    func openAbout() {}
    func openAboutOrganicMaps() {}
    func buyBox() {}
    func shareLocation(cell _: BottomMenuItemCell) {}
    func toggleTrackRecording() {}
  }

  private func makePresenter(sections: [BottomMenuPresenter.Sections] = [.layers, .items]) -> BottomMenuPresenter {
    BottomMenuPresenter(view: MockBottomMenuView(),
                        interactor: MockBottomMenuInteractor(),
                        sections: sections)
  }

  /// Donate shows only when a donate URL is configured; the fork configures none.
  private var expectedCells: [BottomMenuPresenter.CellType] {
    var cells: [BottomMenuPresenter.CellType] = [.profile, .settings, .mapTools,
                                                 .howItWorks, .about, .aboutOrganicMaps, .buyBox]
    if Settings.donateUrl() != nil {
      cells.append(.donate)
    }
    return cells
  }

  func testThreeGroupsUnderTheMapStyles() {
    let presenter = makePresenter()
    XCTAssertEqual(presenter.menuCells, expectedCells)
    XCTAssertEqual(presenter.tableView(UITableView(), numberOfRowsInSection: 1), expectedCells.count)
    XCTAssertEqual(presenter.tableView(UITableView(), numberOfRowsInSection: 0), 1)
    XCTAssertEqual(presenter.numberOfSections(in: UITableView()), 2)
  }

  /// How NonGPS works opens a group; Profile sits under the line of the map styles cell, and Map tools stays in its
  /// group with Settings.
  func testGroupStartsAtHowItWorks() {
    let presenter = makePresenter()
    let starts = presenter.groupStarts.sorted().map { presenter.menuCells[$0] }
    XCTAssertEqual(starts, [.howItWorks])
  }

  func testMapToolsSheetHoldsTheOrganicMapsTools() {
    let presenter = makePresenter(sections: [.mapTools])
    XCTAssertEqual(presenter.menuCells, [.share, .bookmarks, .downloadMaps, .recordTrack, .addPlace])
    XCTAssertTrue(presenter.groupStarts.isEmpty)
    XCTAssertEqual(presenter.numberOfSections(in: UITableView()), 1)
    XCTAssertEqual(presenter.tableView(UITableView(), numberOfRowsInSection: 0), 5)
  }

  /// cellToHighlightIndexPath() looks the cell up in menuCells, so the order decides the row it points at.
  func testRecordTrackCanBeHighlightedInTheMapToolsSheet() {
    let presenter = makePresenter(sections: [.mapTools])
    XCTAssertEqual(presenter.menuCells.firstIndex(of: .recordTrack), 3)
    // Without a pending menu deep link nothing is highlighted.
    XCTAssertNil(presenter.cellToHighlightIndexPath())
    XCTAssertFalse(BottomMenuPresenter.pendingHighlightIsInMapTools)
  }
}
