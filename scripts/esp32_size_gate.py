#!/usr/bin/env python3
"""Gate for the ESP32 firmware size (ticket 08).

Reads the `idf.py size --format json` report and fails when the firmware
outgrows the budgets below. Budgets have ~2x headroom over the 2026-11
baseline (flash ~350KB, DRAM ~19%) so normal growth passes and only
real bloat (e.g. lost --gc-sections, whole-stdlib emission) fails.

Usage: esp32_size_gate.py <size.json>
"""

import json
import sys

FLASH_BUDGET = 800_000  # flash_code + flash_rodata, bytes (factory: 1MB)
DRAM_RATIO_BUDGET = 0.35


def main(path: str) -> int:
    with open(path) as f:
        report = json.load(f)
    flash = report["flash_code"] + report["flash_rodata"]
    dram_ratio = report["used_diram_ratio"]
    print(f"flash code+rodata: {flash} bytes (budget {FLASH_BUDGET})")
    print(f"DRAM used: {report['used_diram']}/{report['diram_total']} bytes "
          f"({dram_ratio:.1%}, budget {DRAM_RATIO_BUDGET:.0%})")
    failed = False
    if flash > FLASH_BUDGET:
        print(f"FAIL: flash {flash} exceeds budget {FLASH_BUDGET}")
        failed = True
    if dram_ratio > DRAM_RATIO_BUDGET:
        print(f"FAIL: DRAM ratio {dram_ratio:.1%} exceeds budget "
              f"{DRAM_RATIO_BUDGET:.0%}")
        failed = True
    print("esp32 size gate: " + ("FAIL" if failed else "PASS"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
