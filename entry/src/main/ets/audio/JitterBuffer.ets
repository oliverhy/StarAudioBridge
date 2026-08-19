/*
 * 抖动缓冲: 按序号排序的音频帧队列, 用于吸收 UDP 网络抖动。
 * - 乱序帧按序号归位; 丢帧补静音(有界), 保持播放时序平滑。
 * - 统计: 收包数 / 丢帧数 / 迟到数 / 欠载数 / 抖动(到达间隔)。
 */
export class JitterBuffer {
  private frames: Uint8Array[] = [];
  private nextExpected: number = -1;
  private firstSeen: boolean = false;
  private readonly maxQueued: number;
  private readonly frameBytes: number;
  private lastFrame: Uint8Array = new Uint8Array(0);
  private curFrame: Uint8Array | null = null;
  private curOffset: number = 0;

  private receivedCount: number = 0;
  private lostCount: number = 0;
  private lateCount: number = 0;
  private underrunCount: number = 0;

  private lastArrivalMs: number = 0;
  private jitterSum: number = 0;
  private jitterSamples: number = 0;
  private jitterMaxMs: number = 0;

  constructor(frameBytes: number, maxQueued: number) {
    this.frameBytes = frameBytes;
    this.maxQueued = maxQueued;
  }

  get depth(): number {
    return this.frames.length;
  }

  get received(): number {
    return this.receivedCount;
  }

  get lost(): number {
    return this.lostCount;
  }

  get late(): number {
    return this.lateCount;
  }

  get underrun(): number {
    return this.underrunCount;
  }

  get avgJitterMs(): number {
    return this.jitterSamples > 0 ? this.jitterSum / this.jitterSamples : 0;
  }

  get maxJitterMs(): number {
    return this.jitterMaxMs;
  }

  reset(): void {
    this.frames = [];
    this.nextExpected = -1;
    this.firstSeen = false;
    this.curFrame = null;
    this.curOffset = 0;
    this.lastFrame = new Uint8Array(0);
    this.receivedCount = 0;
    this.lostCount = 0;
    this.lateCount = 0;
    this.underrunCount = 0;
    this.lastArrivalMs = 0;
    this.jitterSum = 0;
    this.jitterSamples = 0;
    this.jitterMaxMs = 0;
  }

  push(seq: number, payload: ArrayBuffer): void {
    const now: number = Date.now();
    if (this.lastArrivalMs !== 0) {
      const delta: number = now - this.lastArrivalMs;
      this.jitterSum += delta;
      this.jitterSamples++;
      if (delta > this.jitterMaxMs) {
        this.jitterMaxMs = delta;
      }
    }
    this.lastArrivalMs = now;
    this.receivedCount++;

    if (!this.firstSeen) {
      this.firstSeen = true;
      this.nextExpected = seq;
    }

    if (seq === this.nextExpected) {
      this.enqueue(payload);
      this.nextExpected = (this.nextExpected + 1) & 0xFFFF;
    } else if (seq > this.nextExpected) {
      // 丢帧: 补有界静音, 保持时序
      let gap: number = seq - this.nextExpected;
      if (gap > 8) {
        gap = 8;
      }
      for (let i = 0; i < gap; i++) {
        this.enqueueSilence();
        this.lostCount++;
        this.nextExpected = (this.nextExpected + 1) & 0xFFFF;
      }
      this.enqueue(payload);
      this.nextExpected = (seq + 1) & 0xFFFF;
    } else {
      // 迟到 / 重复
      this.lateCount++;
    }
  }

  /**
   * 把队列中的 PCM 作为连续字节流拷入 dst (支持跨帧消费, 不做帧对齐)。
   * 返回实际填充的字节数; 流耗尽时不足部分保持 dst 原值(由调用方填静音)。
   * 连续流读取可避免"缓冲尾部固定填静音"造成的周期性跳变/杂音。
   */
  read(dst: Uint8Array, dstBytes: number): number {
    let filled: number = 0;
    while (filled < dstBytes) {
      if (this.curFrame === null) {
        if (this.frames.length === 0) {
          break;
        }
        const f = this.frames.shift();
        if (f === undefined) {
          break;
        }
        this.curFrame = f;
        this.curOffset = 0;
      }
      const n: number = Math.min(dstBytes - filled, this.curFrame.length - this.curOffset);
      dst.set(this.curFrame.subarray(this.curOffset, this.curOffset + n), filled);
      filled += n;
      this.curOffset += n;
      if (this.curOffset >= this.curFrame.length) {
        this.curFrame = null;
      }
    }
    if (filled < dstBytes) {
      this.underrunCount++;
    }
    return filled;
  }

  private enqueue(payload: ArrayBuffer): void {
    const arr = new Uint8Array(payload);
    // 记录上一帧, 用于丢帧掩蔽 (重复播放而非静音)
    if (arr.length === this.frameBytes) {
      this.lastFrame = arr;
    }
    this.pushFrame(arr);
  }

  private enqueueSilence(): void {
    // 丢帧掩蔽: 重复上一帧。纯静音在音乐/语音上会产生咔哒声, 重复上一帧几乎无感。
    const frame: Uint8Array = this.lastFrame.length === this.frameBytes
      ? this.lastFrame
      : new Uint8Array(this.frameBytes);
    this.pushFrame(frame);
  }

  private pushFrame(frame: Uint8Array): void {
    if (this.frames.length >= this.maxQueued) {
      this.frames.shift();
      this.lostCount++; // 溢出丢弃也算作丢失
    }
    this.frames.push(frame);
  }
}
