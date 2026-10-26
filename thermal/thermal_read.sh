#!/system/bin/sh
# 设备侧采集脚本：输出 key=value，一行一项
# 温度单位 0.001°C；-273000 表示该传感器无效
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat "$z/type" 2>/dev/null)
  v=$(cat "$z/temp" 2>/dev/null)
  [ -n "$t" ] && echo "tz.$t=$v"
done

B=/sys/class/power_supply/battery
echo "bat.cap=$(cat $B/capacity 2>/dev/null)"
echo "bat.cur=$(cat $B/current_now 2>/dev/null)"
echo "bat.volt=$(cat $B/voltage_now 2>/dev/null)"
echo "bat.temp=$(cat $B/temp 2>/dev/null)"
echo "bat.status=$(cat $B/status 2>/dev/null)"
echo "bat.cc=$(cat $B/charge_counter 2>/dev/null)"

i=0
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
  echo "cpu.$i=$(cat "$f" 2>/dev/null)"
  i=$((i+1))
done

echo "net.eth0=$(cat /sys/class/net/eth0/operstate 2>/dev/null)"
echo "net.carrier=$(cat /sys/class/net/eth0/carrier 2>/dev/null)"
echo "net.rx=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null)"
echo "net.tx=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null)"
echo "load=$(cat /proc/loadavg 2>/dev/null)"
