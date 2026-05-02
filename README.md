# helixcli

A native macOS command-line tool for controlling Line 6 HX Stomp guitar processors via USB.

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

```bash
# List snapshots
helixcli snapshot list

# Switch snapshot
helixcli snapshot switch 2
```

### Block Control

```bash
# List blocks
helixcli block list

# Toggle block
helixcli block toggle A

# Set parameter
helixcli block param A gain 7.5
```

## OpenClaw Integration

See [HELIXCLI.md](https://github.com/acwilan/helixcli/blob/main/docs/OPENCLAW.md) for agent configuration.

## License

MIT
