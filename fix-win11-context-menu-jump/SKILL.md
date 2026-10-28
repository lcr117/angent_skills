---
name: fix-win11-context-menu-jump
description: Use when Windows 11 modern right-click menus on the desktop, files, folders, executables or application shortcuts show temporary Loading or 正在加载 rows, then shrink, flicker or move items, and the user wants to keep the modern menu. Applies across computers with different installed menu extensions.
---

# 修复 Win11 桌面、文件和应用右键菜单跳动

保留 Windows 新版菜单，以当前电脑的扩展清单和实测结果选择处理对象。**桌面已修好，不代表文件、程序 `.exe` 或快捷方式 `.lnk` 也修好；不要照搬其他电脑的软件名或 CLSID。**

## 1. 确认场景和证据

记录 Windows build 与受影响对象：桌面空白、文件夹空白、文件夹本身、普通文件、图片、`.exe`、`.lnk`。分别复现。区分占位行消失引起的缩短、等高文字替换、纯动画、经典/新版切换、菜单关闭或完全不弹出。

按 [录屏与验证](references/verification.md) 捕捉首次加载及连续帧。重复右键稳定可能只是缓存。锁屏只可进行后台检查，不能验证菜单；不索取密码或绕过登录。若自动化未命中真实文件，或窗口被权限提示抢到前台，该段录像无效。

## 2. 识别本机菜单注册

在当前交互用户的 **Windows PowerShell 5.1**、技能目录内执行：

```powershell
# 桌面/文件夹空白菜单
& .\scripts\inspect-menu-packages.ps1 -BackgroundOnly | ConvertTo-Json -Depth 8
# 文件、程序、快捷方式、文件夹：读取完整清单
& .\scripts\inspect-menu-packages.ps1 | ConvertTo-Json -Depth 8
```

若策略阻止脚本，启动 `powershell.exe -NoProfile -ExecutionPolicy Bypass`；它仅作用于此次进程。JSON 管道留在同一进程。访问拒绝、`InspectionError` 或清单不完整时先解决读取权限，不能解释为“没有扩展”。诊断输出只保存到本机，放在 Git 仓库之外。

| 注册类型 | 直接调查对象 |
|---|---|
| `Directory\Background`、`DesktopBackground` | 文件夹/桌面空白菜单 |
| `*` | 普通文件，包括程序文件；不等于桌面空白 |
| `.exe`、`.lnk`、`.jpg` 等 | 对应对象及可能的快捷方式目标类型 |
| `Directory`、`Drive` | 文件夹本身、磁盘 |

查看 `AllVerbs`、CLSID、重复注册、包状态、`ExtensionCategories`、外部 DLL。异常状态只是线索。某个包可注册多个命令或共享 CLSID；先核对影响哪些菜单，不能把一个加载行机械对应成一个软件。

## 3. 选择最小的可恢复处理

先考虑所属软件的菜单开关。已授权修复时执行必要的可恢复操作，不要求用户重复批准常规步骤；事先说明实际影响和作用范围。

| 处理路线 | 适用情况 | 操作说明 |
|---|---|---|
| 屏蔽菜单 CLSID | 保留应用及其他集成，仅移除特定菜单入口 | 阅读 [菜单类屏蔽](references/menu-blocking.md)，使用 `manage-menu-blocks.ps1` |
| 注销独立菜单包 | 已核实为独立 menu-only sparse package，且可可靠恢复 | 使用下方原有包管理脚本 |
| 暂不修改 | 归属不明、无法恢复或测试不能确认 | 保留证据，继续诊断 |

**HKCU 和 HKLM 不能混为一谈。** 实测中 HKCU 对部分新版扩展无效；HKLM 对本机 OneDrive、QQ、百度网盘、PowerRename 菜单类有效，随后用户确认文件及应用菜单稳定。这是该机器的组级验证结果，不是其他电脑的卸载名单。HKLM 作用于所有用户，需要管理员权限；通过正常 UAC 取得权限，不自动点击安全桌面。

OneDrive 等包可能同时包含 `windows.cloudFiles`、`windows.shareTarget` 等功能，**不能为移除菜单而注销整个包**。只从 `windows.fileExplorerContextMenus` 的实际 `Verb.Clsid` 选择菜单类，不屏蔽包内所有 COM 类。不关闭云盘同步或卸载主应用。

### 独立菜单包路线

核实 `IsMenuOnlyCandidate`（仍只是筛选）、厂商原始 MSIX/Appx、匹配身份和外部 DLL。桌面默认 `-MenuSurface Background`；独立文件菜单组件显式使用 `-MenuSurface All`。有其他集成功能的包会被拒绝。

```powershell
$options = @{
    Action='Disable'; PackageName='Fabrikam.FileMenu'
    InstallerPath='C:\Vendor\Menu\FileMenu.msix'
    ExternalLocation='C:\Vendor\Menu'
    BackupDirectory='D:\MenuDiagnostics\package-01'
    MenuOnlyConfirmed=$true; MenuSurface='All'
}
& .\scripts\manage-menu-package.ps1 @options             # 只展示计划
& .\scripts\manage-menu-package.ps1 @options -Apply
& .\scripts\manage-menu-package.ps1 -Action Restore `
    -BackupDirectory 'D:\MenuDiagnostics\package-01' -Apply
```

使用本机候选替换示例。脚本备份原始安装包、manifest、身份和 DLL 哈希；仅注销当前用户的精确包。没有匹配恢复包就停止。ZIP 有签名条目不等于脚本验证了证书；厂商来源需核实，Windows 在恢复时验证签名。禁止通配符卸载、`-AllUsers`、删除程序目录、切换经典菜单。

## 4. 对照、撤回与交付

一次选择一个已核实集成做对照；若必须分组隔离，记录为“组级结果”，不能宣称每个成员都是原因。没有改善先恢复该次修改。不继续叠加无效黑名单。

重启当前用户 Explorer 后按相同对象测试冷启动，并补充缓存测试；保护正在进行的文件复制任务。检查实际高度、行数及保留入口。写入成功不代表修复成功。**自动录屏无效时可以请求用户手动复核，但明确标注“用户确认”，不能声称已逐帧验证。**

交付说明：哪些场景通过、依据是录屏还是用户确认、移除哪些入口、HKCU/HKLM 范围、恢复路径和未验证场景。等高加载替换可仍存在；软件升级可能重新注册入口。恢复只修改自己的值，发现后续改动则停止。

## 校验与边界

- 关闭动画不能消除内容重排；删除“显示设置/个性化”没有对应根治证据。
- 本机录屏、头像、用户名路径、原始扩展清单和备份不上 GitHub。
- 离线检查，不操作真实应用包或注册表：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-menu-blocks.ps1
```
