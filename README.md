# helixcli

A native macOS command-line tool for controlling Line 6 HX Stomp guitar processors via USB.

## Current Status

Core preset control is working against real HX Stomp hardware:

- device detection and USB topology inspection
- proprietary protocol handshake
- preset list/current read
- preset switching via USB MIDI
- current-preset raw data capture
- current-preset block parsing with human-readable model/category names
- read-only block list/get commands
- first-pass parameter labels and conservative display values for common/current-preset models

Still missing: exact HX Edit-style parameter units/display scaling, full parameter-name coverage, true arbitrary preset reads by ID, block writes, snapshot support, tuner support, tests, and release automation.

See [`docs/STATUS.md`](docs/STATUS.md) for the detailed capability/gap matrix and [`docs/LATENCY.md`](docs/LATENCY.md) for preliminary latency notes. Parser regression fixtures live in [`docs/fixtures/`](docs/fixtures/) and can be checked with `scripts/verify_fixtures.py`.

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

# Parse a captured preset payload without USB hardware
helixcli preset parse-fixture docs/fixtures/current-preset-gospeltone.hex
```

### Snapshot Management

Snapshot commands exist but are currently stubs:

```bash
helixcli snapshot list
helixcli snapshot switch 2
```

### Block Control

Read-only block inspection works for the current preset:

```bash
helixcli block list --timeout 500 --max-packets 120
helixcli block list --include-empty --timeout 500 --max-packets 120
helixcli block get A3 --timeout 500 --max-packets 120
```

Write operations are still stubs and do not send changes yet:

```bash
helixcli block toggle A3
helixcli block param A3 drive 0.7
```

## OpenClaw Integration

See [`docs/SKILL.md`](docs/SKILL.md) for agent guidance and [`docs/STATUS.md`](docs/STATUS.md) for the current implementation status.

## License

MIT
