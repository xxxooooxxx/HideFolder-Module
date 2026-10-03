#!/system/bin/sh
# HideFolder 公共函数库
# 通过 bind mount 空目录来"隐藏"文件夹，文件本身不受影响，umount 即恢复
#
# Android 上的三个关键点：
# 1. /storage/emulated/0 是 FUSE 挂载，真实数据在 /data/media/0。
#    各应用看到的都是 FUSE 守护进程转交的内容，所以必须在全局 mount ns
#    里对下层真实路径做 bind（经由 init 的 ns，保证位置正确），一次覆盖所有应用。
# 2. 每个应用有独立的 mount namespace，运行时添加的规则还要逐个 ns 补挂载，
#    覆盖直接文件访问和非 FUSE 路径。
# 3. 相册类应用走 MediaStore 数据库而非直接读文件，隐藏后要清掉对应记录，
#    恢复后要触发重新扫描，否则相册里依然看得到。

case "$0" in
  */scripts/*) MODDIR="$(cd "$(dirname "$0")/.." && pwd)" ;;
esac
MODDIR="${MODDIR:-/data/adb/modules/hidefolder}"

EMPTY="$MODDIR/empty"
RULES="$MODDIR/rules.txt"
STATE="$MODDIR/active.txt"
LOGF="$MODDIR/hidefolder.log"

NSENTER="$(command -v nsenter 2>/dev/null)"
HAS_AM=0; command -v am >/dev/null 2>&1 && HAS_AM=1

log() {
  echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOGF"
}

ensure_dirs() {
  mkdir -p "$EMPTY" "$MODDIR/scripts" "$MODDIR/webroot"
  [ -f "$RULES" ] || : > "$RULES"
  [ -f "$STATE" ] || : > "$STATE"
}

# ---------------- 路径换算 ----------------

norm_path() {
  # 去掉末尾多余的 /
  local p="$1"
  while [ "$p" != "${p%/}" ]; do p="${p%/}"; done
  [ -n "$p" ] || p="/"
  echo "$p"
}

lower_path_of() {
  # 用户可见路径 → 下层真实路径（FUSE/sdcardfs 的 lower），不是外部存储则输出空
  case "$1" in
    /storage/emulated/0) echo "/data/media/0" ;;
    /storage/emulated/0/*) echo "/data/media/0${1#/storage/emulated/0}" ;;
    /sdcard) echo "/data/media/0" ;;
    /sdcard/*) echo "/data/media/0${1#/sdcard}" ;;
    /mnt/sdcard) echo "/data/media/0" ;;
    /mnt/sdcard/*) echo "/data/media/0${1#/mnt/sdcard}" ;;
    /storage/self/primary) echo "/data/media/0" ;;
    /storage/self/primary/*) echo "/data/media/0${1#/storage/self/primary}" ;;
    /storage/emulated/[0-9]*)
      local u="${1#/storage/emulated/}"; u="${u%%/*}"
      echo "/data/media/$u${1#/storage/emulated/$u}" ;;
    /storage/????-????)
      echo "/mnt/media_rw/${1#/storage/}" ;;
    /storage/????-????/*)
      local v="${1#/storage/}"; v="${v%%/*}"
      echo "/mnt/media_rw/$v${1#/storage/$v}" ;;
  esac
}

is_shared_storage() {
  case "$1" in
    /storage/*|/sdcard|/sdcard/*|/mnt/sdcard|/mnt/sdcard/*|/data/media/*) return 0 ;;
  esac
  return 1
}

# ---------------- mount 基础 ----------------

# 在全局 mount namespace（init 的 ns）里执行命令
# 注意：不在这里吞掉 stderr，调用方需要把挂载失败的原因记到日志里
in_global_ns() {
  if [ -n "$NSENTER" ]; then
    "$NSENTER" -t 1 -m "$@"
  else
    "$@"
  fi
}

g_is_mounted() {
  # $1=path：检查全局 ns 里是否已挂载（精确匹配挂载点字段）
  in_global_ns awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
}

g_mount() {
  # $1=path：在全局 ns 里 bind 空目录（幂等），失败原因记日志
  local err rc
  [ -e "$1" ] || return 0
  if g_is_mounted "$1"; then return 0; fi
  err="$(in_global_ns mount -o bind "$EMPTY" "$1" 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    log "mount(global): $1"
    return 0
  fi
  log "mount(global) FAILED: $1: $err"
  return 1
}

g_umount() {
  # $1=path：在全局 ns 里恢复
  in_global_ns umount -l "$1"
  log "umount(global): $1"
}

each_mntns_pid() {
  # 每行输出一个 pid，代表一个唯一的 mount namespace
  local pid ns seen=""
  for pid in $(ls /proc 2>/dev/null | grep '^[0-9][0-9]*$'); do
    ns="$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)" || continue
    case "$seen" in *"|$ns|"*) continue ;; esac
    seen="$seen|$ns|"
    echo "$pid"
  done
}

ns_bind_path() {
  # $1=path：在所有 mount namespace 里 bind 空目录（幂等），覆盖运行时已启动的应用
  local pid
  [ -n "$NSENTER" ] || return 0
  [ -e "$1" ] || return 0
  for pid in $(each_mntns_pid); do
    if ! "$NSENTER" --mount="/proc/$pid/ns/mnt" \
        awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null; then
      "$NSENTER" --mount="/proc/$pid/ns/mnt" mount -o bind "$EMPTY" "$1" 2>/dev/null
    fi
  done
}

ns_umount_path() {
  # $1=path：在所有 mount namespace 里恢复
  local pid
  [ -n "$NSENTER" ] || return 0
  for pid in $(each_mntns_pid); do
    "$NSENTER" --mount="/proc/$pid/ns/mnt" umount -l "$1" 2>/dev/null
  done
}

is_mounted() {
  awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
}

ns_is_mounted() {
  # $1=pid $2=path
  [ -n "$NSENTER" ] || return 1
  "$NSENTER" -t "$1" -m awk -v p="$2" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
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

# ---------------- MediaStore ----------------

uri_encode() {
  # $1 → percent 编码（保留 / 和 unreserved 字符），用于 file:// URI
  printf '%s' "$1" | od -An -v -tu1 | tr -s ' ' '\n' | grep '[0-9]' | awk '
    { c = $1 + 0
      if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) \
          || c == 45 || c == 46 || c == 47 || c == 95 || c == 126) { printf "%c", c }
      else { printf "%%%02X", c } }'
  echo
}

ms_purge() {
  # $1=用户路径 $2=文件列表文件：让 MediaStore 移除该路径下的记录
  #
  # 安全方式：逐文件触发系统扫描。此时文件已被 bind 隐藏，扫描器看不到它们，
  # MediaStore 只会删除数据库中的对应行，绝不触碰文件本身。
  #
  # 血的教训：禁止用 `content delete`——在 Android 上它会把文件一起删掉！
  local mp f enc
  mp="$1"
  if [ "$HAS_AM" = "1" ] && [ -f "$2" ]; then
    ( while IFS= read -r f; do
        [ -n "$f" ] || continue
        enc="$(uri_encode "$f")"
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$enc" >/dev/null 2>&1
      done < "$2"
      log "ms_purge(scan): $mp" ) >/dev/null 2>&1 < /dev/null &
  else
    log "ms_purge: skipped (no am or empty file list)"
  fi
  return 0
}

ms_rescan() {
  # $1=用户路径：恢复后触发重扫，把记录加回来（后台执行，文件多时不阻塞调用方）
  local f enc
  if [ "$HAS_AM" = "1" ] && is_shared_storage "$1" && [ -d "$1" ]; then
    ( find "$1" -type f 2>/dev/null | head -n 500 | while IFS= read -r f; do
        [ -n "$f" ] || continue
        enc="$(uri_encode "$f")"
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$enc" >/dev/null 2>&1
      done
      log "ms_rescan: $1" ) >/dev/null 2>&1 < /dev/null &
  fi
  return 0
}

# ---------------- 隐藏 / 恢复 ----------------

do_hide_global() {
  # $1=path：全局隐藏
  #  - FUSE 下层真实路径在全局 ns 里挂载（走 FUSE 的应用一次全覆盖）
  #  - 用户路径在所有 mount ns 里挂载（覆盖直接访问、非 FUSE 路径、已运行应用）
  #  - 只有确认至少一处挂载成功后，才写 state 并清理 MediaStore；
  #    否则回滚并返回失败（绝不能在没藏住的情况下动媒体库）
  # 返回：0=已隐藏，1=挂载失败
  local path lower flist="" ok=0
  path="$(norm_path "$1")"
  lower="$(lower_path_of "$path")"

  # 预先收集文件列表（MediaStore 扫描用，此时文件还可见）
  if [ "$HAS_AM" = "1" ] && is_shared_storage "$path" && [ -d "$path" ]; then
    flist="$MODDIR/.flist.tmp"
    find "$path" -type f 2>/dev/null | head -n 3000 > "$flist"
  fi

  [ -n "$lower" ] && g_mount "$lower" && ok=1
  g_mount "$path" && ok=1
  ns_bind_path "$path"

  # 验证：全局 ns 里至少一处挂载成功才算成功
  if [ "$ok" = "0" ]; then
    if g_is_mounted "$path"; then
      ok=1
    elif [ -n "$lower" ] && g_is_mounted "$lower"; then
      ok=1
    fi
  fi
  if [ "$ok" = "0" ]; then
    log "hide(global) ABORT: mount failed, rolling back: $path"
    ns_umount_path "$path"
    [ -n "$lower" ] && g_umount "$lower"
    g_umount "$path"
    [ -n "$flist" ] && rm -f "$flist"
    return 1
  fi

  state_add "global|$path"
  log "hide(global): $path lower=${lower:-none}"

  if is_shared_storage "$path"; then
    ms_purge "$path" "$flist"
  fi
  [ -n "$flist" ] && rm -f "$flist"
  return 0
}

do_show_global() {
  # $1=path：全局恢复
  local path lower
  path="$(norm_path "$1")"
  lower="$(lower_path_of "$path")"
  ns_umount_path "$path"
  [ -n "$lower" ] && g_umount "$lower"
  g_umount "$path"
  state_del "global" "$path"
  log "show(global): $path"
  ms_rescan "$path"
  return 0
}

pids_of() {
  # $1 = 包名，返回该应用所有进程 pid
  pidof "$1" 2>/dev/null
}

do_hide_app() {
  # $1 = 包名 $2 = path，用 nsenter 进入应用的 mount namespace 单独隐藏
  # 注意：只屏蔽文件直接访问；走系统 MediaStore 读图的应用仍可能看到（媒体库全局共享）
  # 返回：0=已隐藏，2=应用未在运行，1=挂载失败
  local pid ok=1 err
  for pid in $(pids_of "$1"); do
    if ! ns_is_mounted "$pid" "$2"; then
      if [ -n "$NSENTER" ]; then
        err="$("$NSENTER" -t "$pid" -m mount -o bind "$EMPTY" "$2" 2>&1)" && ok=0 \
          || log "hide(app=$1) FAILED pid=$pid: $2: $err"
      else
        log "hide(app=$1) FAILED: nsenter not found"
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
  if [ -z "$(pids_of "$1")" ]; then
    return 2
  fi
  return 1
}

do_show_app() {
  # $1 = 包名 $2 = path
  local pid
  [ -n "$NSENTER" ] || return 0
  for pid in $(pids_of "$1"); do
    "$NSENTER" -t "$pid" -m umount -l "$2" 2>/dev/null
  done
  state_del "$1" "$2"
  log "show(app=$1): $2"
}
