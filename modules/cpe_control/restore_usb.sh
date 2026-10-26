#!/system/bin/sh
# 恢复 USB 输入限流（放电结束/熔断时调用）
USB_IL=/sys/class/power_supply/usb/input_current_limit
ORIG_FILE=/data/adb/cpe/usb_il_orig
V=$(cat "$ORIG_FILE" 2>/dev/null)
[ -z "$V" ] && V=900000
echo "$V" > "$USB_IL" 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S') restore_usb: set input_current_limit=$V" >> /data/adb/cpe/discharge.log
