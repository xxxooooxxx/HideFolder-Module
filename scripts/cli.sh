#!/system/bin/sh
# HideFolder WebUI 后端
# 用法: cli.sh list | add <scope> <path> | del <id> | toggle <id> | apply | restore | status
# 规则文件格式 rules.txt: id|enabled(0/1)|scope(global 或包名)|path
. "$(dirname "$0")/common.sh"
ensure_dirs

cmd="$1"

valid_scope() {
  [ "$1" = "global" ] && return 0
  case "$1" in
    *[!A-Za-z0-9._]*) return 1 ;;
  esac
  case "$1" in
    .*|*.) return 1 ;;
  esac
  case "$1" in
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_path() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *\|*) return 1 ;;
  esac
  return 0
}

clean_arg() {
  printf '%s' "$1" | tr -d '\n\t'
}

# 生成唯一 id：秒级时间戳 + pid + urandom，避免连续调用碰撞
gen_id() {
  local r id
  r="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')"
  id="$(date +%s)$$${r:-$RANDOM}"
  while grep -q -m1 "^$id|" "$RULES" 2>/dev/null; do
    r="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')"
    id="${id}_${r:-$RANDOM}"
  done
  echo "$id"
}

do_list() {
  cat "$RULES"
}

do_add() {
  scope="$(clean_arg "$1")"
  path="$(clean_arg "$2")"
  valid_scope "$scope" || { echo "ERR|scope 非法"; exit 1; }
  valid_path "$path" || { echo "ERR|path 非法：需为绝对路径且不含 |"; exit 1; }
  path="$(norm_path "$path")"
  [ "$path" = "/" ] && { echo "ERR|不能隐藏根目录"; exit 1; }
  # 重复规则精确匹配（scope + path 完全一致才算重复，子串不算）
  if awk -F'|' -v s="$scope" -v p="$path" '$3 == s && $4 == p { found = 1 } END { exit !found }' "$RULES" 2>/dev/null; then
    echo "ERR|规则已存在"
    exit 1
  fi
  id="$(gen_id)"
  echo "$id|1|$scope|$path" >> "$RULES"
  log "rule add: $scope $path"
  # 立即应用（幂等）
  if [ -e "$path" ]; then
    if [ "$scope" = "global" ]; then
      do_hide_global "$path"
    else
      do_hide_app "$scope" "$path"
    fi
  else
    log "rule add: path not exist now, will apply later: $path"
  fi
  echo "OK|已添加并应用"
}

do_del() {
  id="$(clean_arg "$1")"
  line="$(grep -m1 "^$id|" "$RULES")"
  [ -n "$line" ] || { echo "ERR|规则不存在"; exit 1; }
  scope="$(echo "$line" | cut -d'|' -f3)"
  path="$(echo "$line" | cut -d'|' -f4-)"
  if [ "$scope" = "global" ]; then
    do_show_global "$path"
  else
    do_show_app "$scope" "$path"
  fi
  # 注意：grep -v 删光所有行时 exit 1 但输出为空文件，这正是我们要的，不能用 &&
  grep -v "^$id|" "$RULES" > "$RULES.tmp"
  mv "$RULES.tmp" "$RULES"
  log "rule del: $scope $path"
  echo "OK|已删除并恢复"
}

do_enable_disable() {
  # $1 = 1/0, $2 = id
  want="$1"
  id="$(clean_arg "$2")"
  line="$(grep -m1 "^$id|" "$RULES")"
  [ -n "$line" ] || { echo "ERR|规则不存在"; exit 1; }
  scope="$(echo "$line" | cut -d'|' -f3)"
  path="$(echo "$line" | cut -d'|' -f4-)"
  tmp="$RULES.tmp"
  if ! awk -F'|' -v id="$id" -v w="$want" 'BEGIN { OFS="|" } $1 == id { $2 = w } { print }' "$RULES" > "$tmp"; then
    echo "ERR|规则更新失败"
    exit 1
  fi
  mv "$tmp" "$RULES"
  if [ "$want" = "1" ]; then
    if [ -e "$path" ]; then
      if [ "$scope" = "global" ]; then
        do_hide_global "$path"
      else
        do_hide_app "$scope" "$path"
      fi
    fi
    log "rule enable: $scope $path"
    echo "OK|已启用并应用"
  else
    if [ "$scope" = "global" ]; then
      do_show_global "$path"
    else
      do_show_app "$scope" "$path"
    fi
    log "rule disable: $scope $path"
    echo "OK|已禁用并恢复"
  fi
}

do_toggle() {
  id="$(clean_arg "$1")"
  line="$(grep -m1 "^$id|" "$RULES")"
  [ -n "$line" ] || { echo "ERR|规则不存在"; exit 1; }
  enabled="$(echo "$line" | cut -d'|' -f2)"
  if [ "$enabled" = "1" ]; then
    do_enable_disable 0 "$id"
  else
    do_enable_disable 1 "$id"
  fi
}

do_apply() {
  sh "$(dirname "$0")/apply.sh"
  echo "OK|已应用全部启用中的规则"
}

do_restore() {
  sh "$(dirname "$0")/restore.sh"
}

do_status() {
  rules=0; enabled=0; hidden=0
  [ -f "$RULES" ] && rules=$(grep -c . "$RULES" 2>/dev/null)
  [ -f "$RULES" ] && enabled=$(awk -F'|' '$2 == 1' "$RULES" 2>/dev/null | grep -c . )
  [ -f "$STATE" ] && hidden=$(grep -c . "$STATE" 2>/dev/null)
  echo "rules=$rules enabled=$enabled hidden=$hidden"
}

case "$cmd" in
  list)    do_list ;;
  add)     do_add "$2" "$3" ;;
  del)     do_del "$2" ;;
  toggle)  do_toggle "$2" ;;
  enable)  do_enable_disable 1 "$2" ;;
  disable) do_enable_disable 0 "$2" ;;
  apply)   do_apply ;;
  restore) do_restore ;;
  status)  do_status ;;
  *) echo "ERR|未知命令"; exit 1 ;;
esac
