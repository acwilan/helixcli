# helixcli Status

Last verified: 2026-05-02 against Andres's Line 6 HX Stomp (`0x0E41:0x4246`, serial `3428080`).

## Summary

`helixcli` is a native Swift/macOS CLI for controlling a Line 6 HX Stomp over USB. The core read/control path is now working against real hardware:

- The CLI can detect the HX Stomp.
- The proprietary USB protocol interface can be opened and claimed.
- The connect handshake works.
- Preset names can be read from the device.
- The current preset name can be read.
- Preset switching works through the HX Stomp USB MIDI interface.
- Raw current-preset data can be captured.
- Initial block/parameter parsing works with human-readable model/category mapping for known model IDs, plus first-pass parameter labels for common/current-preset models. Parameter units/display scaling are still experimental.

The remaining work is mostly parser quality and advanced write operations.

## Confirmed Hardware / USB Topology

Observed device:

| Field | Value |
|---|---|
| Device | HX Stomp |
| Vendor ID | `0x0E41` / Line 6 |
| Product ID | `0x4246` |
| Serial | `3428080` |

Confirmed endpoints:

| Interface | Purpose | Endpoints | Status |
|---|---|---|---|
| 0 | Proprietary Helix protocol | bulk OUT `0x01`, bulk IN `0x81` | Working |
| 4 | USB MIDI | bulk OUT `0x02`, bulk IN `0x82` | Preset switching works |

Important caution: avoid `libusb_reset_device` as a routine operation. In live testing it caused the Stomp to stop responding until power-cycled.

## Commands: Current Status

### Device Commands

| Command | Status | Notes |
|---|---|---|
| `helixcli device list` | Working | Lists supported Line 6 devices. |
| `helixcli device list --all` | Working | Lists all USB devices through IOKit. |
| `helixcli device info` | Working | Shows first supported HX/Helix device. |
| `helixcli device topology` | Working | Uses libusb to show configurations/interfaces/endpoints. |
| `helixcli device probe` | Working | Opens/claims/releases interface 0 without data transfer. |
| `helixcli device ping` | Diagnostic only | Sends connect-start packet. Do not run repeatedly in one powered-on session. |
| `helixcli device connect` | Working diagnostic | Runs the handshake and returns trace metadata. |
| `helixcli device preset-names` | Working diagnostic | Reads and decodes 125 preset names. |
| `helixcli device current-name` | Working diagnostic | Reads current preset name. |
| `helixcli device preset-data` | Working diagnostic | Captures raw current-preset data packets and payload hex. |
| `helixcli device send-raw` | Diagnostic only | Useful for protocol experiments. |
| `helixcli device reset` | Risky diagnostic | Avoid except with explicit warning; may require power-cycle. |

### Preset Commands

| Command | Status | Notes |
|---|---|---|
| `helixcli preset list` | Working | Reads 125 preset names from hardware. |
| `helixcli preset current` | Working | Reads current preset name, e.g. `GospelTone CLN`. |
| `helixcli preset switch <id>` | Working | Uses USB-MIDI Program Change on interface 4. Valid IDs currently 0-125. |
| `helixcli preset get-current` | Working | Captures and parses the currently loaded preset data; also attempts a separate current-name request and returns `nameSource`. Use `--skip-name` for the faster payload-only path. |
| `helixcli preset get --id <id>` | Deprecated alias | Reads current preset only and returns a warning; arbitrary preset reads by ID are not implemented yet. |
| `helixcli preset parse-fixture <path>` | Working offline diagnostic | Parses a raw preset payload hex fixture without USB access; useful for parser regression checks. |

### Snapshot Commands

| Command | Status | Notes |
|---|---|---|
| `helixcli snapshot list` | Working read-only | Parses current preset payload and returns 3 snapshots with current flag. |
| `helixcli snapshot switch <id>` | Stub | Validates 1-3 but does not send USB/MIDI command yet. |

### Block Commands

| Command | Status | Notes |
|---|---|---|
| `helixcli block list` | Working read-only | Reads current preset data and returns parsed non-empty blocks. Use `--include-empty` to include all slots. |
| `helixcli block get <slot>` | Working read-only | Reads current preset data and returns one parsed slot, e.g. `A3`. |
| `helixcli block toggle <slot>` | Stub | Placeholder only; no write is sent. |
| `helixcli block param <slot> <param> <value>` | Stub | Placeholder only. |

### Tuner

| Command | Status | Notes |
|---|---|---|
| `helixcli tuner` | Stub | Starts a run loop but does not read tuner data. |

## Parser Status

### Working

`preset get-current --timeout 500 --max-packets 120` returns a successful JSON response with:

- `blockCount: 16`
- slots `A1` through `A8`, `B1` through `B8`
- enabled/disabled booleans for several blocks
- raw model IDs like `8205`, `8518`, `8206`, `830e`
- numeric parameter values parsed from `0xca` IEEE-754 floats plus boolean markers `0xc2`/`0xc3`
- top-level `name` from the current-name request when available, with `nameSource`
- `namedValues` entries with `index`, first-pass `name`, raw parsed `value`, `displayValue`, and `displayKind`

### Known Parser Gaps

- Preset name from full preset payload parsing still returns `Unknown`; `preset get-current` works around this by doing a separate current-name request unless `--skip-name` is used.
- Known model IDs are mapped through the `helix_usb` module catalog, including categories like Amp, Cab, Dynamic, Delay, Modulation, etc.
- Parameter labels exist for common categories and the current preset's known models (`US Double Nrm`, `LA Studio Comp`, `Deluxe Phaser`, `Vintage Digital`, dual cabs), but they are first-pass and need validation against HX Edit/manuals.
- Display scaling is conservative and marked by `displayKind` (`normalized-0-10`, `percent`, `frequency`, `boolean`, `raw`, etc.). It is useful for agent summaries but not yet a substitute for exact HX Edit display values.
- Some parsed numeric values still need semantic decoding/scaling; suspicious values intentionally fall back to `raw` instead of over-formatting.
- `preset get --id` is deprecated and intentionally warns that it reads current preset data, not arbitrary preset data by ID.
- Snapshot names/settings are visible in raw payload sections but not parsed into structured snapshot data yet.

## Verified Commands

These were verified during live testing:

```bash
swift build
swift run helixcli device list
swift run helixcli preset list --timeout 250 --max-packets 120
swift run helixcli preset current --timeout 500
swift run helixcli preset switch 1
swift run helixcli preset switch 0
swift run helixcli preset get-current --timeout 500 --max-packets 120
swift run helixcli preset get-current --skip-name --timeout 500 --max-packets 120
swift run helixcli preset get --id 0 --timeout 500 --max-packets 120
swift run helixcli snapshot list --timeout 500 --max-packets 120
swift run helixcli block list --timeout 500 --max-packets 120
swift run helixcli block get A3 --timeout 500 --max-packets 120
swift run helixcli preset parse-fixture docs/fixtures/current-preset-gospeltone.hex
swift run helixcli preset parse-fixture docs/fixtures/preset-001-full-dist.hex
swift run helixcli preset parse-fixture docs/fixtures/preset-002-preset-002.hex
swift run helixcli preset parse-fixture docs/fixtures/preset-003-preset-003.hex
scripts/verify_fixtures.py
```

Representative verified behavior:

- `preset current` returned `GospelTone CLN`.
- After switching to preset `1`, `preset current` returned `Full Dist`.
- Switching back to preset `0` restored `GospelTone CLN`.
- `preset list` decoded all 125 preset names.
- `preset get-current` returned the current preset name (`GospelTone CLN`) plus 16 blocks and parsed parameter values.
- `preset get --id 0` returned a deprecated/current-preset warning instead of implying arbitrary preset reads.
- `snapshot list` returned 3 snapshots (`SNAPSHOT 1`, `SNAPSHOT 2`, `SNAPSHOT 3`) with snapshot 1 marked current.
- `block list` returned parsed non-empty blocks including `US Double Nrm`, `LA Studio Comp`, `Deluxe Phaser`, `Vintage Digital`, and a dual cab block.
- `block get A3` returned the current amp block as `US Double Nrm (mono)` with named/display parameters including `Drive` = `3.8`, `Bass` = `4.4`, `Mid` = `5.2`, `Treble` = `5.0`, `Presence` = `5.0`, `Ch Vol` = `5.0`, `Master` = `6.0`, and `Sag` = `5.0`.
- Fixture verification now covers four captured payloads: `GospelTone CLN`, `Full Dist`, preset 002 (`Compulsive Drive`), and preset 003 (`Ping Pong`).

## Latency / Benchmarking

Preliminary latency notes and the comparison plan against `helix_usb` are documented in [`LATENCY.md`](LATENCY.md).

Current quick read:

- `helixcli preset current` and `preset get-current --skip-name` can complete around ~0.6-1.0s with the release binary; plain `preset get-current` is slower because it performs an additional current-name request.
- Tail latency is not stable yet; some independent command runs waited ~30-60s.
- Automated `helix_usb` benchmarking needs more work because the Python interactive session did not settle cleanly under `pexpect` during the first attempt.

## What Is Missing / Next Work

### Highest Priority

1. Implement true arbitrary preset reads by ID when the protocol is known.
2. Expand/verify model ID mapping edge cases beyond the imported `helix_usb` catalog.
3. Validate first-pass parameter-name mappings and replace conservative display scaling with exact HX Stomp display values where possible.
4. Extract preset name directly from full preset payload data so `get-current --skip-name` and fixtures can avoid `Unknown`.

### Protocol / Feature Work

5. Implement snapshot switch against real hardware.
6. Continue improving block list/get parser quality.
7. Implement block toggle/write operations safely.
8. Implement block parameter writes safely, with confirmation-oriented UX for OpenClaw use.
9. Investigate tuner data protocol.

### Productization

10. Keep expanding fixture regression coverage with more captured preset payloads and exact expected values, especially snapshots, IRs, EQ, modulation, and edge-case routing.
11. Add integration-test notes that require attached hardware.
12. Add GitHub Actions CI.
13. Finalize Homebrew tap/release workflow.
14. Improve error messages around interface access conflicts.
15. Decide whether diagnostic commands should remain public, hidden, or marked experimental.

## Useful Notes for Future Development

- Prefer one clean protocol session per read operation: connect → reconfigure x1 → request data.
- Avoid repeated `device ping` calls in the same powered-on device session; it can leave the Stomp waiting for a later handshake phase.
- Avoid routine USB reset.
- `preset switch` is currently safer through USB MIDI than through the proprietary protocol.
- `preset-data` is the best command for capturing fixtures for parser development.

## Current Git State at Documentation Time

Recent functional commit:

```text
2ace548 fix: improve preset data parsing
```

Documentation should be updated whenever new parser mappings or write operations are verified against hardware.
