---
name: fix-win11-context-menu-jump
description: Use when the Windows 11 modern desktop right-click menu shows temporary Loading or 正在加载 rows, then shrinks, flickers, or moves items, and the user wants to retain the modern menu. Also applies to diagnosing packaged context-menu extensions across computers with different installed software.
---

# 修复 Win11 新版右键菜单加载后跳动

目标：保留 Windows 新版菜单，消除加载占位行消失引起的高度变化。**以当前电脑的扩展清单和冷启动录屏为依据，不照搬其他电脑的组件名单。**

## 1. 确认现象

区分：占位行消失导致缩短、等高替换、纯动画闪烁、旧菜单切换、菜单整体关闭。这些不是同一问题。先记录 Windows `DisplayVersion`、`CurrentBuild`、`UBR`。

录制首次桌面右键的连续帧；步骤见 [录屏与冷启动验证](references/verification.md)。重复点击可能命中缓存，不能证明修好。若已有清晰截图，也要保留处理前后相同条件的视频。不要因为菜单中有 Fences、终端或某款软件就认定它是原因。

## 2. 识别本机的实际扩展

在当前交互用户的 **Windows PowerShell 5.1** 中执行；PowerShell 7 中 Appx 模块不可用时使用 `powershell.exe`。访问被拒绝表示执行权限不足，不能解释为没有扩展。

```powershell
& .\scripts\inspect-menu-packages.ps1 -BackgroundOnly |
    ConvertTo-Json -Depth 8
```

若执行策略阻止本地脚本，可启动 `powershell.exe -NoProfile -ExecutionPolicy Bypass` 后再执行；它仅作用于此次进程，不修改持久策略。JSON 管道在同一个 PowerShell 进程内执行，避免把子进程格式化文本当作对象。脚本只读，输出可保存到技能仓库之外的本地诊断目录。出现 `InspectionError` 或最终清单不完整错误时，先解决读取问题，不能得出“没有扩展”的结论。

查看 `BackgroundVerbs` 的类型、CLSID、重复注册、包状态和 `ExternalRootHint`。`Directory\Background`、`DesktopBackground` 是直接候选；仅 `*` 或 `Directory` 不证明它参与桌面空白菜单。状态异常是线索，不是原因证据。

`IsMenuOnlySparseCandidate` 只是清单筛选，不能代替确认它是否为可单独注销的菜单组件。用所属程序、包清单及外部 DLL 路径核实；查看 `AllVerbs`，告知注销也会影响该组件的文件/文件夹菜单入口。

## 3. 单项对照与可恢复处理

优先使用所属软件的菜单开关。已授权修复时可以进行必要、可恢复的处理，不额外要求用户逐条批准常规步骤；说明实际影响。

对于独立的 menu-only sparse package：先找到本机厂商原始 MSIX/Appx 和外部程序根目录。确认版本、发布者、架构及 DLL 文件；没有可靠恢复包就停在诊断，不注销。复制 manifest 不等于完整备份。

| 操作 | 适用条件 |
|---|---|
| 软件菜单开关 | 所属软件提供并能控制目标新版入口 |
| 当前用户注销独立菜单包 | 已确认 menu-only；匹配厂商恢复包与外部文件齐全 |
| 暂不修改 | 属于完整应用、用途未明或无法可靠恢复 |

使用下方虚构名称替换为**本机实测候选**。一次只选一个，备份目录每次新建。

```powershell
$options = @{
    Action = 'Disable'
    PackageName = 'Fabrikam.DesktopHints'
    InstallerPath = 'C:\Vendor\Menu\DesktopHints.msix'
    ExternalLocation = 'C:\Vendor\Menu'
    BackupDirectory = 'D:\MenuDiagnostics\candidate-01'
    MenuOnlyConfirmed = $true
}
# 默认仅检查并展示计划；核对范围后加 -Apply，-WhatIf 也可用于预览。
& .\scripts\manage-menu-package.ps1 @options
& .\scripts\manage-menu-package.ps1 @options -Apply

# 没改善时先恢复，再调查下一项。
& .\scripts\manage-menu-package.ps1 -Action Restore `
    -BackupDirectory 'D:\MenuDiagnostics\candidate-01' -Apply
```

脚本备份原始安装包、manifest、SHA-256、身份、用户和电脑信息，再按精确 PackageFullName 注销当前用户的菜单包。它不会自动重启 Explorer。安装包来源和外部目录完整性仍需人工核实；ZIP 中存在签名条目不等于脚本验证了证书。Windows 在恢复安装时执行包签名验证。

若逐项验证了多个独立贡献者，可保留有效处理；每项保留恢复记录。不要卸载整款 WPS、同步盘、PowerToys 或桌面工具来替代菜单组件处理。禁止通配符卸载、`-AllUsers`、删除外部程序目录、改成经典菜单。

## 4. 验证后交付

按 [验证步骤](references/verification.md) 重启 Explorer，确保显示的是桌面空白区，再检查首次右键的每一帧及保留入口。加载行变成等高的“在终端中打开”不算菜单缩短；分别报告残余加载和布局结果。

成功标准是本次冷启动测试中消失行/缩短被消除，且仍为新版菜单。一次测试不能保证长期无复发。提供前后录屏、实际移除组件、文件菜单影响、恢复路径；应用升级可能重新注册组件。

## 已验证的经验边界

- 常规 `Shell Extensions\Blocked` 在实测的打包新版扩展上没有效果；若冷启动对照仍无效，恢复该次修改，不反复叠加黑名单。
- 关闭动画不能消除占位行引起的内容重排；删除“显示设置/个性化”也没有对应证据。
- 不能把先前成功电脑上的联想、WPS、PowerRename 名单硬编码为通用卸载名单。
- 若与加载占位无关，停止套用此修复，回到症状诊断。

运行无副作用的离线测试：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1`。测试会模拟系统包接口，不注销真实软件。诊断记录、用户名路径和录屏只保存在本机，不提交至公共仓库。
