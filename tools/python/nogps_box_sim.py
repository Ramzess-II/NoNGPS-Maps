#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyobjc-framework-CoreBluetooth>=10; sys_platform == 'darwin'",
#     "dbus-next>=0.2.3; sys_platform == 'linux'",
#     "winsdk>=1.0.0b10; sys_platform == 'win32' and python_version < '3.13'",
# ]
# ///
"""The sensor box of NonGPS Maps, simulated on this computer so a phone can find it without the hardware.

  just box [--radio auto|macos|linux|windows|fake] [--id S] [--port 0] [--no-browser]
  uv run --script tools/python/nogps_box_sim.py [the same]

The box stands in a parked car: it advertises the service of the box over Bluetooth LE and sends the NGI, NGS and
NGD lines of docs/nogps/esp32-firmware-spec.md section 9. A panel in the browser shows what is going on and changes
what the box says: the flags, the state of the OBD adapter, the shake, the version. The mark on the phone doesn't
move, and nothing here is kept between runs.

A debug build of the application is needed on Android: the simulator asks for no pairing, and a release build takes
the lines of a paired box alone. iOS doesn't check the pairing, but on macOS CoreBluetooth can't advertise the
manufacturer data of BLE-13, so the pairing window flag never reaches the phone, and only a debug build takes an
advertisement without that data as a box that accepts a new phone. BlueZ on Linux does advertise it, the panel sets
the flags there, and an iOS release build connects to the simulator as it does to a box. Windows keeps the name
and the manufacturer data of an advertisement for itself, so the radio there advertises neither and a debug build
is needed as on macOS; it is written without a machine to try it on, see its docstring.

What it doesn't simulate, and why:
- the pairing rules (BLE-11, BLE-12, BLE-15, BLE-16): on macOS pairing belongs to the system, with no code of 123456
  and no "display only" capability; so no drop of a link that stays unencrypted and no BT_UNSECURE event, and the
  write queue of BLE-5 is the radio's, not ours;
- any motion: no speed, no turns, no jolts;
- the firmware update, the car values and the places of two phones: NGI tells the ability "BLE" and no more, so the
  application doesn't update the box, and CAR_GET, CAR_SET and PEER get ERR,UNKNOWN as from any box that doesn't know
  them (the application reads only OTA from the abilities);
- the phones: a phone is bonded here at its first HELLO, by its name, as the firmware bonds it at pairing, with an
  address made from the name, as the system gives the simulator none. BT_PAIR,<code> sets the pairing flag of the
  advertisement and nothing closes it: no window of 120 s, no code asked from the phone, and bare BT_PAIR gets
  ERR,VALUE. A phone that is bonded and gone stays in the list until the panel, BT_FORGET,<address> or
  FACTORY_RESET removes it. The window after a power-on and the recovery window (BLE-16) take the code 123456 on a
  real box and no code here; the panel's "3 quick power-ons" opens the recovery window, in which a new phone erases
  nobody and a full box drops the phone with the oldest last HELLO (the event BT_DROP);
- FACTORY_RESET: the leader gets OK, and half a second later the box is new -- no bond, no key, the pairing window
  open, every link dropped. The other phone gets ERR,BUSY. The box doesn't restart: the program keeps its panel
  state.

The box proves itself as section 9.5 says: AUTH_SET takes a key of a phone, AUTH answers with the proof of it. A key
outlives the program in the file of --keys, as the firmware keeps it in NVS over a restart: otherwise the application,
which keeps its key, would refuse the simulator from its second run on. The keys of each box id are its own, so the
id the panel sets brings its own keys. The panel's "Forget the keys" is a box that has lost them, which the
application refuses until the car is forgotten in it.

A key belongs to the phone whose name is in its HELLO (9.2), not to the id the radio gives the link: the simulator
asks for no pairing, so the system can't resolve the private address of a phone and gives a new id about every 15
minutes (CBCentral.identifier on macOS, the BlueZ device path on Linux), while the firmware keeps the key with the
bond. So two phones that give one name share a key here, which the firmware would keep apart.

The bonds do not outlive the program, the keys do. So the first HELLO of a run bonds its phone in the pairing window as
a phone that has just paired, and AUTH_SET with a new key on that first link replaces the kept key: a 0.6.1 box, which
keeps the bond, answers ERR,EXISTS there. To see that refusal, send AUTH_SET with another key on a later link of the
same run, or start with --keys '' (no kept keys).

The radio needs a package -- PyObjC on macOS, dbus-next on Linux, winsdk on Windows -- and the script declares
them above, each for its own platform, so uv puts them in an environment of its own and nothing is installed into
the system Python. winsdk has no wheel past Python 3.12 and is declared for those alone: the radio of Windows needs
an interpreter of 3.10 to 3.12, `uv run --python 3.12 --script`. The panel and the tests need no package at
all and run with plain python3, which is how CI runs them.

A radio is a class Radio in nogps_box_sim_radio_<platform>.py with:
  name, supports_manufacturer_data
  on_event(kind, phone_id, arg): set by the box. 'connect' (arg: the name to show), 'subscribe' (arg: how many bytes
      a notification holds), 'disconnect' (arg: None), 'write' (arg: the bytes written to RX or OTA)
  advertise(name, manufacturer): start or change the advertisement, manufacturer is bytes or None
  stop_advertising()
  send(phone_id, data) -> bool: one notification; False when the stack can't take it now (BLE-8)
  disconnect(phone_id)
  run(tick, interval_s): run the platform loop, calling tick() every interval_s, until stop()
  stop()
advertise, send, disconnect and on_event all happen on the thread that runs run().
"""

import argparse
import collections
import hashlib
import hmac
import importlib
import json
import os
import sys
import threading
import time
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'nogps_box_sim.html')

VERSION = 1
SERVICE_UUID = '02CB0001-C0C3-40D0-819C-5A85998DCD99'
TX_UUID = '02CB0002-C0C3-40D0-819C-5A85998DCD99'
RX_UUID = '02CB0003-C0C3-40D0-819C-5A85998DCD99'
# NET-9: NonGPS-XXXX; a box that is not updated says NoGPS-XXXX, see State.legacy_name.
NAME_PREFIX = 'NonGPS-'
LEGACY_NAME_PREFIX = 'NoGPS-'
# BLE-13: the company id, a byte of the format version, a byte of the flags and the 4 characters of the box id.
COMPANY_ID = 0xFFFF
ADV_FORMAT = 2
ADV_FLAGS = [('pairing_open', 1), ('full', 2), ('has_phones', 4)]

# Section 9.2: without any command for this long the box stops sending the data.
HELLO_TIMEOUT_S = 10.0
# A radio that can't see a link drop takes a central as gone after this long without a write: well above the
# session timeout, as a connected phone that doesn't write is kept by a real box and only gets no data.
SILENT_GONE_S = 60.0
# Section 9.3: NGD 50 times a second, 9.4: NGS once a second and at once on a change.
DATA_PERIOD_S = 0.02
STATUS_PERIOD_S = 1.0
# BLE-8: NGA, NGO, NGI, NGE and NGS wait in a queue of 12 lines and go before NGD, which is dropped instead.
QUEUE_LINES = 12
# BLE-4: a notification holds MTU - 3 bytes. Until the phone tells its own, the smallest a phone may give.
MIN_PAYLOAD = 20
# What the panel shows of the lines; a minute of NGD at 50 Hz is 3000 lines.
LINES_KEPT = 4000
# The panel's Shut down waits this long, so its answer reaches the page before the program is gone.
QUIT_DELAY_S = 0.3

# Section 9.3, the bits of the data flags, in their order.
FLAG_BITS = [('IMU_OK', 0x001), ('BIAS_OK', 0x002), ('UP_OK', 0x004), ('FWD_OK', 0x008), ('OBD_OK', 0x010),
             ('STILL', 0x020), ('CALIBRATING', 0x040), ('MOUNT_MOVED', 0x080), ('REVERSE', 0x100),
             ('OBD_ABSENT', 0x200), ('ERROR', 0x400)]
# The flags the panel sets. OBD_OK and OBD_ABSENT follow the state of the adapter, the rest a command.
PANEL_FLAGS = ['IMU_OK', 'BIAS_OK', 'UP_OK', 'STILL', 'MOUNT_MOVED', 'ERROR']
# Section 9.4, the states of the OBD adapter.
OBD_STATES = ['DISABLED', 'NO_ADAPTER', 'INIT', 'SEARCHING', 'NO_CAR', 'NO_DATA', 'ERROR', 'OK', 'SLEEP']
# Section 16: the adapter is absent or its polling is off, which is not an error.
OBD_ABSENT_STATES = {'DISABLED', 'NO_ADAPTER', 'SLEEP'}
# Section 4.4, the last error of the OBD, from the state the panel sets.
OBD_ERRORS = {'NO_ADAPTER': 'NO_ADAPTER', 'NO_CAR': 'NO_CAR', 'NO_DATA': 'NO_SPEED', 'ERROR': 'BUS_ERROR'}
OBD_PROTOCOL = 'ISO 15765-4 (CAN 11/500)'
# The abilities of NGI: the lines of the box itself. The application reads only OTA from this field (9.6), and the
# simulator doesn't take a firmware.
ABILITIES = 'BLE'
# BLE-12: the box keeps this many phones. Section 9.5: a code of BT_PAIR is 6 digits.
MAX_BONDS = 4
CODE_DIGITS = 6
# Section 9.5: a phone that forgets itself is dropped this long after its OK, and the box answers FACTORY_RESET this
# long before it erases everything.
FORGET_DROP_S = 0.5
# Section 9.5: the key is 16 bytes, the nonce 8, and the box answers the first 8 bytes of HMAC-SHA256(key, nonce).
AUTH_KEY_BYTES = 16
AUTH_NONCE_BYTES = 8
AUTH_PROOF_BYTES = 8
# The keys of the phones, by the id of the box: the firmware keeps them in NVS, the simulator in this file.
DEFAULT_KEYS_PATH = os.path.expanduser('~/.nogps-box-sim-keys.json')
FLAG = dict(FLAG_BITS)
# A command of section 7.2 or 7.3 sets the flags its calibration would set.
CALIBRATION = {'CAL_BIAS': {'BIAS_OK': True},
               'CAL_UP': {'UP_OK': True, 'BIAS_OK': True, 'MOUNT_MOVED': False},
               'CAL_RESET': {'UP_OK': False, 'MOUNT_MOVED': False}}


def crc16(text):
    """CRC-16/CCITT-FALSE of the bytes between '$' and '*', as esp32::Crc16 does it."""
    crc = 0xFFFF
    for byte in text.encode('ascii'):
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def hex_bytes(text, size):
    """The bytes of a hex text of exactly |size| bytes, None if it is not one."""
    if len(text) != size * 2:
        return None
    try:
        return bytes.fromhex(text)
    except ValueError:
        return None


def auth_proof(key, nonce):
    """The answer to AUTH, in lowercase hex; the key and the nonce are the bytes of their hex texts."""
    return hmac.new(key, nonce, hashlib.sha256).hexdigest()[:AUTH_PROOF_BYTES * 2]


def line(body):
    """\returns the line of a body without '$', the checksum and the end, as the box sends it."""
    return ('$%s*%04X\r\n' % (body, crc16(body))).encode('ascii')


def bond_address(name):
    """A made-up address of a phone: the system gives the simulator none. Locally administered, so no vendor's."""
    digest = hashlib.sha256(name.encode('utf-8')).digest()
    return ':'.join('%02X' % byte for byte in bytes([0x02]) + digest[:5])


def parse(raw):
    """\returns the fields of a line with a valid checksum, the first one is its type, as esp32::Parse does."""
    text = raw.strip()
    star = text.rfind('*')
    if not text.startswith('$') or star < 0 or len(text) != star + 5:
        return None
    body = text[1:star]
    try:
        if int(text[star + 1:], 16) != crc16(body):
            return None
    except (ValueError, UnicodeEncodeError):
        return None
    return body.split(',')


def notifications(data, size):
    """\returns the line cut into notifications: BLE-4, TX is a stream of bytes and a long line is split."""
    size = max(1, size)
    return [data[i:i + size] for i in range(0, len(data), size)]


class State:
    """What the box says about itself, all of it set by the panel. The lock of the Box guards it."""

    def __init__(self, box_id):
        self.box_id = box_id
        self.firmware = '0.6.0'
        self.build = time.strftime('%Y-%m-%dT%H:%M')
        self.chip = 'esp32s3'
        self.board = 's3zero'
        self.revision = 'R1'
        self.imu_name = 'ICM42688'
        self.imu_rate = 500
        self.imu_state = 'OK'
        self.imu_chip_id = '0x47'
        self.temp_dc = 412
        self.bias_up_mdps = -15
        self.obd = 'NO_ADAPTER'
        # Section 9.3: in percent of the limit under which the box counts itself still.
        self.shake_pct = 4
        self.flags = {name: name in ('IMU_OK', 'BIAS_OK', 'UP_OK', 'STILL') for name in PANEL_FLAGS}
        self.adv = {'pairing_open': True, 'full': False, 'has_phones': False}
        self.advertising = True
        self.legacy_name = False
        # BLE-16: the window opened by 3 quick power-ons; a phone that pairs in it closes it and erases nobody.
        self.recovery_window = False

    def name(self):
        return (LEGACY_NAME_PREFIX if self.legacy_name else NAME_PREFIX) + self.box_id

    def manufacturer(self):
        flags = 0
        for key, bit in ADV_FLAGS:
            if self.adv.get(key):
                flags |= bit
        return bytes([COMPANY_ID & 0xFF, COMPANY_ID >> 8, ADV_FORMAT, flags]) + self.box_id.ljust(4)[:4].encode('ascii', 'replace')

    def flags_value(self):
        value = 0
        for name, bit in FLAG_BITS:
            if self.flags.get(name):
                value |= bit
        if self.obd == 'OK':
            value |= FLAG['OBD_OK']
        if self.obd in OBD_ABSENT_STATES:
            value |= FLAG['OBD_ABSENT']
        return value

    def data(self, seq, time_ms):
        """Section 9.3. The car stands: the turn, the path and the speed don't move."""
        speed, age = (0, 0) if self.obd == 'OK' else (-1, -1)
        body = 'NGD,%d,%d,%d,0,0,0,%d,%d,%X' % (VERSION, seq, time_ms, speed, age, self.flags_value())
        # The accelerations are empty without the vertical or the gyroscope, the shake without the gyroscope.
        body += ',0,0,0,0' if self.flags.get('UP_OK') and self.flags.get('IMU_OK') else ',,,,'
        body += ',%d' % self.shake_pct if self.flags.get('IMU_OK') else ','
        return line(body)

    def status(self):
        """Section 9.4, the 16 fields of version 2: the ones of version 3 may be absent and the box has no car.

        The last field is the number of the last event, and it is empty because the journal of the simulator is:
        a number there, 0 among them, is an event the application then asks for (Esp32Source::OnLastEventNumber).
        """
        found = self.obd not in ('DISABLED', 'NO_ADAPTER')
        return line('NGS,%d,%s,%s,%d,%s,%s,%d,%d,%d,%s,%s,%s,%d,%d,' % (
            VERSION, self.firmware, self.imu_name, self.imu_rate, self.obd, OBD_PROTOCOL if found else '',
            0, self.temp_dc, 0, self.imu_state, self.imu_chip_id, OBD_ERRORS.get(self.obd, 'NONE'),
            38400 if found else 0, self.bias_up_mdps))

    def info(self):
        """Section 9.6."""
        return line('NGI,%d,%s,%s,%s,%s,%s,4096,2031616,ota_0,VALID,%s,0,%s' % (
            VERSION, self.firmware, self.build, self.chip, self.board, self.box_id, ABILITIES, self.revision))


class SilenceWatch:
    """When each central last wrote, for a radio the stack of which never reports a central that went away."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.written = {}

    def wrote(self, phone_id):
        self.written[phone_id] = self.clock()

    def forget(self, phone_id):
        self.written.pop(phone_id, None)

    def gone(self):
        """Returns the ids silent for SILENT_GONE_S, and forgets them."""
        now = self.clock()
        found = [phone_id for phone_id, at in self.written.items() if now - at >= SILENT_GONE_S]
        for phone_id in found:
            del self.written[phone_id]
        return found


class Phone:
    """A phone connected to the box: what it told in its HELLO and what is waiting to go to it."""

    def __init__(self, phone_id, label):
        self.id = phone_id
        self.label = label
        self.name = ''
        self.unix_s = 0
        self.subscribed = False
        self.payload = MIN_PAYLOAD
        self.hello_at = 0.0
        # Section 9.2: the last command that keeps the session, 0 until the first HELLO starts one.
        self.cmd_at = 0.0
        self.info_sent = False
        # The order of the first HELLO among the phones: the box listens to the lowest, 0 before any.
        self.hello_order = 0
        # Bonded on this link, as a phone that paired with the code: AUTH_SET may replace its key (#37 of ELMandIMU).
        self.paired = False
        self.queue = collections.deque(maxlen=QUEUE_LINES)
        # The tail of a line that has started going out: BLE-4 sends it whole.
        self.pending = b''
        self.sent = 0
        self.dropped = 0

    def in_session(self, now):
        """Section 9.2: a HELLO has started a session and a command has come within the timeout."""
        return bool(self.cmd_at) and now - self.cmd_at < HELLO_TIMEOUT_S

    def heard(self, now):
        return self.subscribed and self.in_session(now)


class Box:
    """The box: it keeps the state, answers the commands and sends the lines through a radio."""

    def __init__(self, state, radio, clock=time.monotonic, keys_path=None):
        self.lock = threading.RLock()
        self.state = state
        self.radio = radio
        radio.on_event = self.on_event
        # Monotonic seconds; the tests drive their own.
        self.clock = clock
        self.phones = {}
        # BLE-12: the bonded phones, by address; they outlive their connections, as in NVS.
        self.bonds = {}
        self.hellos = 0
        # Section 9.5: the key of each phone, kept with its bond; the file keeps them over a restart, as NVS does.
        self.keys_path = keys_path
        self.auth_keys = self.load_keys()
        self.seq = 0
        self.started = clock()
        self.log = collections.deque(maxlen=LINES_KEPT)
        self.logged = 0
        self.status_at = 0.0
        self.status_dirty = True
        self.advertised = None
        self.rate_at = 0.0
        self.rate_sent = 0
        self.rate = 0
        # The phones the panel asks to drop; the tick drops them, see keep_advertisement.
        self.dropping = set()
        # The phones that forget themselves are dropped after their OK: id -> when.
        self.dropping_at = {}
        # When the panel's Shut down takes the program down, see tick.
        self.quit_at = None
        # When FACTORY_RESET erases the box: after its OK.
        self.reset_at = None
        # The number of the next event of the journal that is sent, see event().
        self.event_number = 0

    def time_ms(self):
        """Section 9.3: the time of the box since it started, which overflows in 49 days."""
        return int((self.clock() - self.started) * 1000) & 0xFFFFFFFF

    def note(self, out, text, phone=None):
        self.logged += 1
        kind = text[1:4] if len(text) > 4 and text.startswith('$') else '?'
        self.log.append({'n': self.logged, 'out': out, 'kind': kind, 'text': text,
                         'phone': phone.label if phone else ''})

    # The radio and the tick run on one thread, the panel on its own: the lock guards the state and the log.

    def on_event(self, kind, phone_id, arg=None):
        with self.lock:
            if kind == 'connect':
                self.phones[phone_id] = Phone(phone_id, arg or str(phone_id))
                self.note(False, '(connected)', self.phones[phone_id])
                return
            phone = self.phones.get(phone_id)
            if phone is None:
                return
            if kind == 'subscribe':
                phone.subscribed = True
                phone.payload = max(MIN_PAYLOAD, int(arg or MIN_PAYLOAD))
                self.note(False, '(subscribed, %d bytes)' % phone.payload, phone)
            elif kind == 'disconnect':
                self.phones.pop(phone_id, None)
                self.note(False, '(disconnected)', phone)
            elif kind == 'write':
                self.on_write(phone, arg or b'')

    def on_write(self, phone, data):
        """BLE-5: one write is one line, and several lines split by '\\n' in one write are taken too."""
        for raw in data.split(b'\n'):
            text = raw.decode('ascii', 'replace').strip()
            if not text:
                continue
            self.note(False, text, phone)
            fields = parse(text)
            if fields and fields[0] == 'NGC' and len(fields) >= 3:
                self.on_command(phone, fields)

    def on_command(self, phone, fields):
        """Section 9.5. The box has the abilities of ABILITIES only: anything else is unknown."""
        command_id, name, rest = fields[1], fields[2], fields[3:]
        # Section 9.2: any command but PEER, which the box relays before it looks at the commands, keeps a
        # session that is still on. An ended one the box restarts on HELLO alone: it has freed the phone's slot.
        if phone.in_session(self.clock()) and name != 'PEER':
            phone.cmd_at = self.clock()
        if name == 'HELLO':
            # HELLO,<name>,<Unix s> from a newer application; the box remembers both for its list of phones.
            # A HELLO that starts a session ranks after the phones in one: a lapsed phone frees its slot.
            if not phone.in_session(self.clock()):
                self.hellos += 1
                phone.hello_order = self.hellos
            phone.hello_at = phone.cmd_at = self.clock()
            if rest:
                phone.name = rest[0]
            if len(rest) > 1 and rest[1].isdigit():
                phone.unix_s = int(rest[1])
            self.bond(phone)
            if not phone.info_sent:
                phone.info_sent = True
                self.queue(phone, self.state.info())
            return
        if name == 'STATUS':
            self.queue(phone, self.state.status())
            return
        if name == 'INFO':
            self.queue(phone, self.state.info())
            return
        if name == 'EVENTS':
            # Section 10: the events from that number. The journal is empty, so there is nothing before the answer.
            self.queue(phone, line('NGA,%s,OK' % command_id))
            return
        if name in CALIBRATION:
            for flag, value in CALIBRATION[name].items():
                if flag in self.state.flags:
                    self.state.flags[flag] = value
            self.status_dirty = True
            self.queue(phone, line('NGA,%s,OK' % command_id))
            return
        if name in ('BT_LIST', 'BT_PAIR', 'BT_FORGET', 'FACTORY_RESET'):
            self.queue(phone, line('NGA,%s,%s' % (command_id, self.bt_command(phone, name, rest))))
            return
        if name == 'AUTH_SET':
            self.queue(phone, line('NGA,%s,%s' % (command_id, self.auth_set(phone, rest))))
            return
        if name == 'AUTH':
            self.queue(phone, line('NGA,%s,%s' % (command_id, self.auth(phone, rest))))
            return
        self.queue(phone, line('NGA,%s,ERR,UNKNOWN' % command_id))

    def bond(self, phone):
        """Section 9.5: the box remembers the phone, its name and time, for BT_LIST; a full box bonds no fifth."""
        address = bond_address(self.auth_phone(phone))
        if address not in self.bonds:
            # A new phone is bonded only in the pairing window, and not while its forgotten link is being dropped.
            if (not self.state.adv['pairing_open'] or phone.id in self.dropping_at or phone.id in self.dropping
                    or self.reset_at is not None):
                return
            if len(self.bonds) >= MAX_BONDS:
                # BLE-16: the recovery window takes a phone on a full box and drops the one with the oldest HELLO.
                if not self.state.recovery_window:
                    return
                self.drop_least_recent()
            if self.state.recovery_window:
                self.state.recovery_window = False
                self.state.adv['pairing_open'] = False
            phone.paired = True
        self.bonds[address] = {'name': phone.name, 'unix_s': phone.unix_s, 'hello_at': self.clock()}
        self.sync_adv()

    def drop_least_recent(self):
        """A full box in the recovery window forgets the phone with the oldest last HELLO and tells it: BT_DROP."""
        address = min(self.bonds, key=lambda a: self.bonds[a].get('hello_at', 0))
        self.forget(address)
        self.event('W', 'BT_DROP', address)

    def event(self, level, code, text):
        """Section 10: an event goes to the phones that listen. The journal of the simulator stays empty, so a phone
        that misses it doesn't ask for it."""
        now = self.clock()
        body = 'NGE,%d,%d,%d,%s,%s,%s' % (VERSION, self.event_number, self.time_ms(), level, code, text)
        self.event_number += 1
        for phone in self.phones.values():
            if phone.heard(now):
                self.queue(phone, line(body))

    def sync_adv(self):
        """The advertisement flags follow the bond list (BLE-12): has_phones with any bond, full at MAX_BONDS."""
        self.state.adv['has_phones'] = bool(self.bonds)
        self.state.adv['full'] = len(self.bonds) >= MAX_BONDS

    def address_of(self, phone):
        return bond_address(self.auth_phone(phone))

    def changer(self):
        """The phone that changes the box and the one it listens to: the first that sent HELLO, while its session
        lasts (9.5). None when there is no such phone."""
        now = self.clock()
        live = [p for p in self.phones.values() if p.hello_order and p.in_session(now) and self.address_of(p) in self.bonds]
        return min(live, key=lambda p: p.hello_order) if live else None

    def bt_command(self, phone, name, rest):
        """BT_LIST, BT_PAIR, BT_FORGET and FACTORY_RESET, the answer after 'NGA,<n>,'. A phone that doesn't change
        the box is refused with BUSY, but for BT_LIST and the forgetting of its own link."""
        if name == 'BT_LIST':
            changer = self.changer()
            mine = self.address_of(phone)
            rows = ['%s|%s|%s|%d|%d' % (address, bond['name'], bond['unix_s'] or '', address == mine,
                                        bool(changer) and address == self.address_of(changer))
                    for address, bond in self.bonds.items()]
            return 'OK,%s,%d' % (';'.join(rows), changer is phone)
        own = name == 'BT_FORGET' and rest and rest[0] == self.address_of(phone) and rest[0] in self.bonds
        if self.changer() is not phone and not own:
            return 'ERR,BUSY'
        if name == 'FACTORY_RESET':
            self.reset_at = self.clock() + FORGET_DROP_S
            return 'OK'
        if name == 'BT_PAIR':
            # The code is the app's: the window of a bare BT_PAIR is gone, 123456 is of the windows of the box itself.
            if not (rest and len(rest[0]) == CODE_DIGITS and rest[0].isascii() and rest[0].isdigit()):
                return 'ERR,VALUE'
            if len(self.bonds) >= MAX_BONDS:
                return 'ERR,FULL'
            self.state.adv['pairing_open'] = True
            return 'OK'
        if not rest:
            # Forgetting every phone is FACTORY_RESET now.
            return 'ERR,VALUE'
        if rest[0] not in self.bonds:
            return 'ERR,ADDR'
        self.forget(rest[0], FORGET_DROP_S if own else 0)
        return 'OK'

    def forget(self, address, drop_after=0):
        """The phone is gone from the list with its key (9.5) and its link is dropped, after its OK if it asks."""
        del self.bonds[address]
        for name in [n for n in self.auth_keys if bond_address(n) == address]:
            del self.auth_keys[name]
        for phone in list(self.phones.values()):
            if self.address_of(phone) == address:
                if drop_after:
                    self.dropping_at[phone.id] = self.clock() + drop_after
                else:
                    self.dropping.add(phone.id)
        self.sync_adv()
        self.save_keys()

    def factory_reset(self):
        """Everything the box keeps in NVS is erased and it starts as new: no phone, no key, every link dropped, the
        pairing window open as after a power-on of a box with no phones."""
        self.bonds.clear()
        self.auth_keys.clear()
        self.reset_at = None
        self.state.recovery_window = False
        self.state.adv['pairing_open'] = True
        self.dropping.update(self.phones)
        self.sync_adv()
        self.save_keys()

    @staticmethod
    def auth_phone(phone):
        """The phone a key belongs to: the name of its HELLO, the radio's id until it has given one. See the docstring
        of the module: the id changes with the private address of the phone, the name does not."""
        return phone.name or phone.id

    def auth_set(self, phone, rest):
        """AUTH_SET,<32 hex>: the key is taken once; the same key again is taken, another one is refused, unless the
        phone was bonded on this link: a phone that paired again with the code replaces the key it lost."""
        key = hex_bytes(rest[0], AUTH_KEY_BYTES) if rest else None
        if key is None:
            return 'ERR,VALUE'
        name = self.auth_phone(phone)
        if self.auth_keys.get(name, key) != key and not phone.paired:
            return 'ERR,EXISTS'
        self.auth_keys[name] = key
        self.save_keys()
        return 'OK'

    def load_keys(self):
        """The keys this box has kept in the file of --keys, none without one or when it can not be read."""
        if not self.keys_path:
            return {}
        try:
            with open(self.keys_path, encoding='utf-8') as f:
                kept = json.load(f)[self.state.box_id]
            return {phone: bytes.fromhex(key) for phone, key in kept.items()}
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return {}

    def save_keys(self):
        """The keys of this box go into the file of --keys, beside those of the other box ids in it."""
        if not self.keys_path:
            return
        try:
            with open(self.keys_path, encoding='utf-8') as f:
                kept = json.load(f)
            if not isinstance(kept, dict):
                kept = {}
        except (OSError, ValueError):
            kept = {}
        kept[self.state.box_id] = {phone: key.hex() for phone, key in self.auth_keys.items()}
        try:
            with open(self.keys_path, 'w', encoding='utf-8') as f:
                json.dump(kept, f)
        except OSError as error:
            print('the keys are not kept in %s: %s' % (self.keys_path, error))

    def auth(self, phone, rest):
        """AUTH,<16 hex nonce>: OK,<proof>, NOKEY if the phone has no key."""
        nonce = hex_bytes(rest[0], AUTH_NONCE_BYTES) if rest else None
        if nonce is None:
            return 'ERR,VALUE'
        key = self.auth_keys.get(self.auth_phone(phone))
        if key is None:
            return 'ERR,NOKEY'
        return 'OK,' + auth_proof(key, nonce)

    def queue(self, phone, data):
        """An answer or a status waits its turn; the oldest is dropped when the queue is full (BLE-8)."""
        phone.queue.append(data)

    def tick(self):
        """Sends what is due: the queue first, then one NGD to every phone the box has heard from."""
        with self.lock:
            now = self.clock()
            if self.reset_at is not None and now >= self.reset_at:
                self.factory_reset()
            for phone_id in self.dropping:
                self.radio.disconnect(phone_id)
            self.dropping.clear()
            self.keep_advertisement()
            if now - self.status_at >= STATUS_PERIOD_S or self.status_dirty:
                self.status_at = now
                self.status_dirty = False
                status = self.state.status()
                for phone in self.phones.values():
                    if phone.heard(now):
                        self.queue(phone, status)
            for phone_id, at in list(self.dropping_at.items()):
                if now >= at:
                    del self.dropping_at[phone_id]
                    self.radio.disconnect(phone_id)
            ready = [phone for phone in list(self.phones.values()) if self.flush(phone) and phone.heard(now)]
            if ready:
                # One packet for every phone listening: its number counts the packets, not the phones, and both
                # phones hear the same line, which is what makes its dist_mm one moment for both (9.7).
                self.seq = (self.seq + 1) & 0xFFFFFFFF
                data = self.state.data(self.seq, self.time_ms())
                for phone in ready:
                    if self.send_line(phone, data, drop=True):
                        self.note(True, data.decode('ascii').strip(), phone)
                    else:
                        phone.dropped += 1
            if now - self.rate_at >= 1.0:
                self.rate = self.rate_sent
                self.rate_at, self.rate_sent = now, 0
            if self.quit_at is not None and now >= self.quit_at:
                # The radio takes the service down as it stops, and main() closes the panel after it.
                self.radio.stop()

    def keep_advertisement(self):
        """The advertisement follows the panel: the name, the flags of BLE-13 and the switch."""
        want = (self.state.name(), self.state.manufacturer()) if self.state.advertising else None
        if want == self.advertised:
            return
        self.advertised = want
        if want is None:
            self.radio.stop_advertising()
        else:
            self.radio.advertise(want[0], want[1] if self.radio.supports_manufacturer_data else None)

    def flush(self, phone):
        """Sends what waits for the phone. \returns True when nothing is left and a data line can follow."""
        if not self.send_pending(phone):
            return False
        while phone.queue:
            data = phone.queue.popleft()
            sent = self.send_line(phone, data)
            # Told once, as it starts going out: what is left of it waits in pending and is not dropped (BLE-4).
            self.note(True, data.decode('ascii').strip(), phone)
            if not sent:
                return False
        return True

    def send_pending(self, phone):
        """BLE-4: a line that has started going out is sent whole, over the ticks it takes."""
        while phone.pending:
            chunk = phone.pending[:phone.payload]
            if not self.radio.send(phone.id, chunk):
                return False
            phone.pending = phone.pending[len(chunk):]
        return True

    def send_line(self, phone, data, drop=False):
        """Sends one line. \returns False when the stack couldn't take all of it now (BLE-8).

        What is left of a line that has started going out waits in pending. An NGD that hasn't started goes
        nowhere: it carries the totals, so the next one says the same.
        """
        for index, chunk in enumerate(notifications(data, phone.payload)):
            if not self.radio.send(phone.id, chunk):
                if not (index == 0 and drop):
                    phone.pending = data[index * phone.payload:]
                return False
        phone.sent += 1
        self.rate_sent += 1
        return True

    # What the panel reads and writes.

    def panel_state(self):
        with self.lock:
            now = self.clock()
            state = self.state
            return {
                'radio': self.radio.name,
                'manufacturer': self.radio.supports_manufacturer_data,
                'advertising': state.advertising,
                'quitting': self.quit_at is not None,
                'name': state.name(),
                'uptime_s': int(now - self.started),
                'rate': self.rate,
                'logged': self.logged,
                'flags': dict(state.flags),
                'flags_value': '%03X' % state.flags_value(),
                'adv': dict(state.adv),
                'obd': state.obd,
                'obd_states': OBD_STATES,
                'shake_pct': state.shake_pct,
                'box_id': state.box_id,
                'legacy_name': state.legacy_name,
                'firmware': state.firmware,
                'chip': state.chip,
                'board': state.board,
                'imu_name': state.imu_name,
                'keys': len(self.auth_keys),
                'recovery_window': state.recovery_window,
                'resetting': self.reset_at is not None,
                'bonds': [{'address': address, 'name': bond['name'], 'unix_s': bond['unix_s'],
                           'connected': any(self.address_of(p) == address for p in self.phones.values())}
                          for address, bond in self.bonds.items()],
                'phones': [{'label': p.label, 'name': p.name, 'unix_s': p.unix_s, 'payload': p.payload,
                            'subscribed': p.subscribed, 'heard': p.heard(now), 'sent': p.sent, 'dropped': p.dropped,
                            'hello_age_ms': int((now - p.hello_at) * 1000) if p.hello_at else -1}
                           for p in self.phones.values()],
            }

    def panel_lines(self, since, with_data):
        with self.lock:
            lines = [item for item in self.log if item['n'] > since and (with_data or item['kind'] != 'NGD')]
            return {'lines': lines[-400:], 'next': self.logged}

    def panel_set(self, values):
        with self.lock:
            state = self.state
            for name, value in (values.get('flags') or {}).items():
                if name in state.flags:
                    state.flags[name] = bool(value)
            for name, value in (values.get('adv') or {}).items():
                if name in state.adv:
                    state.adv[name] = bool(value)
            if values.get('obd') in OBD_STATES:
                state.obd = values['obd']
            if 'shake_pct' in values:
                state.shake_pct = max(0, min(9999, int(values['shake_pct'])))
            box_id = state.box_id
            for name in ('box_id', 'firmware', 'chip', 'board', 'imu_name'):
                if values.get(name):
                    # The id is the four characters of the name of a box, as --id takes them. Only macOS
                    # drops an advertised name over 8 characters: the panel's name tells when it does.
                    setattr(state, name, str(values[name])[:4 if name == 'box_id' else 32])
            if state.box_id != box_id:
                # Another id is another box: it has the keys of that id, and those of the old one stay in the file.
                self.auth_keys = self.load_keys()
            if 'legacy_name' in values:
                state.legacy_name = bool(values['legacy_name'])
            if 'advertising' in values:
                state.advertising = bool(values['advertising'])
            self.status_dirty = True
        return self.panel_state()

    def quick_power_ons(self):
        """BLE-16: 3 quick power-ons of a box that has phones open the recovery window, code 123456. A box with no
        phones has the window of a power-on anyway."""
        if self.bonds:
            self.state.recovery_window = True
        self.state.adv['pairing_open'] = True

    def panel_action(self, action, label):
        with self.lock:
            if action == 'start':
                self.state.advertising = True
            elif action == 'stop':
                # A parking takes the Bluetooth of the box down altogether (BLE-14).
                self.state.advertising = False
                self.dropping.update(self.phones)
            elif action == 'disconnect':
                self.dropping.update(p.id for p in self.phones.values() if p.label == label)
            elif action == 'quit':
                # Off the air at once, gone a moment later: the page gets the answer first.
                self.state.advertising = False
                self.dropping.update(self.phones)
                self.quit_at = self.clock() + QUIT_DELAY_S
            elif action == 'clear':
                self.log.clear()
            elif action == 'forget_bond' and label in self.bonds:
                self.forget(label)
            elif action == 'quick_power_ons':
                self.quick_power_ons()
            elif action == 'factory_reset':
                self.factory_reset()
            elif action == 'forget_keys':
                self.auth_keys.clear()
                self.save_keys()
        return self.panel_state()


class FakeRadio:
    """No Bluetooth: for the tests and for working on the panel. Its phones come from the panel's /api/fake."""

    name = 'fake'
    supports_manufacturer_data = False

    def __init__(self):
        self.on_event = lambda *args: None
        self.sent = []
        self.ready = True
        self.advertisement = None
        self.stopped = threading.Event()

    def advertise(self, name, manufacturer):
        self.advertisement = (name, manufacturer)

    def stop_advertising(self):
        self.advertisement = None

    def send(self, phone_id, data):
        if not self.ready:
            return False
        self.sent.append((phone_id, data))
        return True

    def disconnect(self, phone_id):
        self.on_event('disconnect', phone_id)

    def run(self, tick, interval_s):
        while not self.stopped.wait(interval_s):
            tick()

    def stop(self):
        self.stopped.set()


def default_radio(platform):
    if platform.startswith('linux'):
        return 'linux'
    return {'darwin': 'macos', 'win32': 'windows'}.get(platform, 'fake')


def make_radio(kind):
    if kind == 'auto':
        kind = default_radio(sys.platform)
    if kind == 'fake':
        return FakeRadio()
    module_name = 'nogps_box_sim_radio_' + kind
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        return importlib.import_module(module_name).Radio()
    except ImportError as e:
        packages = {'macos': 'pyobjc-framework-CoreBluetooth', 'linux': 'dbus-next', 'windows': 'winsdk'}
        if kind == 'windows' and sys.version_info >= (3, 13):
            sys.exit('winsdk, which the radio of Windows needs, has no wheel for Python %d.%d: run this file with\n'
                     '`uv run --python 3.12 --script`, or take the panel alone with --radio fake.\n(%s)'
                     % (sys.version_info[0], sys.version_info[1], e))
        sys.exit('%s needs %s, which the script declares for uv: run it with `just box`, or with\n'
                 '`uv run --script` on this file. Without uv, put the package in a virtual environment of your own.\n'
                 '(%s)' % (module_name, packages.get(kind, '?'), e))


def handler(box):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, body, content_type='application/json'):
            if not isinstance(body, bytes):
                body = (body if isinstance(body, str) else json.dumps(body, separators=(',', ':'))).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', content_type + '; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def fail(self, code, text):
            body = text.encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def allowed(self, post):
            """Only the page of this server, so no other site can drive the box through the browser."""
            port = self.server.server_address[1]
            if self.headers.get('Host') not in ('127.0.0.1:%d' % port, 'localhost:%d' % port):
                return False
            return not post or self.headers.get('X-NoGPS-Box-Sim') == '1'

        def do_GET(self):
            url = urlparse(self.path)
            if not self.allowed(False):
                return self.fail(403, 'forbidden')
            try:
                if url.path == '/':
                    with open(PAGE, 'rb') as f:
                        return self.send(f.read(), 'text/html')
                if url.path == '/api/state':
                    return self.send(box.panel_state())
                if url.path == '/api/lines':
                    query = parse_qs(url.query)
                    since = int(query.get('since', ['0'])[0])
                    return self.send(box.panel_lines(since, query.get('ngd', ['0'])[0] == '1'))
                self.fail(404, 'not found')
            except Exception:
                self.fail(500, traceback.format_exc())

        def do_POST(self):
            url = urlparse(self.path)
            data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            if not self.allowed(True):
                return self.fail(403, 'forbidden')
            try:
                values = json.loads(data or b'{}')
                if url.path == '/api/set':
                    return self.send(box.panel_set(values))
                if url.path == '/api/action':
                    return self.send(box.panel_action(values.get('action', ''), values.get('phone', '')))
                self.fail(404, 'not found')
            except (ValueError, KeyError) as e:
                self.fail(400, str(e))
            except Exception:
                self.fail(500, traceback.format_exc())

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--radio', default='auto', choices=['auto', 'macos', 'linux', 'windows', 'fake'])
    parser.add_argument('--id', default='S', help='the four characters after NonGPS- in the name of a box; macOS '
                                                   'drops a name over 8 characters from the advertisement, so one '
                                                   'character fits after NonGPS- and two after NoGPS- there')
    parser.add_argument('--legacy-name', action='store_true',
                        help='advertise NoGPS-XXXX as a box that is not updated does')
    parser.add_argument('--keys', default=DEFAULT_KEYS_PATH,
                        help='the file with the keys the phones have given the box, as NVS keeps them over a restart; '
                             'empty keeps them in memory alone')
    parser.add_argument('--port', type=int, default=0, help='0 takes a free one')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()

    # The lines below are a running log: they are of no use when a redirected stdout holds them back.
    sys.stdout.reconfigure(line_buffering=True)
    radio = make_radio(args.radio)
    state = State(args.id)
    state.legacy_name = args.legacy_name
    box = Box(state, radio, keys_path=args.keys or None)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(box))
    url = 'http://127.0.0.1:%d/' % server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print('%s radio, the box is %s' % (radio.name, box.state.name()))
    print('open', url, '- Ctrl+C stops')
    if not args.no_browser:
        webbrowser.open(url)
    try:
        radio.run(box.tick, DATA_PERIOD_S)
    except KeyboardInterrupt:
        pass
    finally:
        radio.stop()
        server.shutdown()


if __name__ == '__main__':
    main()
