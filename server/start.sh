#!/bin/bash

# =============================================================================
# Minecraft Fabric Server Startup Script
# Also run by the minecraft systemd service at boot.
# =============================================================================

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Minecraft ${MC_VERSION} Fabric Server (${PROFILE})${NC}"
echo -e "${GREEN}========================================${NC}"

# Check Java
if ! command -v java &> /dev/null; then
    echo -e "${RED}[ERROR] Java is not installed. Run: apt install temurin-${JAVA_VERSION}-jdk -y (see setup.sh for the Adoptium repo)${NC}"
    exit 1
fi

INSTALLED_JAVA=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
if [ "$INSTALLED_JAVA" -lt "$JAVA_VERSION" ]; then
    echo -e "${RED}[ERROR] Java ${JAVA_VERSION}+ is required. Found Java ${INSTALLED_JAVA}.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Java ${INSTALLED_JAVA} detected.${NC}"

cd "$SERVER_DIR" || exit 1

# Check JAR
if [ ! -f "$JAR" ]; then
    echo -e "${RED}[ERROR] Server JAR not found: ${SERVER_DIR}/${JAR}${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Server JAR found.${NC}"

# Check EULA
if ! grep -q "eula=true" eula.txt 2>/dev/null; then
    echo -e "${YELLOW}[WARN] EULA not accepted. Accepting now...${NC}"
    echo "eula=true" > eula.txt
fi
echo -e "${GREEN}[OK] EULA accepted.${NC}"

# Check if the server is already running
if is_server_running; then
    echo -e "${YELLOW}[WARN] The server is already running.${NC}"
    echo -e "${YELLOW}       Reattach with: screen -r ${SCREEN_NAME}${NC}"
    exit 1
fi

# A screen left over from a server stopped with 'stop' is just waiting for Enter
if is_screen_running; then
    echo -e "${YELLOW}[WARN] Closing leftover screen session '${SCREEN_NAME}'.${NC}"
    screen -S "$SCREEN_NAME" -X quit
fi

# Launch
echo ""
echo -e "${GREEN}Starting server with ${RAM} RAM in screen session '${SCREEN_NAME}'...${NC}"
echo -e "${GREEN}  Detach : Ctrl+A then D${NC}"
echo -e "${GREEN}  Attach : screen -r ${SCREEN_NAME}${NC}"
echo -e "${GREEN}  Stop   : attach and type 'stop'${NC}"
echo ""

if start_server; then
    echo -e "${GREEN}[OK] Server is running! Attach with: screen -r ${SCREEN_NAME}${NC}"
else
    echo -e "${RED}[ERROR] Server failed to start. Check logs in ${SERVER_DIR}/logs/latest.log${NC}"
    exit 1
fi
