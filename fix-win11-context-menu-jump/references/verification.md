# 录屏、首次加载与恢复核对

## 录屏

桌面空白、文件夹、普通文件、图片、`.exe`、`.lnk` 分别验证，不能用桌面结果替代文件结果。确认录到目标文件菜单，而非 Fences 面板或桌面空白菜单。

### DPI、前台窗口与锁屏

150% 等缩放下，DPI 不感知进程的 `Screen.Bounds`、GDI 截图尺寸、鼠标逻辑坐标和 FFmpeg 像素可能不一致。先确定物理分辨率及截图范围，不对坐标盲乘缩放比。原生操作可在截图/定位线程使用 `SetThreadDpiAwarenessContext(-4)`，用 `SetPhysicalCursorPos`、`GetPhysicalCursorPos` 核对落点。只点击实际截图中观察到的位置；布局改变后重新定位。

UAC 或 Codex 执行确认可能让其他窗口到前台。等待确认结束后显示测试对象，再开始采集。菜单没出现时排查输入未送达、前台被抢、落点错误及 Explorer 响应，不能直接归因于扩展。必要时请用户手动右键，工具仅采集；人工确认单独记录，不等于逐帧自动验证。

锁屏或 UAC 安全桌面上停止注入鼠标键盘。锁屏可做后台检查/备份，不能验证菜单；用户自行解锁，不索取密码。锁屏录像不能作为修复证据。

优先使用环境已有的桌面/录屏工具。没有专用工具时可以使用本机 FFmpeg 的 Windows `gdigrab`，无需修改系统菜单或关闭动画。先用 `Get-Command ffmpeg` 找可执行文件，不写死另一台电脑的安装路径。

让用户短暂不操作鼠标。确认屏幕尺寸、缩放和桌面空白区位置；避免图标、Fences 面板、任务栏及可执行动作。尽量只录菜单附近，防止暴露其他窗口内容。以下是示例矩形，必须按实际屏幕调整：

```powershell
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
# 前台录制会占用命令窗口；可先启动隐藏录制进程，再右键。
# 输出路径是本地诊断目录，不是技能 Git 工作目录。
$video = 'D:\MenuDiagnostics\before.mp4'
$arguments = @(
    '-n', '-f', 'gdigrab', '-framerate', '60',
    '-offset_x', '700', '-offset_y', '200', '-video_size', '600x700',
    '-i', 'desktop', '-t', '12', '-c:v', 'libx264',
    '-preset', 'ultrafast', '-crf', '18', '-pix_fmt', 'yuv420p',
    ('"' + $video + '"')
)
$capture = Start-Process -FilePath $ffmpeg -ArgumentList $arguments `
    -WindowStyle Hidden -PassThru
# 开始录制后在已核实的桌面空白处右键；不点击菜单项。
# 用原生桌面工具操作，或让用户手动触发。先等录制初始化。
$capture.WaitForExit()
if ($capture.ExitCode -ne 0) { throw 'Recording failed; inspect FFmpeg output before continuing.' }
```

60 fps 是请求采集率；检查 FFmpeg 日志中的丢帧，不能把稀疏缩略图当作逐帧证据。原始录屏保留。提取弹出前后连续帧和慢放：

```powershell
# -ss 和 -t 按原片实际菜单出现时刻调整。
& $ffmpeg -n -ss 1.4 -t 0.6 -i $video `
    -vf 'scale=300:350,tile=6x6' -frames:v 1 'D:\MenuDiagnostics\frames.png'
& $ffmpeg -n -ss 1.3 -t 1.5 -i $video `
    -vf 'setpts=5*PTS,fps=15' 'D:\MenuDiagnostics\slow.gif'
```

若 GIF 太大，可裁剪菜单区域、缩小尺寸；用原始帧判断是否缩短，不凭 GIF 的降采样断言无瞬时加载。原始画面中尺寸未变但文字加载，可以报告“仍有加载，未观察到高度变化”。

## 冷启动对照

1. 记录处理前占位行数、最终行数、菜单高度及 Windows build；用相同位置、裁剪和采集率对照。
2. 验证用户当前是否有文件复制/移动任务；进行这类任务时推迟重启 Explorer。
3. 重启前告知任务栏会短暂消失，记录文件夹窗口。优先通过任务管理器重启 Windows 资源管理器；若使用进程接口，先确认目标属于当前用户会话，不终止其他会话。
4. 等待 Explorer 和桌面初始化。它可能恢复文件夹窗口；最小化后先截图确认桌面，不能把“此电脑”或某个磁盘的菜单当作桌面测试。
5. 录制重启后首次桌面右键，再用 Esc 关闭。连续点击只是补充的缓存测试。
6. 比较弹出瞬间的连续帧，而非每秒一两张的总览。确认没有消失行造成的缩短，并检查需要保留的菜单入口。
7. 若结果不变，使用该候选的恢复记录先回滚，再测试其他候选。若改善，记录该项贡献；剩余候选逐项同法验证。
8. 交付时区分“本次 Explorer 冷启动通过”与“重启 Windows 后通过”；没有做过后者就不要声称做过。告知软件更新可能重新注册扩展。

## 恢复与停止条件

`manage-menu-package.ps1 -Action Restore` 使用原电脑、原用户备份，不跨电脑套用路径或注册表。源厂商程序目录必须仍在。原始恢复 MSIX 应与已安装包的 Name、Version、Publisher、Architecture 和 ResourceId 匹配；文件哈希用于检查备份后是否被修改。

恢复遇到源文件缺失、权限不足、签名/依赖报错或已有不同版本时，保留备份和错误，先修复所属程序或使用其官方安装器。不要为绕过签名错误启用开发者模式、关闭签名检查或接管 WindowsApps 目录权限。不要自动降级现有版本。

应用不提供独立菜单包、恢复原始安装包不可得、真实原因未确认时，停止注销路径，报告当前证据。用户请求修复不意味着可以删除整款应用或切换到经典菜单。
