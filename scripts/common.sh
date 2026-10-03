#!/system/bin/sh
# HideFolder 公共函数库
# 通过 bind mount 空目录来"隐藏"文件夹，文件本身不受影响，umount 即恢复

# 推导模块目录（兼容 WebUI / 开机脚本 / 手动调用）
case "$0" in
  */scripts/*) MODDIR="$(cd "$(dirname "$0")/.." && pwd)" ;;
esac
MODDIR="${MODDIR:-/data/adb/modules/hidefolder}"

EMPTY="$MODDIR/empty"
RULES="$MODDIR/rules.txt"
STATE="$MODDIR/active.txt"
LOGF="$MODDIR/hidefolder.log"

log() {
  echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOGF"
}

ensure_dirs() {
  mkdir -p "$EMPTY" "$MODDIR/scripts" "$MODDIR/webroot"
  [ -f "$RULES" ] || : > "$RULES"
  [ -f "$STATE" ] || : > "$STATE"
}

# 检查当前 mount namespace 下 path 是否已被挂载（精确匹配挂载点字段）
is_mounted() {
  awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
}

# 检查指定 pid 的 mount namespace 下 path 是否已被挂载
ns_is_mounted() {
  # $1=pid $2=path
  nsenter -t "$1" -m awk -v p="$2" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
}

state_add() {
  # $1 = 记录行，去重追加
  grep -qxF "$1" "$STATE" 2>/dev/null || echo "$1" >> "$STATE"
}

state_del() {
  # $1 = global 或包名，$2 = path
  local tmp="$STATE.tmp"
  if [ "$1" = "global" ]; then
    grep -v -x -F "global|$2" "$STATE" > "$tmp" 2>/dev/null
  else
    grep -v -x -F "app|$1|$2" "$STATE" > "$tmp" 2>/dev/null
  fi
  mv "$tmp" "$STATE"
}

do_hide_global() {
  # $1 = path，在当前（全局）mount namespace 隐藏
  if is_mounted "$1"; then return 0; fi
  if mount -o bind "$EMPTY" "$1" 2>/dev/null; then
    state_add "global|$1"
    log "hide(global): $1"
    return 0
  fi
  log "hide(global) FAILED: $1"
  return 1
}

do_show_global() {
  # $1 = path
  umount -l "$1" 2>/dev/null
  state_del "global" "$1"
  log "show(global): $1"
}

pids_of() {
  # $1 = 包名，返回该应用所有进程 pid
  pidof "$1" 2>/dev/null
}

do_hide_app() {
  # $1 = 包名 $2 = path，用 nsenter 进入应用的 mount namespace 单独隐藏
  local pid ok=1
  for pid in $(pids_of "$1"); do
    if ! ns_is_mounted "$pid" "$2"; then
      if nsenter -t "$pid" -m mount -o bind "$EMPTY" "$2" 2>/dev/null; then
        ok=0
      else
        log "hide(app=$1) FAILED pid=$pid: $2"
      fi
    else
      ok=0
    fi
  done
  if [ "$ok" = "0" ]; then
    state_add "app|$1|$2"
    log "hide(app=$1): $2"
    return 0
  fi
  return 1
}

do_show_app() {
  # $1 = 包名 $2 = path
  local pid
  for pid in $(pids_of "$1"); do
    nsenter -t "$pid" -m umount -l "$2" 2>/dev/null
  done
  state_del "$1" "$2"
  log "show(app=$1): $2"
}
