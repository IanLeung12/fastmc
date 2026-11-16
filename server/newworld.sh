#!/bin/bash

# =============================================================================
# Minecraft — New World Script
# Archives the current world and restarts the server with a fresh one.
# =============================================================================

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$SERVER_DIR" || exit 1

# =============================================================================
# 1. Stop the server gracefully
# =============================================================================
if ! is_server_running && ! is_screen_running; then
    echo -e "${YELLOW}[WARN] Server is not running. Starting fresh world anyway...${NC}"
else
    echo -e "${GREEN}==>${NC} Stopping server..."
    stop_server "Server restarting for a new world in 5 seconds..." || exit 1
fi

echo -e "${GREEN}[OK] Server stopped.${NC}"

# =============================================================================
# 2. Archive the current world
# =============================================================================
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [ -d "world" ]; then
    BACKUP_NAME="world_${TIMESTAMP}"
    echo -e "${GREEN}==>${NC} Archiving current world to ${BACKUP_NAME}..."
    mv world "$BACKUP_NAME"
    [ -d "world_nether" ]  && mv world_nether  "${BACKUP_NAME}_nether"
    [ -d "world_the_end" ] && mv world_the_end "${BACKUP_NAME}_the_end"
    echo -e "${GREEN}[OK] World archived as ${BACKUP_NAME}.${NC}"
else
    echo -e "${YELLOW}[WARN] No existing world folder found. Starting fresh.${NC}"
fi

# =============================================================================
# 3. Start the server with a new world
# =============================================================================
echo -e "${GREEN}==>${NC} Starting server with new world..."
if start_server; then
    echo -e "${GREEN}[OK] Server started with a fresh world!${NC}"
    echo -e "${GREEN}     Attach: screen -r ${SCREEN_NAME}${NC}"
else
    echo -e "${RED}[ERROR] Server failed to start. Check logs/latest.log${NC}"
    exit 1
fi

# =============================================================================
# 4. List archived worlds
# =============================================================================
echo ""
echo -e "${GREEN}Archived worlds:${NC}"
ls -d world_* 2>/dev/null | grep -v "_nether\|_the_end" || echo "  (none)"
