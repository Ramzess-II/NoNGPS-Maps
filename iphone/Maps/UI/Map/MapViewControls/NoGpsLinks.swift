/// The pages about the sensor box the app sends the user to: the shop of the Box sheet and of the intro of the first
/// start, and the video of the intro. There is no video yet, so both point at the site; `video` is the single line to
/// change when there is one.
enum NoGpsLinks {
  static let shop = URL(string: "https://non-gps.com")!
  static let video = URL(string: "https://non-gps.com")!
}
