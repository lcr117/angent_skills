# 证书核验、部署和回滚

命令使用 PowerShell。路径是示例，在目标电脑重新发现，不复用另一台电脑的用户路径或固定指纹。诊断目录放在 Git 仓库外。

## 核验安装包与实际证书

```powershell
$installer = Join-Path $env:USERPROFILE 'Downloads\SinopecCAImport.exe'
Get-AuthenticodeSignature -LiteralPath $installer |
    Select-Object Status, StatusMessage, SignerCertificate
Get-FileHash -LiteralPath $installer -Algorithm SHA256
```

核对签名有效、发布者与 IT 提供的信息一致。不要硬编码本次包哈希为永久白名单，更新包必须重新核验。若必须跳过 TLS 才能下载文件，该下载连接不能独立证明文件可信。组织签名与指纹核验不充分时停在诊断。

盘点 `Cert:\CurrentUser\Root`、`Cert:\CurrentUser\CA`、`Cert:\LocalMachine\Root`、`Cert:\LocalMachine\CA`。按已确认的完整指纹查询，记录是否已存在。证书元数据至少包括 Subject、Issuer、Thumbprint、SHA-256、NotBefore、NotAfter、SAN、公钥长度、签名算法及 Basic Constraints。

自解压 EXE 可能是带 ZIP 尾部的包。先列出条目再只提取经核对的 `.cer`：使用 `.NET ZipArchive` 与 `ZipFileExtensions.ExtractToFile`；输出采用条目的叶文件名，拒绝重复叶名和目录穿越；不使用不受控全量解压覆盖文件。不支持 ZIP 的安装包改用组织提供的解包方式，不修改 EXE。

```powershell
$certPath = 'C:\LocalDiagnostics\sinopec-ca\RootCA_rsa4096.cer'
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath)
$cert | Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    ([BitConverter]::ToString($sha256.ComputeHash($cert.RawData))).Replace('-', '')
} finally { $sha256.Dispose() }
$cert.Extensions | ForEach-Object {
    [pscustomobject]@{ Oid=$_.Oid.Value; Meaning=$_.Format($true) }
}
```

Subject=Issuer 只是自签名线索，不是信任依据。叶证书的 SAN 必须覆盖实际 DNS 名或 IP；IP SAN 必须是对应 IP 条目。一个服务器缺 SAN 或名称不匹配，不应通过导入为根或改客户端安全策略处理。

## 机器范围导入与变更账本

机器范围影响所有用户，使用同一用户正常 UAC 提升的 PowerShell。若组织只授权当前用户部署，使用相应用户范围，不能自动扩大范围。

导入前在新建本地目录记录电脑、用户 SID、时间、每张证书 SHA-256/Thumbprint、源文件、目标 store、是否已存在；已有项必要时导出 `.cer` 与属性清单。为每项先写 `Prepared` 记录，导入后立即核对完整指纹并记录 `Applied`；失败保留部分执行状态。回滚仅删除确实由本次新增的项。

下面示例适用于核实包内容确有这些文件的中石化 CA 包；文件名不能代替角色和签名核验。导入动作仅在上述账本已准备后执行：

```powershell
$bundle = 'C:\LocalDiagnostics\sinopec-ca'
Import-Certificate -FilePath (Join-Path $bundle 'RootCA_rsa4096.cer') `
    -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop
Import-Certificate -FilePath (Join-Path $bundle 'CA_rsa1024_sha2.cer') `
    -CertStoreLocation 'Cert:\LocalMachine\CA' -ErrorAction Stop
Import-Certificate -FilePath (Join-Path $bundle 'CA_rsa2048.cer') `
    -CertStoreLocation 'Cert:\LocalMachine\CA' -ErrorAction Stop
```

核对精确指纹确实持久存在，再在全新的 PowerShell 进程中用正常证书校验请求目标 URL。先前进程可能缓存失败；结果只作系统客户端对照，不替代 Chrome。

若 Chrome 失败链使用服务器送来的旧中间 CA 和旧同名根，成功链使用组织提供的新版 CA，记录两套链。该证据支持链选择差异，不能单凭它证明旧 CA 应删除。优先让服务器维护方配置正确的叶证书和中间链，避免发送无关/错误根。机器范围补齐已核验中间 CA 是客户端路线，是否解决以真实冷启动日志为准。

## 回滚

回滚前按账本核对电脑、store、完整指纹及本次新增状态。只对 `BeforeExists=false` 且本次确实新增、仍为预期证书的项进行精确删除；不用 CN、通配符或整库删除。已存在项保持不动；后续被组织策略接管或用途变化时先确认归属，不覆盖组织部署。

如需撤销用户级与机器级两次导入，分别使用各自变更账本。恢复精确删除的原证书或原属性；GPO 部署从相同管理渠道撤销。证书回滚不应顺带恢复旧的浏览器错误放行记录，除非用户明确要求恢复该状态并理解影响。

## 官方依据

- [Chromium：Windows 根与中间证书库处理](https://chromium.googlesource.com/chromium/src/+/main/net/cert/internal/trust_store_win.cc)。当前实现同时读取用户与机器存储；机器范围并非普遍必需条件。
- [Chrome：移除证书 CN 回退匹配](https://developer.chrome.com/blog/chrome-58-deprecations)。以 SAN 和浏览器当前错误判定，不套用历史兼容策略。
