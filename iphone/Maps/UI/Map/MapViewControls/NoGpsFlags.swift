import AVFoundation

/// A flag of a test drive: the moment the tester saw the car shown wrong, with the car position, a screenshot of the
/// app and maybe a voice note.
struct NoGpsFlag: Codable, Equatable {
  /// The local time of the flag, yyyyMMdd-HHmmss: the name of its files.
  var name = ""
  /// FLAG N in the log.
  var number = 0
  var lat: Double?
  var lon: Double?
  /// The length of the voice note, 0 without one.
  var voiceS = 0
  var sent = false

  private enum CodingKeys: String, CodingKey {
    case number = "n"
    case lat
    case lon
    case voiceS = "voice_s"
    case sent
  }
}

/// The flags live in Documents/flags next to the logs: <name>.json, .png and .m4a. The settings send them by email.
enum NoGpsFlags {
  enum Constants {
    /// kFlagKeepDays: older flags are deleted at launch.
    static let keepDays = 7
    /// kFlagVoiceMaxS.
    static let voiceMaxS: TimeInterval = 15
    /// kFlagMailMaxMB: a mail server may refuse bigger attachments, the user is warned.
    static let mailMaxMB = 20
    static let json = "json"
    static let png = "png"
    static let voice = "m4a"
  }

  /// The file operations go one after another: the voice length is written after the flag.
  static let queue = DispatchQueue(label: "app.organicmaps.nogps.flags", qos: .utility)

  static var folder: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("flags")
  }

  static func url(_ name: String, _ ext: String) -> URL {
    folder.appendingPathComponent(name).appendingPathExtension(ext)
  }

  private static let nameFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }()

  static func name(of date: Date) -> String {
    nameFormatter.string(from: date)
  }

  static func date(of name: String) -> Date? {
    nameFormatter.date(from: name)
  }

  /// "dd-MM-yy" of the log file names, see Logger.
  static func logDay(of name: String) -> String {
    let digits = Array(name.prefix(8))
    guard digits.count == 8 else { return "" }
    return "\(String(digits[6 ..< 8]))-\(String(digits[4 ..< 6]))-\(String(digits[2 ..< 4]))"
  }

  /// "dd.MM.yy" for the mail subject.
  static func mailDay(of name: String) -> String {
    logDay(of: name).replacingOccurrences(of: "-", with: ".")
  }

  /// "HH:mm:ss" as the log tools take it.
  static func time(of name: String) -> String {
    let digits = Array(name.dropFirst(9).prefix(6))
    guard digits.count == 6 else { return "" }
    return "\(String(digits[0 ..< 2])):\(String(digits[2 ..< 4])):\(String(digits[4 ..< 6]))"
  }

  /// The log files of the days, all their parts and those of another phone id too: "log-dd-MM-yy-<phone>[.<part>].log".
  static func logFiles(_ files: [String], days: Set<String>) -> [String] {
    files.filter { file in file.hasSuffix(".log") && days.contains { file.hasPrefix("log-\($0)-") } }
  }

  static func isExpired(_ name: String, now: Date) -> Bool {
    guard let date = date(of: name) else { return false }
    return now.timeIntervalSince(date) > TimeInterval(Constants.keepDays * 24 * 60 * 60)
  }

  /// "FLAG N HH:mm:ss lat,lon voice 12 s": the mail body has one per flag.
  static func mailLine(_ flag: NoGpsFlag) -> String {
    var line = "FLAG \(flag.number) \(time(of: flag.name))"
    if let lat = flag.lat, let lon = flag.lon {
      line += String(format: " %.5f,%.5f", lat, lon)
    } else {
      line += " no position"
    }
    if flag.voiceS > 0 {
      line += " voice \(flag.voiceS) s"
    }
    return line
  }

  static func mailSubject(version: String, flags: [NoGpsFlag]) -> String {
    var days = [String]()
    for day in flags.map(\.name).sorted().map(mailDay) where !days.contains(day) {
      days.append(day)
    }
    return "[\(version)] Flags \(days.joined(separator: ", "))"
  }

  /// Oldest first, as the mail lists them.
  static func mailBody(_ flags: [NoGpsFlag]) -> String {
    flags.sorted { $0.name < $1.name }.map(mailLine).joined(separator: "\n")
  }

  // MARK: - Files

  /// Newest first.
  static func load() -> [NoGpsFlag] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return files.filter { $0.hasSuffix(".\(Constants.json)") }.sorted(by: >)
      .compactMap { load(String($0.dropLast(Constants.json.count + 1))) }
  }

  static func load(_ name: String) -> NoGpsFlag? {
    guard let data = try? Data(contentsOf: url(name, Constants.json)),
          var flag = try? JSONDecoder().decode(NoGpsFlag.self, from: data) else { return nil }
    flag.name = name
    return flag
  }

  static func save(_ flag: NoGpsFlag) {
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try JSONEncoder().encode(flag).write(to: url(flag.name, Constants.json), options: .atomic)
    } catch {
      LOG(.error, "Failed to save flag \(flag.name): \(error)")
    }
  }

  static func update(_ name: String, _ change: (inout NoGpsFlag) -> Void) {
    guard var flag = load(name) else { return }
    change(&flag)
    save(flag)
  }

  /// Saves a new flag on the queue.
  static func add(_ flag: NoGpsFlag, screenshot: UIImage?) {
    queue.async {
      save(flag)
      if let data = screenshot?.pngData() {
        try? data.write(to: url(flag.name, Constants.png), options: .atomic)
      }
    }
  }

  static func deleteExpired() {
    queue.async {
      let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
      let now = Date()
      for file in files where isExpired((file as NSString).deletingPathExtension, now: now) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
      }
    }
  }

  /// The screenshot and the voice note of the flags.
  static func attachments(_ flags: [NoGpsFlag]) -> [URL] {
    flags.flatMap { [url($0.name, Constants.png), url($0.name, Constants.voice)] }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }
}

/// Records the voice note of a flag after a tap of the voice flag button.
final class NoGpsFlagRecorder: NSObject {
  /// On the main thread when a recording is over, at kFlagVoiceMaxS too.
  var onFinish: (() -> Void)?
  private var recorder: AVAudioRecorder?
  private var name = ""
  private var start: CFTimeInterval = 0
  private var session: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                        options: AVAudioSession.CategoryOptions)?

  enum Permission {
    case granted
    case denied
    /// The system asks the user now.
    case asked
  }

  static func checkPermission() -> Permission {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return .granted
      case .denied: return .denied
      default:
        AVAudioApplication.requestRecordPermission { _ in }
        return .asked
      }
    }
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return .granted
    case .denied: return .denied
    default:
      AVAudioSession.sharedInstance().requestRecordPermission { _ in }
      return .asked
    }
  }

  var isRecording: Bool { recorder != nil }

  /// Records to the flag up to kFlagVoiceMaxS.
  func start(_ name: String) -> Bool {
    stop()
    // The voice prompts play in their own category: it comes back after the recording.
    let audio = AVAudioSession.sharedInstance()
    // A recording still finishing has not restored it yet.
    if session == nil {
      session = (audio.category, audio.mode, audio.categoryOptions)
    }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050,
                                   AVNumberOfChannelsKey: 1,
                                   AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
    do {
      // The phone microphone: a hands-free one would turn the car audio into a call.
      try audio.setCategory(.playAndRecord, mode: .default,
                            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
      try audio.setActive(true)
      try FileManager.default.createDirectory(at: NoGpsFlags.folder, withIntermediateDirectories: true)
      let recorder = try AVAudioRecorder(url: NoGpsFlags.url(name, NoGpsFlags.Constants.voice), settings: settings)
      recorder.delegate = self
      guard recorder.record(forDuration: NoGpsFlags.Constants.voiceMaxS) else {
        LOG(.error, "Failed to record the voice of flag \(name)")
        restoreSession()
        return false
      }
      self.recorder = recorder
      self.name = name
      start = CACurrentMediaTime()
      return true
    } catch {
      LOG(.error, "Failed to record the voice of flag \(name): \(error)")
      restoreSession()
      return false
    }
  }

  func stop() {
    recorder?.stop()
  }

  private func restoreSession() {
    guard let session else { return }
    try? AVAudioSession.sharedInstance().setCategory(session.category, mode: session.mode, options: session.options)
    self.session = nil
  }
}

extension NoGpsFlagRecorder: AVAudioRecorderDelegate {
  /// Also when kFlagVoiceMaxS is over.
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully _: Bool) {
    guard recorder === self.recorder else { return }
    self.recorder = nil
    restoreSession()
    let seconds = Int(min(CACurrentMediaTime() - start, NoGpsFlags.Constants.voiceMaxS).rounded())
    let name = name
    let url = recorder.url
    LOG(.info, "FLAG voice \(name) \(seconds) s")
    DispatchQueue.main.async { [weak self] in self?.onFinish?() }
    NoGpsFlags.queue.async {
      // A second tap right after the first has nothing to hear.
      guard seconds > 0 else {
        try? FileManager.default.removeItem(at: url)
        return
      }
      NoGpsFlags.update(name) { $0.voiceS = seconds }
    }
  }
}
