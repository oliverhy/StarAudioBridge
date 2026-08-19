# StarAudioBridge — 鸿蒙端「电脑音频随身听 + 随身麦克风」

> bundle: `com.yinhe.staraudiobridge` · API 24 (HarmonyOS 6.1.1) · DevEco/hvigor 6.24
> 一句话: **不挑电脑的跨端音频桥** —— 任意 Windows PC 装个小服务, 鸿蒙手机扫码/输 IP 即连:
> 手机当无线音箱放电脑声音、当无线麦克风给电脑说话; 手机已配对的蓝牙耳机自动接管输出。

## 项目结构

```
StarAudioBridge/
├── entry/                          # 鸿蒙 App (Stage 模型, ArkTS)
│   └── src/main/ets/
│       ├── model/Protocol.ets      # 线协议: UDP 包头 + 控制 JSON
│       ├── audio/JitterBuffer.ets  # 抖动缓冲 (乱序归位/补静音/统计)
│       ├── audio/PcmPlayer.ets     # AudioRenderer 低延迟 writeData 播放
│       ├── audio/MicCapturer.ets   # AudioCapturer readData 采麦
│       ├── net/ControlChannel.ets  # TCP 控制通道 (换行 JSON)
│       ├── net/AudioBridgeClient.ets # 协调器: 握手/UDP/启停/心跳/后台保活
│       └── pages/Index.ets         # UI: 连接/开关/预缓冲/实时统计
└── PC-Server/                      # Windows 服务端 (C# .NET 8 + NAudio)
    └── Program.cs                  # WASAPI 环回采集 + UDP 推流 + 麦克风播放
```

## 延迟设计 (UDP 极致低延迟)

- **传输**: UDP 裸 PCM S16LE 48kHz, 5ms/帧 (立体声 960B / 单声道 480B), 单包不触发 IP 分片。
- **播放**: `AudioRenderer` 的 `writeData` 回调 (系统按需拉取, 无额外缓冲), 手机端预缓冲 1~12 帧可调 (默认 4 = 20ms)。
- **采集**: `AudioCapturer` 的 `readData` 回调。
- **控制**: TCP + TCPNoDelay 意向, 换行 JSON; 每 2s ping 测 RTT。
- **保活**: `backgroundTaskManager` audioPlayback 长时任务, 锁屏持续播放。
- 目标端到端 < 100ms (同 Wi-Fi)。预留 Opus/FEC 优化路径。

## 协议摘要

- 控制 (TCP 59301): `hello → welcome{sr,ch,codec,frameMs,udpPort}` / `start{pc2phone,phone2pc}` / `ping→pong` / `bye`
- 媒体 (UDP 59302, 双向): 8 字节头 `magic(0x5A41) ver flags seq len` + PCM 载荷
- 手机连接后先发**通告包** (空载荷 FIRST 帧), PC 据此学习手机 UDP 端点用于回推音频。

## 构建

```powershell
# 工程根目录
devecocli build --build-mode debug        # 产物: entry/build/default/outputs/entry-default-unsigned.hap
```

仓库不会提交本机签名文件或带有绝对路径的 `build-profile.json5`。首次在新电脑打开项目时，复制 `build-profile.example.json5` 为 `build-profile.json5`，再用 DevEco Studio 自动签名，或执行：

```powershell
devecocli auth login
devecocli signature generate
```

正式上架请使用华为开发者账号生成的 release 签名材料；不要把 `.p12`、密码、`.cer` 或 `.p7b` 提交到 Git。

## 部署到真机 (需要你的华为账号, 交互式命令由你执行)

已检测到真机 **HUAWEI Mate 60 Pro** (`FMR0223825061156`)。安装需要签名:

```powershell
devecocli auth login          # 登录华为账号 (交互式)
devecocli signature generate  # 生成签名材料并写入工程配置
devecocli run --module entry  # 构建+安装+启动到真机
```

或直接在 DevEco Studio 打开工程, File → Project Structure → Signing Configs → 自动签名, 然后 Run。

## 使用

1. PC 端: 见 `PC-Server/README.md` (需 .NET 8 SDK, 当前本机未安装)
2. 手机与电脑同一 Wi-Fi:
   - **自动发现 (推荐)**: App 首页点「自动发现电脑」→ 点发现的电脑即自动连接
   - 手动: 输入电脑 IP 连接
3. 开关「播放电脑声音」「手机当麦克风」:
   - 双向开启时手机自动使用系统语音通话链路，并优先走听筒以启用 AEC、减少声学回授
   - PC 端默认关闭手机麦克风的扬声器监听；作为电脑麦克风使用时，请在 PC 界面选择虚拟音频线输出
   - 蓝牙/有线耳机已连接时，手机系统会优先保留外接音频路由

## mDNS 自动发现

- PC 端开机即广播 `_star-audio-bridge._tcp` (Makaretu.Dns.Multicast), 附带电脑名
- 手机端用 `@ohos.net.mdns` 搜索 `_star-audio-bridge._tcp`, 列出发现的电脑, 点击自动填 IP 并连接
- 免去手输 IP; 若自动发现不到(路由器禁组播等), 仍可手动输入

## 真机实测结果 (HUAWEI Mate 60 Pro + Windows 11, 2026-08-14)

| 项 | 结果 |
|---|---|
| 连接握手 (TCP 59301 + UDP 通告) | ✅ 秒连 |
| PC→手机 音频流 | ✅ 稳定 200fps (48k 立体声 5ms/帧), 手机播放器持续运行 |
| 手机→PC 麦克风 | ✅ 实时 ~97KB/s (48k 单声道), PC 端正常播放 |
| RTT (控制通道心跳) | ✅ 8~25ms (同 Wi-Fi) |
| 抖动缓冲 | ✅ 默认 120ms/可调 5~300ms, 长时播放缓冲稳定无漂移 |
| 丢包 | ~3% (共享 Wi-Fi 下补静音/丢帧, 后续可加 FEC) |
| 静音时 | PC 环回不产生数据 → 手机自动停流, 有声即恢复 |

### 已知限制 (重要)

- **锁屏/灭屏后音频中断**: 后台长时任务 (`backgroundTaskManager`) 在**调试签名/hdc 安装**下被系统拒绝
  (9800005, 已对照验证 DATA_TRANSFER 同样被拒, 属系统级限制而非代码问题)。
  **正式签名上架(或 release 签名安装)后应可用**; 当前可用 App 内「保持屏幕常亮」开关保底。
- WASAPI 环回静音时无数据: 属正常行为, 有声音才推流。
- Windows 普通应用不能直接创建系统麦克风设备；手机麦克风需要输出到虚拟音频线，再由会议/录音软件选择对应录音端点。

## 待办 (Roadmap)

- [ ] PC 端 .NET 构建验证 + 真机联调 (延迟实测) — 已双向打通, 剩余延迟精调
- [x] mDNS 自动发现 (手机自动找到电脑)
- [ ] 二维码扫码 (另一台电脑/手机扫码连接)
- [ ] release 签名后验证长时任务/锁屏播放
- [ ] Opus 编码选项 (带宽敏感场景)
- [ ] UDP 丢包 FEC / 码率自适应 / 丢帧掩蔽(重复上一帧替代静音) — 丢帧掩蔽已完成
- [ ] 服务卡片一键开关、多设备
