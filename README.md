# helixcli

A native macOS command-line tool for controlling Line 6 HX Stomp guitar processors via USB.

## Current Status

Core preset control is working against real HX Stomp hardware:

- device detection and USB topology inspection
- proprietary protocol handshake
- preset list/current read
- preset switching via USB MIDI
- current-preset raw data capture
- initial block/parameter parsing

Still missing: human-readable model/parameter mappings, true arbitrary preset reads by ID, block writes, snapshot support, tuner support, tests, and release automation.

See [`docs/STATUS.md`](docs/STATUS.md) for the detailed capability/gap matrix.

## Installation

### Homebrew (Recommended)

```bash
brew tap acwilan/helixcli
brew install helixcli
```

### Build from Source

Requirements:
- macOS 14+
- Swift 6.0+
- libusb (`brew install libusb`)

```bash
git clone https://github.com/acwilan/helixcli.git
cd helixcli
swift build -c release
sudo cp .build/release/helixcli /usr/local/bin/
```

## Usage

### Preset Management

```bash
# List all presets
helixcli preset list

# Get current preset
helixcli preset current

# Switch to preset
helixcli preset switch 12

# Get preset details
helixcli preset get --id 5
```

### Snapshot Management

Snapshot commands exist but are currently stubs:

```bash
helixcli snapshot list
helixcli snapshot switch 2
```

### Block Control

Block commands exist but are currently stubs. For now, use `preset get` to inspect initial parsed block data from the current preset:

```bash
helixcli preset get --id 0 --timeout 500 --max-packets 120
```

## OpenClaw Integration

See [`docs/SKILL.md`](docs/SKILL.md) for agent guidance and [`docs/STATUS.md`](docs/STATUS.md) for the current implementation status.

## License

MIT
