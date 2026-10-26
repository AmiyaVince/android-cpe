#!/system/bin/sh
###############################################################################
# cpe_sms - 短信转发模块（开机自启 + 看门狗）
#
# 结构：
#   1. 等 sys.boot_completed
#   2. 等 FBE 解锁（锁屏没解除前 /data 不可读，短信库也读不到）
#   3. 初始化水位线
#   4. 起 inotifyd 监听短信库（事件触发，约 1.5 秒送达）
#   5. 每 POLL 秒兜底轮询一次，顺便检查 inotifyd 是否还活着
#
# 手动用法：
#   sh service.sh status
#   sh service.sh test
#   sh service.sh send 123
#   sh service.sh resend
#   sh service.sh start | stop | restart
###############################################################################

CONF=/data/adb/cpe/sms.conf
LOG=/data/adb/cpe/sms.log
STATE_DIR=/data/adb/cpe
LAST_ID_FILE=$STATE_DIR/sms.last_id
PENDING_FILE=$STATE_DIR/sms.pending

SMSDIR=/data/adb/modules/cpe_sms
WATCH=$SMSDIR/sms_watch.sh
DB_DIR=/data/data/com.android.providers.telephony/databases
DB_FILE=$DB_DIR/mmssms.db

POLL=60

mkdir -p "$STATE_DIR" 2>/dev/null
[ -f "$CONF" ] && . "$CONF"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ---- 日志轮转（256KB）----
if [ -f "$LOG" ]; then
    SZ=$(wc -c < "$LOG" 2>/dev/null)
    [ -n "$SZ" ] && [ "$SZ" -gt 262144 ] && mv -f "$LOG" "$LOG.1"
fi

###############################################################################
# 工具
###############################################################################

inotify_alive() {
    pgrep -f "inotifyd $WATCH" >/dev/null 2>&1
}

start_inotify() {
    if inotify_alive; then
        log "inotifyd 已在运行"
        return 0
    fi
    if [ ! -f "$WATCH" ]; then
        log "FATAL: $WATCH 不存在"
        return 1
    fi
    # 目录事件（journal 创建/删除）+ 数据库文件事件（写入/关闭）双保险
    setsid inotifyd "$WATCH" "$DB_DIR:nmdy" "$DB_FILE:cw" >/dev/null 2>&1 </dev/null &
    sleep 1
    if inotify_alive; then
        log "inotifyd 已启动"
        return 0
    fi
    log "inotifyd 启动失败"
    return 1
}

stop_inotify() {
    if inotify_alive; then
        pkill -f "inotifyd $WATCH" 2>/dev/null
        sleep 1
        log "inotifyd 已停止"
    fi
}

# FBE 解锁判据：deviceLocked=0 才说明 CE 存储可用
unlocked() {
    dumpsys trust 2>/dev/null | grep -q "deviceLocked=0"
}

###############################################################################
# 子命令（手动调用走这里，不进入看门狗循环）
###############################################################################
case "$1" in
    start)
        start_inotify
        exit $?
        ;;
    stop)
        stop_inotify
        exit 0
        ;;
    restart)
        stop_inotify
        sleep 1
        start_inotify
        exit $?
        ;;
    init)
        sh "$WATCH" --init
        exit $?
        ;;
    test)
        sh "$WATCH" --test
        exit $?
        ;;
    send)
        sh "$WATCH" --send "$2"
        exit $?
        ;;
    resend)
        sh "$WATCH" --resend
        exit $?
        ;;
    status)
        echo "inotify : $(inotify_alive && echo alive || echo dead)"
        echo "unlocked: $(unlocked && echo yes || echo NO)"
        echo "last_id : $(cat "$LAST_ID_FILE" 2>/dev/null || echo -)"
        echo "last_dt : $(cat "$STATE_DIR/sms.last_date" 2>/dev/null || echo -)"
        if [ -f "$PENDING_FILE" ]; then
            echo "pending : $(wc -l < "$PENDING_FILE" 2>/dev/null)"
        else
            echo "pending : 0"
        fi
        echo "bark    : $([ -n "$BARK_KEY" ] && echo "configured (${#BARK_KEY} chars)" || echo MISSING)"
        echo "poll    : ${POLL}s"
        echo "--- last log ---"
        tail -6 "$LOG" 2>/dev/null
        exit 0
        ;;
esac

###############################################################################
# 开机流程
###############################################################################
log "=== cpe_sms boot ==="

N=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$N" -lt 180 ]; do
    sleep 2
    N=$((N + 1))
done

# 等用户解锁（关掉安全锁屏的话这一关会直接过）
N=0
while ! unlocked; do
    N=$((N + 1))
    if [ $((N % 15)) -eq 1 ]; then
        log "等待手机解锁（FBE 锁定中，短信库暂不可读）..."
    fi
    sleep 2
done
log "存储已解锁"

sh "$WATCH" --init

start_inotify

# ---- 看门狗 ----
log "watchdog started (${POLL}s)"
while true; do
    sleep "$POLL"
    [ -f "$CONF" ] && . "$CONF"
    if ! inotify_alive; then
        log "inotifyd 不在了，重启"
        start_inotify
    fi
    sh "$WATCH" --poll
done
