# helixcli - HX Stomp Skill

Control Line 6 HX Stomp guitar processors via `helixcli` command.

## Overview

This skill enables OpenClaw agents to interact with HX Stomp guitar pedals, allowing:
- Reading current preset and effect chain
- Switching presets and snapshots
- Adjusting effect block parameters
- Collaborative tone crafting with users

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

# Get preset details including effect blocks
helixcli preset get --id <ID>
```

### Snapshot Management

```bash
# List snapshots in current preset
helixcli snapshot list

# Switch to snapshot (1-3)
helixcli snapshot switch <ID>
```

### Effect Block Control

```bash
# List all blocks in current preset
helixcli block list

# Toggle block on/off
helixcli block toggle <SLOT>

# Set block parameter
helixcli block param <SLOT> <PARAM> <VALUE>

# Get block details
helixcli block get <SLOT>
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
2. **Make incremental suggestions** - Don't change everything at once
3. **Explain changes** - Tell the user what you're adjusting and why
4. **Confirm before applying** - Especially for live performance scenarios
5. **Handle errors gracefully** - Device might not be connected

## Safety

- HX Stomp stores up to 128 presets - switching is safe
- Changes are immediate - warn user if audio is audible
- No permanent damage risk from parameter changes

## Examples

### Clean Tone with Delay

```bash
# Read current
helixcli preset current

# Ensure reverb and delay are enabled
helixcli block toggle C  # Delay
helixcli block toggle D  # Reverb

# Set delay time (in ms)
helixcli block param C time 350

# Set reverb decay
helixcli block param D decay 45
```

### High-Gain Lead

```bash
# Switch to high-gain preset
helixcli preset switch 12

# Boost with overdrive
helixcli block param A drive 8
helixcli block param A level 7

# Add delay for leads
helixcli block toggle C
helixcli block param C mix 25
```

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
