#!/system/bin/sh
# 0.5 秒粒度采样 60 秒，记录各测点峰值 + cpu7 频率上限的变化
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat "$z/type" 2>/dev/null)
  case "$t" in
    battery)           ZB=$z ;;
    shell_back)        ZSB=$z ;;
    skin-msm-therm)    ZSK=$z ;;
    cpu-1-5)           ZC5=$z ;;
    cpu-1-2)           ZC2=$z ;;
    cpu-1-7)           ZC7=$z ;;
    gpuss-0)           ZG=$z ;;
    mdmss-0)           ZM=$z ;;
  esac
done

mb=0; msb=0; msk=0; mc5=0; mc2=0; mc7=0; mg=0; mm=0
capmin=99999999; capmax=0
n=0
while [ $n -lt 120 ]; do
  v=$(cat $ZB/temp 2>/dev/null);  [ "${v:-0}" -gt $mb ] && mb=$v
  v=$(cat $ZSB/temp 2>/dev/null); [ "${v:-0}" -gt $msb ] && msb=$v
  v=$(cat $ZSK/temp 2>/dev/null); [ "${v:-0}" -gt $msk ] && msk=$v
  v=$(cat $ZC5/temp 2>/dev/null); [ "${v:-0}" -gt $mc5 ] && mc5=$v
  v=$(cat $ZC2/temp 2>/dev/null); [ "${v:-0}" -gt $mc2 ] && mc2=$v
  v=$(cat $ZC7/temp 2>/dev/null); [ "${v:-0}" -gt $mc7 ] && mc7=$v
  v=$(cat $ZG/temp 2>/dev/null);  [ "${v:-0}" -gt $mg ] && mg=$v
  v=$(cat $ZM/temp 2>/dev/null);  [ "${v:-0}" -gt $mm ] && mm=$v
  v=$(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 2>/dev/null)
  [ -n "$v" ] && [ "$v" -lt $capmin ] && capmin=$v
  [ -n "$v" ] && [ "$v" -gt $capmax ] && capmax=$v
  n=$((n+1))
  sleep 0.5
done

echo "=== 60 秒峰值 ==="
echo "battery      = $mb"
echo "shell_back   = $msb"
echo "skin-msm     = $msk"
echo "cpu-1-5      = $mc5"
echo "cpu-1-2      = $mc2"
echo "cpu-1-7      = $mc7"
echo "gpuss-0      = $mg"
echo "mdmss-0      = $mm"
echo "=== cpu7 频率上限 ==="
echo "min = $capmin"
echo "max = $capmax"
