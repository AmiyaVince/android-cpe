#!/usr/bin/env bash
# 采样一次温度/频率/供电，追加到 thermal/<tag>.csv
# 用法: ./thermal_log.sh [tag]      tag 默认 no_fan
set -u
ADB="${ADB:-adb}"   # 需要指定路径时：ADB=/path/to/adb ./thermal_log.sh no_fan
TAG="${1:-no_fan}"
# Git Bash 的 pwd 给的是 /e/... 风格，原生 adb 不认，优先取 Windows 风格
DIR="$(cd "$(dirname "$0")" && { pwd -W 2>/dev/null || pwd; })"
CSV="$DIR/$TAG.csv"
DEVSCRIPT=/data/local/tmp/thermal_read.sh

export MSYS_NO_PATHCONV=1
"$ADB" push "$DIR/thermal_read.sh" "$DEVSCRIPT" >/dev/null
raw=$("$ADB" shell su -c "sh $DEVSCRIPT" 2>/dev/null | tr -d '\r')
if [ -z "$raw" ]; then
  echo "采样失败：adb 不通或设备不在线，本次不写入 CSV" >&2
  exit 1
fi

# 取某个 key 的值
get() { printf '%s\n' "$raw" | sed -n "s/^$1=//p" | head -1; }

# 0.001°C -> "25.1"；无效值输出空
fmt() {
  local v="${1:-}"
  [ -z "$v" ] && { printf ""; return; }
  case "$v" in ''|*[!0-9-]*) printf ""; return;; esac
  [ "$v" -lt -100000 ] && { printf ""; return; }
  local w=$((v / 100))
  printf "%d.%d" $((w / 10)) $((w % 10))
}

# 0.1°C -> "31.4"
fmt10() { local v="${1:-}"; [ -z "$v" ] && { printf ""; return; }; printf "%d.%d" $((v / 10)) $((v % 10)); }

freqs=$(printf '%s\n' "$raw" | sed -n 's/^cpu\.\([0-9]*\)=//p' | paste -sd'/' -)

if [ ! -f "$CSV" ]; then
  echo "time,batt,shell_back,shell_front,skin_msm,cpu00,cpu10,cpu13,cpu17,gpu0,mdm0,ddr,pa,sdr0pa,sdr1pa,xo,conn,ipa,usb,cap,cur_uA,volt_uV,status,cc_uAh,freqs,eth0,carrier,rx_bytes,tx_bytes,load" > "$CSV"
fi

line="$(date +%FT%T)"
line="$line,$(fmt "$(get tz.battery)"),$(fmt "$(get tz.shell_back)"),$(fmt "$(get tz.shell_front)"),$(fmt "$(get tz.skin-msm-therm)")"
line="$line,$(fmt "$(get tz.cpu-0-0)"),$(fmt "$(get tz.cpu-1-0)"),$(fmt "$(get tz.cpu-1-3)"),$(fmt "$(get tz.cpu-1-7)")"
line="$line,$(fmt "$(get tz.gpuss-0)"),$(fmt "$(get tz.mdmss-0)"),$(fmt "$(get tz.ddr)"),$(fmt "$(get tz.pa)")"
line="$line,$(fmt "$(get tz.sdr0-pa)"),$(fmt "$(get tz.sdr1-pa)"),$(fmt "$(get tz.xo-therm)")"
line="$line,$(fmt "$(get tz.conn-therm)"),$(fmt "$(get tz.oplus_thermal_ipa)"),$(fmt "$(get tz.usb)")"
line="$line,$(get bat.cap),$(get bat.cur),$(get bat.volt),$(get bat.status),$(get bat.cc)"
line="$line,$freqs,$(get net.eth0),$(get net.carrier),$(get net.rx),$(get net.tx),$(get load)"

echo "$line" | tee -a "$CSV"
