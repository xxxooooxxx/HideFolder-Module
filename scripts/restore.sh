#!/system/bin/sh
# 恢复所有隐藏（按 active.txt 记录逐个 umount）
. "$(dirname "$0")/common.sh"

[ -f "$STATE" ] || exit 0
while IFS='|' read -r kind a b; do
  case "$kind" in
    global) do_show_global "$a" ;;
    app)    do_show_app "$a" "$b" ;;
  esac
done < "$STATE"
: > "$STATE"
log "restore all done"
echo "OK|已恢复全部"
