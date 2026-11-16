#!/bin/bash
# Subcommands for bin/mc. Each one strings together the three stages:
# config.sh (resolve) -> render.sh (user data) -> aws.sh (AWS calls).

REMOTE_DIR="/home/ubuntu/minecraft"

usage() {
    cat <<EOF
Usage: bin/mc <command> [options]

Commands:
  launch [options]        Launch a new server (see 'bin/mc launch --help')
  list                    List servers in the region
  ssh [name]              SSH into a server
  console [name]          Attach to the server console (detach: Ctrl+A then D)
  logs [name] [--game]    Follow the setup log (or the game log with --game)
  newworld [name]         Archive the current world and start a fresh one
  backup [name]           Download all worlds to backups/
  stop [name]             Stop the instance (world is saved; storage still billed)
  start [name]            Start a stopped instance and print its new IP
  destroy <name>          Terminate a server and delete its resources
  allow-ip [name] [cidr]  Allow SSH from your current IP (or the given CIDR)

[name] can be left out when only one server exists. Every command takes
--region to override AWS_REGION from .env.
EOF
}

launch_usage() {
    cat <<EOF
Usage: bin/mc launch [options]

Server:
  --name NAME             Server name (default: the profile name)
  --profile NAME          Mod profile from profiles/ (available: $(list_profiles))
  --mod JAR               Add a jar from mods/<MC_VERSION>/ (repeatable)
  --no-mod JAR            Drop one of the profile's mods (repeatable)
  --ref REF               Git branch/tag/commit to download mods from

Instance:
  --region REGION         AWS region
  --type TYPE             Instance type (default: c7i.xlarge)
  --disk GB               Root volume size (default: 20)
  --spot                  Use a spot instance (much cheaper, can be interrupted)
  --elastic-ip            Keep the same IP across stop/start

World:
  --seed SEED             --gamemode MODE        --difficulty LEVEL
  --hardcore              --max-players N        --motd TEXT
  --view-distance N       --sim-distance N       --level-type TYPE
  --prop KEY=VALUE        Any server.properties setting (repeatable)

Players:
  --ops "a,b"             Make these players operators
  --whitelist "a,b"       Turn on the whitelist with these players

Other:
  --dry-run               Print the resolved config and exit
  --render-only           Print the EC2 user data and exit (for console launches)
EOF
}

# --- launch ------------------------------------------------------------------

parse_launch_flags() {
    DRY_RUN=false
    RENDER_ONLY=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)          need_val "$1" "${2-}"; flag_set NAME "$2"; shift 2 ;;
            --profile)       need_val "$1" "${2-}"; FLAG_PROFILE="$2"; shift 2 ;;
            --mod)           need_val "$1" "${2-}"; FLAG_ADD_MODS="$FLAG_ADD_MODS $2"; shift 2 ;;
            --no-mod)        need_val "$1" "${2-}"; FLAG_DEL_MODS="$FLAG_DEL_MODS $2"; shift 2 ;;
            --ref)           need_val "$1" "${2-}"; flag_set REPO_REF "$2"; shift 2 ;;
            --region)        need_val "$1" "${2-}"; flag_set AWS_REGION "$2"; shift 2 ;;
            --type)          need_val "$1" "${2-}"; flag_set INSTANCE_TYPE "$2"; shift 2 ;;
            --disk)          need_val "$1" "${2-}"; flag_set DISK_GB "$2"; shift 2 ;;
            --spot)          flag_set SPOT true; shift ;;
            --elastic-ip)    flag_set ELASTIC_IP true; shift ;;
            --seed)          need_val "$1" "${2-}"; flag_prop "level-seed=$2"; shift 2 ;;
            --gamemode)      need_val "$1" "${2-}"; flag_prop "gamemode=$2"; shift 2 ;;
            --difficulty)    need_val "$1" "${2-}"; flag_prop "difficulty=$2"; shift 2 ;;
            --hardcore)      flag_prop "hardcore=true"; shift ;;
            --max-players)   need_val "$1" "${2-}"; flag_prop "max-players=$2"; shift 2 ;;
            --motd)          need_val "$1" "${2-}"; flag_prop "motd=$2"; shift 2 ;;
            --view-distance) need_val "$1" "${2-}"; flag_prop "view-distance=$2"; shift 2 ;;
            --sim-distance)  need_val "$1" "${2-}"; flag_prop "simulation-distance=$2"; shift 2 ;;
            --level-type)    need_val "$1" "${2-}"; flag_prop "level-type=$2"; shift 2 ;;
            --prop)
                need_val "$1" "${2-}"
                [[ "$2" == ?*=* ]] || die "--prop takes KEY=VALUE (got: $2)"
                flag_prop "$2"; shift 2 ;;
            --ops)           need_val "$1" "${2-}"; flag_set OPS "${2//,/ }"; shift 2 ;;
            --whitelist)     need_val "$1" "${2-}"; flag_set WHITELIST "${2//,/ }"; shift 2 ;;
            --dry-run)       DRY_RUN=true; shift ;;
            --render-only)   RENDER_ONLY=true; shift ;;
            -h|--help)       launch_usage; exit 0 ;;
            *)               die "Unknown option: $1 (see 'bin/mc launch --help')" ;;
        esac
    done
}

warn_uncommitted_server_changes() {
    local changes
    changes=$(git -C "$REPO_ROOT" status --porcelain -- server/ 2> /dev/null || true)
    if [ -n "$changes" ]; then
        warn "Launching with uncommitted changes in server/ (they're embedded as-is):"
        echo "$changes" >&2
    fi
}

# Instances download mods from GitHub, so a jar that only exists locally (or
# on another branch) would fail setup minutes in. Catch it now.
check_remote_mods() {
    local mod url missing=""
    for mod in $MODS; do
        url="${REPO_RAW_URL}/${REPO_REF}/mods/${MC_VERSION}/${mod}"
        curl -fsIL --max-time 15 -o /dev/null "$url" || missing="$missing\n  $url"
    done
    [ -z "$missing" ] || die "These mods aren't downloadable from GitHub yet:$(echo -e "$missing")\nPush them, or pick the branch that has them with --ref."
}

cmd_launch() {
    local ssh_cidr type_info arch mem view_distance ami root_dev sg userdata size id

    parse_launch_flags "$@"
    resolve_config
    validate_config

    if [ "$DRY_RUN" = true ]; then print_config; return; fi
    if [ "$RENDER_ONLY" = true ]; then
        userdata=$(render_userdata)
        printf '%s\n' "$userdata"
        printf '%s\n' "$userdata" | check_console_size
        return
    fi

    warn_uncommitted_server_changes
    aws_preflight
    check_remote_mods
    [ -z "$(find_instance "$NAME")" ] \
        || die "A server named '$NAME' already exists in ${AWS_REGION}. Use --name, or 'bin/mc destroy $NAME' first."

    type_info=$(instance_type_info "$INSTANCE_TYPE")
    read -r arch mem <<< "$type_info"
    view_distance=$(prop_value view-distance)
    if [ "${view_distance:-0}" -gt 12 ] && [ "$mem" -lt 7500 ]; then
        warn "$INSTANCE_TYPE has $((mem / 1024)) GB RAM; view-distance $view_distance wants 8 GB. Consider --view-distance 10."
    fi

    info "Launching '$NAME': $PROFILE (MC $MC_VERSION), $INSTANCE_TYPE ($arch), ${DISK_GB} GB, ${AWS_REGION}$( [ "$SPOT" = true ] && echo ", spot")"
    ssh_cidr=$(resolve_ssh_cidr)
    ami=$(resolve_ami "$arch")
    root_dev=$(root_device_name "$ami")
    ensure_key_pair
    sg=$(ensure_security_group "$ssh_cidr")

    # Plain text is just over EC2's 16 KB limit; cloud-init unpacks gzip itself.
    userdata=$(mktemp)
    render_userdata | gzip -9 > "$userdata"
    size=$(wc -c < "$userdata")
    if [ "$size" -gt "$USERDATA_LIMIT" ]; then
        rm -f "$userdata"
        die "User data is $size bytes gzipped; EC2 allows $USERDATA_LIMIT. Trim the server/ scripts."
    fi

    id=$(run_instance "$ami" "$sg" "$userdata" "$root_dev")
    rm -f "$userdata"
    ok "Launched $id."

    info "Waiting for the instance to start..."
    aws_cli ec2 wait instance-running --instance-ids "$id"
    if [ "$ELASTIC_IP" = true ]; then
        attach_elastic_ip "$id"
        ok "Attached an Elastic IP."
    fi
    wait_until_ready "$id" 900 "First boot installs Java, Fabric and the mods, then generates the world (~5-8 min)"
}

# Args: instance-id timeout-seconds message
wait_until_ready() {
    local ip
    ip=$(instance_field "$1" PublicIpAddress)
    info "Instance is up at $ip. Waiting for Minecraft. $3"
    if wait_for_port "$ip" "$GAME_PORT" "$2"; then
        print_summary "$1"
    else
        warn "Minecraft isn't answering after $(($2 / 60)) min. See what setup is doing with: bin/mc logs $NAME"
        print_summary "$1"
        return 1
    fi
}

print_summary() {
    local id="$1" ip type sg ports eip
    ip=$(instance_field "$id" PublicIpAddress)
    type=$(instance_field "$id" InstanceType)
    sg=$(instance_field "$id" 'SecurityGroups[0].GroupId')
    ports=$(aws_cli ec2 describe-security-groups --group-ids "$sg" \
        --query 'SecurityGroups[0].IpPermissions[?FromPort!=`22`].[IpProtocol, FromPort]' --output text \
        | tr '\t' ' ' | paste -sd, - | sed 's/,/, /g')
    eip=$(aws_cli ec2 describe-addresses --filters "Name=instance-id,Values=$id" \
        --query 'Addresses[0].PublicIp' --output text)

    echo
    echo -e "${GREEN}${BOLD}$NAME is up${NC} (profile: $PROFILE)"
    echo -e "  Connect:   ${BOLD}${ip}${NC}  (port $GAME_PORT)"
    echo    "  Ports:     $ports"
    echo    "  SSH:       bin/mc ssh $NAME"
    echo    "  Console:   bin/mc console $NAME"
    echo    "  Instance:  $id, $type, $AWS_REGION"
    if [ "$eip" = "None" ]; then
        echo    "  Note:      the IP changes on every stop/start (launch with --elastic-ip to keep one)"
    fi
    echo    "  Billing:   runs until 'bin/mc stop $NAME' or 'bin/mc destroy $NAME'"
}

# --- Commands that act on an existing server ----------------------------------

# Parse "[name] [extra positional] [--region R] [flags...]" into TARGET,
# TARGET_ARG and TARGET_FLAGS, then load .env. $1 lists the allowed flags.
parse_target() {
    local allowed="$1"
    shift
    TARGET=""
    TARGET_ARG=""
    TARGET_FLAGS=""
    local region=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --region) need_val "$1" "${2-}"; region="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            --*)
                [[ " $allowed " == *" $1 "* ]] || die "Unknown option: $1"
                TARGET_FLAGS="$TARGET_FLAGS $1"; shift ;;
            *)
                if [ -z "$TARGET" ]; then TARGET="$1"
                elif [ -z "$TARGET_ARG" ]; then TARGET_ARG="$1"
                else die "Too many arguments: $1"
                fi
                shift ;;
        esac
    done
    load_env
    if [ -n "$region" ]; then AWS_REGION="$region"; export AWS_REGION; fi
}

# Resolve TARGET to an instance ID in TARGET_ID. With no name given, picks the
# only server if there's exactly one.
require_target() {
    local names count
    if [ -z "$TARGET" ]; then
        names=$(list_server_names)
        count=$(wc -w <<< "$names")
        [ "$count" -gt 0 ] || die "No servers in ${AWS_REGION}."
        [ "$count" -eq 1 ] || die "Which server? Found: $(echo $names)"
        TARGET="$names"
    fi
    TARGET_ID=$(find_instance "$TARGET")
    [ -n "$TARGET_ID" ] || die "No server named '$TARGET' in ${AWS_REGION}."
    NAME="$TARGET"
    PROFILE=$(instance_field "$TARGET_ID" "Tags[?Key=='Profile']|[0].Value")
}

# Args: instance-id tty(yes|no) [remote command...]
ssh_to() {
    local id="$1" tty="$2" ip key_path
    shift 2
    ip=$(instance_field "$id" PublicIpAddress)
    [ "$ip" != "None" ] || die "'$NAME' has no public IP. Is it running? Try: bin/mc start $NAME"
    key_path=$(expand_home "$KEY_PATH")
    [ -f "$key_path" ] || die "SSH key not found: $KEY_PATH"
    # Instances come and go and AWS reuses IPs, so don't pin host keys.
    local opts=(-i "$key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    [ "$tty" = yes ] && opts+=(-t)
    ssh "${opts[@]}" "ubuntu@$ip" "$@"
}

cmd_list() {
    local rows
    parse_target "" "$@"
    rows=$(list_servers)
    if [ -z "$rows" ]; then
        echo "No servers in ${AWS_REGION}."
        return
    fi
    { printf 'NAME\tPROFILE\tSTATE\tTYPE\tIP\tLAUNCHED\n'; echo "$rows"; } | column -t -s $'\t'
}

cmd_ssh() {
    parse_target "" "$@"
    require_target
    ssh_to "$TARGET_ID" yes
}

cmd_console() {
    parse_target "" "$@"
    require_target
    ssh_to "$TARGET_ID" yes "screen -r mc || echo 'The server is not running. Start it with: bash $REMOTE_DIR/start.sh'"
}

cmd_logs() {
    parse_target "--game" "$@"
    require_target
    if [[ "$TARGET_FLAGS" == *--game* ]]; then
        ssh_to "$TARGET_ID" no "tail -n 50 -F $REMOTE_DIR/logs/latest.log"
    else
        ssh_to "$TARGET_ID" no "tail -n 50 -F /var/log/mc-setup.log"
    fi
}

cmd_newworld() {
    parse_target "" "$@"
    require_target
    confirm "Archive the current world on '$NAME' and start a new one? Players will be disconnected." || exit 0
    ssh_to "$TARGET_ID" no "bash $REMOTE_DIR/newworld.sh"
}

# Stream every world folder off the server as a tarball. Saving is paused
# while it runs so the files on disk are consistent.
backup_worlds() {
    local file
    mkdir -p "$REPO_ROOT/backups"
    file="$REPO_ROOT/backups/${NAME}_$(date +%Y%m%d_%H%M%S).tar.gz"
    info "Downloading worlds from '$NAME' to backups/${file##*/}..."
    if ssh_to "$1" no 'bash -s' > "$file" <<REMOTE
cd $REMOTE_DIR
if screen -list | grep -q '\.mc'; then
    screen -S mc -X stuff "save-off\$(printf '\r')save-all flush\$(printf '\r')"
    sleep 5
fi
tar czf - world*
status=\$?
screen -S mc -X stuff "save-on\$(printf '\r')" 2> /dev/null
exit \$status
REMOTE
    then
        ok "Saved $(du -h "$file" | cut -f1) to backups/${file##*/}."
    else
        rm -f "$file"
        return 1
    fi
}

cmd_backup() {
    parse_target "" "$@"
    require_target
    backup_worlds "$TARGET_ID" || die "Backup failed."
}

cmd_stop() {
    parse_target "" "$@"
    require_target
    info "Stopping '$NAME' (the server saves the world on shutdown)..."
    aws_cli ec2 stop-instances --instance-ids "$TARGET_ID" > /dev/null
    aws_cli ec2 wait instance-stopped --instance-ids "$TARGET_ID"
    ok "Stopped. Compute billing has stopped; the disk is still billed until 'bin/mc destroy $NAME'."
}

cmd_start() {
    parse_target "" "$@"
    require_target
    info "Starting '$NAME'..."
    aws_cli ec2 start-instances --instance-ids "$TARGET_ID" > /dev/null
    aws_cli ec2 wait instance-running --instance-ids "$TARGET_ID"
    wait_until_ready "$TARGET_ID" 300 "The server starts automatically on boot."
}

cmd_destroy() {
    local state reply
    parse_target "" "$@"
    [ -n "$TARGET" ] || die "Name the server to destroy: bin/mc destroy <name>"
    NAME="$TARGET"
    TARGET_ID=$(find_instance "$NAME")

    if [ -n "$TARGET_ID" ]; then
        state=$(instance_field "$TARGET_ID" State.Name)
        if [ "$state" = "running" ]; then
            if confirm "Download the worlds from '$NAME' before destroying it?"; then
                backup_worlds "$TARGET_ID" || die "Backup failed, so nothing was destroyed."
            fi
        else
            warn "'$NAME' is $state, so its worlds can't be downloaded. Run 'bin/mc start $NAME' first if you want them."
        fi

        read -r -p "This permanently deletes '$NAME' and its worlds. Type the name to confirm: " reply
        [ "$reply" = "$NAME" ] || die "Name didn't match; nothing was destroyed."

        cancel_spot_request "$TARGET_ID"
        info "Terminating $TARGET_ID..."
        aws_cli ec2 terminate-instances --instance-ids "$TARGET_ID" > /dev/null
        aws_cli ec2 wait instance-terminated --instance-ids "$TARGET_ID"
        ok "Terminated $TARGET_ID."
    else
        info "No instance named '$NAME'; cleaning up any leftover resources."
    fi

    release_elastic_ips "$NAME"
    delete_security_group "$NAME"
}

cmd_allow_ip() {
    local sg cidr
    parse_target "" "$@"
    # Allow `allow-ip 1.2.3.4/32` with the server name left out
    if [[ "$TARGET" == */* && -z "$TARGET_ARG" ]]; then
        TARGET_ARG="$TARGET"
        TARGET=""
    fi
    require_target
    if [ -n "$TARGET_ARG" ]; then cidr="$TARGET_ARG"; else SSH_CIDR=auto; cidr=$(resolve_ssh_cidr); fi
    [[ "$cidr" =~ ^[0-9.]+/[0-9]+$ ]] || die "Not a CIDR: $cidr (e.g. 1.2.3.4/32)"
    sg=$(instance_field "$TARGET_ID" 'SecurityGroups[0].GroupId')
    replace_ssh_rule "$sg" "$cidr"
    ok "SSH to '$NAME' is now allowed from $cidr only."
}
