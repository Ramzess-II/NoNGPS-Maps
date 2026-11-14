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
} NS_SWIFT_NAME(NoGpsBleState);

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
} NS_SWIFT_NAME(NoGpsEvent);

/// Posted on the main queue, the MWMNoGpsEvent is in the userInfo by MWMNoGpsEventKey.
extern NSNotificationName const MWMNoGpsEventNotification NS_SWIFT_NAME(NoGps.eventNotification);
extern NSString * const MWMNoGpsEventKey NS_SWIFT_NAME(NoGps.eventKey);

/// A value of the sensor box with its unit, empty if the box sends the field empty.
NS_SWIFT_NAME(NoGpsBoxValueItem)
@interface MWMNoGpsBoxValueItem : NSObject

@property(nonatomic, readonly) MWMNoGpsBoxValue kind;
@property(nonatomic, readonly) NSString * value;

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
@property(nonatomic, readonly) double speedLagSec;
@property(nonatomic, readonly) BOOL speedLagMeasured;
@property(nonatomic, readonly) MWMNoGpsCalibrationState calibration;
@property(nonatomic, readonly) NSInteger calibrationProgress;
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
+ (void)calibrate;
+ (void)clearSpeedCalibration;
/// Sends the firmware of MWMNoGpsStatus.bundledFirmware to the box.
+ (void)startFirmwareUpdate;
+ (void)cancelFirmwareUpdate;

/// The bytes of the ESP32 sensor box and the state of the connection to it.
+ (void)onEsp32BleBytes:(NSData *)data;
+ (void)onEsp32BleState:(MWMNoGpsBleState)state;

@end

NS_ASSUME_NONNULL_END
