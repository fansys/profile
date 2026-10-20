#!/bin/sh
# Alpine Linux / OpenRC shadowsocks-rust installer
# curl -fsSL https://raw.githubusercontent.com/fansys/profile/master/scripts/shadowsocks.sh | sh
# 下载后执行（适合检查脚本后再运行）：
# curl -fsSL https://raw.githubusercontent.com/fansys/profile/master/scripts/shadowsocks.sh -o shadowsocks.sh && sh shadowsocks.sh
set -eu

NAME=shadowsocks
CONFIG_DIR=/etc/shadowsocks
CONFIG_FILE=$CONFIG_DIR/config.json
SERVICE_FILE=/etc/init.d/shadowsocks
BIN=/usr/local/bin/ssserver
REPO=https://github.com/shadowsocks/shadowsocks-rust
DEFAULT_PORT=8388
DEFAULT_METHOD=2022-blake3-aes-128-gcm

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die '请以 root 身份运行'
[ -f /etc/alpine-release ] || die '仅支持 Alpine Linux'
command -v rc-service >/dev/null 2>&1 || die '未找到 OpenRC（rc-service）'

# 从 /dev/tty 单独读取用户输入，不消耗 curl | sh 的脚本内容。
# 无终端时直接使用默认值。FD 3 仅用于读取配置输入。
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

info '安装依赖...'
apk add --no-cache curl ca-certificates xz openssl jq coreutils >/dev/null

case "$(uname -m)" in
    x86_64) TARGET=x86_64-unknown-linux-musl ;;
    aarch64) TARGET=aarch64-unknown-linux-musl ;;
    *) die "暂不支持的 CPU 架构：$(uname -m)" ;;
esac

printf '\n========== Shadowsocks 配置 ==========\n\n'
while :; do
    ask "端口 [$DEFAULT_PORT]: "
    PORT=${ANSWER:-$DEFAULT_PORT}
    case "$PORT" in
        ''|*[!0-9]*) printf '端口必须为数字\n'; continue ;;
    esac
    # 规避前导 0 和过长整数带来的 shell 数值问题
    [ "${#PORT}" -le 5 ] || { printf '端口范围为 1-65535\n'; continue; }
    PORT=$(printf '%s' "$PORT" | sed 's/^0*//')
    PORT=${PORT:-0}
    if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then break; fi
    printf '端口范围为 1-65535\n'
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
        *) printf '无效选项，请重试\n' ;;
    esac
done

valid_2022_key() {
    # 解码后必须为正确字节数，重新编码需与输入完全一致。
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
    printf '2022 密钥不符合长度/Base64 格式，请重试\n'
done

printf '\n端口：%s\n加密：%s\n密码/密钥：%s\nTCP/UDP：均启用\n开机自启：开启\n\n' "$PORT" "$METHOD" "$PASSWORD"

info '查询 GitHub 官方最新版本及构建资源...'
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
trap 'exit 1' HUP INT TERM
curl -fsSL --retry 3 --connect-timeout 15 \
    https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
    -o "$WORKDIR/release.json" || die '查询 GitHub Releases 失败'
VERSION=$(jq -r '.tag_name // empty' "$WORKDIR/release.json")
[ -n "$VERSION" ] || die '无法解析发布版本'
ASSET=$(jq -r --arg target "$TARGET" '.assets[].name | select(endswith("." + $target + ".tar.xz"))' "$WORKDIR/release.json" | head -n 1)
[ -n "$ASSET" ] || die "官方发布版本 $VERSION 未提供 $TARGET 的安装包"
DOWNLOAD_URL=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .browser_download_url' "$WORKDIR/release.json")
CHECK_URL=$(jq -r --arg asset "$ASSET.sha256" '.assets[] | select(.name == $asset) | .browser_download_url' "$WORKDIR/release.json")
[ -n "$CHECK_URL" ] || die '未找到对应 SHA256 校验文件'

info "下载 $VERSION ($TARGET)..."
curl -fL --retry 3 --connect-timeout 15 "$DOWNLOAD_URL" -o "$WORKDIR/$ASSET" || die '下载失败'
curl -fL --retry 3 --connect-timeout 15 "$CHECK_URL" -o "$WORKDIR/checksum" || die '下载校验文件失败'
EXPECTED=$(awk 'NR==1 {print $1}' "$WORKDIR/checksum")
ACTUAL=$(sha256sum "$WORKDIR/$ASSET" | awk '{print $1}')
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || die 'SHA256 校验失败'

mkdir -p "$WORKDIR/unpack"
tar -xJf "$WORKDIR/$ASSET" -C "$WORKDIR/unpack" || die '解压安装包失败'
SERVER=$(find "$WORKDIR/unpack" -type f -name ssserver -print -quit)
[ -n "$SERVER" ] || die '安装包中未找到 ssserver'

# 先创建新配置并保留旧文件备份。
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
jq -n --arg server '0.0.0.0' --argjson port "$PORT" \
    --arg method "$METHOD" --arg password "$PASSWORD" \
    '{server:$server, server_port:$port, method:$method, password:$password, mode:"tcp_and_udp"}' \
    > "$WORKDIR/config.json" || die '无法生成配置'

# 配置服务，supervise-daemon 可在进程异常终止时重启服务。
cat > "$WORKDIR/openrc" <<'EOF'
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

if [ -f "$SERVICE_FILE" ]; then
    info '停止现有 Shadowsocks 服务...'
    rc-service "$NAME" stop || true
fi
[ ! -f "$CONFIG_FILE" ] || cp -p "$CONFIG_FILE" "$CONFIG_FILE.bak"
install -m 755 "$SERVER" "$BIN"
install -m 600 "$WORKDIR/config.json" "$CONFIG_FILE"
install -m 755 "$WORKDIR/openrc" "$SERVICE_FILE"

info '设置开机自启并启动服务...'
rc-update add "$NAME" default
rc-service "$NAME" start || die '服务启动失败；检查日志排查原因'
sleep 2
rc-service "$NAME" status || die '服务状态异常'

printf '\n========== 安装完成 ==========\n'
printf '版本：%s\n端口：%s\n算法：%s\n密钥：%s\n' "$VERSION" "$PORT" "$METHOD" "$PASSWORD"
printf '配置：%s\n服务：%s（已设置开机自启）\n' "$CONFIG_FILE" "$NAME"
printf '管理：rc-service shadowsocks {start|stop|restart|status}\n'
printf '请放行服务器及云安全组 TCP/UDP %s 端口。\n' "$PORT"
