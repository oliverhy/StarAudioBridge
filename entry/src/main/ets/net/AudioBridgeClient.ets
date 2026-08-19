/*
 * StarAudioBridge 客户端协调器:
 * - TCP 控制通道握手/启停/心跳(RTT 测量)
 * - UDP 媒体通道 (PC->手机 播放 / 手机->PC 麦克风)
 * - 抖动缓冲 + 低延迟播放器 + 麦克风采集 编排
 * - 后台长时任务 (audioPlayback) 保活
 */
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityAccessCtrl, common, PermissionRequestResult, WantAgent, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { window } from '@kit.ArkUI';
import {
  ByeMsg, HelloMsg, ParsedPacket, PingMsg, Proto, StartMsg, WelcomeMsg
} from '../model/Protocol';
import { JitterBuffer } from '../audio/JitterBuffer';
import { MicCapturer } from '../audio/MicCapturer';
import { PcmPlayer } from '../audio/PcmPlayer';
import { ControlChannel } from './ControlChannel';

const DOMAIN: number = 0x0000;
const TAG: string = 'StarAudioBridge';

export enum BridgeState {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  STREAMING = 'streaming'
}

export class BridgeStats {
  state: string = BridgeState.IDLE;
  pc2phone: boolean = false;
  phone2pc: boolean = false;
  rttMs: number = 0;
  rttAvgMs: number = 0;
  jitterDepth: number = 0;
  jitterMaxMs: number = 0;
  jitterAvgMs: number = 0;
  received: number = 0;
  lost: number = 0;
  late: number = 0;
  underrun: number = 0;
  playerState: string = 'stopped';
  micState: string = 'stopped';
  peer: string = '';
  mediaPort: number = 0;
}

export class AudioBridgeClient {
  onLog: (msg: string) => void = (msg: string): void => {
  };
  onStateChanged: (state: BridgeState) => void = (state: BridgeState): void => {
  };

  private readonly ctx: common.UIAbilityContext;
  private control: ControlChannel;
  private udp: socket.UDPSocket | undefined = undefined;
  private player: PcmPlayer | undefined = undefined;
  private mic: MicCapturer | undefined = undefined;
  private jitter: JitterBuffer = new JitterBuffer(Proto.STEREO_FRAME_BYTES, 128);

  private state: BridgeState = BridgeState.IDLE;
  private host: string = '';
  private mediaPort: number = Proto.DEFAULT_MEDIA_PORT;
  private pc2phone: boolean = true;
  private phone2pc: boolean = false;
  private echoProtection: boolean = true;

  private pingSeq: number = 0;
  private lastPingTs: number = 0;
  private rttMs: number = 0;
  private rttSum: number = 0;
  private rttSamples: number = 0;
  private pingTimer: number | undefined = undefined;
  private lrtActive: boolean = false;

  private welcomeResolver: ((w: WelcomeMsg) => void) | undefined = undefined;
  private welcomeRejecter: ((e: Error) => void) | undefined = undefined;

  private avSession: avSession.AVSession | undefined = undefined;
  private prebufferFrames: number;
  private playerStarted: boolean = false;
  private micSeq: number = 0;

  constructor(ctx: common.UIAbilityContext, prebufferFrames: number = 24) {
    this.ctx = ctx;
    this.prebufferFrames = prebufferFrames;
    this.control = new ControlChannel(
      (line: string): void => this.handleControlLine(line),
      (): void => this.handleControlClosed(),
      (msg: string): void => this.log('控制通道错误: ' + msg)
    );
  }

  get currentState(): BridgeState {
    return this.state;
  }

  /** 调整预缓冲深度 (帧数), 越大越稳、延迟越高。 */
  setPrebuffer(frames: number): void {
    if (frames < 1) {
      frames = 1;
    }
    if (frames > 60) {
      frames = 60;
    }
    this.prebufferFrames = frames;
    this.jitter.reset();
  }

  log(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
    this.onLog(msg);
  }

  /** 连接 PC: TCP 握手 -> UDP 就绪 -> 开始推流。 */
  async connect(host: string, port: number): Promise<void> {
    if (this.state === BridgeState.CONNECTING || this.state === BridgeState.CONNECTED
      || this.state === BridgeState.STREAMING) {
      this.log('已在连接中');
      return;
    }
    this.host = host;
    this.state = BridgeState.CONNECTING;
    this.onStateChanged(this.state);
    this.log(`连接 ${host}:${port} ...`);

    try {
      // 1) TCP 控制通道
      await this.control.connect(host, port);
      this.control.sendJson(new HelloMsg());

      // 2) 等待 welcome (5s 超时)
      const welcome: WelcomeMsg = await this.waitWelcome();
      this.mediaPort = welcome.udpPort > 0 ? welcome.udpPort : Proto.DEFAULT_MEDIA_PORT;
      this.log(`握手成功: ${welcome.sr}Hz/${welcome.ch}ch codec=${welcome.codec} UDP端口=${this.mediaPort}`);

      // 3) UDP 媒体通道
      this.udp = socket.constructUDPSocketInstance();
      await this.udp.bind({ address: '0.0.0.0', family: 1 });
      await this.udp.setExtraOptions({
        receiveBufferSize: 2 * 1024 * 1024,
        sendBufferSize: 2 * 1024 * 1024
      });
      this.udp.on('message', (info: socket.SocketMessageInfo): void => {
        this.handleUdpMessage(info);
      });
      // 通告包: 让 PC 知道本机 UDP 端点, 用于回推音频
      const announce: ArrayBuffer = Proto.buildPacket(0, new ArrayBuffer(0), Proto.FLAG_FIRST);
      await this.udp.send({
        data: announce,
        address: { address: host, port: this.mediaPort, family: 1 }
      });

      // 4) 开始推流
      this.state = BridgeState.STREAMING;
      this.onStateChanged(this.state);
      this.sendStart();
      this.startPingLoop();
      await this.ensureAvSession();   // AVSession 是 audioPlayback 长时任务的前置条件
      this.startLongRunningTask();
      this.log('已开始音频流');
    } catch (err) {
      this.log('连接失败: ' + JSON.stringify(err));
      await this.teardown(false);
      throw new Error('connect failed: ' + JSON.stringify(err));
    }
  }

  /** 断开连接, 释放全部资源。 */
  async disconnect(): Promise<void> {
    await this.teardown(true);
  }

  /** 更新方向开关 (播放电脑声音 / 手机当麦克风)。 */
  async setDirections(pc2phone: boolean, phone2pc: boolean): Promise<void> {
    const previousVoiceMode: boolean = this.phone2pc && this.echoProtection;
    this.pc2phone = pc2phone;
    this.phone2pc = phone2pc;
    const audioModeChanged: boolean = previousVoiceMode !== (this.phone2pc && this.echoProtection);
    if (this.state === BridgeState.STREAMING) {
      this.sendStart();
      // AudioRenderer 的音乐/通话 usage 创建后不可原地切换。
      // 双向状态改变时重建播放器，使手机系统 AEC 获得正确的播放参考。
      if (audioModeChanged && this.playerStarted) {
        await this.stopPlayer();
        if (pc2phone) {
          await this.startPlayer();
        }
      }
      if (phone2pc) {
        await this.ensureMic();
      } else {
        await this.stopMic();
      }
    }
  }

  /** 双向音频策略：开启时优先 AEC/防回声，关闭时优先音乐播放音质。 */
  async setEchoProtection(enabled: boolean): Promise<void> {
    if (this.echoProtection === enabled) {
      return;
    }
    this.echoProtection = enabled;
    if (this.state !== BridgeState.STREAMING || !this.phone2pc) {
      return;
    }

    // 播放和采集的 usage/source 都是在创建时确定，切换策略时需要重建。
    if (this.playerStarted) {
      await this.stopPlayer();
      if (this.pc2phone) {
        await this.startPlayer();
      }
    }
    await this.stopMic();
    await this.ensureMic();
    this.log(enabled
      ? '双向模式: 防回声优先 (通话链路/AEC/听筒优先)'
      : '双向模式: 音质优先 (音乐链路/扬声器，建议使用耳机)');
  }

  /** 保持屏幕常亮 (后台长时任务被系统拒绝时的临时保底方案)。 */
  async setKeepScreenOn(on: boolean): Promise<void> {
    try {
      const win = await window.getLastWindow(this.ctx);
      await win.setWindowKeepScreenOn(on);
      this.log('屏幕常亮: ' + (on ? '开启' : '关闭'));
    } catch (err) {
      this.log('设置屏幕常亮失败: ' + JSON.stringify(err));
    }
  }

  /** 当前统计快照 (UI 轮询)。 */
  getStats(): BridgeStats {
    const s = new BridgeStats();
    s.state = this.state;
    s.pc2phone = this.pc2phone;
    s.phone2pc = this.phone2pc;
    s.rttMs = this.rttMs;
    s.rttAvgMs = this.rttSamples > 0 ? this.rttSum / this.rttSamples : 0;
    s.jitterDepth = this.jitter.depth;
    s.jitterMaxMs = this.jitter.maxJitterMs;
    s.jitterAvgMs = this.jitter.avgJitterMs;
    s.received = this.jitter.received;
    s.lost = this.jitter.lost;
    s.late = this.jitter.late;
    s.underrun = this.jitter.underrun;
    s.playerState = this.player !== undefined ? this.player.state : 'stopped';
    s.micState = this.mic !== undefined ? this.mic.state : 'stopped';
    s.peer = this.host;
    s.mediaPort = this.mediaPort;
    return s;
  }

  // ---------- 内部 ----------

  private waitWelcome(): Promise<WelcomeMsg> {
    return new Promise<WelcomeMsg>((resolve: (w: WelcomeMsg) => void, reject: (e: Error) => void): void => {
      this.welcomeResolver = resolve;
      this.welcomeRejecter = reject;
      setTimeout((): void => {
        if (this.welcomeResolver !== undefined) {
          this.welcomeResolver = undefined;
          this.welcomeRejecter = undefined;
          reject(new Error('等待 welcome 超时'));
        }
      }, 5000);
    });
  }

  private handleControlLine(line: string): void {
    try {
      const obj = JSON.parse(line) as Record<string, Object>;
      const t: string = obj['t'] as string;
      if (t === 'welcome') {
        const w = new WelcomeMsg();
        w.sr = obj['sr'] as number;
        w.ch = obj['ch'] as number;
        w.codec = obj['codec'] as string;
        w.frameMs = obj['frameMs'] as number;
        w.udpPort = obj['udpPort'] as number;
        const resolver = this.welcomeResolver;
        if (resolver !== undefined) {
          this.welcomeResolver = undefined;
          this.welcomeRejecter = undefined;
          resolver(w);
        }
      } else if (t === 'pong') {
        const now: number = Date.now();
        this.rttMs = now - this.lastPingTs;
        this.rttSum += this.rttMs;
        this.rttSamples++;
      } else {
        this.log('控制消息: ' + line);
      }
    } catch (err) {
      this.log('控制消息解析失败: ' + JSON.stringify(err));
    }
  }

  private handleControlClosed(): void {
    this.log('控制通道已断开');
    this.teardown(true);
  }

  private handleUdpMessage(info: socket.SocketMessageInfo): void {
    const pkt: ParsedPacket | null = Proto.parsePacket(info.message);
    if (pkt === null) {
      return;
    }
    if ((pkt.flags & Proto.FLAG_END) !== 0) {
      this.log('收到流结束标记');
      this.stopPlayer();
      return;
    }
    if (pkt.payload.byteLength === 0) {
      return; // 通告包/空包不入抖动缓冲, 避免污染序号对齐
    }
    this.jitter.push(pkt.seq, pkt.payload);

    // 预缓冲达到目标后再启动播放器, 避免开头欠载
    if (!this.playerStarted && this.pc2phone && this.jitter.depth >= this.prebufferFrames) {
      this.startPlayer();
    }
  }

  private sendStart(): void {
    const msg = new StartMsg();
    msg.pc2phone = this.pc2phone;
    msg.phone2pc = this.phone2pc;
    this.control.sendJson(msg);
  }

  private startPingLoop(): void {
    this.stopPingLoop();
    this.pingTimer = setInterval((): void => {
      if (this.state !== BridgeState.STREAMING) {
        return;
      }
      const msg = new PingMsg();
      msg.id = this.pingSeq++;
      msg.ts = Date.now();
      this.lastPingTs = msg.ts;
      this.control.sendJson(msg);

      // 每 5 次心跳(约10s)输出一次接收统计, 便于锁屏后观察
      if (this.pingSeq % 5 === 0) {
        hilog.info(DOMAIN, TAG,
          'recv=%{public}d depth=%{public}d lost=%{public}d late=%{public}d underrun=%{public}d',
          this.jitter.received, this.jitter.depth, this.jitter.lost, this.jitter.late, this.jitter.underrun);
      }
    }, 2000);
  }

  private stopPingLoop(): void {
    if (this.pingTimer !== undefined) {
      clearInterval(this.pingTimer);
      this.pingTimer = undefined;
    }
  }

  private async startPlayer(): Promise<void> {
    if (this.playerStarted) {
      return;
    }
    this.playerStarted = true;
    try {
      const voiceMode: boolean = this.phone2pc && this.echoProtection;
      this.player = new PcmPlayer(this.jitter, voiceMode);
      await this.player.start();
      this.log(voiceMode
        ? '播放器已启动 (通话模式/AEC/听筒优先)'
        : '播放器已启动 (低延迟音乐模式)');
    } catch (err) {
      this.playerStarted = false;
      this.log('播放器启动失败: ' + JSON.stringify(err));
    }
  }

  private async stopPlayer(): Promise<void> {
    this.playerStarted = false;
    const p = this.player;
    this.player = undefined;
    if (p !== undefined) {
      await p.stop();
    }
  }

  private async ensureMic(): Promise<void> {
    // 先申请麦克风权限
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(this.ctx, ['ohos.permission.MICROPHONE']);
      let granted: boolean = false;
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        granted = true;
      }
      if (!granted) {
        this.log('麦克风权限被拒绝, 手机->PC 方向不可用');
        return;
      }
    } catch (err) {
      this.log('请求麦克风权限失败: ' + JSON.stringify(err));
      return;
    }

    if (this.mic !== undefined) {
      return;
    }
    this.mic = new MicCapturer((buf: ArrayBuffer): void => {
      this.sendMicPacket(buf);
    }, this.echoProtection);
    try {
      await this.mic.start();
      this.log('麦克风采集已启动');
    } catch (err) {
      this.log('麦克风启动失败: ' + JSON.stringify(err));
    }
  }

  private async stopMic(): Promise<void> {
    const m = this.mic;
    this.mic = undefined;
    if (m !== undefined) {
      await m.stop();
    }
  }

  private sendMicPacket(buf: ArrayBuffer): void {
    const udp = this.udp;
    if (udp === undefined || this.phone2pc === false) {
      return;
    }
    const packet: ArrayBuffer = Proto.buildPacket(this.micSeq, buf, 0);
    this.micSeq = (this.micSeq + 1) & 0xFFFF;
    const target: socket.NetAddress = {
      address: this.host,
      port: this.mediaPort,
      family: 1
    };
    try {
      udp.send({ data: packet, address: target });
    } catch (err) {
      // 静默丢弃: 网络瞬时繁忙
      hilog.warn(DOMAIN, TAG, 'UDP send failed: %{public}s', JSON.stringify(err));
    }
  }

  private async ensureAvSession(): Promise<void> {
    if (this.avSession !== undefined) {
      return;
    }
    try {
      const session = await avSession.createAVSession(this.ctx, 'StarAudioBridge', 'audio');
      await session.activate();
      // 设置媒体元数据: 让系统识别为"音乐/媒体"应用, 从而允许后台播放
      const meta: avSession.AVMetadata = {
        assetId: 'star-audio-bridge-stream',
        title: 'StarAudioBridge 电脑音频',
        artist: this.host,
        album: '电脑声音',
        subtitle: 'UDP 低延迟'
      };
      await session.setAVMetadata(meta);
      const state: avSession.AVPlaybackState = {
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        speed: 1.0,
        position: { elapsedTime: 0, updateTime: Date.now() }
      };
      await session.setAVPlaybackState(state);
      this.avSession = session;
      this.log('AVSession 已激活 (音乐播放器模式)');
    } catch (err) {
      this.log('AVSession 创建失败: ' + JSON.stringify(err));
    }
  }

  private async destroyAvSession(): Promise<void> {
    const s = this.avSession;
    this.avSession = undefined;
    if (s !== undefined) {
      try {
        await s.destroy();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'avSession destroy failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  private async startLongRunningTask(): Promise<void> {
    if (this.lrtActive) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'com.yinhe.staraudiobridge',
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      // API 22+: 音频类长时任务使用 MODE_AV_PLAYBACK_AND_RECORD + AVSESSION 子模式。
      // 注意: 调试签名/hdc 安装的应用会被系统拒绝 (9800005), 正式签名上架后可用。
      const req = new backgroundTaskManager.ContinuousTaskRequest();
      req.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_AV_PLAYBACK_AND_RECORD];
      req.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_AVSESSION_AUDIO_PLAYBACK];
      req.wantAgent = agent;
      await backgroundTaskManager.startBackgroundRunning(this.ctx, req);
      this.lrtActive = true;
      this.log('后台长时任务已激活 (AV播放/录音)');
    } catch (err) {
      this.log('后台长时任务启动失败(不影响前台播放): ' + JSON.stringify(err));
    }
  }

  private async stopLongRunningTask(): Promise<void> {
    if (!this.lrtActive) {
      return;
    }
    this.lrtActive = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.ctx);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stop LRT failed: %{public}s', JSON.stringify(err));
    }
  }

  private async teardown(sendBye: boolean): Promise<void> {
    const wasStreaming: boolean = this.state === BridgeState.STREAMING;
    this.state = BridgeState.IDLE;
    this.onStateChanged(this.state);

    if (sendBye && wasStreaming) {
      try {
        this.control.sendJson(new ByeMsg());
      } catch (err) {
        // ignore
      }
    }
    this.stopPingLoop();
    await this.stopMic();
    await this.stopPlayer();
    this.jitter.reset();

    const udp = this.udp;
    this.udp = undefined;
    if (udp !== undefined) {
      try {
        await udp.close();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'udp close failed: %{public}s', JSON.stringify(err));
      }
    }
    this.control.close();
    await this.destroyAvSession();
    await this.stopLongRunningTask();
    this.log('已断开连接');
  }
}
