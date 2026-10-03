# HideFolder

一个 Magisk / KernelSU / APatch 通用模块：**隐藏指定文件夹，而不是删除文件**，可随时恢复。

## 功能

- 📁 **隐藏文件夹**：用空目录 bind mount 覆盖目标文件夹，文件本身不受任何影响
- ↩️ **随时恢复**：禁用 / 删除规则立即 `umount` 恢复；卸载模块时自动恢复全部
- 🌍 **全局隐藏**：开机早期（zygote 启动前）挂载，对所有应用生效
- 📱 **按应用隐藏**：用 `nsenter` 进入目标应用的 mount namespace 单独挂载，其他应用不受影响
- 🖥️ **WebUI 管理**：添加 / 删除 / 启用 / 禁用规则，所见即所得
- 🔄 **后台补应用**：新启动的目标应用约 2 分钟内自动补上隐藏

## 安装

1. 下载本仓库的 zip（或自行打包：`zip -r HideFolder.zip * -x '*.git*'`，注意压缩包根目录直接是 `module.prop` 等文件）
2. 在 Magisk / KernelSU / APatch 的模块页面选择「从本地安装」
3. 重启手机
4. 在模块的 WebUI（或 MMRL / WebUI X）中打开 HideFolder 管理规则

## 使用

### WebUI

- **添加规则**：填写要隐藏的文件夹绝对路径（如 `/sdcard/DCIM/私密相册`），选择「全局隐藏」或「仅对某个应用」并填写包名（如 `com.tencent.mm`）
- **启用 / 禁用**：点规则旁的开关，禁用立即恢复，启用立即隐藏
- **删除**：删除规则的同时恢复该文件夹
- **应用全部 / 恢复全部**：一键操作

### 命令行（adb shell / 终端，root）

```sh
CLI=/data/adb/modules/hidefolder/scripts/cli.sh
sh $CLI list                    # 列出规则（id|启用|范围|路径）
sh $CLI add global /sdcard/私密  # 添加全局规则
sh $CLI add com.tencent.mm /sdcard/Download/xxx  # 添加按应用规则
sh $CLI toggle <id>             # 启用/禁用切换
sh $CLI enable <id> / sh $CLI disable <id>
sh $CLI del <id>                # 删除规则并恢复
sh $CLI apply                   # 应用全部启用中的规则
sh $CLI restore                 # 恢复全部隐藏
sh $CLI status                  # 规则数 / 已启用 / 隐藏中
```

规则保存在 `/data/adb/modules/hidefolder/rules.txt`，格式为 `id|enabled|scope|path`，
手动编辑后执行 `apply` 即可生效。

## 原理

```
隐藏：mount -o bind <模块空目录> <目标文件夹>   → 目标看起来是空的
恢复：umount -l <目标文件夹>                    → 文件原样回来
```

- 全局隐藏在 `post-fs-data.sh` 执行（早于 zygote），所有应用继承该挂载
- 按应用隐藏通过 `nsenter -t <pid> -m` 进入该应用的 mount namespace 执行挂载
- `service.sh` 在 late_start 补应用全局规则，并起后台循环每 120 秒为新启动的目标应用补应用按应用规则
- 所有操作幂等，重复执行无副作用；日志在 `hidefolder.log`

## 文件结构

```
HideFolder/
├── module.prop          模块元信息
├── customize.sh         安装脚本
├── post-fs-data.sh      开机早期：应用全局隐藏
├── service.sh           开机后期：补应用 + 后台守护
├── uninstall.sh         卸载时自动恢复全部
├── scripts/
│   ├── common.sh        挂载/恢复核心函数
│   ├── apply.sh         按规则应用隐藏
│   ├── restore.sh       恢复全部
│   └── cli.sh           WebUI/命令行后端
├── webroot/
│   └── index.html       WebUI（清爽蓝 iOS 风格）
└── README.md
```

## 注意事项

- 隐藏的是**文件夹本身**（看起来是空目录），不会删除或修改任何文件
- 按应用隐藏依赖 `nsenter` / `pidof`（Android 自带 toybox 一般都有）
- 某些 ROM 的多开 / 应用双开进程名可能不同，规则按包名匹配主进程
- 卸载模块前建议先在 WebUI 点「恢复全部」（即使忘了，`uninstall.sh` 也会自动恢复）

## 兼容性

| 管理器 | 安装 | WebUI |
|---|---|---|
| Magisk（官方/Kitsune） | ✅ | ✅（需支持 WebUI 的版本） |
| KernelSU | ✅ | ✅ |
| APatch | ✅ | ✅ |

## License

MIT
