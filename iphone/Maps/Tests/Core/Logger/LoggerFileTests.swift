import CoreApi
@testable import Organic_Maps__Debug_
import XCTest

/// The file writer of Logger: the file of a launch, startTrip, midnight and concurrent lines. It drives the files of
/// the faked days 2099-01-01 and 2099-01-02 (never a day of a real trip) in the logs folder of the app, which it
/// removes.
/// The app keeps logging through the same Logger, so the tests look only at the files that hold their marker lines.
final class LoggerFileTests: XCTestCase {
  private let marker = "LoggerFileTests"
  private var now = Date()
  private let clockLock = NSLock()
  private var logsFolder: URL!
  private var enabledByTest = false

  override func setUp() {
    super.setUp()
    logsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logs")
    Logger.setClockForTesting { [unowned self] in
      clockLock.lock()
      defer { clockLock.unlock() }
      return now
    }
    setTime(2099, 1, 1, 12, 0, 0)
    // Turning logging off removes every log of the app, those of a phone with a recorded trip too: only turn it on,
    // and off again at the end only if it was off.
    enabledByTest = !Settings.isFileLoggingEnabled()
    if enabledByTest {
      Logger.setFileLoggingEnabled(true)
    }
    // A file of the app may be open: unlink the faked days first, then close it, so no line of the tests goes into an
    // unlinked file. The first line of a test opens the file under test.
    removeFakeDays()
    Logger.startTrip()
  }

  override func tearDown() {
    // The real clock first: a line the app logs after startTrip must not open a file under the faked clock, whose
    // 2099 day the writer would then never leave.
    Logger.setClockForTesting(nil)
    Logger.startTrip()
    removeFakeDays()
    if enabledByTest {
      Logger.setFileLoggingEnabled(false)
    }
    super.tearDown()
  }

  func testFirstLineGoesToAFileOfTheLaunchWithTheHeader() throws {
    Logger.log(.info, message: "\(marker) one")
    Logger.log(.info, message: "\(marker) two")

    let files = logFiles()
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files[0].lastPathComponent, "120000.log")
    XCTAssertEqual(files[0].deletingLastPathComponent().lastPathComponent, "2099-01-01")
    let lines = try lines(of: files[0])
    XCTAssertTrue(lines[0].hasPrefix("LOGFMT 2 "), lines[0])
    XCTAssertEqual(markerLines(lines).count, 2)
  }

  func testStartTripPutsTheLinesAfterItInANewFile() throws {
    Logger.log(.info, message: "\(marker) drive 1")
    setTime(2099, 1, 1, 12, 0, 5)
    Logger.startTrip()
    Logger.log(.info, message: "\(marker) drive 2")

    let files = logFiles()
    XCTAssertEqual(files.map(\.lastPathComponent), ["120000.log", "120005.log"])
    XCTAssertEqual(try markerLines(lines(of: files[0])).map { $0.suffix(7) }, ["drive 1"])
    XCTAssertEqual(try markerLines(lines(of: files[1])).map { $0.suffix(7) }, ["drive 2"])
    XCTAssertTrue(try lines(of: files[1])[0].hasPrefix("LOGFMT 2 "))
  }

  func testStartTripInTheSameSecondTakesAFreeName() {
    Logger.log(.info, message: "\(marker) drive 1")
    Logger.startTrip()
    Logger.log(.info, message: "\(marker) drive 2")

    XCTAssertEqual(logFiles().map(\.lastPathComponent), ["120000-2.log", "120000.log"])
  }

  func testStartTripNamesTheFileAfterItsFirstLine() {
    Logger.log(.info, message: "\(marker) drive 1")
    // The clock moves before startTrip: a line of the app between the two would open the file at the trip's time.
    setTime(2099, 1, 1, 12, 0, 20)
    Logger.startTrip()
    Logger.log(.info, message: "\(marker) drive 2")

    XCTAssertEqual(logFiles().map(\.lastPathComponent), ["120000.log", "120020.log"])
  }

  func testMidnightContinuesTheFileInTheFolderOfTheNextDay() throws {
    setTime(2099, 1, 1, 23, 59, 50)
    // A line of the app after setUp may have opened a file at 12:00:00: close it, so the next line opens at 23:59:50.
    Logger.startTrip()
    Logger.log(.info, message: "\(marker) before")
    setTime(2099, 1, 2, 0, 0, 5)
    Logger.log(.info, message: "\(marker) after")
    Logger.log(.info, message: "\(marker) after too")

    let files = logFiles()
    let names = files.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent }
    XCTAssertEqual(names, ["2099-01-01/235950.log", "2099-01-02/235950.log"])
    XCTAssertEqual(try markerLines(lines(of: files[0])).count, 1)
    XCTAssertEqual(try markerLines(lines(of: files[1])).count, 2)
    // The file of the next day is a file of its own: it begins with the header.
    XCTAssertTrue(try lines(of: files[1])[0].hasPrefix("LOGFMT 2 "))
  }

  func testConcurrentLinesStayWhole() throws {
    let threads = 8
    let perThread = 200
    DispatchQueue.concurrentPerform(iterations: threads) { id in
      for i in 0 ..< perThread {
        Logger.log(.info, message: "\(marker) line \(id) \(i) end")
      }
    }
    _ = Logger.getLogFileSize() // On the queue of the writer: the lines before it are written.

    let files = logFiles()
    XCTAssertEqual(files.count, 1)
    let lines = try markerLines(lines(of: files[0]))
    XCTAssertEqual(lines.count, threads * perThread)
    var seen = Set<String>()
    for line in lines {
      let parts = line.components(separatedBy: " ")
      let tail = parts.suffix(5)
      XCTAssertEqual(tail.count, 5, line)
      XCTAssertEqual(tail.first, marker, line)
      XCTAssertEqual(tail.last, "end", line)
      XCTAssertTrue(seen.insert(tail.joined(separator: " ")).inserted, line)
    }
  }

  // MARK: - Helpers

  private func setTime(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) {
    let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour,
                                                          minute: minute, second: second))!
    clockLock.lock()
    now = date
    clockLock.unlock()
  }

  /// The log files of the faked days that hold a marker line, sorted by their paths. A foreign line of the app may
  /// open a file of its own under the faked clock: it has no marker line.
  private func logFiles() -> [URL] {
    _ = Logger.getLogFileSize() // On the queue of the writer: the lines before it are written.
    return fakeDayFiles().filter { file in
      file.pathExtension == "log" && ((try? lines(of: file)) ?? []).contains { $0.contains(marker) }
    }
  }

  /// Everything under the logs folder that lies in a folder of a faked day, folders included.
  private func fakeDayFiles() -> [URL] {
    guard let paths = FileManager.default.subpaths(atPath: logsFolder.path) else { return [] }
    return paths.sorted().filter { path in fakeDays.contains { path.contains("/" + $0 + "/") || path.hasSuffix("/" + $0) } }
      .map { logsFolder.appendingPathComponent($0) }
  }

  private let fakeDays = ["2099-01-01", "2099-01-02"]

  private func removeFakeDays() {
    guard let paths = FileManager.default.subpaths(atPath: logsFolder.path) else { return }
    for path in paths where fakeDays.contains(where: { path.hasSuffix("/" + $0) }) {
      try? FileManager.default.removeItem(at: logsFolder.appendingPathComponent(path))
    }
  }

  private func lines(of file: URL) throws -> [String] {
    try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  private func markerLines(_ lines: [String]) -> [String] {
    lines.filter { $0.contains(marker) && !$0.hasPrefix("LOGFMT") }
  }
}
