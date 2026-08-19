/*
 * StarAudioBridge wire protocol v1
 *
 * 控制通道: TCP, 默认端口 59301, 换行分隔的 JSON 消息。
 *   客户端 -> 服务端: {"t":"hello","v":1,"app":"StarAudioBridge"}
 *   服务端 -> 客户端: {"t":"welcome","v":1,"sr":48000,"ch":2,"codec":"pcm","frameMs":5,"udpPort":59302}
 *   客户端 -> 服务端: {"t":"start","pc2phone":true,"phone2pc":true}
 *   客户端 -> 服务端: {"t":"ping","id":1} / 服务端 -> 客户端: {"t":"pong","id":1}
 *   客户端 -> 服务端: {"t":"stop"} / {"t":"bye"}
 *
 * 媒体通道: UDP, 双向, 端口由 welcome 消息告知 (默认 59302)。
 *   包头 8 字节 (小端):
 *     offset 0: u16 magic = 0x5A41 ('ZA')
 *     offset 2: u8  version = 1
 *     offset 3: u8  flags   bit0 = END(流结束)  bit1 = FIRST(首帧)
 *     offset 4: u16 seq (回绕)
 *     offset 6: u16 payloadLen
 *     offset 8: payload = 裸 PCM S16LE (48kHz, PC->手机 立体声 / 手机->PC 单声道)
 */
export class Proto {
  static readonly MAGIC: number = 0x5A41;
  static readonly VERSION: number = 1;
  static readonly HEADER_SIZE: number = 8;

  static readonly FLAG_END: number = 0x01;
  static readonly FLAG_FIRST: number = 0x02;

  static readonly DEFAULT_CONTROL_PORT: number = 59301;
  static readonly DEFAULT_MEDIA_PORT: number = 59302;

  // 音频参数 (与 PC 端协商一致)
  static readonly SAMPLE_RATE: number = 48000;
  static readonly FRAME_MS: number = 5;          // 每帧 5ms
  static readonly FRAME_SAMPLES: number = 240;   // 48000 * 0.005
  static readonly BYTES_PER_SAMPLE: number = 2;  // S16LE
  // PC->手机: 双声道 每帧字节 = 240 * 2 * 2 = 960
  static readonly STEREO_FRAME_BYTES: number = Proto.FRAME_SAMPLES * 2 * Proto.BYTES_PER_SAMPLE;
  // 手机->PC: 单声道 每帧字节 = 240 * 2 = 480
  static readonly MONO_FRAME_BYTES: number = Proto.FRAME_SAMPLES * 1 * Proto.BYTES_PER_SAMPLE;

  static buildPacket(seq: number, payload: ArrayBuffer, flags: number): ArrayBuffer {
    const total: number = Proto.HEADER_SIZE + payload.byteLength;
    const buf = new ArrayBuffer(total);
    const dv = new DataView(buf);
    dv.setUint16(0, Proto.MAGIC, true);
    dv.setUint8(2, Proto.VERSION);
    dv.setUint8(3, flags);
    dv.setUint16(4, seq & 0xFFFF, true);
    dv.setUint16(6, payload.byteLength, true);
    new Uint8Array(buf).set(new Uint8Array(payload), Proto.HEADER_SIZE);
    return buf;
  }

  static parsePacket(buf: ArrayBuffer): ParsedPacket | null {
    if (buf.byteLength < Proto.HEADER_SIZE) {
      return null;
    }
    const dv = new DataView(buf);
    if (dv.getUint16(0, true) !== Proto.MAGIC) {
      return null;
    }
    if (dv.getUint8(2) !== Proto.VERSION) {
      return null;
    }
    const flags: number = dv.getUint8(3);
    const seq: number = dv.getUint16(4, true);
    const len: number = dv.getUint16(6, true);
    if (len > buf.byteLength - Proto.HEADER_SIZE) {
      return null;
    }
    const payload = buf.slice(Proto.HEADER_SIZE, Proto.HEADER_SIZE + len);
    return new ParsedPacket(seq, flags, payload);
  }
}

export class ParsedPacket {
  seq: number;
  flags: number;
  payload: ArrayBuffer;

  constructor(seq: number, flags: number, payload: ArrayBuffer) {
    this.seq = seq;
    this.flags = flags;
    this.payload = payload;
  }
}

// ---- 控制消息 (JSON) ----

export class HelloMsg {
  t: string = 'hello';
  v: number = 1;
  app: string = 'StarAudioBridge';
}

export class WelcomeMsg {
  t: string = 'welcome';
  v: number = 1;
  sr: number = 48000;
  ch: number = 2;
  codec: string = 'pcm';
  frameMs: number = 5;
  udpPort: number = Proto.DEFAULT_MEDIA_PORT;
}

export class StartMsg {
  t: string = 'start';
  pc2phone: boolean = true;
  phone2pc: boolean = false;
  micSr: number = 48000;
  micCh: number = 1;
}

export class PingMsg {
  t: string = 'ping';
  id: number = 0;
  ts: number = 0;
}

export class PongMsg {
  t: string = 'pong';
  id: number = 0;
  ts: number = 0;
}

export class ByeMsg {
  t: string = 'bye';
}
