#!/usr/bin/env bash

set -e

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
CONFIG_FILE="${BASE_DIR}/config.yml"
SINGBOX_FILE="${BASE_DIR}/singbox.json"
LOG_FILE="${BASE_DIR}/node.log"

CONTAINER_NAME="xboard-node"
IMAGE="ghcr.io/cedar2025/xboard-node"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    else
        error "Docker Compose is not installed."
        exit 1
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed."
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        error "Docker is not running or permission is denied."
        exit 1
    fi

    detect_compose
}

create_compose() {
    cat > "${COMPOSE_FILE}" <<EOF
services:
  xboard-node:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    network_mode: bridge

    command:
      - "-c"
      - "/etc/xboard-node/config.yml"

    ports:
      - "10000-10009:10000-10009"
      - "8443:8443/udp"

    volumes:
      - ./config.yml:/etc/xboard-node/config.yml
      - ./singbox.json:/etc/xboard-node/singbox.json
      - ./node.log:/etc/xboard-node/node.log

    environment:
      TZ: Asia/Shanghai

    restart: unless-stopped

    logging:
      driver: local
      options:
        max-size: 10m
        max-file: "3"
EOF

    success "docker-compose.yml created."
}

create_singbox() {
    cat > "${SINGBOX_FILE}" <<'EOF'
{
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "address": "1.1.1.1"
      }
    ],
    "strategy": "prefer_ipv4"
  }
}
EOF

    success "singbox.json created."
}

create_config() {
    local panel="$1"
    local machine_id="$2"
    local token="$3"

    panel="${panel%/}"

    cat > "${CONFIG_FILE}" <<EOF
panel:
  url: ${panel}

machine:
  machine_id: ${machine_id}
  token: ${token}

kernel:
  type: singbox

  custom_outbound:
    - type: direct
      tag: direct
      domain_resolver:
        server: cf
        strategy: prefer_ipv4

  custom_config: /etc/xboard-node/singbox.json

log:
  level: info
  output: /etc/xboard-node/node.log
EOF

    chmod 600 "${CONFIG_FILE}"

    success "config.yml created."
}

create_log() {
    if [ -d "${LOG_FILE}" ]; then
        warn "node.log is a directory. Removing it."
        rm -rf "${LOG_FILE}"
    fi

    if [ ! -f "${LOG_FILE}" ]; then
        touch "${LOG_FILE}"
    fi

    chmod 666 "${LOG_FILE}"
}

prepare_files() {
    [ -f "${COMPOSE_FILE}" ] || create_compose
    [ -f "${SINGBOX_FILE}" ] || create_singbox
    create_log
}

extract_arg() {
    local command="$1"
    local name="$2"

    echo "${command}" | sed -nE \
        "s/.*--${name}[=[:space:]]+['\"]?([^'\"[:space:]]+)['\"]?.*/\1/p"
}

parse_install_command() {
    local command="$1"

    PANEL_URL="$(extract_arg "${command}" "panel")"
    TOKEN="$(extract_arg "${command}" "token")"
    MACHINE_ID="$(extract_arg "${command}" "machine-id")"

    if [ -z "${PANEL_URL}" ]; then
        error "Unable to parse --panel."
        return 1
    fi

    if [ -z "${TOKEN}" ]; then
        error "Unable to parse --token."
        return 1
    fi

    if [ -z "${MACHINE_ID}" ]; then
        error "Unable to parse --machine-id."
        return 1
    fi
}

manual_config() {
    echo

    read -rp "Panel URL: " PANEL_URL
    read -rp "Machine ID: " MACHINE_ID
    read -rsp "Token: " TOKEN
    echo

    if [ -z "${PANEL_URL}" ]; then
        error "Panel URL is required."
        return 1
    fi

    if [ -z "${MACHINE_ID}" ]; then
        error "Machine ID is required."
        return 1
    fi

    if [ -z "${TOKEN}" ]; then
        error "Token is required."
        return 1
    fi
}

configure() {
    echo
    echo "Select configuration method:"
    echo
    echo "  1) Enter Panel URL, Machine ID and Token"
    echo "  2) Paste Xboard install command"
    echo

    read -rp "Select [1/2]: " choice

    case "${choice}" in
        1)
            manual_config
            ;;

        2)
            echo
            echo "Paste the Xboard install command:"
            read -r install_command

            if ! parse_install_command "${install_command}"; then
                exit 1
            fi

            echo
            info "Configuration parsed:"
            echo "Panel URL  : ${PANEL_URL}"
            echo "Machine ID : ${MACHINE_ID}"
            ;;

        *)
            error "Invalid option."
            exit 1
            ;;
    esac

    create_config \
        "${PANEL_URL}" \
        "${MACHINE_ID}" \
        "${TOKEN}"
}

init() {
    check_docker

    cd "${BASE_DIR}"

    info "Initializing Xboard-Node."

    create_compose
    create_singbox
    create_log

    if [ -n "${1:-}" ]; then
        info "Parsing Xboard install command."

        if ! parse_install_command "$1"; then
            exit 1
        fi

        create_config \
            "${PANEL_URL}" \
            "${MACHINE_ID}" \
            "${TOKEN}"
    else
        configure
    fi

    success "Initialization completed."

    start
}

start() {
    check_docker

    cd "${BASE_DIR}"

    prepare_files

    if [ ! -f "${CONFIG_FILE}" ]; then
        warn "config.yml not found."
        configure
    fi

    info "Starting ${CONTAINER_NAME}."

    ${COMPOSE} up -d

    success "Xboard-Node started."

    status
}

stop() {
    check_docker

    cd "${BASE_DIR}"

    info "Stopping ${CONTAINER_NAME}."

    ${COMPOSE} down

    success "Xboard-Node stopped."
}

restart() {
    check_docker

    cd "${BASE_DIR}"

    create_log

    info "Restarting ${CONTAINER_NAME}."

    ${COMPOSE} restart

    success "Xboard-Node restarted."
}

status() {
    check_docker

    echo

    docker ps -a \
        --filter "name=^/${CONTAINER_NAME}$" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    echo
}

logs() {
    if [ -f "${LOG_FILE}" ]; then
        tail -n 200 -f "${LOG_FILE}"
    else
        docker logs -f --tail 200 "${CONTAINER_NAME}"
    fi
}

shell() {
    check_docker

    if docker exec "${CONTAINER_NAME}" sh -c 'command -v bash' >/dev/null 2>&1; then
        docker exec -it "${CONTAINER_NAME}" bash
    else
        docker exec -it "${CONTAINER_NAME}" sh
    fi
}

clear() {
    check_docker

    cd "${BASE_DIR}"

    info "Stopping container."

    ${COMPOSE} down

    rm -rf "${LOG_FILE}"

    create_log

    info "Starting container."

    ${COMPOSE} up -d

    success "Log cleared and Xboard-Node restarted."
}

upgrade() {
    check_docker

    cd "${BASE_DIR}"

    info "Pulling latest image."

    ${COMPOSE} pull

    create_log

    info "Recreating container."

    ${COMPOSE} up -d --force-recreate

    success "Upgrade completed."

    status
}

show_help() {
    cat <<EOF

Xboard-Node Control Script

Usage:
  ./ctl.sh <command>

Commands:
  init      Initialize configuration and start
  config    Update node configuration
  start     Start
  stop      Stop
  restart   Restart
  status    Show status
  logs      Show logs
  shell     Enter container
  clear     Delete log and restart
  upgrade   Pull latest image and recreate
  help      Show help

Initialization:

  ./ctl.sh init

Direct install command:

  ./ctl.sh init "curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | sudo bash -s -- --mode machine --panel 'https://xboard.site.com' --token 'TOKEN' --machine-id 8"

EOF
}

case "${1:-}" in
    init)
        shift
        init "${*:-}"
        ;;

    config)
        configure
        ;;

    start)
        start
        ;;

    stop)
        stop
        ;;

    restart)
        restart
        ;;

    status)
        status
        ;;

    logs)
        logs
        ;;

    shell)
        shell
        ;;

    clear)
        clear
        ;;

    upgrade)
        upgrade
        ;;

    help|"")
        show_help
        ;;

    *)
        error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
