# OT35 clock hardware test results

Sanitized summary of a user-operated test on the `tests` branch. Device address,
raw captures, exact personal timestamps and measurement histories are excluded.

## Observed result

- BlueZ connected to an already paired OT35 and resolved its GATT services.
- Current Time (`1805/2A2B`) offered read, write and notify.
- The Rust-generated ten-byte Current Time write was accepted with a GATT write
  response. The subsequent FFF3=01 blink command was also accepted.
- The first readback matched all ten bytes written, including date, weekday,
  fractional seconds and manual adjustment reason (01).
- A second read approximately two seconds later showed advancing whole seconds.
  Fractional seconds and adjustment reason were then both 00. This shows they
  are not simply retained in subsequent readbacks; their internal use is unknown.
- Measured differences against laptop time were approximately -0.27 and -0.79
  seconds. Both passed the tester's two-second tolerance; the weekday was correct.
- `clock_test_passed` was reported. Later D-Bus Value events were queued during
  the synchronous test; their log order does not establish device notification
  timing or prove an active notification subscription.

## What remains unverified

The calendar date was already correct before the write and remained the same
in both readbacks. The payload writes year, month and day as well as time, but
changing an incorrect date has not yet been demonstrated on hardware.

No visual confirmation of the two LED flashes was supplied for this test.
Persistence after power-off, timestamps of subsequent measurements, long-term
accuracy and Android/iOS clock synchronization remain unverified.

## Tester update after this run

The successful hardware run used the Rust-backed tester. The tester now encodes
Current Time in Python so that Rust and Flutter are unnecessary. Synthetic codec
checks cover leap-day encoding, weekday, fraction, adjustment reason, local wall
time and invalid input. The Python replacement has not yet been run on hardware.

Run those checks with `python3 -m unittest discover -s tests`.
To check persistence, disconnect, power-cycle, reconnect and use `read 2a2b`
before another clock write. To verify a calendar change, separately arrange a
known incorrect device date and compare before/after readbacks; `clock-test`
always writes the laptop's current local date and time.

## Next prepared test: calendar change

`date-test [YYYY-MM-DD]` is available in the Python tester. It requires a
date different from the device readback and verifies the write with two reads.
Its `finally` block attempts to restore and verify current laptop time even
if the test write or its verification fails. No calendar-change hardware
result is recorded yet. The tests branch contains Python investigation tools
and documentation; Flutter/Rust library sources live on main.
