#!/system/bin/sh
###############################################################################
# cpe_sms - 短信 -> Bark 推送（处理器）
#
# 调用方式：
#   sms_watch.sh            inotifyd 事件回调（参数忽略）
#   sms_watch.sh --poll     兜底轮询
#   sms_watch.sh --init     初始化水位线（默认不补发历史短信）
#   sms_watch.sh --test     发一条测试推送
#   sms_watch.sh --send ID  单独转发某条短信
#   sms_watch.sh --resend   重发失败队列
#
# 幂等：水位线是 (date, _id) 复合游标，重复调用不会重复推送。
#   ⚠️ 不能只用 _id：SQLite 的 rowid 会复用已删除的最大 id，
#      删掉一条短信后新短信可能拿到同一个 id（实测踩过）。
#
# 隐私：日志只记号码 / 长度 / 结果，不落短信正文。
###############################################################################

CONF=/data/adb/cpe/sms.conf
LOG=/data/adb/cpe/sms.log
STATE_DIR=/data/adb/cpe
LAST_ID_FILE=$STATE_DIR/sms.last_id
LAST_DATE_FILE=$STATE_DIR/sms.last_date
PENDING_FILE=$STATE_DIR/sms.pending
LOCK_DIR=$STATE_DIR/sms.lock

# ---- 默认配置（可被 $CONF 覆盖）----
BARK_SERVER=https://api.day.app
BARK_KEY=
GROUP=cpe-sms
SOUND=default
LEVEL=active
TITLE_PREFIX=短信
COPY_ON_TAP=1
FORWARD_EXISTING=0
RETRY=3
MAX_BATCH=20
DEBOUNCE=1

mkdir -p "$STATE_DIR" 2>/dev/null
[ -f "$CONF" ] && . "$CONF"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ---- 日志轮转（256KB）----
if [ -f "$LOG" ]; then
    SZ=$(wc -c < "$LOG" 2>/dev/null)
    [ -n "$SZ" ] && [ "$SZ" -gt 262144 ] && mv -f "$LOG" "$LOG.1"
fi

###############################################################################
# 锁：inotify 事件和兜底轮询可能同时进来，只让一个干活
###############################################################################
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
        return 0
    fi
    # 上次异常退出留下的死锁
    OLD=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$OLD" ] && ! kill -0 "$OLD" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
            return 0
        fi
    fi
    return 1
}

###############################################################################
# 读短信库
#
# 输出格式（content 命令固定）：
#   Row: 0 _id=7, address=95559, date=1792317315003, sub_id=1, body=正文
# body 里可能有换行，所以按单条查询、只从第一行剥前缀，后续行原样保留。
###############################################################################
q() { content query --uri content://sms "$@" 2>/dev/null; }

max_id() {
    q --projection _id --sort "_id DESC" \
        | sed -n '1s/^Row: [0-9]* _id=\([0-9]*\).*/\1/p'
}

max_date() {
    q --projection date --sort "date DESC" \
        | sed -n '1s/^Row: [0-9]* date=\([0-9]*\).*/\1/p'
}

# 复合游标：date 更大，或 date 相同但 _id 更大
# 这样即使 rowid 被复用（新短信拿到旧 id），也能靠 date 抓到。
new_rows_after() {
    # $1=last_date $2=last_id
    q --projection _id,date \
      --where "date > $1 OR _id > $2" \
      --sort "date ASC, _id ASC" \
      | sed -n 's/^Row: [0-9]* _id=\([0-9]*\), date=\([0-9]*\).*/\1 \2/p'
}

fetch_row() {
    q --projection address,sub_id,body --where "_id = $1"
}

row_address() {
    printf '%s\n' "$1" | sed -n '1s/^Row: [0-9]* address=\([^,]*\), sub_id=.*/\1/p'
}
row_sub() {
    printf '%s\n' "$1" | sed -n '1s/^Row: [0-9]* address=[^,]*, sub_id=\([0-9]*\), body=.*/\1/p'
}
row_body() {
    printf '%s\n' "$1" | sed -n '1s/^Row: [0-9]* address=[^,]*, sub_id=[0-9]*, body=//p'
    printf '%s\n' "$1" | sed -n '2,$p'
}

###############################################################################
# 推送
#
# 用 form 编码而不是 JSON：短信正文里的引号、反斜杠、换行、中文全部交给
# curl --data-urlencode 处理，脚本里不需要写任何转义。
###############################################################################
send_bark() {
    TITLE=$1
    BODY=$2
    if [ -z "$BARK_KEY" ]; then
        log "ERROR: BARK_KEY 未配置，跳过推送"
        return 1
    fi
    if [ "$COPY_ON_TAP" = "1" ]; then
        COPY=$BODY
    else
        COPY=
    fi
    I=0
    RESP=
    while [ "$I" -lt "$RETRY" ]; do
        RESP=$(curl -sS --max-time 15 -X POST "$BARK_SERVER/push" \
            --data-urlencode "device_key=$BARK_KEY" \
            --data-urlencode "title=$TITLE" \
            --data-urlencode "body=$BODY" \
            --data-urlencode "group=$GROUP" \
            --data-urlencode "level=$LEVEL" \
            --data-urlencode "sound=$SOUND" \
            --data-urlencode "copy=$COPY" 2>/dev/null)
        case "$RESP" in
            *'"code":200'*) return 0 ;;
        esac
        I=$((I + 1))
        [ "$I" -lt "$RETRY" ] && sleep $((I * 2))
    done
    log "ERROR: Bark 失败: $RESP"
    return 1
}

###############################################################################
# 主流程
###############################################################################
notification_title() {
    # $1=address $2=sub_id
    T="$TITLE_PREFIX"
    [ -n "$2" ] && T="$T · SIM$2"
    [ -n "$1" ] && T="$T · $1"
    echo "$T"
}

# $1=_id  $2=是否入队（1=失败入队，0=由调用方处理）
forward_one() {
    ID=$1
    QUEUE=${2:-1}
    ROW=$(fetch_row "$ID")
    if [ -z "$ROW" ]; then
        log "id=$ID 读取为空，跳过"
        return 2
    fi
    ADDR=$(row_address "$ROW")
    SUB=$(row_sub "$ROW")
    BODY=$(row_body "$ROW")
    [ -n "$BODY" ] || BODY="(空短信)"
    TT=$(notification_title "$ADDR" "$SUB")
    if send_bark "$TT" "$BODY"; then
        log "sent id=$ID from=$ADDR sub=$SUB len=${#BODY}"
        return 0
    fi
    log "FAILED id=$ID from=$ADDR sub=$SUB"
    [ "$QUEUE" = "1" ] && echo "$ID" >> "$PENDING_FILE"
    return 1
}

flush_pending() {
    [ -s "$PENDING_FILE" ] || return 0
    TMP="$PENDING_FILE.tmp"
    : > "$TMP"
    while IFS= read -r ID; do
        [ -n "$ID" ] || continue
        forward_one "$ID" 0
        RC=$?
        case "$RC" in
            0) log "resend ok id=$ID" ;;
            2) : ;;                        # 短信已被删除，丢弃
            *) echo "$ID" >> "$TMP" ;;     # 仍然失败，留在队列
        esac
    done < "$PENDING_FILE"
    mv -f "$TMP" "$PENDING_FILE"
}

ensure_state() {
    if [ "$FORWARD_EXISTING" = "1" ] && [ ! -s "$LAST_ID_FILE" ]; then
        echo 0 > "$LAST_ID_FILE"
        echo 0 > "$LAST_DATE_FILE"
        log "FORWARD_EXISTING=1，水位线置 0（将补发历史短信）"
        return 0
    fi
    if [ -s "$LAST_ID_FILE" ] && [ -s "$LAST_DATE_FILE" ]; then
        return 0
    fi
    # 首次安装 / 从旧版本升级：以当前库的最大值作为起点，不补发历史
    LID=$(max_id); [ -n "$LID" ] || LID=0
    LD=$(max_date); [ -n "$LD" ] || LD=0
    echo "$LID" > "$LAST_ID_FILE"
    echo "$LD" > "$LAST_DATE_FILE"
    log "初始化水位线 last_id=$LID last_date=$LD（不补发历史短信）"
}

process_new() {
    LAST_ID=$(cat "$LAST_ID_FILE" 2>/dev/null); [ -n "$LAST_ID" ] || LAST_ID=0
    LAST_DATE=$(cat "$LAST_DATE_FILE" 2>/dev/null); [ -n "$LAST_DATE" ] || LAST_DATE=0
    ROWS=$(new_rows_after "$LAST_DATE" "$LAST_ID")
    [ -z "$ROWS" ] && return 0
    N=0
    while read -r ID DATE; do
        [ -n "$ID" ] || continue
        N=$((N + 1))
        if [ "$N" -gt "$MAX_BATCH" ]; then
            log "达到单次上限 $MAX_BATCH，剩余留待下次"
            break
        fi
        forward_one "$ID"
        # 只有推进了才写盘，避免空转
        echo "$ID" > "$LAST_ID_FILE"
        if [ -n "$DATE" ] && [ "$DATE" -gt "$LAST_DATE" ]; then
            echo "$DATE" > "$LAST_DATE_FILE"
            LAST_DATE=$DATE
        fi
        LAST_ID=$ID
    done <<EOF
$ROWS
EOF
}

###############################################################################
# 入口
###############################################################################
case "$1" in
    --init)
        ensure_state
        exit $?
        ;;
    --test)
        if send_bark "CPE 短信转发" "测试：$(date '+%H:%M:%S') 链路正常"; then
            echo "test: OK"
            exit 0
        fi
        echo "test: FAILED"
        exit 1
        ;;
    --send)
        [ -n "$2" ] || { echo "usage: $0 --send ID"; exit 2; }
        forward_one "$2"
        exit $?
        ;;
    --resend)
        acquire_lock || exit 0
        flush_pending
        exit 0
        ;;
    --poll)
        acquire_lock || exit 0
        ensure_state
        flush_pending
        process_new
        exit 0
        ;;
esac

# ---- 默认：inotifyd 事件回调 ----
acquire_lock || exit 0
sleep "$DEBOUNCE"     # 等 SQLite 提交
ensure_state
flush_pending
process_new
sleep 1
process_new           # 接住提交稍晚的那一条
exit 0
