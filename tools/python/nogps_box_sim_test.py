#!/usr/bin/env python3
"""Tests of nogps_box_sim.py: the lines, the commands and the queue, over a radio that holds no Bluetooth.

  python3 tools/python/nogps_box_sim_test.py
"""

import asyncio
import contextlib
import importlib
import io
import os
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nogps_box_sim as sim  # noqa: E402

PHONE = 'phone-1'
OTHER = 'phone-2'


class Clock:
    """The seconds the box sees, moved by the test."""

    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def pass_s(self, seconds):
        self.now += seconds


class Radio(sim.FakeRadio):
    """A radio that refuses what the test tells it to, to see the queue and the drops."""

    def __init__(self, take=None):
        super().__init__()
        # None takes everything; a number takes that many notifications and refuses the rest.
        self.take = take
        self.disconnected = []

    def disconnect(self, phone_id):
        self.disconnected.append(phone_id)
        super().disconnect(phone_id)

    def send(self, phone_id, data):
        if self.take is not None:
            if self.take <= 0:
                return False
            self.take -= 1
        return super().send(phone_id, data)

    def lines(self, kind=None):
        """\returns the lines put together from the notifications, which is what the phone does (BLE-4)."""
        text = b''.join(data for _, data in self.sent).decode('ascii')
        found = [raw for raw in text.split('\r\n') if raw]
        return [raw for raw in found if kind is None or raw[1:4] == kind]


def box(take=None, box_id='S1', keys_path=None):
    clock = Clock()
    radio = Radio(take)
    made = sim.Box(sim.State(box_id), radio, clock, keys_path=keys_path)
    return made, radio, clock


def connect(made, hello=True, payload=182):
    made.on_event('connect', PHONE, 'Test phone')
    made.on_event('subscribe', PHONE, payload)
    if hello:
        made.on_event('write', PHONE, command(1, 'HELLO,Test phone,1794685760'))
    return made.phones[PHONE]


def command(number, text):
    """The line the application writes to RX, as esp32::Command builds it."""
    body = 'NGC,%d,%s' % (number, text)
    return ('$%s*%04X\r\n' % (body, sim.crc16(body))).encode('ascii')


def fields(raw):
    return sim.parse(raw)


class Lines(unittest.TestCase):
    def test_crc_of_the_spec(self):
        self.assertEqual(sim.crc16('123456789'), 0x29B1)

    def test_line_and_parse(self):
        raw = sim.line('NGA,7,OK').decode('ascii')
        self.assertEqual(raw, '$NGA,7,OK*%04X\r\n' % sim.crc16('NGA,7,OK'))
        self.assertEqual(sim.parse(raw), ['NGA', '7', 'OK'])

    def test_parse_refuses_a_broken_line(self):
        self.assertIsNone(sim.parse('$NGA,7,OK*0000'))
        self.assertIsNone(sim.parse('NGA,7,OK*29B1'))
        self.assertIsNone(sim.parse('$NGA,7,OK*29B'))
        self.assertIsNone(sim.parse(''))

    def test_data_of_a_standing_box(self):
        made, radio, _ = box()
        made.state.obd = 'NO_ADAPTER'
        got = fields(made.state.data(5, 1234).decode('ascii').strip())
        # NGD, version, seq, t_ms, yaw, rate, dist, speed, age, flags, h1, h2, up, jolt, shake.
        self.assertEqual(got[:9], ['NGD', '1', '5', '1234', '0', '0', '0', '-1', '-1'])
        self.assertEqual(int(got[9], 16), 0x001 | 0x002 | 0x004 | 0x020 | 0x200)
        self.assertEqual(got[10:], ['0', '0', '0', '0', '4'])
        self.assertEqual(len(got), 15)

    def test_data_speaks_of_the_obd_adapter(self):
        made, _, _ = box()
        made.state.obd = 'OK'
        got = fields(made.state.data(1, 0).decode('ascii').strip())
        self.assertEqual(got[7:9], ['0', '0'])
        self.assertTrue(int(got[9], 16) & sim.FLAG['OBD_OK'])
        self.assertFalse(int(got[9], 16) & sim.FLAG['OBD_ABSENT'])

    def test_data_without_the_vertical_has_no_accelerations(self):
        made, _, _ = box()
        made.state.flags['UP_OK'] = False
        got = fields(made.state.data(1, 0).decode('ascii').strip())
        self.assertEqual(got[10:], ['', '', '', '', '4'])
        made.state.flags['IMU_OK'] = False
        got = fields(made.state.data(1, 0).decode('ascii').strip())
        self.assertEqual(got[10:], ['', '', '', '', ''])

    def test_status_has_the_sixteen_fields_of_version_two(self):
        made, _, _ = box()
        got = fields(made.state.status().decode('ascii').strip())
        self.assertEqual(len(got), 16)
        self.assertEqual(got[0:5], ['NGS', '1', '0.6.0', 'ICM42688', '500'])
        # No adapter: no protocol, no baud rate, and the last error names it.
        self.assertEqual([got[5], got[6], got[12], got[13]], ['NO_ADAPTER', '', 'NO_ADAPTER', '0'])
        # The number of the last event is empty: with a number there the application asks for the journal.
        self.assertEqual(got[15], '')

    def test_status_of_a_car_that_answers(self):
        made, _, _ = box()
        made.state.obd = 'OK'
        got = fields(made.state.status().decode('ascii').strip())
        self.assertEqual([got[5], got[6], got[12], got[13]], ['OK', sim.OBD_PROTOCOL, 'NONE', '38400'])

    def test_info_tells_the_firmware_the_application_drives(self):
        made, _, _ = box()
        got = fields(made.state.info().decode('ascii').strip())
        self.assertEqual(len(got), 14)
        self.assertEqual([got[0], got[1], got[2], got[4], got[5], got[6]],
                         ['NGI', '1', '0.6.0', 'esp32s3', 's3zero', 'S1'])
        # The application reads only OTA from the abilities, and the simulator takes no firmware.
        self.assertEqual(got[11], 'BLE')

    def test_the_name_fits_the_advertisement(self):
        made, _, _ = box(box_id='S')
        # macOS drops a longer name when the service UUID of 16 bytes is in the packet.
        self.assertLessEqual(len(made.state.name()), 8)
        # BLE-13, version 2: the company, the version, the flags and the 4 characters of the id.
        self.assertEqual(made.state.manufacturer(), bytes([0xFF, 0xFF, 2, 1]) + b'S   ')
        made.state.adv['has_phones'] = True
        self.assertEqual(made.state.manufacturer()[3], 1 | 4)

    def test_the_advertisement_carries_the_id_of_the_box(self):
        made, _, _ = box(box_id='C47D')
        self.assertEqual(made.state.manufacturer()[4:], b'C47D')
        self.assertEqual(made.state.name(), 'NonGPS-C47D')

    def test_a_long_line_is_split_and_put_back_together(self):
        made, radio, _ = box()
        connect(made, payload=20)
        made.tick()
        data = radio.lines('NGD')
        self.assertEqual(len(data), 1)
        # More than one notification, and the phone reads the same line back.
        self.assertGreater(len(radio.sent), 2)
        self.assertEqual(len(max((d for _, d in radio.sent), key=len)), 20)
        self.assertIsNotNone(fields(data[0]))


class Commands(unittest.TestCase):
    def test_hello_brings_the_info_once(self):
        made, radio, _ = box()
        connect(made)
        made.tick()
        self.assertEqual(len(radio.lines('NGI')), 1)
        made.on_event('write', PHONE, command(2, 'HELLO,Test phone,1794685761'))
        made.tick()
        self.assertEqual(len(radio.lines('NGI')), 1)
        phone = made.phones[PHONE]
        self.assertEqual((phone.name, phone.unix_s), ('Test phone', 1794685761))

    def test_a_plain_hello_of_an_older_application(self):
        made, _, _ = box()
        made.on_event('connect', PHONE, 'Phone')
        made.on_event('subscribe', PHONE, 182)
        made.on_event('write', PHONE, command(1, 'HELLO'))
        self.assertEqual(made.phones[PHONE].name, '')
        self.assertTrue(made.phones[PHONE].heard(made.clock()))

    def test_status_and_info_are_answered_with_the_lines(self):
        made, radio, _ = box()
        connect(made)
        made.on_event('write', PHONE, command(3, 'STATUS'))
        made.on_event('write', PHONE, command(4, 'INFO'))
        made.tick()
        self.assertEqual(len(radio.lines('NGS')), 2)  # the one of the tick and the asked one
        self.assertEqual(len(radio.lines('NGI')), 2)
        # Neither command is answered with an NGA.
        self.assertEqual(radio.lines('NGA'), [])

    def test_calibration_sets_the_flags(self):
        made, radio, _ = box()
        connect(made)
        made.state.flags['UP_OK'] = False
        made.state.flags['MOUNT_MOVED'] = True
        made.on_event('write', PHONE, command(5, 'CAL_UP'))
        made.tick()
        self.assertEqual(fields(radio.lines('NGA')[0]), ['NGA', '5', 'OK'])
        self.assertTrue(made.state.flags['UP_OK'])
        self.assertFalse(made.state.flags['MOUNT_MOVED'])
        made.on_event('write', PHONE, command(6, 'CAL_RESET'))
        made.tick()
        self.assertFalse(made.state.flags['UP_OK'])

    def test_the_journal_is_asked_for_and_empty(self):
        made, radio, _ = box()
        connect(made)
        # The application asks on its own when the status names a last event; it must not be told the box is new
        # to the command, as a box of any firmware knows it.
        made.on_event('write', PHONE, command(30, 'EVENTS,0'))
        made.tick()
        self.assertEqual(fields(radio.lines('NGA')[0]), ['NGA', '30', 'OK'])
        self.assertEqual(radio.lines('NGE'), [])

    def test_a_command_the_box_hasnt_got(self):
        made, radio, _ = box()
        connect(made)
        for number, text in ((7, 'PEER,1,2'), (8, 'CAR_GET,spd_scale'), (9, 'OTA_BEGIN,1,2,3')):
            made.on_event('write', PHONE, command(number, text))
        made.tick()
        self.assertEqual([fields(raw)[2:] for raw in radio.lines('NGA')], [['ERR', 'UNKNOWN']] * 3)

    def answers(self, made, radio):
        made.tick()
        return [fields(raw)[2:] for raw in radio.lines('NGA')]

    def second_phone(self, made, name='Other', hello=True):
        made.on_event('connect', OTHER, name)
        made.on_event('subscribe', OTHER, 182)
        if hello:
            made.on_event('write', OTHER, command(1, 'HELLO,%s,1794680000' % name))

    def test_the_phone_list_has_the_bonds_and_who_changes_the_box(self):
        made, radio, _ = box()
        connect(made)
        self.second_phone(made)
        made.on_event('write', PHONE, command(2, 'BT_LIST'))
        made.on_event('write', OTHER, command(2, 'BT_LIST'))
        first, second = self.answers(made, radio)
        rows = first[1].split(';')
        self.assertEqual(len(rows), 2)
        (a1, n1, t1, mine1, listened1), (a2, n2, t2, mine2, listened2) = (r.split('|') for r in rows)
        self.assertEqual((n1, t1, mine1, listened1, first[2]), ('Test phone', '1794685760', '1', '1', '1'))
        self.assertEqual((n2, t2, mine2, listened2), ('Other', '1794680000', '0', '0'))
        self.assertNotEqual(a1, a2)
        # The second phone sees its own link and the first one listened to; it doesn't change the box.
        self.assertEqual(second[1].split(';')[1].split('|')[3:], ['1', '0'])
        self.assertEqual(second[2], '0')

    def test_a_phone_without_a_hello_is_listed_by_nobody_but_the_list_is_there(self):
        made, radio, _ = box()
        connect(made, hello=False)
        made.on_event('write', PHONE, command(2, 'BT_LIST'))
        self.assertEqual(self.answers(made, radio), [['OK', '', '0']])

    def test_the_recovery_code_of_the_old_firmware_is_unknown(self):
        made, radio, _ = box()
        connect(made)
        made.on_event('write', PHONE, command(2, 'BT_RECOVERY'))
        self.assertEqual(self.answers(made, radio), [['ERR', 'UNKNOWN']])

    def test_pairing_takes_a_code_of_six_digits(self):
        made, radio, _ = box()
        connect(made)
        made.state.adv['pairing_open'] = False
        for number, text in ((2, 'BT_PAIR,12345'), (3, 'BT_PAIR,12345a')):
            made.on_event('write', PHONE, command(number, text))
        self.assertEqual(self.answers(made, radio), [['ERR', 'VALUE']] * 2)
        self.assertFalse(made.state.adv['pairing_open'])
        made.on_event('write', PHONE, command(4, 'BT_PAIR,123456'))
        self.assertEqual(self.answers(made, radio)[2:], [['OK']])
        self.assertTrue(made.state.adv['pairing_open'])
        # The window with no code of the app is the box's own, with 123456: BT_PAIR without a code is refused.
        made.state.adv['pairing_open'] = False
        made.on_event('write', PHONE, command(5, 'BT_PAIR'))
        self.assertEqual(self.answers(made, radio)[3:], [['ERR', 'VALUE']])
        self.assertFalse(made.state.adv['pairing_open'])

    def test_pairing_is_for_the_phone_the_box_listens_to_and_a_full_box_refuses(self):
        made, radio, _ = box()
        connect(made)
        self.second_phone(made)
        made.on_event('write', OTHER, command(2, 'BT_PAIR,123456'))
        made.on_event('write', PHONE, command(2, 'BT_PAIR,123456'))
        self.assertEqual(self.answers(made, radio), [['OK'], ['ERR', 'BUSY']])
        for name in ('Third', 'Fourth'):
            made.bonds['02:00:00:00:00:' + name[:2]] = {'name': name, 'unix_s': 0}
        made.on_event('write', PHONE, command(3, 'BT_PAIR,123456'))
        self.assertEqual(self.answers(made, radio)[2:], [['ERR', 'FULL']])

    def test_a_fifth_phone_is_not_bonded(self):
        made, _, _ = box()
        connect(made)
        for number in range(5):
            made.on_event('connect', 'p%d' % number, 'P')
            made.on_event('write', 'p%d' % number, command(1, 'HELLO,Phone %d,1' % number))
        self.assertEqual(len(made.bonds), 4)

    def test_advertisement_flags_follow_the_bonds(self):
        made, _, _ = box()
        connect(made)
        self.assertEqual((made.state.adv['has_phones'], made.state.adv['full']), (True, False))
        for number in range(1, 5):
            made.on_event('connect', 'p%d' % number, 'P')
            made.on_event('write', 'p%d' % number, command(1, 'HELLO,Phone %d,1' % number))
        self.assertTrue(made.state.adv['full'])
        made.factory_reset()
        self.assertEqual((made.state.adv['has_phones'], made.state.adv['full']), (False, False))

    def test_an_unbonded_fifth_phone_does_not_change_the_box(self):
        made, radio, clock = box()
        connect(made)
        for number in range(1, 4):
            made.on_event('connect', 'p%d' % number, 'P')
            made.on_event('write', 'p%d' % number, command(1, 'HELLO,Phone %d,1' % number))
        clock.pass_s(1000)
        made.on_event('connect', 'p9', 'P')
        made.on_event('write', 'p9', command(1, 'HELLO,Phone 9,1'))
        self.assertIsNone(made.changer())
        made.on_event('write', 'p9', command(2, 'FACTORY_RESET'))
        self.assertEqual(self.answers(made, radio)[-1], ['ERR', 'BUSY'])

    def test_a_phone_that_forgot_itself_is_not_bonded_again_before_its_drop(self):
        made, radio, _ = box()
        connect(made)
        made.on_event('write', PHONE, command(2, 'BT_LIST'))
        address = self.answers(made, radio)[0][1].split('|')[0]
        made.on_event('write', PHONE, command(3, 'BT_FORGET,' + address))
        made.on_event('write', PHONE, command(4, 'HELLO,Phone,1'))
        self.assertEqual(len(made.bonds), 0)

    def test_forgetting_one_phone(self):
        made, radio, clock = box()
        connect(made)
        self.second_phone(made)
        made.on_event('write', PHONE, command(2, 'BT_LIST'))
        rows = [r.split('|')[0] for r in self.answers(made, radio)[0][1].split(';')]
        other = rows[1]
        made.on_event('write', PHONE, command(3, 'BT_FORGET,00:00:00:00:00:00'))
        made.on_event('write', PHONE, command(4, 'BT_FORGET,' + other))
        self.assertEqual(self.answers(made, radio)[1:], [['ERR', 'ADDR'], ['OK']])
        self.assertEqual(len(made.bonds), 1)
        made.tick()
        self.assertEqual(radio.disconnected, [OTHER])
        # The forgotten phone has no key any more.
        self.assertNotIn('Other', made.auth_keys)

    def test_a_phone_that_doesnt_change_the_box_forgets_only_itself(self):
        made, radio, _ = box()
        connect(made)
        self.second_phone(made)
        made.on_event('write', OTHER, command(2, 'BT_LIST'))
        rows = [r.split('|') for r in self.answers(made, radio)[0][1].split(';')]
        mine = [r[0] for r in rows if r[3] == '1'][0]
        theirs = [r[0] for r in rows if r[3] == '0'][0]
        made.on_event('write', OTHER, command(3, 'BT_FORGET,' + theirs))
        made.on_event('write', OTHER, command(4, 'BT_FORGET,' + mine))
        self.assertEqual(self.answers(made, radio)[1:], [['ERR', 'BUSY'], ['OK']])
        self.assertEqual(list(made.bonds), [theirs])

    def test_the_phone_that_forgets_itself_is_dropped_half_a_second_after_its_ok(self):
        made, radio, clock = box()
        connect(made)
        made.on_event('write', PHONE, command(2, 'BT_LIST'))
        made.tick()
        address = fields(radio.lines('NGA')[-1])[3].split('|')[0]
        made.on_event('write', PHONE, command(3, 'BT_FORGET,' + address))
        made.tick()
        self.assertEqual(fields(radio.lines('NGA')[-1])[2:], ['OK'])
        self.assertEqual(radio.disconnected, [])
        clock.pass_s(0.6)
        made.tick()
        self.assertEqual(radio.disconnected, [PHONE])
        self.assertEqual(made.bonds, {})

    def test_forgetting_all_is_no_command_any_more(self):
        made, radio, _ = box()
        connect(made)
        made.on_event('write', PHONE, command(2, 'BT_FORGET'))
        self.assertEqual(self.answers(made, radio), [['ERR', 'VALUE']])
        self.assertEqual(len(made.bonds), 1)

    def test_factory_reset_erases_the_box_after_its_ok(self):
        made, radio, clock = box()
        connect(made)
        self.second_phone(made)
        made.state.adv['pairing_open'] = False
        made.on_event('write', PHONE, command(2, 'AUTH_SET,000102030405060708090a0b0c0d0e0f'))
        made.on_event('write', PHONE, command(3, 'FACTORY_RESET'))
        made.tick()
        self.assertEqual([fields(raw)[2:] for raw in radio.lines('NGA')][-1], ['OK'])
        # The answer goes first: nothing is erased yet.
        self.assertEqual(len(made.bonds), 2)
        self.assertEqual(radio.disconnected, [])
        clock.pass_s(sim.FORGET_DROP_S + 0.1)
        made.tick()
        self.assertEqual(made.bonds, {})
        self.assertEqual(made.auth_keys, {})
        self.assertEqual(sorted(radio.disconnected), sorted([PHONE, OTHER]))
        self.assertEqual(made.state.adv, {'pairing_open': True, 'full': False, 'has_phones': False})

    def test_factory_reset_is_for_the_phone_the_box_listens_to(self):
        made, radio, clock = box()
        connect(made)
        self.second_phone(made)
        made.on_event('write', OTHER, command(2, 'FACTORY_RESET'))
        self.assertEqual(self.answers(made, radio), [['ERR', 'BUSY']])
        clock.pass_s(1)
        made.tick()
        self.assertEqual(len(made.bonds), 2)

    def test_a_phone_is_not_bonded_while_the_box_resets(self):
        made, radio, clock = box()
        connect(made)
        made.on_event('write', PHONE, command(2, 'FACTORY_RESET'))
        made.on_event('connect', OTHER, 'Other')
        made.on_event('write', OTHER, command(1, 'HELLO,Other,1'))
        self.assertEqual(len(made.bonds), 1)

    def test_the_panel_resets_the_box(self):
        made, radio, _ = box()
        connect(made)
        made.panel_action('factory_reset', '')
        self.assertEqual(made.bonds, {})
        made.tick()
        self.assertEqual(radio.disconnected, [PHONE])
        self.assertTrue(made.panel_state()['adv']['pairing_open'])

    def test_quick_power_ons_open_a_window_in_which_a_new_phone_erases_nobody(self):
        made, radio, _ = box()
        connect(made)
        made.state.adv['pairing_open'] = False
        # A closed window takes no new phone.
        self.second_phone(made)
        self.assertEqual(len(made.bonds), 1)
        made.on_event('disconnect', OTHER)
        made.panel_action('quick_power_ons', '')
        self.assertTrue(made.state.recovery_window)
        self.assertTrue(made.state.adv['pairing_open'])
        self.second_phone(made)
        self.assertEqual(sorted(b['name'] for b in made.bonds.values()), ['Other', 'Test phone'])
        # The phone that paired closes the window.
        self.assertFalse(made.state.recovery_window)
        self.assertFalse(made.state.adv['pairing_open'])
        made.tick()
        self.assertEqual(radio.disconnected, [])

    def test_quick_power_ons_of_a_full_box_drop_the_phone_with_the_oldest_hello(self):
        made, radio, clock = box()
        connect(made)
        for number in range(1, 4):
            clock.pass_s(1)
            made.on_event('connect', 'p%d' % number, 'P')
            made.on_event('subscribe', 'p%d' % number, 182)
            made.on_event('write', 'p%d' % number, command(1, 'HELLO,Phone %d,1' % number))
        self.assertTrue(made.state.adv['full'])
        # The first phone speaks again: the oldest HELLO is Phone 1's now.
        clock.pass_s(1)
        made.on_event('write', PHONE, command(5, 'HELLO,Test phone,1'))
        made.panel_action('quick_power_ons', '')
        clock.pass_s(1)
        self.second_phone(made, 'Fifth')
        names = sorted(b['name'] for b in made.bonds.values())
        self.assertEqual(names, ['Fifth', 'Phone 2', 'Phone 3', 'Test phone'])
        made.tick()
        # One event, sent to every phone that listens.
        drop = [fields(raw) for raw in radio.lines('NGE')]
        self.assertEqual({(f[2], f[4], f[5], f[6]) for f in drop},
                         {('0', 'W', 'BT_DROP', sim.bond_address('Phone 1'))})
        # The dropped phone has no key and its link is dropped.
        self.assertEqual(radio.disconnected, ['p1'])

    def test_a_full_box_takes_no_phone_outside_the_recovery_window(self):
        made, _, _ = box()
        connect(made)
        for number in range(1, 4):
            made.on_event('connect', 'p%d' % number, 'P')
            made.on_event('write', 'p%d' % number, command(1, 'HELLO,Phone %d,1' % number))
        made.state.adv['pairing_open'] = True
        self.second_phone(made, 'Fifth')
        self.assertEqual(len(made.bonds), 4)
        self.assertNotIn(sim.bond_address('Fifth'), made.bonds)

    def test_a_lapsed_phone_ranks_after_the_other_at_its_next_hello(self):
        made, radio, clock = box()
        connect(made)
        self.second_phone(made)
        clock.pass_s(sim.HELLO_TIMEOUT_S - 1)
        made.on_event('write', OTHER, command(5, 'STATUS'))
        clock.pass_s(2)
        self.assertIs(made.changer(), made.phones[OTHER])
        made.on_event('write', PHONE, command(6, 'HELLO,Test phone,1794685760'))
        self.assertIs(made.changer(), made.phones[OTHER])

    def test_forgetting_a_gone_phone_drops_its_key(self):
        made, radio, _ = box()
        connect(made)
        self.second_phone(made)
        made.on_event('write', OTHER, command(5, 'AUTH_SET,000102030405060708090a0b0c0d0e0f'))
        self.assertIn('Other', made.auth_keys)
        made.on_event('disconnect', OTHER)
        made.forget(sim.bond_address('Other'))
        self.assertNotIn('Other', made.auth_keys)

    def test_the_panel_forgets_a_bond(self):
        made, _, _ = box()
        connect(made)
        address = next(iter(made.bonds))
        made.panel_action('forget_bond', address)
        self.assertEqual(made.bonds, {})

    def test_the_box_takes_a_key_and_proves_itself(self):
        made, radio, _ = box()
        connect(made)
        key = '000102030405060708090a0b0c0d0e0f'
        made.on_event('write', PHONE, command(10, 'AUTH,a1b2c3d4e5f60718'))
        made.on_event('write', PHONE, command(11, 'AUTH_SET,' + key))
        made.on_event('write', PHONE, command(12, 'AUTH,a1b2c3d4e5f60718'))
        made.on_event('write', PHONE, command(13, 'AUTH,A1B2C3D4E5F60718'))
        made.tick()
        got = [fields(raw)[1:] for raw in radio.lines('NGA')]
        # The vector is the one of the core's test of esp32::AuthProof.
        self.assertEqual(got, [['10', 'ERR', 'NOKEY'], ['11', 'OK'], ['12', 'OK', '0620aee41375224a'],
                               ['13', 'OK', '0620aee41375224a']])

    def test_the_key_is_taken_once_and_kept_for_the_phone(self):
        made, radio, _ = box()
        connect(made)
        key = '000102030405060708090a0b0c0d0e0f'
        other = 'ff' * 16
        made.on_event('write', PHONE, command(1, 'AUTH_SET,' + key))
        # The same key again is taken (its answer may have been lost), another one is not.
        made.on_event('write', PHONE, command(2, 'AUTH_SET,' + key))
        made.on_event('write', PHONE, command(3, 'AUTH_SET,' + other))
        made.on_event('write', PHONE, command(4, 'AUTH_SET,' + key[:-2]))
        made.on_event('write', PHONE, command(5, 'AUTH_SET,' + 'zz' * 16))
        made.on_event('write', PHONE, command(6, 'AUTH,a1b2c3d4e5f6071'))
        made.on_event('write', PHONE, command(7, 'AUTH'))
        made.tick()
        got = [fields(raw)[1:] for raw in radio.lines('NGA')]
        self.assertEqual(got, [['1', 'OK'], ['2', 'OK'], ['3', 'ERR', 'EXISTS'], ['4', 'ERR', 'VALUE'],
                               ['5', 'ERR', 'VALUE'], ['6', 'ERR', 'VALUE'], ['7', 'ERR', 'VALUE']])
        # The key stays after the phone has gone and comes back.
        made.on_event('disconnect', PHONE)
        connect(made)
        made.on_event('write', PHONE, command(1, 'AUTH,a1b2c3d4e5f60718'))
        made.tick()
        self.assertEqual(fields(radio.lines('NGA')[-1])[2:], ['OK', '0620aee41375224a'])

    def test_the_keys_of_the_phones_outlive_the_program(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, 'keys.json')
            first, _, _ = box(keys_path=path)
            connect(first)
            first.on_event('write', PHONE, command(1, 'AUTH_SET,000102030405060708090a0b0c0d0e0f'))
            first.tick()
            # The program starts again, as the box restarts: the key of the phone is where NVS keeps it.
            again, radio, _ = box(keys_path=path)
            connect(again)
            again.on_event('write', PHONE, command(2, 'AUTH,a1b2c3d4e5f60718'))
            again.tick()
            self.assertEqual(fields(radio.lines('NGA')[-1])[2:], ['OK', '0620aee41375224a'])
            # A box of another id has its own keys in the same file.
            other, other_radio, _ = box(box_id='S2', keys_path=path)
            connect(other)
            other.on_event('write', PHONE, command(3, 'AUTH,a1b2c3d4e5f60718'))
            other.tick()
            self.assertEqual(fields(other_radio.lines('NGA')[-1])[2:], ['ERR', 'NOKEY'])
            # The keys the panel makes the box forget are gone from the file too.
            again.panel_action('forget_keys', '')
            last, _, _ = box(keys_path=path)
            self.assertEqual(last.auth_keys, {})

    def test_the_key_follows_the_phone_through_a_new_address(self):
        made, radio, _ = box()
        connect(made)
        made.on_event('write', PHONE, command(1, 'AUTH_SET,000102030405060708090a0b0c0d0e0f'))
        made.on_event('disconnect', PHONE)
        # The private address of the phone has changed, so the radio gives the link another id; the name of its
        # HELLO is the same, and the key is the phone's.
        made.on_event('connect', 'phone-2', 'Test phone')
        made.on_event('subscribe', 'phone-2', 182)
        made.on_event('write', 'phone-2', command(2, 'HELLO,Test phone,1794685761'))
        made.on_event('write', 'phone-2', command(3, 'AUTH,a1b2c3d4e5f60718'))
        made.tick()
        self.assertEqual(fields(radio.lines('NGA')[-1])[1:], ['3', 'OK', '0620aee41375224a'])
        self.assertEqual(made.panel_state()['keys'], 1)

    def test_the_keys_follow_the_id_the_panel_sets(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, 'keys.json')
            made, radio, _ = box(keys_path=path)
            connect(made)
            first = '000102030405060708090a0b0c0d0e0f'
            made.on_event('write', PHONE, command(1, 'AUTH_SET,' + first))
            # Another id is another box: it has no key of this phone, and takes the one the application gives it.
            made.panel_set({'box_id': 'S2'})
            self.assertEqual(made.panel_state()['keys'], 0)
            made.on_event('write', PHONE, command(2, 'AUTH_SET,' + 'ff' * 16))
            made.tick()
            self.assertEqual(fields(radio.lines('NGA')[-1])[1:], ['2', 'OK'])
            # Back at the first id, the first key is the one the box proves itself with.
            made.panel_set({'box_id': 'S1'})
            made.on_event('write', PHONE, command(3, 'AUTH,a1b2c3d4e5f60718'))
            made.tick()
            self.assertEqual(fields(radio.lines('NGA')[-1])[1:], ['3', 'OK', '0620aee41375224a'])
            # Both boxes have their keys in the file.
            with open(path, encoding='utf-8') as kept:
                self.assertEqual(sorted(sim.json.load(kept)), ['S1', 'S2'])

    def test_the_panel_makes_the_box_forget_the_keys(self):
        made, radio, _ = box()
        connect(made)
        made.on_event('write', PHONE, command(1, 'AUTH_SET,' + '00' * 16))
        self.assertEqual(made.panel_state()['keys'], 1)
        made.panel_action('forget_keys', '')
        self.assertEqual(made.panel_state()['keys'], 0)
        made.on_event('write', PHONE, command(2, 'AUTH,a1b2c3d4e5f60718'))
        made.tick()
        self.assertEqual(fields(radio.lines('NGA')[-1])[2:], ['ERR', 'NOKEY'])

    def test_a_line_with_a_wrong_checksum_is_dropped(self):
        made, radio, _ = box()
        connect(made)
        made.on_event('write', PHONE, b'$NGC,10,STATUS*0000\r\n')
        made.tick()
        self.assertEqual(radio.lines('NGA'), [])
        self.assertEqual(len(radio.lines('NGS')), 1)

    def test_two_commands_in_one_write(self):
        made, radio, _ = box()
        connect(made)
        made.on_event('write', PHONE, command(11, 'CAL_BIAS') + command(12, 'CAL_UP'))
        made.tick()
        self.assertEqual([fields(raw)[1] for raw in radio.lines('NGA')], ['11', '12'])


class Session(unittest.TestCase):
    def test_no_data_before_a_hello(self):
        made, radio, _ = box()
        connect(made, hello=False)
        made.tick()
        self.assertEqual(radio.lines('NGD'), [])
        self.assertEqual(radio.lines('NGS'), [])

    def test_the_data_stops_ten_seconds_after_the_last_command(self):
        made, radio, clock = box()
        connect(made)
        made.tick()
        self.assertEqual(len(radio.lines('NGD')), 1)
        clock.pass_s(9.9)
        made.tick()
        self.assertEqual(len(radio.lines('NGD')), 2)
        clock.pass_s(0.2)
        made.tick()
        self.assertEqual(len(radio.lines('NGD')), 2)
        # The phone is back on the air: the data goes again, and the sequence number goes on.
        made.on_event('write', PHONE, command(20, 'HELLO,Test phone,1794685770'))
        made.tick()
        self.assertEqual(len(radio.lines('NGD')), 3)
        self.assertEqual([fields(raw)[2] for raw in radio.lines('NGD')], ['1', '2', '3'])

    def test_any_command_keeps_the_session(self):
        made, radio, clock = box()
        connect(made)
        for number in range(2, 5):
            clock.pass_s(6)
            made.on_event('write', PHONE, command(number, 'STATUS'))
            made.tick()
        self.assertEqual(len(radio.lines('NGD')), 3)

    def test_a_command_does_not_start_a_session(self):
        made, radio, _ = box()
        connect(made, hello=False)
        made.on_event('write', PHONE, command(1, 'STATUS'))
        made.tick()
        self.assertEqual(radio.lines('NGD'), [])

    def test_a_command_does_not_restart_an_ended_session(self):
        """Section 9.2: the box has freed the phone's slot, so only a HELLO starts the session again."""
        made, radio, clock = box()
        connect(made)
        clock.pass_s(sim.HELLO_TIMEOUT_S + 1)
        made.on_event('write', PHONE, command(2, 'STATUS'))
        made.tick()
        self.assertEqual(radio.lines('NGD'), [])
        made.on_event('write', PHONE, command(3, 'HELLO,Test phone,1794685770'))
        made.tick()
        self.assertEqual(len(radio.lines('NGD')), 1)

    def test_peer_does_not_keep_the_session(self):
        """The box relays PEER before it looks at the commands, so it does not refresh the session."""
        made, radio, clock = box()
        connect(made)
        clock.pass_s(6)
        made.on_event('write', PHONE, command(2, 'PEER,SELF,1000,0,0,0,10,BOX'))
        clock.pass_s(5)
        made.tick()
        self.assertEqual(radio.lines('NGD'), [])

    def test_two_phones_hear_the_same_data_line(self):
        """Section 9.7: both phones hear the same NGD, so its totals are one moment for both."""
        made, radio, _ = box()
        connect(made)
        made.on_event('connect', 'phone-2', 'Other phone')
        made.on_event('subscribe', 'phone-2', 182)
        made.on_event('write', 'phone-2', command(1, 'HELLO,Other phone,1794685760'))
        made.tick()
        sent = {}
        for phone_id, data in radio.sent:
            sent.setdefault(phone_id, b'')
            sent[phone_id] += data
        lines = {phone_id: [raw for raw in text.decode('ascii').split('\r\n') if raw[1:4] == 'NGD']
                 for phone_id, text in sent.items()}
        self.assertEqual(sorted(lines), [PHONE, 'phone-2'])
        self.assertEqual(lines[PHONE], lines['phone-2'])
        # One packet, so one number: not one per phone.
        self.assertEqual(fields(lines[PHONE][0])[2], '1')
        made.tick()
        self.assertEqual(made.seq, 2)

    def test_the_status_goes_once_a_second_and_at_once_on_a_change(self):
        made, radio, clock = box()
        connect(made)
        made.tick()
        self.assertEqual(len(radio.lines('NGS')), 1)
        clock.pass_s(0.5)
        made.tick()
        self.assertEqual(len(radio.lines('NGS')), 1)
        made.panel_set({'obd': 'OK'})
        made.tick()
        self.assertEqual(len(radio.lines('NGS')), 2)
        clock.pass_s(1.1)
        made.tick()
        self.assertEqual(len(radio.lines('NGS')), 3)

    def test_a_dropped_data_line_carries_nothing_away(self):
        """BLE-8: the box drops an NGD the stack can't take, and the next one tells the same totals."""
        made, radio, clock = box()
        connect(made)
        made.tick()
        radio.take = 0
        clock.pass_s(0.02)
        made.tick()
        self.assertEqual(made.phones[PHONE].dropped, 1)
        self.assertEqual(len(radio.lines('NGD')), 1)
        radio.take = None
        clock.pass_s(0.02)
        made.tick()
        data = radio.lines('NGD')
        self.assertEqual(len(data), 2)
        # The turn, the rate and the path are the totals since the box started: the drop lost nothing.
        self.assertEqual(fields(data[0])[4:7], fields(data[1])[4:7])

    def test_the_answers_go_before_the_data_and_wait_for_the_stack(self):
        """BLE-8: NGI, NGS and NGA wait in the queue; the data line is not even tried before them."""
        made, radio, _ = box(take=0)
        connect(made)
        made.tick()
        self.assertEqual(radio.sent, [])
        self.assertEqual(made.phones[PHONE].dropped, 0)
        radio.take = None
        made.tick()
        self.assertEqual([raw[1:4] for raw in radio.lines()], ['NGI', 'NGS', 'NGD'])

    def test_a_line_that_started_going_out_is_finished(self):
        """BLE-4: half a line is not thrown away, and it is not sent twice either."""
        made, radio, _ = box(take=1)
        connect(made, payload=20)
        made.tick()
        started = len(radio.sent)
        self.assertEqual(started, 1)
        radio.take = None
        made.tick()
        info = radio.lines('NGI')
        self.assertEqual(len(info), 1)
        self.assertIsNotNone(fields(info[0]))
        # The panel says it once, not once per piece.
        told = [item for item in made.panel_lines(0, False)['lines'] if item['kind'] == 'NGI']
        self.assertEqual(len(told), 1)

    def test_the_panel_drops_a_phone_only_from_the_tick(self):
        made, radio, _ = box()
        connect(made)
        made.panel_action('stop', '')
        self.assertIn(PHONE, made.phones)
        made.tick()
        self.assertEqual(made.phones, {})
        self.assertIsNone(radio.advertisement)
        made.panel_action('start', '')
        made.tick()
        self.assertEqual(radio.advertisement, ('NonGPS-S1', None))

    def test_a_box_that_is_not_updated_advertises_the_old_name(self):
        made, radio, _ = box()
        made.panel_set({'legacy_name': True})
        self.assertEqual(made.state.name(), 'NoGPS-S1')
        made.panel_set({'legacy_name': False})
        self.assertEqual(made.state.name(), 'NonGPS-S1')

    def test_the_panel_shuts_the_simulator_down(self):
        made, radio, clock = box()
        connect(made)
        made.tick()
        state = made.panel_action('quit', '')
        # Off the air at once, and the answer tells the page to stop asking.
        self.assertFalse(state['advertising'])
        self.assertTrue(state['quitting'])
        self.assertFalse(radio.stopped.is_set())
        # The program itself goes a moment later, so the answer reaches the page first.
        made.tick()
        self.assertFalse(radio.stopped.is_set())
        clock.pass_s(sim.QUIT_DELAY_S)
        made.tick()
        self.assertTrue(radio.stopped.is_set())
        self.assertEqual(made.phones, {})

    def test_the_panel_sees_the_phone_and_the_lines(self):
        made, radio, _ = box()
        connect(made)
        made.tick()
        state = made.panel_state()
        self.assertEqual(state['radio'], 'fake')
        self.assertEqual(len(state['phones']), 1)
        self.assertEqual(state['phones'][0]['name'], 'Test phone')
        self.assertTrue(state['phones'][0]['heard'])
        self.assertEqual(state['phones'][0]['hello_age_ms'], 0)
        # IMU_OK, BIAS_OK, UP_OK, STILL, and OBD_ABSENT of the adapter that isn't there.
        self.assertEqual(state['flags_value'], '227')
        without = made.panel_lines(0, False)
        self.assertTrue(all(item['kind'] != 'NGD' for item in without['lines']))
        self.assertTrue(any(item['kind'] == 'NGD' for item in made.panel_lines(0, True)['lines']))

    def test_the_panel_shows_the_age_of_the_last_hello(self):
        """The panel says 'HELLO ... s ago': a command of another kind keeps the session but is not a HELLO."""
        made, _, clock = box()
        connect(made)
        clock.pass_s(4)
        made.on_event('write', PHONE, command(2, 'STATUS'))
        made.tick()
        self.assertEqual(made.panel_state()['phones'][0]['hello_age_ms'], 4000)

    def test_the_panel_does_not_take_a_flag_it_doesnt_know(self):
        made, _, _ = box()
        made.panel_set({'flags': {'NOPE': True}, 'shake_pct': 50000, 'obd': 'NOT_A_STATE'})
        self.assertNotIn('NOPE', made.state.flags)
        self.assertEqual(made.state.shake_pct, 9999)
        self.assertEqual(made.state.obd, 'NO_ADAPTER')
        # The id is the four characters of the name of a box.
        made.panel_set({'box_id': 'TOOLONG'})
        self.assertEqual(made.state.name(), 'NonGPS-TOOL')
        made.panel_set({'legacy_name': True})
        self.assertEqual(made.panel_state()['legacy_name'], True)
        self.assertEqual(made.state.name(), 'NoGPS-TOOL')

    def test_the_panel_takes_the_id_of_a_real_box(self):
        made, _, _ = box()
        # The panel takes a four-character id whole, as --id does: a box of a known car can be stood in for.
        made.panel_set({'box_id': 'C47D'})
        self.assertEqual(made.panel_state()['box_id'], 'C47D')
        self.assertEqual(made.state.name(), 'NonGPS-C47D')
        self.assertEqual(fields(made.state.info().decode('ascii').strip())[6], 'C47D')


class SilenceWatchTest(unittest.TestCase):
    def test_a_central_is_gone_only_after_a_long_silence(self):
        clock = Clock()
        watch = sim.SilenceWatch(clock)
        watch.wrote('a')
        watch.wrote('b')
        clock.pass_s(sim.SILENT_GONE_S - 1)
        watch.wrote('b')
        self.assertGreater(sim.SILENT_GONE_S, 5 * sim.HELLO_TIMEOUT_S)
        self.assertEqual(watch.gone(), [])
        clock.pass_s(1)
        self.assertEqual(watch.gone(), ['a'])
        # Taken once; a phone that writes again is watched again.
        self.assertEqual(watch.gone(), [])
        watch.wrote('a')
        watch.forget('b')
        clock.pass_s(sim.SILENT_GONE_S)
        self.assertEqual(watch.gone(), ['a'])


class WindowsRadioTest(unittest.TestCase):
    """The bookkeeping of the radio of Windows, over a stub of winsdk: nothing here touches Bluetooth."""

    @classmethod
    def setUpClass(cls):
        from unittest import mock
        names = ['winsdk', 'winsdk.windows', 'winsdk.windows.devices', 'winsdk.windows.devices.bluetooth',
                 'winsdk.windows.devices.bluetooth.advertisement',
                 'winsdk.windows.devices.bluetooth.genericattributeprofile', 'winsdk.windows.storage',
                 'winsdk.windows.storage.streams']
        cls.patch = mock.patch.dict(sys.modules, {name: mock.MagicMock() for name in names})
        cls.patch.start()
        sys.modules.pop('nogps_box_sim_radio_windows', None)
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        cls.module = importlib.import_module('nogps_box_sim_radio_windows')

    @classmethod
    def tearDownClass(cls):
        sys.modules.pop('nogps_box_sim_radio_windows', None)
        cls.patch.stop()

    def radio(self):
        radio = self.module.Radio()
        radio.events = []
        radio.on_event = lambda *args: radio.events.append(args)
        return radio

    @staticmethod
    def provider():
        calls = []
        return types.SimpleNamespace(calls=calls, start_advertising=lambda parameters: calls.append('start'),
                                     stop_advertising=lambda: calls.append('stop'))

    @staticmethod
    def client(phone_id, size):
        return types.SimpleNamespace(session=types.SimpleNamespace(device_id=types.SimpleNamespace(id=phone_id)),
                                     max_notification_size=size)

    def test_write_after_silence_keeps_the_client(self):
        radio = self.radio()
        radio.tx = types.SimpleNamespace(subscribed_clients=[self.client('dev-a', 182)])
        radio.sync_clients(radio.tx.subscribed_clients)
        radio.forget('dev-a')
        radio.on_write('dev-a', b'HELLO')
        self.assertIn('dev-a', radio.clients)
        self.assertEqual(radio.phones['dev-a'], 182)

    def test_subscribed_client_is_a_phone(self):
        radio = self.radio()
        radio.sync_clients([self.client('dev-a', 182)])
        self.assertEqual(radio.events, [('connect', 'dev-a', 'dev-a'), ('subscribe', 'dev-a', 182)])
        radio.sync_clients([self.client('dev-a', 182)])
        self.assertEqual(len(radio.events), 2)
        radio.sync_clients([self.client('dev-a', 20)])
        self.assertEqual(radio.events[-1], ('subscribe', 'dev-a', 20))
        radio.sync_clients([])
        self.assertEqual(radio.events[-1], ('disconnect', 'dev-a'))
        self.assertEqual(radio.phones, {})

    def test_notification_is_never_shorter_than_the_smallest(self):
        radio = self.radio()
        radio.sync_clients([self.client('dev-a', 5)])
        self.assertEqual(radio.events[-1], ('subscribe', 'dev-a', sim.MIN_PAYLOAD))

    def test_write_from_an_unknown_phone_makes_it_a_phone(self):
        radio = self.radio()
        radio.on_write('dev-a', b'HELLO')
        self.assertEqual([e[0] for e in radio.events], ['connect', 'subscribe', 'write'])
        self.assertEqual(radio.events[-1], ('write', 'dev-a', b'HELLO'))

    def test_send_needs_a_subscribed_phone_and_room(self):
        radio = self.radio()
        self.assertFalse(radio.send('dev-a', b'x'))
        radio.on_write('dev-a', b'HELLO')
        self.assertFalse(radio.send('dev-a', b'x'))
        radio.sync_clients([self.client('dev-a', 182)])
        radio.pending = sim.QUEUE_LINES
        self.assertFalse(radio.send('dev-a', b'x'))

    def test_disconnect_forgets_the_phone_once(self):
        radio = self.radio()
        radio.sync_clients([self.client('dev-a', 182)])
        radio.disconnect('dev-a')
        radio.disconnect('dev-a')
        self.assertEqual([e for e in radio.events if e[0] == 'disconnect'], [('disconnect', 'dev-a')])

    def test_the_advertisement_is_the_service_alone(self):
        """Windows reserves the name and the flags of BLE-13, so the panel changes nothing in the advertisement."""
        self.assertFalse(self.module.Radio.supports_manufacturer_data)
        radio = self.radio()
        radio.provider = self.provider()
        radio.wanted = (sim.NAME_PREFIX + 'S1', None)
        with contextlib.redirect_stdout(io.StringIO()):
            asyncio.run(radio.apply())
            asyncio.run(radio.apply())
            self.assertEqual(radio.provider.calls, ['start'])
            radio.wanted = None
            asyncio.run(radio.apply())
        self.assertEqual(radio.provider.calls, ['start', 'stop'])

    def test_default_radio_of_each_platform(self):
        self.assertEqual([sim.default_radio(p) for p in ('darwin', 'linux', 'win32', 'freebsd')],
                         ['macos', 'linux', 'windows', 'fake'])


if __name__ == '__main__':
    unittest.main()
