#!/bin/sh
# Shadowsocks-Rust 多发行版安装脚本
# 支持 Alpine、Ubuntu、Debian、CentOS、Rocky、AlmaLinux/systemd
# curl -fsSL https://raw.githubusercontent.com/fansys/profile/master/scripts/shadowsocks.sh | sh
# 下载后执行（适合检查脚本后再运行）：
# curl -fsSL https://raw.githubusercontent.com/fansys/profile/master/scripts/shadowsocks.sh -o shadowsocks.sh && sh shadowsocks.sh
set -eu

SERVICE_NAME=shadowsocks
CONFIG_DIR=/etc/shadowsocks
CONFIG_FILE=$CONFIG_DIR/config.json
BIN=/usr/local/bin/ssserver
REPO_API=https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest
DEFAULT_PORT=8388
VERSION=2610301620

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die '请以 root 身份运行'
[ -r /etc/os-release ] || die '无法识别 Linux 发行版（缺少 /etc/os-release）'
. /etc/os-release
OS_ID=${ID:-unknown}
OS_LIKE=${ID_LIKE:-}
case "$OS_ID" in
    alpine)
        FAMILY=alpine
        PKG=apk
        SERVICE_FILE=/etc/init.d/${SERVICE_NAME}
        ;;
    ubuntu|debian)
        FAMILY=debian
        PKG=apt-get
        SERVICE_FILE=/etc/systemd/system/$SERVICE_NAME.service
        ;;
    centos|rhel|rocky|almalinux|ol|fedora)
        FAMILY=rhel
        if command -v dnf >/dev/null 2>&1; then
            PKG=dnf
        elif command -v yum >/dev/null 2>&1; then
            PKG=yum
        else
            die '未找到 dnf 或 yum'
        fi
        SERVICE_FILE=/etc/systemd/system/$SERVICE_NAME.service
        ;;
    *)
        case " $OS_LIKE " in
            *' debian '*) FAMILY=debian; PKG=apt-get; SERVICE_FILE=/etc/systemd/system/$SERVICE_NAME.service ;;
            *' rhel '*|*' fedora '*)
                FAMILY=rhel
                if command -v dnf >/dev/null 2>&1; then PKG=dnf
                elif command -v yum >/dev/null 2>&1; then PKG=yum
                else die '未找到 dnf 或 yum'; fi
                SERVICE_FILE=/etc/systemd/system/$SERVICE_NAME.service
                ;;
            *) die "不支持的发行版：$OS_ID" ;;
        esac
        ;;
esac

if [ "$FAMILY" = alpine ]; then
    command -v rc-service >/dev/null 2>&1 || die '未找到 OpenRC (rc-service)'
else
    command -v systemctl >/dev/null 2>&1 || die '未找到 systemd (systemctl)'
    [ -d /run/systemd/system ] || die '当前环境未运行 systemd，无法安装 systemd 服务'
fi

case "$(uname -m)" in
    x86_64|amd64) TARGET=x86_64-unknown-linux-musl ;;
    aarch64|arm64) TARGET=aarch64-unknown-linux-musl ;;
    *) die "不支持的 CPU 架构：$(uname -m)（当前脚本支持 x86_64/aarch64）" ;;
esac

info "操作系统：${PRETTY_NAME:-$OS_ID}；架构：$TARGET；服务管理：$(if [ "$FAMILY" = alpine ]; then printf OpenRC; else printf systemd; fi)"
info '安装依赖...'
case "$FAMILY" in
    alpine)
        apk add --no-cache curl ca-certificates xz openssl jq coreutils tar findutils >/dev/null
        ;;
    debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends curl ca-certificates xz-utils openssl jq coreutils tar findutils >/dev/null
        ;;
    rhel)
        "$PKG" install -y curl ca-certificates xz openssl jq coreutils tar findutils >/dev/null
        ;;
esac

# /dev/tty 单独读取交互输入，支持 curl | sh。
INTERACTIVE=0
if [ -r /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
    exec 3</dev/tty
    INTERACTIVE=1
else
    exec 3</dev/null
fi
ask() {
    ANSWER=''
    printf '%s' "$1" >&2
    if [ "$INTERACTIVE" -eq 1 ]; then
        IFS= read -r ANSWER <&3 || ANSWER=''
    else
        printf '\n' >&2
    fi
}

printf '\n========== Shadowsocks 配置 ==========\n\n'
while :; do
    ask "端口 [$DEFAULT_PORT]: "
    PORT=${ANSWER:-$DEFAULT_PORT}
    case "$PORT" in ''|*[!0-9]*) warn '端口必须为数字'; continue ;; esac
    [ "${#PORT}" -le 5 ] || { warn '端口范围为 1-65535'; continue; }
    PORT=$(printf '%s' "$PORT" | sed 's/^0*//')
    PORT=${PORT:-0}
    if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then break; fi
    warn '端口范围为 1-65535'
done

printf '\n可选加密算法：\n'
printf '  1) 2022-blake3-aes-128-gcm (默认)\n'
printf '  2) 2022-blake3-aes-256-gcm\n'
printf '  3) 2022-blake3-chacha20-poly1305\n'
printf '  4) aes-256-gcm\n'
printf '  5) aes-128-gcm\n'
printf '  6) chacha20-ietf-poly1305\n\n'
while :; do
    ask '选择 [1]: '
    case "${ANSWER:-1}" in
        1) METHOD=2022-blake3-aes-128-gcm; KEY_BYTES=16; break ;;
        2) METHOD=2022-blake3-aes-256-gcm; KEY_BYTES=32; break ;;
        3) METHOD=2022-blake3-chacha20-poly1305; KEY_BYTES=32; break ;;
        4) METHOD=aes-256-gcm; KEY_BYTES=0; break ;;
        5) METHOD=aes-128-gcm; KEY_BYTES=0; break ;;
        6) METHOD=chacha20-ietf-poly1305; KEY_BYTES=0; break ;;
        *) warn '无效选项，请重试' ;;
    esac
done

valid_2022_key() {
    # 先检查解码后字节数，再要求规范 Base64 编码完全一致。
    decoded=$(printf '%s' "$1" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]')
    [ "$decoded" = "$KEY_BYTES" ] || return 1
    normalized=$(printf '%s' "$1" | openssl base64 -d -A 2>/dev/null | openssl base64 -A 2>/dev/null)
    [ "$normalized" = "$1" ]
}

printf '\n'
while :; do
    if [ "$KEY_BYTES" -gt 0 ]; then
        printf '此算法要求 %s 字节随机密钥的 Base64 编码\n' "$KEY_BYTES"
    fi
    ask '密码/密钥 [回车自动生成]: '
    PASSWORD=$ANSWER
    if [ -z "$PASSWORD" ]; then
        if [ "$KEY_BYTES" -gt 0 ]; then
            PASSWORD=$(openssl rand -base64 "$KEY_BYTES" | tr -d '\n')
        else
            PASSWORD=$(openssl rand -hex 24)
        fi
    fi
    if [ "$KEY_BYTES" -eq 0 ] || valid_2022_key "$PASSWORD"; then break; fi
    warn '2022 密钥不符合长度/Base64 格式，请重试'
done

printf '\n端口：%s\n加密：%s\n密码/密钥：%s\nTCP/UDP：均启用\n开机自启：开启\n\n' "$PORT" "$METHOD" "$PASSWORD"

info '查询 GitHub 官方最新稳定版及构建资源...'
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
trap 'exit 1' HUP INT TERM
curl -fsSL --retry 3 --connect-timeout 15 "$REPO_API" -o "$WORKDIR/release.json" || die '查询 GitHub Releases 失败'
VERSION=$(jq -r '.tag_name // empty' "$WORKDIR/release.json")
[ -n "$VERSION" ] || die '无法解析发布版本'
ASSET=$(jq -r --arg target "$TARGET" '[.assets[].name | select(endswith("." + $target + ".tar.xz"))] | first // empty' "$WORKDIR/release.json")
[ -n "$ASSET" ] || die "官方发布版本 $VERSION 未提供 $TARGET 的安装包"
DOWNLOAD_URL=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .browser_download_url' "$WORKDIR/release.json")
CHECK_URL=$(jq -r --arg asset "$ASSET.sha256" '.assets[] | select(.name == $asset) | .browser_download_url' "$WORKDIR/release.json")
[ -n "$DOWNLOAD_URL" ] && [ -n "$CHECK_URL" ] || die '未找到安装包下载地址或 SHA256 校验文件'

info "下载 $VERSION ($TARGET)..."
curl -fL --retry 3 --connect-timeout 15 "$DOWNLOAD_URL" -o "$WORKDIR/$ASSET" || die '安装包下载失败'
curl -fL --retry 3 --connect-timeout 15 "$CHECK_URL" -o "$WORKDIR/checksum" || die 'SHA256 校验文件下载失败'
EXPECTED=$(awk 'NR==1 {print $1}' "$WORKDIR/checksum")
ACTUAL=$(sha256sum "$WORKDIR/$ASSET" | awk '{print $1}')
[ "${#EXPECTED}" -eq 64 ] && [ "$EXPECTED" = "$ACTUAL" ] || die 'SHA256 校验失败'

mkdir -p "$WORKDIR/unpack"
tar -xJf "$WORKDIR/$ASSET" -C "$WORKDIR/unpack" || die '解压失败'
SERVER=$(find "$WORKDIR/unpack" -type f -name ssserver -print -quit)
[ -n "$SERVER" ] || die '安装包中未找到 ssserver'
chmod 755 "$SERVER"
"$SERVER" --version >/dev/null 2>&1 || die '下载的二进制程序无法在当前系统执行'

jq -n --arg server '0.0.0.0' --argjson port "$PORT" \
    --arg method "$METHOD" --arg password "$PASSWORD" \
    '{server:$server, server_port:$port, method:$method, password:$password, mode:"tcp_and_udp"}' \
    > "$WORKDIR/config.json" || die '生成配置失败'
chmod 600 "$WORKDIR/config.json"

if [ "$FAMILY" = alpine ]; then
    cat > "$WORKDIR/service" <<'EOF'
#!/sbin/openrc-run
name="shadowsocks"
description="Shadowsocks-Rust Server"
supervisor="supervise-daemon"
command="/usr/local/bin/ssserver"
command_args="-c /etc/shadowsocks/config.json"
respawn_delay=5
respawn_max=0
depend() {
    need net
}
EOF
else
    cat > "$WORKDIR/service" <<'EOF'
[Unit]
Description=Shadowsocks-Rust Server
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
fi

# 备份已有文件后覆盖，保留原文件权限由 install 设置。
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
if [ "$FAMILY" = alpine ]; then
    if [ -f "$SERVICE_FILE" ]; then
        info '停止已有 OpenRC 服务...'
        rc-service "${SERVICE_NAME}" stop || true
    fi
else
    if [ -f "$SERVICE_FILE" ]; then
        info '停止已有 systemd 服务...'
        systemctl stop "${SERVICE_NAME}" || true
    fi
fi
[ ! -f "$CONFIG_FILE" ] || cp -p "$CONFIG_FILE" "$CONFIG_FILE.bak"
[ ! -f "$BIN" ] || cp -p "$BIN" "$BIN.bak"
[ ! -f "$SERVICE_FILE" ] || cp -p "$SERVICE_FILE" "$SERVICE_FILE.bak"
install -m 755 "$SERVER" "$BIN"
install -m 600 "$WORKDIR/config.json" "$CONFIG_FILE"
install -m 644 "$WORKDIR/service" "$SERVICE_FILE"
[ "$FAMILY" != alpine ] || chmod 755 "$SERVICE_FILE"

info '启用并启动服务...'
if [ "$FAMILY" = alpine ]; then
    rc-update add "${SERVICE_NAME}" default
    rc-service "${SERVICE_NAME}" start || die '服务启动失败，请检查 OpenRC 日志'
    sleep 2
    rc-service "${SERVICE_NAME}" status || die '服务状态异常'
    MANAGE='rc-service shadowsocks {start|stop|restart|status}'
else
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null
    systemctl restart "${SERVICE_NAME}" || die '服务启动失败，请运行 journalctl -u shadowsocks -n 50 --no-pager'
    sleep 2
    systemctl is-active --quiet "${SERVICE_NAME}" || die '服务状态异常，请运行 journalctl -u shadowsocks -n 50 --no-pager'
    MANAGE='systemctl {start|stop|restart|status} shadowsocks'
fi

printf '\n========== 安装完成 ==========\n'
printf '系统：%s\n版本：%s\n端口：%s\n算法：%s\n密钥：%s\n' "${PRETTY_NAME:-$OS_ID}" "$VERSION" "$PORT" "$METHOD" "$PASSWORD"
printf '配置：%s\n服务：%s（已设置开机自启）\n' "$CONFIG_FILE" "${SERVICE_NAME}"
printf '管理：%s\n' "$MANAGE"
printf '请放行服务器防火墙及云安全组中的 TCP/UDP %s 端口。\n' "$PORT"
