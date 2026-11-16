#!/bin/bash

# =============================================================================
# Minecraft Fabric Server — first-boot setup
# Run as root by the EC2 user data that `bin/mc launch` generates. The user
# data first writes this script, the other server scripts and server.env into
# the server directory, then runs this. Works for any profile: everything
# profile-specific comes from server.env.
# =============================================================================

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_USER="ubuntu"

# --- Logging — all output goes to /var/log/mc-setup.log ---
exec > /var/log/mc-setup.log 2>&1
set -eo pipefail

# shellcheck source=/dev/null
. "$SERVER_DIR/server.env"

export DEBIAN_FRONTEND=noninteractive

echo "[$(date)] Starting Minecraft ${MC_VERSION} server setup (profile: ${PROFILE})..."

# =============================================================================
# 1. System update & dependencies
# =============================================================================
echo "[$(date)] Installing dependencies..."
apt update && apt upgrade -y -o Dpkg::Options::="--force-confold"
apt install screen wget curl unzip gpg apt-transport-https -y

# Ubuntu's repos don't carry every Java version Minecraft needs (26.2 needs
# 25), so always install Eclipse Temurin from the Adoptium repo.
echo "[$(date)] Installing Temurin ${JAVA_VERSION} from Adoptium..."
mkdir -p /etc/apt/keyrings
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/adoptium.list
apt update
apt install "temurin-${JAVA_VERSION}-jdk" -y
java -version

cd "$SERVER_DIR"

# =============================================================================
# 2. Download & run Fabric installer
# =============================================================================
echo "[$(date)] Downloading Fabric installer..."
INSTALLER_URL="https://maven.fabricmc.net/net/fabricmc/fabric-installer/${FABRIC_INSTALLER_VERSION}/fabric-installer-${FABRIC_INSTALLER_VERSION}.jar"
wget "$INSTALLER_URL" -O fabric-installer.jar

echo "[$(date)] Running Fabric installer for Minecraft ${MC_VERSION}..."
java -jar fabric-installer.jar server -mcversion "$MC_VERSION" -downloadMinecraft

# =============================================================================
# 3. Accept EULA
# =============================================================================
echo "[$(date)] Accepting EULA..."
echo "eula=true" > eula.txt

# =============================================================================
# 4. server.properties
# =============================================================================
# The server merges these into the full server.properties on first start.
# PROPS is a ;-separated list of key=value pairs, already merged from the
# defaults, the profile, .env and launch flags. Later entries win.
set_prop() {
    touch server.properties
    grep -v "^${1}=" server.properties > server.properties.tmp || true
    mv server.properties.tmp server.properties
    echo "${1}=${2}" >> server.properties
}

echo "[$(date)] Writing server.properties..."
IFS=';' read -ra PROP_ENTRIES <<< "$PROPS"
for ENTRY in "${PROP_ENTRIES[@]}"; do
    [ -z "$ENTRY" ] && continue
    set_prop "${ENTRY%%=*}" "${ENTRY#*=}"
done
if [ -n "$WHITELIST" ]; then
    set_prop white-list true
    set_prop enforce-whitelist true
fi
cat server.properties

# =============================================================================
# 5. Download mods from GitHub
# =============================================================================
# GitHub serves the raw path verbatim, so filenames with '+' need no encoding.
# Each jar is verified as a readable zip archive — a 404 or a truncated
# download otherwise lands in mods/ as a file the server silently refuses.
MOD_URL="${REPO_RAW_URL}/${REPO_REF}/mods/${MC_VERSION}"
echo "[$(date)] Downloading mods from ${MOD_URL}..."
mkdir -p mods
for MOD in $MODS; do
    echo "[$(date)] Downloading $MOD..."
    if ! wget --tries=3 "${MOD_URL}/${MOD}" -O "mods/${MOD}"; then
        echo "[$(date)] ERROR: failed to download ${MOD}."
        rm -f "mods/${MOD}"
        exit 1
    fi

    if ! unzip -tqq "mods/${MOD}" > /dev/null 2>&1; then
        echo "[$(date)] ERROR: ${MOD} is not a valid jar (got $(wc -c < "mods/${MOD}") bytes)."
        echo "[$(date)] First line of what was downloaded:"
        head -c 200 "mods/${MOD}"
        rm -f "mods/${MOD}"
        exit 1
    fi
    echo "[$(date)] Verified ${MOD}."
done
echo "[$(date)] All mods downloaded and verified."

# =============================================================================
# 6. Ops and whitelist
# =============================================================================
# ops.json and whitelist.json need UUIDs, so look each name up with Mojang.
# A failed lookup only skips that player: `op <name>` in the console still works.
lookup_uuid() {
    local body id
    body=$(curl -fsS --max-time 10 "https://api.mojang.com/users/profiles/minecraft/${1}") || return 1
    id=$(printf '%s' "$body" | grep -o '"id" *: *"[0-9a-f]\{32\}"' | grep -o '[0-9a-f]\{32\}') || return 1
    echo "$id" | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

# $1 = output file, $2 = extra JSON fields per entry, rest = player names
write_player_json() {
    local file="$1" extra="$2" name uuid entries=""
    shift 2
    for name in "$@"; do
        if ! uuid=$(lookup_uuid "$name"); then
            echo "[$(date)] WARN: couldn't look up a UUID for ${name}, skipping."
            continue
        fi
        entries="${entries:+${entries},}{\"uuid\":\"${uuid}\",\"name\":\"${name}\"${extra}}"
    done
    echo "[${entries}]" > "$file"
    echo "[$(date)] Wrote ${file}: [${entries}]"
}

if [ -n "$OPS" ]; then
    # shellcheck disable=SC2086
    write_player_json ops.json ',"level":4,"bypassesPlayerLimit":false' $OPS
fi
if [ -n "$WHITELIST" ]; then
    # Ops are whitelisted too so they can never lock themselves out
    # shellcheck disable=SC2086
    write_player_json whitelist.json '' $(echo $WHITELIST $OPS | tr ' ' '\n' | sort -fu)
fi

# =============================================================================
# 7. Hand the server over to the login user
# =============================================================================
# User data runs as root, so everything above is root-owned. Without this the
# ubuntu user can't write worlds, logs, or configs.
echo "[$(date)] Setting ownership to ${SERVER_USER}..."
chmod +x "$SERVER_DIR"/*.sh
chown -R "${SERVER_USER}:${SERVER_USER}" "$SERVER_DIR"

# =============================================================================
# 8. Start on boot
# =============================================================================
# The service runs start.sh/stop.sh, so the server lives in the usual 'mc'
# screen session (`screen -r mc` still works) and is saved cleanly whenever
# the instance stops.
echo "[$(date)] Installing minecraft.service..."
cat > /etc/systemd/system/minecraft.service <<UNIT
[Unit]
Description=Minecraft server (screen session "mc")
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${SERVER_USER}
WorkingDirectory=${SERVER_DIR}
ExecStart=/bin/bash ${SERVER_DIR}/start.sh
ExecStop=/bin/bash ${SERVER_DIR}/stop.sh
TimeoutStopSec=150

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now minecraft.service

# =============================================================================
# 9. Done
# =============================================================================
echo "[$(date)] Setup complete! The server is starting in screen session 'mc'."
