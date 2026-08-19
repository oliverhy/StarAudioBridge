/*
 * 麦克风采集: 封装 AudioCapturer, 使用 readData 回调。
 * 采集到的 PCM (48kHz 单声道 S16LE) 逐块回调给上层, 由上层封包后经 UDP 发送到 PC。
 */
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'StarAudioBridge';

export class MicCapturer {
  private capturer: audio.AudioCapturer | undefined = undefined;
  private running: boolean = false;
  private readonly onPcm: (buf: ArrayBuffer) => void;

  constructor(onPcm: (buf: ArrayBuffer) => void) {
    this.onPcm = onPcm;
  }

  get state(): string {
    return this.running ? 'capturing' : 'stopped';
  }

  /** 启动采集 (需要 ohos.permission.MICROPHONE 已授权)。 */
  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    try {
      const options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          // 使用网络语音通话源，让系统启用通话场景的 AEC/降噪/自动增益链路。
          source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION,
          capturerFlags: 0
        }
      };
      this.capturer = await audio.createAudioCapturer(options);
      this.capturer.on('readData', (data: ArrayBuffer): void => {
        if (this.running) {
          this.onPcm(data);
        }
      });
      await this.capturer.start();
      this.running = true;
      hilog.info(DOMAIN, TAG, 'MicCapturer started (48kHz mono)');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'MicCapturer start failed: %{public}s', JSON.stringify(err));
      throw new Error('MicCapturer start failed: ' + JSON.stringify(err));
    }
  }

  /** 停止并释放采集器。 */
  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }
    this.running = false;
    try {
      const c = this.capturer;
      if (c !== undefined) {
        await c.stop();
        await c.release();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'MicCapturer stop failed: %{public}s', JSON.stringify(err));
    }
    this.capturer = undefined;
  }
}
