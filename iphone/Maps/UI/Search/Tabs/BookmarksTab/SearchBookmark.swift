struct SearchBookmark: Equatable {
  let id: MWMMarkID
  let name: String
  let listName: String
  let color: UIColor
  let iconName: String
  let mercatorPoint: CGPoint
  let distance: CLLocationDistance?

  func image(size: CGFloat) -> UIImage {
    // The glyph keeps the proportions of the Bookmarks list: a 3pt inset in a 22pt circle.
    circleImageForColor(color, frameSize: size, iconName: iconName, iconInset: size * 3 / 22)
  }
}

enum SearchBookmarks {
  /// The bookmarks of the first list in the Bookmarks screen order, in that list's order.
  static func firstList(manager: BookmarksManager = .shared(),
                        location: CLLocation? = LocationManager.lastLocation()) -> [SearchBookmark] {
    guard let group = manager.sortedUserCategories().first else { return [] }
    return makeBookmarks(group, location: location)
  }

  /// The bookmarks of all user lists, nearest first.
  static func all(manager: BookmarksManager = .shared(),
                  location: CLLocation? = LocationManager.lastLocation()) -> [SearchBookmark] {
    sorted(manager.sortedUserCategories().flatMap { makeBookmarks($0, location: location) })
  }

  /// Nearest first; by name when the position is unknown or the distances are equal.
  static func sorted(_ bookmarks: [SearchBookmark]) -> [SearchBookmark] {
    bookmarks.sorted { lhs, rhs in
      if let lhsDistance = lhs.distance, let rhsDistance = rhs.distance, lhsDistance != rhsDistance {
        return lhsDistance < rhsDistance
      }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  private static func makeBookmarks(_ group: BookmarkGroup, location: CLLocation?) -> [SearchBookmark] {
    group.bookmarks.map { bookmark in
      let coordinate = bookmark.locationCoordinate
      let distance = location?.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
      return SearchBookmark(id: bookmark.bookmarkId,
                            name: bookmark.bookmarkName,
                            listName: group.title,
                            color: bookmark.bookmarkColor,
                            iconName: bookmark.bookmarkIconName,
                            mercatorPoint: bookmark.mercatorPoint,
                            distance: distance)
    }
  }
}
