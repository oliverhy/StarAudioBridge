/*
 * StarAudioBridge 主页面
 * - 输入 PC 的 IP/端口, 连接/断开
 * - 开关: 播放电脑声音(PC->手机) / 手机当麦克风(手机->PC)
 * - 预缓冲深度调节 (延迟 vs 抗抖动)
 * - 实时状态: RTT / 抖动 / 丢包 / 欠载 / 日志
 */
import { common } from '@kit.AbilityKit';
import { AudioBridgeClient, BridgeState, BridgeStats } from '../net/AudioBridgeClient';
import { DiscoveredHost, MdnsDiscovery } from '../net/MdnsDiscovery';
import { Proto } from '../model/Protocol';

const MAX_LOG: number = 60;
const APP_VERSION: string = '1.0.1';
const APP_VERSION_CODE: string = '1000001';
const APP_BUNDLE: string = 'com.yinhe.staraudiobridge';
const SUPPORT_EMAIL: string = '39323856@qq.com';

@Entry
@Component
struct Index {
  @State ip: string = '192.168.1.189';
  @State port: string = `${Proto.DEFAULT_CONTROL_PORT}`;
  @State connecting: boolean = false;
  @State connected: boolean = false;
  @State pc2phone: boolean = true;
  @State phone2pc: boolean = false;
  @State echoProtection: boolean = true;
  @State keepScreenOn: boolean = false;
  @State prebuffer: number = 24;
  @State statusText: string = '未连接';
  @State statsText: string = '等待连接...';
  @State logs: string[] = [];
  @State searching: boolean = false;
  @State foundHosts: DiscoveredHost[] = [];

  private client: AudioBridgeClient | undefined = undefined;
  private statsTimer: number | undefined = undefined;
  private discovery: MdnsDiscovery | undefined = undefined;

  aboutToAppear(): void {
    this.appendLog('StarAudioBridge v1.0.1 — UDP 低延迟音频桥');
    this.appendLog('可点「自动发现电脑」找到 PC, 或手动输入 IP 连接');
  }

  aboutToDisappear(): void {
    this.stopStatsTimer();
    this.stopDiscovery();
  }

  onPageShow(): void {
    this.startStatsTimer();
  }

  onPageHide(): void {
    this.stopStatsTimer();
  }

  build() {
    Column({ space: 10 }) {
      // 标题
      Text('StarAudioBridge')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16 })

      // 连接参数
      Row({ space: 8 }) {
        TextInput({ placeholder: 'PC 局域网 IP', text: this.ip })
          .layoutWeight(1)
          .type(InputType.Normal)
          .onChange((v: string): void => {
            this.ip = v;
          })
        TextInput({ placeholder: '端口', text: this.port })
          .width(96)
          .type(InputType.Number)
          .onChange((v: string): void => {
            this.port = v;
          })
      }
      .width('92%')

      // 连接 / 断开
      Row({ space: 12 }) {
        Button(this.connected ? '断开' : '连接')
          .width(140)
          .enabled(!this.connecting)
          .onClick(() => {
            if (this.connected) {
              this.onDisconnect();
            } else {
              this.onConnect();
            }
          })
        if (this.connecting) {
          Text('连接中...')
            .fontColor('#666666')
        }
      }
      .margin({ top: 4 })

      // 自动发现
      Row({ space: 12 }) {
        Button(this.searching ? '停止搜索' : '自动发现电脑')
          .width(140)
          .onClick(() => {
            if (this.searching) {
              this.stopDiscovery();
            } else {
              this.startDiscovery();
            }
          })
        Text(this.searching ? '搜索中...' : '点击搜索局域网内的 PC')
          .fontSize(13)
          .fontColor('#888888')
      }
      .width('92%')

      // 发现的设备列表
      if (this.foundHosts.length > 0) {
        List({ space: 4 }) {
          ForEach(this.foundHosts, (h: DiscoveredHost) => {
            ListItem() {
              Row({ space: 8 }) {
                Text('🖥 ' + h.name)
                  .fontSize(14)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(h.ip + ':' + h.port)
                  .fontSize(12)
                  .fontColor('#1a6bff')
              }
              .width('100%')
              .padding(10)
              .backgroundColor('#f2f2f2')
              .borderRadius(8)
              .onClick(() => {
                this.onHostSelected(h);
              })
            }
          }, (h: DiscoveredHost) => h.ip + h.port)
        }
        .width('92%')
        .height(this.foundHosts.length > 3 ? 132 : undefined)
        .scrollBar(BarState.Off)
      }

      Divider().margin({ top: 6, bottom: 6 })

      // 方向开关
      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.pc2phone })
          .onChange((on: boolean): void => {
            this.pc2phone = on;
            this.applyDirections();
          })
        Text('播放电脑声音')
          .layoutWeight(1)
          .fontSize(16)
        Text(this.pc2phone ? 'PC → 手机' : '关闭')
          .fontSize(13)
          .fontColor(this.pc2phone ? '#1a6bff' : '#999999')
      }
      .width('92%')

      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.phone2pc })
          .onChange((on: boolean): void => {
            this.phone2pc = on;
            this.applyDirections();
          })
        Text('手机当麦克风')
          .layoutWeight(1)
          .fontSize(16)
        Text(this.phone2pc ? '手机 → PC' : '关闭')
          .fontSize(13)
          .fontColor(this.phone2pc ? '#1a6bff' : '#999999')
      }
      .width('92%')

      // 双向开启时可在音乐音质和系统防回声链路之间选择。
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Switch, isOn: this.echoProtection })
            .onChange((on: boolean): void => {
              this.echoProtection = on;
              this.applyEchoProtection();
            })
          Text('双向音频模式')
            .layoutWeight(1)
            .fontSize(14)
          Text(this.echoProtection ? '防回声优先' : '音质优先')
            .fontSize(13)
            .fontColor(this.echoProtection ? '#00a862' : '#1a6bff')
        }
        .width('100%')

        Text(this.echoProtection
          ? '适合手机外放：通话链路与听筒优先，回声更少，音乐音质会降低'
          : '适合耳机：保持 48kHz 双声道音乐链路；手机外放时可能产生回声')
          .fontSize(12)
          .fontColor('#777777')
          .width('100%')
      }
      .width('92%')

      // 预缓冲调节
      Row({ space: 8 }) {
        Text(`预缓冲 ${this.prebuffer * Proto.FRAME_MS}ms`)
          .fontSize(14)
          .width(110)
        Slider({ value: this.prebuffer, min: 1, max: 60, step: 1 })
          .layoutWeight(1)
          .onChange((v: number, _mode: SliderChangeMode): void => {
            this.prebuffer = Math.round(v);
            if (this.client !== undefined) {
              this.client.setPrebuffer(this.prebuffer);
            }
          })
      }
      .width('92%')

      // 屏幕常亮 (后台保活被系统限制时的保底)
      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.keepScreenOn })
          .onChange((on: boolean): void => {
            this.keepScreenOn = on;
            if (this.client !== undefined) {
              this.client.setKeepScreenOn(on);
            }
          })
        Text('保持屏幕常亮')
          .layoutWeight(1)
          .fontSize(14)
        Text(this.keepScreenOn ? '开' : '关')
          .fontSize(13)
          .fontColor(this.keepScreenOn ? '#1a6bff' : '#999999')
      }
      .width('92%')

      Divider().margin({ top: 6, bottom: 6 })

      // 状态
      Text(this.statusText)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.connected ? '#00a862' : '#666666')
        .width('92%')

      Text(this.statsText)
        .fontSize(13)
        .fontColor('#555555')
        .width('92%')
        .textAlign(TextAlign.Start)

      Divider().margin({ top: 6, bottom: 6 })

      // 日志
      Text('日志')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .width('92%')

      List({ space: 2 }) {
        ForEach(this.logs, (line: string) => {
          ListItem() {
            Text(line)
              .fontSize(12)
              .fontColor('#444444')
              .width('100%')
          }
        }, (line: string, idx: number) => `${idx}_${line}`)
      }
      .layoutWeight(1)
      .width('92%')
      .alignListItem(ListItemAlign.Start)
      .scrollBar(BarState.Off)

      // 关于
      Divider().margin({ top: 6, bottom: 6 })
      Column({ space: 3 }) {
        Text('关于 StarAudioBridge')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .width('92%')
        Text(`版本 ${APP_VERSION}  (Build ${APP_VERSION_CODE})`)
          .fontSize(12)
          .fontColor('#666666')
          .width('92%')
        Text(`Bundle: ${APP_BUNDLE}`)
          .fontSize(12)
          .fontColor('#666666')
          .width('92%')
        Text('HarmonyOS 双向低延迟音频桥 · PCM 48kHz · TCP/UDP')
          .fontSize(12)
          .fontColor('#666666')
          .width('92%')
        Text(`联系邮箱：${SUPPORT_EMAIL}`)
          .fontSize(12)
          .fontColor('#1a6bff')
          .width('92%')
      }
      .width('100%')
      .padding({ bottom: 4 })

      Blank().height(12)
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 逻辑 ----------

  // ---------- mDNS 自动发现 ----------

  private startDiscovery(): void {
    try {
      const hostCtx = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        this.appendLog('无法获取宿主上下文');
        return;
      }
      const ctx = hostCtx as common.UIAbilityContext;
      const d = new MdnsDiscovery(ctx);
      this.discovery = d;
      d.onFound = (host: DiscoveredHost): void => {
        this.addFoundHost(host);
      };
      d.onLog = (msg: string): void => {
        this.appendLog(msg);
      };
      this.foundHosts = [];
      this.searching = true;
      d.start();
    } catch (err) {
      this.appendLog('自动发现启动失败: ' + JSON.stringify(err));
      this.searching = false;
    }
  }

  private stopDiscovery(): void {
    const d = this.discovery;
    this.discovery = undefined;
    if (d !== undefined) {
      d.stop();
    }
    this.searching = false;
  }

  private addFoundHost(host: DiscoveredHost): void {
    // 按 IP 去重
    for (let i = 0; i < this.foundHosts.length; i++) {
      if (this.foundHosts[i].ip === host.ip) {
        return;
      }
    }
    this.foundHosts = [...this.foundHosts, host];
  }

  private onHostSelected(host: DiscoveredHost): void {
    this.stopDiscovery();
    this.ip = host.ip;
    this.port = host.port.toString();
    this.appendLog('选择电脑: ' + host.name + ' (' + host.ip + ':' + host.port + ')');
    if (!this.connected) {
      this.onConnect();
    }
  }

  private appendLog(msg: string): void {
    const ts: string = new Date().toTimeString().substring(0, 8);
    const lines: string[] = [`[${ts}] ${msg}`, ...this.logs];
    this.logs = lines.slice(0, MAX_LOG);
  }

  private async onConnect(): Promise<void> {
    if (this.connecting) {
      return;
    }
    this.connecting = true;
    try {
      const hostCtx = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        this.appendLog('无法获取宿主上下文');
        return;
      }
      const ctx = hostCtx as common.UIAbilityContext;
      const client = new AudioBridgeClient(ctx, this.prebuffer);
      // 同步当前 UI 开关状态到客户端 (否则重连后麦克风/播放开关状态会丢失)
      client.setEchoProtection(this.echoProtection);
      client.setDirections(this.pc2phone, this.phone2pc);
      this.client = client;
      client.onLog = (msg: string): void => {
        this.appendLog(msg);
      };
      client.onStateChanged = (state: BridgeState): void => {
        this.onBridgeState(state);
      };
      await client.connect(this.ip.trim(), parseInt(this.port, 10));
    } catch (err) {
      this.appendLog('连接失败: ' + JSON.stringify(err));
    } finally {
      this.connecting = false;
    }
  }

  private async onDisconnect(): Promise<void> {
    const client = this.client;
    this.client = undefined;
    if (client !== undefined) {
      await client.disconnect();
    }
    this.connected = false;
    this.statusText = '未连接';
    this.statsText = '等待连接...';
  }

  private onBridgeState(state: BridgeState): void {
    if (state === BridgeState.STREAMING) {
      this.connected = true;
      this.statusText = '已连接, 音频流进行中';
    } else if (state === BridgeState.CONNECTING) {
      this.statusText = '连接中...';
    } else {
      this.connected = false;
      this.statusText = '未连接';
    }
  }

  private applyDirections(): void {
    const client = this.client;
    if (client === undefined) {
      return;
    }
    client.setDirections(this.pc2phone, this.phone2pc);
  }

  private applyEchoProtection(): void {
    const client = this.client;
    if (client === undefined) {
      return;
    }
    client.setEchoProtection(this.echoProtection);
  }

  private startStatsTimer(): void {
    this.stopStatsTimer();
    this.statsTimer = setInterval((): void => {
      const client = this.client;
      if (client === undefined) {
        return;
      }
      const s: BridgeStats = client.getStats();
      const lossRate: string = s.received + s.lost > 0
        ? ((100 * s.lost) / (s.received + s.lost)).toFixed(2)
        : '0.00';
      this.statsText =
        `RTT ${s.rttMs}ms(均${s.rttAvgMs.toFixed(0)}ms)  抖动 ${s.jitterAvgMs.toFixed(1)}ms/峰${s.jitterMaxMs}ms\n` +
        `缓冲 ${s.jitterDepth}帧  收包 ${s.received}  丢帧 ${lossRate}%  迟到 ${s.late}  欠载 ${s.underrun}\n` +
        `播放 ${s.playerState}  麦克风 ${s.micState}  对端 ${s.peer}:${s.mediaPort}`;
    }, 500);
  }

  private stopStatsTimer(): void {
    if (this.statsTimer !== undefined) {
      clearInterval(this.statsTimer);
      this.statsTimer = undefined;
    }
  }
}
