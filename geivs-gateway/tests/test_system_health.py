"""Tests for the system_health status roll-up (pure logic, no I/O)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "services"))
import system_health as h  # noqa: E402


def sysinfo(**kw):
    d = {
        "cpu_percent": 5, "cores": 16, "load": [0.1, 0.2, 0.3],
        "ram_used_gb": 10, "ram_total_gb": 33, "ram_percent": 30,
        "disk_used_gb": 300, "disk_free_gb": 600, "disk_percent": 34,
    }
    d.update(kw)
    return d


def disk(**kw):
    d = {"device": "sda", "health": "PASSED", "reallocated": 0,
         "uncorrectable": 0, "crc_errors": 0, "life_remaining_pct": 97}
    d.update(kw)
    return d


class TestRollUp(unittest.TestCase):
    def test_all_healthy_is_ok(self):
        level, alerts = h.roll_up(sysinfo(), {"cpu_c": 50, "gpu_c": 45}, [disk()])
        self.assertEqual(level, "ok")
        self.assertEqual(alerts, [])

    def test_disk_full_is_critical(self):
        level, alerts = h.roll_up(sysinfo(disk_percent=97), {"cpu_c": 50, "gpu_c": 45}, [])
        self.assertEqual(level, "critical")
        self.assertTrue(any("disk" in a for a in alerts))

    def test_disk_warn_threshold(self):
        level, _ = h.roll_up(sysinfo(disk_percent=88), {"cpu_c": 50, "gpu_c": 45}, [])
        self.assertEqual(level, "warn")

    def test_smart_failed_is_critical(self):
        level, _ = h.roll_up(sysinfo(), {"cpu_c": 50, "gpu_c": 45}, [disk(health="FAILED")])
        self.assertEqual(level, "critical")

    def test_reallocated_sectors_critical(self):
        level, _ = h.roll_up(sysinfo(), {"cpu_c": 50, "gpu_c": 45}, [disk(reallocated=3)])
        self.assertEqual(level, "critical")

    def test_cpu_temp_warn(self):
        level, _ = h.roll_up(sysinfo(), {"cpu_c": 82, "gpu_c": 45}, [])
        self.assertEqual(level, "warn")

    def test_cpu_temp_critical(self):
        level, _ = h.roll_up(sysinfo(), {"cpu_c": 92, "gpu_c": 45}, [])
        self.assertEqual(level, "critical")

    def test_ram_warn(self):
        level, _ = h.roll_up(sysinfo(ram_percent=95), {"cpu_c": 50, "gpu_c": 45}, [])
        self.assertEqual(level, "warn")

    def test_low_ssd_life_warns(self):
        level, alerts = h.roll_up(sysinfo(), {"cpu_c": 50, "gpu_c": 45}, [disk(life_remaining_pct=5)])
        self.assertEqual(level, "warn")
        self.assertTrue(any("life" in a for a in alerts))

    def test_missing_temps_dont_crash(self):
        level, _ = h.roll_up(sysinfo(), {"cpu_c": None, "gpu_c": None}, [disk()])
        self.assertEqual(level, "ok")


if __name__ == "__main__":
    unittest.main()
