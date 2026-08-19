# StarAudioBridge PC Server (Windows)

Windows 端**图形界面**服务 (WinForms + 托盘), 负责:

- **采集电脑声音** (WASAPI 环回, 任何软件出声都能抓到) → 切成 5ms 帧 → UDP 推给手机
- **接收手机麦克风** (手机经 UDP 发来的 PCM) → 输出到用户指定的 WASAPI 设备
- **防回声路由**: 默认关闭本机扬声器监听；推荐选择虚拟音频线，让通话/录音软件把它作为麦克风
- **mDNS 自动发现**: 广播 `_star-audio-bridge._tcp`, 手机 App 一键发现
- **控制通道** (TCP + JSON): 握手 / 启停 / 心跳 RTT

## 直接下载（推荐）

前往 [GitHub Releases](https://github.com/oliverhy/StarAudioBridge/releases/latest) 下载 `StarAudioBridge.Server-win-x64-*.exe`。该文件是 Windows 10/11 x64 自包含版本，双击即可运行，无需安装 .NET Runtime。

若 Windows SmartScreen 出现提示，点「更多信息」→「仍要运行」。首次运行遇到防火墙提示时，勾选「专用网络」并允许访问。

### 轻量版

轻量版 ZIP 约 1 MB，不包含 .NET。完整解压后双击 `StarAudioBridge.Server.exe`，启动器会检测 `.NET 8 Desktop Runtime (x64)`：已安装时直接启动主程序；未安装时显示中文提示，并打开微软官方下载页面。

生成轻量版：

```powershell
./build-lite.ps1 -Version 1.0.2
```

## 构建与运行

需要 [.NET SDK 8+](https://dotnet.microsoft.com/download) (本机已装 8.0.424):

```powershell
cd PC-Server
dotnet restore
dotnet build -c Release
```

运行 `bin/Release/net8.0-windows/StarAudioBridge.Server.exe` (双击即启动 GUI):
- 窗口显示: 运行状态 / 本机 IP / 端口 / 手机麦克风输出设备 / 实时统计 / 日志
- 支持「启动/停止服务」「隐藏到托盘」, 托盘右键可退出
- 日志同时写入 `star-audio-bridge.log` (UTF-8)

无界面模式 (自动化/调试): `StarAudioBridge.Server.exe --console`

可选参数: `--ctrl-port <端口>` `--media-port <端口>` `--dump <file>` `--console`

## Windows 防火墙

首次运行会被防火墙拦截, 放行 TCP 59301 / UDP 59302 (管理员 PowerShell):

```powershell
netsh advfirewall firewall add rule name="StarAudioBridge TCP" dir=in action=allow protocol=TCP localport=59301
netsh advfirewall firewall add rule name="StarAudioBridge UDP" dir=in action=allow protocol=UDP localport=59302
```

## 用法

1. 电脑和手机连**同一个 Wi-Fi/路由器**
2. 启动本服务, 记下电脑的局域网 IP (`ipconfig` 查 IPv4)
3. 手机打开 StarAudioBridge App, 输入该 IP, 点「连接」
4. 想听电脑声音: 打开「播放电脑声音」
5. 想用手机当麦克风:
   - 推荐先安装虚拟音频线，在 PC 服务窗口的「手机麦克风输出」中选择它
   - 再在会议、直播或录音软件中选择虚拟音频线对应的**录音端点**作为麦克风
   - 未检测到虚拟设备时默认关闭本地监听，避免手机声音从电脑扬声器延迟回放并再次进入系统环回

> 手动选择物理扬声器仍可监听手机麦克风，但会产生延迟耳返和回声风险；仅建议配合耳机调试。

## 延迟相关 (默认参数)

| 项 | 值 | 说明 |
|---|---|---|
| 采样率 | 48kHz | |
| 帧长 | 5ms (960B 立体声) | 单包 < MTU, 不 IP 分片 |
| 传输 | UDP 裸 PCM | 无编解码延迟, 局域网带宽 ~1.5Mbps |
| 手机端预缓冲 | 1~12 帧可调 (默认 4 = 20ms) | UI 里滑杆调节 |
| 目标端到端延迟 | < 100ms | 同 Wi-Fi 下 |

## 后续优化方向

- Opus 编码 (带宽敏感场景, 手机/PC 端各加 ~20ms)
- FEC/前向纠错抗丢包
- 双 UDP 端口分离上下行
- mDNS 自动发现 / 二维码扫码
- 内置虚拟麦克风驱动 (免安装第三方虚拟音频线)
- 托盘常驻 + 开机自启
