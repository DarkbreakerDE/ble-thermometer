"""Synthetic CTS fixtures; runnable without BLE, Rust or Flutter."""
import sys
import unittest
from datetime import datetime, timezone, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analyse"))
from decode_ovy import encode_clock, decode_clock, choose_date_test_time


class ClockCodecTests(unittest.TestCase):
    def test_leap_day_weekday_fraction_and_reason(self):
        stamp = datetime(2024, 2, 29, 12, 34, 56, 500000)
        raw = encode_clock(stamp)
        self.assertEqual(raw.hex(), "e807021d0c2238048001")
        self.assertEqual(decode_clock(raw), (stamp.replace(microsecond=0), 4, 128, 1))

    def test_local_wall_time_is_preserved(self):
        stamp = datetime(2024, 3, 1, 1, 2, 3, 999999,
                         tzinfo=timezone(timedelta(hours=2)))
        self.assertEqual(encode_clock(stamp).hex(), "e807030101020305ff01")

    def test_default_date_differs_from_device(self):
        now = datetime(2024, 12, 31, 23, 30)
        target = choose_date_test_time(now, now)
        self.assertEqual(target, datetime(2025, 1, 1, 23, 30))
        self.assertEqual(choose_date_test_time(now, target), datetime(2025, 1, 2, 23, 30))

    def test_explicit_date_keeps_time_and_changes_calendar(self):
        now = datetime(2024, 3, 1, 12, 34, 56, 500000)
        target = choose_date_test_time(now, now, "2024-02-29")
        self.assertEqual(target, datetime(2024, 2, 29, 12, 34, 56, 500000))
        self.assertEqual(encode_clock(target).hex(), "e807021d0c2238048001")

    def test_identical_or_invalid_date_is_rejected_before_write(self):
        now = datetime(2024, 3, 1)
        for requested in ("2024-03-01", "2023-02-29", "1581-01-01", "invalid"):
            with self.assertRaises(ValueError):
                choose_date_test_time(now, now, requested)

    def test_reject_bad_length_and_calendar(self):
        for raw in (bytes(9), bytes(11), bytes.fromhex("e807021e000000010000")):
            with self.assertRaises(ValueError):
                decode_clock(raw)

    def test_reject_out_of_range_clock_year(self):
        with self.assertRaises(ValueError):
            encode_clock(datetime(1581, 1, 1))


if __name__ == "__main__":
    unittest.main()
