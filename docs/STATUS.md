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
- Initial block/parameter parsing works, but still returns raw model IDs and unlabeled numeric parameters.

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
| `helixcli preset get --id <id>` | Partially working | Captures and parses current preset data. The `id` argument is not yet used to fetch arbitrary preset storage. |

### Snapshot Commands

| Command | Status | Notes |
|---|---|---|
| `helixcli snapshot list` | Stub | Returns placeholder JSON only. |
| `helixcli snapshot switch <id>` | Stub | Validates 1-3 but does not send USB/MIDI command yet. |

### Block Commands

| Command | Status | Notes |
|---|---|---|
| `helixcli block list` | Stub | Placeholder only. Similar data is currently available through `preset get`. |
| `helixcli block get <slot>` | Stub | Placeholder only. |
| `helixcli block toggle <slot>` | Stub | Placeholder only. |
| `helixcli block param <slot> <param> <value>` | Stub | Placeholder only. |

### Tuner

| Command | Status | Notes |
|---|---|---|
| `helixcli tuner` | Stub | Starts a run loop but does not read tuner data. |

## Parser Status

### Working

`preset get --id 0 --timeout 500 --max-packets 120` returns a successful JSON response with:

- `blockCount: 16`
- slots `A1` through `A8`, `B1` through `B8`
- enabled/disabled booleans for several blocks
- raw model IDs like `8205`, `8518`, `8206`, `830e`
- numeric parameter values parsed from `0xca` IEEE-754 floats plus boolean markers `0xc2`/`0xc3`

### Known Parser Gaps

- Preset name from full preset data still returns `Unknown`; use `preset current` for the current preset name.
- Raw model IDs are not yet mapped to human-readable names such as compressors, drives, amps, delays, reverbs, etc.
- Parameters are unlabeled numeric arrays; there is no mapping yet to parameter names, units, ranges, or display values.
- Some parsed numeric values likely need semantic decoding/scaling.
- `preset get --id` currently reads current preset data, not arbitrary preset data by ID.
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
swift run helixcli preset get --id 0 --timeout 500 --max-packets 120
```

Representative verified behavior:

- `preset current` returned `GospelTone CLN`.
- After switching to preset `1`, `preset current` returned `Full Dist`.
- Switching back to preset `0` restored `GospelTone CLN`.
- `preset list` decoded all 125 preset names.
- `preset get --id 0` returned 16 blocks and parsed parameter values.

## What Is Missing / Next Work

### Highest Priority

1. Clarify `preset get --id` semantics:
   - Either implement true arbitrary preset reads by ID, or
   - Rename/scope it to something like `preset get-current` until arbitrary reads are known.
2. Map model IDs to human-readable model names.
3. Map parameter positions to names, units, display ranges, and actual HX Stomp values.
4. Extract preset name from full preset data, or combine `preset current` with `preset get` when reading current preset.

### Protocol / Feature Work

5. Implement snapshot list/switch against real hardware.
6. Implement block list/get as wrappers around the parser output.
7. Implement block toggle/write operations safely.
8. Implement block parameter writes safely, with confirmation-oriented UX for OpenClaw use.
9. Investigate tuner data protocol.

### Productization

10. Add unit tests for parsers using captured fixture payloads.
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
