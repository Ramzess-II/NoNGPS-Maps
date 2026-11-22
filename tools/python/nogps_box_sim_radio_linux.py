#!/usr/bin/env python3
"""The radio of nogps_box_sim.py on Linux: a GATT server and an advertisement of BlueZ over D-Bus.

  just box

nogps_box_sim.py declares the package for uv, which keeps it out of the system Python.

BlueZ gives what CoreBluetooth doesn't: the manufacturer data of BLE-13 is advertised, so the panel's flags of the
pairing window reach the phone and a release build of iOS connects as it does to a box. A pairing with a passkey is
BlueZ's to give too, through an agent, but the simulator doesn't ask for one yet, so the phone never pairs with it:
Android takes the lines of a paired box alone, so a debug build is needed here as well.

What it does differently from the box:
- BlueZ tells the device of a write but not of a StartNotify, so a phone is known from its first command. The lines
  go to everyone subscribed, which is one phone: two at once are out of the simulator's scope.
- the length of a notification comes from the MTU of the last write; until then the smallest a phone may give.
"""

import asyncio

from dbus_next import BusType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method
from dbus_next.constants import PropertyAccess

import nogps_box_sim as sim

BLUEZ = 'org.bluez'
ROOT = '/org/nogps/box'
SERVICE_PATH = ROOT + '/service0'
TX_PATH = SERVICE_PATH + '/char0'
RX_PATH = SERVICE_PATH + '/char1'
ADVERTISEMENT_PATH = ROOT + '/advertisement0'


class Advertisement(ServiceInterface):
    """org.bluez.LEAdvertisement1: the name, the service and the manufacturer data of BLE-13."""

    def __init__(self, radio):
        super().__init__('org.bluez.LEAdvertisement1')
        self.radio = radio

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> 's':
        return 'peripheral'

    @dbus_property(access=PropertyAccess.READ)
    def ServiceUUIDs(self) -> 'as':
        return [sim.SERVICE_UUID.lower()]

    @dbus_property(access=PropertyAccess.READ)
    def LocalName(self) -> 's':
        return self.radio.local_name

    @dbus_property(access=PropertyAccess.READ)
    def ManufacturerData(self) -> 'a{qv}':
        # BlueZ puts the company id in itself, so only the format version and the flags go here.
        return {sim.COMPANY_ID: Variant('ay', bytes(self.radio.manufacturer[2:]))}

    @dbus_property(access=PropertyAccess.READ)
    def Discoverable(self) -> 'b':
        return True

    @method()
    def Release(self):
        pass


class Characteristic(ServiceInterface):
    """org.bluez.GattCharacteristic1: TX notifies the lines of the box, RX takes the commands (BLE-3)."""

    def __init__(self, path, uuid, flags, radio):
        super().__init__('org.bluez.GattCharacteristic1')
        self.path = path
        self.uuid = uuid.lower()
        self.flags = flags
        self.radio = radio
        self.value = bytes()
        self.notifying = False

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> 's':
        return self.uuid

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> 'o':
        return SERVICE_PATH

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> 'as':
        return self.flags

    @dbus_property(access=PropertyAccess.READ)
    def Notifying(self) -> 'b':
        return self.notifying

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> 'ay':
        return self.value

    @method()
    def WriteValue(self, value: 'ay', options: 'a{sv}'):
        device = options.get('device')
        mtu = options.get('mtu')
        self.radio.on_write(device.value if device else '', mtu.value if mtu else 0, bytes(value))

    @method()
    def ReadValue(self, options: 'a{sv}') -> 'ay':
        return self.value

    @method()
    def StartNotify(self):
        self.notifying = True
        self.radio.on_notify(True)

    @method()
    def StopNotify(self):
        self.notifying = False
        self.radio.on_notify(False)

    def notify(self, data):
        self.value = data
        self.emit_properties_changed({'Value': data})

    def managed(self):
        return {'org.bluez.GattCharacteristic1': {
            'UUID': Variant('s', self.uuid), 'Service': Variant('o', SERVICE_PATH),
            'Flags': Variant('as', self.flags), 'Notifying': Variant('b', self.notifying),
            'Value': Variant('ay', self.value)}}


class Service(ServiceInterface):
    """org.bluez.GattService1: the one service of the box."""

    def __init__(self):
        super().__init__('org.bluez.GattService1')

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> 's':
        return sim.SERVICE_UUID.lower()

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> 'b':
        return True

    def managed(self):
        return {'org.bluez.GattService1': {'UUID': Variant('s', sim.SERVICE_UUID.lower()),
                                           'Primary': Variant('b', True)}}


class Application(ServiceInterface):
    """The object manager BlueZ reads the service and its characteristics from."""

    def __init__(self, radio):
        super().__init__('org.freedesktop.DBus.ObjectManager')
        self.radio = radio

    @method()
    def GetManagedObjects(self) -> 'a{oa{sa{sv}}}':
        return {SERVICE_PATH: self.radio.service.managed(),
                TX_PATH: self.radio.tx.managed(),
                RX_PATH: self.radio.rx.managed()}


class Radio:
    name = 'linux'
    supports_manufacturer_data = True

    def __init__(self):
        self.on_event = lambda *args: None
        self.local_name = sim.NAME_PREFIX + 'S1'
        self.manufacturer = bytes([0, 0, sim.ADV_FORMAT, 0])
        self.bus = None
        self.adapter = None
        self.service = Service()
        self.tx = Characteristic(TX_PATH, sim.TX_UUID, ['notify'], self)
        self.rx = Characteristic(RX_PATH, sim.RX_UUID, ['write', 'write-without-response'], self)
        self.advertisement = Advertisement(self)
        self.application = Application(self)
        self.registered = False
        self.advertising = False
        self.wanted = None
        self.phones = {}
        self.payload = sim.MIN_PAYLOAD
        self.loop = None
        self.stopped = False

    # The box asks. Everything runs on the thread of the loop, so these only remember and schedule.

    def advertise(self, name, manufacturer):
        self.wanted = (name, manufacturer)
        self.later(self.apply())

    def stop_advertising(self):
        self.wanted = None
        self.later(self.apply())

    def send(self, phone_id, data):
        """BlueZ takes the line and sends it to everyone subscribed; it doesn't refuse one."""
        if not self.tx.notifying or phone_id not in self.phones:
            return False
        self.tx.notify(data)
        return True

    def disconnect(self, phone_id):
        if phone_id in self.phones:
            self.later(self.drop(phone_id))

    def run(self, tick, interval_s):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self.serve(tick, interval_s))

    def stop(self):
        self.stopped = True

    def later(self, coroutine):
        if self.loop is None or not self.loop.is_running():
            coroutine.close()
            return
        asyncio.ensure_future(coroutine, loop=self.loop)

    # BlueZ answers.

    def on_write(self, device, mtu, data):
        if not device:
            return
        if mtu:
            # BLE-4: a notification holds MTU - 3 bytes.
            self.payload = max(sim.MIN_PAYLOAD, mtu - 3)
        if device not in self.phones:
            self.phones[device] = device.rsplit('/', 1)[-1]
            self.on_event('connect', device, self.phones[device].replace('dev_', '').replace('_', ':'))
            if self.tx.notifying:
                self.on_event('subscribe', device, self.payload)
        self.on_event('write', device, data)

    def on_notify(self, notifying):
        for device in self.phones:
            self.on_event('subscribe' if notifying else 'disconnect', device, self.payload)
        if not notifying:
            self.phones.clear()

    # The work on the bus.

    async def serve(self, tick, interval_s):
        self.bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        self.adapter = await self.find_adapter()
        self.bus.export(ROOT, self.application)
        self.bus.export(SERVICE_PATH, self.service)
        self.bus.export(TX_PATH, self.tx)
        self.bus.export(RX_PATH, self.rx)
        self.bus.export(ADVERTISEMENT_PATH, self.advertisement)
        await self.apply()
        while not self.stopped:
            await asyncio.sleep(interval_s)
            tick()
        await self.unregister()

    async def find_adapter(self):
        introspection = await self.bus.introspect(BLUEZ, '/')
        proxy = self.bus.get_proxy_object(BLUEZ, '/', introspection)
        objects = await proxy.get_interface('org.freedesktop.DBus.ObjectManager').call_get_managed_objects()
        for path, interfaces in objects.items():
            if 'org.bluez.GattManager1' in interfaces and 'org.bluez.LEAdvertisingManager1' in interfaces:
                return path
        raise SystemExit('No Bluetooth adapter with a GATT server: is BlueZ running?')

    async def interface(self, path, name):
        introspection = await self.bus.introspect(BLUEZ, path)
        return self.bus.get_proxy_object(BLUEZ, path, introspection).get_interface(name)

    async def apply(self):
        """Brings the service and the advertisement to what the panel wants."""
        if self.bus is None:
            return
        if self.wanted is None:
            await self.unregister()
            return
        self.local_name, self.manufacturer = self.wanted
        if not self.registered:
            manager = await self.interface(self.adapter, 'org.bluez.GattManager1')
            await manager.call_register_application(ROOT, {})
            self.registered = True
        if self.advertising:
            # The name or the flags have changed: BlueZ reads them again when the advertisement comes back.
            await self.stop_advertisement()
        advertising = await self.interface(self.adapter, 'org.bluez.LEAdvertisingManager1')
        await advertising.call_register_advertisement(ADVERTISEMENT_PATH, {})
        self.advertising = True

    async def stop_advertisement(self):
        if not self.advertising:
            return
        self.advertising = False
        advertising = await self.interface(self.adapter, 'org.bluez.LEAdvertisingManager1')
        await advertising.call_unregister_advertisement(ADVERTISEMENT_PATH)

    async def unregister(self):
        await self.stop_advertisement()
        for device in list(self.phones):
            await self.drop(device)
        if self.registered:
            self.registered = False
            manager = await self.interface(self.adapter, 'org.bluez.GattManager1')
            await manager.call_unregister_application(ROOT)

    async def drop(self, device):
        if self.phones.pop(device, None) is None:
            return
        self.on_event('disconnect', device)
        try:
            await (await self.interface(device, 'org.bluez.Device1')).call_disconnect()
        except Exception as e:
            print('Could not drop', device, e)
