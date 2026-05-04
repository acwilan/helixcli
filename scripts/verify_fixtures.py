#!/usr/bin/env python3
"""Verify parser behavior against checked-in preset payload fixtures."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
HELIXCLI = ROOT / ".build" / "debug" / "helixcli"
FIXTURES = ROOT / "docs" / "fixtures"


def run_json(*args: str) -> dict[str, Any]:
    proc = subprocess.run(
        [str(HELIXCLI), *args],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return json.loads(proc.stdout)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def parse_fixture(name: str) -> dict[str, Any]:
    result = run_json("preset", "parse-fixture", str(FIXTURES / name))
    require(result.get("success") is True, f"fixture parse failed for {name}: {result}")
    data = result["data"]
    require(data["blockCount"] == 16, f"{name}: expected 16 blocks, got {data['blockCount']}")
    require(data["source"] == "currentPreset", f"{name}: unexpected source: {data.get('source')}")
    require(data["nameSource"] == "preset-payload-parser", f"{name}: unexpected name source: {data.get('nameSource')}")
    require(data["requestedPresetId"] is None, f"{name}: unexpected requested preset id: {data.get('requestedPresetId')}")
    return data


def by_slot(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {block["slot"]: block for block in data["blocks"]}


def named_values(block: dict[str, Any]) -> list[dict[str, Any]]:
    return block["params"].get("namedValues", [])


def verify_gospeltone() -> None:
    data = parse_fixture("current-preset-gospeltone.hex")
    slots = by_slot(data)

    amp = slots["A3"]
    require(amp["modelName"] == "US Double Nrm (mono)", f"unexpected A3 model: {amp['modelName']}")
    amp_params = named_values(amp)
    require(amp_params[0]["name"] == "Drive", f"unexpected A3 param 0: {amp_params[0]}")
    require(amp_params[0]["displayValue"] == "3.8", f"unexpected A3 Drive display: {amp_params[0]}")
    require(amp_params[1]["displayValue"] == "4.4", f"unexpected A3 Bass display: {amp_params[1]}")

    compressor = slots["A5"]
    require(compressor["modelName"] == "LA Studio Comp (mono)", f"unexpected A5 model: {compressor['modelName']}")
    compressor_params = named_values(compressor)
    require(compressor_params[0]["name"] == "Peak Reduction", f"unexpected A5 param 0: {compressor_params[0]}")
    require(compressor_params[3]["displayValue"] == "67%", f"unexpected A5 Mix display: {compressor_params[3]}")

    delay = slots["B7"]
    require(delay["modelName"] == "Vintage Digital Mono, Stereo Line 6 Original (mono)", f"unexpected B7 model: {delay['modelName']}")
    delay_params = named_values(delay)
    require(delay_params[4]["name"] == "Mix", f"unexpected B7 param 4: {delay_params[4]}")
    require(delay_params[4]["displayValue"] == "20%", f"unexpected B7 Mix display: {delay_params[4]}")
    require(delay_params[7]["name"] == "Trails", f"unexpected B7 param 7: {delay_params[7]}")
    require(delay_params[7]["displayValue"] == "On", f"unexpected B7 Trails display: {delay_params[7]}")


def verify_full_dist() -> None:
    data = parse_fixture("preset-001-full-dist.hex")
    require(data["name"] == "Minotaur", f"unexpected parsed preset name: {data['name']}")
    slots = by_slot(data)

    drive = slots["A2"]
    require(drive["type"] == "Distortion", f"unexpected A2 type: {drive['type']}")
    require(drive["modelName"] == "Minotaur (mono)", f"unexpected A2 model: {drive['modelName']}")
    drive_params = named_values(drive)
    require(drive_params[0]["name"] == "Drive", f"unexpected Minotaur param 0: {drive_params[0]}")
    require(drive_params[0]["displayValue"] == "6.1", f"unexpected Minotaur drive display: {drive_params[0]}")

    amp_cab = slots["A4"]
    require(amp_cab["type"] == "Amp + Cab", f"unexpected A4 type: {amp_cab['type']}")
    require("Interstate Zed" in amp_cab["modelName"], f"unexpected A4 model: {amp_cab['modelName']}")

    reverb = slots["A6"]
    require(reverb["type"] == "Reverb", f"unexpected A6 type: {reverb['type']}")
    require(reverb["modelName"] == "Searchlights (stereo)", f"unexpected A6 model: {reverb['modelName']}")


def verify_compulsive_drive() -> None:
    data = parse_fixture("preset-002-preset-002.hex")
    require(data["name"] == "Compulsive Drive", f"unexpected parsed preset name: {data['name']}")
    slots = by_slot(data)

    drive = slots["A2"]
    require(drive["modelName"] == "Compulsive Drive (mono)", f"unexpected A2 model: {drive['modelName']}")
    drive_params = named_values(drive)
    require(drive_params[0]["displayValue"] == "8.8", f"unexpected Compulsive Drive display: {drive_params[0]}")

    reverb = slots["A4"]
    require(reverb["modelName"] == "Searchlights (stereo)", f"unexpected A4 model: {reverb['modelName']}")


def verify_ping_pong() -> None:
    data = parse_fixture("preset-003-preset-003.hex")
    require(data["name"] == "Ping Pong", f"unexpected parsed preset name: {data['name']}")
    slots = by_slot(data)

    delay = slots["A4"]
    require(delay["modelName"] == "Ping Pong  (stereo)", f"unexpected A4 model: {delay['modelName']}")
    delay_params = named_values(delay)
    require(delay_params[0]["name"] == "Time", f"unexpected Ping Pong param 0: {delay_params[0]}")
    require(delay_params[1]["displayValue"] == "4.0", f"unexpected Ping Pong feedback display: {delay_params[1]}")

    reverb = slots["A5"]
    require(reverb["modelName"] == "Searchlights (stereo)", f"unexpected A5 model: {reverb['modelName']}")
    reverb_params = named_values(reverb)
    require(reverb_params[0]["name"] == "Decay", f"unexpected Searchlights param 0: {reverb_params[0]}")
    require(reverb_params[0]["displayValue"] == "3.7", f"unexpected Searchlights decay display: {reverb_params[0]}")


def main() -> int:
    if not HELIXCLI.exists():
        subprocess.run(["swift", "build"], cwd=ROOT, check=True)

    verify_gospeltone()
    verify_full_dist()
    verify_compulsive_drive()
    verify_ping_pong()

    print("fixture verification passed: 4 preset payload fixtures")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 - command-line verifier should print concise failures
        print(f"fixture verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
