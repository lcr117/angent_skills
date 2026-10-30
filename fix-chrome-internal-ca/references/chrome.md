# Chrome 失败日志、站点例外与冷启动

## 捕获真正失败的启动

先发现 Chrome 路径、实际进程命令行和用户配置目录。默认配置通常为 `%LOCALAPPDATA%\Google\Chrome\User Data\Default`，但必须核对 `chrome://version` 的 Profile Path；自定义用户目录或 Profile 不能套 Default。

优先用 `chrome://net-export` 的默认模式，或在启动命令加 `--log-net-log`。不选择包含 Cookies、凭据或原始字节的采集模式。日志即使默认模式也可能包含业务 URL 和系统元数据，只保存在本机。

必须全部退出 Chrome 后才能捕获启动参数：已有进程会接管新窗口，可能不启用所传日志参数。正常关闭后处理残留；先通知用户保存工作，不自动强杀。

PowerShell 的 `Start-Process -ArgumentList` 会将数组拼接为空格分隔命令行，**路径有空格时必须在最终命令行里保留双引号**，不是依赖数组元素边界：

```powershell
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$log = 'C:\Local Diagnostics\Chrome\startup-netlog.json'
$url = 'https://auth.siam.sinopec.com/idp/Authn/TAMUserPassAuth'
# 换成本机真实入口，保存原查询参数；变量不得含引号或命令文本。
$arguments = '--new-window --log-net-log="' + $log + '" "' + $url + '"'
Start-Process -FilePath $chrome -ArgumentList $arguments -WindowStyle Normal
```

先创建日志父目录，使用新日志名防止覆盖失败证据。检查真实进程命令行和日志实际路径。用户正常重启才失败时，创建临时诊断快捷方式保留原配置和入口，让用户用它复现并停在警告页；不要点击继续访问，否则会新增放行状态。

分析日志优先在 Chrome 退出、文件完整后进行。需读取仍打开文件时用 `FileStream` 的 `FileShare.ReadWrite`；实时 JSON 可能未闭合，只解析已写完的事件，不把部分结果当作没有错误。

## 只分析目标主机的验证任务

NetLog 的事件类型数字通过 `constants.logEventTypes` 解码，不硬编码数字。定位目标 host 的 `CERT_VERIFIER_JOB`，沿 `source_dependency` 跟踪到 `CERT_VERIFY_PROC`；同一文件中的 Google 或其他站点验证通过不能证明目标站点正常。

关注：

- `CERT_VERIFY_PROC_INPUT_CERT`：服务器提供的证书。
- `CERT_VERIFY_PROC_PATH_BUILT`：尝试的链与 `errors`、`is_valid`。
- 对应任务结束的 `cert_status`、`net_error`、`has_valid_path`。
- 目标验证成功通常为 `cert_status: 0` 且无 `net_error`。内部 CA 的 `is_issued_by_known_root: false` 本身不等于失败。

`VerifySignedData failed` 表示某条候选链签名验证失败；多个失败候选后仍可能存在有效链，需看整个目标任务最终结果。比较成功与失败的实际 DER/SHA-256/完整 Thumbprint，不以相同 Subject/CN 合并证书。

独立配置、headless、Windows 客户端仅是对照。`--dump-dom` 返回登录页标题不充分；确认目标验证日志和实际安全状态。不得使用 `--ignore-certificate-errors`、禁用网络服务沙箱、启用过时 TLS 或关闭吊销检查制造通过结果。

## 定点清除证书错误放行记录

优先通过站点信息中的“开启警告”撤销。直接文件编辑作为后备，必须全部退出 Chrome，并确认实际 Profile Path。

1. 为 `Preferences` 创建带时间戳的不可覆盖本地备份，包含敏感信息，不上传。
2. 读取 JSON，检查 `profile.content_settings.exceptions.ssl_cert_decisions`。
3. 找出仅对应已确认认证主机的现存键。此结构常见键形如 `https://auth.siam.sinopec.com:443,*`，实际以文件为准；非默认端口不凭访问 URL 猜键。
4. 只移除确认的键，其余结构和值保持不变；用足够深度的 JSON 序列化（PowerShell 7 可用 `ConvertFrom-Json -AsHashtable`、`ConvertTo-Json -Depth 100`），UTF-8 无 BOM，检查无深度截断警告。旧版 PowerShell 不支持 `-AsHashtable`，改用支持的 JSON 库或 PowerShell 7，不照抄执行。
5. 先写入 Preferences 同目录的新临时文件，重读校验仅目标键消失、其余 JSON 语义一致；确认原文件自备份后未变化，再使用本机文件系统支持的原子替换方式替换。写入、校验或替换失败时保留原文件和备份，不先删原文件。启动 Chrome 后重测证书，而非以删除成功作为修复成功。

恢复时只恢复该键：核对其当前状态与本次改后状态一致，若有后续变化则停止；不要用完整旧 Preferences 覆盖新的浏览历史/配置。删除的错误放行记录不应作为证书修复必要依赖；它不会让不可信证书变可信。

## 完成标准

连续两次冷启动通过，并至少一次由用户日常快捷方式启动确认。最终不用诊断参数重开，停止日志采集，移除自己创建的临时快捷方式（确认绝对路径与归属，遵守环境删除权限）；原始日志与配置备份按用户需求留在本地。

证书无警告后再单独核实密码填充：已保存条目与登录 origin 匹配，点击字段有候选项，选择能填。实际登录由用户完成；验证码、动态口令或客户端证书步骤另行判断。无法现场验证就报告“证书日志通过，填充待用户确认”，不报告全修复。

## 官方依据

- [Chromium：密码问题的日志入口](https://chromium.googlesource.com/chromium/src/+/main/docs/autofill/bug_reports.md)：密码日志是 `chrome://password-manager-internals`，不是通用 autofill 日志。
- [Chrome 密码管理帮助](https://support.google.com/chrome/answer/95606?hl=zh-Hans)。
