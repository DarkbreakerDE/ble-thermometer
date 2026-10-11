#!/usr/bin/env python3
"""Interactive BlueZ tester. Run on the laptop host, not in a sandbox.

Requires python3-dbus and python3-gi. Pair using bluetoothctl first.
No automatic setting/time writes, completion acknowledgements or reconnects.
"""
import argparse
import json
import shlex
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

try:
    import dbus
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib
except ImportError:
    sys.exit("Benötigt python3-dbus und python3-gi im Python des Laptops.")

from decode_ovy import decode_measurement

DEV = "org.bluez.Device1"
CHAR = "org.bluez.GattCharacteristic1"
PROP = "org.freedesktop.DBus.Properties"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", required=True, help="Bluetooth-Adresse des eigenen Thermometers")
    parser.add_argument("--log", type=Path, default=Path(__file__).with_name("live-ovy.jsonl"))
    args = parser.parse_args()
    started = time.monotonic()
    log_file = args.log.open("a", buffering=1)

    def log(event, **data):
        entry = dict(time=datetime.now().astimezone().isoformat(),
                     elapsed=round(time.monotonic() - started, 3), event=event, **data)
        line = json.dumps(entry, ensure_ascii=False)
        print(line, flush=True)
        log_file.write(line + "\n")

    DBusGMainLoop(set_as_default=True)
    try:
        bus = dbus.SystemBus()
        manager = dbus.Interface(bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager")
        objects = manager.GetManagedObjects()
    except dbus.DBusException as e:
        log("error", message=str(e))
        sys.exit("Kein Zugriff auf BlueZ: bitte im normalen Laptop-Terminal starten.")
    devices = [str(p) for p, v in objects.items()
               if DEV in v and str(v[DEV].get("Address", "")).upper() == args.address.upper()]
    if len(devices) != 1:
        sys.exit("Gerät fehlt oder ist auf mehreren Adaptern vorhanden. Erst bluetoothctl scan/pair verwenden.")
    path = devices[0]
    device = dbus.Interface(bus.get_object("org.bluez", path), DEV)
    props = dbus.Interface(bus.get_object("org.bluez", path), PROP)
    chars = {}
    loop = GLib.MainLoop()

    def snapshot():
        objects = manager.GetManagedObjects()
        chars.clear()
        for p, interfaces in objects.items():
            if str(p).startswith(path + "/") and CHAR in interfaces:
                c = interfaces[CHAR]
                uuid = str(c["UUID"]).lower()
                chars[uuid] = (str(p), list(map(str, c["Flags"])))
        return objects

    def characteristic(short):
        uuid = f"0000{short}-0000-1000-8000-00805f9b34fb"
        if uuid not in chars:
            raise ValueError("Characteristic fehlt; Services noch nicht aufgelöst?")
        p, flags = chars[uuid]
        return dbus.Interface(bus.get_object("org.bluez", p), CHAR), flags

    def changed(interface, changes, invalidated, object_path=None):
        p = str(object_path)
        if p != path and not p.startswith(path + "/"):
            return
        if interface == DEV:
            for key in ("Connected", "ServicesResolved", "Paired", "Bonded"):
                if key in changes:
                    log("device", property=key, value=bool(changes[key]))
        elif interface == CHAR and "Value" in changes:
            raw = bytes(changes["Value"]).hex()
            uuid = next((u for u, (cp, _) in chars.items() if cp == p), "unknown")
            data = dict(uuid=uuid, raw=raw)
            if uuid.startswith("0000fff1"):
                try:
                    stamp, value, unit, location = decode_measurement(raw)
                    data.update(measurement_time=stamp, value=value, unit=unit)
                except ValueError as e:
                    data["decode_error"] = str(e)
            log("value", **data)

    bus.add_signal_receiver(changed, signal_name="PropertiesChanged", dbus_interface=PROP,
                            bus_name="org.bluez", path_keyword="object_path")

    def run_command(line):
        try:
            parts = shlex.split(line)
            if not parts:
                return False
            command, *rest = parts
            log("command", text=line)
            if command == "status":
                p = props.GetAll(DEV)
                log("status", connected=bool(p.get("Connected")), paired=bool(p.get("Paired")),
                    resolved=bool(p.get("ServicesResolved")))
            elif command == "connect":
                if not props.Get(DEV, "Connected"):
                    device.Connect(timeout=30)
            elif command == "read" and len(rest) == 1:
                c, flags = characteristic(rest[0].lower())
                if "read" not in flags:
                    raise ValueError("Diese Characteristic bietet kein Read an.")
                log("read", uuid=rest[0], raw=bytes(c.ReadValue(dbus.Dictionary({}, signature="sv"))).hex())
            elif command == "settings" and len(rest) == 1:
                if rest[0] not in {"0000", "0001", "0002", "0003", "0004", "0100", "0103"}:
                    raise ValueError("Zulässig: 0000, 0001, 0002, 0003, 0004, 0100, 0103")
                c, _ = characteristic("fff4")
                c.WriteValue(dbus.Array(bytes.fromhex(rest[0]), signature="y"),
                             dbus.Dictionary({"type": "request"}, signature="sv"))
                log("write_ok", uuid="fff4", raw=rest[0])
            elif command == "fetch":
                for short in ("fff1", "fff2"):
                    c, _ = characteristic(short)
                    cp = chars[f"0000{short}-0000-1000-8000-00805f9b34fb"][0]
                    state = dbus.Interface(bus.get_object("org.bluez", cp), PROP)
                    if state.Get(CHAR, "Notifying"):
                        c.StopNotify()
                for short in ("fff1", "fff2"):
                    characteristic(short)[0].StartNotify()
                log("subscriptions_started")
            elif command == "ack" or command == "control" and len(rest) == 1:
                raw = "01" if command == "ack" else rest[0].lower()
                if raw not in {"00", "01", "02"}:
                    raise ValueError("FFF3-Testwerte: control 00, control 01 oder control 02")
                characteristic("fff3")[0].WriteValue(dbus.Array(bytes.fromhex(raw), signature="y"),
                                      dbus.Dictionary({"type": "request"}, signature="sv"))
                log("write_ok", uuid="fff3", raw=raw)
            elif command == "mark":
                log("marker", text=" ".join(rest))
            elif command == "quit":
                if props.Get(DEV, "Connected"):
                    device.Disconnect()
                loop.quit()
            else:
                raise ValueError("Befehle: status, read 2a19, read fff4, settings HEX, fetch, ack, control 00/01/02, connect, mark TEXT, quit")
        except (dbus.DBusException, ValueError) as e:
            log("error", message=str(e))
        return False

    def terminal():
        for line in sys.stdin:
            GLib.idle_add(run_command, line.strip())

    def discovery():
        try:
            snapshot()
            if props.Get(DEV, "ServicesResolved"):
                log("ready", characteristics={u: flags for u, (_, flags) in chars.items()})
                print("Befehle: status | read 2a19 | read fff4 | fetch | ack | control 00/01/02 | settings 0003 | mark TEXT | quit", flush=True)
                return False
        except dbus.DBusException as e:
            log("error", message=str(e))
        return True

    log("start", address=args.address, log=str(args.log))
    if not props.Get(DEV, "Paired"):
        sys.exit("Bitte zuerst im Laptop-Terminal mit bluetoothctl pair koppeln.")
    if not props.Get(DEV, "Connected"):
        device.Connect(timeout=30)
    threading.Thread(target=terminal, daemon=True).start()
    GLib.timeout_add_seconds(1, discovery)
    try:
        loop.run()
    except KeyboardInterrupt:
        run_command("quit")
    finally:
        log_file.close()


if __name__ == "__main__":
    main()
