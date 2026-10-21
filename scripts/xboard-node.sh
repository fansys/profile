#!/bin/sh
# Xboard-Node: Alpine/OpenRC, Debian/Ubuntu/CentOS/systemd; native or Docker Compose.
# Quick install: curl -fsSL https://raw.githubusercontent.com/fansys/profile/master/scripts/xboard-node.sh | sh
set -eu
umask 077

APP_DIR=/etc/xboard-node
CONFIG=$APP_DIR/config.yml
SINGBOX=$APP_DIR/singbox.json
COMPOSE=$APP_DIR/compose.yml
PROGRAM=/usr/local/bin/xboard-node
IMAGE=ghcr.io/cedar2025/xboard-node:latest
RELEASES=https://github.com/cedar2025/Xboard-Node/releases

mode=${MODE:-}
backend=${BACKEND:-}
panel_url=${PANEL:-}
token=${TOKEN:-}
node_id=${NODE_ID:-}
machine_id=${MACHINE_ID:-}
kernel=${KERNEL:-singbox}
version=${VERSION:-latest}
local_binary=${BINARY:-}
mem_limit=${GOMEMLIMIT:-96MiB}
gc_percent=${GOGC:-50}
cf_dns=${CF_DNS:-no}
action=install
paste_command=

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

help() {
    cat <<'EOF'
Xboard-Node Manager
Supported: Alpine (OpenRC), Debian / Ubuntu / CentOS (systemd)

Usage:
  sh install-xboard-node.sh [install|config|start|stop|restart|status|logs|shell|clear|upgrade|uninstall] [options]

Options:
  --backend native|docker       Native is recommended for tiny VPS
  --mode node|machine
  --panel URL                   Panel URL
  --token TOKEN                 Panel token (interactive entry is safer)
  --node-id ID                  Node mode ID
  --machine-id ID               Machine mode ID
  --kernel singbox|xray         Default singbox
  --from-command 'COMMAND'      Parse an Xboard installation command
  --version TAG                 Native release tag, default latest
  --binary PATH                 Install local native binary
  --gomemlimit SIZE             Default 96MiB
  --gogc NUMBER                 Default 50
  --cf-dns yes|no               Optional Cloudflare DNS and direct outbound

Examples:
  sh install-xboard-node.sh
  sh install-xboard-node.sh --backend native --mode node --panel https://panel.example --node-id 1
  sh install-xboard-node.sh --backend docker --mode machine --machine-id 1
  sh install-xboard-node.sh status
  sh install-xboard-node.sh logs

Docker is optional and must already be installed. Config is kept on uninstall.
EOF
}

parse_args() {
    case "${1:-}" in
        install|config|start|stop|restart|status|logs|shell|clear|upgrade|uninstall)
            action=$1; shift ;;
        help|--help|-h) help; exit 0 ;;
    esac
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --backend|--mode|--panel|--token|--node-id|--machine-id|--kernel|--version|--binary|--gomemlimit|--gogc|--cf-dns|--from-command)
                [ "$#" -ge 2 ] || fail "Missing value for $1"
                case "$1" in
                    --backend) backend=$2 ;; --mode) mode=$2 ;;
                    --panel) panel_url=$2 ;; --token) token=$2 ;;
                    --node-id) node_id=$2 ;; --machine-id) machine_id=$2 ;;
                    --kernel) kernel=$2 ;; --version) version=$2 ;;
                    --binary) local_binary=$2 ;; --gomemlimit) mem_limit=$2 ;;
                    --gogc) gc_percent=$2 ;; --cf-dns) cf_dns=$2 ;; --from-command) paste_command=$2 ;;
                esac
                shift 2 ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
}

detect_os() {
    [ "$(id -u)" -eq 0 ] || fail 'Run as root'
    [ -r /etc/os-release ] || fail 'Cannot detect OS'
    . /etc/os-release
    case "$ID" in
        alpine)
            service=openrc
            package_manager=apk
            ;;
        debian|ubuntu)
            service=systemd
            package_manager=apt
            ;;
        centos)
            service=systemd
            if command -v dnf >/dev/null 2>&1; then
                package_manager=dnf
            elif command -v yum >/dev/null 2>&1; then
                package_manager=yum
            else
                fail 'Neither dnf nor yum is available on CentOS'
            fi
            ;;
        *) fail 'Supported systems: Alpine, Debian, Ubuntu and CentOS' ;;
    esac
    if [ "$service" = systemd ]; then
        [ -d /run/systemd/system ] || fail "systemd is required on $ID"
        command -v systemctl >/dev/null 2>&1 || fail 'systemctl is missing'
    fi
    case "$(uname -m)" in
        x86_64) arch=amd64 ;; aarch64) arch=arm64 ;;
        *) fail 'Only amd64 and arm64 binaries are supported' ;;
    esac
}

# Never read interactive input from stdin: it may contain the piped script.
ask() {
    prompt=$1
    current=$2
    hidden=${3:-no}
    answer=$current
    [ -z "$answer" ] || return 0
    [ -r /dev/tty ] || fail "Missing $prompt (supply command-line flags)"
    echo -n "$prompt: " > /dev/tty
    if [ "$hidden" = yes ]; then
        stty -echo < /dev/tty
        trap 'stty echo < /dev/tty 2>/dev/null || :; cleanup' EXIT
    fi
    IFS= read -r answer < /dev/tty || answer=
    if [ "$hidden" = yes ]; then
        stty echo < /dev/tty
        echo > /dev/tty
        trap cleanup EXIT
    fi
}

# Extract straightforward --flag value, --flag=value and single/double-quoted values.
# This does NOT evaluate or execute the pasted shell command.
command_value() {
    key=$1
    line=$2
    result=$(echo "$line" | sed -n "s/.*--${key}[= ][[:space:]]*'\([^']*\)'.*/\1/p")
    [ -z "$result" ] || { echo "$result"; return; }
    result=$(echo "$line" | sed -n "s/.*--${key}[= ][[:space:]]*\"\([^\"]*\)\".*/\1/p")
    [ -z "$result" ] || { echo "$result"; return; }
    echo "$line" | sed -n "s/.*--${key}[= ][[:space:]]*\([^[:space:]'\"]*\).*/\1/p"
}

parse_pasted_command() {
    [ -n "$paste_command" ] || return 0
    panel_url=$(command_value panel "$paste_command")
    token=$(command_value token "$paste_command")
    machine_id=$(command_value machine-id "$paste_command")
    node_id=$(command_value node-id "$paste_command")
    case "$paste_command" in
        *'--mode machine'*) mode=machine ;;
        *'--mode node'*) mode=node ;;
        *) [ -z "$machine_id" ] || mode=machine ;;
    esac
    [ -n "$panel_url" ] && [ -n "$token" ] || fail 'Pasted command is missing --panel or --token'
}

collect_settings() {
    if [ -z "$backend" ]; then
        echo
        echo 'Deployment: 1) Native (low memory)   2) Docker Compose'
        ask 'Select 1/2 [1]' ''
        case "${answer:-1}" in 1) backend=native ;; 2) backend=docker ;; *) fail 'Invalid deployment' ;; esac
    fi

    if [ -z "$paste_command" ] && [ -z "$panel_url" ] && [ -r /dev/tty ]; then
        echo
        echo 'Configuration: 1) Manual entry   2) Paste Xboard install command'
        ask 'Select 1/2 [1]' ''
        if [ "${answer:-1}" = 2 ]; then
            ask 'Paste install command' ''
            paste_command=$answer
        fi
    fi
    parse_pasted_command

    ask 'Mode [node/machine] (default node)' "$mode"
    mode=${answer:-node}
    ask 'Panel URL' "$panel_url"
    panel_url=${answer%/}
    ask 'Token' "$token" yes
    token=$answer
    if [ "$mode" = machine ]; then
        ask 'Machine ID' "$machine_id"
        machine_id=$answer
        binding_id=$machine_id
    else
        ask 'Node ID' "$node_id"
        node_id=$answer
        binding_id=$node_id
    fi
}

validate_settings() {
    case "$backend" in native|docker) : ;; *) fail 'Invalid backend' ;; esac
    case "$mode" in node|machine) : ;; *) fail 'Invalid mode' ;; esac
    case "$panel_url" in https://*|http://*) : ;; *) fail 'Invalid panel URL' ;; esac
    case "$panel_url" in *[[:space:]]*) fail 'Spaces not allowed in panel URL' ;; esac
    [ -n "$token" ] || fail 'Token is required'
    case "$binding_id" in ''|*[!0-9]*) fail 'ID must be numeric' ;; esac
    [ "$binding_id" -gt 0 ] 2>/dev/null || fail 'ID must be positive'
    case "$kernel" in singbox|xray) : ;; *) fail 'Invalid kernel' ;; esac
    case "$mem_limit" in ''|*[!0-9A-Za-z]*) fail 'Invalid memory limit' ;; esac
    case "$gc_percent" in ''|*[!0-9]*) fail 'Invalid GOGC value' ;; esac
    case "$cf_dns" in yes|no) : ;; *) fail "--cf-dns must be yes or no" ;; esac
    case "$version" in ''|*[!0-9A-Za-z._-]*) fail 'Invalid version' ;; esac
}

yaml_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

confirm_replace() {
    [ -e "$CONFIG" ] || return 0
    [ -r /dev/tty ] || fail 'Config exists: run interactively to confirm replacement'
    ask 'Overwrite existing configuration? [y/N]' ''
    case "$answer" in y|Y|yes) : ;; *) fail 'Cancelled' ;; esac
}

write_config() {
    mkdir -p "$APP_DIR"
    chmod 700 "$APP_DIR"
    next_config=$APP_DIR/.config.yml.new
    url=$(yaml_quote "$panel_url")
    secret=$(yaml_quote "$token")

    if [ "$mode" = machine ]; then
        cat > "$next_config" <<EOF
panel:
  url: $url

machine:
  machine_id: $binding_id
  token: $secret
EOF
    else
        cat > "$next_config" <<EOF
panel:
  url: $url
  token: $secret
  node_id: $binding_id
EOF
    fi

    cat >> "$next_config" <<EOF

kernel:
  type: $kernel
  log_level: error
EOF
    if [ "$kernel" = singbox ]; then
        if [ "$cf_dns" = yes ]; then
            cat > "$SINGBOX" <<'EOF'
{
  "dns": {
    "servers": [{"tag": "cf", "address": "1.1.1.1"}],
    "strategy": "prefer_ipv4"
  }
}
EOF
            cat >> "$next_config" <<'EOF'
  custom_outbound:
    - type: direct
      tag: direct
      domain_resolver:
        server: cf
        strategy: prefer_ipv4
EOF
        else
            [ -f "$SINGBOX" ] || echo '{}' > "$SINGBOX"
        fi
        echo '  custom_config: /etc/xboard-node/singbox.json' >> "$next_config"
    fi
    cat >> "$next_config" <<EOF

log:
  level: error
  output: stdout

runtime:
  gomemlimit: $(yaml_quote "$mem_limit")
  gogc: $gc_percent

health_port: 0
EOF
    chmod 600 "$next_config"
    mv -f "$next_config" "$CONFIG"
    next_config=
    info "Config written to $CONFIG"
}

ensure_downloader() {
    command -v curl >/dev/null 2>&1 && return
    command -v wget >/dev/null 2>&1 && return
    case "$package_manager" in
        apk)
            apk add --no-cache curl ca-certificates
            ;;
        apt)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates
            ;;
        dnf)
            dnf install -y curl ca-certificates
            ;;
        yum)
            yum install -y curl ca-certificates
            ;;
    esac
}

install_binary() {
    ensure_downloader
    mkdir -p /usr/local/bin
    temp_binary=$(mktemp /usr/local/bin/.xboard-node.XXXXXX)
    if [ -n "$local_binary" ]; then
        cp "$local_binary" "$temp_binary"
    else
        if [ "$version" = latest ]; then
            url=$RELEASES/latest/download/xboard-node-linux-$arch
        else
            url=$RELEASES/download/$version/xboard-node-linux-$arch
        fi
        info "Downloading native binary ($arch)"
        if command -v curl >/dev/null 2>&1; then
            curl -fLsS --retry 2 -o "$temp_binary" "$url" || fail 'Binary download failed'
        else
            wget -q -O "$temp_binary" "$url" || fail 'Binary download failed'
        fi
    fi
    chmod 755 "$temp_binary"
    "$temp_binary" --help >/dev/null 2>&1 || fail 'Downloaded binary cannot execute'
    native_stop || :
    mv -f "$temp_binary" "$PROGRAM"
    temp_binary=
}

write_native_service() {
    if [ "$service" = openrc ]; then
        cat > /etc/init.d/xboard-node <<'EOF'
#!/sbin/openrc-run
name="xboard-node"
description="Xboard-Node"
command="/usr/local/bin/xboard-node"
command_args="-c /etc/xboard-node/config.yml"
directory="/etc/xboard-node"
command_background=true
pidfile="/run/xboard-node.pid"
output_log="/dev/null"
error_log="/dev/null"
depend() { need net; }
EOF
        chmod 755 /etc/init.d/xboard-node
        rc-update add xboard-node default >/dev/null
    else
        cat > /etc/systemd/system/xboard-node.service <<'EOF'
[Unit]
Description=Xboard-Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/etc/xboard-node
ExecStart=/usr/local/bin/xboard-node -c /etc/xboard-node/config.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xboard-node >/dev/null
    fi
}

native_start() {
    if [ "$service" = openrc ]; then rc-service xboard-node start; else systemctl start xboard-node; fi
}
native_stop() {
    if [ "$service" = openrc ]; then rc-service xboard-node stop; else systemctl stop xboard-node; fi
}
native_restart() {
    if [ "$service" = openrc ]; then rc-service xboard-node restart; else systemctl restart xboard-node; fi
}
native_status() {
    if [ "$service" = openrc ]; then rc-service xboard-node status; else systemctl --no-pager status xboard-node; fi
}
native_logs() {
    if [ "$service" = openrc ]; then
        warn 'Native OpenRC logs are disabled to conserve disk; check process/status'
        native_status
    else
        journalctl -u xboard-node -n 100 --no-pager
    fi
}

check_docker() {
    command -v docker >/dev/null 2>&1 || fail 'Docker is not installed'
    docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable'
    if docker compose version >/dev/null 2>&1; then
        compose_tool=plugin
    elif command -v docker-compose >/dev/null 2>&1; then
        compose_tool=legacy
    else
        fail 'Docker Compose is not installed'
    fi
}

compose() {
    if [ "$compose_tool" = plugin ]; then
        docker compose -f "$COMPOSE" "$@"
    else
        docker-compose -f "$COMPOSE" "$@"
    fi
}

write_compose() {
    # Host networking avoids incorrect fixed port maps for panel-managed nodes.
    cat > "$COMPOSE" <<EOF
services:
  xboard-node:
    image: $IMAGE
    container_name: xboard-node
    network_mode: host
    command: ["-c", "/etc/xboard-node/config.yml"]
    volumes:
      - /etc/xboard-node/config.yml:/etc/xboard-node/config.yml:ro
      - /etc/xboard-node/singbox.json:/etc/xboard-node/singbox.json:ro
    environment:
      TZ: UTC
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "1m"
        max-file: "1"
EOF
    chmod 600 "$COMPOSE"
}

ensure_docker_files() {
    [ -f "$CONFIG" ] || fail "Missing config: $CONFIG (run install first)"
    [ -f "$SINGBOX" ] || echo '{}' > "$SINGBOX"
    [ -f "$COMPOSE" ] || write_compose
}

read_backend() {
    [ -f "$COMPOSE" ] && { backend=docker; return; }
    [ -e /etc/init.d/xboard-node ] && { backend=native; return; }
    [ -e /etc/systemd/system/xboard-node.service ] && { backend=native; return; }
    fail 'No installation detected; run install first'
}

install() {
    collect_settings
    validate_settings
    confirm_replace
    if [ "$backend" = docker ]; then
        check_docker
        mkdir -p "$APP_DIR"
        [ -f "$SINGBOX" ] || echo '{}' > "$SINGBOX"
        write_config
        write_compose
        compose up -d
    else
        # Download before overwriting config or service.
        ensure_downloader
        install_binary
        write_config
        write_native_service
        native_start
    fi
    info "Installed: $backend / $mode / $kernel"
    info 'Subscription links remain on the Xboard panel'
}

manage() {
    read_backend
    if [ "$backend" = docker ]; then
        check_docker
        ensure_docker_files
        case "$action" in
            start) compose up -d ;;
            stop) compose down ;;
            restart) compose up -d --force-recreate ;;
            status) compose ps ;;
            logs) compose logs --tail 100 -f ;;
            shell) docker exec -it xboard-node sh ;;
            clear) compose down; compose up -d; warn 'Docker logs are rotated; old logs may remain until container is recreated' ;;
            upgrade) compose pull; compose up -d --force-recreate ;;
        esac
    else
        case "$action" in
            start) native_start ;; stop) native_stop ;; restart) native_restart ;;
            status) native_status ;; logs) native_logs ;;
            shell) fail 'Shell is only supported in Docker mode' ;;
            clear) warn 'No persistent OpenRC log; systemd logs are managed by journald' ;;
            upgrade) fail 'For native upgrades, run install again with the desired --version' ;;
        esac
    fi
}

uninstall() {
    read_backend
    if [ "$backend" = docker ]; then
        check_docker
        compose down
        rm -f "$COMPOSE"
    else
        native_stop || :
        if [ "$service" = openrc ]; then
            rc-update del xboard-node default 2>/dev/null || :
            rm -f /etc/init.d/xboard-node
        else
            systemctl disable xboard-node 2>/dev/null || :
            rm -f /etc/systemd/system/xboard-node.service
            systemctl daemon-reload
        fi
        rm -f "$PROGRAM"
    fi
    info "Uninstalled service; configuration retained at $CONFIG"
}

cleanup() {
    [ -z "${temp_binary:-}" ] || rm -f "$temp_binary"
    [ -z "${next_config:-}" ] || rm -f "$next_config"
}

main() {
    parse_args "$@"
    detect_os
    case "$action" in
        install) install ;;
        config)
            read_backend
            collect_settings
            validate_settings
            confirm_replace
            write_config
            if [ "$backend" = docker ]; then
                check_docker; ensure_docker_files; compose up -d --force-recreate
            else
                native_restart
            fi ;;
        uninstall) uninstall ;;
        *) manage ;;
    esac
}

trap cleanup EXIT
main "$@"
