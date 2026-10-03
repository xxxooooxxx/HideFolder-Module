#!/system/bin/sh
# 按 rules.txt 应用隐藏规则（幂等，可重复执行）
# 用法: apply.sh [global-only|app-only]   默认全部
. "$(dirname "$0")/common.sh"
ensure_dirs

mode="${1:-all}"
[ -f "$RULES" ] || exit 0

while IFS='|' read -r id enabled scope path rest; do
  case "$id" in ''|\#*) continue ;; esac
  [ "$enabled" = "1" ] || continue
  case "$mode" in
    global-only) [ "$scope" = "global" ] || continue ;;
    app-only)    [ "$scope" = "global" ] && continue ;;
  esac
  [ -e "$path" ] || { log "skip not exist: $path"; continue; }
  if [ "$scope" = "global" ]; then
    do_hide_global "$path"
  else
    do_hide_app "$scope" "$path"
  fi
done < "$RULES"
