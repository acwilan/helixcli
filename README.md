# helixcli

A native macOS command-line tool for controlling Line 6 HX Stomp guitar processors via USB.

`helixcli` is a Swift/macOS-native implementation inspired by and heavily informed by [`kempline/helix_usb`](https://github.com/kempline/helix_usb), the Python project that mapped much of the HX Stomp USB protocol behavior this tool builds on. The goal here is to keep the protocol learnings from `helix_usb` while providing a dependency-light CLI that is easy to package, script, and call from OpenClaw.

## Relationship to helix_usb

This project would not exist without [`helix_usb`](https://github.com/kempline/helix_usb). It remains the primary reference implementation for:

- proprietary Helix/HX USB handshake and packet flow
- preset-name and current-preset data requests
- slot/module parsing heuristics
- model/module ID catalogs
- latency comparison against a long-running Python USB session

`helixcli` is not a drop-in replacement yet. It currently focuses on native macOS CLI usage, read/control operations that are verified on Andres's HX Stomp, and OpenClaw-friendly JSON output. When behavior differs from `helix_usb`, the local docs call that out explicitly.

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

# Get currently loaded preset details
helixcli preset get-current

# Deprecated compatibility alias; reads current preset only, --id is informational
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

## Acknowledgements

Special thanks to [`kempline/helix_usb`](https://github.com/kempline/helix_usb) for the original Python implementation and protocol exploration. Much of `helixcli`'s packet structure, parser strategy, and model catalog work traces back to that project.

## License

MIT
