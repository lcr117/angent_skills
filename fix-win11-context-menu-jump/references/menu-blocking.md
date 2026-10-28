# 按菜单 CLSID 屏蔽，保留应用和其他集成

## 从本机清单选择

`manage-menu-blocks.ps1` 接受一个精确包名和显式 CLSID 列表，仅允许该安装包在 `windows.fileExplorerContextMenus` 下实际声明的 `Verb.Clsid`。不自动选择软件，不注销 Appx 包。不使用整份 COM 清单作为屏蔽名单。

同一 CLSID 可能服务多个菜单类型。脚本展示所有匹配类型；屏蔽可能同时移除文件、文件夹、桌面或经典菜单里的同类入口，而非只对当前文件生效。先说明此影响。

以下是虚构名称与 CLSID，需替换为本机实测候选。先创建独立本地诊断目录，父目录必须已存在；每个实验使用新的备份文件。

```powershell
$options=@{
    Action='Block'; PackageName='Fabrikam.Cloud'
    Clsid=@('{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}')
    Scope='CurrentUser'; BackupFile='D:\MenuDiagnostics\cloud-menu-hkcu.json'
}
& .\scripts\manage-menu-blocks.ps1 @options              # 无写入计划
& .\scripts\manage-menu-blocks.ps1 @options -Apply -WhatIf
& .\scripts\manage-menu-blocks.ps1 @options -Apply
```

## HKCU 与 HKLM

固定目标键：`SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`。值名为规范化 `{CLSID}`，数据为字符串。默认 HKCU；64 位 Windows 使用 64 位注册表视图，避免进程位数引起落点不同。

若 HKCU 在重启 Explorer 后无效，恢复本次修改；不能因此断言扩展无关。对于已核实候选，可在明确机器范围影响后改用 HKLM 验证：

```powershell
$options.Scope='LocalMachine'
$options.BackupFile='D:\MenuDiagnostics\cloud-menu-hklm.json'
# 在同一用户通过正常 UAC 提升的 Windows PowerShell 内执行。
& .\scripts\manage-menu-blocks.ps1 @options -Apply -MachineScopeConfirmed
```

`-MachineScopeConfirmed` 表示已核对“影响所有用户”的范围，不授予权限。使用原交互用户的管理员令牌，不切换其他账号以免读取错 Appx 清单。未提升时写入失败，保留备份处理部分执行。不关闭 UAC 或绕过锁屏；脚本不自动提权、重启 Explorer。

实测曾在独立桌面包注销之后，使用 HKLM 精确菜单类屏蔽处理文件/应用菜单，最终由用户确认稳定。不是对所有电脑有效的固定名单；须各自 A/B 对照，不能预置本机 OneDrive、QQ、百度或 PowerRename 标识。

## 恢复与部分失败

不可变备份在任何注册表写入之前创建，包含电脑、用户 SID、包名/版本、范围、视图、每个值的存在性、原始类型/数据和预期写入值，不覆盖原始恢复基线。

```powershell
& .\scripts\manage-menu-blocks.ps1 -Action Restore `
    -BackupFile 'D:\MenuDiagnostics\cloud-menu-hklm.json'    # 只展示计划
& .\scripts\manage-menu-blocks.ps1 -Action Restore `
    -BackupFile 'D:\MenuDiagnostics\cloud-menu-hklm.json' -Apply
```

HKLM 恢复同样需要原用户的管理员令牌。恢复前检查所有值：等于原状态则跳过；等于本次值则恢复；既不是原值也不是本次值则停止，避免覆盖后续修改。只删除自己新增的值，不删除整个 Blocked 键。保留 String、ExpandString、DWORD、QWORD、Binary、MultiString 等原类型。

若某次写入中途失败，仍可根据备份恢复已写入部分。不把部分执行报告为成功。菜单无改善时撤回；应用升级后重新从当前清单调查，不重放旧机器路径和名单。
