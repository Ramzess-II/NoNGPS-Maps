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
/// sent data are remembered as the paired ones, and a new box is connected only while it accepts a new phone.
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
    static let knownBoxesKey = "NoGpsKnownBoxes"
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
  /// The box accepted a new phone when it was found: the user may be entering its code.
  private var acceptsNewPhone = false
  /// The box had sent data before, when it was found.
  private var isKnown = false
  /// When the connection was made.
  private var linkedTime: TimeInterval?
  /// Silent connections to a known box in a row, the last one ended at lastSilentTime.
  private var silentConnections = 0
  private var lastSilentTime: TimeInterval = 0
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

  /// The system asks the user for the code of a new box, or is about to: the box asks for it 1.5 s after the
  /// connection. iOS doesn't tell it, and the core is told that the box is connected meanwhile, so it keeps sending
  /// HELLO: the box answers as soon as the connection is encrypted.
  @objc
  var isPairing: Bool {
    guard let peripheral, peripheral.state == .connected, !isHeard else { return false }
    return !knownBoxes.contains(peripheral.identifier.uuidString)
  }

  @objc
  func open() {
    close()
    isOpen = true
    retryDelay = Constants.retryDelay
    silentConnections = 0
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

  /// The user asks to look for the box again after a failed pairing or a lost bond, which stop the search.
  @objc
  func retry() {
    guard isOpen, peripheral == nil else { return }
    retryDelay = Constants.retryDelay
    silentConnections = 0
    start()
  }

  /// The user has forgotten the box: a box found later is new, even this one after a reset.
  @objc
  func forgetKnownBoxes() {
    knownBoxes.removeAll()
    UserDefaults.standard.removeObject(forKey: Constants.knownBoxesKey)
  }

  @objc
  func close() {
    guard isOpen else { return }
    isOpen = false
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
    guard newState != state else { return }
    LOG(.info, "state = \(newState.rawValue)")
    state = newState
    NoGps.onEsp32BleState(newState)
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
      setState(.searching)
      return
    }
    // Duplicates are reported: the box tells in every advertisement if it accepts a new phone, and this changes.
    central.scanForPeripherals(withServices: [Constants.service],
                               options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    scanStart = ProcessInfo.processInfo.systemUptime
    setState(.searching)
  }

  private func isPairingOpen(_ advertisementData: [String: Any]) -> Bool {
    guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return false }
    let bytes = [UInt8](data)
    return bytes.count >= 4 && Array(bytes[0 ..< 2]) == Constants.manufacturerId
      && bytes[3] & Constants.pairingOpenFlag != 0
  }

  private func connect(_ peripheral: CBPeripheral, known: Bool, acceptsNewPhone: Bool) {
    central?.stopScan()
    cancelPairingClosedCheck()
    self.peripheral = peripheral
    isKnown = known
    self.acceptsNewPhone = acceptsNewPhone
    peripheral.delegate = self
    setState(.connecting)
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
  private func onPairingClosed() {
    pairingClosedTime = ProcessInfo.processInfo.systemUptime
    setState(.pairingClosed)
    guard pairingClosedCheck == nil else { return }
    schedulePairingClosedCheck(after: Constants.pairingClosedTimeout)
  }

  private func schedulePairingClosedCheck(after delay: TimeInterval) {
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      pairingClosedCheck = nil
      guard state == .pairingClosed else { return }
      let left = pairingClosedTime + Constants.pairingClosedTimeout - ProcessInfo.processInfo.systemUptime
      if left > 0 {
        schedulePairingClosedCheck(after: left)
      } else {
        setState(.searching)
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
    peripheral = nil
    rx = nil
    ota = nil
    isReady = false
    isHeard = false
    acceptsNewPhone = false
    isKnown = false
    linkedTime = nil
    isWriting = false
    outgoing.removeAll()
    firmware.removeAll()
  }

  private func restartLater() {
    let worked = isReady
    let linkedFor = linkedTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    let silent = linkedFor >= Constants.minSilentLink && !isHeard
    let known = isKnown
    closeConnection()
    guard isOpen else { return }
    if silent, !known {
      // The system has asked for the code: it was cancelled or wrong, or the box stopped accepting a new phone. Asked
      // again at once, the code window would come back every few seconds, and the box refuses for 60 s after 3 failures
      // (BLE-12).
      LOG(.warning, "Pairing failed")
      stopUntilRetry(.pairingFailed)
      return
    }
    if silent, countSilentConnection() {
      LOG(.warning, "The box has forgotten the phone: \(silentConnections) silent connections")
      stopUntilRetry(.bondLost)
      return
    }
    setState(.searching)
    retryDelay = worked ? Constants.retryDelay : min(Constants.maxRetryDelay, retryDelay * 2)
    schedule(after: retryDelay) { [weak self] in self?.start() }
    // The search, a connection and the box wake the app up, the wait doesn't. The system gives some time to finish it
    // in the background, about 30 s; the box is searched earlier if that is not enough.
    if backgroundWait == .invalid {
      backgroundWait = UIApplication.shared.beginBackgroundTask(withName: "NoGpsBoxRetry") { [weak self] in
        self?.start()
      }
    }
  }

  /// The box is not searched until the user asks for it: see retry().
  private func stopUntilRetry(_ newState: NoGpsBleState) {
    // Its end would search again.
    endBackgroundWait()
    setState(newState)
  }

  /// Returns true if there are too many silent connections in a row.
  private func countSilentConnection() -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    let inRow = silentConnections > 0 && now - lastSilentTime <= Constants.silentConnectionsGap
    silentConnections = inRow ? silentConnections + 1 : 1
    lastSilentTime = now
    return silentConnections >= Constants.maxSilentConnections
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
    guard isOpen, self.peripheral == nil else { return }
    let known = knownBoxes.contains(peripheral.identifier.uuidString)
    let pairingOpen = isPairingOpen(advertisementData)
    if !known {
      // The box accepts a new phone for two minutes after it is powered, the system asks for its code.
      guard pairingOpen else {
        onPairingClosed()
        return
      }
      // A box paired already is taken first if it is near: the new one may be somebody else's. Without it the new box
      // is a second or a replaced one of the user.
      if !knownBoxes.isEmpty, ProcessInfo.processInfo.systemUptime - scanStart < Constants.newBoxDelay {
        return
      }
    }
    LOG(.info, "Found \(peripheral.identifier) rssi \(RSSI) known \(known) pairing open \(pairingOpen)")
    connect(peripheral, known: known, acceptsNewPhone: pairingOpen)
  }

  func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral === self.peripheral else { return }
    LOG(.info, "Connected")
    linkedTime = ProcessInfo.processInfo.systemUptime
    // The system asks for the code of a new box now, or of a known one the phone has forgotten.
    if !isKnown || acceptsNewPhone {
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
    // forgotten it.
    if knownBoxes.contains(peripheral.identifier.uuidString), !acceptsNewPhone {
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
      timer?.cancel()
      remember(peripheral)
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
