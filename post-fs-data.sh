#!/system/bin/sh
# 开机早期（zygote 启动前）应用全局隐藏规则，
# 此时挂载对之后启动的所有应用都可见
MODDIR=${0%/*}
. "$MODDIR/scripts/common.sh"
ensure_dirs
log "post-fs-data: apply global rules"
sh "$MODDIR/scripts/apply.sh" global-only
