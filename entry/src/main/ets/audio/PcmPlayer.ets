/*
 * PCM 播放器: 封装 AudioRenderer, 使用 writeData 低延迟回调。
 * 系统在需要数据时回调, 我们从抖动缓冲取帧填充; 缓冲不足填静音保持时序。
 */
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JitterBuffer } from '../audio/JitterBuffer';

const DOMAIN: number = 0x0000;
const TAG: string = 'StarAudioBridge';

export class PcmPlayer {
  private renderer: audio.AudioRenderer | undefined = undefined;
  private jitter: JitterBuffer;
  private readonly voiceCommunication: boolean;
  private running: boolean = false;

  constructor(jitter: JitterBuffer, voiceCommunication: boolean) {
    this.jitter = jitter;
    this.voiceCommunication = voiceCommunication;
  }

  get state(): string {
    return this.running ? 'playing' : 'stopped';
  }

  /** 启动播放 (内部创建渲染器并 start)。采样率/声道由 streamInfo 固定。 */
  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    try {
      const options: audio.AudioRendererOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
          channels: audio.AudioChannel.CHANNEL_2,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        rendererInfo: {
          // 双向传输时必须进入系统通话链路，才能与 VOICE_COMMUNICATION
          // 麦克风共享系统 AEC/降噪处理；单向播放仍保留音乐模式音质。
          usage: this.voiceCommunication
            ? audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION
            : audio.StreamUsage.STREAM_USAGE_MUSIC,
          rendererFlags: 0
        }
      };
      this.renderer = await audio.createAudioRenderer(options);
      if (this.voiceCommunication) {
        try {
          // 双向模式默认走听筒，减少扬声器声音直接漏入手机麦克风。
          // 外接有线/蓝牙耳机时系统会优先保留外接设备路由。
          await this.renderer.setDefaultOutputDevice(audio.DeviceType.EARPIECE);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'Switch to earpiece failed: %{public}s', JSON.stringify(err));
        }
      }
      this.renderer.on('writeData', (data: ArrayBuffer): audio.AudioDataCallbackResult => {
        return this.onWriteData(data);
      });
      await this.renderer.start();
      this.running = true;
      hilog.info(DOMAIN, TAG, 'PcmPlayer started (renderer, low-latency writeData)');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'PcmPlayer start failed: %{public}s', JSON.stringify(err));
      throw new Error('PcmPlayer start failed: ' + JSON.stringify(err));
    }
  }

  /** 停止并释放渲染器。 */
  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }
    this.running = false;
    try {
      const r = this.renderer;
      if (r !== undefined) {
        await r.stop();
        await r.release();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'PcmPlayer stop failed: %{public}s', JSON.stringify(err));
    }
    this.renderer = undefined;
  }

  private onWriteData(data: ArrayBuffer): audio.AudioDataCallbackResult {
    if (!this.running) {
      return audio.AudioDataCallbackResult.INVALID;
    }
    const dst = new Uint8Array(data);
    const n: number = this.jitter.read(dst, dst.byteLength);
    // 不足部分填静音, 保持播放时序平滑
    for (let i = n; i < dst.byteLength; i++) {
      dst[i] = 0;
    }
    return audio.AudioDataCallbackResult.VALID;
  }
}
