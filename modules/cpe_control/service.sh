#!/system/bin/sh
###############################################################################
# cpe_control - OnePlus 10 Pro (NE2210) CPE boot control
#
# 作用：开机后重新应用内核原生充电上限。
#   本机重启会把 chg_up_limit 复位成 0,80,0,80,2，所以必须每次开机重写。
#
# 节点：/sys/devices/virtual/oplus_chg/common/chg_up_limit
# 格式：enable,upper,force,lower,callname
#   内核 monitor_ui_soc_to_enable_chg_up_limit 每 ~6s 轮询：
#   ui_soc >= upper  -> 自动写 mmi_charging_enable=0（停充/旁路）
#   ui_soc <  lower  -> 恢复充电
#   中间区间保持状态
###############################################################################

MODDIR=${0%/*}
CFG=/data/adb/cpe/config.conf
LOG=/data/adb/cpe/cpe.log
CHG_UP=/sys/devices/virtual/oplus_chg/common/chg_up_limit

mkdir -p /data/adb/cpe

# 首次运行生成配置
if [ ! -f "$CFG" ]; then
    cat > "$CFG" <<'EOF'
# ===== CPE 充电上限配置 =====
# UPPER: 充到该电量停止（默认 50）
# LOWER: 掉到该电量恢复充电（默认 45）
# ENABLE: 1=启用本策略；0=关闭，恢复系统默认 0,80,0,80,2（满充）
# 改完保存即可，看门狗 60 秒内自动生效，无需重启。
UPPER=50
LOWER=45
ENABLE=1
EOF
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ]; then
        : > "$LOG"
    fi
}

# 等 sysfs 节点就绪（充电驱动可能比 late_start 晚）
i=0
while [ ! -e "$CHG_UP" ] && [ "$i" -lt 120 ]; do
    sleep 1
    i=$((i + 1))
done

if [ ! -e "$CHG_UP" ]; then
    log "FATAL: $CHG_UP not found after ${i}s, giving up"
    exit 1
fi
log "boot: charge node ready after ${i}s"

apply() {
    # 每次重新读取配置，实现热更新
    # shellcheck disable=SC1090
    . "$CFG" 2>/dev/null
    UPPER=${UPPER:-50}
    LOWER=${LOWER:-45}
    ENABLE=${ENABLE:-1}

    if [ "$ENABLE" = "1" ]; then
        want="1,${UPPER},1,${LOWER},2"
    else
        want="0,80,0,80,2"
    fi

    cur=$(cat "$CHG_UP" 2>/dev/null)
    if [ "$cur" != "$want" ]; then
        echo "$want" > "$CHG_UP" 2>/dev/null
        rc=$?
        log "apply: [$cur] -> [$want] rc=$rc"
    fi
}

apply
log "watchdog started (60s interval)"

while true; do
    sleep 60
    apply
done
