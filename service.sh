#!/system/bin/sh
# late_start：在 /sdcard 就绪后补应用全局规则，
# 并启动后台任务，定期为新启动的目标应用应用按应用隐藏规则
MODDIR=${0%/*}
. "$MODDIR/scripts/common.sh"
ensure_dirs
log "service: apply global rules (late)"
sh "$MODDIR/scripts/apply.sh" global-only

(
  sleep 20
  sh "$MODDIR/scripts/apply.sh"
  while true; do
    sleep 120
    sh "$MODDIR/scripts/apply.sh" app-only
  done
) &
