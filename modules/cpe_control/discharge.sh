#!/system/bin/sh
###############################################################################
# discharge.sh - 一次性放电控制器（临时用，不进开机模块）
#
# 目标：把电池从当前电量放到 TARGET%，然后恢复 USB 输入限流。
# 原理：把 /sys/class/power_supply/usb/input_current_limit 设为 0，
#       手机失去外部供电 -> 靠电池运行 -> 电量下降。USB 数据不受影响。
#
# 安全设计（重要）：
#   * 三重熔断：到达 TARGET / 触及 FLOOR / 超过 MAX_HOURS，任一触发即恢复输入
#   * 脚本跑在手机上，不依赖电脑；电脑掉线不影响熔断
#   * 手机若中途重启，input_current_limit 会复位为默认值，天然安全
###############################################################################

LOG=/data/adb/cpe/discharge.log
USB_IL=/sys/class/power_supply/usb/input_current_limit
ORIG_FILE=/data/adb/cpe/usb_il_orig
BAT_CAP=/sys/class/power_supply/battery/capacity
BAT_CUR=/sys/class/power_supply/battery/current_now

TARGET=50      # 到达该电量即停止放电
FLOOR=46       # 熔断下限（绝不低于此值）
MAX_HOURS=20   # 最长运行时长

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
cap() { cat "$BAT_CAP" 2>/dev/null; }
cur() { cat "$BAT_CUR" 2>/dev/null; }

restore_and_exit() {
    echo "$ORIG" > "$USB_IL" 2>/dev/null
    log "RESTORE input_current_limit=$ORIG (rc=$?) capacity=$(cap)"
    exit 0
}

# 备份原始输入限流
if [ ! -f "$ORIG_FILE" ]; then
    cat "$USB_IL" > "$ORIG_FILE" 2>/dev/null
fi
ORIG=$(cat "$ORIG_FILE" 2>/dev/null)
[ -z "$ORIG" ] && ORIG=900000

log "=== discharge START: capacity=$(cap)% cur=$(cur) orig_il=$ORIG target=${TARGET}% floor=${FLOOR}% ==="

echo 0 > "$USB_IL" 2>/dev/null
log "input_current_limit -> 0 (rc=$?)"

start=$(date +%s)
while true; do
    sleep 60
    c=$(cap)
    case "$c" in ''|*[!0-9]*) log "tick: cap read failed [$c], skip"; continue ;; esac

    if [ "$c" -le "$TARGET" ]; then
        log "TARGET REACHED: capacity=${c}%"
        restore_and_exit
    fi
    if [ "$c" -le "$FLOOR" ]; then
        log "FLOOR HIT: capacity=${c}%"
        restore_and_exit
    fi
    now=$(date +%s)
    if [ $(( (now - start) / 3600 )) -ge "$MAX_HOURS" ]; then
        log "TIMEOUT after ${MAX_HOURS}h: capacity=${c}%"
        restore_and_exit
    fi
    log "tick capacity=${c}% cur=$(cur) elapsed=$(( (now - start) / 60 ))min"
done
