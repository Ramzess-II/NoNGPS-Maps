package app.organicmaps.nogps;

import android.content.Context;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.annotation.StringRes;
import app.organicmaps.BuildConfig;
import app.organicmaps.R;
import app.organicmaps.sdk.location.NoGps;
import java.util.Locale;

/**
 * What the Box sheet and the bottom bar tell about the sensor box, its car and its firmware.
 */
public final class BoxTexts
{
  private BoxTexts() {}

  /**
   * Also told by the Box button of the bottom bar.
   */
  @NonNull
  public static String boxStateText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    // The phone keeps looking for a sleeping box.
    if (status.getSourceState() == NoGps.SourceState.BOX_SLEEPING)
      return context.getString(R.string.nogps_box_sleeping) + " · " + context.getString(boxSearchText(context, status));
    return context.getString(switch (status.getSourceState())
    {
      case DISCONNECTED -> R.string.nogps_elm_disconnected;
      case CONNECTING -> boxSearchText(context, status);
      case NO_ADAPTER -> R.string.nogps_elm_no_adapter;
      case OBD_DISABLED -> R.string.nogps_box_obd_disabled;
      case OBD_CONNECTING -> R.string.nogps_box_obd_connecting;
      case OBD_ERROR -> R.string.nogps_elm_error;
      case NO_CAR_DATA -> R.string.nogps_elm_no_car;
      case BOX_SLEEPING -> R.string.nogps_box_sleeping;
      case OBD_SLEEPING -> R.string.nogps_box_obd_sleeping;
      case CONNECTED -> R.string.nogps_elm_connected;
      case UPDATING -> R.string.nogps_box_updating;
    });
  }

  /**
   * The box is not heard yet: what the phone does to reach it.
   */
  @StringRes
  private static int boxSearchText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    if (NoGps.isLocationOffForBox(context, status))
      return R.string.nogps_box_step_location_off;
    return switch (status.getBleState())
    {
      // Named as in the settings: Android before 12 finds Bluetooth devices with the location permission.
      case NO_PERMISSION ->
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? R.string.nogps_box_bt_no_nearby
                                                       : R.string.nogps_box_bt_no_location;
      // OFF: the phone has no Bluetooth LE.
      case OFF, DISABLED -> R.string.nogps_box_bt_disabled;
      case SEARCHING -> R.string.nogps_box_bt_searching;
      case PAIRING_CLOSED -> R.string.nogps_box_bt_pairing_closed;
      case PAIRING_BY_PHONE -> R.string.nogps_box_bt_pairing_by_phone;
      case PAIRING_FULL -> R.string.nogps_box_bt_pairing_full;
      case CONNECTING -> R.string.nogps_box_bt_connecting;
      case PAIRING -> R.string.nogps_box_bt_pairing;
      case CONNECTED -> R.string.nogps_box_bt_waiting;
      case PAIRING_FAILED -> R.string.nogps_box_bt_pairing_failed;
      case BOND_LOST -> R.string.nogps_box_bt_bond_lost;
    };
  }

  @NonNull
  static String boxCalibrationText(@NonNull Context context, @NonNull NoGps.Status status,
                                   @NonNull NoGps.CalibrationState calibration)
  {
    return switch (calibration)
    {
      case NONE -> context.getString(R.string.nogps_box_not_calibrated);
      case CALIBRATING -> context.getString(R.string.nogps_box_calibrating, status.calibrationProgress);
      // The box keeps its calibration, but it may stand in another way since it was plugged in.
      case DONE ->
        context.getString(status.boxCalibrationAdvised ? R.string.nogps_box_calibration_advised
                                                       : R.string.nogps_box_calibrated);
      case FAILED_MOVING -> context.getString(R.string.nogps_box_calibration_failed);
      case MOUNT_MOVED -> context.getString(R.string.nogps_gyro_mount_moved);
      case LINK_LOST -> context.getString(R.string.nogps_box_calibration_link_lost);
    };
  }

  /**
   * The firmware of the box, or how its update goes.
   */
  @NonNull
  static String firmwareText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    return switch (status.getFirmwareUpdate())
    {
      case STARTING -> context.getString(R.string.nogps_firmware_starting);
      case SENDING -> context.getString(R.string.nogps_firmware_sending, status.firmwareUpdateProgress);
      case VERIFYING -> context.getString(R.string.nogps_firmware_verifying);
      case RESTARTING -> context.getString(R.string.nogps_firmware_restarting);
      case NONE, DONE, FAILED -> status.boxFirmware;
    };
  }

  /**
   * The box works with the firmware the application is tested with: there is nothing to install. A debug build sends
   * it again to try the update itself.
   */
  static boolean canInstallFirmware(@NonNull NoGps.Status status)
  {
    return !isUpdating(status.getFirmwareUpdate()) && !status.bundledFirmware.isEmpty()
 && (BuildConfig.DEBUG || !status.bundledFirmware.equals(status.boxFirmware));
  }

  static boolean isUpdating(@NonNull NoGps.FirmwareUpdate update)
  {
    return update == NoGps.FirmwareUpdate.STARTING || update == NoGps.FirmwareUpdate.SENDING
 || update == NoGps.FirmwareUpdate.VERIFYING || update == NoGps.FirmwareUpdate.RESTARTING;
  }

  /**
   * How many ranges of the car speed GPS has measured. The rough table by the roads doesn't count: it is only a guess.
   */
  @NonNull
  static String speedTableText(@NonNull Context context, @NonNull NoGps.Status status)
  {
    final int all = status.speedTableCarM.length;
    if (status.speedTableRanges == 0)
      return context.getString(R.string.nogps_speed_table_not_calibrated);
    if (status.speedTableRanges >= all)
      return context.getString(R.string.nogps_speed_table_calibrated);
    return context.getString(R.string.nogps_speed_table_calibrating, status.speedTableRanges, all);
  }

  @NonNull
  static String speedTableRowText(@NonNull Context context, @NonNull NoGps.Status status, int i)
  {
    final float carM = status.speedTableCarM[i];
    final float scale = status.speedTableScale[i];
    final String value;
    // The rough table from the roads is used while GPS has measured no range.
    if (scale > 0)
      value = String.format(Locale.US, "%s×%.2f", status.speedTableRanges == 0 ? "≈" : "", scale);
    else if (carM >= 1)
      value = context.getString(R.string.nogps_speed_table_left,
                                Math.max(1, (int) Math.ceil(NoGps.SPEED_TABLE_MIN_DISTANCE_M - carM)));
    else
      value = "—";
    return context.getString(R.string.nogps_speed_table_row, NoGps.speedTableFromKmh(i), NoGps.speedTableToKmh(i),
                             value);
  }

  @NonNull
  static String boxValueText(@NonNull Context context, @NonNull NoGps.Status status, @NonNull NoGps.BoxValue id,
                             @NonNull String value)
  {
    if (value.isEmpty())
    {
      // The box asks the car for them while it stands.
      final boolean standingOnly =
          id == NoGps.BoxValue.RPM || id == NoGps.BoxValue.ELM_VOLTAGE || id == NoGps.BoxValue.ECU_VOLTAGE;
      return context.getString(standingOnly && status.speedKmh > 0 ? R.string.nogps_not_while_driving
                                                                   : R.string.nogps_unknown);
    }
    return switch (id)
    {
      case ENGINE ->
        value.equals("RUN")   ? context.getString(R.string.nogps_engine_running)
        : value.equals("OFF") ? context.getString(R.string.nogps_engine_stopped)
                              : value;
      case RPM -> rpmText(context, value);
      case BOX_VOLTAGE, ELM_VOLTAGE, ECU_VOLTAGE -> context.getString(R.string.nogps_volts, value);
      case VOLTAGE_MISMATCH -> context.getString(value.equals("1") ? R.string.yes : R.string.no);
      case IMU_RATE -> context.getString(R.string.nogps_box_value_hz, value);
      case IMU_TEMPERATURE -> context.getString(R.string.nogps_box_value_celsius, value);
      case BIAS_AGE -> context.getString(R.string.nogps_box_value_seconds_ago, value);
      case BIAS -> context.getString(R.string.nogps_box_value_degrees_per_second, value);
      case FLASH_SIZE, MAX_IMAGE_SIZE -> context.getString(R.string.nogps_box_value_kilobytes, value);
      default -> value;
    };
  }

  @NonNull
  private static String rpmText(@NonNull Context context, @NonNull String value)
  {
    try
    {
      return context.getString(R.string.nogps_rpm, Integer.parseInt(value));
    }
    catch (NumberFormatException e)
    {
      return value;
    }
  }

  @StringRes
  static int boxValueLabel(@NonNull NoGps.BoxValue id)
  {
    return switch (id)
    {
      case ENGINE -> R.string.nogps_box_value_engine;
      case RPM -> R.string.nogps_box_value_rpm;
      case BOX_VOLTAGE -> R.string.nogps_box_value_box_voltage;
      case ELM_VOLTAGE -> R.string.nogps_box_value_elm_voltage;
      case ECU_VOLTAGE -> R.string.nogps_box_value_ecu_voltage;
      case VOLTAGE_MISMATCH -> R.string.nogps_box_value_voltage_mismatch;
      case IMU_NAME -> R.string.nogps_box_value_name;
      case IMU_STATE, OBD_STATE -> R.string.nogps_box_value_state;
      case IMU_CHIP_ID -> R.string.nogps_box_value_chip_id;
      case IMU_RATE -> R.string.nogps_box_value_rate;
      case IMU_TEMPERATURE -> R.string.nogps_box_value_temperature;
      case IMU_ERRORS -> R.string.nogps_box_value_read_errors;
      case BIAS_AGE -> R.string.nogps_box_value_bias_age;
      case BIAS -> R.string.nogps_box_value_bias;
      case OBD_PROTOCOL -> R.string.nogps_box_value_protocol;
      case OBD_ERROR -> R.string.nogps_box_value_last_error;
      case OBD_BAUD -> R.string.nogps_box_value_uart_baud;
      case FIRMWARE -> R.string.nogps_box_value_firmware;
      case BUILD_DATE -> R.string.nogps_box_value_build_date;
      case CHIP -> R.string.nogps_box_value_chip;
      case BOARD -> R.string.nogps_box_value_board;
      case ID -> R.string.nogps_box_value_id;
      case FLASH_SIZE -> R.string.nogps_box_value_flash_size;
      case MAX_IMAGE_SIZE -> R.string.nogps_box_value_max_image_size;
      case SLOT -> R.string.nogps_box_value_slot;
      case SLOT_STATE -> R.string.nogps_box_value_slot_state;
      case ABILITIES -> R.string.nogps_box_value_abilities;
      case POWER_ONS -> R.string.nogps_box_value_power_ons;
      case LAST_EVENT -> R.string.nogps_box_value_last_event;
    };
  }

  /**
   * "Car C47D" until the user names it.
   */
  @NonNull
  static String carName(@NonNull Context context, @NonNull NoGps.Car car)
  {
    return car.name.isEmpty() ? context.getString(app.organicmaps.sdk.R.string.nogps_car_default_name, car.id)
                              : car.name;
  }

  /**
   * The states follow "Box: name ·" in other places, here they start the line.
   */
  @NonNull
  static String capitalize(@NonNull String text)
  {
    return text.isEmpty() ? text : text.substring(0, 1).toUpperCase(Locale.getDefault()) + text.substring(1);
  }
}
