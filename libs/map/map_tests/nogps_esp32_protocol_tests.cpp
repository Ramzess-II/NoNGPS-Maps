#include "testing/testing.hpp"

#include "map/nogps/box_car_values.hpp"
#include "map/nogps/esp32_protocol.hpp"
#include "map/nogps/storage.hpp"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

namespace nogps_esp32_protocol_tests
{
using namespace nogps;
using namespace nogps::esp32;

// Returns the line with its checksum.
std::string WithCrc(std::string const & body)
{
  char crc[8];
  std::snprintf(crc, sizeof(crc), "%04X", Crc16(body));
  return "$" + body + "*" + crc;
}

UNIT_TEST(NoGps_Esp32_Crc)
{
  // The check value of CRC-16/CCITT-FALSE.
  TEST_EQUAL(Crc16("123456789"), 0x29B1, ());
}

UNIT_TEST(NoGps_Esp32_Command)
{
  TEST_EQUAL(Command(17, "HELLO"), "$NGC,17,HELLO*D289\r\n", ());
  TEST_EQUAL(Command(18, "CAL_UP"), "$NGC,18,CAL_UP*5D27\r\n", ());
}

UNIT_TEST(NoGps_Esp32_ParsesData)
{
  auto const fields = Parse("$NGD,1,15230,845213,-1234567,-15300,5021345,43,80,1F*1BDE\r\n");
  TEST(fields, ());
  auto const data = ParseData(*fields);
  TEST(data, ());
  TEST_EQUAL(data->m_seq, 15230, ());
  TEST_EQUAL(data->m_timeMs, 845213, ());
  TEST_EQUAL(data->m_yawMdeg, -1234567, ());
  TEST_EQUAL(data->m_rateMdps, -15300, ());
  TEST_EQUAL(data->m_distMm, 5021345, ());
  TEST_EQUAL(data->m_speedKmh, 43, ());
  TEST_EQUAL(data->m_speedAgeMs, 80, ());
  TEST_EQUAL(data->m_flags, 0x1F, ());
}

UNIT_TEST(NoGps_Esp32_ParsesAccel)
{
  // The lines of the firmware with the accelerations: a speed bump.
  auto data = ParseData(*Parse("$NGD,1,5022,945253,-21882,-2100,812584,43,100,1F,-180,95,2350,6800*47CA"));
  TEST(data, ());
  TEST(data->m_hasAccel, ());
  TEST_ALMOST_EQUAL_ABS(data->m_accelH1, -0.18, 1e-9, ());
  TEST_ALMOST_EQUAL_ABS(data->m_accelH2, 0.095, 1e-9, ());
  TEST_ALMOST_EQUAL_ABS(data->m_accelUp, 2.35, 1e-9, ());
  TEST_ALMOST_EQUAL_ABS(data->m_jolt, 6.8, 1e-9, ());
  TEST_EQUAL(data->m_speedKmh, 43, ());
  // The vertical is not calibrated.
  data = ParseData(*Parse("$NGD,1,77,12345,0,0,0,-1,-1,223,,,,*9174"));
  TEST(data, ());
  TEST(!data->m_hasAccel, ());
  // An older box.
  data = ParseData(*Parse("$NGD,1,1234,845213,-15300,0,0,-1,-1,227*AEEE"));
  TEST(data, ());
  TEST(!data->m_hasAccel, ());
}

UNIT_TEST(NoGps_Esp32_ParsesShake)
{
  // The shake comes with the accelerations and without them, before the calibration.
  auto data = ParseData(*Parse(WithCrc("NGD,1,5022,945253,-21882,-2100,812584,43,100,1F,-180,95,2350,6800,135")));
  TEST(data, ());
  TEST(data->m_hasAccel, ());
  TEST_EQUAL(data->m_shakePct, 135, ());
  data = ParseData(*Parse(WithCrc("NGD,1,77,12345,0,0,0,-1,-1,223,,,,,40")));
  TEST(data, ());
  TEST(!data->m_hasAccel, ());
  TEST_EQUAL(data->m_shakePct, 40, ());
  // An older box doesn't tell it, a damaged field is a damaged line.
  data = ParseData(*Parse(WithCrc("NGD,1,5022,945253,-21882,-2100,812584,43,100,1F,-180,95,2350,6800")));
  TEST(data, ());
  TEST_EQUAL(data->m_shakePct, -1, ());
  TEST(!ParseData(*Parse(WithCrc("NGD,1,77,12345,0,0,0,-1,-1,223,,,,,x"))), ());
}

UNIT_TEST(NoGps_Esp32_RejectsBadChecksum)
{
  TEST(!Parse("$NGD,1,15230,845213,-1234567,-15300,5021345,43,80,1F*1BDF"), ());
  TEST(!Parse("NGD,1,15230*1BDE"), ());
  TEST(!Parse("$NGD,1,15230"), ());
  TEST(!Parse("$NGD,1*ZZZZ"), ());
}

UNIT_TEST(NoGps_Esp32_RejectsOtherVersion)
{
  TEST(!ParseData({"NGD", "2", "1", "1", "1", "1", "1", "1", "1", "1F"}), ());
}

UNIT_TEST(NoGps_Esp32_ParsesReplies)
{
  auto const ok = Parse("$NGA,18,OK*461D");
  TEST(ok, ());
  auto const okReply = ParseReply(*ok);
  TEST(okReply, ());
  TEST_EQUAL(okReply->m_id, 18, ());
  TEST(okReply->m_ok, ());

  auto const progress = Parse("$NGA,18,PROGRESS,40*4D95");
  TEST(progress, ());
  auto const progressReply = ParseReply(*progress);
  TEST(progressReply, ());
  TEST_EQUAL(progressReply->m_progress, 40, ());
  TEST(!progressReply->m_ok, ());

  auto const error = Parse("$NGA,18,ERR,MOVING*416A");
  TEST(error, ());
  auto const errorReply = ParseReply(*error);
  TEST(errorReply, ());
  TEST_EQUAL(errorReply->m_error, "MOVING", ());
}

UNIT_TEST(NoGps_Esp32_ParsesStatus)
{
  auto const fields = Parse("$NGS,1,1.0.0,ICM42688,400,OK,ISO 15765-4 CAN 11/500,12,412,0*8BEB");
  TEST(fields, ());
  TEST_EQUAL(ParseImuName(*fields), "ICM42688", ());
  TEST_EQUAL(ParseObdState(*fields), "OK", ());
}

UNIT_TEST(NoGps_Esp32_ParsesStatusWithoutElm327)
{
  // The fields added in the second spec follow the first ones.
  auto const fields = Parse(WithCrc("NGS,1,2.0.0,ICM42688,400,NO_ADAPTER,,12,412,0,OK,0x47,NO_ADAPTER,0,-15,3"));
  TEST(fields, ());
  TEST_EQUAL(ParseObdState(*fields), "NO_ADAPTER", ());
  TEST(!ParseObdState(*Parse("$NGA,18,OK*461D")), ());
}

UNIT_TEST(NoGps_Esp32_ParsesCarInfo)
{
  // Lines from the firmware with the engine, its speed and the voltage in the fields 17-19.
  auto car = ParseCarInfo(*Parse(
      "$NGS,1,0.2.0,ICM20602,500,OK,ISO 15765-4 (CAN 11/500),12,331,0,OK,0x12,NONE,38400,-386,9,RUN,812,14100*EA0D"));
  TEST(car, ());
  TEST_EQUAL(car->m_engineRunning, true, ());
  TEST_EQUAL(car->m_rpm, 812, ());
  TEST_EQUAL(car->m_boxMillivolts, 14100, ());
  TEST_EQUAL(car->m_elmMillivolts, -1, ());
  TEST(!car->m_voltageMismatch, ());

  car = ParseCarInfo(*Parse("$NGS,1,0.2.0,ICM20602,500,SLEEP,,12,331,0,OK,0x12,NONE,38400,-386,14,OFF,,12480*3920"));
  TEST(car, ());
  TEST_EQUAL(car->m_engineRunning, false, ());
  TEST_EQUAL(car->m_rpm, -1, ());
  TEST_EQUAL(car->m_boxMillivolts, 12480, ());

  // Nothing is known without ELM327: the last fields are empty.
  car = ParseCarInfo(*Parse("$NGS,1,0.2.0,ICM20602,500,NO_ADAPTER,,,331,0,OK,0x12,NO_ADAPTER,0,-386,4,,,*D654"));
  TEST(car, ());
  TEST(!car->m_engineRunning, ());
  TEST_EQUAL(car->m_boxMillivolts, -1, ());

  // Lines of the firmware with 21 fields: the voltage from ELM327 and from the control unit of the car.
  car =
      ParseCarInfo(*Parse("$NGS,1,0.2.0,ICM20602,500,OK,ISO 15765-4 (CAN 11/500),12,331,0,OK,0x12,NONE,38400,"
                          "-386,9,RUN,812,14100,13800,14080*AF2F"));
  TEST(car, ());
  TEST_EQUAL(car->m_boxMillivolts, 14100, ());
  TEST_EQUAL(car->m_elmMillivolts, 13800, ());
  TEST_EQUAL(car->m_ecuMillivolts, 14080, ());
  TEST_EQUAL(car->GetReferenceMillivolts(), 14080, ());
  TEST(!car->m_voltageMismatch, ());

  // The car drives: only the voltage measured by the box comes.
  car =
      ParseCarInfo(*Parse("$NGS,1,0.2.0,ICM20602,500,OK,ISO 15765-4 (CAN 11/500),3,335,0,OK,0x12,NONE,38400,-380,"
                          "9,RUN,,14230,,*3483"));
  TEST(car, ());
  TEST_EQUAL(car->m_rpm, -1, ());
  TEST_EQUAL(car->m_boxMillivolts, 14230, ());
  TEST_EQUAL(car->m_elmMillivolts, -1, ());
  TEST_EQUAL(car->m_ecuMillivolts, -1, ());

  // No divider in the box, the car doesn't tell its voltage.
  car =
      ParseCarInfo(*Parse("$NGS,1,0.2.0,ICM20602,500,OK,ISO 15765-4 (CAN 11/500),12,331,0,OK,0x12,NONE,38400,-386,"
                          "9,RUN,790,,13800,*9680"));
  TEST(car, ());
  TEST_EQUAL(car->m_boxMillivolts, -1, ());
  TEST_EQUAL(car->GetReferenceMillivolts(), 13800, ());
  TEST(!car->m_voltageMismatch, ());

  // The divider of the box is wrong if its voltage differs from the car by more than 10%.
  car =
      ParseCarInfo(*Parse(WithCrc("NGS,1,0.2.0,ICM20602,500,OK,,12,331,0,OK,0x12,NONE,38400,-386,9,RUN,812,17200,"
                                  "12400,")));
  TEST(car, ());
  TEST(car->m_voltageMismatch, ());

  // A status of an older firmware and other lines tell nothing about the car.
  TEST(!ParseCarInfo(*Parse("$NGA,18,OK*461D")), ());
}

UNIT_TEST(NoGps_Esp32_BoxValues)
{
  using V = BoxValue;
  // The status of spec 2, 16 fields: in the units they are shown in.
  TEST_EQUAL(ParseBoxValues(*Parse("$NGS,1,2.0.0,ICM42688,400,OK,ISO 15765-4 CAN 11 500,12,412,0,OK,0x47,NONE,38400,"
                                   "-15,0*6D29")),
             BoxValues({{V::ImuName, "ICM42688"},
                        {V::ImuState, "OK"},
                        {V::ImuChipId, "0x47"},
                        {V::ImuRate, "400"},
                        {V::ImuTemperature, "41.2"},
                        {V::ImuErrors, "0"},
                        {V::BiasAge, "12"},
                        {V::Bias, "-0.015"},
                        {V::ObdState, "OK"},
                        {V::ObdProtocol, "ISO 15765-4 CAN 11 500"},
                        {V::ObdError, "NONE"},
                        {V::ObdBaud, "38400"},
                        {V::Firmware, "2.0.0"},
                        {V::LastEvent, "0"}}),
             ());

  // 21 fields: the car.
  auto values =
      ParseBoxValues(*Parse("$NGS,1,0.2.0,ICM20602,500,OK,ISO 15765-4 (CAN 11/500),12,331,0,OK,0x12,NONE,"
                            "38400,-386,9,RUN,812,14100,13800,14080*AF2F"));
  TEST_EQUAL(values.size(), 19, ());
  TEST_EQUAL(BoxValues(values.begin(), values.begin() + 5),
             BoxValues({{V::Engine, "RUN"},
                        {V::Rpm, "812"},
                        {V::BoxVoltage, "14.10"},
                        {V::ElmVoltage, "13.80"},
                        {V::EcuVoltage, "14.08"}}),
             ());

  // Empty fields stay empty, the absent ones are not shown.
  values = ParseBoxValues(*Parse("$NGS,1,0.2.0,ICM20602,500,NO_ADAPTER,,,331,0,OK,0x12,NO_ADAPTER,0,-386,4,,,*D654"));
  TEST_EQUAL(values.size(), 17, ());
  TEST_EQUAL(BoxValues(values.begin(), values.begin() + 3),
             BoxValues({{V::Engine, ""}, {V::Rpm, ""}, {V::BoxVoltage, ""}}), ());
  auto const value = [&values](V id)
  { return std::find_if(values.begin(), values.end(), [id](auto const & v) { return v.first == id; })->second; };
  TEST_EQUAL(value(V::ObdProtocol), "", ());
  TEST_EQUAL(value(V::BiasAge), "", ());
  TEST_EQUAL(value(V::ImuTemperature), "33.1", ());

  // The info, 13 fields: the firmware is shown from the status.
  TEST_EQUAL(ParseBoxValues(*Parse("$NGI,1,0.3.5,2026-10-10T10:35,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,"
                                   "WIFI BLE OTA,0*92DA")),
             BoxValues({{V::BuildDate, "2026-10-10T10:35"},
                        {V::Chip, "esp32s3"},
                        {V::Board, "s3zero"},
                        {V::Id, "C47D"},
                        {V::FlashSize, "4096"},
                        {V::MaxImageSize, "1984"},
                        {V::Slot, "ota_0"},
                        {V::SlotState, "VALID"},
                        {V::Abilities, "WIFI BLE OTA"},
                        {V::PowerOns, "0"}}),
             ());

  TEST_EQUAL(ParseBoxValues(*Parse(WithCrc("NGI,1,0.4.3,2026-11-18T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,"
                                           "BLE OTA,5,R1"))),
             BoxValues({{V::BuildDate, "2026-11-18T10:00"},
                        {V::Chip, "esp32s3"},
                        {V::Board, "s3zero"},
                        {V::Revision, "R1"},
                        {V::Id, "C47D"},
                        {V::FlashSize, "4096"},
                        {V::MaxImageSize, "1984"},
                        {V::Slot, "ota_0"},
                        {V::SlotState, "VALID"},
                        {V::Abilities, "BLE OTA"},
                        {V::PowerOns, "5"}}),
             ());

  TEST(ParseBoxValues(*Parse("$NGA,18,OK*461D")).empty(), ());
}

UNIT_TEST(NoGps_Esp32_ParsesLinesOfFirmware)
{
  // Lines from the firmware 0.2.0: ELM327 is off, the box stands still.
  auto const data = ParseData(*Parse("$NGD,1,1234,845213,-15300,0,0,-1,-1,227*AEEE"));
  TEST(data, ());
  TEST_EQUAL(data->m_yawMdeg, -15300, ());
  TEST_EQUAL(data->m_speedKmh, -1, ());
  TEST_EQUAL(data->m_flags, kFlagImuOk | kFlagBiasOk | kFlagUpOk | kFlagStill | kFlagObdAbsent, ());

  auto const status = Parse("$NGS,1,0.2.0,ICM20602,500,DISABLED,,,331,0,OK,0x12,NONE,0,-386,3*9ED2");
  TEST(status, ());
  TEST_EQUAL(ParseImuName(*status), "ICM20602", ());
  TEST_EQUAL(ParseObdState(*status), "DISABLED", ());
  TEST_EQUAL(ParseLastEventNumber(*status), 3, ());

  auto const info =
      ParseInfo(*Parse("$NGI,1,0.3.3,2026-10-10T07:33,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,WIFI BLE OTA*C597"));
  TEST(info, ());
  TEST_EQUAL(info->m_firmware, "0.3.3", ());
  TEST_EQUAL(info->m_chip, "esp32s3", ());
  TEST_EQUAL(info->m_board, "s3zero", ());
  TEST(info->m_canUpdate, ());
  TEST_EQUAL(info->m_id, "C47D", ());
  TEST(!info->m_powerOns, ());
  // A later firmware counts how many times the box was powered on.
  auto const countingInfo = ParseInfo(
      *Parse("$NGI,1,0.3.5,2026-10-10T11:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,WIFI BLE OTA,12*94E1"));
  TEST(countingInfo, ());
  TEST(countingInfo->m_canUpdate, ());
  TEST(!countingInfo->m_canStoreCarValues, ());
  TEST(countingInfo->m_powerOns, ());
  TEST_EQUAL(*countingInfo->m_powerOns, 12, ());
  TEST(countingInfo->m_revision.empty(), ());
  // A firmware that tells the hardware revision.
  auto const revisionInfo = ParseInfo(*Parse(
      WithCrc("NGI,1,0.4.3,2026-11-18T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA CAR PHONES,5,R1")));
  TEST(revisionInfo, ());
  TEST_EQUAL(revisionInfo->m_revision, "R1", ());
  TEST_EQUAL(*revisionInfo->m_powerOns, 5, ());
  // A firmware that keeps the values of the car.
  auto const carInfo = ParseInfo(
      *Parse(WithCrc("NGI,1,0.4.1,2026-11-15T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA CAR,3")));
  TEST(carInfo, ());
  TEST(carInfo->m_canUpdate, ());
  TEST(carInfo->m_canStoreCarValues, ());
  // The first firmware with Bluetooth didn't take a firmware over it.
  auto const oldInfo =
      ParseInfo(*Parse("$NGI,1,0.3.0,2026-10-08T19:43,esp32s3,s3zero,1B00,4096,2031616,ota_0,VALID,WIFI BLE*BBC4"));
  TEST(oldInfo, ());
  TEST(!oldInfo->m_canUpdate, ());
  TEST(!ParseInfo(*Parse("$NGE,1,7,845100,I,CAL_AUTO,-386*AC09")), ());

  auto const received = ParseUpdateProgress(*Parse("$NGO,1,4320,RESEND*4B18"));
  TEST(received, ());
  TEST_EQUAL(received->m_received, 4320, ());
  TEST_EQUAL(received->m_state, "RESEND", ());
  // What an accepted command returns: the size of a piece and of the window.
  auto const begun = ParseReply(*Parse("$NGA,21,OK,240,4096*88F0"));
  TEST(begun, ());
  TEST(begun->m_ok, ());
  TEST_EQUAL(begun->m_values, std::vector<std::string>({"240", "4096"}), ());

  auto const event = ParseEvent(*Parse("$NGE,1,7,845100,I,CAL_AUTO,-386*AC09"));
  TEST(event, ());
  TEST_EQUAL(event->m_number, 7, ());
  TEST_EQUAL(event->m_level, "I", ());
  TEST_EQUAL(event->m_code, "CAL_AUTO", ());
  TEST_EQUAL(event->m_text, "-386", ());
}

UNIT_TEST(NoGps_Esp32_CarValueCommands)
{
  // The lines of the spec of the box.
  TEST_EQUAL(Command(30, "CAR_GET,spd_scale"), "$NGC,30,CAR_GET,spd_scale*7EA1\r\n", ());
  TEST_EQUAL(Command(31, "CAR_SET,spd_scale,1.0420"), "$NGC,31,CAR_SET,spd_scale,1.0420*F21A\r\n", ());
  auto const value = ParseReply(*Parse("$NGA,32,OK,1.0420*DD5C"));
  TEST(value && value->m_ok, ());
  TEST_EQUAL(value->m_values, std::vector<std::string>({"1.0420"}), ());
  auto const empty = ParseReply(*Parse("$NGA,30,OK*875D"));
  TEST(empty && empty->m_ok && empty->m_values.empty(), ());
  auto const error = ParseReply(*Parse("$NGA,33,ERR,KEY*78A1"));
  TEST(error && !error->m_ok, ());
  TEST_EQUAL(error->m_error, "KEY", ());
}

UNIT_TEST(NoGps_Esp32_ParsesPhones)
{
  auto const info = ParseInfo(*Parse(
      WithCrc("NGI,1,0.4.2,2026-11-14T21:35,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE CAR PHONES MULTI,3")));
  TEST(info && info->m_hasPhones && info->m_twoPhones && info->m_canStoreCarValues && !info->m_canUpdate, ());
  auto const old = ParseInfo(
      *Parse(WithCrc("NGI,1,0.4.1,2026-11-14T21:35,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA CAR,3")));
  TEST(old && !old->m_hasPhones && !old->m_twoPhones, ());

  auto const recoveryInfo =
      ParseInfo(*Parse(WithCrc("NGI,1,0.4.5,2026-11-20T21:35,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID,BLE OTA CAR "
                               "PHONES MULTI RECOVERY,3")));
  TEST(recoveryInfo && recoveryInfo->m_hasRecovery && !info->m_hasRecovery, ());

  auto const reply = [](std::string const & body) { return *ParseReply(*Parse(WithCrc("NGA,4," + body))); };
  TEST_EQUAL(ParseRecoveryCode(reply("OK,123456")), std::optional<std::string>("123456"), ());
  TEST_EQUAL(ParseRecoveryCode(reply("OK,000042")), std::optional<std::string>("000042"), ());
  for (auto const * bad : {"OK", "OK,12345", "OK,1234567", "OK,12345a", "ERR,BUSY", "ERR,UNKNOWN"})
    TEST(!ParseRecoveryCode(reply(bad)), (bad));
  auto const phones = ParsePhones(reply("OK,BC:D0:74:A9:71:92|Mac mini|1794685760|1;D0:56:FB:11:00:88|||0,0"));
  TEST(phones, ());
  TEST_EQUAL(phones->m_phones.size(), 2, ());
  TEST_EQUAL(phones->m_phones[0], (Phone{"BC:D0:74:A9:71:92", "Mac mini", 1794685760, true, false}), ());
  // This phone doesn't change the box: the only other one does.
  TEST_EQUAL(phones->m_phones[1], (Phone{"D0:56:FB:11:00:88", "", 0, false, true}), ());
  TEST(!phones->m_changesBox, ());
  auto const changes = [](std::optional<Phones> const & phones)
  {
    std::vector<bool> result;
    for (auto const & phone : phones->m_phones)
      result.push_back(phone.m_changesBox);
    return result;
  };
  TEST_EQUAL(changes(ParsePhones(reply("OK,BC:D0:74:A9:71:92|a||1;D0:56:FB:11:00:88|b||0,1"))),
             (std::vector<bool>{true, false}), ());
  // Which of the other phones changes the box is not known.
  TEST_EQUAL(changes(ParsePhones(reply("OK,BC:D0:74:A9:71:92|a||1;D0:56:FB:11:00:88|b||0;D0:56:FB:11:00:89|c||0,0"))),
             (std::vector<bool>{false, false, false}), ());

  // The fifth part names the phone the box takes the changes from, also among 3 phones.
  TEST_EQUAL(
      changes(ParsePhones(reply("OK,BC:D0:74:A9:71:92|a||1|0;D0:56:FB:11:00:88|b||0|0;D0:56:FB:11:00:89|c||0|1,0"))),
      (std::vector<bool>{false, false, true}), ());
  TEST_EQUAL(
      changes(ParsePhones(reply("OK,BC:D0:74:A9:71:92|a||1|1;D0:56:FB:11:00:88|b||0|0;D0:56:FB:11:00:89|c||0|0,1"))),
      (std::vector<bool>{true, false, false}), ());
  // The asking phone changes the box when none has sent HELLO.
  TEST_EQUAL(changes(ParsePhones(reply("OK,BC:D0:74:A9:71:92|a||1|0;D0:56:FB:11:00:88|b||0|0,1"))),
             (std::vector<bool>{true, false}), ());

  // A box without phones. The reply without the last field comes from nobody, it would change the box.
  auto const none = ParsePhones(reply("OK,,1"));
  TEST(none && none->m_phones.empty() && none->m_changesBox, ());
  TEST(ParsePhones(reply("OK,D0:56:FB:11:00:88|||0"))->m_changesBox, ());
  TEST(!ParsePhones(reply("ERR,BT")), ());
  TEST(!ParsePhones(reply("OK,D0:56:FB:11:00:88|x|soon|0,1")), ());
  TEST(!ParsePhones(reply("OK,D0:56:FB:11:00:88|x,1")), ());
}

UNIT_TEST(NoGps_PeerSync_PeerLineFormat)
{
  Peer peer;
  peer.m_kind = 'A';
  peer.m_distMm = 123456;
  peer.m_latE7 = 501234567;
  peer.m_lonE7 = -301234567;
  peer.m_headingCdeg = 9050;
  peer.m_accuracyDm = 50;
  peer.m_source = 'T';
  TEST_EQUAL(PeerCommand(peer), "PEER,A,123456,501234567,-301234567,9050,50,T", ());
  // The box passes the payload on as it is.
  auto const fields = Parse(WithCrc("NGX,1,A,123456,501234567,-301234567,9050,50,T"));
  TEST(fields, ());
  auto const parsed = ParsePeer(*fields);
  TEST(parsed, ());
  TEST(*parsed == peer, ());

  // No heading.
  peer.m_headingCdeg = -1;
  TEST(*ParsePeer(*Parse(WithCrc("NGX,1,A,123456,501234567,-301234567,-1,50,T"))) == peer, ());

  // What is not a place of a phone.
  for (auto const body :
       {"NGX,1,X,1,5,5,100,10,G", "NGX,2,A,1,5,5,100,10,G", "NGX,1,A,1,5,5,100,10", "NGX,1,A,x,5,5,100,10,G",
        "NGX,1,A,1,910000000,5,100,10,G", "NGX,1,A,1,5,5,36000,10,G", "NGX,1,A,1,5,5,100,10,GG",
        "NGD,1,A,1,5,5,100,10,G", "NGX,1,A,1,-2147483648,5,100,10,G", "NGX,1,A,1,5,-2147483648,100,10,G",
        "NGX,1,A,1,5,5,100,-1,G", "NGX,1,A,1,5,5,100,1000001,G", "NGX,1,A,-1,5,5,100,10,G"})
  {
    TEST(!ParsePeer(*Parse(WithCrc(body))), (body));
  }
}

UNIT_TEST(NoGps_PeerSync_InfoHasPeerAbility)
{
  auto const info = [](std::string const & abilities)
  {
    return ParseInfo(*Parse(
        WithCrc("NGI,1,0.4.3,2026-11-18T10:00,esp32s3,s3zero,C47D,4096,2031616,ota_0,VALID," + abilities + ",3")));
  };
  TEST(info("BLE OTA CAR PHONES MULTI PEER")->m_canPeer, ());
  TEST(!info("BLE OTA CAR PHONES MULTI")->m_canPeer, ());
}

UNIT_TEST(NoGps_Esp32_HelloWithNameOfPhone)
{
  TEST_EQUAL(Hello("", 1794685760123), "HELLO", ());
  TEST_EQUAL(Hello("Pixel 8", 1794685760123), "HELLO,Pixel 8,1794685760", ());
  TEST_EQUAL(PhoneName("  iPhone 15 Pro  "), "iPhone 15 Pro", ());
  // The separators of the lines and of the list of the phones, and what is not ASCII, are replaced.
  TEST_EQUAL(PhoneName("a,b*c$d|e;f\tЖ"), "a_b_c_d_e_f___", ());
  TEST_EQUAL(PhoneName("Samsung Galaxy S24 Ultra 5G"), "Samsung Galaxy S24 U", ());
}

UNIT_TEST(NoGps_BoxCarValues_Encoding)
{
  auto const roundTrip = [](std::string_view key, std::string const & value)
  {
    BoxCarValues::Values box;
    for (auto const & [boxKey, boxValue] : BoxCarValues::Encode(key, value))
    {
      TEST_LESS_OR_EQUAL(boxValue.size(), BoxCarValues::kMaxValueSize, (boxKey));
      // Printable ASCII without the separators of the line.
      for (char const c : boxValue)
        TEST(c >= 0x20 && c <= 0x7E && c != ',' && c != '*' && c != '$', (boxKey, boxValue));
      box[boxKey] = boxValue;
    }
    return BoxCarValues::Decode(key, box);
  };

  std::string const name = "Ауді 80, 100% моя*$";
  auto const encodedName = BoxCarValues::Encode(CarStorage::kCarName, name);
  TEST_EQUAL(encodedName.size(), 1, ());
  TEST_EQUAL(encodedName[0].first, "car_name", ());
  TEST_EQUAL(roundTrip(CarStorage::kCarName, name), name, ());
  // A long name is cut between its characters.
  std::string longName;
  for (int i = 0; i < 40; ++i)
    longName += "Ж";
  auto const cut = roundTrip(CarStorage::kCarName, longName);
  TEST(cut && longName.starts_with(*cut), (cut));
  // Each letter takes 6 characters on the box.
  TEST_EQUAL(cut->size(), 2 * (BoxCarValues::kMaxNameSize / 6), ());
  auto const longestName = BoxCarValues::Encode(CarStorage::kCarName, std::string(300, 'a'))[0].second;
  TEST_EQUAL(longestName.size(), BoxCarValues::kMaxNameSize, ());
  TEST_LESS_OR_EQUAL(Command(99999, "CAR_SET,car_name," + longestName).size(), BoxCarValues::kMaxLineSize, ());

  std::string const place = "50.4500000,30.5390470,90,0,1821,51,1700000258500";
  TEST_EQUAL(BoxCarValues::Encode(Storage::kCarPosition, place)[0].second,
             "50.4500000:30.5390470:90:0:1821:51:1700000258500", ());
  TEST_EQUAL(roundTrip(Storage::kCarPosition, place), place, ());

  // The longest table: a range of a speed table keeps up to 10 km of the car.
  std::string table;
  for (int i = 0; i < 14; ++i)
    table += std::string(i > 0 ? ";" : "") + "10000:12500:7200";
  auto const halves = BoxCarValues::Encode(Storage::kSpeedTable, table);
  TEST_EQUAL(halves.size(), 2, ());
  TEST_EQUAL(halves[0].first, "spd_table_lo", ());
  TEST_EQUAL(halves[1].first, "spd_table_hi", ());
  TEST_EQUAL(halves[0].second, halves[1].second, ());
  TEST_EQUAL(roundTrip(Storage::kSpeedTable, table), table, ());
  TEST_LESS_OR_EQUAL(Command(99999, "CAR_SET," + halves[0].first + "," + halves[0].second).size(),
                     BoxCarValues::kMaxLineSize, ());
  // A half without the other one is not a table.
  TEST(!BoxCarValues::Decode(Storage::kSpeedTable, {{halves[0].first, halves[0].second}}), ());

  // An empty value erases the keys of the box.
  for (auto const key : CarStorage::kValuesOnBox)
  {
    for (auto const & [boxKey, boxValue] : BoxCarValues::Encode(key, ""))
      TEST(boxValue.empty(), (key, boxKey));
    TEST(!roundTrip(key, ""), (key));
  }
  TEST_EQUAL(roundTrip(Storage::kSpeedScale, "1.042"), "1.042", ());
}
}  // namespace nogps_esp32_protocol_tests
