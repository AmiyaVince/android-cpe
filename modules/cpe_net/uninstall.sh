#!/system/bin/sh
###############################################################################
# cpe_net 卸载：撤掉我们自己加的规则，把 eth0 还给 ColorOS
###############################################################################

LOG=/data/adb/cpe/net.log
ETH=eth0
GW=10.68.92.161
PIDF=/data/adb/cpe/dnsmasq_${ETH}.pid

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') uninstall: $*" >> "$LOG"; }

# 停 dnsmasq
if [ -f "$PIDF" ]; then
    P=$(cat "$PIDF" 2>/dev/null)
    [ -n "$P" ] && kill "$P" 2>/dev/null
    rm -f "$PIDF"
    log "dnsmasq stopped"
fi

# 撤 iptables（尽力而为）
for UP in rmnet_data0 rmnet_data1 rmnet_data2 rmnet_data3 rmnet_data4 rmnet_data5; do
    iptables -t nat -D POSTROUTING -o "$UP" -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i "$ETH" -o "$UP" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$UP" -o "$ETH" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$UP" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -i "$UP" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
done

# 撤掉我们加的 IP
ip addr del "$GW/24" dev "$ETH" 2>/dev/null

log "done"
exit 0
