import CoreApi
@testable import Organic_Maps__Debug_
import XCTest

/// The file writer of Logger: the file of a launch, startTrip, midnight and concurrent lines. It drives the files in
/// the logs folder of the app, which it removes: run it on a simulator.
final class LoggerFileTests: XCTestCase {
  private let marker = "LoggerFileTests"
  private var now = Date()
  private let clockLock = NSLock()
  private var logsFolder: URL!

  override func setUp() {
    super.setUp()
    logsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logs")
    Logger.setFileLoggingEnabled(false)
    Logger.setClockForTesting { [unowned self] in
      clockLock.lock()
      defer { clockLock.unlock() }
      return now
    }
    setTime(2026, 11, 1, 12, 0, 0)
    Logger.setFileLoggingEnabled(true)
    // Enabling opens a file at once: drop it, the first line of a test opens the file under test.
    Logger.startTrip()
    try? FileManager.default.removeItem(at: logsFolder)
  }

  override func tearDown() {
    Logger.setFileLoggingEnabled(false)
    Logger.setClockForTesting(nil)
    super.tearDown()
  }

  func testFirstLineGoesToAFileOfTheLaunchWithTheHeader() throws {
    Logger.log(.info, message: "\(marker) one")
    Logger.log(.info, message: "\(marker) two")

    let files = logFiles()
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files[0].lastPathComponent, "120000.log")
    XCTAssertEqual(files[0].deletingLastPathComponent().lastPathComponent, "2026-11-01")
    let lines = try lines(of: files[0])
    XCTAssertTrue(lines[0].hasPrefix("LOGFMT 2 "), lines[0])
    XCTAssertEqual(markerLines(lines).count, 2)
  }

  func testStartTripPutsTheLinesAfterItInANewFile() throws {
    Logger.log(.info, message: "\(marker) drive 1")
    setTime(2026, 11, 1, 12, 0, 5)
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

  func testStartTripWithoutLinesOpensNoFileAtOnce() {
    Logger.startTrip()
    XCTAssertTrue(logFiles().isEmpty)
  }

  func testMidnightContinuesTheFileInTheFolderOfTheNextDay() throws {
    setTime(2026, 11, 1, 23, 59, 50)
    Logger.log(.info, message: "\(marker) before")
    setTime(2026, 11, 2, 0, 0, 5)
    Logger.log(.info, message: "\(marker) after")
    Logger.log(.info, message: "\(marker) after too")

    let files = logFiles()
    let names = files.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent }
    XCTAssertEqual(names, ["2026-11-01/235950.log", "2026-11-02/235950.log"])
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

  /// The log files under the logs folder, sorted by their paths.
  private func logFiles() -> [URL] {
    guard let paths = FileManager.default.subpaths(atPath: logsFolder.path) else { return [] }
    return paths.sorted().map { logsFolder.appendingPathComponent($0) }.filter {
      $0.pathExtension == "log"
    }
  }

  private func lines(of file: URL) throws -> [String] {
    try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  private func markerLines(_ lines: [String]) -> [String] {
    lines.filter { $0.contains(marker) && !$0.hasPrefix("LOGFMT") }
  }
}
