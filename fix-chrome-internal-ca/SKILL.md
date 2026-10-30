---
name: fix-chrome-internal-ca
description: Use when Windows Chrome reports NET::ERR_CERT_AUTHORITY_INVALID on Sinopec or other internal HTTPS authentication sites, saved passwords stop filling, or certificate trust works temporarily but fails after browser restart. Diagnose CA-chain errors separately from IP or hostname mismatch.
---

# 修复 Chrome 内部 CA 信任与密码不填充

适用 Windows、Chrome、中石化统一认证或其他内部 CA 网站。目标是让正常启动的 Chrome 验证真实服务器证书，而不是绕过告警。**Windows HTTPS 请求成功、独立浏览器配置成功、刷新成功，都不能替代用户日常配置的冷启动验证。**

## 诊断分流

先记录用户、Chrome 版本与实际配置目录、入口及认证域名、是否使用代理。检查实际跳转后的页面。Firefox 能填只能作为对照，不能据此认定 Chrome 表单识别失败。

| 证据 | 下一步 |
|---|---|
| Chrome Security 显示 `ERR_CERT_AUTHORITY_INVALID` | 读取证书链，核对 CA 来源、存储范围、签名与指纹 |
| 有时正常，重启后失败 | 同一日常配置分别捕获成功与失败启动 NetLog；比较完整链 |
| `VerifySignedData failed`，旧/新 CA 同名 | 按完整指纹区分链；优先纠正服务器发送的链，按授权部署已核验新版根和中间 CA |
| IP 入口、自签名、无匹配 IP SAN | 转服务器证书更换或匹配 DNS SAN 的正式域名；仅导入 CA 无法修复名称错误 |
| Chrome 证书有效，仍不填密码 | 回到密码条目域名、配置文件、管理策略、扩展和表单诊断 |

F12 → Ctrl+Shift+P → `Show security` 获取具体错误。没有浏览器接管工具时，可请用户截图 Security 面板；不要索取密码或读取浏览器密码数据库。

## 核验证书来源后修复

阅读 [证书核验、导入与回滚](references/certificates.md)。安装包签名有效和“文件与网站下载相同”只是来源证据；若网站自身证书不可信，仍需组织 IT 提供的独立可信渠道确认发布者、包哈希或证书指纹。不要把本技能当作 CA 信任授权。

优先使用组织正式部署。用户已授权修复时，完成必要的检查、备份和可恢复操作；涉及管理员权限，按环境正常提权/UAC，不关闭 UAC 或替用户点击安全桌面。

安装程序一闪而过不代表成功。检查实际目标证书库。若签名有效的自解压包调用旧版导入程序失败，可只解出公钥 `.cer`，检查根/中间角色后用 Windows `Import-Certificate` 导入，不盲目运行包内脚本。

将根放在 `Root`、中间 CA 放在 `CA`。在已确认机器范围部署的情况下，将核验后的完整链导入 `LocalMachine`；当前用户安装能暂时成功但冷启动失败时，不反复删除浏览器例外代替证书链调查。**不能仅凭某台电脑的成功断言所有电脑都需机器范围安装，或保证此步骤必然根治。**

## Chrome 启动验证与站点例外

阅读 [Chrome NetLog、例外与冷启动验证](references/chrome.md)。使用与用户相同配置、同一入口、同一代理条件；没有使用 `--ignore-certificate-errors`、安全功能禁用或错误放行。

需要结束 Chrome 时先说明未保存内容的影响，正常关闭后再处理残留进程。未经授权不强制关闭用户工作。启动 GUI 使用可见窗口；仅管理员后台导入脚本可隐藏窗口。

如果仍存在“已为此网站关闭安全警告”，先使用 Chrome 的“开启警告”撤销此站点例外。必要时在 Chrome 完全退出后备份并定点编辑实际配置文件的 `ssl_cert_decisions`。不删除整份站点数据，不恢复整份旧配置覆盖用户后续变化。

至少连续两次完整退出全部 Chrome 进程、用用户日常快捷方式启动并访问同一入口：

1. 没有证书错误页或“不安全”；Security 面板证书有效。
2. 目标主机 NetLog 的验证结果 `cert_status: 0`，链指纹与核验目标一致。
3. 密码候选与填充实际恢复；需要登录验证时由用户完成，不索取密码。

两次本机冷启动通过只能报告该范围已通过；操作系统重启、其他电脑需另行验证。若反复失败，停止叠加相同修改，回到首次失败的完整链、代理、策略和服务器节点差异。

## 常见误区与交付

- 表单有 `autocomplete="off"`、文字覆盖层或 Firefox 可用，不足以确认根因；有证书错误先查证书。
- 证书 CN 相同不等于同一 CA；比较完整指纹、公钥、AKI/SKI、签名和 SAN。
- IE 可信站点、ActiveX、旧 TLS、关闭吊销检查的 `.reg` 不修复 Chrome 的链或名称错误，不直接导入。
- 不把内部 CA、EXE、完整业务 URL 查询参数、IP 清单、用户配置、原始 NetLog、账号或截图上传公共仓库。

交付说明实际新增证书的指纹/存储范围、回滚记录位置、Chrome 例外改动、验证次数、用户确认与工具验证的区别、未验证项。临时诊断快捷方式与日志采集在完成后停用；日志只保存在本机。
