/*
 * 控制通道: TCP, 换行分隔的 JSON 消息。
 * 处理 TCP 流的分包/粘包: 内部按 '\n' 切分后逐条回调。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'StarAudioBridge';

export class ControlChannel {
  private tcp: socket.TCPSocket | undefined = undefined;
  private recvBuffer: string = '';
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private readonly onLine: (line: string) => void;
  private readonly onClosed: () => void;
  private readonly onError: (msg: string) => void;

  constructor(onLine: (line: string) => void, onClosed: () => void, onError: (msg: string) => void) {
    this.onLine = onLine;
    this.onClosed = onClosed;
    this.onError = onError;
  }

  get connected(): boolean {
    return this.tcp !== undefined;
  }

  /** 建立 TCP 连接 (启用 TCPNoDelay 降低控制延迟)。 */
  async connect(host: string, port: number): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.recvBuffer = '';

    tcp.on('message', (info: socket.SocketMessageInfo): void => {
      this.onData(info);
    });
    tcp.on('close', (): void => {
      this.recvBuffer = '';
      this.tcp = undefined;
      this.onClosed();
    });
    tcp.on('error', (err: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'Control TCP error: %{public}s', JSON.stringify(err));
      this.recvBuffer = '';
      this.tcp = undefined;
      this.onError(JSON.stringify(err));
    });

    const options: socket.TCPConnectOptions = {
      address: { address: host, port: port },
      timeout: 5000
    };
    try {
      await tcp.connect(options);
    } catch (err) {
      this.tcp = undefined;
      throw new Error('TCP connect failed: ' + JSON.stringify(err));
    }
  }

  /** 发送一条 JSON 控制消息 (自动补换行)。 */
  sendJson(obj: object): void {
    const tcp = this.tcp;
    if (tcp === undefined) {
      return;
    }
    const line: string = JSON.stringify(obj) + '\n';
    try {
      tcp.send({ data: line });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Control send failed: %{public}s', JSON.stringify(err));
    }
  }

  close(): void {
    const tcp = this.tcp;
    this.tcp = undefined;
    if (tcp !== undefined) {
      try {
        tcp.close();
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'Control close failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  private onData(info: socket.SocketMessageInfo): void {
    try {
      const text: string = this.decoder.decodeToString(new Uint8Array(info.message));
      this.recvBuffer += text;
      let idx: number = this.recvBuffer.indexOf('\n');
      while (idx >= 0) {
        const line: string = this.recvBuffer.substring(0, idx).trim();
        this.recvBuffer = this.recvBuffer.substring(idx + 1);
        if (line.length > 0) {
          this.onLine(line);
        }
        idx = this.recvBuffer.indexOf('\n');
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Control decode failed: %{public}s', JSON.stringify(err));
    }
  }
}
