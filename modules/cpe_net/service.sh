#!/system/bin/sh
###############################################################################
# cpe_net - 把一加 10 Pro 的 USB 网卡做成 CPE 的下游出口
#
# 目标：开机后自动把 5G 分享到 eth0，不需要人去点 ColorOS 的共享开关，
#       并且开关被系统关掉 / 链路抖动之后能自己恢复。
#
# 做四件事（全部幂等，可重复执行）：
#   1. eth0 拉起 + 配网关 IP（10.68.92.161/24，沿用 ColorOS 的网段）
#   2. 打开 IPv4 转发
#   3. iptables MASQUERADE（下游 -> 5G 上行）+ MSS clamp（上行 MTU 只有 1400）
#   4. dnsmasq 提供 DHCP + DNS
#
# 与 ColorOS 原生「以太网网络共享」共存策略：
#   检测到 ColorOS 已经接管（dumpsys ethernet 显示 Tethering interface mode: 2）时，
#   只补 iptables，不抢 IP、不起 dnsmasq —— 避免两个 DHCP 服务器打架。
###############################################################################

LOG=/data/adb/cpe/net.log
CONF=/data/adb/cpe/net.conf
ETH=eth0

# ---- 默认配置（可被 $CONF 覆盖）----
GW=10.68.92.161
DHCP_START=10.68.92.100
DHCP_END=10.68.92.200
DNS1=223.5.5.5
DNS2=114.114.114.114
DHCP_MTU=1400
POLL=30
# 管理地址：FTTR（192.168.1.1）降级成二层交换机后，下游客户端都在手机的共享网段里，
# 够不到 192.168.1.1。给 eth0 挂一个同网段的地址，手机就能管 FTTR：
#   curl --interface 192.168.1.250 http://192.168.1.1/cgi-bin/luci
# 置空可关闭。
MGMT_ALIAS=192.168.1.250/24
# 拉起 ColorOS 原生「以太网网络共享」的小工具（app_process + 反射调 TetheringManager）。
# 没有它就只能靠 UI 开关，开机不会自启、抖动掉了也回不来。置空可关闭这项功能。
TETHER_HELPER=/data/adb/modules/cpe_net/tetherctl.dex

mkdir -p /data/adb/cpe 2>/dev/null

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ---- 配置热加载 ----
[ -f "$CONF" ] && . "$CONF"

DNSMASQ_PID=/data/adb/cpe/dnsmasq_${ETH}.pid

# ---- 日志轮转（256KB）----
if [ -f "$LOG" ]; then
    SZ=$(wc -c < "$LOG" 2>/dev/null)
    [ -n "$SZ" ] && [ "$SZ" -gt 262144 ] && mv -f "$LOG" "$LOG.1"
fi

###############################################################################
# 工具函数
###############################################################################

# 找上游：第一个有 IPv4 的 rmnet 接口（通常是 rmnet_data3）
find_upstream() {
    for i in rmnet_data0 rmnet_data1 rmnet_data2 rmnet_data3 rmnet_data4 rmnet_data5; do
        if ip -4 addr show "$i" 2>/dev/null | grep -q "inet "; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# ColorOS 是否已经接管了 eth0 的共享（mode 2 = SERVER）
coloros_owns() {
    dumpsys ethernet 2>/dev/null | grep -q "Tethering interface mode: 2"
}

# 调 helper 拉起以太网共享。返回 0 表示已经是开着 / 刚刚拉起来。
# helper 输出：
#   RESULT:STARTED   刚拉起来
#   RESULT:FAILED error=18   DUPLICATE_REQUEST —— 本来就开着（正常）
#   RESULT:FAILED error=NN   真失败
tether_up() {
    [ -n "$TETHER_HELPER" ] && [ -f "$TETHER_HELPER" ] || return 1

    OUT=$(CLASSPATH="$TETHER_HELPER" app_process /system/bin cpecpe.TetherCtl start 2>&1)
    case "$OUT" in
        *STARTED*)
            log "tether: 已拉起（STARTED）"
            return 0
            ;;
        *"error=18"*)
            # DUPLICATE_REQUEST：已经开着，什么都不用做
            return 0
            ;;
        *)
            log "tether: 拉起失败 -> $OUT"
            return 1
            ;;
    esac
}

# 等 eth0 出现（最多 10 分钟）
wait_eth() {
    n=0
    while [ $n -lt 300 ]; do
        [ -e "/sys/class/net/$ETH" ] && return 0
        sleep 2
        n=$((n + 1))
    done
    return 1
}

###############################################################################
# dnsmasq
###############################################################################

dnsmasq_alive() {
    [ -f "$DNSMASQ_PID" ] || return 1
    P=$(cat "$DNSMASQ_PID" 2>/dev/null)
    [ -n "$P" ] || return 1
    kill -0 "$P" 2>/dev/null
}

start_dnsmasq() {
    dnsmasq_alive && return 0

    # 先清掉可能残留的、由我们启动的实例
    stop_dnsmasq

    /system/bin/dnsmasq \
        --keep-in-foreground \
        --no-resolv \
        --no-poll \
        --no-hosts \
        --interface="$ETH" \
        --bind-interfaces \
        --dhcp-authoritative \
        --dhcp-range="$DHCP_START,$DHCP_END,12h" \
        --dhcp-option=1,255.255.255.0 \
        --dhcp-option=3,"$GW" \
        --dhcp-option=6,"$DNS1,$DNS2" \
        --dhcp-option=26,"$DHCP_MTU" \
        --server="$DNS1" \
        --server="$DNS2" \
        --pid-file="$DNSMASQ_PID" \
        --user=root \
        >>"$LOG" 2>&1 &

    sleep 1
    if dnsmasq_alive; then
        log "dnsmasq started (pid=$(cat $DNSMASQ_PID), range=$DHCP_START-$DHCP_END)"
    else
        log "dnsmasq FAILED to start"
    fi
}

stop_dnsmasq() {
    if [ -f "$DNSMASQ_PID" ]; then
        P=$(cat "$DNSMASQ_PID" 2>/dev/null)
        [ -n "$P" ] && kill "$P" 2>/dev/null && log "dnsmasq stopped (pid=$P)"
        rm -f "$DNSMASQ_PID"
    fi
}

###############################################################################
# iptables（幂等）
###############################################################################

ensure_nat() {
    UP="$1"

    # MASQUERADE：下游出 5G 上行
    if ! iptables -t nat -C POSTROUTING -o "$UP" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$UP" -j MASQUERADE 2>/dev/null \
            && log "nat: MASQUERADE -o $UP"
    fi

    # 转发放行
    iptables -C FORWARD -i "$ETH" -o "$UP" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$ETH" -o "$UP" -j ACCEPT 2>/dev/null

    iptables -C FORWARD -i "$UP" -o "$ETH" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$UP" -o "$ETH" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

    # MSS clamp：5G 上行 MTU 只有 1400，不夹的话下游大包会卡
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$UP" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$UP" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

    # 反方向也要夹（下游 MTU 1500 -> 上游 1400）
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -i "$UP" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i "$UP" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
}

###############################################################################
# 主逻辑
###############################################################################

apply() {
    ip link set "$ETH" up 2>/dev/null

    UP=$(find_upstream)
    if [ -z "$UP" ]; then
        log "apply: 还没有上游数据接口，跳过"
        return 1
    fi

    OWNED=0
    coloros_owns && OWNED=1

    # 0. 共享没开就主动拉起来（开机不自启 / 链路抖动掉了，全靠这里自愈）
    if [ "$OWNED" = "0" ]; then
        if tether_up; then
            sleep 2
            coloros_owns && OWNED=1
        fi
    fi

    # 1. IP（ColorOS 在管的话它自己会配，我们不抢）
    if [ "$OWNED" = "0" ]; then
        if ! ip -4 addr show "$ETH" 2>/dev/null | grep -q "$GW/"; then
            ip addr add "$GW/24" dev "$ETH" 2>/dev/null && log "eth0: +$GW/24"
        fi
    fi

    # 1b. 管理地址（无论 ColorOS 管不管共享都要挂，用来管理被降级的 FTTR）
    if [ -n "$MGMT_ALIAS" ] && ! ip -4 addr show "$ETH" 2>/dev/null | grep -q "inet ${MGMT_ALIAS%/*}/"; then
        ip addr add "$MGMT_ALIAS" dev "$ETH" 2>/dev/null && log "eth0: +$MGMT_ALIAS (管理地址)"
    fi

    # 2. 转发
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null && log "ip_forward=1"
    fi

    # 3. NAT
    ensure_nat "$UP"

    # 4. DHCP
    if [ "$OWNED" = "1" ]; then
        dnsmasq_alive && stop_dnsmasq
    else
        start_dnsmasq
    fi

    return 0
}

# ---- 手动调用入口（调试用，不影响开机流程）----
#   sh service.sh apply   立刻应用一次
#   sh service.sh stop    停掉我们起的 dnsmasq
#   sh service.sh status  打印当前状态
case "$1" in
    apply)
        apply
        exit $?
        ;;
    stop)
        stop_dnsmasq
        exit 0
        ;;
    tether)
        tether_up && echo "tether: OK" || echo "tether: FAIL"
        exit 0
        ;;
    status)
        echo "eth0 ip:  $(ip -4 addr show $ETH 2>/dev/null | grep inet | tr -s ' ')"
        echo "upstream: $(find_upstream)"
        echo "coloros:  $(coloros_owns && echo YES || echo no)"
        echo "dnsmasq:  $(dnsmasq_alive && echo "alive pid=$(cat $DNSMASQ_PID)" || echo dead)"
        echo "ip_fwd:   $(cat /proc/sys/net/ipv4/ip_forward)"
        exit 0
        ;;
esac

# ---- 开机：等系统起来 ----
log "=== cpe_net boot ==="
n=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $n -lt 180 ]; do
    sleep 2
    n=$((n + 1))
done
sleep 15

if ! wait_eth; then
    log "FATAL: eth0 一直没出现，退出"
    exit 1
fi
log "eth0 已就绪"

apply

# ---- 看门狗 ----
log "watchdog started (${POLL}s)"
while true; do
    sleep "$POLL"
    # 配置热加载
    [ -f "$CONF" ] && . "$CONF"
    apply
done
