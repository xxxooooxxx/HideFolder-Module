# HideFolder 安装脚本（兼容 Magisk / KernelSU / APatch）

ui_print "- 正在安装 HideFolder ..."
mkdir -p "$MODPATH/empty" "$MODPATH/scripts" "$MODPATH/webroot"
chmod 755 "$MODPATH"/scripts/*.sh
chmod 644 "$MODPATH/module.prop"
: > "$MODPATH/rules.txt"
: > "$MODPATH/active.txt"
ui_print "- 安装完成"
ui_print "- 原理：bind mount 空目录覆盖目标文件夹，文件本身不受影响"
ui_print "- 在 Magisk / KernelSU / APatch 的 WebUI 中管理隐藏规则"
