import CoreBluetooth
import UIKit

/// The Bluetooth LE connection to the NoGPS ESP32 sensor box for the navigation without GPS in the core: the core talks
/// to the box, this class searches the box by its service, connects, subscribes to its lines and passes the received
/// bytes back on the main queue. It keeps doing it until closed: the box switches its radio off while the car is parked.
/// The service and the pairing are described in docs/nogps/esp32-firmware-spec.md, section 17.
///
/// It works in the background too (bluetooth-central in Info.plist): iOS wakes the app up for the events of the box.
///
/// iOS doesn't tell an app if a device is paired, and pairs by itself when the box asks for it. So the boxes that have
/// sent data are remembered as the paired ones, and a new box is connected only while it accepts a new phone. A box
/// with phones that doesn't is tried once when the user adds a car, or has none and didn't forget this box: the
/// system may still pair it.
@objc
final class Esp32BleTransport: NSObject {
  private enum Constants {
    static let service = CBUUID(string: "02CB0001-C0C3-40D0-819C-5A85998DCD99")
    /// The lines of the box, notified.
    static let tx = CBUUID(string: "02CB0002-C0C3-40D0-819C-5A85998DCD99")
    /// The commands to the box.
    static let rx = CBUUID(string: "02CB0003-C0C3-40D0-819C-5A85998DCD99")
    /// The pieces of a new firmware of the box, section 18 of the same document.
    static let ota = CBUUID(string: "02CB0004-C0C3-40D0-819C-5A85998DCD99")
    // The box tells in its advertisement if it accepts a new phone now: company 0xFFFF, format version, flags.
    static let manufacturerId: [UInt8] = [0xFF, 0xFF]
    static let pairingOpenFlag: UInt8 = 1
    static let fullFlag: UInt8 = 1 << 1
    static let hasPhonesFlag: UInt8 = 1 << 2
    static let knownBoxesKey = "NoGpsKnownBoxes"
    // The boxes of the cars the user has forgotten: still paired, they are not connected until the user adds the car.
    static let forgottenBoxesKey = "NoGpsForgottenBoxes"
    // The name of the box is NonGPS-XXXX; the boxes that are not updated still say NoGPS-XXXX.
    static let namePrefixes = ["NonGPS-", "NoGPS-"]
    static let retryDelay: TimeInterval = 2
    // A box that is found but can't be connected and subscribed to is tried less and less often, e.g. the user has
    // refused to pair with it. One that was is tried again soon: after a parking, the first connections may stay
    // silent (October 31, three times in a row).
    static let maxRetryDelay: TimeInterval = 60
    // From the connection to the first data: iOS tries to connect forever, the box may have gone since it was found, and
    // a step may wait for a callback that never comes. Not in the background: the timer doesn't run while the app is
    // suspended and fires late, when the app is woken up, maybe by this connection made. On October 31 it cancelled
    // the connection 3 s after the box was back from a parking.
    static let connectWatchdog: TimeInterval = 20
    // A new box: the user enters the code meanwhile.
    static let pairingWatchdog: TimeInterval = 60
    // The box tells in every advertisement that it doesn't accept a new phone. Without them it has gone, e.g. it was a
    // box of the neighbours.
    static let pairingClosedTimeout: TimeInterval = 10
    // A known box that connects but sends nothing again and again has forgotten the phone (BLE-15). After a parking up
    // to 3 connections in a row stay silent, the next one works (#154).
    static let maxSilentConnections = 6
    // Silent connections further apart are not counted together: the box has slept in between.
    static let silentConnectionsGap: TimeInterval = 180
    // A shorter connection was lost by the radio, it is not counted: the box asks for the encryption 1.5 s after the
    // connection, a refused one lasts longer.
    static let minSilentLink: TimeInterval = 3
    // A new box waits this long for a paired one to be found: both may be near.
    static let newBoxDelay: TimeInterval = 3
    // The box of another car waits this long for the box of the current car: both may be near, e.g. two cars in the
    // yard with their engines just stopped.
    static let otherCarDelay: TimeInterval = 3
    // A box is near while its advertisement was seen this recently, see isBoxNearby().
    static let nearbyTimeout: TimeInterval = 60
    // A paired box answers HELLO at once over an encrypted connection. One that stays silent is connected again: the
    // connection has stayed unencrypted, and the box would drop it only after 60 s (October 13, three times in a row).
    static let silenceTimeout: TimeInterval = 5
    // The box doesn't answer the commands, a few of them wait for the previous one to leave at most.
    static let maxOutgoing = 16
    // The box takes the pieces of a firmware 4096 bytes ahead of what it has written: 17 pieces.
    static let maxFirmwarePieces = 64
  }

  private var central: CBCentralManager?
  private var isOpen = false
  private var state = NoGpsBleState.off
  private var scanStart: TimeInterval = 0
  private var peripheral: CBPeripheral?
  private var rx: CBCharacteristic?
  /// A box with an old firmware has none.
  private var ota: CBCharacteristic?
  /// Subscribed to the lines of the box.
  private var isReady = false
  /// The box has sent data over this connection: it is encrypted, so the box is paired.
  private var isHeard = false
  private var foregroundObserver: NSObjectProtocol?
  /// The box accepted a new phone when it was found: the user may be entering its code.
  private var acceptsNewPhone = false
  /// The box had sent data before, when it was found.
  private var isKnown = false
  /// When the connection was made.
  private var linkedTime: TimeInterval?
  /// Silent connections to a known box in a row, the last one ended at lastSilentTime.
  private var silentConnections = 0
  private var lastSilentTime: TimeInterval = 0
  /// Too many silent connections: the lost-pairing hint is shown, and the search goes on once a minute.
  private var isBondLost = false
  /// What the core was told with the last state.
  private var reportedBondLost = false
  /// The box with a closed window that has phones is connected once, as it may be paired in the system: its id and
  /// the flags of its advertisement. Silent, it gets the hint of the flags.
  private var closedTry: (id: UUID, flags: UInt8)?
  /// The boxes tried so: not again while their advertisements come.
  private var triedClosed = Set<UUID>()
  /// The last advertisement of a box that doesn't accept a new phone, and the check that it still comes.
  private var pairingClosedTime: TimeInterval = 0
  private var pairingClosedCheck: DispatchWorkItem?
  // A line written with a response waits for it.
  private var isWriting = false
  private var outgoing: [Data] = []
  // The pieces of a firmware go after the lines: a line a second keeps the connection with the box.
  private var firmware: [Data] = []
  private var retryDelay = Constants.retryDelay
  // The next search or the end of a connection attempt.
  private var timer: DispatchWorkItem?
  /// Nothing wakes the app up in the background while it waits to search again: it would stay suspended.
  private var backgroundWait = UIBackgroundTaskIdentifier.invalid
  private lazy var knownBoxes = Set(UserDefaults.standard.stringArray(forKey: Constants.knownBoxesKey) ?? [])
  private lazy var forgottenBoxes = Set(UserDefaults.standard.stringArray(forKey: Constants.forgottenBoxesKey) ?? [])
  /// The user adds a car: only a box that is not of a known car is connected.
  private var newBoxOnly = false
  /// The cars and the current one, as the search starts.
  private var carIds = Set<String>()
  private var currentCar = ""
  /// The box connected, nil if its name is not known.
  private var boxId: String?
  /// When each box was seen in the search, also while one is connected: the Box sheet offers a car whose box is awake.
  private var seenTimes: [String: TimeInterval] = [:]

  /// The system asks the user for the code of a new box, or is about to: the box asks for it 1.5 s after the
  /// connection. iOS doesn't tell it, and the core is told that the box is connected meanwhile, so it keeps sending
  /// HELLO: the box answers as soon as the connection is encrypted.
  @objc
  var isPairing: Bool {
    guard let peripheral, peripheral.state == .connected, !isHeard, closedTry == nil else { return false }
    return !knownBoxes.contains(peripheral.identifier.uuidString)
  }

  @objc
  func open() {
    close()
    isOpen = true
    retryDelay = Constants.retryDelay
    silentConnections = 0
    isBondLost = false
    triedClosed.removeAll()
    // A scan started in the background reports a box once: start it again to see the boxes near now.
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, isOpen, isHeard, central?.state == .poweredOn else { return }
      scan()
    }
    if central == nil {
      // The user is asked for Bluetooth the first time, centralManagerDidUpdateState() follows.
      central = CBCentralManager(delegate: self, queue: nil)
    }
    start()
  }

  @objc
  func send(_ line: Data) {
    guard isReady, let peripheral else { return }
    guard line.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
      LOG(.warning, "A line of \(line.count) bytes doesn't fit")
      return
    }
    if outgoing.count >= Constants.maxOutgoing {
      outgoing.removeFirst()
    }
    outgoing.append(line)
    writeNext()
  }

  /// A piece of a new firmware of the box. A piece that doesn't fit is dropped: the box tells where it has stopped,
  /// and the core sends from there again.
  @objc
  func sendFirmware(_ piece: Data) {
    guard isReady, ota != nil, let peripheral, firmware.count < Constants.maxFirmwarePieces,
          piece.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else { return }
    firmware.append(piece)
    writeNext()
  }

  /// The user asks to look for the box again after a failed pairing or a lost bond. The search goes on while the
  /// lost-pairing hint is shown, so a connection of the box may be open: it is dropped and the box is searched at once.
  @objc
  func retry() {
    guard Self.retrySearches(isOpen: isOpen, hasConnection: peripheral != nil, bondLost: isBondLost) else { return }
    if peripheral != nil {
      closeConnection()
    }
    retryDelay = Constants.retryDelay
    silentConnections = 0
    isBondLost = false
    triedClosed.removeAll()
    start()
  }

  /// The user adds a car: only a box that is not of a known car is connected, the box connected now is dropped. Ends
  /// when the new box is heard, or with false.
  @objc
  func searchNewBox(_ newOnly: Bool) {
    guard newBoxOnly != newOnly else { return }
    LOG(.info, "New box only = \(newOnly)")
    newBoxOnly = newOnly
    guard isOpen else { return }
    closeConnection()
    retryDelay = Constants.retryDelay
    silentConnections = 0
    isBondLost = false
    triedClosed.removeAll()
    start()
  }

  /// The user has forgotten the car: its box, still paired, is not connected until the car is added again.
  @objc
  func forgetBox(_ carId: String) {
    guard forgottenBoxes.insert(carId).inserted else { return }
    UserDefaults.standard.set(Array(forgottenBoxes), forKey: Constants.forgottenBoxesKey)
  }

  /// The user has forgotten the box: a box found later is new, even this one after a reset.
  @objc
  func forgetKnownBoxes() {
    knownBoxes.removeAll()
    UserDefaults.standard.removeObject(forKey: Constants.knownBoxesKey)
  }

  /// The box of the car, other than the connected one (it doesn't advertise), was seen in the last minute.
  @objc
  func isBoxNearby(_ carId: String) -> Bool {
    guard isOpen, carId != boxId, let seen = seenTimes[carId] else { return false }
    return ProcessInfo.processInfo.systemUptime - seen <= Constants.nearbyTimeout
  }

  @objc
  func close() {
    guard isOpen else { return }
    isOpen = false
    foregroundObserver.map(NotificationCenter.default.removeObserver)
    foregroundObserver = nil
    seenTimes.removeAll()
    timer?.cancel()
    cancelPairingClosedCheck()
    endBackgroundWait()
    if central?.state == .poweredOn {
      central?.stopScan()
    }
    closeConnection()
    state = .off
  }

  private func setState(_ newState: NoGpsBleState) {
    guard newState != state || isBondLost != reportedBondLost else { return }
    LOG(.info, "state = \(newState.rawValue)\(isBondLost ? " bond lost" : "")")
    state = newState
    reportedBondLost = isBondLost
    // .connected while the pairing is thought lost is a probe: the core sends HELLO, which the box waits for, but it
    // is not a working link until the box is heard.
    NoGps.onEsp32BleState(newState, bondLost: isBondLost)
  }

  private func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
    timer?.cancel()
    let item = DispatchWorkItem(block: action)
    timer = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  /// Searches the box, or waits until it can be searched.
  private func start() {
    timer?.cancel()
    endBackgroundWait()
    guard isOpen, peripheral == nil, let central else { return }
    switch central.state {
    case .poweredOn:
      break
    case .unauthorized:
      setState(.noPermission)
      return
    case .poweredOff:
      setState(.disabled)
      return
    case .unsupported:
      setState(.off)
      return
    default:
      // Bluetooth is starting, centralManagerDidUpdateState() follows.
      setState(searchState)
      return
    }
    scan()
    scanStart = ProcessInfo.processInfo.systemUptime
    carIds = Set(NoGps.cars().map(\.carId))
    currentCar = NoGps.status().carId
    setState(searchState)
    connectLinked()
    // The box of another car is refused for otherCarDelay: ask again when it has passed.
    guard peripheral == nil else { return }
    schedule(after: Constants.otherCarDelay) { [weak self] in self?.connectLinked() }
  }

  /// The system keeps the link to a paired box after the application has gone, and doesn't report the box while it
  /// is linked. Holding one of its two links, the box may not advertise at all.
  private func connectLinked() {
    guard isOpen, peripheral == nil, let central else { return }
    let linked = central.retrieveConnectedPeripherals(withServices: [Constants.service]).first { peripheral in
      let id = Self.boxId(peripheral, [:])
      return knownBoxes.contains(peripheral.identifier.uuidString)
        && (id.map { isBoxWanted($0, known: true) } ?? !newBoxOnly)
    }
    if let linked {
      LOG(.info, "Linked by the system \(linked.identifier) \(Self.boxId(linked, [:]) ?? "-")")
      connect(linked, id: Self.boxId(linked, [:]), known: true, acceptsNewPhone: false)
    }
  }

  /// Duplicates are reported: the box tells in every advertisement if it accepts a new phone, and this changes. And a
  /// box seen again is still near.
  private func scan() {
    central?.scanForPeripherals(withServices: [Constants.service],
                                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
  }

  /// A box always advertises its flags (BLE-13). A debug build also takes a box that advertises no data at all as
  /// one that accepts a new phone: the box simulator can't advertise it on macOS, where CoreBluetooth puts the name
  /// and the service UUIDs in the advertisement and nothing else. See tools/python/nogps_box_sim.py.
  private func advertisedFlags(_ advertisementData: [String: Any]) -> UInt8 {
    guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
#if DEBUG
      return Constants.pairingOpenFlag
#else
      return 0
#endif
    }
    let bytes = [UInt8](data)
    return bytes.count >= 4 && Array(bytes[0 ..< 2]) == Constants.manufacturerId ? bytes[3] : 0
  }

  /// The four characters of the name of the box, NonGPS-XXXX or NoGPS-XXXX, nil if the box doesn't tell it.
  private static func boxId(_ peripheral: CBPeripheral, _ advertisementData: [String: Any]) -> String? {
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
    guard let name, let prefix = Constants.namePrefixes.first(where: { name.hasPrefix($0) }) else { return nil }
    return String(name.dropFirst(prefix.count))
  }

  /// The user has the most cars: a box that is not of one of them would drive the mark under the current car's values.
  private var isCarLimitReached: Bool {
    carIds.count >= NoGps.maxCars()
  }

  /// Returns false if the box is not to be connected now: of a known car while the user adds one, not of a car at the
  /// limit of cars (the state is told in didDiscover), forgotten, or of another car while the box of the current one
  /// may be found too.
  private func isBoxWanted(_ id: String, known: Bool) -> Bool {
    if isCarLimitReached, !carIds.contains(id) {
      return false
    }
    if newBoxOnly {
      return !carIds.contains(id)
    }
    // Without cars the box is set up anew, as any box.
    if !carIds.isEmpty, forgottenBoxes.contains(id) {
      return false
    }
    return !known || currentCar.isEmpty || currentCar == id
      || ProcessInfo.processInfo.systemUptime - scanStart >= Constants.otherCarDelay
  }

  /// The box sends data: a new one ends the search for it, a forgotten one is added again.
  private func onBoxHeard() {
    newBoxOnly = false
    guard let boxId, forgottenBoxes.remove(boxId) != nil else { return }
    UserDefaults.standard.set(Array(forgottenBoxes), forKey: Constants.forgottenBoxesKey)
  }

  private func connect(_ peripheral: CBPeripheral, id: String?, known: Bool, acceptsNewPhone: Bool,
                       closedFlags: UInt8? = nil) {
    central?.stopScan()
    cancelPairingClosedCheck()
    self.peripheral = peripheral
    boxId = id
    isKnown = known
    self.acceptsNewPhone = acceptsNewPhone
    closedTry = closedFlags.map { (peripheral.identifier, $0) }
    peripheral.delegate = self
    // The lost-pairing hint stays while the search goes on.
    if !isBondLost {
      setState(.connecting)
    }
    central?.connect(peripheral)
    scheduleWatchdog(after: Constants.connectWatchdog)
  }

  private func scheduleWatchdog(after delay: TimeInterval) {
    schedule(after: delay) { [weak self] in
      guard let self else { return }
      if UIApplication.shared.applicationState == .background {
        scheduleWatchdog(after: delay)
        return
      }
      LOG(.warning, "No data from the box in time")
      restartLater()
    }
  }

  /// The box tells in every advertisement that it doesn't accept a new phone: the state is kept while they come.
  private func onPairingClosed(_ flags: UInt8) {
    if flags & Constants.fullFlag != 0 {
      onBoxSkipped(.pairingFull)
    } else if flags & Constants.hasPhonesFlag != 0 {
      onBoxSkipped(.pairingByPhone)
    } else {
      onBoxSkipped(.pairingClosed)
    }
  }

  /// A box is found that is not connected: |reason| is kept while its advertisements come, then the search goes on.
  private func onBoxSkipped(_ reason: NoGpsBleState) {
    pairingClosedTime = ProcessInfo.processInfo.systemUptime
    setState(reason)
    guard pairingClosedCheck == nil else { return }
    schedulePairingClosedCheck(after: Constants.pairingClosedTimeout)
  }

  private func schedulePairingClosedCheck(after delay: TimeInterval) {
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      pairingClosedCheck = nil
      guard [.pairingClosed, .pairingByPhone, .pairingFull, .carLimit].contains(state) else { return }
      let left = pairingClosedTime + Constants.pairingClosedTimeout - ProcessInfo.processInfo.systemUptime
      if left > 0 {
        schedulePairingClosedCheck(after: left)
      } else {
        setState(searchState)
        triedClosed.removeAll()
      }
    }
    pairingClosedCheck = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func cancelPairingClosedCheck() {
    pairingClosedCheck?.cancel()
    pairingClosedCheck = nil
  }

  private func closeConnection() {
    timer?.cancel()
    if let peripheral {
      peripheral.delegate = nil
      if central?.state == .poweredOn {
        central?.cancelPeripheralConnection(peripheral)
      }
    }
    if central?.state == .poweredOn {
      // Only the search connects a box.
      central?.stopScan()
    }
    peripheral = nil
    boxId = nil
    rx = nil
    ota = nil
    isReady = false
    isHeard = false
    acceptsNewPhone = false
    closedTry = nil
    isKnown = false
    linkedTime = nil
    isWriting = false
    outgoing.removeAll()
    firmware.removeAll()
  }

  private func restartLater() {
    let now = ProcessInfo.processInfo.systemUptime
    let end = Self.afterConnection(
      heard: isHeard, known: isKnown, closedTry: closedTry != nil, worked: isReady,
      linkedFor: linkedTime.map { now - $0 }, silentConnections: silentConnections,
      sinceLastSilent: now - lastSilentTime, bondLost: isBondLost, retryDelay: retryDelay
    )
    let tried = closedTry
    closeConnection()
    guard isOpen else { return }
    if end.pairingFailed {
      // The system has asked for the code: it was cancelled or wrong, or the box stopped accepting a new phone. Asked
      // again at once, the code window would come back every few seconds, and the box refuses for 60 s after 3 failures
      // (BLE-12).
      LOG(.warning, "Pairing failed")
      stopUntilRetry(.pairingFailed)
      return
    }
    if end.isSilent {
      lastSilentTime = now
    }
    if end.bondLost, !isBondLost {
      LOG(.warning, "The box has forgotten the phone: \(end.silentConnections) silent connections")
    }
    silentConnections = end.silentConnections
    isBondLost = end.bondLost
    retryDelay = end.retryDelay
    setState(searchState)
    if let tried {
      // Not paired in the system: the hint of its flags, and it is not tried again while its advertisements come.
      triedClosed.insert(tried.id)
      onPairingClosed(tried.flags)
    }
    schedule(after: retryDelay) { [weak self] in self?.start() }
    // The search, a connection and the box wake the app up, the wait doesn't. The system gives some time to finish it
    // in the background, about 30 s; the box is searched earlier if that is not enough.
    if backgroundWait == .invalid {
      backgroundWait = UIApplication.shared.beginBackgroundTask(withName: "NoGpsBoxRetry") { [weak self] in
        self?.start()
      }
    }
  }

  /// The state while the box is searched: the lost-pairing hint stays until the box is heard.
  private var searchState: NoGpsBleState {
    isBondLost ? .bondLost : .searching
  }

  /// The box is not searched until the user asks for it: see retry().
  private func stopUntilRetry(_ newState: NoGpsBleState) {
    // Its end would search again.
    endBackgroundWait()
    setState(newState)
  }

  struct ConnectionEnd: Equatable {
    /// The connection to a new box ended without data: the user has cancelled the code or entered a wrong one.
    var pairingFailed = false
    /// The connection to a known box lasted but gave no data.
    var isSilent = false
    var silentConnections = 0
    /// Six silent connections in a row: the hint is shown, the search goes on.
    var bondLost = false
    var retryDelay: TimeInterval
  }

  /// What follows a connection that ended. A silent connection is not a proof of a lost bond (#154), so the search
  /// goes on once a minute after the hint.
  static func afterConnection(heard: Bool, known: Bool, closedTry: Bool, worked: Bool, linkedFor: TimeInterval?,
                              silentConnections: Int, sinceLastSilent: TimeInterval, bondLost: Bool,
                              retryDelay: TimeInterval) -> ConnectionEnd {
    var end = ConnectionEnd(silentConnections: silentConnections, bondLost: bondLost,
                            retryDelay: worked ? Constants.retryDelay
                              : min(Constants.maxRetryDelay, retryDelay * 2))
    // A box with a closed window that was tried is not paired, or the user can't tell: it is no silent connection.
    guard !heard, !closedTry, let linkedFor, linkedFor >= Constants.minSilentLink else { return end }
    guard known else {
      end.pairingFailed = true
      return end
    }
    let inRow = silentConnections > 0 && sinceLastSilent <= Constants.silentConnectionsGap
    end.isSilent = true
    end.silentConnections = inRow ? silentConnections + 1 : 1
    // A gap of more than 3 min starts the count again, but only the data of the box take the hint away.
    end.bondLost = bondLost || end.silentConnections >= Constants.maxSilentConnections
    if end.bondLost {
      end.retryDelay = Constants.maxRetryDelay
    }
    return end
  }

  /// Whether the user's Try again searches the box now. A connection open while the lost-pairing hint is shown is a
  /// search connection of the box thought lost: the caller drops it. A link without the hint works, it is kept.
  static func retrySearches(isOpen: Bool, hasConnection: Bool, bondLost: Bool) -> Bool {
    isOpen && (!hasConnection || bondLost)
  }

  enum FoundBox: Equatable {
    case connect
    /// A box with a closed window that has phones: it may be paired in the system.
    case connectClosed
    case wait
    /// Not connected: the hint of its flags.
    case skip
  }

  /// Whether a box that is found is connected: |tried| is a box with a closed window that was connected already.
  static func foundBox(known: Bool, pairingOpen: Bool, hasPhones: Bool, forgotten: Bool, addsCar: Bool, hasCars: Bool,
                       hasKnownBoxes: Bool, sinceSearchStart: TimeInterval, tried: Bool) -> FoundBox {
    if known {
      return .connect
    }
    guard pairingOpen else {
      // The app may have lost the box (a reinstall, the other build) while the system still has the pairing: a new car
      // is looked for, or the user has none. The box of a forgotten car is not taken this way: it still has the
      // pairing, so only setting it up again, while it accepts a new phone, brings the car back (#325), as on Android.
      return hasPhones && (addsCar || (!hasCars && !forgotten)) && !tried ? .connectClosed : .skip
    }
    // A box paired already is taken first if it is near: the new one may be somebody else's. Without it the new box is
    // a second or a replaced one of the user.
    return !addsCar && hasKnownBoxes && sinceSearchStart < Constants.newBoxDelay ? .wait : .connect
  }

  private func endBackgroundWait() {
    guard backgroundWait != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundWait)
    backgroundWait = .invalid
  }

  private func remember(_ peripheral: CBPeripheral) {
    guard knownBoxes.insert(peripheral.identifier.uuidString).inserted else { return }
    UserDefaults.standard.set(Array(knownBoxes), forKey: Constants.knownBoxesKey)
  }

  private func writeNext() {
    guard let peripheral, let rx else { return }
    // Until the box is heard the connection may be unencrypted. The box drops a write without response then silently,
    // and refuses a write with a response: iOS encrypts the connection on that, or asks for the code of a new box.
    if !isHeard {
      guard !isWriting, !outgoing.isEmpty else { return }
      isWriting = true
      peripheral.writeValue(outgoing.removeFirst(), for: rx, type: .withResponse)
      return
    }
    // Without a response: the box answers a command with a line, and its data are the answer to HELLO. It tells how
    // much of a firmware it has got in lines too. A write iOS can't take now would be dropped.
    while peripheral.canSendWriteWithoutResponse {
      if !outgoing.isEmpty {
        peripheral.writeValue(outgoing.removeFirst(), for: rx, type: .withoutResponse)
      } else if let ota, !firmware.isEmpty {
        peripheral.writeValue(firmware.removeFirst(), for: ota, type: .withoutResponse)
      } else {
        return
      }
    }
  }
}

extension Esp32BleTransport: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    LOG(.info, "Bluetooth = \(central.state.rawValue)")
    guard isOpen else { return }
    if central.state != .poweredOn {
      // The connection is lost without a callback.
      closeConnection()
    }
    start()
  }

  func centralManager(_: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard isOpen else { return }
    let id = Self.boxId(peripheral, advertisementData)
    if let id {
      seenTimes[id] = ProcessInfo.processInfo.systemUptime
    }
    guard self.peripheral == nil else { return }
    let known = knownBoxes.contains(peripheral.identifier.uuidString)
    if isCarLimitReached, id.map({ !carIds.contains($0) }) ?? !known {
      onBoxSkipped(.carLimit)
      return
    }
    // A known box without its name may be of a car: not while a new one is added.
    guard id.map({ isBoxWanted($0, known: known) }) ?? !((newBoxOnly && known) || (!known && isCarLimitReached))
    else { return }
    let flags = advertisedFlags(advertisementData)
    let pairingOpen = flags & Constants.pairingOpenFlag != 0
    let forgotten = id.map { forgottenBoxes.contains($0) } == true
    var closedFlags: UInt8?
    switch Self.foundBox(
      known: known, pairingOpen: pairingOpen,
      hasPhones: flags & (Constants.hasPhonesFlag | Constants.fullFlag) != 0, forgotten: forgotten,
      addsCar: newBoxOnly, hasCars: !carIds.isEmpty, hasKnownBoxes: !knownBoxes.isEmpty,
      sinceSearchStart: ProcessInfo.processInfo.systemUptime - scanStart,
      tried: triedClosed.contains(peripheral.identifier)
    ) {
    case .wait:
      return
    case .skip:
      // A box accepts a new phone for two minutes after it is powered, if it has no phones, or after a paired phone has
      // let it. The system asks for the code. The box of a forgotten car still knows this phone: powered on again, it
      // takes it back.
      onPairingClosed(forgotten ? 0 : flags)
      return
    case .connectClosed:
      closedFlags = forgotten ? 0 : flags
    case .connect:
      break
    }
    LOG(.info, "Found \(peripheral.identifier) \(id ?? "-") rssi \(RSSI) known \(known) pairing open \(pairingOpen)")
    connect(peripheral, id: id, known: known, acceptsNewPhone: pairingOpen, closedFlags: closedFlags)
  }

  func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral === self.peripheral else { return }
    LOG(.info, "Connected")
    linkedTime = ProcessInfo.processInfo.systemUptime
    // The system asks for the code of a new box now, or of a known one the phone has forgotten.
    if (!isKnown && closedTry == nil) || acceptsNewPhone {
      scheduleWatchdog(after: Constants.pairingWatchdog)
    }
    // Nothing else is asked for: the box asks for the connection it needs by itself.
    peripheral.discoverServices([Constants.service])
  }

  func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard peripheral === self.peripheral else { return }
    LOG(.warning, "Failed to connect: \(String(describing: error))")
    restartLater()
  }

  func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    guard peripheral === self.peripheral else { return }
    LOG(.info, "Disconnected: \(String(describing: error))")
    restartLater()
  }
}

extension Esp32BleTransport: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard peripheral === self.peripheral else { return }
    guard let service = peripheral.services?.first(where: { $0.uuid == Constants.service }) else {
      LOG(.warning, "No service of the box: \(String(describing: error))")
      restartLater()
      return
    }
    peripheral.discoverCharacteristics([Constants.tx, Constants.rx, Constants.ota], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard peripheral === self.peripheral else { return }
    let characteristics = service.characteristics ?? []
    guard let tx = characteristics.first(where: { $0.uuid == Constants.tx }),
          let rx = characteristics.first(where: { $0.uuid == Constants.rx }) else {
      LOG(.warning, "No characteristics of the box: \(String(describing: error))")
      restartLater()
      return
    }
    self.rx = rx
    ota = characteristics.first(where: { $0.uuid == Constants.ota })
    peripheral.setNotifyValue(true, for: tx)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                  error: Error?) {
    guard peripheral === self.peripheral else { return }
    guard error == nil, characteristic.isNotifying else {
      // E.g. the user has refused to pair or has entered a wrong code.
      LOG(.warning, "Not subscribed: \(String(describing: error))")
      restartLater()
      return
    }
    LOG(.info, "Subscribed")
    isReady = true
    // The core sends HELLO now.
    setState(.connected)
    // A box accepting a new phone may wait for the user to enter its code, even a paired one: the phone may have
    // forgotten it. The data may come before this callback: the box keeps the subscription of a paired phone.
    if !isHeard, knownBoxes.contains(peripheral.identifier.uuidString) || closedTry != nil, !acceptsNewPhone {
      schedule(after: Constants.silenceTimeout) { [weak self] in
        LOG(.warning, "No data from the box")
        self?.restartLater()
      }
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === self.peripheral, error == nil, let data = characteristic.value, !data.isEmpty else { return }
    if !isHeard {
      isHeard = true
      silentConnections = 0
      isBondLost = false
      // The probe is a link now.
      setState(state)
      closedTry = nil
      timer?.cancel()
      remember(peripheral)
      onBoxHeard()
      // The boxes of the other cars are only seen, not connected: the search ended with the connection.
      scan()
      // The lines waiting for a write with a response go without it now.
      writeNext()
    }
    NoGps.onEsp32BleBytes(data)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor _: CBCharacteristic, error: Error?) {
    guard peripheral === self.peripheral else { return }
    isWriting = false
    // E.g. "Insufficient Authentication" while iOS encrypts the connection. The box has forgotten the phone if it
    // keeps coming (docs/nogps/esp32-firmware-spec.md, BLE-15).
    if let error {
      LOG(.warning, "Not written: \(error)")
    }
    writeNext()
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard peripheral === self.peripheral else { return }
    writeNext()
  }
}
