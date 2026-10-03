#!/system/bin/sh
# 卸载模块时自动恢复所有隐藏的文件夹
MODDIR=${0%/*}

if [ -f "$MODDIR/scripts/restore.sh" ]; then
  sh "$MODDIR/scripts/restore.sh"
fi

# 兜底：把规则里出现过的所有路径都 umount 一遍
if [ -f "$MODDIR/rules.txt" ]; then
  while IFS='|' read -r id enabled scope path rest; do
    case "$id" in ''|\#*) continue ;; esac
    umount -l "$path" 2>/dev/null
  done < "$MODDIR/rules.txt"
fi
