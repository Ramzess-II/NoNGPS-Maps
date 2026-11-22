/// The pages of the project the app sends the user to: the shop of the Box sheet, of the intro of the first start and
/// of the main menu, the video of the intro, the account, the sources and the project the app is based on. There is no
/// video and no account screen yet, so both point at the site; each is the single line to change when there is one.
enum NoGpsLinks {
  static let shop = URL(string: "https://non-gps.com")!
  static let video = URL(string: "https://non-gps.com")!
  static let account = URL(string: "https://non-gps.com")!
  static let sourceCode = URL(string: "https://github.com/Ramzess-II/NoNGPS-Maps")!
  static let organicMaps = URL(string: "https://organicmaps.app")!
}
