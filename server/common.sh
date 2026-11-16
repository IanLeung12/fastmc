#!/bin/bash

# =============================================================================
# Minecraft — shared helpers, sourced by start.sh, stop.sh and newworld.sh.
# Reads the profile settings that setup.sh wrote to server.env.
# =============================================================================

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SERVER_DIR/server.env"

JAR="fabric-server-launch.jar"
SCREEN_NAME="mc"

# Use all available RAM minus 2GB for the OS (never less than 1GB)
TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')
RAM_MB=$((TOTAL_MB - 2048))
[ "$RAM_MB" -lt 1024 ] && RAM_MB=1024
RAM="${RAM_MB}M"

# --- Colours ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Colour

is_server_running() {
    pgrep -f "$JAR" > /dev/null 2>&1
}

is_screen_running() {
    screen -list | grep -q "\.${SCREEN_NAME}"
}

# Launch the server in a detached screen session. Returns non-zero if the
# session didn't come up.
start_server() {
    cd "$SERVER_DIR" || return 1
    screen -S "$SCREEN_NAME" -dm bash -c "java -Xmx${RAM} -Xms${RAM} -jar ${JAR} nogui; echo -e '${RED}Server stopped. Press Enter to close.${NC}'; read"
    sleep 1
    is_screen_running
}

# Stop the server gracefully. Optional $1 is a chat warning, sent 5 seconds
# before stopping. Returns non-zero if the server didn't stop in time.
stop_server() {
    local warning="${1:-}"

    if is_screen_running && is_server_running; then
        if [ -n "$warning" ]; then
            screen -S "$SCREEN_NAME" -X stuff "say ${warning}$(printf '\r')"
            sleep 5
        fi
        screen -S "$SCREEN_NAME" -X stuff "stop$(printf '\r')"
    fi

    # Wait for the Java process to stop (more reliable than watching screen)
    for _ in {1..90}; do
        if ! is_server_running; then
            break
        fi
        sleep 1
    done

    if is_server_running; then
        echo -e "${RED}[ERROR] Server didn't stop in time. Kill it manually with: kill \$(pgrep -f ${JAR})${NC}"
        return 1
    fi

    # Clean up the screen session if it's still lingering
    if is_screen_running; then
        screen -S "$SCREEN_NAME" -X quit
    fi
}
