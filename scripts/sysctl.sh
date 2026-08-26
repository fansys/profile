#!/usr/bin/env bash

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SWAP_FILE="/swapfile"
DEFAULT_SWAPPINESS=10
NATCFG_URL="https://raw.githubusercontent.com/arloor/iptablesUtils/refs/heads/master/natcfg.sh"

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

install_packages() {
    require_root
    local pm
    pm="$(get_pkg_manager)"
    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y "$@"
            ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        apk) apk add --no-cache "$@" ;;
        *) red "无法识别软件包管理器"; return 1 ;;
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

gateway_show() {
    ip route show default
}

gateway_set() {
    require_root
    local gw="${1:-}" iface="${2:-}"
    [ -n "$gw" ] || { red "用法: $SCRIPT_NAME gateway set <网关IP> [网卡]"; return 1; }
    if [ -z "$iface" ]; then
        iface="$(ip route show default | awk '{print $5; exit}')"
        [ -n "$iface" ] || iface="$(ip -o link show | awk -F': ' '$2!="lo" {print $2; exit}')"
    fi
    ip route replace default via "$gw" dev "$iface"
    green "默认网关已临时设置为 $gw dev $iface"
    yellow "该设置重启后可能失效；Cloud-Init/PVE 管理的网络建议在 Cloud-Init 中持久化。"
}

gateway_persist_nm() {
    require_root
    local gw="${1:-}" iface="${2:-}" conn
    [ -n "$gw" ] || { red "用法: $SCRIPT_NAME gateway persist <网关IP> [网卡]"; return 1; }
    command_exists nmcli || { red "未检测到 NetworkManager/nmcli，无法安全自动写入持久配置"; return 1; }
    [ -n "$iface" ] || iface="$(ip route show default | awk '{print $5; exit}')"
    conn="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')"
    [ -n "$conn" ] || { red "找不到网卡 $iface 的活动 NetworkManager 连接"; return 1; }
    nmcli connection modify "$conn" ipv4.gateway "$gw"
    nmcli connection up "$conn"
    green "已持久设置连接 [$conn] 的网关为 $gw"
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

nfs_mount() {
    require_root
    local remote="${1:-}" mountpoint="${2:-}" options="${3:-defaults,_netdev,nofail,x-systemd.automount}"
    [ -n "$remote" ] && [ -n "$mountpoint" ] || {
        red "用法: $SCRIPT_NAME nfs mount <server:/path> <本地目录> [options]"
        return 1
    }
    ensure_nfs_client || return 1
    mkdir -p "$mountpoint"

    # 清掉同一挂载点的旧 fstab 项，再写入新配置
    awk -v mp="$mountpoint" '$2 != mp {print}' /etc/fstab > /etc/fstab.tmp.$$ && mv /etc/fstab.tmp.$$ /etc/fstab
    printf '%s %s nfs %s 0 0\n' "$remote" "$mountpoint" "$options" >> /etc/fstab

    if command_exists systemctl; then systemctl daemon-reload; fi
    if ! mount "$mountpoint" 2>/dev/null; then
        # 去掉只适用于 fstab/systemd 的参数后直接尝试挂载
        local direct_options
        direct_options="$(printf '%s' "$options" | sed -E 's/(^|,)(nofail|_netdev|x-systemd\.automount)(,|$)/,/g; s/^,+//; s/,+$//; s/,,+/,/g')"
        if [ -n "$direct_options" ]; then
            mount -t nfs -o "$direct_options" "$remote" "$mountpoint"
        else
            mount -t nfs "$remote" "$mountpoint"
        fi
    fi
    green "NFS 已挂载：$remote -> $mountpoint"
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
    command_exists curl || install_packages curl || return 1
    blue "下载并运行 arloor/iptablesUtils natcfg.sh ..."
    curl -fsSL --retry 3 --connect-timeout 10 "$NATCFG_URL" -o "$tmp" || { rm -f "$tmp"; red "natcfg.sh 下载失败"; return 1; }
    chmod 700 "$tmp"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

# =========================
# 帮助 / 菜单
# =========================

show_help() {
    cat <<EOF
Linux 系统维护工具

用法:
  $SCRIPT_NAME <command> [参数]

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
  swap-remove                  删除 /swapfile
  swap-info                    查看 Swap
  swappiness <0-200>           设置 vm.swappiness

网络:
  network                      网络诊断
  dns [domain]                 DNS 检查
  ports                        查看监听端口
  gateway show                 查看默认网关
  gateway set <gw> [iface]     临时修改默认网关
  gateway persist <gw> [iface] 使用 NetworkManager 持久修改网关

NFS:
  nfs list
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
    echo "12. 查找大文件"
    echo " 0. 退出"
}

menu_gateway() {
    echo "1) 查看网关"
    echo "2) 临时设置网关"
    echo "3) NetworkManager 持久设置"
    read -r -p "请选择: " x
    case "$x" in
        1) gateway_show ;;
        2) read -r -p "网关IP: " gw; read -r -p "网卡(留空自动): " iface; gateway_set "$gw" "$iface" ;;
        3) read -r -p "网关IP: " gw; read -r -p "网卡(留空自动): " iface; gateway_persist_nm "$gw" "$iface" ;;
    esac
}

menu_nfs() {
    echo "1) 查看 NFS"
    echo "2) 挂载 NFS"
    echo "3) 卸载 NFS"
    read -r -p "请选择: " x
    case "$x" in
        1) nfs_list ;;
        2)
            read -r -p "远程地址(server:/path): " remote
            read -r -p "本地目录: " mp
            read -r -p "挂载参数(留空使用默认): " opts
            nfs_mount "$remote" "$mp" "${opts:-defaults,_netdev,nofail,x-systemd.automount}"
            ;;
        3)
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
            0) exit 0 ;;
            *) red "无效选项" ;;
        esac
        pause
    done
}

case "${1:-}" in
    "") interactive_menu ;;
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
            persist) gateway_persist_nm "${3:-}" "${4:-}" ;;
            *) show_help; exit 1 ;;
        esac
        ;;
    nfs)
        case "${2:-list}" in
            list) nfs_list ;;
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
