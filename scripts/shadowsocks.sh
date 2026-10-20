
#!/bin/sh
set -eu

# Alpine Linux Shadowsocks-Rust 一键安装
# OpenRC 服务名称: shadowsocks
# 配置: /etc/shadowsocks/config.json
# Quick install: curl -fsSL https://raw.githubusercontent.com/fansys/profile/master/scripts/shadowsocks.sh | sh

NAME="shadowsocks"
DIR="/etc/shadowsocks"
CONF="$DIR/config.json"
SERVICE="/etc/init.d/$NAME"
BIN="/usr/local/bin/ssserver"
REPO="https://github.com/shadowsocks/shadowsocks-rust"

DEFAULT_PORT=8388
DEFAULT_METHOD="2022-blake3-aes-128-gcm"

info() {
    printf '\033[32m[INFO]\033[0m %s\n' "$*"
}

error() {
    printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || error "请使用 root 执行"
[ -f /etc/alpine-release ] || error "仅支持 Alpine Linux"
command -v rc-service >/dev/null 2>&1 || \
    error "未检测到 OpenRC"

info "安装依赖..."
apk add --no-cache curl ca-certificates xz \
    openssl jq coreutils

# CPU 架构
case "$(uname -m)" in
    x86_64)
        ARCH="x86_64"
        ;;
    aarch64)
        ARCH="aarch64"
        ;;
    *)
        error "当前脚本支持 x86_64 / aarch64"
        ;;
esac

TARGET="${ARCH}-unknown-linux-musl"

echo ""
echo "========== Shadowsocks 配置 =========="
echo ""

# 输入端口
while :; do
    printf "端口 [%s]: " "$DEFAULT_PORT"
    read -r PORT || true
    PORT="${PORT:-$DEFAULT_PORT}"

    case "$PORT" in
        *[!0-9]*|'')
            echo "端口必须是数字"
            continue
            ;;
    esac

    PORT="$(echo "$PORT" | sed 's/^0*//')"
    PORT="${PORT:-0}"

    if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
        break
    fi

    echo "端口范围: 1-65535"
done

# 选择加密算法
echo ""
echo "加密算法:"
echo "1) 2022-blake3-aes-128-gcm [默认]"
echo "2) 2022-blake3-aes-256-gcm"
echo "3) 2022-blake3-chacha20-poly1305"
echo "4) aes-256-gcm"
echo "5) aes-128-gcm"
echo "6) chacha20-ietf-poly1305"
echo ""

printf "请选择 [1]: "
read -r CHOICE || true

case "${CHOICE:-1}" in
    1) METHOD="2022-blake3-aes-128-gcm" ;;
    2) METHOD="2022-blake3-aes-256-gcm" ;;
    3) METHOD="2022-blake3-chacha20-poly1305" ;;
    4) METHOD="aes-256-gcm" ;;
    5) METHOD="aes-128-gcm" ;;
    6) METHOD="chacha20-ietf-poly1305" ;;
    *) error "无效选项" ;;
esac

# 根据算法确定密钥长度
case "$METHOD" in
    2022-blake3-aes-128-gcm)
        KEY_BYTES=16
        ;;
    2022-*)
        KEY_BYTES=32
        ;;
    *)
        KEY_BYTES=0
        ;;
esac

# 验证 2022 密钥
valid_key() {
    KEY="$1"

    DECODED="$(printf '%s' "$KEY" | \
        openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"

    [ "$DECODED" = "$KEY_BYTES" ] || return 1

    # 确认 Base64 格式及内容有效
    NORMALIZED="$(printf '%s' "$KEY" | \
        openssl base64 -d -A 2>/dev/null | \
        openssl base64 -A 2>/dev/null)"

    [ "$NORMALIZED" = "$KEY" ]
}

echo ""
while :; do
    if [ "$KEY_BYTES" -gt 0 ]; then
        echo "当前算法要求 Base64 编码的 ${KEY_BYTES} 字节密钥"
    fi

    printf "密码/密钥 [回车自动生成]: "

    if [ -t 0 ]; then
        stty -echo
    fi

    PASSWORD=""
    read -r PASSWORD || true

    if [ -t 0 ]; then
        stty echo
    fi
    echo ""

    if [ -z "$PASSWORD" ]; then
        if [ "$KEY_BYTES" -gt 0 ]; then
            PASSWORD="$(openssl rand -base64 "$KEY_BYTES" | tr -d '\n')"
        else
            PASSWORD="$(openssl rand -hex 24)"
        fi
    fi

    if [ "$KEY_BYTES" -gt 0 ]; then
        if valid_key "$PASSWORD"; then
            break
        fi
        echo "密钥格式错误，请重新输入"
    else
        break
    fi
done

echo ""
echo "========== 当前配置 =========="
echo "端口: $PORT"
echo "加密: $METHOD"
echo "密码: $PASSWORD"
echo "协议: TCP + UDP"
echo "服务: $NAME"
echo "配置: $CONF"
echo "开机自启: 是"
echo "=============================="
echo ""

# 获取最新版本
info "获取官方最新版本..."

VERSION="$(curl -fsSL --retry 3 \
    https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
    | jq -r '.tag_name // empty')"

[ -n "$VERSION" ] || error "获取版本失败"

ASSET="shadowsocks-${VERSION}.${TARGET}.tar.xz"
URL="$REPO/releases/download/$VERSION/$ASSET"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

info "下载 Shadowsocks-Rust $VERSION ..."

curl -fL --retry 3 "$URL" \
    -o "$WORKDIR/$ASSET" \
    || error "下载失败"

# SHA256 校验
info "校验安装包..."

curl -fL --retry 3 "$URL.sha256" \
    -o "$WORKDIR/checksum" \
    || error "下载校验文件失败"

EXPECTED="$(awk 'NR==1 {print $1}' "$WORKDIR/checksum")"
ACTUAL="$(sha256sum "$WORKDIR/$ASSET" | awk '{print $1}')"

[ "$EXPECTED" = "$ACTUAL" ] || error "SHA256 校验失败"

# 解压
mkdir -p "$WORKDIR/extract"

tar -xJf "$WORKDIR/$ASSET" \
    -C "$WORKDIR/extract"

SERVER="$(find "$WORKDIR/extract" \
    -type f -name ssserver | head -n 1)"

[ -n "$SERVER" ] || error "未找到 ssserver"

# 安装
info "安装服务端程序..."

# 停止已存在的同名服务
if [ -f "$SERVICE" ]; then
    rc-service "$NAME" stop || true
fi

install -m 755 "$SERVER" "$BIN"

# 创建配置
mkdir -p "$DIR"
chmod 700 "$DIR"

if [ -f "$CONF" ]; then
    cp -p "$CONF" "$CONF.bak"
    info "旧配置已备份到 $CONF.bak"
fi

jq -n \
    --arg server "0.0.0.0" \
    --argjson port "$PORT" \
    --arg password "$PASSWORD" \
    --arg method "$METHOD" \
    '{
        server: $server,
        server_port: $port,
        password: $password,
        method: $method,
        mode: "tcp_and_udp"
    }' > "$CONF"

chmod 600 "$CONF"

# 安装 OpenRC 服务
info "配置 OpenRC..."

cat > "$SERVICE" <<'EOF'
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

chmod 755 "$SERVICE"

# 设置开机自启
rc-update add "$NAME" default

# 启动
info "启动 Shadowsocks..."
rc-service "$NAME" start || error "服务启动失败"

sleep 2

rc-service "$NAME" status || error "服务运行异常"

echo ""
echo "========================================"
echo " Shadowsocks-Rust 安装完成！"
echo "========================================"
echo "版本: $VERSION"
echo "服务名称: $NAME"
echo "服务器端口: $PORT"
echo "加密算法: $METHOD"
echo "连接密钥: $PASSWORD"
echo "网络协议: TCP + UDP"
echo "配置文件: $CONF"
echo "开机自启: 已开启"
echo "========================================"
echo ""
echo "启动: rc-service shadowsocks start"
echo "停止: rc-service shadowsocks stop"
echo "重启: rc-service shadowsocks restart"
echo "状态: rc-service shadowsocks status"
echo ""
echo "请确保防火墙和云服务器安全组已放行"
echo "TCP/UDP 端口: $PORT"
echo ""
