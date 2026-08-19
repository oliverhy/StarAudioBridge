/*
 * mDNS 自动发现: 在局域网内搜索 StarAudioBridge PC 服务端。
 * 服务类型: _star-audio-bridge._tcp (PC 端用 Makaretu.Dns 广播)
 */
import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'StarAudioBridge';
const SERVICE_TYPE: string = '_star-audio-bridge._tcp';
const DEFAULT_PORT: number = 59301;

export class DiscoveredHost {
  name: string;
  ip: string;
  port: number;

  constructor(name: string, ip: string, port: number) {
    this.name = name;
    this.ip = ip;
    this.port = port;
  }
}

export class MdnsDiscovery {
  private ctx: common.UIAbilityContext;
  private discovery: mdns.DiscoveryService | undefined = undefined;
  private resolving: boolean = false;

  onFound: (host: DiscoveredHost) => void = (host: DiscoveredHost): void => {
  };
  onLog: (msg: string) => void = (msg: string): void => {
  };

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  get active(): boolean {
    return this.discovery !== undefined;
  }

  start(): void {
    this.stop();
    try {
      const d = mdns.createDiscoveryService(this.ctx, SERVICE_TYPE);
      this.discovery = d;
      d.on('serviceFound', (info: mdns.LocalServiceInfo): void => {
        this.handleFound(info);
      });
      d.on('discoveryStart', (info: mdns.DiscoveryEventInfo): void => {
        this.onLog('mDNS 开始搜索电脑...');
      });
      d.startSearchingMDNS();
    } catch (err) {
      this.onLog('mDNS 启动失败: ' + JSON.stringify(err));
    }
  }

  stop(): void {
    const d = this.discovery;
    this.discovery = undefined;
    if (d !== undefined) {
      try {
        d.stopSearchingMDNS();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'mdns stop failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  private async handleFound(info: mdns.LocalServiceInfo): Promise<void> {
    if (this.resolving) {
      return;
    }
    this.resolving = true;
    try {
      const resolved = await mdns.resolveLocalService(this.ctx, info);
      const host = resolved.host;
      if (host !== undefined && host.address.length > 0) {
        const port: number = resolved.port !== undefined ? resolved.port : DEFAULT_PORT;
        const name: string = info.serviceName;
        this.onFound(new DiscoveredHost(name, host.address, port));
        this.onLog('发现电脑: ' + name + ' (' + host.address + ':' + port + ')');
      }
    } catch (err) {
      this.onLog('mDNS 解析失败: ' + JSON.stringify(err));
    } finally {
      this.resolving = false;
    }
  }
}
