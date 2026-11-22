#!/usr/bin/env python3
"""The radio of nogps_box_sim.py on macOS: CBPeripheralManager through PyObjC.

  python3 -m pip install pyobjc-framework-CoreBluetooth

macOS asks for Bluetooth of the program that started this one, usually the terminal, and keeps the answer. If it
refuses, put the script into a small .app of its own: a bundle has an identity and an Info.plist with
NSBluetoothAlwaysUsageDescription of its own.

What CoreBluetooth doesn't give the simulator:
- the manufacturer data of BLE-13: startAdvertising takes the local name and the service UUIDs and nothing else, so
  the pairing window flag never reaches the phone and only a debug build of the application connects;
- the pairing of BLE-11: the system pairs by itself, with no bt_pin and no "display only" capability;
- dropping a central: there is no such call. Stop and Disconnect take the service away instead, which is what the
  phone sees when the box parks, and it searches again when the service comes back.
- the name in the advertisement is dropped by macOS when it is longer than 8 characters, because the 16 bytes of the
  service UUID leave no room: the name of the box is NoGPS- and two characters.
"""

import objc
from CoreBluetooth import (CBAdvertisementDataLocalNameKey, CBAdvertisementDataServiceUUIDsKey,
                           CBATTErrorSuccess, CBAttributePermissionsReadable, CBAttributePermissionsWriteable,
                           CBCharacteristicPropertyNotify, CBCharacteristicPropertyWrite,
                           CBCharacteristicPropertyWriteWithoutResponse, CBManagerStatePoweredOn,
                           CBMutableCharacteristic, CBMutableService, CBPeripheralManager, CBUUID)
from Foundation import NSData, NSDate, NSObject, NSRunLoop

import nogps_box_sim as sim


class Delegate(NSObject):
    """The calls of CoreBluetooth, all on the thread that runs the run loop."""

    def initWithRadio_(self, radio):
        self = objc.super(Delegate, self).init()
        self.radio = radio
        return self

    def peripheralManagerDidUpdateState_(self, manager):
        if manager.state() == CBManagerStatePoweredOn:
            self.radio.on_powered_on()
        else:
            print('Bluetooth is not on: state', manager.state())

    def peripheralManager_didAddService_error_(self, manager, service, error):
        if error is not None:
            print('The service of the box was refused:', error)
        self.radio.on_service_added(error)

    def peripheralManagerDidStartAdvertising_error_(self, manager, error):
        if error is not None:
            print('The advertisement was refused:', error)
        else:
            print('Advertising as', self.radio.local_name())

    def peripheralManager_central_didSubscribeToCharacteristic_(self, manager, central, characteristic):
        self.radio.on_subscribe(central)

    def peripheralManager_central_didUnsubscribeFromCharacteristic_(self, manager, central, characteristic):
        self.radio.on_unsubscribe(central)

    def peripheralManager_didReceiveWriteRequests_(self, manager, requests):
        for request in requests:
            value = request.value()
            self.radio.on_write(request.central(), bytes(value) if value is not None else b'')
        # One answer for the batch, as CoreBluetooth asks; a write without a response doesn't wait for it.
        if len(requests):
            manager.respondToRequest_withResult_(requests[0], CBATTErrorSuccess)

    def peripheralManagerIsReadyToUpdateSubscribers_(self, manager):
        self.radio.ready = True


class Radio:
    name = 'macos'
    supports_manufacturer_data = False

    def __init__(self):
        self.on_event = lambda *args: None
        self.delegate = Delegate.alloc().initWithRadio_(self)
        self.manager = CBPeripheralManager.alloc().initWithDelegate_queue_options_(self.delegate, None, None)
        self.tx = None
        self.rx = None
        self.centrals = {}
        # What the panel wants: (name, manufacturer) or None. Done as soon as Bluetooth is on.
        self.wanted = None
        self.powered_on = False
        # 'off', 'adding' while CoreBluetooth takes the service, then 'serving'. The advertisement waits for the
        # service: started before it is added, it never begins and CoreBluetooth says nothing.
        self.serving = 'off'
        self.advertised_name = None
        # CoreBluetooth refuses a notification when its queue is full and calls back when it is free again.
        self.ready = True
        self.stopped = False

    # The box asks.

    def advertise(self, name, manufacturer):
        self.wanted = (name, manufacturer)
        self.apply()

    def local_name(self):
        return self.wanted[0] if self.wanted else '-'

    def stop_advertising(self):
        self.wanted = None
        self.apply()

    def send(self, phone_id, data):
        central = self.centrals.get(phone_id)
        if central is None or not self.ready:
            return False
        value = NSData.dataWithBytes_length_(data, len(data))
        if not self.manager.updateValue_forCharacteristic_onSubscribedCentrals_(value, self.tx, [central]):
            self.ready = False
            return False
        return True

    def disconnect(self, phone_id):
        """CoreBluetooth can't drop one central: the service goes away for all of them and comes back."""
        if phone_id not in self.centrals:
            return
        self.teardown()
        self.apply()

    def run(self, tick, interval_s):
        loop = NSRunLoop.currentRunLoop()
        while not self.stopped:
            # The calls of CoreBluetooth arrive while the run loop runs, so the tick has them all by its turn.
            loop.runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(interval_s))
            tick()

    def stop(self):
        self.stopped = True
        self.wanted = None
        self.apply()

    # CoreBluetooth answers.

    def on_powered_on(self):
        self.powered_on = True
        self.apply()

    def on_subscribe(self, central):
        phone_id = str(central.identifier().UUIDString())
        if phone_id not in self.centrals:
            self.centrals[phone_id] = central
            self.on_event('connect', phone_id, phone_id[:8])
        self.on_event('subscribe', phone_id, int(central.maximumUpdateValueLength()))

    def on_unsubscribe(self, central):
        phone_id = str(central.identifier().UUIDString())
        if self.centrals.pop(phone_id, None) is not None:
            self.on_event('disconnect', phone_id)

    def on_write(self, central, data):
        phone_id = str(central.identifier().UUIDString())
        if phone_id not in self.centrals:
            self.centrals[phone_id] = central
            self.on_event('connect', phone_id, phone_id[:8])
        self.on_event('write', phone_id, data)

    def on_service_added(self, error):
        if self.serving != 'adding':
            return
        if error is not None:
            self.serving = 'off'
            return
        self.serving = 'serving'
        self.apply()

    def apply(self):
        """Brings the service and the advertisement to what the panel wants."""
        if not self.powered_on:
            return
        if self.wanted is None:
            self.teardown()
            return
        if self.serving == 'off':
            self.serving = 'adding'
            self.add_service()
        elif self.serving == 'serving' and self.advertised_name != self.wanted[0]:
            self.manager.stopAdvertising()
            self.advertised_name = self.wanted[0]
            self.manager.startAdvertising_({
                CBAdvertisementDataLocalNameKey: self.wanted[0],
                CBAdvertisementDataServiceUUIDsKey: [CBUUID.UUIDWithString_(sim.SERVICE_UUID)],
            })

    def teardown(self):
        """The box parks: the advertisement and the service go away, and the phones with them (BLE-14)."""
        if self.serving == 'off':
            return
        self.manager.stopAdvertising()
        self.manager.removeAllServices()
        self.serving = 'off'
        self.advertised_name = None
        for phone_id in list(self.centrals):
            del self.centrals[phone_id]
            self.on_event('disconnect', phone_id)

    def add_service(self):
        # BLE-3: TX notifies the lines, RX takes the commands. The OTA characteristic is not here: the abilities of
        # NGI don't offer an update, and both applications take it as optional.
        self.tx = CBMutableCharacteristic.alloc().initWithType_properties_value_permissions_(
            CBUUID.UUIDWithString_(sim.TX_UUID), CBCharacteristicPropertyNotify, None, CBAttributePermissionsReadable)
        self.rx = CBMutableCharacteristic.alloc().initWithType_properties_value_permissions_(
            CBUUID.UUIDWithString_(sim.RX_UUID),
            CBCharacteristicPropertyWrite | CBCharacteristicPropertyWriteWithoutResponse, None,
            CBAttributePermissionsWriteable)
        service = CBMutableService.alloc().initWithType_primary_(CBUUID.UUIDWithString_(sim.SERVICE_UUID), True)
        service.setCharacteristics_([self.tx, self.rx])
        self.manager.addService_(service)
