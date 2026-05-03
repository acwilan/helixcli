#!/usr/bin/env python3
"""Compare helixcli command latency with helix_usb interactive latency.

This script uses safe/read-mostly operations by default:
- helixcli preset current
- helixcli preset list
- helixcli preset get-current
- helix_usb interactive commands 0, 2, 1 respectively

It intentionally does not benchmark preset switching unless extended manually.
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

try:
    import pexpect
except ImportError:  # pragma: no cover
    pexpect = None


ROOT = Path(__file__).resolve().parents[1]
HELIXCLI = ROOT / ".build" / "release" / "helixcli"
HELIX_USB = Path("/Users/andres/dev/helix_usb")
HELIX_USB_PYTHON = HELIX_USB / ".venv" / "bin" / "python"
HELIX_USB_SCRIPT = HELIX_USB / "helix_usb.py"


@dataclass
class Sample:
    command: str
    seconds: float
    ok: bool
    note: str = ""


def summarize(samples: list[Sample]) -> dict:
    values = [s.seconds for s in samples if s.ok]
    if not values:
        return {"count": 0, "ok": 0, "error": "no successful samples"}
    return {
        "count": len(samples),
        "ok": len(values),
        "min_ms": round(min(values) * 1000, 1),
        "median_ms": round(statistics.median(values) * 1000, 1),
        "mean_ms": round(statistics.mean(values) * 1000, 1),
        "max_ms": round(max(values) * 1000, 1),
    }


def run_helixcli(command: list[str], runs: int) -> list[Sample]:
    samples: list[Sample] = []
    for _ in range(runs):
        start = time.perf_counter()
        note = ""
        ok = False
        try:
            proc = subprocess.run(
                [str(HELIXCLI), *command],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=90,
            )
            if proc.returncode == 0:
                try:
                    payload = json.loads(proc.stdout)
                    ok = bool(payload.get("success"))
                    if not ok:
                        note = json.dumps(payload.get("error"), sort_keys=True)
                except Exception as exc:
                    note = f"invalid json: {exc}"
            else:
                note = proc.stderr.strip() or f"exit {proc.returncode}"
        except subprocess.TimeoutExpired:
            note = "timeout"
        elapsed = time.perf_counter() - start
        samples.append(Sample("helixcli " + " ".join(command), elapsed, ok, note))
        time.sleep(0.25)
    return samples


def start_helix_usb(timeout: int):
    if pexpect is None:
        raise RuntimeError("pexpect is not installed")
    child = pexpect.spawn(
        str(HELIX_USB_PYTHON),
        [str(HELIX_USB_SCRIPT)],
        cwd=str(HELIX_USB),
        encoding="utf-8",
        timeout=timeout,
    )
    child.logfile_read = sys.stderr if False else None
    child.expect("command: ")
    # helix_usb starts its USB monitor asynchronously and prints the prompt before
    # the initial connect/reconfigure/preset-name pipeline has necessarily settled.
    # Give it time so interactive command timing does not include startup churn.
    time.sleep(8.0)
    return child


def run_helix_usb(child, command: str, expect_pattern: str, runs: int, timeout: int) -> list[Sample]:
    samples: list[Sample] = []
    for _ in range(runs):
        start = time.perf_counter()
        child.sendline(command)
        note = ""
        ok = True
        try:
            child.expect(expect_pattern, timeout=timeout)
            # Then wait for prompt so we measure the usable command completion point.
            child.expect("command: ", timeout=timeout)
        except Exception as exc:
            ok = False
            note = repr(exc)
            try:
                child.expect("command: ", timeout=3)
            except Exception:
                pass
        elapsed = time.perf_counter() - start
        samples.append(Sample(f"helix_usb {command}", elapsed, ok, note))
        time.sleep(0.25)
    return samples


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--skip-helix-usb", action="store_true")
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()

    results: dict[str, dict] = {}
    raw: dict[str, list[dict]] = {}

    helixcli_cases = {
        "helixcli_current": ["preset", "current", "--timeout", "500"],
        "helixcli_preset_list": ["preset", "list", "--timeout", "250", "--max-packets", "120"],
        "helixcli_preset_get_current": ["preset", "get-current", "--timeout", "500", "--max-packets", "120"],
    }

    for name, cmd in helixcli_cases.items():
        samples = run_helixcli(cmd, args.runs)
        results[name] = summarize(samples)
        raw[name] = [s.__dict__ for s in samples]

    if not args.skip_helix_usb:
        child = None
        try:
            child = start_helix_usb(args.timeout)
            usb_cases = {
                "helix_usb_current_name": ("0", r"Preset Name:"),
                "helix_usb_preset_names": ("2", r"Received preset names: 125"),
                "helix_usb_preset_data": ("1", r"Switching mode from request_preset to standard|Slot"),
            }
            for name, (cmd, pattern) in usb_cases.items():
                samples = run_helix_usb(child, cmd, pattern, args.runs, args.timeout)
                results[name] = summarize(samples)
                raw[name] = [s.__dict__ for s in samples]
        except Exception as exc:
            results["helix_usb_error"] = {"error": repr(exc)}
        finally:
            if child is not None:
                try:
                    child.sendline("exit")
                    child.expect(pexpect.EOF, timeout=5)
                except Exception:
                    child.close(force=True)

    output = {"runs": args.runs, "summary": results, "samples": raw}
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
