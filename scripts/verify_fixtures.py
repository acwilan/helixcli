#!/usr/bin/env python3
"""Verify parser behavior against checked-in preset payload fixtures."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELIXCLI = ROOT / ".build" / "debug" / "helixcli"
FIXTURE = ROOT / "docs" / "fixtures" / "current-preset-gospeltone.hex"


def run_json(*args: str) -> dict:
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


def main() -> int:
    if not HELIXCLI.exists():
        subprocess.run(["swift", "build"], cwd=ROOT, check=True)

    result = run_json("preset", "parse-fixture", str(FIXTURE))
    require(result.get("success") is True, f"fixture parse failed: {result}")

    data = result["data"]
    blocks = data["blocks"]
    by_slot = {block["slot"]: block for block in blocks}

    require(data["blockCount"] == 16, f"expected 16 blocks, got {data['blockCount']}")
    require(data["source"] == "currentPreset", f"unexpected source: {data.get('source')}")
    require(data["requestedPresetId"] is None, f"unexpected requested preset id: {data.get('requestedPresetId')}")

    amp = by_slot["A3"]
    require(amp["modelName"] == "US Double Nrm (mono)", f"unexpected A3 model: {amp['modelName']}")
    amp_params = amp["params"]["namedValues"]
    require(amp_params[0]["name"] == "Drive", f"unexpected A3 param 0: {amp_params[0]}")
    require(amp_params[0]["displayValue"] == "3.8", f"unexpected A3 Drive display: {amp_params[0]}")
    require(amp_params[1]["displayValue"] == "4.4", f"unexpected A3 Bass display: {amp_params[1]}")

    compressor = by_slot["A5"]
    require(compressor["modelName"] == "LA Studio Comp (mono)", f"unexpected A5 model: {compressor['modelName']}")
    compressor_params = compressor["params"]["namedValues"]
    require(compressor_params[0]["name"] == "Peak Reduction", f"unexpected A5 param 0: {compressor_params[0]}")
    require(compressor_params[3]["displayValue"] == "67%", f"unexpected A5 Mix display: {compressor_params[3]}")

    delay = by_slot["B7"]
    require(delay["modelName"] == "Vintage Digital Mono, Stereo Line 6 Original (mono)", f"unexpected B7 model: {delay['modelName']}")
    delay_params = delay["params"]["namedValues"]
    require(delay_params[4]["name"] == "Mix", f"unexpected B7 param 4: {delay_params[4]}")
    require(delay_params[4]["displayValue"] == "20%", f"unexpected B7 Mix display: {delay_params[4]}")
    require(delay_params[7]["name"] == "Trails", f"unexpected B7 param 7: {delay_params[7]}")
    require(delay_params[7]["displayValue"] == "On", f"unexpected B7 Trails display: {delay_params[7]}")

    print("fixture verification passed: current-preset-gospeltone.hex")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 - command-line verifier should print concise failures
        print(f"fixture verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
