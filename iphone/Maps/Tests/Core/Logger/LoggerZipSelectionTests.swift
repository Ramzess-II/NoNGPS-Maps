import CoreApi
@testable import Organic_Maps__Debug_
import XCTest

/// The files of the flag-day zip: Logger.zipLogFiles(days:) takes the files of the days and the files a trip goes on
/// from, the same rules as LogFileNameTest.ofDays_* of Android. It makes the trees of two fake phones on the days of
/// 2095 to 2099 (never a day of a real trip) in the logs folder of the app, and reads the names of the entries of the
/// zip it gets.
final class LoggerZipSelectionTests: XCTestCase {
  private let phone = "ZipTestPhone-0001"
  private let otherPhone = "ZipTestPhone-0002"
  private let fullSize: UInt64 = 30_000_000
  /// A modification date before and after every faked time of a file name.
  private let early = Date(timeIntervalSince1970: 1)
  private let later = Date(timeIntervalSince1970: 7_000_000_000)
  private var logsFolder: URL!

  override func setUp() {
    super.setUp()
    logsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logs")
    removePhones()
  }

  override func tearDown() {
    removePhones()
    super.tearDown()
  }

  func testTakesEveryFileAndPhoneOfTheDays() throws {
    makeFile(phone, "2099-11-02", "081500.log")
    makeFile(phone, "2099-11-02", "173000.log")
    makeFile(otherPhone, "2099-11-02", "090000.log")
    makeFile(phone, "2099-11-01", "070000.log")
    makeFile(phone, "2099-11-03", "070000.log")

    XCTAssertEqual(try zipped(["2099-11-02"]), [
      "\(phone)/2099-11-02/081500.log", "\(phone)/2099-11-02/173000.log", "\(otherPhone)/2099-11-02/090000.log",
    ])
    XCTAssertEqual(try zipped(["2099-11-03", "2099-11-01"]), [
      "\(phone)/2099-11-01/070000.log", "\(phone)/2099-11-03/070000.log",
    ])
    // A day with no folder.
    XCTAssertNil(Logger.zipLogFiles(days: ["2099-10-31"]))
  }

  func testTakesTheFileATripGoesOnFrom() throws {
    for day in ["2099-11-01", "2099-11-02", "2099-11-03"] {
      makeFile(phone, day, "235907.log")
    }
    makeFile(phone, "2099-11-01", "081500.log")
    makeFile(phone, "2099-11-02", "081500.log")
    makeFile(otherPhone, "2099-11-01", "235907.log")

    // The trip started on the first and went on over two midnights: the day of its end takes its first file too.
    XCTAssertEqual(try zipped(["2099-11-03"]), [
      "\(phone)/2099-11-01/235907.log", "\(phone)/2099-11-02/235907.log", "\(phone)/2099-11-03/235907.log",
    ])
    // The day it started on has no file of the days before: only its own.
    XCTAssertEqual(try zipped(["2099-11-01"]), [
      "\(phone)/2099-11-01/081500.log", "\(phone)/2099-11-01/235907.log", "\(otherPhone)/2099-11-01/235907.log",
    ])
  }

  func testTakesTheFileATripGoesOnFromOverAMonthAndAYearEnd() throws {
    makeFile(phone, "2098-12-31", "230000.log")
    makeFile(phone, "2099-01-01", "230000.log")
    makeFile(phone, "2099-01-31", "220000.log")
    makeFile(phone, "2099-02-01", "220000.log")
    // 2096 is a leap year.
    makeFile(phone, "2096-02-29", "210000.log")
    makeFile(phone, "2096-03-01", "210000.log")

    XCTAssertEqual(try zipped(["2099-01-01"]), ["\(phone)/2098-12-31/230000.log", "\(phone)/2099-01-01/230000.log"])
    XCTAssertEqual(try zipped(["2099-02-01"]), ["\(phone)/2099-01-31/220000.log", "\(phone)/2099-02-01/220000.log"])
    XCTAssertEqual(try zipped(["2096-03-01"]), ["\(phone)/2096-02-29/210000.log", "\(phone)/2096-03-01/210000.log"])
  }

  func testDoesNotTakeAFileWhenTheDayBetweenIsMissing() throws {
    // The trip's file of the second day is gone: the third does not reach back to the first.
    makeFile(phone, "2099-11-01", "235907.log")
    makeFile(phone, "2099-11-03", "235907.log")

    XCTAssertEqual(try zipped(["2099-11-03"]), ["\(phone)/2099-11-03/235907.log"])
  }

  func testTakesTheFileOfADriveStartedInTheSameSecond() throws {
    // The second drive of the second is "-2" before midnight and goes on as the plain name after it.
    makeFile(phone, "2099-11-01", "235907.log")
    makeFile(phone, "2099-11-01", "235907-2.log")
    makeFile(phone, "2099-11-02", "235907.log")
    makeFile(phone, "2099-11-02", "081500.log")
    XCTAssertEqual(try zipped(["2099-11-02"]), [
      "\(phone)/2099-11-01/235907-2.log", "\(phone)/2099-11-01/235907.log", "\(phone)/2099-11-02/081500.log",
      "\(phone)/2099-11-02/235907.log",
    ])
    // The other way round: the drive of the plain name goes on as "-2".
    makeFile(phone, "2099-11-05", "100000.log")
    makeFile(phone, "2099-11-06", "100000-2.log")
    XCTAssertEqual(try zipped(["2099-11-06"]), ["\(phone)/2099-11-05/100000.log", "\(phone)/2099-11-06/100000-2.log"])
    // Another time is not the same drive.
    XCTAssertFalse(try zipped(["2099-11-06"]).contains("\(phone)/2099-11-01/235907.log"))
  }

  func testTakesTheFilesATripSplitBySizeGoesOnFrom() throws {
    // Started at 19:00, split by size at 23:30, went on after midnight under the name of the second file.
    makeFile(phone, "2099-11-01", "190000.log", size: fullSize, modified: later)
    makeFile(phone, "2099-11-01", "233000.log", size: fullSize, modified: later)
    makeFile(phone, "2099-11-02", "233000.log")
    // A short file before it is another trip, and so is the one after the chain.
    makeFile(phone, "2099-11-01", "080000.log")
    makeFile(phone, "2099-11-02", "090000.log")
    XCTAssertEqual(try zipped(["2099-11-02"]), [
      "\(phone)/2099-11-01/190000.log", "\(phone)/2099-11-01/233000.log", "\(phone)/2099-11-02/090000.log",
      "\(phone)/2099-11-02/233000.log",
    ])
    // A full file of another phone does not go on into this one.
    makeFile(otherPhone, "2099-11-01", "200000.log", size: fullSize, modified: later)
    XCTAssertFalse(try zipped(["2099-11-02"]).contains("\(otherPhone)/2099-11-01/200000.log"))
    // The last file of a phone has nothing to go on into.
    XCTAssertNil(Logger.zipLogFiles(days: ["2099-11-03"]))
  }

  func testDoesNotTakeAnotherTripAfterAFullAfterMidnightPart() throws {
    // Started at 21:00 on the first, full at 04:30 on the second: the split file is named by a time of the second.
    makeFile(phone, "2099-11-01", "210000.log")
    makeFile(phone, "2099-11-02", "043000.log")
    makeFile(phone, "2099-11-02", "210000.log", size: fullSize, modified: early)
    makeFile(phone, "2099-11-03", "080000.log")
    XCTAssertEqual(try zipped(["2099-11-03"]), ["\(phone)/2099-11-03/080000.log"])
    // The day of the part takes the file it began in, and the first file of its day, where it goes on.
    XCTAssertEqual(try zipped(["2099-11-02"]), [
      "\(phone)/2099-11-01/210000.log", "\(phone)/2099-11-02/043000.log", "\(phone)/2099-11-02/210000.log",
    ])
  }

  // MARK: - Helpers

  /// The paths of the files of the two test phones in the zip of the days, without "logs/", sorted.
  private func zipped(_ days: Set<String>) throws -> [String] {
    let url = try XCTUnwrap(Logger.zipLogFiles(days: days))
    defer { try? FileManager.default.removeItem(at: url) }
    return try zipEntryNames(Data(contentsOf: url))
      .filter { $0.hasPrefix("logs/" + phone) || $0.hasPrefix("logs/" + otherPhone) }
      .map { String($0.dropFirst("logs/".count)) }.sorted()
  }

  /// The entry names of the central directory of a zip.
  private func zipEntryNames(_ zip: Data) throws -> [String] {
    func u16(_ at: Int) -> Int { Int(zip[zip.startIndex + at]) | Int(zip[zip.startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    var end = zip.count - 22
    while end >= 0, u32(end) != 0x0605_4B50 {
      end -= 1
    }
    XCTAssertGreaterThanOrEqual(end, 0, "no end of central directory")
    guard end >= 0 else { return [] }
    var names: [String] = []
    var at = u32(end + 16)
    for _ in 0 ..< u16(end + 10) {
      XCTAssertEqual(u32(at), 0x0201_4B50)
      let length = u16(at + 28)
      let start = zip.startIndex + at + 46
      names.append(String(decoding: zip[start ..< start + length], as: UTF8.self))
      at += 46 + length + u16(at + 30) + u16(at + 32)
    }
    return names
  }

  private func makeFile(_ phone: String, _ day: String, _ name: String, size: UInt64 = 10, modified: Date? = nil) {
    let file = logsFolder.appendingPathComponent(phone).appendingPathComponent(day).appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: file.path, contents: nil)
    if let handle = try? FileHandle(forWritingTo: file) {
      // A sparse file: a full one costs no disk.
      try? handle.truncate(atOffset: size)
      try? handle.close()
    }
    try? FileManager.default.setAttributes([.modificationDate: modified ?? early], ofItemAtPath: file.path)
  }

  private func removePhones() {
    for phone in [phone, otherPhone] {
      try? FileManager.default.removeItem(at: logsFolder.appendingPathComponent(phone))
    }
  }
}
