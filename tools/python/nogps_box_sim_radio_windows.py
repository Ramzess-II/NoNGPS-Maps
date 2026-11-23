#!/usr/bin/env python3
"""The radio of nogps_box_sim.py on Windows: GattServiceProvider and an advertisement publisher of winsdk.

  just box

nogps_box_sim.py declares the package for uv, which keeps it out of the system Python.

Written without a Windows machine and not tried on one yet: the names of winsdk follow the WinRT documentation, and
the tests only drive the bookkeeping of the phones over a stub of the package. What a person on Windows has to see:
the box is found by a phone, the phone subscribes and gets the lines, a write reaches the panel's log, and with
the pairing window flag set a release build of the application takes the advertisement as a box that accepts a
new phone (BLE-13).

Two advertisements run side by side: the one of the GATT service provider (the service UUID, connectable) and the
one of the publisher, which carries what the provider's can't: the local name and the manufacturer data of BLE-13.
If the system refuses the second one next to the first, the log says so and the phone finds the box by its service
alone, the way it does on macOS.

What it does differently from the box:
- the pairing of BLE-11 is the system's: the simulator asks for no passkey, so Android takes the lines of a paired
  box alone and needs a debug build, as with the other radios.
- Windows can't drop a link from here: disconnect() forgets the phone and tells the box, and a phone that writes
  again slots into the same row.
- a phone that went away without an unsubscription is taken as gone by its silence alone, as on macOS.
- the length of a notification is the MTU of the link of each subscribed phone, less the 3 bytes of the header.
"""

import asyncio
import traceback
import uuid

from winsdk.windows.devices.bluetooth import BluetoothError
from winsdk.windows.devices.bluetooth.advertisement import (BluetoothLEAdvertisementPublisher,
                                                            BluetoothLEManufacturerData)
from winsdk.windows.devices.bluetooth.genericattributeprofile import (GattCharacteristicProperties,
                                                                      GattLocalCharacteristicParameters,
                                                                      GattProtectionLevel, GattServiceProvider,
                                                                      GattServiceProviderAdvertisingParameters,
                                                                      GattWriteOption)
from winsdk.windows.storage.streams import DataReader, DataWriter

import nogps_box_sim as sim


def to_buffer(data):
    writer = DataWriter()
    writer.write_bytes(data)
    return writer.detach_buffer()


def from_buffer(buffer):
    reader = DataReader.from_buffer(buffer)
    data = bytearray(reader.unconsumed_buffer_length)
    reader.read_bytes(data)
    return bytes(data)


class Radio:
    name = 'windows'
    supports_manufacturer_data = True

    def __init__(self):
        self.on_event = lambda *args: None
        self.loop = None
        self.stopped = False
        self.provider = None
        self.tx = None
        self.rx = None
        self.publisher = None
        self.provider_on = False
        self.publisher_on = False
        # What the panel wants: (name, manufacturer) or None.
        self.wanted = None
        # The phones the box knows -> the length of a notification each takes, and the subscribed ones' handles.
        self.phones = {}
        self.clients = {}
        # Notifications handed to Windows and not answered yet: a full queue is a refusal for the box (BLE-8).
        self.pending = 0
        self.silence = sim.SilenceWatch()
        self.tasks = set()

    # The box asks. Everything runs on the thread of the loop, so these only remember and schedule.

    def advertise(self, name, manufacturer):
        self.wanted = (name, manufacturer)
        self.spawn(self.apply())

    def stop_advertising(self):
        self.wanted = None
        self.spawn(self.apply())

    def send(self, phone_id, data):
        client = self.clients.get(phone_id)
        if client is None or self.pending >= sim.QUEUE_LINES:
            return False
        self.pending += 1
        self.spawn(self.notify(client, data))
        return True

    def disconnect(self, phone_id):
        self.forget(phone_id)

    def run(self, tick, interval_s):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self.serve(tick, interval_s))

    def stop(self):
        self.stopped = True

    def spawn(self, coroutine):
        if self.loop is None or not self.loop.is_running():
            coroutine.close()
            return
        task = asyncio.ensure_future(coroutine, loop=self.loop)
        self.tasks.add(task)
        task.add_done_callback(self.finished)

    def finished(self, task):
        self.tasks.discard(task)
        if not task.cancelled() and task.exception() is not None:
            print('The radio failed:', ''.join(traceback.format_exception(task.exception())))

    def post(self, function, *args):
        """Windows calls the handlers on a thread of its own: they go over to the thread of the loop."""
        self.loop.call_soon_threadsafe(function, *args)

    # Windows answers.

    def remember(self, phone_id, payload):
        """Tells the box of a new phone and of a changed notification length."""
        if phone_id not in self.phones:
            self.phones[phone_id] = None
            self.on_event('connect', phone_id, phone_id[-8:])
        if self.phones[phone_id] != payload:
            self.phones[phone_id] = payload
            self.on_event('subscribe', phone_id, payload)

    def forget(self, phone_id):
        self.silence.forget(phone_id)
        self.clients.pop(phone_id, None)
        if phone_id in self.phones:
            del self.phones[phone_id]
            self.on_event('disconnect', phone_id)

    def sync_clients(self, clients):
        """The subscribed clients of TX changed: a new one is a phone, one that left is a phone gone."""
        found = {client.session.device_id.id: client for client in clients}
        for phone_id in [p for p in self.clients if p not in found]:
            self.forget(phone_id)
        for phone_id, client in found.items():
            self.clients[phone_id] = client
            # BLE-4: a notification holds MTU - 3 bytes; Windows tells it as the size of a notification.
            self.remember(phone_id, max(sim.MIN_PAYLOAD, client.max_notification_size))
            self.silence.wrote(phone_id)

    def on_write(self, phone_id, data):
        self.remember(phone_id, self.phones.get(phone_id) or sim.MIN_PAYLOAD)
        self.silence.wrote(phone_id)
        self.on_event('write', phone_id, data)

    def write_requested(self, characteristic, args):
        deferral = args.get_deferral()
        self.post(self.spawn, self.read_write(args, deferral))

    async def read_write(self, args, deferral):
        try:
            request = await args.get_request_async()
            self.on_write(args.session.device_id.id, from_buffer(request.value))
            if request.option == GattWriteOption.WRITE_WITH_RESPONSE:
                request.respond()
        finally:
            deferral.complete()

    async def notify(self, client, data):
        try:
            await self.tx.notify_value_async(to_buffer(data), client)
        finally:
            self.pending -= 1

    # The work with Windows.

    async def serve(self, tick, interval_s):
        await self.create_service()
        await self.apply()
        while not self.stopped:
            await asyncio.sleep(interval_s)
            tick()
            for phone_id in self.silence.gone():
                self.forget(phone_id)
        self.wanted = None
        await self.apply()

    async def create_service(self):
        created = await GattServiceProvider.create_async(uuid.UUID(sim.SERVICE_UUID))
        if created.error != BluetoothError.SUCCESS:
            raise SystemExit('Windows gave no GATT server (%s): is Bluetooth LE on, and the adapter able to '
                             'be a peripheral?' % created.error)
        self.provider = created.service_provider
        # BLE-3: TX notifies the lines, RX takes the commands. The OTA characteristic is not here: the abilities of
        # NGI don't offer an update, and both applications take it as optional.
        self.tx = await self.add_characteristic(sim.TX_UUID, GattCharacteristicProperties.NOTIFY)
        self.rx = await self.add_characteristic(
            sim.RX_UUID, GattCharacteristicProperties.WRITE | GattCharacteristicProperties.WRITE_WITHOUT_RESPONSE)
        self.tx.add_subscribed_clients_changed(lambda sender, args: self.post(self.sync_clients_now))
        self.rx.add_write_requested(self.write_requested)

    def sync_clients_now(self):
        self.sync_clients(list(self.tx.subscribed_clients))

    async def add_characteristic(self, characteristic_uuid, properties):
        parameters = GattLocalCharacteristicParameters()
        parameters.characteristic_properties = properties
        parameters.read_protection_level = GattProtectionLevel.PLAIN
        parameters.write_protection_level = GattProtectionLevel.PLAIN
        created = await self.provider.service.create_characteristic_async(uuid.UUID(characteristic_uuid), parameters)
        if created.error != BluetoothError.SUCCESS:
            raise SystemExit('Windows refused the characteristic %s (%s)' % (characteristic_uuid, created.error))
        return created.characteristic

    async def apply(self):
        """Brings the two advertisements to what the panel wants."""
        if self.provider is None:
            return
        if self.publisher_on:
            self.publisher.stop()
            self.publisher_on = False
        if self.wanted is None:
            if self.provider_on:
                self.provider.stop_advertising()
                self.provider_on = False
            for phone_id in list(self.phones):
                self.forget(phone_id)
            return
        if not self.provider_on:
            parameters = GattServiceProviderAdvertisingParameters()
            parameters.is_connectable = True
            parameters.is_discoverable = True
            self.provider.start_advertising(parameters)
            self.provider_on = True
        name, manufacturer = self.wanted
        # A publisher is read when it starts, so a new name or new flags need a new one.
        self.publisher = BluetoothLEAdvertisementPublisher()
        self.publisher.advertisement.local_name = name
        # Windows puts the company id in itself: only the format version and the flags go in the data.
        self.publisher.advertisement.manufacturer_data.append(
            BluetoothLEManufacturerData(sim.COMPANY_ID, to_buffer(bytes(manufacturer[2:]))))
        self.publisher.start()
        self.publisher_on = True
        print('Advertising as', name)
