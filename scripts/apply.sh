#!/system/bin/sh
# 按 rules.txt 应用隐藏规则（幂等，可重复执行）
# 用法: apply.sh [global-only|app-only]   默认全部
# 退出码：0=全部成功（应用未运行不算失败，后台会补），1=有规则挂载失败
. "$(dirname "$0")/common.sh"
ensure_dirs

mode="${1:-all}"
fail=0
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
    do_hide_global "$path" || fail=1
  else
    do_hide_app "$scope" "$path"
    rc=$?
    # rc=2 表示应用未在运行，不算失败，service 的后台循环会补上
    [ "$rc" = "1" ] && fail=1
  fi
done < "$RULES"

[ "$fail" = "0" ] || log "apply done with failures"
exit "$fail"
