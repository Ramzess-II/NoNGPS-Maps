#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The orders of the enums are the same as in the core (libs/map/nogps).

typedef NS_ENUM(NSInteger, MWMNoGpsPositionSource) {
  MWMNoGpsPositionSourceNone,
  MWMNoGpsPositionSourceGps,
  // Cell towers and Wi-Fi.
  MWMNoGpsPositionSourceNetwork,
  MWMNoGpsPositionSourceManual,
  // Car speed and turns.
  MWMNoGpsPositionSourceInertial,
} NS_SWIFT_NAME(NoGpsPositionSource);

// What GPS is worth now, whether the car follows it or not.
typedef NS_ENUM(NSInteger, MWMNoGpsGpsState) {
  MWMNoGpsGpsStateNone,
  // Only Wi-Fi and cell towers, or not accurate positions.
  MWMNoGpsGpsStateCoarse,
  MWMNoGpsGpsStateSpoofed,
  // Good positions not trusted yet after GPS was bad, or the satellites are searched after the start.
  MWMNoGpsGpsStateChecking,
  MWMNoGpsGpsStateGood,
} NS_SWIFT_NAME(NoGpsGpsState);

typedef NS_ENUM(NSInteger, MWMNoGpsSourceState) {
  MWMNoGpsSourceStateDisconnected,
  MWMNoGpsSourceStateConnecting,
  MWMNoGpsSourceStateNoAdapter,
  MWMNoGpsSourceStateObdDisabled,
  MWMNoGpsSourceStateObdConnecting,
  MWMNoGpsSourceStateObdError,
  MWMNoGpsSourceStateNoCarData,
  MWMNoGpsSourceStateBoxSleeping,
  MWMNoGpsSourceStateObdSleeping,
  MWMNoGpsSourceStateConnected,
  // The sensor box takes a new firmware: it sends no data until it restarts with it.
  MWMNoGpsSourceStateUpdating,
} NS_SWIFT_NAME(NoGpsSourceState);

/// What the phone does to reach the ESP32 sensor box over Bluetooth LE.
typedef NS_ENUM(NSInteger, MWMNoGpsBleState) {
  // Not searched, or the phone has no Bluetooth LE.
  MWMNoGpsBleStateOff,
  MWMNoGpsBleStateNoPermission,
  // Bluetooth is switched off on the phone.
  MWMNoGpsBleStateDisabled,
  MWMNoGpsBleStateSearching,
  // A box is found, but it doesn't accept a new phone now.
  MWMNoGpsBleStatePairingClosed,
  MWMNoGpsBleStateConnecting,
  // The system asks the user for the code of the box.
  MWMNoGpsBleStatePairing,
  // Subscribed to the lines of the box.
  MWMNoGpsBleStateConnected,
  // A cancelled or wrong code: not tried again until the user asks.
  MWMNoGpsBleStatePairingFailed,
  // A paired box sends nothing: it has forgotten the phone. Not tried again until the user asks.
  MWMNoGpsBleStateBondLost,
  // A box that doesn't know the phone and has phones: a new one is added on one of them.
  MWMNoGpsBleStatePairingByPhone,
  // The same, and the box has no room: a phone is removed on one of them first.
  MWMNoGpsBleStatePairingFull,
  // A box of no car of the user is found, and the user has the most cars: a car is forgotten first.
  MWMNoGpsBleStateCarLimit,
} NS_SWIFT_NAME(NoGpsBleState);

/// What the box does about a new phone, see startAddPhone.
typedef NS_ENUM(NSInteger, MWMNoGpsAddPhone) {
  MWMNoGpsAddPhoneNone,
  // The code is sent to the box.
  MWMNoGpsAddPhoneOpening,
  // The box takes a new phone with the code for addPhoneSecondsLeft.
  MWMNoGpsAddPhoneOpen,
  MWMNoGpsAddPhoneAdded,
  // No phone has paired in time.
  MWMNoGpsAddPhoneExpired,
  // The box has 4 phones.
  MWMNoGpsAddPhoneFull,
  MWMNoGpsAddPhoneFailed,
} NS_SWIFT_NAME(NoGpsAddPhone);

/// What the phone does about the place of the car when two phones are on one box: the one that changes the box leads,
/// the other one follows it.
typedef NS_ENUM(NSInteger, MWMNoGpsPeerRole) {
  // The box can't pass the places on, or this phone is alone on it.
  MWMNoGpsPeerRoleNone,
  MWMNoGpsPeerRoleLeading,
  MWMNoGpsPeerRoleFollowing,
} NS_SWIFT_NAME(NoGpsPeerRole);

typedef NS_ENUM(NSInteger, MWMNoGpsCalibrationState) {
  MWMNoGpsCalibrationStateNone,
  MWMNoGpsCalibrationStateCalibrating,
  MWMNoGpsCalibrationStateDone,
  MWMNoGpsCalibrationStateFailedMoving,
  MWMNoGpsCalibrationStateMountMoved,
  MWMNoGpsCalibrationStateLinkLost,
} NS_SWIFT_NAME(NoGpsCalibrationState);

/// The update of the firmware of the ESP32 sensor box, nogps::Esp32Update::State.
typedef NS_ENUM(NSInteger, MWMNoGpsFirmwareUpdate) {
  MWMNoGpsFirmwareUpdateNone,
  // The box is asked to take the firmware.
  MWMNoGpsFirmwareUpdateStarting,
  MWMNoGpsFirmwareUpdateSending,
  // Everything is sent, the box checks it.
  MWMNoGpsFirmwareUpdateVerifying,
  // The box restarts with the new firmware and tells its version.
  MWMNoGpsFirmwareUpdateRestarting,
  MWMNoGpsFirmwareUpdateDone,
  MWMNoGpsFirmwareUpdateFailed,
} NS_SWIFT_NAME(NoGpsFirmwareUpdate);

/// A value the sensor box sends in its status and info lines, nogps::esp32::BoxValue: the Box values page shows them in
/// this order.
typedef NS_ENUM(NSInteger, MWMNoGpsBoxValue) {
  // The car.
  MWMNoGpsBoxValueEngine,
  MWMNoGpsBoxValueRpm,
  // Volts.
  MWMNoGpsBoxValueBoxVoltage,
  MWMNoGpsBoxValueElmVoltage,
  MWMNoGpsBoxValueEcuVoltage,
  // "1" if the voltage of the box differs from the car, "0" if not.
  MWMNoGpsBoxValueVoltageMismatch,
  // The gyroscope.
  MWMNoGpsBoxValueImuName,
  MWMNoGpsBoxValueImuState,
  MWMNoGpsBoxValueImuChipId,
  // Hz.
  MWMNoGpsBoxValueImuRate,
  // °C.
  MWMNoGpsBoxValueImuTemperature,
  MWMNoGpsBoxValueImuErrors,
  // Seconds.
  MWMNoGpsBoxValueBiasAge,
  // °/s.
  MWMNoGpsBoxValueBias,
  // OBD.
  MWMNoGpsBoxValueObdState,
  MWMNoGpsBoxValueObdProtocol,
  MWMNoGpsBoxValueObdError,
  MWMNoGpsBoxValueObdBaud,
  // The box.
  MWMNoGpsBoxValueFirmware,
  MWMNoGpsBoxValueBuildDate,
  MWMNoGpsBoxValueChip,
  MWMNoGpsBoxValueBoard,
  MWMNoGpsBoxValueRevision,
  MWMNoGpsBoxValueId,
  // KB.
  MWMNoGpsBoxValueFlashSize,
  MWMNoGpsBoxValueMaxImageSize,
  MWMNoGpsBoxValueSlot,
  MWMNoGpsBoxValueSlotState,
  MWMNoGpsBoxValueAbilities,
  MWMNoGpsBoxValuePowerOns,
  MWMNoGpsBoxValueLastEvent,
} NS_SWIFT_NAME(NoGpsBoxValue);

typedef NS_ENUM(NSInteger, MWMNoGpsEvent) {
  MWMNoGpsEventManualModeChanged,
  MWMNoGpsEventGpsBack,
  MWMNoGpsEventGpsLost,
  MWMNoGpsEventGpsSpoofed,
  MWMNoGpsEventGpsRestored,
  MWMNoGpsEventRoadLost,
  MWMNoGpsEventTurnsReversed,
  MWMNoGpsEventMotionSourceStopped,
  MWMNoGpsEventMarkNoRoad,
  MWMNoGpsEventNotCalibrated,
  MWMNoGpsEventFirmwareUpdateAvailable,
  MWMNoGpsEventFirmwareUpdateDone,
  MWMNoGpsEventFirmwareUpdateFailed,
  MWMNoGpsEventBoxCalibrationAdvised,
  // The box has removed this phone on the request of the user: the car of the box is forgotten.
  MWMNoGpsEventThisPhoneRemoved,
  /// GPS has measured a range of the speed table: speedHintRange and speedMilestone of the status tell which, and what
  /// it has completed.
  MWMNoGpsEventSpeedRangeCalibrated,
  /// A run from a standing start is timed: sprintKind and the sprint properties of the status tell the result.
  MWMNoGpsEventSprintMeasured,
  /// The box has connected after 5 minutes or more without it: a drive starts. A new file of the trip log is started
  /// before the notification is posted.
  MWMNoGpsEventTripStarted,
} NS_SWIFT_NAME(NoGpsEvent);

/// The kinds of the runs from a standing start.
typedef NS_ENUM(NSInteger, MWMNoGpsSprintKind) {
  MWMNoGpsSprintKindTo100,
  MWMNoGpsSprintKindQuarterMile,
} NS_SWIFT_NAME(NoGpsSprintKind);

/// What the last speed range measured by GPS has completed.
typedef NS_ENUM(NSInteger, MWMNoGpsSpeedMilestone) {
  MWMNoGpsSpeedMilestoneRange,
  /// All of 5-60 km/h.
  MWMNoGpsSpeedMilestoneCity,
  /// All of 5-100 km/h.
  MWMNoGpsSpeedMilestoneOutOfTown,
  MWMNoGpsSpeedMilestoneFull,
} NS_SWIFT_NAME(NoGpsSpeedMilestone);

/// Posted on the main queue, the MWMNoGpsEvent is in the userInfo by MWMNoGpsEventKey.
extern NSNotificationName const MWMNoGpsEventNotification NS_SWIFT_NAME(NoGps.eventNotification);
extern NSString * const MWMNoGpsEventKey NS_SWIFT_NAME(NoGps.eventKey);

/// A value of the sensor box with its unit, empty if the box sends the field empty.
NS_SWIFT_NAME(NoGpsBoxValueItem)
@interface MWMNoGpsBoxValueItem : NSObject

@property(nonatomic, readonly) MWMNoGpsBoxValue kind;
@property(nonatomic, readonly) NSString * value;

@end

/// A car is known by the sensor box in it: what the navigation learns about a car is kept for each one.
NS_SWIFT_NAME(NoGpsCar)
@interface MWMNoGpsCar : NSObject

/// The four characters of the name of the box, NoGPS-XXXX.
@property(nonatomic, readonly) NSString * carId;
/// Empty until the user names the car.
@property(nonatomic, readonly) NSString * name;
@property(nonatomic, readonly) NSString * firmware;
/// When the box told about itself the last time.
@property(nonatomic, readonly, nullable) NSDate * lastSeen;

@end

/// A timed run from a standing start, kept for the car.
NS_SWIFT_NAME(NoGpsSprint)
@interface MWMNoGpsSprint : NSObject

@property(nonatomic, readonly) MWMNoGpsSprintKind kind;
@property(nonatomic, readonly) NSDate * date;
@property(nonatomic, readonly) double sec;
/// The speed at the end of the quarter mile, 0 for 0-100 km/h.
@property(nonatomic, readonly) NSInteger trapKmh;

@end

/// A phone paired with the sensor box.
NS_SWIFT_NAME(NoGpsPhone)
@interface MWMNoGpsPhone : NSObject

/// The Bluetooth address the box knows the phone by: forgetBoxPhone takes it.
@property(nonatomic, readonly) NSString * address;
/// The model the phone has told the box, empty if none.
@property(nonatomic, readonly) NSString * name;
/// When it connected the last time.
@property(nonatomic, readonly, nullable) NSDate * lastSeen;
@property(nonatomic, readonly) BOOL thisPhone;
/// The box takes the commands that change it from this phone, false if not known.
@property(nonatomic, readonly) BOOL changesBox;

@end

/// Everything the UI shows about the navigation without GPS, taken at once.
NS_SWIFT_NAME(NoGpsStatus)
@interface MWMNoGpsStatus : NSObject

@property(nonatomic, readonly) MWMNoGpsPositionSource source;
// Of the shown position.
@property(nonatomic, readonly) double accuracyM;
@property(nonatomic, readonly) BOOL manualMode;
// The next tap on the map shows where the car is: the button for it is pressed.
@property(nonatomic, readonly) BOOL markByTap;
// Since the user has set the position in the manual mode.
@property(nonatomic, readonly) NSTimeInterval manualAge;
@property(nonatomic, readonly) BOOL gpsSpoofed;
@property(nonatomic, readonly) BOOL gpsDisabled;
@property(nonatomic, readonly) MWMNoGpsGpsState gpsState;
// The age of the last good GPS position, negative if there is none.
@property(nonatomic, readonly) NSTimeInterval lastGoodGpsAge;
// GPS works now, also in the manual mode where it is not used. Negative if it doesn't.
@property(nonatomic, readonly) double workingGpsAccuracyM;
@property(nonatomic, readonly) double workingNetworkAccuracyM;
// The position is not from GPS: the user corrects it with the buttons.
@property(nonatomic, readonly) BOOL movedByHand;
/// The speed limit of the road the car is on, the way it goes: 0 for none, -1 if unknown.
@property(nonatomic, readonly) NSInteger speedLimitKmh;

@property(nonatomic, readonly) BOOL inertialEnabled;
/// The box of the current car, see cars: empty before a box is heard.
@property(nonatomic, readonly) NSString * carId;
// The rest is known while the inertial navigation works.
@property(nonatomic, readonly) BOOL inertialStarted;
@property(nonatomic, readonly) MWMNoGpsSourceState sourceState;
@property(nonatomic, readonly) MWMNoGpsBleState bleState;
@property(nonatomic, readonly) NSString * deviceName;
// Negative if unknown.
@property(nonatomic, readonly) NSInteger speedKmh;
@property(nonatomic, readonly) BOOL hasCarInfo;
// Negative if unknown, 0 if stopped, 1 if running.
@property(nonatomic, readonly) NSInteger engineRunning;
// The car data, negative if unknown.
@property(nonatomic, readonly) NSInteger rpm;
@property(nonatomic, readonly) NSInteger boxMillivolts;
@property(nonatomic, readonly) NSInteger elmMillivolts;
@property(nonatomic, readonly) NSInteger ecuMillivolts;
@property(nonatomic, readonly) BOOL voltageMismatch;
@property(nonatomic, readonly) double speedScale;
@property(nonatomic, readonly) NSInteger speedTableRanges;
@property(nonatomic, readonly) NSInteger roughSpeedTableRanges;
/// The ranges of the table in use, the rough one while speedTableRanges is 0: the distance driven by the car speed
/// and the ratio, 0 until the range is measured.
@property(nonatomic, readonly) NSArray<NSNumber *> * speedTableCarM;
@property(nonatomic, readonly) NSArray<NSNumber *> * speedTableScale;
/// The table GPS has measured, without the rough one.
@property(nonatomic, readonly) NSArray<NSNumber *> * gpsSpeedTableCarM;
@property(nonatomic, readonly) NSArray<NSNumber *> * gpsSpeedTableScale;
/// The bar next to the speed: GPS has not measured the speed of the car. The range it tells about, at
/// MWMNoGpsEventSpeedRangeCalibrated the one just measured.
@property(nonatomic, readonly) BOOL speedHintShown;
@property(nonatomic, readonly) NSInteger speedHintRange;
/// Accurate GPS measures the speed now.
@property(nonatomic, readonly) BOOL speedHintGps;
@property(nonatomic, readonly) MWMNoGpsSpeedMilestone speedMilestone;
/// The result of the last MWMNoGpsEventSprintMeasured: the trap speed of the quarter mile, the best time of the car of
/// that kind before it, 0 for none, and whether it is faster than that.
@property(nonatomic, readonly) MWMNoGpsSprintKind sprintKind;
@property(nonatomic, readonly) double sprintSec;
@property(nonatomic, readonly) NSInteger sprintTrapKmh;
@property(nonatomic, readonly) double sprintBestSec;
@property(nonatomic, readonly) BOOL sprintRecord;
@property(nonatomic, readonly) double speedLagSec;
@property(nonatomic, readonly) BOOL speedLagMeasured;
@property(nonatomic, readonly) MWMNoGpsCalibrationState calibration;
@property(nonatomic, readonly) NSInteger calibrationProgress;
/// The core waits for the car to stand still to calibrate the box, or calibrates it: see +calibrateWhenStill.
@property(nonatomic, readonly) BOOL calibrationArmed;
/// The sensor box reports that it stands still.
@property(nonatomic, readonly) BOOL boxStill;
/// The user has not seen the offer of bundledFirmware: show it and call +firmwareOfferShown.
@property(nonatomic, readonly) BOOL firmwareOfferPending;
/// The sensor box has been powered on since the user calibrated it: it may stand in another way now.
@property(nonatomic, readonly) BOOL boxCalibrationAdvised;
@property(nonatomic, readonly) BOOL hasInertialPosition;
/// The mark waits for the user to put it on a road: the road is lost.
@property(nonatomic, readonly) BOOL roadLost;
/// How many other roads the car may be on after a turn that fitted several, switchMark shows the car on them.
@property(nonatomic, readonly) NSInteger otherMarks;

/// The firmware of the sensor box, empty until the box tells it.
@property(nonatomic, readonly) NSString * boxFirmware;
/// The firmware for this box that comes with the app, if the box can take it now. Empty otherwise.
@property(nonatomic, readonly) NSString * bundledFirmware;
@property(nonatomic, readonly) MWMNoGpsFirmwareUpdate firmwareUpdate;
@property(nonatomic, readonly) NSInteger firmwareUpdateProgress;
/// Why the update has failed: a code of the box (MOVING, LOW_VOLTAGE, SIGNATURE etc.) or of the app (LINK, CANCELED,
/// ROLLBACK etc.).
@property(nonatomic, readonly) NSString * firmwareUpdateError;
/// All the sensor box has told in this connection, in the order of MWMNoGpsBoxValue.
@property(nonatomic, readonly) NSArray<MWMNoGpsBoxValueItem *> * boxValues;
/// The box is connected and knows its phones: they are listed, removed and added.
@property(nonatomic, readonly) BOOL boxHasPhones;
/// The phones of the box, nil until it lists them.
@property(nonatomic, readonly, nullable) NSArray<MWMNoGpsPhone *> * boxPhones;
/// Another phone has connected to the box first and changes it: this one gets the data only.
@property(nonatomic, readonly) BOOL boxReadOnly;
@property(nonatomic, readonly) MWMNoGpsPeerRole peerRole;
/// The name of the phone this one follows, empty if the box doesn't know it.
@property(nonatomic, readonly) NSString * peerName;
@property(nonatomic, readonly) MWMNoGpsAddPhone addPhone;
/// The code to enter on the new phone while addPhone is Open.
@property(nonatomic, readonly) NSString * addPhoneCode;
@property(nonatomic, readonly) NSInteger addPhoneSecondsLeft;

@end

/// Navigation without GPS, done in the core: it chooses the position to show from GPS, the marks of the user and the
/// inertial navigation by the ESP32 sensor box. Everything is called on the main queue.
NS_SWIFT_NAME(NoGps)
@interface MWMNoGps : NSObject

/// A position from CoreLocation. The chosen position comes back to MWMLocationManager.
+ (void)onLocation:(CLLocation *)location;
/// The last position from CoreLocation as it came: the GPS sheet shows its details.
+ (nullable CLLocation *)lastPlatformLocation;
/// A valid heading of the compass, only written to the log of a drive.
+ (void)onHeading:(CLHeading *)heading;

+ (void)start;
+ (void)stop;

+ (MWMNoGpsStatus *)status;

/// The next single tap on the map shows where the car is, the core handles it. Pass NO to take it back.
+ (void)setMarkByTap:(BOOL)armed;
/// The mark goes by the last GPS fix near the car, see nogps::Engine::PlaceMarkByGps().
/// @return NO if GPS can't place it: the caller tells the user and arms the tap with setMarkByTap:.
+ (BOOL)placeMarkByGps;
/// The car is at the point: the mark goes to the nearest road, the map follows the car.
/// @return NO if there is no road near, MWMNoGpsEventMarkNoRoad is posted then.
+ (BOOL)placeMarkAt:(CLLocationCoordinate2D)coordinate;
+ (void)reverseDirection;
/// Shows the car on the next of the other roads it may be on.
+ (void)switchMark;
+ (void)setGpsDisabled:(BOOL)disabled;
+ (void)setInertialNavigationEnabled:(BOOL)enabled;
/// Turns the navigation by the box off, and a box found later is taken for a new one.
+ (void)forgetBox;
/// Looks for the box again after MWMNoGpsBleStatePairingFailed or MWMNoGpsBleStateBondLost.
+ (void)retryBox;
/// The cars of the user in the order they were added, a car for each box heard.
+ (NSArray<MWMNoGpsCar *> *)cars;
/// The timed runs of the current car, newest first.
+ (NSArray<MWMNoGpsSprint *> *)sprints;
/// The timed runs kept for the car, newest first; none for a car that is not there.
+ (NSArray<MWMNoGpsSprint *> *)sprintsOfCar:(NSString *)carId;
/// No car is added over this many: the user can't add one.
+ (NSInteger)maxCars;
/// The user drives the car: its values are used, the box of the car is looked for.
+ (void)selectCar:(NSString *)carId;
/// An empty name gives the car its usual name back.
+ (void)renameCar:(NSString *)carId name:(NSString *)name;
/// Forgets the car with what is learned about it. Its box is not connected until the car is added again. Without cars
/// left the box is not looked for.
+ (void)forgetCar:(NSString *)carId;
/// The box of the car, other than the connected one, was seen in the last minute: the car may be switched to.
+ (BOOL)isBoxNearby:(NSString *)carId;
/// The user adds a car: only a box that is not of a known car is connected, until it is heard or this is called with
/// NO.
+ (void)searchNewBox:(BOOL)newOnly;
+ (void)calibrate;
/// Calibrates the box as soon as the car stands still, see MWMNoGpsStatus.calibrationArmed. The core disarms itself
/// after the calibration, with a lost link or 2 min without a still car.
+ (void)calibrateWhenStill;
+ (void)cancelCalibrateWhenStill;
/// The shake of the box in the last 3 s, the oldest first, as NSNumber in percent of the limit under which the box
/// counts the car still. Empty without a box or with an old firmware.
+ (NSArray<NSNumber *> *)boxShake;
+ (void)clearSpeedCalibration;
/// Sends the firmware of MWMNoGpsStatus.bundledFirmware to the box.
+ (void)startFirmwareUpdate;
+ (void)cancelFirmwareUpdate;
/// The user has been offered the firmware, see MWMNoGpsStatus.firmwareOfferPending.
+ (void)firmwareOfferShown;
/// Asks the box of the car for its phones again, see MWMNoGpsStatus.boxPhones.
+ (void)listBoxPhones;
/// Removes the phone from the box. Removing this phone ends with MWMNoGpsEventThisPhoneRemoved.
+ (void)forgetBoxPhone:(NSString *)address;
/// Lets the box take a new phone with a new code for two minutes, see MWMNoGpsStatus.addPhone.
+ (void)startAddPhone;
/// The code is not shown any more.
+ (void)endAddPhone;

/// The bytes of the ESP32 sensor box and the state of the connection to it.
+ (void)onEsp32BleBytes:(NSData *)data;
/// `bondLost`: the pairing is thought lost, MWMNoGpsBleStateConnected then is a probe that carries nothing until the
/// box is heard.
+ (void)onEsp32BleState:(MWMNoGpsBleState)state bondLost:(BOOL)bondLost;

@end

NS_ASSUME_NONNULL_END
