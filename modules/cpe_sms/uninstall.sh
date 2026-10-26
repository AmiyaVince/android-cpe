#!/system/bin/sh
###############################################################################
# cpe_sms 卸载：停掉 inotifyd，清掉水位线和队列
# 不碰短信库本身，也不动 /data/adb/cpe/sms.log（留档）
###############################################################################

SMSDIR=/data/adb/modules/cpe_sms
WATCH=$SMSDIR/sms_watch.sh

pkill -f "inotifyd $WATCH" 2>/dev/null

rm -rf /data/adb/cpe/sms.lock 2>/dev/null
rm -f /data/adb/cpe/sms.last_id 2>/dev/null
rm -f /data/adb/cpe/sms.pending 2>/dev/null

echo "cpe_sms: stopped and state cleared"
exit 0
