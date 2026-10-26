#!/system/bin/sh
# 卸载/移除模块时恢复系统默认充电行为（关闭充电上限）
CHG_UP=/sys/devices/virtual/oplus_chg/common/chg_up_limit
[ -e "$CHG_UP" ] && echo "0,80,0,80,2" > "$CHG_UP" 2>/dev/null
exit 0
