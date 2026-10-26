#!/system/bin/sh
# Read-only CPE diagnostics on the phone.
echo "== eth0 stats =="
for f in rx_bytes rx_packets tx_bytes tx_packets rx_errors tx_errors rx_dropped tx_dropped; do
  printf '%s=' "$f"; cat /sys/class/net/eth0/statistics/$f 2>/dev/null
done
echo "== rmnet_data3 stats =="
for f in rx_bytes rx_packets tx_bytes tx_packets rx_errors tx_errors rx_dropped tx_dropped; do
  printf '%s=' "$f"; cat /sys/class/net/rmnet_data3/statistics/$f 2>/dev/null
done
echo "== eth0 carrier/speed =="
cat /sys/class/net/eth0/carrier /sys/class/net/eth0/speed 2>/dev/null
echo "== tethering =="
dumpsys tethering 2>/dev/null | grep -E "eth0 -|wlan2 -|Current upstream|enableBpfOffload"
echo "== ip rule =="
ip rule show | head -12
echo "== wifi scan channel info =="
# 只显示指定 SSID 的扫描结果；用法：SSID=你的WiFi名 sh cpe_diag.sh
[ -n "${SSID:-}" ] && cmd wifi list-scan-results 2>/dev/null | grep -iF "$SSID"
echo "== wifi status =="
cmd wifi status 2>/dev/null | head -5
