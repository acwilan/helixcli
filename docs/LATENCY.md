# helixcli Latency Notes

Last attempted: 2026-05-02.

## Goal

Compare command latency between native Swift `helixcli` and Python `helix_usb` for equivalent HX Stomp operations.

## Benchmark Script

A repeatable benchmark helper lives at:

```bash
scripts/benchmark_latency.py
```

Recommended invocation:

```bash
swift build -c release
/Users/andres/dev/helix_usb/.venv/bin/python scripts/benchmark_latency.py --runs 3
```

The script currently benchmarks:

| Operation | helixcli | helix_usb |
|---|---|---|
| Current preset name | `helixcli preset current --timeout 500` | interactive command `0` |
| Preset names/list | `helixcli preset list --timeout 250 --max-packets 120` | interactive command `2` |
| Current preset data | `helixcli preset get-current --skip-name --timeout 500 --max-packets 120` | interactive command `1` |

## Preliminary helixcli Numbers

Using the release binary, successful non-outlier calls were roughly:

| Command | Typical latency observed |
|---|---:|
| `preset current` | ~0.6-0.8s |
| `preset get-current --skip-name` | ~0.85-1.0s |
| `preset list` | sometimes ~0.5s, but often ~31s |

Important: these are preliminary and noisy. Repeated independent process invocations sometimes hit long waits:

- `preset current`: one observed outlier around 63s
- `preset list`: observed around 31s on multiple runs
- `preset get-current`: one observed `NOT_CONNECTED` after around 63s, then subsequent calls worked again

Plain `preset get-current` now also performs a separate current-name request, so it is expected to be slower than the original payload-only measurement. Use `--skip-name` for latency comparisons with the older data path.

This suggests the current per-command connect/handshake lifecycle is not consistently settling cleanly every run. Median/typical command latency is promising, but tail latency needs work.

## Preliminary helix_usb Automation Result

`helix_usb` did not produce a clean apples-to-apples automated benchmark yet.

Setup completed:

```bash
cd /Users/andres/dev/helix_usb
python3 -m venv .venv
.venv/bin/pip install pyusb pexpect xlsxwriter
```

Observed issue when driven via `pexpect`:

- command `0` timed out waiting for `Preset Name:`
- command `2` timed out waiting for `Received preset names: 125`
- logs showed repeated `No x1x10 response!` / `No x2x10 response!`
- command `1` appeared to return quickly, but the result is not trustworthy because the session was already unhealthy

So the current script is useful scaffolding, but we should not treat the helix_usb numbers as valid until the interactive Python session starts cleanly and reaches a stable standard mode.

## Interpretation So Far

Current `helixcli` architecture is one-shot per command:

```text
process start → USB open/claim → drain → handshake → request → parse → exit
```

`helix_usb` is long-running:

```text
process start → USB monitor/reader threads → persistent mode → interactive command
```

That means there are two comparisons worth measuring separately:

1. **Cold command latency** — one-shot process cost included. This is what `helixcli` currently optimizes for.
2. **Warm session latency** — persistent connection already open. `helix_usb` should do better here once automated cleanly.

For OpenClaw use, cold one-shot latency around 0.6-1.0s is acceptable for read commands, but 30-60s tail latency is not. The main optimization target is reliability/tail latency, not just average speed.

## Next Benchmark Work

1. Make the benchmark script wait for a reliable helix_usb startup marker before sending commands.
2. Add better command-specific success detection for helix_usb command `1`.
3. Capture stdout/stderr logs to files for each failed run.
4. Run each case at least 10 times.
5. Separate cold and warm helixcli cases:
   - current one-shot binary invocation
   - future daemon/session mode, if added
6. Investigate why `helixcli preset list` often takes ~31s despite sometimes completing in ~0.5s.
7. Add optional preset-switch latency benchmark only when explicitly desired, because it changes the live device state.

## Optimization Ideas for helixcli

- Add a persistent `helixcli daemon` or `helixcli session` mode for warm command latency.
- Reuse a single protocol session for multiple reads.
- Improve handshake/drain end conditions to avoid 30-60s stalls.
- Add explicit timeout budgets per handshake phase and fail fast with actionable errors.
- Prefer USB MIDI for preset switching, which already has a simpler path.
