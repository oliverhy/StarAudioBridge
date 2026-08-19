// 回声消除 (AEC) v3.1:
//   延迟: 长窗口(2048)交叉相关, 宽搜每~0.5s重估 + 窄窗跟踪 (可靠锁定, 曾达 corr 0.88)
//   增益: 逐块最小二乘 g=<y,x>/<x,x> (瞬时、抗双讲: 系统声与参考不相关)
//   扣除: 从左右声道减去 增益×延迟对齐参考
// 注意: 本类与 Program.cs 同处全局命名空间 (顶层语句工程)。
sealed class EchoCanceller
{
    const int RingSize = 48000 * 4;          // 4s @48k 单声道参考环
    const int MaxDelay = 20000;              // 宽搜上限(约417ms)
    const int NarrowRadius = 800;            // 窄窗半径(±16.7ms), 跟踪漂移
    readonly float[] _ring = new float[RingSize];
    float[] _mono = new float[4096];         // 单声道 scratch
    long _refTotal;
    long _playedTotal;
    int _delaySamples = -1;
    double _gain = 1.0;
    double _lastCorr;
    bool _active;
    long _lastEstimate;

    public bool Active => _active && _playedTotal > 0;
    public int DelaySamples => _delaySamples;
    public double Gain => _gain;
    public double LastCorr => _lastCorr;

    public void SetActive(bool on) => _active = on;

    public void SetPlayed(long played) => _playedTotal = played;

    /// <summary>写入参考信号(手机麦克风播放的样本, 单声道)。</summary>
    public void AddReference(ReadOnlySpan<short> mono)
    {
        foreach (var s in mono)
        {
            _ring[_refTotal % RingSize] = s / 32768f;
            _refTotal++;
        }
    }

    float RefAt(long globalIdx)
    {
        if (globalIdx < 0) return 0f;
        return _ring[globalIdx % RingSize];
    }

    /// <summary>用一块环回采集(单声道)更新延迟估计; 内部节流 + 窄窗/宽搜。</summary>
    public void EstimateDelay(float[] mono, int len)
    {
        if (!_active || _refTotal < 2048 || _playedTotal < 2048 || len < 64) return;
        bool force = _delaySamples < 0;
        if (!force && _refTotal - _lastEstimate < 24000) return; // 每~0.5s
        _lastEstimate = _refTotal;

        int win = Math.Min(len, 2048);
        int searchLo = force ? 0 : Math.Max(0, _delaySamples - NarrowRadius);
        int searchHi = force ? MaxDelay : _delaySamples + NarrowRadius;

        int best = -1;
        double bestCorr = 0.4;
        long refEnd = _playedTotal - 1;
        for (int d = searchLo; d <= searchHi; d++)
        {
            double num = 0, e1 = 1e-9, e2 = 1e-9;
            long baseIdx = refEnd - d - win + 1;
            for (int i = 0; i < win; i += 2)
            {
                double x = RefAt(baseIdx + i);
                double y = mono[i];
                num += x * y;
                e1 += x * x;
                e2 += y * y;
            }
            if (e1 < 1e-6 || e2 < 1e-6) continue;
            double c = num / (Math.Sqrt(e1) * Math.Sqrt(e2));
            if (c > bestCorr) { bestCorr = c; best = d; }
        }
        if (best >= 0)
        {
            _delaySamples = best;
            _lastCorr = bestCorr;
        }
    }

    /// <summary>处理一块立体声 int16 环回采集(就地), 扣除回声。</summary>
    public void Process(Span<short> buf, int len)
    {
        if (!Active || len < 2) return;
        int frames = len / 2;
        if (frames <= 0 || _delaySamples < 0) return;

        if (_mono.Length < frames) _mono = new float[frames + 256];
        var mono = _mono;
        for (int f = 0; f < frames; f++)
            mono[f] = (buf[f * 2] + buf[f * 2 + 1]) * 0.5f / 32768f;

        // 逐块最小二乘增益
        long baseIdx = _playedTotal - _delaySamples - frames + 1;
        double sumX2 = 1e-9, sumXY = 0;
        for (int f = 0; f < frames; f++)
        {
            double x = RefAt(baseIdx + f);
            sumX2 += x * x;
            sumXY += mono[f] * x;
        }
        double g = sumXY / sumX2;
        if (g < 0) g = 0;
        if (g > 2) g = 2;
        _gain = g;

        for (int f = 0; f < frames; f++)
        {
            double echo = g * RefAt(baseIdx + f) * 32768.0;
            buf[f * 2] = (short)Math.Clamp(buf[f * 2] - echo, short.MinValue, short.MaxValue);
            buf[f * 2 + 1] = (short)Math.Clamp(buf[f * 2 + 1] - echo, short.MinValue, short.MaxValue);
        }
    }
}
