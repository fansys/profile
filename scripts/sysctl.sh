#!/usr/bin/env bash

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.2"
UPDATE_URL="https://gh.fansy.life/https://raw.githubusercontent.com/fansys/profile/master/scripts/sysctl.sh"
SWAP_FILE="/swap"
DEFAULT_SWAPPINESS=10
NATCFG_URL="https://gh.fansy.life/https://raw.githubusercontent.com/arloor/iptablesUtils/master/natcfg.sh"
APT_UPDATED=0

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
NC='\033[0m'

red()    { printf "${RED}%s${NC}\n" "$*"; }
green()  { printf "${GREEN}%s${NC}\n" "$*"; }
yellow() { printf "${YELLOW}%s${NC}\n" "$*"; }
blue()   { printf "${BLUE}%s${NC}\n" "$*"; }
line()   { printf '%*s\n' "${COLUMNS:-64}" '' | tr ' ' '-'; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        red "请使用 root 权限执行"
        exit 1
    fi
}

pause() {
    if [ -t 0 ]; then
        echo
        read -r -p "按 Enter 继续..."
    fi
}

get_pkg_manager() {
    if command_exists apt-get; then
        echo apt
    elif command_exists dnf; then
        echo dnf
    elif command_exists yum; then
        echo yum
    elif command_exists apk; then
        echo apk
    else
        echo unknown
    fi
}

# =========================
# 脚本自更新
# =========================

get_self_path() {
    local src="${BASH_SOURCE[0]}"
    if command_exists readlink; then
        readlink -f "$src" 2>/dev/null && return 0
    fi
    printf '%s\n' "$src"
}

show_update_url() {
    echo "脚本地址: $UPDATE_URL"
}

ensure_downloader() {
    command_exists curl && return 0
    command_exists wget && return 0

    blue "未检测到 curl/wget，按需安装 curl..."
    case "$(get_pkg_manager)" in
        apt|dnf|yum|apk) install_packages curl ;;
        *) red "无法自动安装下载工具"; return 1 ;;
    esac
}

download_file() {
    local url="$1" dest="$2"
    ensure_downloader || return 1

    if command_exists curl; then
        curl --fail --silent --show-error --location \
            --retry 5 --retry-delay 2 --connect-timeout 10 \
            "$url" -o "$dest"
    else
        wget -q --timeout=15 --tries=5 -O "$dest" "$url"
    fi
}

self_update() {
    require_root
    local url="$UPDATE_URL"
    local current tmp new backup

    current="$(get_self_path)"
    [ -f "$current" ] || {
        red "无法确定当前脚本路径：$current"
        return 1
    }

    tmp="$(mktemp /tmp/sysctl.sh.update.XXXXXX)" || return 1
    new="${current}.new.$$"
    backup="${current}.bak"

    blue "当前版本：$SCRIPT_VERSION"
    blue "更新地址：$url"
    blue "正在下载新版本..."

    if ! download_file "$url" "$tmp"; then
        rm -f "$tmp" "$new"
        red "脚本下载失败"
        return 1
    fi

    [ -s "$tmp" ] || {
        rm -f "$tmp"
        red "下载到的脚本为空"
        return 1
    }

    # 下载完成后必须先通过 Bash 语法检查，再允许覆盖当前脚本。
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        red "新脚本语法校验失败，已取消更新"
        return 1
    fi

    if cmp -s "$current" "$tmp"; then
        rm -f "$tmp"
        green "当前已经是最新版本"
        return 0
    fi

    cp -p "$current" "$backup" || {
        rm -f "$tmp"
        red "无法创建备份：$backup"
        return 1
    }

    install -m 0755 "$tmp" "$new" || {
        rm -f "$tmp" "$new"
        red "无法写入新脚本"
        return 1
    }

    if command_exists chown; then
        chown --reference="$current" "$new" 2>/dev/null || true
    fi

    mv -f "$new" "$current" || {
        rm -f "$tmp" "$new"
        red "替换脚本失败，原文件未被修改"
        return 1
    }
    rm -f "$tmp"

    green "脚本更新完成"
    echo "脚本路径：$current"
    echo "备份文件：$backup"
    echo "如需回滚：$SCRIPT_NAME rollback-self"
}

self_rollback() {
    require_root
    local current backup tmp
    current="$(get_self_path)"
    backup="${current}.bak"
    [ -f "$backup" ] || {
        red "未找到备份文件：$backup"
        return 1
    }
    bash -n "$backup" || {
        red "备份脚本语法校验失败，拒绝回滚"
        return 1
    }
    tmp="${current}.rollback.$$"
    cp -p "$backup" "$tmp" && mv -f "$tmp" "$current"
    green "已回滚到上一次更新前的版本"
}

install_packages() {
    require_root
    [ "$#" -gt 0 ] || return 0

    local pm
    pm="$(get_pkg_manager)"
    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            # 只有真正缺少依赖并需要安装时才刷新 APT 索引；同一次脚本执行最多刷新一次。
            if [ "$APT_UPDATED" -eq 0 ]; then
                apt-get update
                APT_UPDATED=1
            fi
            apt-get install -y --no-install-recommends "$@"
            ;;
        dnf)
            dnf install -y --setopt=install_weak_deps=False "$@"
            ;;
        yum)
            yum install -y "$@"
            ;;
        apk)
            apk add --no-cache "$@"
            ;;
        *)
            red "无法识别软件包管理器，请手动安装：$*"
            return 1
            ;;
    esac
}

# =========================
# Swap
# =========================

size_to_mb() {
    local input number
    input="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"

    if printf '%s\n' "$input" | grep -Eq '^[0-9]+([.][0-9]+)?G$'; then
        number="${input%G}"
        awk -v n="$number" 'BEGIN { printf "%d\n", n * 1024 }'
    elif printf '%s\n' "$input" | grep -Eq '^[0-9]+([.][0-9]+)?M$'; then
        number="${input%M}"
        awk -v n="$number" 'BEGIN { printf "%d\n", n }'
    elif printf '%s\n' "$input" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
        awk -v n="$input" 'BEGIN { printf "%d\n", n * 1024 }'
    else
        return 1
    fi
}

set_swappiness() {
    require_root
    local value="${1:-10}" quiet="${2:-}"
    if ! printf '%s\n' "$value" | grep -Eq '^[0-9]+$' || [ "$value" -gt 200 ]; then
        red "swappiness 必须是 0-200 的整数"
        return 1
    fi
    printf 'vm.swappiness=%s\n' "$value" > /etc/sysctl.d/99-swap.conf
    /sbin/sysctl -w "vm.swappiness=$value" >/dev/null 2>&1 || sysctl -w "vm.swappiness=$value" >/dev/null
    [ "$quiet" = quiet ] || green "vm.swappiness 已设置为 $value"
}

set_swap() {
    require_root
    local size="${1:-}" size_mb
    if [ -z "$size" ]; then
        echo "用法: $SCRIPT_NAME swap 0.5G|1G|1.5G|512M|0"
        return 1
    fi

    case "$(printf '%s' "$size" | tr '[:lower:]' '[:upper:]')" in
        0|0G|0M) remove_swap; return ;;
    esac

    size_mb="$(size_to_mb "$size")" || {
        red "无效大小：$size；支持 0.5G、1.5G、512M 等"
        return 1
    }
    [ "$size_mb" -ge 64 ] || { red "Swap 至少设置 64M"; return 1; }

    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_FILE"; then
        swapoff "$SWAP_FILE" || return 1
    fi
    sed -i "\|^[[:blank:]]*${SWAP_FILE}[[:blank:]]|d" /etc/fstab
    rm -f "$SWAP_FILE"

    blue "创建 ${size_mb}M Swap..."
    if command_exists fallocate && fallocate -l "${size_mb}M" "$SWAP_FILE" 2>/dev/null; then
        :
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mb" status=progress
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
    swapon "$SWAP_FILE"
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
    set_swappiness "$DEFAULT_SWAPPINESS" quiet
    green "Swap 设置完成"
    free -h
    swapon --show
}

remove_swap() {
    require_root
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_FILE"; then
        swapoff "$SWAP_FILE"
    fi
    sed -i "\|^[[:blank:]]*${SWAP_FILE}[[:blank:]]|d" /etc/fstab
    rm -f "$SWAP_FILE"
    green "已删除 $SWAP_FILE"
}

swap_info() {
    free -h
    echo
    swapon --show 2>/dev/null || true
    echo
    echo "vm.swappiness = $(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
}

# =========================
# 系统维护
# =========================

system_info() {
    line; blue "系统信息"; line
    echo "主机名      : $(hostname)"
    if [ -r /etc/os-release ]; then . /etc/os-release; echo "操作系统    : ${PRETTY_NAME:-unknown}"; fi
    echo "内核        : $(uname -r)"
    echo "架构        : $(uname -m)"
    echo "运行时间    : $(uptime -p 2>/dev/null || uptime)"
    echo "CPU 核心    : $(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
    echo
    blue "内存"; free -h
    echo
    blue "磁盘"; df -hT -x tmpfs -x devtmpfs
    echo
    blue "IP"; ip -br addr 2>/dev/null || true
    echo
    blue "默认路由"; ip route show default 2>/dev/null || true
}

system_update() {
    require_root
    case "$(get_pkg_manager)" in
        apt) export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get upgrade -y ;;
        dnf) dnf upgrade -y ;;
        yum) yum update -y ;;
        apk) apk update; apk upgrade ;;
        *) red "不支持当前软件包管理器"; return 1 ;;
    esac
    green "系统更新完成"
}

system_clean() {
    require_root
    case "$(get_pkg_manager)" in
        apt) export DEBIAN_FRONTEND=noninteractive; apt-get autoremove -y; apt-get autoclean -y; apt-get clean ;;
        dnf) dnf autoremove -y || true; dnf clean all ;;
        yum) yum clean all ;;
        apk) rm -rf /var/cache/apk/* ;;
    esac
    find /tmp -mindepth 1 -mtime +7 -delete 2>/dev/null || true
    find /var/tmp -mindepth 1 -mtime +7 -delete 2>/dev/null || true
    green "系统清理完成"
}

journal_clean() {
    require_root
    local days="${1:-7}"
    command_exists journalctl || { red "没有 journalctl"; return 1; }
    printf '%s\n' "$days" | grep -Eq '^[0-9]+$' || { red "天数必须为整数"; return 1; }
    journalctl --disk-usage
    journalctl --vacuum-time="${days}d"
    journalctl --disk-usage
}

docker_info() {
    command_exists docker || { red "Docker 未安装"; return 1; }
    docker system df
}

docker_clean() {
    require_root
    command_exists docker || { red "Docker 未安装"; return 1; }
    yellow "仅清理未使用的容器、镜像、网络和构建缓存，不删除 Volume"
    docker container prune -f
    docker image prune -a -f
    docker network prune -f
    docker builder prune -a -f 2>/dev/null || true
    docker system df
}

disk_usage() {
    local path="${1:-/}"
    [ -d "$path" ] || { red "目录不存在：$path"; return 1; }
    df -h "$path"
    echo
    du -xhd1 "$path" 2>/dev/null | sort -hr | head -20
}

large_files() {
    local path="${1:-/}" size="${2:-500M}"
    find "$path" -xdev -type f -size "+$size" -printf '%s\t%p\n' 2>/dev/null \
        | sort -nr | head -30 \
        | while IFS=$'\t' read -r bytes file; do
            if command_exists numfmt; then
                printf '%8s %s\n' "$(numfmt --to=iec "$bytes")" "$file"
            else
                printf '%12s %s\n' "$bytes" "$file"
            fi
          done
}

inode_info() { df -ih; }
top_memory() { ps aux --sort=-%mem 2>/dev/null | head -11 || ps aux | head -11; }
top_cpu() { ps aux --sort=-%cpu 2>/dev/null | head -11 || ps aux | head -11; }
failed_services() { command_exists systemctl && systemctl --failed || red "当前系统未使用 systemd"; }
service_status() { [ -n "${1:-}" ] || { red "请指定服务名"; return 1; }; systemctl status "$1" --no-pager; }
time_info() { date; command_exists timedatectl && timedatectl; command_exists chronyc && chronyc tracking 2>/dev/null || true; }
reboot_required() {
    if [ -f /var/run/reboot-required ]; then yellow "系统需要重启"; [ -f /var/run/reboot-required.pkgs ] && cat /var/run/reboot-required.pkgs; else green "未检测到需要重启的标记"; fi
}

# =========================
# 网络 / DNS / 网关
# =========================

network_check() {
    local target="${1:-223.5.5.5}" domain="${2:-www.baidu.com}" gateway
    blue "IP 地址"; ip -br addr 2>/dev/null || ip addr
    echo; blue "路由"; ip route
    gateway="$(ip route | awk '/^default/ {print $3; exit}')"
    echo; blue "网关测试"; [ -n "$gateway" ] && ping -c 3 -W 2 "$gateway" || true
    echo; blue "公网测试"; ping -c 3 -W 2 "$target" || true
    echo; blue "DNS 解析"; getent hosts "$domain" || true
    echo; blue "网络配置后端"; detect_network_backend
}

dns_check() {
    local domain="${1:-www.baidu.com}"
    command_exists resolvectl && resolvectl status 2>/dev/null | grep -E 'Current DNS Server|DNS Servers|DNS Domain' || true
    echo; cat /etc/resolv.conf 2>/dev/null || true
    echo; getent ahosts "$domain" 2>/dev/null || getent hosts "$domain"
}

ports() {
    if command_exists ss; then ss -lntup; elif command_exists netstat; then netstat -lntup; else red "未找到 ss/netstat"; fi
}

get_default_iface() {
    ip route show default 2>/dev/null | awk '{print $5; exit}'
}

detect_network_backend() {
    # Netplan 是 Ubuntu 等系统的配置源，即使 renderer 是 NetworkManager，也优先按 Netplan 管理。
    if command_exists netplan && find /etc/netplan -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print -quit 2>/dev/null | grep -q .; then
        echo netplan
        return 0
    fi
    if command_exists nmcli; then
        echo networkmanager
        return 0
    fi
    echo unknown
}

gateway_show() {
    echo "当前默认路由："
    ip route show default
    echo
    echo "检测到的网络配置后端：$(detect_network_backend)"
}

gateway_set() {
    require_root
    local gw="${1:-}" iface="${2:-}"
    [ -n "$gw" ] || { red "用法: $SCRIPT_NAME gateway set <网关IP> [网卡]"; return 1; }
    [ -n "$iface" ] || iface="$(get_default_iface)"
    [ -n "$iface" ] || iface="$(ip -o link show | awk -F': ' '$2!="lo" {print $2; exit}')"
    [ -n "$iface" ] || { red "无法确定网卡"; return 1; }
    ip route replace default via "$gw" dev "$iface"
    green "默认网关已临时设置为 $gw dev $iface"
}

gateway_persist_nm() {
    require_root
    local gw="${1:-}" iface="${2:-}" conn
    [ -n "$gw" ] || return 1
    command_exists nmcli || { red "未检测到 nmcli"; return 1; }
    [ -n "$iface" ] || iface="$(get_default_iface)"
    [ -n "$iface" ] || { red "无法确定网卡"; return 1; }
    conn="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')"
    [ -n "$conn" ] || conn="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')"
    [ -n "$conn" ] || { red "找不到网卡 $iface 的 NetworkManager 连接"; return 1; }
    nmcli connection modify "$conn" ipv4.gateway "$gw" ipv4.never-default no
    nmcli connection up "$conn"
    green "NetworkManager 已持久设置：$conn -> gateway $gw"
}

gateway_persist_netplan() {
    require_root
    local gw="${1:-}" iface="${2:-}" existing origin_file backup
    [ -n "$gw" ] || return 1
    command_exists netplan || { red "未检测到 Netplan"; return 1; }
    [ -n "$iface" ] || iface="$(get_default_iface)"
    [ -n "$iface" ] || { red "无法确定网卡"; return 1; }

    # 若该接口存在非默认静态路由，覆盖 routes 列表可能丢失配置，因此拒绝自动修改。
    existing="$(netplan get "ethernets.${iface}.routes" 2>/dev/null || true)"
    if [ -n "$existing" ] && printf '%s\n' "$existing" | awk '
        /^[[:space:]]*to:/ {
            v=$0; sub(/^[[:space:]]*to:[[:space:]]*/, "", v); gsub(/["'\'' ]/, "", v);
            if (v != "default" && v != "0.0.0.0/0") bad=1
        }
        END {exit bad ? 0 : 1}
    '; then
        red "检测到 $iface 存在非默认静态路由，为避免覆盖自定义 routes，拒绝自动修改"
        echo "请手工调整 Netplan，或先清理该接口的自定义 routes。"
        return 1
    fi

    origin_file="/etc/netplan/99-sysctl-gateway.yaml"
    [ -f "$origin_file" ] && cp -p "$origin_file" "${origin_file}.bak"

    if ! netplan set --origin-hint 99-sysctl-gateway "ethernets.${iface}.routes=[{to: default, via: ${gw}}]"; then
        red "netplan set 失败"
        return 1
    fi

    if ! netplan generate; then
        red "Netplan 配置校验失败"
        [ -f "${origin_file}.bak" ] && mv -f "${origin_file}.bak" "$origin_file"
        netplan generate >/dev/null 2>&1 || true
        return 1
    fi

    # 先更新当前路由，降低远程 SSH 因 apply 中断的风险，再应用 Netplan。
    ip route replace default via "$gw" dev "$iface" || true
    if ! netplan apply; then
        red "netplan apply 失败，尝试恢复配置"
        if [ -f "${origin_file}.bak" ]; then
            mv -f "${origin_file}.bak" "$origin_file"
        else
            rm -f "$origin_file"
        fi
        netplan generate >/dev/null 2>&1 || true
        netplan apply >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "${origin_file}.bak"
    green "Netplan 已持久设置：$iface -> gateway $gw"
}

gateway_persist() {
    require_root
    local gw="${1:-}" iface="${2:-}" backend
    [ -n "$gw" ] || { red "用法: $SCRIPT_NAME gateway persist <网关IP> [网卡]"; return 1; }
    backend="$(detect_network_backend)"
    blue "检测到网络配置后端：$backend"
    case "$backend" in
        netplan) gateway_persist_netplan "$gw" "$iface" ;;
        networkmanager) gateway_persist_nm "$gw" "$iface" ;;
        *)
            red "无法识别 Netplan 或 NetworkManager，不能安全写入持久网关"
            echo "可使用临时方式：$SCRIPT_NAME gateway set $gw ${iface:-}"
            return 1
            ;;
    esac
}

# =========================
# NFS
# =========================

ensure_nfs_client() {
    command_exists mount.nfs && return 0
    blue "安装 NFS 客户端..."
    case "$(get_pkg_manager)" in
        apt) install_packages nfs-common ;;
        dnf|yum) install_packages nfs-utils ;;
        apk) install_packages nfs-utils ;;
        *) red "无法自动安装 NFS 客户端"; return 1 ;;
    esac
}

nfs_get_server() {
    local remote="$1" host
    case "$remote" in
        \[*\]:*)
            host="${remote#\[}"
            host="${host%%\]*}"
            ;;
        *:*) host="${remote%%:*}" ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$host"
}

nfs_check() {
    local remote="${1:-}" server resolved
    [ -n "$remote" ] || { red "用法: $SCRIPT_NAME nfs check <server:/path|server>"; return 1; }

    if printf '%s\n' "$remote" | grep -q ':'; then
        server="$(nfs_get_server "$remote" 2>/dev/null || true)"
    else
        server="$remote"
    fi
    [ -n "$server" ] || { red "无法从 NFS 地址解析服务器：$remote"; return 1; }

    resolved="$(getent ahostsv4 "$server" 2>/dev/null | awk '{print $1; exit}')"
    [ -n "$resolved" ] || resolved="$(getent ahosts "$server" 2>/dev/null | awk '{print $1; exit}')"
    [ -n "$resolved" ] || { red "无法解析 NFS 服务器：$server"; return 1; }
    blue "NFS 服务器：$server ($resolved)"

    # NFSv4 主要使用 TCP 2049。rpcinfo 可用时优先做 RPC 层检测。
    if command_exists rpcinfo; then
        if rpcinfo -t "$server" nfs 4 >/dev/null 2>&1 || rpcinfo -t "$server" nfs >/dev/null 2>&1; then
            green "NFS RPC 连通性正常"
            return 0
        fi
    fi

    if command_exists nc; then
        if nc -z -w 3 "$server" 2049 >/dev/null 2>&1; then
            green "NFS TCP/2049 连通性正常"
            return 0
        fi
    elif command_exists timeout; then
        if timeout 4 bash -c "exec 3<>/dev/tcp/${server}/2049" >/dev/null 2>&1; then
            green "NFS TCP/2049 连通性正常"
            return 0
        fi
    fi

    red "NFS 服务不可达：$server:2049"
    echo "请检查服务端 NFS、路由、防火墙及 exports 配置。"
    return 1
}

nfs_mount() {
    require_root
    local remote="${1:-}" mountpoint="${2:-}" options="${3:-defaults,_netdev,nofail,x-systemd.automount}" direct_options
    [ -n "$remote" ] && [ -n "$mountpoint" ] || {
        red "用法: $SCRIPT_NAME nfs mount <server:/path> <本地目录> [options]"
        return 1
    }
    ensure_nfs_client || return 1
    nfs_check "$remote" || return 1
    mkdir -p "$mountpoint"

    # 先进行一次真实挂载测试，成功后才写 fstab，避免错误配置遗留到启动流程。
    direct_options="$(printf '%s' "$options" | sed -E 's/(^|,)(nofail|_netdev|x-systemd\.automount)(,|$)/,/g; s/^,+//; s/,+$//; s/,,+/,/g')"
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        umount "$mountpoint" || { red "无法卸载现有挂载：$mountpoint"; return 1; }
    fi
    if [ -n "$direct_options" ]; then
        mount -t nfs -o "$direct_options" "$remote" "$mountpoint" || return 1
    else
        mount -t nfs "$remote" "$mountpoint" || return 1
    fi

    awk -v mp="$mountpoint" '$2 != mp {print}' /etc/fstab > /etc/fstab.tmp.$$ && mv /etc/fstab.tmp.$$ /etc/fstab
    printf '%s %s nfs %s 0 0\n' "$remote" "$mountpoint" "$options" >> /etc/fstab
    command_exists systemctl && systemctl daemon-reload

    green "NFS 连通性检查及挂载成功：$remote -> $mountpoint"
    findmnt "$mountpoint" 2>/dev/null || mount | grep " $mountpoint " || true
}

nfs_unmount() {
    require_root
    local mountpoint="${1:-}" remove_fstab="${2:-}"
    [ -n "$mountpoint" ] || { red "用法: $SCRIPT_NAME nfs unmount <本地目录> [remove]"; return 1; }
    umount "$mountpoint" 2>/dev/null || umount -l "$mountpoint"
    if [ "$remove_fstab" = remove ]; then
        awk -v mp="$mountpoint" '$2 != mp {print}' /etc/fstab > /etc/fstab.tmp.$$ && mv /etc/fstab.tmp.$$ /etc/fstab
        command_exists systemctl && systemctl daemon-reload
        green "已卸载并删除 fstab 配置：$mountpoint"
    else
        green "已卸载：$mountpoint"
    fi
}

nfs_list() {
    echo "当前 NFS 挂载："
    findmnt -t nfs,nfs4 2>/dev/null || mount -t nfs,nfs4 2>/dev/null || true
    echo
    echo "/etc/fstab 中的 NFS："
    awk '$3=="nfs" || $3=="nfs4" {print}' /etc/fstab
}

# =========================
# iptables NAT / 端口转发
# =========================

enable_ip_forward() {
    require_root
    cat > /etc/sysctl.d/99-ip-forward.conf <<'EON'
net.ipv4.ip_forward=1
EON
    /sbin/sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

ensure_iptables() {
    command_exists iptables && return 0
    case "$(get_pkg_manager)" in
        apt) install_packages iptables ;;
        dnf|yum) install_packages iptables ;;
        apk) install_packages iptables ;;
        *) red "无法自动安装 iptables"; return 1 ;;
    esac
}

resolve_ipv4() {
    local host="$1"
    if printf '%s\n' "$host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        printf '%s\n' "$host"
    else
        getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
    fi
}

nat_add_static() {
    require_root
    local lport="${1:-}" host="${2:-}" rport="${3:-}" proto="${4:-both}" rip p
    [ -n "$lport" ] && [ -n "$host" ] && [ -n "$rport" ] || {
        red "用法: $SCRIPT_NAME nat add <本地端口> <目标IP/域名> <目标端口> [tcp|udp|both]"
        return 1
    }
    printf '%s\n' "$lport" | grep -Eq '^[0-9]+$' || { red "本地端口必须是数字"; return 1; }
    printf '%s\n' "$rport" | grep -Eq '^[0-9]+$' || { red "目标端口必须是数字"; return 1; }
    [ "$lport" -ge 1 ] && [ "$lport" -le 65535 ] || { red "本地端口范围必须为 1-65535"; return 1; }
    [ "$rport" -ge 1 ] && [ "$rport" -le 65535 ] || { red "目标端口范围必须为 1-65535"; return 1; }
    rip="$(resolve_ipv4 "$host")"
    [ -n "$rip" ] || { red "无法解析目标：$host"; return 1; }
    ensure_iptables || return 1
    enable_ip_forward

    case "$proto" in tcp) set -- tcp ;; udp) set -- udp ;; both|all) set -- tcp udp ;; *) red "协议仅支持 tcp/udp/both"; return 1 ;; esac
    for p in "$@"; do
        iptables -t nat -C PREROUTING -p "$p" --dport "$lport" -j DNAT --to-destination "$rip:$rport" 2>/dev/null \
            || iptables -t nat -A PREROUTING -p "$p" --dport "$lport" -j DNAT --to-destination "$rip:$rport"
        iptables -t nat -C POSTROUTING -p "$p" -d "$rip" --dport "$rport" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -p "$p" -d "$rip" --dport "$rport" -j MASQUERADE
        iptables -C FORWARD -p "$p" -d "$rip" --dport "$rport" -j ACCEPT 2>/dev/null \
            || iptables -A FORWARD -p "$p" -d "$rip" --dport "$rport" -j ACCEPT
    done
    green "已添加端口转发：$lport -> $host($rip):$rport [$proto]"
    yellow "这是当前 iptables 规则；若目标是 DDNS 域名并希望 IP 变化后自动更新，请使用: $SCRIPT_NAME nat natcfg"
}

nat_list() {
    ensure_iptables || return 1
    echo "PREROUTING:"; iptables -t nat -L PREROUTING -n -v --line-numbers
    echo; echo "POSTROUTING:"; iptables -t nat -L POSTROUTING -n -v --line-numbers
    echo; echo "FORWARD:"; iptables -L FORWARD -n -v --line-numbers
}

nat_delete_rule() {
    require_root
    local chain="${1:-}" num="${2:-}"
    [ -n "$chain" ] && [ -n "$num" ] || { red "用法: $SCRIPT_NAME nat del <prerouting|postrouting|forward> <规则编号>"; return 1; }
    ensure_iptables || return 1
    case "$chain" in
        prerouting) iptables -t nat -D PREROUTING "$num" ;;
        postrouting) iptables -t nat -D POSTROUTING "$num" ;;
        forward) iptables -D FORWARD "$num" ;;
        *) red "chain 仅支持 prerouting/postrouting/forward"; return 1 ;;
    esac
    green "规则已删除"
}

run_natcfg() {
    require_root
    local tmp="/tmp/natcfg.$$"

    # natcfg 只有在实际使用时才准备依赖。
    ensure_iptables || return 1
    enable_ip_forward

    blue "下载并运行 arloor/iptablesUtils natcfg.sh ..."
    download_file "$NATCFG_URL" "$tmp" || {
        rm -f "$tmp"
        red "natcfg.sh 下载失败"
        return 1
    }

    bash -n "$tmp" || {
        rm -f "$tmp"
        red "natcfg.sh 语法校验失败"
        return 1
    }

    chmod 700 "$tmp"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

# =========================
# 可选依赖状态
# =========================

dependency_status() {
    echo "可选依赖状态（这里只检查，不会安装）："
    line
    printf "%-20s %s\n" "下载工具" "$(command_exists curl && echo 'curl' || { command_exists wget && echo 'wget' || echo '缺失（update-self 时按需安装 curl）'; })"
    printf "%-20s %s\n" "NFS 客户端" "$(command_exists mount.nfs && echo '已安装' || echo '缺失（nfs mount 时按需安装）')"
    printf "%-20s %s\n" "iptables" "$(command_exists iptables && echo '已安装' || echo '缺失（nat 功能时按需安装）')"
    printf "%-20s %s\n" "Netplan" "$(command_exists netplan && echo '可用' || echo '未检测到')"
    printf "%-20s %s\n" "NetworkManager" "$(command_exists nmcli && echo '可用' || echo '未检测到')"
    printf "%-20s %s\n" "Docker" "$(command_exists docker && echo '可用' || echo '未安装（脚本不会自动安装）')"
}

# =========================
# 帮助 / 菜单
# =========================

show_help() {
    cat <<EOF
Linux 系统维护工具

用法:
  $SCRIPT_NAME <command> [参数]

脚本管理:
  version                      查看脚本版本
  update-self                  从内置地址下载并更新脚本
  update-url                   查看内置更新地址
  rollback-self                回滚到上一次更新前的脚本

基础维护:
  info                         系统信息
  update                       系统更新
  clean                        系统清理
  journal [days]               清理 Journal，默认 7 天
  docker                       Docker 空间
  docker-clean                 清理 Docker（不删除 Volume）
  disk [path]                  磁盘占用分析
  large-files [path] [size]    查找大文件，如 / 500M
  inode                        inode 状态
  top-mem                      内存占用 TOP
  top-cpu                      CPU 占用 TOP
  failed                       systemd 失败服务
  service <name>               服务状态
  time                         时间同步状态
  reboot-required              是否需要重启

Swap:
  swap <size>                  设置 Swap，支持 0.5G/1.5G/512M/0
  swap-remove                  删除 /swap
  swap-info                    查看 Swap
  swappiness <0-200>           设置 vm.swappiness

网络:
  network                      网络诊断
  dns [domain]                 DNS 检查
  ports                        查看监听端口
  gateway show                 查看默认网关
  gateway set <gw> [iface]     临时修改默认网关
  gateway persist <gw> [iface] 自动识别 Netplan/NetworkManager 持久修改

NFS:
  nfs list
  nfs check <server:/path|server>
  nfs mount <server:/path> <mountpoint> [options]
  nfs unmount <mountpoint> [remove]

  默认 NFS 参数:
  defaults,_netdev,nofail,x-systemd.automount

iptables 端口转发:
  nat add <local> <host> <remote> [tcp|udp|both]
  nat list
  nat del <prerouting|postrouting|forward> <规则编号>
  nat natcfg                   运行 arloor natcfg.sh，支持 DDNS 动态解析

不带参数运行进入菜单。
EOF
}

show_menu() {
    clear
    echo "============================================================"
    echo "                 Linux 系统维护工具"
    echo "============================================================"
    echo " 1. 系统信息                 13. 网络诊断"
    echo " 2. 系统更新                 14. DNS 检查"
    echo " 3. 系统清理                 15. 监听端口"
    echo " 4. 设置 Swap                16. 网关管理"
    echo " 5. 删除 Swap                17. NFS 管理"
    echo " 6. Swap 状态                18. iptables 端口转发"
    echo " 7. 设置 swappiness          19. CPU TOP"
    echo " 8. Journal 清理             20. 内存 TOP"
    echo " 9. Docker 空间              21. 失败服务"
    echo "10. Docker 清理              22. 时间同步"
    echo "11. 磁盘占用                 23. 是否需要重启"
    echo "12. 查找大文件              24. 更新维护脚本"
    echo "                            25. 查看脚本版本"
    echo " 0. 退出"
}

menu_gateway() {
    echo "1) 查看网关"
    echo "2) 临时设置网关"
    echo "3) 自动持久设置（Netplan/NetworkManager）"
    read -r -p "请选择: " x
    case "$x" in
        1) gateway_show ;;
        2) read -r -p "网关IP: " gw; read -r -p "网卡(留空自动): " iface; gateway_set "$gw" "$iface" ;;
        3) read -r -p "网关IP: " gw; read -r -p "网卡(留空自动): " iface; gateway_persist "$gw" "$iface" ;;
    esac
}

menu_nfs() {
    echo "1) 查看 NFS"
    echo "2) 检查 NFS 连通性"
    echo "3) 挂载 NFS"
    echo "4) 卸载 NFS"
    read -r -p "请选择: " x
    case "$x" in
        1) nfs_list ;;
        2)
            read -r -p "远程地址(server:/path 或 server): " remote
            nfs_check "$remote"
            ;;
        3)
            read -r -p "远程地址(server:/path): " remote
            read -r -p "本地目录: " mp
            read -r -p "挂载参数(留空使用默认): " opts
            nfs_mount "$remote" "$mp" "${opts:-defaults,_netdev,nofail,x-systemd.automount}"
            ;;
        4)
            read -r -p "本地目录: " mp
            read -r -p "同时删除 fstab? [y/N]: " yn
            if [ "$yn" = y ] || [ "$yn" = Y ]; then
                nfs_unmount "$mp" remove
            else
                nfs_unmount "$mp"
            fi
            ;;
    esac
}

menu_nat() {
    echo "1) 添加静态转发"
    echo "2) 查看规则"
    echo "3) 删除规则"
    echo "4) 运行 arloor natcfg.sh（DDNS）"
    read -r -p "请选择: " x
    case "$x" in
        1)
            read -r -p "本地端口: " lp
            read -r -p "目标IP/域名: " host
            read -r -p "目标端口: " rp
            read -r -p "协议 tcp/udp/both [both]: " proto
            nat_add_static "$lp" "$host" "$rp" "${proto:-both}"
            ;;
        2) nat_list ;;
        3)
            read -r -p "链 prerouting/postrouting/forward: " chain
            read -r -p "规则编号: " num
            nat_delete_rule "$chain" "$num"
            ;;
        4) run_natcfg ;;
    esac
}

interactive_menu() {
    while true; do
        show_menu
        read -r -p "请选择: " choice
        echo
        case "$choice" in
            1) system_info ;;
            2) system_update ;;
            3) system_clean ;;
            4) read -r -p "Swap 大小(如 0.5G/1G/512M): " s; set_swap "$s" ;;
            5) remove_swap ;;
            6) swap_info ;;
            7) read -r -p "swappiness [10]: " s; set_swappiness "${s:-10}" ;;
            8) read -r -p "保留天数 [7]: " d; journal_clean "${d:-7}" ;;
            9) docker_info ;;
            10) docker_clean ;;
            11) read -r -p "目录 [/]: " p; disk_usage "${p:-/}" ;;
            12) read -r -p "目录 [/]: " p; read -r -p "大小 [500M]: " s; large_files "${p:-/}" "${s:-500M}" ;;
            13) network_check ;;
            14) dns_check ;;
            15) ports ;;
            16) menu_gateway ;;
            17) menu_nfs ;;
            18) menu_nat ;;
            19) top_cpu ;;
            20) top_memory ;;
            21) failed_services ;;
            22) time_info ;;
            23) reboot_required ;;
            24)
                echo "当前更新地址: $UPDATE_URL"
                read -r -p "直接更新? [Y/n]: " yn
                if [ "$yn" != n ] && [ "$yn" != N ]; then self_update; fi
                ;;
            25) echo "sysctl.sh $SCRIPT_VERSION" ;;
            0) exit 0 ;;
            *) red "无效选项" ;;
        esac
        pause
    done
}

case "${1:-}" in
    "") interactive_menu ;;
    version) echo "sysctl.sh $SCRIPT_VERSION" ;;
    deps) dependency_status ;;
    update-self) self_update ;;
    update-url) show_update_url ;;
    rollback-self) self_rollback ;;
    info) system_info ;;
    update) system_update ;;
    clean) system_clean ;;
    swap) set_swap "${2:-}" ;;
    swap-remove) remove_swap ;;
    swap-info) swap_info ;;
    swappiness) set_swappiness "${2:-10}" ;;
    journal) journal_clean "${2:-7}" ;;
    docker) docker_info ;;
    docker-clean) docker_clean ;;
    disk) disk_usage "${2:-/}" ;;
    large-files) large_files "${2:-/}" "${3:-500M}" ;;
    inode) inode_info ;;
    network) network_check "${2:-223.5.5.5}" "${3:-www.baidu.com}" ;;
    dns) dns_check "${2:-www.baidu.com}" ;;
    ports) ports ;;
    gateway)
        case "${2:-show}" in
            show) gateway_show ;;
            set) gateway_set "${3:-}" "${4:-}" ;;
            persist) gateway_persist "${3:-}" "${4:-}" ;;
            *) show_help; exit 1 ;;
        esac
        ;;
    nfs)
        case "${2:-list}" in
            list) nfs_list ;;
            check) nfs_check "${3:-}" ;;
            mount) nfs_mount "${3:-}" "${4:-}" "${5:-defaults,_netdev,nofail,x-systemd.automount}" ;;
            unmount) nfs_unmount "${3:-}" "${4:-}" ;;
            *) show_help; exit 1 ;;
        esac
        ;;
    nat)
        case "${2:-list}" in
            add) nat_add_static "${3:-}" "${4:-}" "${5:-}" "${6:-both}" ;;
            list) nat_list ;;
            del) nat_delete_rule "${3:-}" "${4:-}" ;;
            natcfg) run_natcfg ;;
            *) show_help; exit 1 ;;
        esac
        ;;
    top-mem) top_memory ;;
    top-cpu) top_cpu ;;
    failed) failed_services ;;
    service) service_status "${2:-}" ;;
    time) time_info ;;
    reboot-required) reboot_required ;;
    help|-h|--help) show_help ;;
    *) red "未知命令：$1"; echo; show_help; exit 1 ;;
esac
