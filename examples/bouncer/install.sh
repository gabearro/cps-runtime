#!/bin/bash
## CPS IRC Bouncer - macOS Install Script
##
## Compiles the bouncer, installs the binary, and sets up launchd.
##
## Usage:
##   bash examples/bouncer/install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BINARY_NAME="cps_bouncer"
INSTALL_DIR="/usr/local/bin"
PLIST_NAME="com.cps.irc-bouncer.plist"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
CONFIG_DIR="$HOME/.config/cps-bouncer"

echo "=== CPS IRC Bouncer Installer ==="
echo ""

# 1. Compile
echo "Compiling bouncer..."
cd "$PROJECT_ROOT"
nim c -d:release "examples/bouncer/$BINARY_NAME.nim"
echo "  Compiled: examples/bouncer/$BINARY_NAME"

# 2. Install binary
echo "Installing binary to $INSTALL_DIR/$BINARY_NAME..."
sudo cp "examples/bouncer/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"
sudo chmod 755 "$INSTALL_DIR/$BINARY_NAME"

# 3. Create config directory
mkdir -p "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR/logs"

# 4. Create default config if needed
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    echo "Creating default config..."
    "$INSTALL_DIR/$BINARY_NAME" --init
fi

# 5. Install launchd plist
echo "Installing launchd plist..."
mkdir -p "$LAUNCH_AGENTS"

# Replace username in plist
USERNAME=$(whoami)
sed "s|REPLACE_WITH_USERNAME|$USERNAME|g" \
    "$SCRIPT_DIR/$PLIST_NAME" > "$LAUNCH_AGENTS/$PLIST_NAME"

# 6. Load service
echo "Loading launchd service..."
launchctl unload "$LAUNCH_AGENTS/$PLIST_NAME" 2>/dev/null || true
launchctl load "$LAUNCH_AGENTS/$PLIST_NAME"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Config: $CONFIG_DIR/config.json"
echo "Socket: $CONFIG_DIR/bouncer.sock"
echo "Logs:   $CONFIG_DIR/logs/"
echo "Stdout: /tmp/cps-bouncer.log"
echo "Stderr: /tmp/cps-bouncer.err"
echo ""
echo "Commands:"
echo "  launchctl stop com.cps.irc-bouncer     # Stop"
echo "  launchctl start com.cps.irc-bouncer    # Start"
echo "  launchctl unload ~/Library/LaunchAgents/$PLIST_NAME  # Disable"
echo ""
echo "Edit $CONFIG_DIR/config.json and restart to configure servers."
