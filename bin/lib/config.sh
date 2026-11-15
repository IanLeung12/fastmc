#!/bin/bash
# Stage 1: resolve config.
#
# Builds one flat set of variables from, in increasing precedence:
#   built-in defaults < profiles/<PROFILE>.conf < .env < launch flags
# Every key overrides the previous layer, except PROPS, which accumulates
# (later entries win when server.properties is written).
#
# Profiles and .env are plain KEY=value data, parsed here rather than sourced,
# so any other language can read them too.

# Every key the resolved config holds, in --dry-run order
CONFIG_KEYS=(
    NAME PROFILE
    AWS_PROFILE AWS_REGION INSTANCE_TYPE DISK_GB SPOT ELASTIC_IP
    KEY_NAME KEY_PATH SSH_CIDR PORTS
    MC_VERSION FABRIC_INSTALLER_VERSION JAVA_VERSION MODS PROPS OPS WHITELIST
    REPO_RAW_URL REPO_REF
)
# The subset written to server.env on the instance
SERVER_KEYS=(
    NAME PROFILE MC_VERSION FABRIC_INSTALLER_VERSION JAVA_VERSION MODS PROPS
    OPS WHITELIST REPO_RAW_URL REPO_REF
)
# Allowed in config files but never printed or sent to the instance
SECRET_KEYS=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)

set_defaults() {
    NAME=""                       # defaults to PROFILE once resolved
    PROFILE="lockout"
    AWS_PROFILE="${AWS_PROFILE:-}"
    AWS_REGION="${AWS_REGION:-ca-central-1}"
    INSTANCE_TYPE="c7i.xlarge"
    DISK_GB="20"
    SPOT="false"
    ELASTIC_IP="false"
    KEY_NAME="lockoutserver"
    KEY_PATH="~/.ssh/lockoutserver.pem"
    SSH_CIDR="auto"
    PORTS="tcp:25565"
    MC_VERSION=""
    FABRIC_INSTALLER_VERSION=""
    JAVA_VERSION=""
    MODS=""
    # view-distance 20 needs a non-burstable instance with 8 GB+ (see README).
    # simulation-distance stays at 10 so far chunks are visible but don't tick.
    PROPS="view-distance=20;simulation-distance=10"
    OPS=""
    WHITELIST=""
    REPO_RAW_URL="https://raw.githubusercontent.com/IanLeung12/lockoutserver"
    REPO_REF="main"
}

# Values end up quoted in server.env and in AWS CLI shorthand, so keep out
# anything that would need escaping.
check_value() {
    case "$2" in
        *[\"\$\`\\]*) die "$1: values can't contain \" \$ \` or \\ (got: $2)" ;;
    esac
}

is_known_key() {
    local k
    for k in "${CONFIG_KEYS[@]}" "${SECRET_KEYS[@]}"; do
        [ "$k" = "$1" ] && return 0
    done
    return 1
}

append_props() {
    PROPS="${PROPS:+${PROPS};}$1"
}

# Load a KEY=value file into variables. Blank lines and # comments are
# skipped; one pair of surrounding quotes is stripped; nothing is expanded.
load_kv_file() {
    local file="$1" line key value n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die "$file:$n: expected KEY=value, got: $line"
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        is_known_key "$key" || die "$file:$n: unknown key $key"
        check_value "$file:$n" "$value"
        if [ "$key" = "PROPS" ]; then
            append_props "$value"
        else
            printf -v "$key" '%s' "$value"
        fi
    done < "$file"
}

# Make the AWS settings visible to the aws CLI.
export_aws_env() {
    local k
    export AWS_REGION
    if [ -n "$AWS_PROFILE" ]; then export AWS_PROFILE; else export -n AWS_PROFILE; fi
    for k in "${SECRET_KEYS[@]}"; do
        if [ -n "${!k:-}" ]; then export "${k?}"; fi
    done
}

# Defaults + .env only: enough for every command except launch.
load_env() {
    set_defaults
    if [ -f "$REPO_ROOT/.env" ]; then load_kv_file "$REPO_ROOT/.env"; fi
    export_aws_env
}

# --- Launch flags ------------------------------------------------------------
# Collected by parse_launch_flags (commands.sh), applied last by resolve_config.
FLAG_SETS=()        # KEY=value overrides, applied in order
FLAG_PROPS=""       # ;-separated server.properties entries
FLAG_ADD_MODS=""
FLAG_DEL_MODS=""
FLAG_PROFILE=""

flag_set()  { check_value "flag" "$2"; FLAG_SETS+=("$1=$2"); }
flag_prop() {
    check_value "flag" "$1"
    [[ "$1" != *";"* ]] || die "server.properties values can't contain ';' (got: $1)"
    FLAG_PROPS="${FLAG_PROPS:+${FLAG_PROPS};}$1"
}

resolve_config() {
    local env_file="$REPO_ROOT/.env" profile kv mod

    # .env may choose the profile, so peek at it first, then start over and
    # apply the layers in order.
    set_defaults
    if [ -f "$env_file" ]; then load_kv_file "$env_file"; fi
    profile="${FLAG_PROFILE:-$PROFILE}"

    set_defaults
    PROFILE="$profile"
    [ -f "$REPO_ROOT/profiles/${PROFILE}.conf" ] \
        || die "No profile '${PROFILE}'. Available: $(list_profiles)"
    load_kv_file "$REPO_ROOT/profiles/${PROFILE}.conf"
    if [ -f "$env_file" ]; then load_kv_file "$env_file"; fi
    PROFILE="$profile"

    for kv in ${FLAG_SETS[@]+"${FLAG_SETS[@]}"}; do
        printf -v "${kv%%=*}" '%s' "${kv#*=}"
    done
    if [ -n "$FLAG_PROPS" ]; then append_props "$FLAG_PROPS"; fi
    for mod in $FLAG_ADD_MODS; do
        [[ " $MODS " == *" $mod "* ]] || MODS="${MODS:+$MODS }$mod"
    done
    for mod in $FLAG_DEL_MODS; do
        [[ " $MODS " == *" $mod "* ]] || die "--no-mod $mod: not in this profile's mods ($MODS)"
        MODS=$(echo " $MODS " | sed "s| $mod | |; s|^ *||; s| *$||")
    done

    NAME="${NAME:-$PROFILE}"
    export_aws_env
}

list_profiles() {
    local f names=""
    for f in "$REPO_ROOT"/profiles/*.conf; do
        f="${f##*/}"
        names="${names:+$names, }${f%.conf}"
    done
    echo "$names"
}

# Last value of a server.properties key in PROPS, or empty.
prop_value() {
    local entries entry value=""
    IFS=';' read -ra entries <<< "$PROPS"
    for entry in ${entries[@]+"${entries[@]}"}; do
        if [ "${entry%%=*}" = "$1" ]; then value="${entry#*=}"; fi
    done
    echo "$value"
}

validate_config() {
    local k entries entry p mod player
    [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] \
        || die "Name '$NAME' must be lowercase letters, digits and dashes (max 40)."
    for k in MC_VERSION FABRIC_INSTALLER_VERSION JAVA_VERSION MODS PORTS \
             AWS_REGION INSTANCE_TYPE KEY_NAME KEY_PATH REPO_RAW_URL REPO_REF; do
        [ -n "${!k}" ] || die "$k is not set (check profiles/${PROFILE}.conf)."
    done
    [[ "$JAVA_VERSION" =~ ^[0-9]+$ ]] || die "JAVA_VERSION must be a number (got: $JAVA_VERSION)."
    [[ "$DISK_GB" =~ ^[0-9]+$ ]] && [ "$DISK_GB" -ge 8 ] || die "DISK_GB must be a number, 8 or more (got: $DISK_GB)."
    [[ "$SPOT" =~ ^(true|false)$ ]] || die "SPOT must be true or false."
    [[ "$ELASTIC_IP" =~ ^(true|false)$ ]] || die "ELASTIC_IP must be true or false."
    [[ "$SSH_CIDR" == auto || "$SSH_CIDR" =~ ^[0-9.]+/[0-9]+$ ]] \
        || die "SSH_CIDR must be 'auto' or a CIDR like 1.2.3.4/32 (got: $SSH_CIDR)."
    for p in $PORTS; do
        [[ "$p" =~ ^(tcp|udp):[0-9]+$ ]] || die "PORTS entries look like tcp:25565 (got: $p)."
    done
    [[ " $PORTS " == *" tcp:25565 "* ]] || die "PORTS must include tcp:25565."
    IFS=';' read -ra entries <<< "$PROPS"
    for entry in ${entries[@]+"${entries[@]}"}; do
        [ -z "$entry" ] || [[ "$entry" == ?*=* ]] || die "PROPS entries look like key=value (got: $entry)."
    done
    for mod in $MODS; do
        [ -f "$REPO_ROOT/mods/${MC_VERSION}/${mod}" ] || die "Mod not found: mods/${MC_VERSION}/${mod}"
    done
    for player in $OPS $WHITELIST; do
        [[ "$player" =~ ^[A-Za-z0-9_]{1,16}$ ]] || die "'$player' isn't a valid Minecraft username."
    done
}

print_config() {
    local k
    for k in "${CONFIG_KEYS[@]}"; do
        printf '%s="%s"\n' "$k" "${!k}"
    done
}

write_server_env() {
    local k
    for k in "${SERVER_KEYS[@]}"; do
        printf '%s="%s"\n' "$k" "${!k}"
    done
}
