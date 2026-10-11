#!/usr/bin/env python3
"""Decode captured Ovy ATT TSV; no Bluetooth writes or dependencies."""
import argparse
import csv
from datetime import datetime
from decimal import Decimal
from pathlib import Path



def encode_clock(stamp):
    """Observed OT35 Current Time payload, using local civil time (no UTC offset)."""
    if not 1582 <= stamp.year <= 9999:
        raise ValueError("Current Time year must be between 1582 and 9999")
    fraction = stamp.microsecond * 256 // 1_000_000
    return stamp.year.to_bytes(2, "little") + bytes((
        stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second,
        stamp.isoweekday(), fraction, 1))


def decode_clock(raw):
    """Decode date/time, weekday, fraction and adjustment reason from CTS."""
    if len(raw) != 10:
        raise ValueError("Current Time must contain exactly ten bytes")
    stamp = datetime(int.from_bytes(raw[:2], "little"), *raw[2:7])
    return stamp, raw[7], raw[8], raw[9]


def decode_measurement(raw):
    b = bytes.fromhex(raw)
    if len(b) != 13 or b[0] not in (6, 7):
        raise ValueError(f"Unsupported measurement: {raw}")
    mantissa = int.from_bytes(b[1:4], "little", signed=True)
    if mantissa in (0x7ffffe, 0x7fffff, -0x800000, -0x7fffff, -0x7ffffe):
        raise ValueError("Special IEEE 11073 FLOAT value")
    exponent = int.from_bytes(b[4:5], "little", signed=True)
    value = Decimal(mantissa) * Decimal(10) ** exponent
    stamp = datetime(int.from_bytes(b[5:7], "little"), *b[7:12])
    return stamp.isoformat(sep=" "), format(value, "f"), "F" if b[0] & 1 else "C", b[12]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tsv", nargs="?", type=Path, default=Path(__file__).with_name("att.tsv"))
    parser.add_argument("--out", type=Path, default=Path(__file__).parent)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    measurements, sessions, seen = [], [], set()
    session = None
    for row in csv.DictReader(args.tsv.open(), delimiter="\t"):
        handle, op, raw = row["btatt.handle"], row["btatt.opcode"], row["btatt.value"]
        connection = row["bthci_acl.chandle"]
        if session is None or session["connection"] != connection:
            session = dict(connection=connection, first_frame=row["frame.number"],
                           snoop_time=row["frame.time"], battery_percent="", settings_hex="",
                           unit="", vibration="", sound="", measurements=0, reported_count="")
            sessions.append(session)
        if handle == "0x0029" and op in ("0x0b", "0x1b") and raw:
            session["battery_percent"] = int(raw, 16)
        elif handle == "0x0039" and op == "0x12":
            b = bytes.fromhex(raw)
            if len(b) != 2:
                raise ValueError(f"Unsupported settings: {raw}")
            session.update(settings_hex=raw, unit="F" if b[0] == 1 else "C" if b[0] == 0 else "unknown",
                           vibration=bool(b[1] & 1), sound=bool(b[1] & 2))
        elif handle == "0x0031" and op == "0x1d" and raw:
            stamp, value, unit, location = decode_measurement(raw)
            session["measurements"] += 1
            if raw not in seen:
                seen.add(raw)
                measurements.append(dict(first_frame=row["frame.number"], snoop_time=row["frame.time"],
                                         measurement_time=stamp, value=value, unit=unit,
                                         temperature_type=location, raw_hex=raw))
        elif handle == "0x0034" and op == "0x1d" and raw:
            session["reported_count"] = int(raw, 16)
    for name, rows in (("messungen-dekodiert.csv", measurements), ("sitzungen.csv", sessions)):
        if rows:
            with (args.out / name).open("w", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=list(rows[0]))
                writer.writeheader()
                writer.writerows(rows)
    print(f"{len(measurements)} distinct payloads, {len(sessions)} connection groups")


if __name__ == "__main__":
    main()
