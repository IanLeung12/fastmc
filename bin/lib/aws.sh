#!/bin/bash
# Stage 3: AWS operations, one function per operation.
#
# Everything the launcher creates is tagged Project=lockoutserver, Name=<name>
# and Profile=<profile>; lookups go by tag, so AWS is the only state there is.

PROJECT_TAG="lockoutserver"
GAME_PORT=25565
LIVE_STATES="pending,running,stopping,stopped"

# Run the AWS CLI in the configured region. Strips the CRs the Windows build
# prints, and stops Git Bash rewriting /aws/... and /dev/... arguments.
aws_cli() {
    local out
    out=$(MSYS_NO_PATHCONV=1 aws --region "$AWS_REGION" "$@") || return $?
    if [ -n "$out" ]; then printf '%s\n' "${out//$'\r'/}"; fi
}

aws_preflight() {
    require_cmd aws "Install the AWS CLI v2: https://aws.amazon.com/cli/"
    aws_cli sts get-caller-identity --query Account --output text > /dev/null \
        || die "AWS credentials aren't working. Check AWS_PROFILE in .env, or run: aws configure${AWS_PROFILE:+ --profile $AWS_PROFILE}"
}

tag_list() {
    echo "{Key=Project,Value=${PROJECT_TAG}},{Key=Name,Value=${NAME}},{Key=Profile,Value=${PROFILE}}"
}

tag_spec() {
    echo "ResourceType=$1,Tags=[$(tag_list)]"
}

my_public_ip() {
    curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '\r\n ' \
        || die "Couldn't look up your public IP. Set SSH_CIDR in .env instead of 'auto'."
}

resolve_ssh_cidr() {
    if [ "$SSH_CIDR" = "auto" ]; then echo "$(my_public_ip)/32"; else echo "$SSH_CIDR"; fi
}

# Prints "<arch> <memory MiB>" for an instance type, e.g. "x86_64 8192".
instance_type_info() {
    local is_arm mem
    read -r is_arm mem <<< "$(aws_cli ec2 describe-instance-types --instance-types "$1" \
        --query "InstanceTypes[0].[contains(ProcessorInfo.SupportedArchitectures, 'arm64'), MemoryInfo.SizeInMiB]" \
        --output text)"
    [ -n "$mem" ] || die "Unknown instance type '$1' in ${AWS_REGION}."
    if [ "$is_arm" = "True" ]; then echo "arm64 $mem"; else echo "x86_64 $mem"; fi
}

# Latest Ubuntu 24.04 AMI for an architecture (x86_64 or arm64).
resolve_ami() {
    local arch="amd64"
    [ "$1" = "arm64" ] && arch="arm64"
    aws_cli ssm get-parameter \
        --name "/aws/service/canonical/ubuntu/server/24.04/stable/current/${arch}/hvm/ebs-gp3/ami-id" \
        --query Parameter.Value --output text
}

root_device_name() {
    aws_cli ec2 describe-images --image-ids "$1" --query 'Images[0].RootDeviceName' --output text
}

# Make sure KEY_NAME exists in this region and KEY_PATH holds its private key.
# Creates a new key pair, or imports an existing local key into a new region.
ensure_key_pair() {
    local key_path pub
    key_path=$(expand_home "$KEY_PATH")

    if aws_cli ec2 describe-key-pairs --key-names "$KEY_NAME" > /dev/null 2>&1; then
        [ -f "$key_path" ] || die "Key pair '$KEY_NAME' exists in ${AWS_REGION} but $KEY_PATH doesn't. Point KEY_PATH at its .pem, or pick a new KEY_NAME."
        return
    fi

    if [ -f "$key_path" ]; then
        info "Importing $KEY_PATH as key pair '$KEY_NAME' in ${AWS_REGION}..."
        pub=$(mktemp)
        ssh-keygen -y -f "$key_path" > "$pub" || die "Couldn't read the public key from $KEY_PATH."
        aws_cli ec2 import-key-pair --key-name "$KEY_NAME" \
            --public-key-material "fileb://$(native_path "$pub")" \
            --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" > /dev/null
        rm -f "$pub"
    else
        info "Creating key pair '$KEY_NAME', saving it to $KEY_PATH..."
        mkdir -p "$(dirname "$key_path")"
        aws_cli ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
            --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
            --query KeyMaterial --output text > "$key_path"
        protect_key "$key_path"
    fi
}

# Open a port; an already-open port is fine. Args: group-id protocol port cidr
sg_allow() {
    local err
    if ! err=$(aws_cli ec2 authorize-security-group-ingress --group-id "$1" \
            --ip-permissions "IpProtocol=$2,FromPort=$3,ToPort=$3,IpRanges=[{CidrIp=$4}]" 2>&1 > /dev/null); then
        [[ "$err" == *Duplicate* ]] || die "Couldn't open $2/$3 on $1: $err"
    fi
}

find_security_group() {
    local sg
    sg=$(aws_cli ec2 describe-security-groups \
        --filters "Name=group-name,Values=mc-$1" "Name=tag:Project,Values=${PROJECT_TAG}" \
        --query 'SecurityGroups[0].GroupId' --output text)
    [ "$sg" = "None" ] || echo "$sg"
}

# Find or create the server's security group (mc-<name>) and open the
# profile's ports to everyone and SSH to $1. Prints the group ID.
ensure_security_group() {
    local ssh_cidr="$1" sg p
    sg=$(find_security_group "$NAME")
    if [ -z "$sg" ]; then
        sg=$(aws_cli ec2 create-security-group --group-name "mc-${NAME}" \
            --description "Minecraft server ${NAME} (lockoutserver)" \
            --tag-specifications "$(tag_spec security-group)" \
            --query GroupId --output text)
    fi
    for p in $PORTS; do
        sg_allow "$sg" "${p%%:*}" "${p#*:}" "0.0.0.0/0"
    done
    sg_allow "$sg" tcp 22 "$ssh_cidr"
    echo "$sg"
}

# Replace every SSH rule on a group with one for $2.
replace_ssh_rule() {
    local rules
    rules=$(aws_cli ec2 describe-security-group-rules --filters "Name=group-id,Values=$1" \
        --query 'SecurityGroupRules[?FromPort==`22` && !IsEgress].SecurityGroupRuleId' --output text)
    if [ -n "$rules" ]; then
        # shellcheck disable=SC2086
        aws_cli ec2 revoke-security-group-ingress --group-id "$1" --security-group-rule-ids $rules > /dev/null
    fi
    sg_allow "$1" tcp 22 "$2"
}

# Security groups can't be deleted until the terminated instance's network
# interface is gone, which lags termination a little.
delete_security_group() {
    local sg
    sg=$(find_security_group "$1")
    [ -n "$sg" ] || return 0
    for _ in {1..10}; do
        if aws_cli ec2 delete-security-group --group-id "$sg" 2> /dev/null; then
            ok "Deleted security group $sg."
            return 0
        fi
        sleep 6
    done
    warn "Couldn't delete security group $sg yet. Run 'mc destroy $1' again later to clean it up."
}

# Instance ID for a server name, or empty. Ignores terminated instances.
find_instance() {
    local ids
    ids=$(aws_cli ec2 describe-instances \
        --filters "Name=tag:Project,Values=${PROJECT_TAG}" "Name=tag:Name,Values=$1" \
                  "Name=instance-state-name,Values=${LIVE_STATES}" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
    [ "$(wc -w <<< "$ids")" -le 1 ] || die "More than one instance is tagged Name=$1: $ids"
    echo "$ids"
}

list_server_names() {
    aws_cli ec2 describe-instances \
        --filters "Name=tag:Project,Values=${PROJECT_TAG}" "Name=instance-state-name,Values=${LIVE_STATES}" \
        --query "Reservations[].Instances[].Tags[?Key=='Name'].Value" --output text
}

# Name, profile, state, type, IP and launch time of every server, one per line.
list_servers() {
    aws_cli ec2 describe-instances \
        --filters "Name=tag:Project,Values=${PROJECT_TAG}" "Name=instance-state-name,Values=${LIVE_STATES}" \
        --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value, Tags[?Key=='Profile']|[0].Value, State.Name, InstanceType, PublicIpAddress, LaunchTime]" \
        --output text
}

# One field of an instance, e.g. instance_field i-123 State.Name
instance_field() {
    aws_cli ec2 describe-instances --instance-ids "$1" \
        --query "Reservations[0].Instances[0].$2" --output text
}

# Args: ami security-group user-data-file root-device. Prints the instance ID.
run_instance() {
    local args=(
        --image-id "$1"
        --instance-type "$INSTANCE_TYPE"
        --key-name "$KEY_NAME"
        --security-group-ids "$2"
        --user-data "fileb://$(native_path "$3")"
        --block-device-mappings "DeviceName=$4,Ebs={VolumeSize=${DISK_GB},VolumeType=gp3,DeleteOnTermination=true}"
        --metadata-options "HttpTokens=required"
        --tag-specifications "$(tag_spec instance)" "$(tag_spec volume)"
        --count 1
        --query 'Instances[0].InstanceId' --output text
    )
    if [ "$SPOT" = "true" ]; then
        # Persistent + stop, so a spot server can be stopped/started like any other
        args+=(--instance-market-options "MarketType=spot,SpotOptions={SpotInstanceType=persistent,InstanceInterruptionBehavior=stop}")
    fi
    aws_cli ec2 run-instances "${args[@]}"
}

attach_elastic_ip() {
    local alloc
    alloc=$(aws_cli ec2 allocate-address --domain vpc \
        --tag-specifications "$(tag_spec elastic-ip)" --query AllocationId --output text)
    aws_cli ec2 associate-address --instance-id "$1" --allocation-id "$alloc" > /dev/null
}

release_elastic_ips() {
    local alloc
    for alloc in $(aws_cli ec2 describe-addresses \
            --filters "Name=tag:Project,Values=${PROJECT_TAG}" "Name=tag:Name,Values=$1" \
            --query 'Addresses[].AllocationId' --output text); do
        aws_cli ec2 release-address --allocation-id "$alloc"
        ok "Released Elastic IP $alloc."
    done
}

# A persistent spot request relaunches its instance unless it's cancelled first.
cancel_spot_request() {
    local sir
    sir=$(instance_field "$1" SpotInstanceRequestId)
    if [ -n "$sir" ] && [ "$sir" != "None" ]; then
        aws_cli ec2 cancel-spot-instance-requests --spot-instance-request-ids "$sir" > /dev/null
        ok "Cancelled spot request $sir."
    fi
}

port_open() {
    timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2> /dev/null
}

# Args: ip port timeout-seconds. Prints a dot every 10 seconds.
wait_for_port() {
    local start=$SECONDS
    while [ $((SECONDS - start)) -lt "$3" ]; do
        if port_open "$1" "$2"; then
            echo >&2
            return 0
        fi
        printf '.' >&2
        sleep 10
    done
    echo >&2
    return 1
}
