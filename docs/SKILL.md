# helixcli - HX Stomp Skill

Control Line 6 HX Stomp guitar processors via `helixcli` command.

## Overview

This skill enables OpenClaw agents to interact with HX Stomp guitar pedals.

Currently verified:
- Detecting the connected HX Stomp
- Listing presets
- Reading the current preset name
- Switching presets
- Capturing and partially parsing current-preset block/parameter data
- Read-only `block list` and `block get <slot>` inspection with model/category names and first-pass `namedValues` parameter labels

Not yet implemented:
- Snapshot list/switch against hardware
- Block toggle/write operations
- Block parameter writes
- Fully verified human-readable parameter mappings, units, ranges, and display scaling
- Tuner data

See `docs/STATUS.md` for the detailed status matrix.

## Prerequisites

```bash
# Install helixcli
brew tap acwilan/helixcli
brew install helixcli

# Connect HX Stomp via USB
```

## Commands Reference

### Preset Management

```bash
# List all presets
helixcli preset list

# Get current preset
helixcli preset current

# Switch to preset by ID (0-127)
helixcli preset switch <ID>

# Get current preset details including current name and partially parsed effect blocks
helixcli preset get-current --timeout 500 --max-packets 120

# Faster current preset details without the separate current-name request
helixcli preset get-current --skip-name --timeout 500 --max-packets 120

# Deprecated compatibility alias: --id is informational; this reads current preset data.
helixcli preset get --id <ID> --timeout 500 --max-packets 120

# Parse captured preset payload fixtures without connecting to USB
helixcli preset parse-fixture docs/fixtures/current-preset-gospeltone.hex
helixcli preset parse-fixture docs/fixtures/preset-001-full-dist.hex
scripts/verify_fixtures.py
```

### Snapshot Management

These commands are currently stubs and should not be relied on for live control yet:

```bash
helixcli snapshot list
helixcli snapshot switch <ID>
```

### Effect Block Control

Read-only inspection works against the current preset:

```bash
helixcli block list --timeout 500 --max-packets 120
helixcli block list --include-empty --timeout 500 --max-packets 120
helixcli block get <SLOT> --timeout 500 --max-packets 120
```

Write commands are currently stubs and should not be used as if they apply changes yet:

```bash
helixcli block toggle <SLOT>
helixcli block param <SLOT> <PARAM> <VALUE>
```

## Agent Workflow

### Tone Crafting Session

```
User: "I want a crunchy blues tone"

Agent:
1. Read current state
   helixcli preset current
   helixcli block list

2. Analyze and suggest
   "Current preset has a Tube Screamer in slot A. For blues, I suggest:
   - Increase Drive to 7
   - Enable a touch of reverb
   - Switch to a warmer amp model"

3. Wait for confirmation

4. Apply changes
   helixcli block param A drive 7
   helixcli block toggle D  # Enable reverb
```

## Response Format

All commands return JSON:

```json
{
  "success": true,
  "data": { ... },
  "error": null
}
```

Error format:

```json
{
  "success": false,
  "data": null,
  "error": {
    "code": "DEVICE_NOT_FOUND",
    "message": "HX Stomp not connected via USB"
  }
}
```

## Block Types Reference

| Type | Description | Common Parameters |
|------|-------------|-------------------|
| Distortion | Overdrive, fuzz | drive, tone, level |
| Delay | Echo effects | time, feedback, mix |
| Reverb | Space effects | decay, pre-delay, mix |
| Amp | Amplifier models | gain, bass, mid, treble |
| Cab | Cabinet simulation | mic, distance, low cut |
| EQ | Equalization | freq, gain, q |

## Tips for Agents

1. **Always check current state first** - Don't assume what's loaded
2. **Treat parsed block data as experimental** - Model names/categories are mapped and `namedValues` includes `displayValue`, but labels/units/scaling are conservative and not fully verified yet
3. **Use fixtures for parser work** - Run `scripts/verify_fixtures.py` after parser/catalog changes
4. **Do not claim block/snapshot writes are available yet** - Those commands are stubs
5. **Make incremental suggestions** - Don't change everything at once
6. **Explain changes** - Tell the user what you're adjusting and why
7. **Confirm before applying** - Especially for live performance scenarios
8. **Handle errors gracefully** - Device might not be connected or the USB interface may be busy

## Safety

- Preset switching is working and immediate - warn user if audio is audible
- Avoid routine `helixcli device reset`; live testing showed it can require a power-cycle
- Avoid repeated `helixcli device ping` in one powered-on session; use higher-level commands instead
- Block/snapshot/parameter writes are not implemented yet

## Examples

### Read Current State

```bash
helixcli preset current --timeout 500
helixcli preset get-current --timeout 500 --max-packets 120
```

### Switch Presets

```bash
# Switch to preset 12
helixcli preset switch 12

# Confirm the active preset after switching
helixcli preset current --timeout 500
```

### Future Block-Write Workflow

Block writes are not implemented yet. When they are, the intended workflow is:

1. Read current preset/block state.
2. Suggest a small change.
3. Ask the user for confirmation.
4. Apply one block toggle/parameter change.
5. Read back state if possible.

Do not use `helixcli block toggle` or `helixcli block param` for real control until those commands are implemented and verified.

## Troubleshooting

| Error | Solution |
|-------|----------|
| DEVICE_NOT_FOUND | Check USB cable, ensure HX Stomp is powered on |
| USB_ERROR | Try different USB port or cable |
| INVALID_PRESET | Use ID between 0-127 |
| INVALID_SNAPSHOT | Use ID between 1-3 |

## See Also

- helixcli GitHub: https://github.com/acwilan/helixcli
- HX Stomp Manual: Line 6 official documentation
- helix_usb (reference): https://github.com/kempline/helix_usb
