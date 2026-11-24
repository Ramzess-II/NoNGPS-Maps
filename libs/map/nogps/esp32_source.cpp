#include "map/nogps/esp32_source.hpp"

#include "map/nogps/clock.hpp"
#include "map/nogps/delegate.hpp"
#include "map/nogps/log_line.hpp"

#include "base/assert.hpp"
#include "base/logging.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <random>

namespace nogps
{
namespace
{
bool IsLinked(BleState state)
{
  return state == BleState::Pairing || state == BleState::Connected;
}

bool HasCalibratedFlags(int flags)
{
  int constexpr kRequired = esp32::kFlagImuOk | esp32::kFlagBiasOk | esp32::kFlagUpOk;
  return (flags & kRequired) == kRequired && (flags & esp32::kFlagMountMoved) == 0;
}
}  // namespace

Esp32Source::Esp32Source(Delegate & delegate, Scheduler & scheduler, Clock const & clock,
                         MotionSource::Listener & listener)
  : m_delegate(delegate)
  , m_clock(clock)
  , m_listener(listener)
  , m_helloTimer(scheduler)
  , m_update(*this, scheduler, clock)
{}

Esp32Source::~Esp32Source()
{
  Stop();
}

void Esp32Source::Start()
{
  if (m_running)
    return;
  LOG(LINFO, ("ESP32 started"));
  m_running = true;
  ForgetAuth();
  m_phoneName = esp32::PhoneName(m_delegate.GetPhoneName());
  m_delegate.Esp32BleOpen();
  SendHello();
}

void Esp32Source::Stop()
{
  if (!m_running)
    return;
  LOG(LINFO, ("ESP32 stopped"));
  m_running = false;
  m_helloTimer.Stop();
  m_delegate.Esp32BleClose();
  m_bleState = BleState::Off;
  m_bleLine.clear();
  m_dataTimesMs.clear();
  m_hasLast = false;
  m_lastDataMs.reset();
  m_batteryLock = BatteryLock::None;
  m_speedKmh = -1;
  m_wakingLinkMs.reset();
  m_info.reset();
  m_carSilent = false;
  m_boxValues.clear();
  m_hellosWithoutInfo = 0;
  m_peer.Reset();
  m_update.Reset();
  ForgetAuth();
  ForgetCarRequests();
  ForgetPhoneRequests();
  m_addPhone.reset();
  ForgetJournal();
}

void Esp32Source::SendHello()
{
  Send(esp32::Hello(m_phoneName, m_clock.UnixNowMs()), ++m_helloId);
  // The box tells about itself when a connection starts, the application may have missed it: the box was
  // talking to it before it was restarted.
  if (!m_info &&
      (IsConnected() || (!m_proven && !m_unprovenInfo && !m_authRefused && m_bleState == BleState::Connected)) &&
      m_hellosWithoutInfo < kInfoRequestHellos * kMaxInfoRequests && ++m_hellosWithoutInfo % kInfoRequestHellos == 0)
  {
    Send("INFO", m_nextCommandId++);
  }
  if (m_authId != 0 && m_clock.NowMs() - m_authSentMs > kAuthReplyTimeoutMs)
  {
    if (m_authSends >= kMaxAuthSends)
      RefuseBox("no reply to the proof");
    else
      SendAuth();
  }
  if (m_carRead && m_clock.NowMs() - m_carRead->m_sentMs > kCarReplyTimeoutMs)
  {
    LOG(LWARNING, ("No reply to the reading of", m_carRead->m_keys.front()));
    m_carRead.reset();
  }
  // Without the list the role of this phone is unknown, and a known list may be stale: the list is asked at
  // once, and again at the next hello when this reply is lost too.
  if (m_listId != 0 && m_clock.NowMs() - m_listSentMs > kCarReplyTimeoutMs)
  {
    LOG(LWARNING, ("No reply to the list of the phones"));
    m_listId = 0;
    ListPhones();
  }
  if (m_recoveryId != 0 && m_clock.NowMs() - m_recoverySentMs > kCarReplyTimeoutMs)
  {
    LOG(LWARNING, ("No reply to the recovery code"));
    m_recoveryId = 0;
    m_recoveryAsked = false;
  }
  AskRecoveryCode();
  // The box may have dropped the command: the list is asked again, the code is not kept.
  if (m_addPhone && m_addPhone->m_state == AddPhone::Opening &&
      m_clock.NowMs() - m_addPhone->m_sentMs > kCarReplyTimeoutMs)
  {
    LOG(LWARNING, ("No reply to the pairing code"));
    m_addPhone->m_state = AddPhone::Failed;
  }
  if (m_forget && m_clock.NowMs() - m_forget->m_sentMs > kCarReplyTimeoutMs)
  {
    LOG(LWARNING, ("No reply to the removal of", m_forget->m_address));
    m_forget.reset();
  }
  m_helloTimer.Start(kHelloIntervalMs, [this] { SendHello(); });
}

int Esp32Source::SendUpdateCommand(std::string const & command)
{
  int const id = m_nextCommandId++;
  Send(command, id);
  return id;
}

void Esp32Source::SendFirmwarePiece(std::string const & piece)
{
  if (m_bleState == BleState::Connected)
    m_delegate.Esp32BleSendFirmware(piece);
}

bool Esp32Source::CanUpdate() const
{
  return m_running && m_bleState == BleState::Connected && m_info && m_info->m_canUpdate && !m_update.IsActive() &&
         !IsReadOnly();
}

void Esp32Source::StartUpdate(Firmware const & firmware)
{
  if (CanUpdate())
    m_update.Start(firmware.m_read(), firmware.m_version, m_info->m_firmware);
}

bool Esp32Source::CanStoreCarValues() const
{
  return m_running && m_bleState == BleState::Connected && m_info && m_info->m_canStoreCarValues &&
         !m_update.IsActive();
}

void Esp32Source::ReadCarValues(std::vector<std::string> keys)
{
  if (!CanStoreCarValues() || keys.empty())
    return;
  m_carRead = CarRead{};
  m_carRead->m_keys = std::move(keys);
  ReadNextCarValue();
}

void Esp32Source::ReadNextCarValue()
{
  auto & read = *m_carRead;
  read.m_id = m_nextCommandId++;
  read.m_sentMs = m_clock.NowMs();
  Send("CAR_GET," + read.m_keys[read.m_values.size()], read.m_id);
}

void Esp32Source::WriteCarValue(std::string const & key, std::string const & value)
{
  if (!CanStoreCarValues())
    return;
  int const id = m_nextCommandId++;
  m_carWrites[id] = {key, value};
  Send("CAR_SET," + key + "," + value, id);
}

bool Esp32Source::OnCarReply(esp32::Reply const & reply)
{
  if (auto const it = m_carWrites.find(reply.m_id); it != m_carWrites.end())
  {
    auto [key, value] = std::move(it->second);
    m_carWrites.erase(it);
    if (!reply.m_ok)
      LOG(LWARNING, ("The box has not written", key, "error =", reply.m_error));
    m_listener.OnBoxCarWritten(key, value, reply.m_ok ? "" : reply.m_error);
    return true;
  }
  if (!m_carRead || reply.m_id != m_carRead->m_id)
    return false;
  auto & read = *m_carRead;
  auto const & key = read.m_keys[read.m_values.size()];
  if (!reply.m_ok)
  {
    LOG(LWARNING, ("The box has not read", key, "error =", reply.m_error));
    m_carRead.reset();
    return true;
  }
  read.m_values[key] = reply.m_values.empty() ? "" : reply.m_values.front();
  if (read.m_values.size() < read.m_keys.size())
  {
    ReadNextCarValue();
    return true;
  }
  auto const values = std::move(read.m_values);
  m_carRead.reset();
  m_listener.OnBoxCarValues(values);
  return true;
}

void Esp32Source::ForgetCarRequests()
{
  // The replies don't come over another link.
  m_carRead.reset();
  m_carWrites.clear();
}

bool Esp32Source::HasPhones() const
{
  return m_running && m_bleState == BleState::Connected && m_info && m_info->m_hasPhones;
}

void Esp32Source::ListPhones()
{
  if (!HasPhones() || m_listId != 0)
    return;
  m_listId = m_nextCommandId++;
  m_listSentMs = m_clock.NowMs();
  Send("BT_LIST", m_listId);
}

void Esp32Source::ListPhonesThrottled()
{
  if (m_clock.NowMs() - m_listSentMs >= kListIntervalMs)
    ListPhones();
}

void Esp32Source::ForgetPhone(std::string const & address)
{
  if (!HasPhones() || IsReadOnly() || m_forget || !m_phones)
    return;
  auto const & phones = m_phones->m_phones;
  auto const it = std::find_if(phones.begin(), phones.end(), [&](auto const & p) { return p.m_address == address; });
  if (it == phones.end())
    return;
  LOG(LINFO, ("Forget the phone", address, "this =", it->m_thisPhone));
  m_forget = ForgetRequest{m_nextCommandId++, address, it->m_thisPhone, m_clock.NowMs()};
  Send("BT_FORGET," + address, m_forget->m_id);
}

void Esp32Source::StartAddPhone()
{
  if (!HasPhones() || IsReadOnly())
    return;
  // The code is what keeps a stranger out: it comes from the random source of the system.
  std::random_device random;
  std::uniform_int_distribution<int> digits(0, 999'999);
  char code[8];
  std::snprintf(code, sizeof(code), "%06d", digits(random));
  m_addPhone = AddPhoneRequest{code, m_nextCommandId++};
  m_addPhone->m_sentMs = m_clock.NowMs();
  m_addPhone->m_lastEvent = m_loggedEvents.empty() ? -1 : *m_loggedEvents.rbegin();
  LOG(LINFO, ("Add a phone"));
  Send("BT_PAIR," + m_addPhone->m_code, m_addPhone->m_id);
}

Esp32Source::AddPhone Esp32Source::GetAddPhoneState() const
{
  if (!m_addPhone)
    return AddPhone::None;
  if (m_addPhone->m_state == AddPhone::Open && GetAddPhoneMsLeft() == 0)
    return AddPhone::Expired;
  return m_addPhone->m_state;
}

int64_t Esp32Source::GetAddPhoneMsLeft() const
{
  if (!m_addPhone || m_addPhone->m_state != AddPhone::Open)
    return 0;
  return std::max<int64_t>(0, m_addPhone->m_openMs + esp32::kPairingWindowMs - m_clock.NowMs());
}

void Esp32Source::AskRecoveryCode()
{
  // Only the phone the box listens to gets the code, and the list tells which one it is.
  if (m_recoveryAsked || !HasRecovery() || !m_phones || m_readOnly)
    return;
  m_recoveryAsked = true;
  m_recoveryId = m_nextCommandId++;
  m_recoverySentMs = m_clock.NowMs();
  Send("BT_RECOVERY", m_recoveryId);
}

bool Esp32Source::OnPhonesReply(esp32::Reply const & reply)
{
  if (m_recoveryId != 0 && reply.m_id == m_recoveryId)
  {
    m_recoveryId = 0;
    if (auto const code = esp32::ParseRecoveryCode(reply))
      m_listener.OnBoxRecoveryCode(*code);
    else
      LOG(LWARNING, ("The box has not told the recovery code, error =", reply.m_error));
    return true;
  }
  if (reply.m_id == m_listId)
  {
    m_listId = 0;
    m_phones = esp32::ParsePhones(reply);
    if (m_phones)
      m_readOnly = !m_phones->m_changesBox;
    else
      LOG(LWARNING, ("The box has not listed its phones, error =", reply.m_error));
    return true;
  }
  if (m_forget && reply.m_id == m_forget->m_id)
  {
    auto const forget = std::move(*m_forget);
    m_forget.reset();
    if (!reply.m_ok)
      LOG(LWARNING, ("The box has not forgotten", forget.m_address, "error =", reply.m_error));
    else if (forget.m_thisPhone)
      m_listener.OnThisPhoneRemoved();
    ListPhones();
    return true;
  }
  if (m_addPhone && reply.m_id == m_addPhone->m_id)
  {
    if (reply.m_ok)
    {
      m_addPhone->m_state = AddPhone::Open;
      m_addPhone->m_openMs = m_clock.NowMs();
    }
    else
    {
      LOG(LWARNING, ("The box has not taken the code, error =", reply.m_error));
      m_addPhone->m_state = reply.m_error == "FULL" ? AddPhone::Full : AddPhone::Failed;
    }
    return true;
  }
  return false;
}

void Esp32Source::ForgetPhoneRequests()
{
  // Without the reply this phone is not known to be removed: the box drops the link after it.
  m_forget.reset();
  m_listId = 0;
  m_phones.reset();
  m_readOnly = false;
  m_recoveryAsked = false;
  m_recoveryId = 0;
  // The box keeps the window open without the link, but this phone can't hear the new one pair.
  if (m_addPhone && m_addPhone->m_state == AddPhone::Opening)
    m_addPhone->m_state = AddPhone::Failed;
}

void Esp32Source::OnInfo(esp32::Info const & info)
{
  if (!m_info || m_info->m_firmware != info.m_firmware)
    LOG(LINFO, (LogHead(m_clock, "ACTION", "box_info"), "Box", info.m_id, "firmware =", info.m_firmware, info.m_chip,
                info.m_board, info.m_revision, "updates =", info.m_canUpdate));
  bool const phonesNew = info.m_hasPhones && (!m_info || !m_info->m_hasPhones);
  m_info = info;
  m_update.OnBoxFirmware(info.m_firmware);
  m_listener.OnBoxHeard(info.m_id, info.m_firmware);
  // The list tells if this phone changes the box.
  if (phonesNew)
    ListPhones();
}

void Esp32Source::StoreBoxValues(esp32::Fields const & fields)
{
  for (auto & [id, value] : esp32::ParseBoxValues(fields))
    m_boxValues[id] = std::move(value);
}

esp32::BoxValues Esp32Source::GetBoxValues() const
{
  if (m_bleState != BleState::Connected)
    return {};
  esp32::BoxValues values;
  for (int i = 0; i <= static_cast<int>(esp32::BoxValue::LastEvent); ++i)
  {
    auto const id = static_cast<esp32::BoxValue>(i);
    auto const it = m_boxValues.find(id);
    std::string value = it == m_boxValues.end() ? std::string() : it->second;
    // The events of the box tell it too. The box tells about the car in the status of version 3 of the spec.
    if (id == esp32::BoxValue::VoltageMismatch && m_boxValues.contains(esp32::BoxValue::Engine))
      value = m_voltageMismatch ? "1" : "0";
    values.emplace_back(id, std::move(value));
  }
  return values;
}

void Esp32Source::Send(std::string_view command, int id)
{
  if (m_bleState == BleState::Connected)
    m_delegate.Esp32BleSend(esp32::Command(id, command));
}

void Esp32Source::OnBleState(BleState state, bool bondLost)
{
  if (!m_running || (state == m_bleState && bondLost == m_bondLost))
    return;
  LOG(LINFO, (LogHead(m_clock, "ACTION", "ble_state"), "Bluetooth =", state, "bond lost =", bondLost));
  // A connection may be pending all the time the box sleeps: only a made one tells that the box is awake. The one
  // that probes a pairing thought lost carries nothing, until the box is heard.
  bool const wasLinked = IsLinked(m_bleState) && !m_bondLost;
  if ((IsLinked(state) && !bondLost) || (wasLinked && m_wakingLinkMs))
    m_wakingLinkMs = m_clock.NowMs();
  m_bondLost = bondLost;
  if (state == m_bleState)
    return;
  m_bleState = state;
  m_bleLine.clear();
  ForgetAuth();
  if (state != BleState::Connected)
  {
    // Another box may be found, or this one with a new firmware.
    m_info.reset();
    m_carSilent = false;
    m_boxValues.clear();
    m_shake.clear();
    m_hellosWithoutInfo = 0;
    m_peer.Reset();
    m_update.OnLinkLost();
    ForgetCarRequests();
    ForgetPhoneRequests();
    ForgetJournal();
    if (m_batteryLock == BatteryLock::Told)
      m_batteryLock = BatteryLock::LinkLost;
    if (m_calibrationId != 0)
    {
      LOG(LWARNING, ("The link is lost during the calibration"));
      m_calibrationId = 0;
      m_calibrationProgress = 0;
      m_calibrationLinkLostMs = m_clock.NowMs();
    }
  }
  // The box starts sending at once, not at the next HELLO.
  if (state == BleState::Connected)
    SendHello();
}

void Esp32Source::OnBleBytes(std::string_view bytes)
{
  if (!m_running)
    return;
  for (char const c : bytes)
  {
    // A line starts with "$": what was received of a line cut in the middle is dropped.
    if (c == '$')
      m_bleLine.clear();
    else if (m_bleLine.empty())
      continue;
    if (c == '\n')
    {
      OnLine(m_bleLine);
      m_bleLine.clear();
    }
    else if (m_bleLine.size() < kMaxLineSize)
    {
      m_bleLine += c;
    }
    else
    {
      m_bleLine.clear();
    }
  }
}

Esp32Source::DataRate Esp32Source::GetDataRate() const
{
  int64_t const now = m_clock.NowMs();
  DataRate rate;
  int64_t previousMs = now - kDataTimeoutMs;
  for (int64_t const timeMs : m_dataTimesMs)
  {
    if (timeMs <= now - kDataTimeoutMs)
      continue;
    ++rate.m_lines;
    rate.m_maxGapMs = std::max(rate.m_maxGapMs, timeMs - previousMs);
    previousMs = timeMs;
  }
  rate.m_maxGapMs = std::max(rate.m_maxGapMs, now - previousMs);
  return rate;
}

void Esp32Source::OnLine(std::string_view text)
{
  auto const fields = esp32::Parse(text);
  if (!fields)
    return;
  if (!m_proven)
  {
    OnUnprovenLine(*fields);
    return;
  }
  if (auto const data = esp32::ParseData(*fields))
  {
    OnData(*data);
    return;
  }
  if (auto const reply = esp32::ParseReply(*fields))
  {
    OnReply(*reply);
    return;
  }
  if (auto const peer = esp32::ParsePeer(*fields))
  {
    OnPeer(*peer);
    return;
  }
  if (auto const event = esp32::ParseEvent(*fields))
  {
    OnEvent(*event);
    return;
  }
  if (auto const info = esp32::ParseInfo(*fields))
  {
    // The box has proved the id it gave: a device that says it is another box is not taken for it.
    if (m_mustProve && info->m_id != m_authCar)
      return RefuseBox("it says it is " + info->m_id + ", not " + m_authCar);
    OnInfo(*info);
    StoreBoxValues(*fields);
    return;
  }
  if (auto const progress = esp32::ParseUpdateProgress(*fields))
  {
    m_update.OnProgress(*progress);
    return;
  }
  StoreBoxValues(*fields);
  if (auto const lastNumber = esp32::ParseLastEventNumber(*fields))
    OnLastEventNumber(*lastNumber);
  if (auto const imuName = esp32::ParseImuName(*fields))
    m_imuName = *imuName;
  if (auto const carInfo = esp32::ParseCarInfo(*fields))
  {
    if (carInfo->m_boxMillivolts >= 0 && carInfo->GetReferenceMillivolts() >= 0)
      m_voltageMismatch = carInfo->m_voltageMismatch;
    m_carInfo = carInfo;
    // The engine speed on the move is for the check of the speed it gives: the status comes less often than the
    // speed, this line tells how often.
    if (carInfo->m_rpm >= 0 && m_speedKmh > 0 && IsConnected())
      LOG(LINFO, (LogHead(m_clock, "RPM"), carInfo->m_rpm, "speed =", m_speedKmh));
  }
  auto const obdState = esp32::ParseObdState(*fields);
  if (obdState && obdState != m_obdState)
  {
    LOG(LINFO, (LogHead(m_clock, "EVENT", "obd_state"), "OBD state =", *obdState));
    m_obdState = obdState;
    if (*obdState == "NO_ADAPTER")
      m_obdAdapterMissing = true;
    else if (*obdState != "INIT")
      m_obdAdapterMissing = false;
  }
  // A link made again may start with the same state.
  if (obdState == "NO_CAR" || obdState == "NO_DATA")
    m_carSilent = true;
  else if (obdState && obdState != "SEARCHING")
    m_carSilent = false;
}

void Esp32Source::ForgetAuth()
{
  m_mustProve = m_delegate.Esp32BoxMustProveItself();
  m_proven = !m_mustProve;
  m_authRefused = false;
  m_unprovenInfo.reset();
  m_authId = 0;
  m_authSends = 0;
  m_authCar.clear();
  m_authKey.clear();
  m_authNonce.clear();
  m_authSetsKey = false;
  m_authKeyUnconfirmed = false;
}

std::string Esp32Source::NewAuthHex(size_t bytes) const
{
  std::random_device device;
  std::uniform_int_distribution<int> digit(0, 15);
  std::string hex;
  for (size_t i = 0; i < bytes * 2; ++i)
    hex += "0123456789abcdef"[digit(device)];
  return hex;
}

void Esp32Source::OnUnprovenLine(esp32::Fields const & fields)
{
  if (m_authRefused)
    return;
  if (auto const reply = esp32::ParseReply(fields))
  {
    if (reply->m_id == m_authId)
      OnAuthReply(*reply);
    return;
  }
  if (esp32::ParseInfo(fields))
    OnAuthInfo(fields);
}

void Esp32Source::OnAuthInfo(esp32::Fields const & fields)
{
  auto const info = esp32::ParseInfo(fields);
  CHECK(info, ());
  // The proof is of the id the box has given: a device that says it is another box meanwhile is not taken for it.
  if (!m_authCar.empty() && info->m_id != m_authCar)
    return RefuseBox("it says it is " + info->m_id + ", not " + m_authCar);
  // The box says who it is: what it says is taken only when it has proved it, the info is kept till then.
  m_unprovenInfo = fields;
  if (m_authId != 0 || info->m_id.empty())
    return;
  bool confirmed = false;
  auto const key = m_listener.GetBoxAuthKey(info->m_id, confirmed);
  if (!info->m_canAuth)
  {
    // A box that could prove itself must not become one that can't: a box of a firmware before the proof is taken
    // only for a car whose box has never proved one. An unconfirmed key is no proof -- the box may never have taken
    // it, and the firmware that took it may be rolled back (FW-6) -- so such a box is taken and keeps its key for the
    // day it can prove itself again.
    if (confirmed)
      return RefuseBox("the box of a car that proved it no longer can");
    LOG(LWARNING, ("The firmware", info->m_firmware, "of the box", info->m_id, "can not prove itself"));
    m_authCar = info->m_id;
    m_proven = true;
    OnInfo(*info);
    StoreBoxValues(fields);
    m_unprovenInfo.reset();
    return;
  }
  m_authCar = info->m_id;
  m_authSetsKey = key.empty();
  m_authKey = key;
  m_authKeyUnconfirmed = !key.empty() && !confirmed;
  if (m_authSetsKey)
  {
    m_authKey = NewAuthHex(esp32::kAuthKeyBytes);
    // The box may take the key and the reply be lost with the link: the key is kept at once, unconfirmed, so that the
    // next session proves the box with it instead of making another one the box would refuse.
    m_authKeyUnconfirmed = true;
    m_listener.OnBoxAuthKey(m_authCar, m_authKey, false /* confirmed */);
  }
  SendAuth();
}

void Esp32Source::SendAuth()
{
  m_authId = m_nextCommandId++;
  m_authSentMs = m_clock.NowMs();
  ++m_authSends;
  if (m_authSetsKey)
  {
    Send("AUTH_SET," + m_authKey, m_authId);
    return;
  }
  // A new nonce for every try: a proof heard before is of no use.
  m_authNonce = NewAuthHex(esp32::kAuthNonceBytes);
  Send("AUTH," + m_authNonce, m_authId);
}

void Esp32Source::OnAuthReply(esp32::Reply const & reply)
{
  if (reply.m_progress)
    return;
  if (!reply.m_ok)
  {
    // The box has not got the key the phone keeps unconfirmed: the phone gives it the same one. Nothing is given away
    // that a new pairing would not get, as a car whose box never took its key trusts the first box that answers.
    if (reply.m_error == "NOKEY" && m_authKeyUnconfirmed && !m_authSetsKey)
    {
      LOG(LINFO, ("The box", m_authCar, "has not got the key it was given: it is given it again"));
      m_authSetsKey = true;
      m_authSends = 0;
      m_authId = 0;
      SendAuth();
      return;
    }
    return RefuseBox("the box says " + reply.m_error);
  }
  if (!m_authSetsKey)
  {
    auto const proof = esp32::AuthProof(m_authKey, m_authNonce);
    std::string answer = reply.m_values.empty() ? "" : reply.m_values.front();
    std::transform(answer.begin(), answer.end(), answer.begin(), [](unsigned char c) { return std::tolower(c); });
    if (proof.empty() || answer != proof)
      return RefuseBox("the proof is wrong");
  }
  // The box has it: the first session of a pairing is trusted, the system has bonded the box and the key goes over
  // that link.
  if (m_authKeyUnconfirmed)
    m_listener.OnBoxAuthKey(m_authCar, m_authKey, true /* confirmed */);
  LOG(LINFO, ("The box", m_authCar, m_authSetsKey ? "has taken a key" : "has proved itself"));
  m_proven = true;
  m_refusalTold = false;
  m_authId = 0;
  auto const fields = std::move(*m_unprovenInfo);
  m_unprovenInfo.reset();
  m_authKey.clear();
  if (auto const info = esp32::ParseInfo(fields))
  {
    OnInfo(*info);
    StoreBoxValues(fields);
  }
}

void Esp32Source::RefuseBox(std::string const & reason)
{
  LOG(LWARNING, ("The box", m_authCar, "is refused:", reason));
  m_proven = false;
  m_authRefused = true;
  m_authId = 0;
  m_unprovenInfo.reset();
  m_authKey.clear();
  // Told once until a box proves itself, so a link that drops and comes back doesn't repeat the notice.
  if (!m_refusalTold)
    m_listener.OnBoxRefused();
  m_refusalTold = true;
}

void Esp32Source::OnData(esp32::Data const & data)
{
  int64_t const now = m_clock.NowMs();
  bool const fresh = m_lastDataMs && now - *m_lastDataMs <= kDataTimeoutMs;
  int64_t const lastDataMs = m_lastDataMs.value_or(now);
  int const lastFlags = m_flags;
  m_lastDataMs = now;
  m_wakingLinkMs.reset();
  // The box answers over a link made after the one that told the lockout: switched off it could not, so it has been
  // plugged back in. Its own time doesn't tell that by itself: the box may have locked seconds after a power-on and
  // be heard later than that, and a time that has run past 2^31 ms looks wrapped around after the restart.
  if (m_batteryLock == BatteryLock::LinkLost)
    m_batteryLock = BatteryLock::None;
  m_dataTimesMs.push_back(now);
  while (now - m_dataTimesMs.front() >= kDataTimeoutMs)
    m_dataTimesMs.pop_front();
  m_flags = data.m_flags;
  if (data.m_shakePct >= 0)
  {
    m_shake.push_back(data.m_shakePct);
    if (m_shake.size() > kShakeLines)
      m_shake.pop_front();
  }
  // The box has restarted, its totals start anew: the places carried by them are lost.
  if (m_hasLast && data.m_timeMs < m_lastTimeMs && m_lastTimeMs - data.m_timeMs < kBoxTimeWrapMs / 2)
    m_peer.Reset();
  m_peer.OnBoxData(now, data.m_distMm, data.m_yawMdeg);
  m_speedKmh = data.m_speedKmh;
  if (data.m_speedKmh >= 0)
    m_listener.OnSpeed(data.m_speedKmh, now - data.m_speedAgeMs);
  // For the trip log only, see AccelLog.
  if (data.m_hasAccel)
  {
    auto const line =
        m_accelLog.OnSample(data.m_timeMs * 1'000'000, data.m_accelH1, data.m_accelH2, data.m_accelUp, data.m_jolt);
    // What the sensor has felt before a break is not before the start.
    if (!fresh)
      m_accelLinesBeforeStart.clear();
    if (line && data.m_speedKmh > 0)
    {
      // The car reports that it moves a second late. What the sensor has felt before that tells which way the car
      // has started, forward or backward.
      for (size_t i = 0; i < m_accelLinesBeforeStart.size(); ++i)
        LOG(LINFO, (LogHead(m_clock, "ACCB_BEFORE"), m_accelLinesBeforeStart.size() - i, m_accelLinesBeforeStart[i]));
      m_accelLinesBeforeStart.clear();
      LOG(LINFO, (LogHead(m_clock, "ACCB"), *line));
    }
    else if (line)
    {
      m_accelLinesBeforeStart.push_back(std::move(*line));
      if (m_accelLinesBeforeStart.size() > kAccelLinesBeforeStart)
        m_accelLinesBeforeStart.pop_front();
    }
    m_listener.OnSourceAccel({data.m_accelH1, data.m_accelH2, data.m_accelUp});
  }

  // The time of the box has gone back, and not because its 32 bits have wrapped around: the box has restarted
  // and counts its rotation and its events from the start.
  if (m_hasLast && data.m_timeMs < m_lastTimeMs && m_lastTimeMs - data.m_timeMs < kBoxTimeWrapMs / 2)
  {
    LOG(LINFO, ("The box has restarted"));
    ForgetJournal();
    m_hasLast = false;
    // The data after BATT_LOCK, which the box sends for a second more, doesn't drop the lockout hint, a restart does.
    m_batteryLock = BatteryLock::None;
  }

  // The box sends the totals: a lost line loses nothing, the next one has the rotation.
  if (m_hasLast)
  {
    int64_t const dtMs = (data.m_timeMs - m_lastTimeMs) & (kBoxTimeWrapMs - 1);
    double const yawDeltaDeg = IsCalibrated() ? (data.m_yawMdeg - m_lastYawMdeg) / 1000.0 : 0;
    if (fresh && dtMs <= kDataTimeoutMs)
    {
      m_listener.OnMotion(yawDeltaDeg, dtMs / 1000.0, now * 1'000'000);
    }
    // The box has counted through a pause unless its calibration has changed meanwhile. The pause comes as the lines
    // the box would have sent, with its mean rotation: one step of many degrees is not a turn rate.
    else if (dtMs <= kMaxBridgedPauseMs && HasCalibratedFlags(lastFlags) == HasCalibratedFlags(data.m_flags))
    {
      LOG(LINFO, ("The box data paused for", dtMs, "ms, rotation =", yawDeltaDeg));
      int64_t const steps = std::max<int64_t>(1, (dtMs + kLineIntervalMs - 1) / kLineIntervalMs);
      for (int64_t i = 1; i <= steps; ++i)
      {
        int64_t const stepMs = lastDataMs + (now - lastDataMs) * i / steps;
        m_listener.OnMotion(yawDeltaDeg / steps, dtMs / 1000.0 / steps, stepMs * 1'000'000);
      }
    }
    else
    {
      LOG(LINFO, ("The box data paused for", dtMs, "ms, its rotation is not counted"));
    }
  }
  m_hasLast = true;
  m_lastTimeMs = data.m_timeMs;
  m_lastYawMdeg = data.m_yawMdeg;
  // For the potholes, after the motion: a hit is placed where this line has moved the car. A line without the
  // accelerations gives 0, which still ends a hit.
  m_listener.OnJolt(data.m_jolt, data.m_speedKmh);
}

bool Esp32Source::CanPeer() const
{
  return HasPhones() && m_info->m_canPeer;
}

PeerRole Esp32Source::GetPeerRole() const
{
  if (!CanPeer())
    return PeerRole::None;
  if (m_readOnly)
    return PeerRole::Following;
  // The box lists the phones paired with it: with one phone there is nobody to tell the place to.
  return m_phones && m_phones->m_phones.size() > 1 ? PeerRole::Leading : PeerRole::None;
}

std::string Esp32Source::GetLeaderName() const
{
  if (GetPeerRole() != PeerRole::Following || !m_phones)
    return {};
  for (auto const & phone : m_phones->m_phones)
    if (!phone.m_thisPhone && phone.m_changesBox)
      return phone.m_name;
  return {};
}

bool Esp32Source::SendPeer(PeerTrigger trigger, PeerOutPlace const & place)
{
  auto const peer = m_peer.MakeMessage(GetPeerRole(), trigger, m_clock.NowMs(), place);
  if (!peer)
    return false;
  Send(esp32::PeerCommand(*peer), m_nextCommandId++);
  return true;
}

void Esp32Source::OnPeer(esp32::Peer const & peer)
{
  auto const place = m_peer.OnReceived(GetPeerRole(), peer);
  if (!place)
  {
    LOG(LINFO, ("The place of the other phone is dropped, kind =", peer.m_kind, "dist =", peer.m_distMm));
    return;
  }
  m_listener.OnPeerPlace(*place);
}

void Esp32Source::OnEvent(esp32::Event const & event)
{
  int64_t const lastNumber = m_loggedEvents.empty() ? -1 : *m_loggedEvents.rbegin();
  // The journal of the box sent on request comes after the new events, so the order doesn't matter.
  if (!m_loggedEvents.insert(event.m_number).second)
    return;
  if (m_loggedEvents.size() > kMaxLoggedEvents)
    m_loggedEvents.erase(m_loggedEvents.begin());
  // The errors of the box are logged to find later why the speed or the gyroscope was lost.
  if (event.m_level == "I")
    LOG(LINFO, (LogHead(m_clock, "EVENT", "box_event"), "Box event #", event.m_number, "at", event.m_timeMs,
                "ms:", event.m_code, event.m_text));
  else
    LOG(LWARNING, (LogHead(m_clock, "EVENT", "box_event"), "Box event #", event.m_number, "at", event.m_timeMs,
                   "ms:", event.m_code, event.m_text));
  // The box compares the raw voltage, the status has the corrected one.
  if (event.m_code == "VOLT_MISMATCH")
    m_voltageMismatch = true;
  else if (event.m_code == "VOLT_CAL")
    m_voltageMismatch = false;
  // The box has switched itself off until it is unplugged. A journal replay of an event older than one seen (a later
  // BOOT, say) must not bring the lock back.
  else if (event.m_code == "BATT_LOCK" && event.m_number > lastNumber)
    m_batteryLock = BatteryLock::Told;
  // "fw 0.3.3 reset POWERON": the box was plugged in. It restarts by itself for other reasons. A BOOT doesn't drop
  // the lockout hint: the box sends it only in the journal of the link, after the events of this link, so the BOOT
  // of a new power-on can't be told from the replayed one of the locked power-on. The data of the new link do.
  else if (event.m_code == "BOOT")
    m_poweredOn = event.m_text.ends_with("reset POWERON");
  else if (event.m_code == "BT_PAIR_OPEN" && m_addPhone && m_addPhone->m_openEvent < 0 &&
           event.m_number > m_addPhone->m_lastEvent)
  {
    m_addPhone->m_openEvent = event.m_number;
  }
  else if (event.m_code == "BT_PAIRED" && m_addPhone && m_addPhone->m_state == AddPhone::Open &&
           m_addPhone->m_openEvent >= 0 && event.m_number > m_addPhone->m_openEvent)
  {
    m_addPhone->m_state = AddPhone::Added;
    ListPhones();
  }
  // The phones are erased but this one and the code is renewed: the list is asked, the code follows it. Only a live
  // event: the same one replayed from the journal after a reconnect would blink the phone rows and spend a BT_LIST.
  else if (event.m_code == "BT_RESET" && event.m_number > lastNumber)
  {
    m_recoveryAsked = false;
    m_recoveryId = 0;
    m_phones.reset();
    m_readOnly = false;
    m_listId = 0;
    ListPhones();
  }
  // The phones changed: the role may have passed from one to the other, with this link up.
  else if ((event.m_code == "PHONE_LOST" || event.m_code == "PHONE_CONNECTED") && m_phones &&
           m_phones->m_phones.size() >= 2)
  {
    ListPhones();
  }
  if (event.m_number > lastNumber + 1)
    RequestLostEvents(lastNumber + 1);
}

void Esp32Source::RequestLostEvents(int64_t fromNumber)
{
  // The events were lost or came before the connection, the journal of the box has them.
  int64_t const now = m_clock.NowMs();
  if (m_eventsRequestMs && now - *m_eventsRequestMs < kEventsRequestIntervalMs)
    return;
  m_eventsRequestMs = now;
  Send("EVENTS," + std::to_string(fromNumber), m_nextCommandId++);
}

void Esp32Source::ForgetJournal()
{
  // The journal is asked from its start again.
  m_loggedEvents.clear();
  m_poweredOn = false;
}

void Esp32Source::OnLastEventNumber(int64_t lastNumber)
{
  if (lastNumber < 0)
    return;
  // The box has restarted and counts its events again.
  if (!m_loggedEvents.empty() && lastNumber < *m_loggedEvents.rbegin())
    ForgetJournal();
  int64_t const loggedNumber = m_loggedEvents.empty() ? -1 : *m_loggedEvents.rbegin();
  if (lastNumber > loggedNumber)
    RequestLostEvents(loggedNumber + 1);
}

void Esp32Source::OnReply(esp32::Reply const & reply)
{
  // BUSY is also a calibration or an update that runs: only the list tells if another phone changes the box.
  if (!reply.m_ok && reply.m_error == "BUSY")
    ListPhonesThrottled();
  if (m_update.OnReply(reply) || OnCarReply(reply) || OnPhonesReply(reply) || reply.m_id != m_calibrationId)
    return;
  if (reply.m_progress)
  {
    m_calibrationProgress = *reply.m_progress;
    return;
  }
  LOG(LINFO, ("Calibration: ok =", reply.m_ok, "error =", reply.m_error));
  m_calibrationId = 0;
  m_calibrationFailed = !reply.m_ok;
  if (reply.m_ok)
    m_calibratedMs = m_clock.NowMs();
}

std::optional<Esp32Source::PowerOn> Esp32Source::GetPowerOn() const
{
  if (!m_poweredOn || !m_hasLast || !IsConnected())
    return {};
  // The box counts its time from its start.
  int64_t const uptimeMs = m_lastTimeMs + m_clock.NowMs() - *m_lastDataMs;
  return PowerOn{m_clock.UnixNowMs() - uptimeMs, uptimeMs};
}

bool Esp32Source::IsConnected() const
{
  return m_running && m_lastDataMs && m_clock.NowMs() - *m_lastDataMs <= kDataTimeoutMs;
}

SourceState Esp32Source::GetState() const
{
  if (!m_running)
    return SourceState::Disconnected;
  // The box sends no data while it takes a firmware and restarts with it.
  if (m_update.IsActive())
    return SourceState::Updating;
  if (!IsConnected())
  {
    if (m_batteryLock != BatteryLock::None)
      return SourceState::BoxBatteryLock;
    return IsSleeping() ? SourceState::BoxSleeping : SourceState::Connecting;
  }
  if (m_flags & esp32::kFlagObdOk)
    return SourceState::Connected;
  if (m_obdState == "SLEEP")
    return SourceState::ObdSleeping;
  // OBD_ABSENT is set also when ELM327 is off in the box, only the status tells one from another.
  if (m_obdAdapterMissing)
    return SourceState::NoAdapter;
  if (!m_obdState)
    return SourceState::NoCarData;
  if (*m_obdState == "DISABLED")
    return SourceState::ObdDisabled;
  // The box searches the protocol again every few seconds while the car is silent.
  if (*m_obdState == "SEARCHING" && m_carSilent)
    return SourceState::NoCarData;
  if (*m_obdState == "INIT" || *m_obdState == "SEARCHING")
    return SourceState::ObdConnecting;
  if (*m_obdState == "ERROR")
    return SourceState::ObdError;
  // NO_CAR and NO_DATA: the adapter answers, the car doesn't.
  return SourceState::NoCarData;
}

bool Esp32Source::IsSleeping() const
{
  // The box switches its radio off a minute after the engine is stopped, so a box that has gone after it has told
  // about the stopped engine is not lost. Connected again, it is awake even before it talks: the first connections
  // after a parking may stay silent, and the phone connects again and again.
  if (!m_lastDataMs)
    return false;
  if (m_wakingLinkMs &&
      ((IsLinked(m_bleState) && !m_bondLost) || m_clock.NowMs() - *m_wakingLinkMs <= kWakingLinkGapMs))
    return false;
  return m_obdState == "SLEEP" || (m_carInfo && m_carInfo->m_engineRunning == false);
}

std::optional<CarInfo> Esp32Source::GetCarInfo() const
{
  if (!IsConnected() || !m_carInfo)
    return {};
  CarInfo car = *m_carInfo;
  car.m_voltageMismatch = m_voltageMismatch;
  return car;
}

bool Esp32Source::IsCalibrated() const
{
  return IsConnected() && HasCalibratedFlags(m_flags);
}

CalibrationState Esp32Source::GetCalibrationState()
{
  if (m_calibrationId != 0 && m_clock.NowMs() - m_calibrationStartMs > kCalibrationTimeoutMs)
  {
    LOG(LWARNING, ("No reply to the calibration"));
    m_calibrationId = 0;
    m_calibrationFailed = true;
  }
  if (m_calibrationId != 0)
    return CalibrationState::Calibrating;
  if (m_calibrationLinkLostMs)
  {
    if (!m_lastDataMs || *m_lastDataMs <= *m_calibrationLinkLostMs)
      return CalibrationState::LinkLost;
    m_calibrationLinkLostMs.reset();
  }
  if (m_calibrationFailed)
    return CalibrationState::FailedMoving;
  if (IsConnected() && (m_flags & esp32::kFlagMountMoved))
    return CalibrationState::MountMoved;
  return IsCalibrated() ? CalibrationState::Done : CalibrationState::None;
}

void Esp32Source::Calibrate()
{
  // The box can't hear the command, and no answer would come to end the calibration. Another phone calibrates.
  if (m_bleState != BleState::Connected || IsReadOnly())
    return;
  // The box zeroes the gyroscope and finds its vertical in the car at once.
  m_calibrationId = m_nextCommandId++;
  m_calibrationStartMs = m_clock.NowMs();
  m_calibrationProgress = 0;
  m_calibrationFailed = false;
  m_calibrationLinkLostMs.reset();
  LOG(LINFO, ("Calibration, id =", m_calibrationId));
  Send("CAL_UP", m_calibrationId);
}

std::string Esp32Source::GetDeviceName() const
{
  return m_imuName.empty() ? "NonGPS-OBD" : "NonGPS-OBD · " + m_imuName;
}
std::string DebugPrint(Esp32Source::AddPhone state)
{
  switch (state)
  {
  case Esp32Source::AddPhone::None: return "None";
  case Esp32Source::AddPhone::Opening: return "Opening";
  case Esp32Source::AddPhone::Open: return "Open";
  case Esp32Source::AddPhone::Added: return "Added";
  case Esp32Source::AddPhone::Expired: return "Expired";
  case Esp32Source::AddPhone::Full: return "Full";
  case Esp32Source::AddPhone::Failed: return "Failed";
  }
  UNREACHABLE();
}
}  // namespace nogps
