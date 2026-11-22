#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyobjc-framework-CoreBluetooth>=10; sys_platform == 'darwin'",
#     "dbus-next>=0.2.3; sys_platform == 'linux'",
# ]
# ///
"""The sensor box of NonGPS Maps, simulated on this computer so a phone can find it without the hardware.

  just box [--radio auto|macos|linux|fake] [--id S] [--port 0] [--no-browser]
  uv run --script tools/python/nogps_box_sim.py [the same]

The box stands in a parked car: it advertises the service of the box over Bluetooth LE and sends the NGI, NGS and
NGD lines of docs/nogps/esp32-firmware-spec.md section 9. A panel in the browser shows what is going on and changes
what the box says: the flags, the state of the OBD adapter, the shake, the version. The mark on the phone doesn't
move, and nothing here is kept between runs.

A debug build of the application is needed on Android: the simulator asks for no pairing, and a release build takes
the lines of a paired box alone. iOS doesn't check the pairing, but on macOS CoreBluetooth can't advertise the
manufacturer data of BLE-13, so the pairing window flag never reaches the phone, and only a debug build takes an
advertisement without that data as a box that accepts a new phone. BlueZ on Linux does advertise it, the panel sets
the flags there, and an iOS release build connects to the simulator as it does to a box.

What it doesn't simulate, and why:
- the pairing rules (BLE-11, BLE-12, BLE-15, BLE-16): on macOS pairing belongs to the system, with no bt_pin and no
  "display only" capability;
- any motion: no speed, no turns, no jolts;
- the firmware update, the car values, the phone list and the places of two phones: NGI tells the abilities "BLE"
  alone, and the application asks for none of them.

The radio needs a package -- PyObjC on macOS, dbus-next on Linux -- and the script declares both above, each
for its own platform, so uv puts them in an environment of its own and nothing is installed into the system
Python. The panel and the tests need no package at all and run with plain python3, which is how CI runs them.

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
# BLE-13: the company id, a byte of the format version and a byte of the flags.
COMPANY_ID = 0xFFFF
ADV_FORMAT = 1
ADV_FLAGS = [('pairing_open', 1), ('full', 2), ('has_phones', 4)]

# Section 9.2: without a HELLO for this long the box stops sending the data.
HELLO_TIMEOUT_S = 3.0
# A radio that can't see a link drop takes a central as gone after this long without a write: far above the
# HELLO timeout, as a connected phone that doesn't write is kept by a real box and only gets no data.
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
# The abilities of NGI: only the lines of the box itself. The application gates CAR_GET, BT_LIST, PEER and the
# firmware update on this field, so it asks for nothing the simulator hasn't got.
ABILITIES = 'BLE'
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


def line(body):
    """\returns the line of a body without '$', the checksum and the end, as the box sends it."""
    return ('$%s*%04X\r\n' % (body, crc16(body))).encode('ascii')


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
        self.firmware = '0.4.4'
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

    def name(self):
        return (LEGACY_NAME_PREFIX if self.legacy_name else NAME_PREFIX) + self.box_id

    def manufacturer(self):
        flags = 0
        for key, bit in ADV_FLAGS:
            if self.adv.get(key):
                flags |= bit
        return bytes([COMPANY_ID & 0xFF, COMPANY_ID >> 8, ADV_FORMAT, flags])

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
        self.info_sent = False
        self.queue = collections.deque(maxlen=QUEUE_LINES)
        # The tail of a line that has started going out: BLE-4 sends it whole.
        self.pending = b''
        self.sent = 0
        self.dropped = 0

    def heard(self, now):
        return self.subscribed and self.hello_at and now - self.hello_at < HELLO_TIMEOUT_S


class Box:
    """The box: it keeps the state, answers the commands and sends the lines through a radio."""

    def __init__(self, state, radio, clock=time.monotonic):
        self.lock = threading.RLock()
        self.state = state
        self.radio = radio
        radio.on_event = self.on_event
        # Monotonic seconds; the tests drive their own.
        self.clock = clock
        self.phones = {}
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
        # When the panel's Shut down takes the program down, see tick.
        self.quit_at = None

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
        if name == 'HELLO':
            # HELLO,<name>,<Unix s> from a newer application; the box remembers both for its list of phones.
            phone.hello_at = self.clock()
            if rest:
                phone.name = rest[0]
            if len(rest) > 1 and rest[1].isdigit():
                phone.unix_s = int(rest[1])
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
        self.queue(phone, line('NGA,%s,ERR,UNKNOWN' % command_id))

    def queue(self, phone, data):
        """An answer or a status waits its turn; the oldest is dropped when the queue is full (BLE-8)."""
        phone.queue.append(data)

    def tick(self):
        """Sends what is due: the queue first, then one NGD to every phone the box has heard from."""
        with self.lock:
            now = self.clock()
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
            for name in ('box_id', 'firmware', 'chip', 'board', 'imu_name'):
                if values.get(name):
                    # One character: macOS drops an advertised name over 8 characters, and NonGPS- is 7.
                    setattr(state, name, str(values[name])[:1 if name == 'box_id' else 32])
            if 'legacy_name' in values:
                state.legacy_name = bool(values['legacy_name'])
            if 'advertising' in values:
                state.advertising = bool(values['advertising'])
            self.status_dirty = True
        return self.panel_state()

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


def make_radio(kind):
    if kind == 'auto':
        kind = {'darwin': 'macos'}.get(sys.platform, 'linux' if sys.platform.startswith('linux') else 'fake')
    if kind == 'fake':
        return FakeRadio()
    module_name = 'nogps_box_sim_radio_' + kind
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        return importlib.import_module(module_name).Radio()
    except ImportError as e:
        packages = {'macos': 'pyobjc-framework-CoreBluetooth', 'linux': 'dbus-next'}
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
    parser.add_argument('--radio', default='auto', choices=['auto', 'macos', 'linux', 'fake'])
    parser.add_argument('--id', default='S', help='the characters after NonGPS- in the name of the box; macOS drops '
                                                   'a name over 8 characters from the advertisement, so one '
                                                   'character fits after NonGPS- and two after NoGPS-')
    parser.add_argument('--legacy-name', action='store_true',
                        help='advertise NoGPS-XXXX as a box that is not updated does')
    parser.add_argument('--port', type=int, default=0, help='0 takes a free one')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()

    # The lines below are a running log: they are of no use when a redirected stdout holds them back.
    sys.stdout.reconfigure(line_buffering=True)
    radio = make_radio(args.radio)
    state = State(args.id)
    state.legacy_name = args.legacy_name
    box = Box(state, radio)
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
