# OT35 clock hardware test results

Sanitized summary of a user-operated test on the `tests` branch. Device address,
raw captures, exact personal timestamps and measurement histories are excluded.

## Initial clock synchronization result

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

The initial clock test kept an already correct date. The later calendar-change
test below demonstrated changing the day and weekday, then restoring them.
Separate changes to the month and year have not yet been tested on hardware.

No visual confirmation of the two LED flashes was supplied for this test.
Persistence after power-off, timestamps of subsequent measurements, long-term
accuracy and Android/iOS clock synchronization remain unverified.

## Tester update after this run

The successful hardware run used the Rust-backed tester. The tester now encodes
Current Time in Python so that Rust and Flutter are unnecessary. Synthetic codec
checks cover leap-day encoding, weekday, fraction, adjustment reason, local wall
time and invalid input. The Python replacement was subsequently used successfully
for the calendar-change and restoration test below.

Run those checks with `python3 -m unittest discover -s tests`.
To check persistence, disconnect, power-cycle, reconnect and use `read 2a2b`
before another clock write. `clock-test` always writes the laptop's current local
date and time; `date-test` tests a deliberately different date and restores it.

## Verified calendar change and restoration (Python-only tester)

- `date-test` read the initial device date, then selected the following day.
- Current Time and FFF3=01 writes were accepted for the test date.
- The first readback matched the complete payload; a second read approximately
  two seconds later retained the changed day and showed advancing seconds.
- The weekday changed from Sunday (07) to Monday (01) and was valid in both reads.
- Test-date deviations were approximately -0.27 and -1.26 seconds, within the
  two-second tolerance. `date_write_verified` was reported.
- The tester then wrote current laptop date/time and sent FFF3=01 again.
  Both writes were accepted. Two readbacks confirmed the original calendar date
  and Sunday weekday were restored, with the clock continuing to advance.
- Restoration deviations were approximately -0.27 and +0.40 seconds, within
  tolerance. `clock_restore_verified` and `date_test_passed` were reported.
- Fraction and adjustment reason matched each write in the immediate readback
  and were 00 in the later reads, consistent with the first clock test.

This run verifies a day/weekday change and restoration through the standalone
Python tester. It does not establish restart persistence, month/year changes,
measurement timestamp behavior or visual LED confirmation. The tests branch
contains Python investigation tools and documentation; Flutter/Rust library
sources live on main.
