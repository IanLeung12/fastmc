#!/bin/bash
# Output, prompts and small portability helpers for bin/mc.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" > /dev/null 2>&1 || die "'$1' is not installed. $2"
}

# Ask a yes/no question; default is no.
confirm() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Fail if a flag that takes a value was given none. Usage: need_val "$1" "${2-}"
need_val() {
    [ -n "$2" ] && [[ "$2" != --* ]] || die "$1 needs a value."
}

expand_home() {
    echo "${1/#\~/$HOME}"
}

# The Windows AWS CLI needs Windows paths for file:// and fileb:// arguments.
native_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -w "$1"
    else
        echo "$1"
    fi
}

# Restrict a private key to the current user. chmod is enough on Linux/macOS;
# on Windows, OpenSSH checks the NTFS ACL instead.
protect_key() {
    chmod 600 "$1"
    if command -v icacls > /dev/null 2>&1; then
        MSYS_NO_PATHCONV=1 icacls "$(native_path "$1")" /inheritance:r /grant:r "${USERNAME:-$USER}:R" > /dev/null
    fi
}
