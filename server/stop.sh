#!/bin/bash

# =============================================================================
# Minecraft — Stop Script
# Warns players, then stops the server gracefully so the world is saved.
# Also run by the minecraft systemd service on shutdown.
# =============================================================================

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if ! is_server_running; then
    echo -e "${YELLOW}[WARN] Server is not running.${NC}"
    is_screen_running && screen -S "$SCREEN_NAME" -X quit
    exit 0
fi

echo -e "${GREEN}==>${NC} Stopping server..."
stop_server "Server stopping in 5 seconds..." || exit 1
echo -e "${GREEN}[OK] Server stopped.${NC}"
