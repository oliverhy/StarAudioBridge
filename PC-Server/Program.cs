// StarAudioBridge PC Server (GUI)
// - 控制通道: TCP 59301, 换行分隔 JSON (hello/welcome/start/ping/pong/bye)
// - 媒体通道: UDP 59302 双向
//   PC -> 手机: WASAPI 环回采集 48kHz 立体声 S16LE, 5ms/帧 (960B) 封包发送
//   手机 -> PC: 收到 PCM 包写入用户指定的 WASAPI 输出设备 (推荐虚拟音频线)
// - 防回声: 默认关闭本地麦克风监听, 避免麦克风输出再次进入系统回环
// - mDNS: 广播 _star-audio-bridge._tcp 供手机自动发现
// 与手机端协议一致, 见 entry/src/main/ets/model/Protocol.ets
using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Makaretu.Dns;
using NAudio.CoreAudioApi;
using NAudio.Wave;

// ---------------------------------------------------------------------------

static class Program
{
    const int DefaultCtrlPort = 59301;
    const int DefaultMediaPort = 59302;

    [STAThread]
    static void Main(string[] args)
    {
        int ctrlPort = DefaultCtrlPort, mediaPort = DefaultMediaPort;
        string? dumpPath = null;
        bool consoleMode = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--console") consoleMode = true;
            else if (args[i] == "--ctrl-port" && i + 1 < args.Length) ctrlPort = int.Parse(args[++i]);
            else if (args[i] == "--media-port" && i + 1 < args.Length) mediaPort = int.Parse(args[++i]);
            else if (args[i] == "--dump" && i + 1 < args.Length) dumpPath = args[++i];
            else if (args[i] == "--help")
            {
                ServerLog.Log("StarAudioBridge PC Server");
                ServerLog.Log("  --console          无 GUI 运行 (日志写文件)");
                ServerLog.Log("  --ctrl-port <port>  控制通道端口 (默认 59301)");
                ServerLog.Log("  --media-port <port> 媒体通道端口 (默认 59302)");
                ServerLog.Log("  --dump <file>       原始环回采集落盘 (诊断)");
                return;
            }
        }

        var server = new AudioBridgeServer(ctrlPort, mediaPort, dumpPath);
        server.Start();
        StartMdnsAdvertising(ctrlPort);

        if (consoleMode)
        {
            ServerLog.Log("控制台模式: 运行中, 日志见 star-audio-bridge.log");
            Thread.Sleep(Timeout.Infinite);
        }
        else
        {
            ApplicationConfiguration.Initialize();
            Application.Run(new MainForm(server, ctrlPort, mediaPort));
        }

        server.Stop();
        ServerLog.Log("server stopped");
    }

    /// <summary>通过 mDNS 广播本服务, 手机端可自动发现 (服务类型 _star-audio-bridge._tcp)。</summary>
    static void StartMdnsAdvertising(int ctrlPort)
    {
        try
        {
            var addrs = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up
                            && n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel))
                .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                .Select(a => a.Address)
                .Where(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
                .ToArray();

            var mdns = new MulticastService();
            var sd = new ServiceDiscovery(mdns);
            var profile = new ServiceProfile(
                new DomainName("StarAudioBridge on " + Environment.MachineName),
                new DomainName("_star-audio-bridge._tcp"),
                (ushort)ctrlPort,
                addrs);
            profile.AddProperty("app", "StarAudioBridge");
            profile.AddProperty("name", Environment.MachineName);

            mdns.NetworkInterfaceDiscovered += (s, e) =>
            {
                try { sd.Announce(profile); } catch { /* ignore */ }
            };
            sd.Advertise(profile);
            mdns.Start();

            ServerLog.Log($"mDNS 广告已启动: _star-audio-bridge._tcp  (IP: {string.Join(",", addrs.Select(a => a.ToString()))})");
        }
        catch (Exception ex)
        {
            ServerLog.Log($"mDNS 广告启动失败(不影响手动连接): {ex.Message}");
        }
    }
}

// ---------------------------------------------------------------------------

/// <summary>日志: 写文件 + (可附加控制台/GUI 订阅)。</summary>
static class ServerLog
{
    private static readonly object _lock = new();
    private static readonly StreamWriter? _file;
    public static event Action<string>? OnLine;

    static ServerLog()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "star-audio-bridge.log");
            _file = new StreamWriter(path, append: true, encoding: new UTF8Encoding(true)) { AutoFlush = true };
        }
        catch { _file = null; }
    }

    public static void Log(string msg)
    {
        var line = $"[{DateTime.Now:HH:mm:ss.fff}] {msg}";
        try { lock (_lock) { _file?.WriteLine(line); } } catch { /* ignore */ }
        try { Console.WriteLine(line); } catch { /* ignore */ }
        OnLine?.Invoke(line);
    }
}

// ---------------------------------------------------------------------------

sealed class AudioBridgeServer
{
    // 与手机端 Protocol.ets 保持一致的线协议常量
    private static class Proto
    {
        public const ushort Magic = 0x5A41;   // 'ZA'
        public const byte Version = 1;
        public const byte FlagEnd = 0x01;
        public const byte FlagFirst = 0x02;
        public const int FrameBytes = 960;    // 48kHz * 2ch * 2B * 5ms
    }

    private readonly int _ctrlPort;
    private readonly int _mediaPort;
    private readonly string? _dumpPath;
    private UdpClient? _udp;
    private TcpListener? _listener;
    private FileStream? _dumpStream;
    private long _dumpBytes;
    private volatile IPEndPoint? _phoneEndpoint;  // 手机 UDP 端点 (由通告包/媒体包学习)
    private volatile bool _pc2Phone;
    private volatile bool _phone2Pc;
    private ushort _outSeq;
    private long _sentFrames;
    private long _recvBytes;
    private DateTime _lastStatLog = DateTime.MinValue;
    private WasapiLoopbackCapture? _capture;
    private IWavePlayer? _out;
    private BufferedWaveProvider? _outBuf;
    private MMDevice? _micOutputDevice;
    private string? _micOutputDeviceId;
    private string _micOutputDeviceName = "关闭本地监听";
    private readonly object _outLock = new();
    private volatile bool _running;
    private byte[] _carry = Array.Empty<byte>();   // 帧切分余数结转, 避免丢尾部

    public AudioBridgeServer(int ctrlPort, int mediaPort, string? dumpPath = null)
    {
        _ctrlPort = ctrlPort;
        _mediaPort = mediaPort;
        _dumpPath = dumpPath;
    }

    public bool Running => _running;

    public void Start()
    {
        _running = true;
        _udp = new UdpClient(new IPEndPoint(IPAddress.Any, _mediaPort));
        _listener = new TcpListener(IPAddress.Any, _ctrlPort);
        _listener.Start();

        ServerLog.Log($"StarAudioBridge server: ctrl=tcp/{_ctrlPort} media=udp/{_mediaPort}");
        ServerLog.Log("等待手机连接 (手机 App 自动发现或输入 IP) ...");

        _ = Task.Run(ReceiveLoop);
        _ = Task.Run(AcceptLoop);
    }

    public void Stop()
    {
        _running = false;
        _pc2Phone = false;
        _phone2Pc = false;
        try { _listener?.Stop(); } catch { /* ignore */ }
        try { _udp?.Close(); } catch { /* ignore */ }
        StopStreams();
    }

    public ServerStats GetStats() => new ServerStats
    {
        Running = _running,
        SentFrames = Interlocked.Read(ref _sentFrames),
        RecvBytes = Interlocked.Read(ref _recvBytes),
        PhoneEndpoint = _phoneEndpoint?.ToString() ?? "未连接",
        Pc2Phone = _pc2Phone,
        Phone2Pc = _phone2Pc,
        MicOutputName = _micOutputDeviceName,
        MicOutputActive = _out != null
    };

    /// <summary>枚举手机麦克风可输出到的 WASAPI 渲染设备。</summary>
    public IReadOnlyList<AudioOutputDeviceInfo> GetAudioOutputDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        string? defaultId = null;
        try
        {
            defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID;
        }
        catch { /* 当前可能没有默认输出设备 */ }

        var result = new List<AudioOutputDeviceInfo>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            try
            {
                result.Add(new AudioOutputDeviceInfo(
                    device.ID,
                    device.FriendlyName,
                    device.ID == defaultId,
                    IsVirtualAudioDevice(device.FriendlyName)));
            }
            finally
            {
                device.Dispose();
            }
        }
        return result
            .OrderByDescending(device => device.IsVirtual)
            .ThenBy(device => device.Name)
            .ToArray();
    }

    /// <summary>
    /// 设置手机麦克风输出。null 表示不在电脑扬声器监听；选择虚拟音频线后，
    /// 通话/录音软件可把对应的虚拟录音端点选作麦克风。
    /// </summary>
    public void SetMicOutputDevice(string? deviceId, string displayName)
    {
        bool restart = _phone2Pc;
        StopPlayback();
        lock (_outLock)
        {
            _micOutputDeviceId = string.IsNullOrWhiteSpace(deviceId) ? null : deviceId;
            _micOutputDeviceName = string.IsNullOrWhiteSpace(deviceId) ? "关闭本地监听" : displayName;
        }

        ServerLog.Log(_micOutputDeviceId == null
            ? "手机麦克风本地监听已关闭 (防回声)"
            : $"手机麦克风输出设备: {_micOutputDeviceName}");
        if (restart) StartPlayback();
    }

    private static bool IsVirtualAudioDevice(string name)
    {
        string value = name.ToLowerInvariant();
        return value.Contains("vb-audio") || value.Contains("cable input")
            || value.Contains("voicemeeter") || value.Contains("virtual") || value.Contains("虚拟");
    }

    private async Task AcceptLoop()
    {
        while (_running)
        {
            TcpClient client;
            try { client = await _listener!.AcceptTcpClientAsync(); }
            catch { break; }
            _ = Task.Run(() => HandleControl(client));
        }
    }

    private async Task ReceiveLoop()
    {
        var udp = _udp;
        var buffer = new byte[4096];
        while (_running && udp != null)
        {
            UdpReceiveResult r;
            try { r = await udp.ReceiveAsync(); }
            catch { break; }
            _phoneEndpoint = r.RemoteEndPoint; // 记住手机端点(通告/媒体包均可)
            HandleMediaPacket(r.Buffer, r.Buffer.Length);
        }
    }

    private void HandleMediaPacket(byte[] buf, int len)
    {
        if (len < 8) return;
        if (BinaryPrimitives.ReadUInt16LittleEndian(buf) != Proto.Magic) return;
        byte flags = buf[3];
        ushort seq = BinaryPrimitives.ReadUInt16LittleEndian(buf.AsSpan(4));
        ushort payloadLen = BinaryPrimitives.ReadUInt16LittleEndian(buf.AsSpan(6));
        if (payloadLen > len - 8) return;

        if ((flags & Proto.FlagEnd) != 0) { StopPlayback(); return; }
        if (payloadLen == 0) return; // 通告包
        Interlocked.Add(ref _recvBytes, payloadLen);

        // 手机 -> PC: 仅写入用户明确选择的输出设备。
        // 默认不播放到本机扬声器，避免该信号再次被 WASAPI 回环采集。
        if (!_phone2Pc) return;
        lock (_outLock)
        {
            if (_outBuf == null) return;
            var data = new byte[payloadLen];
            Array.Copy(buf, 8, data, 0, payloadLen);
            _outBuf.AddSamples(data, 0, data.Length);
            // 缓冲过大则丢弃最旧数据 (防堆积延迟)
            if (_outBuf.BufferedDuration > TimeSpan.FromMilliseconds(300))
                _outBuf.ClearBuffer();
        }
    }

    // ---------- 控制通道 ----------

    private async Task HandleControl(TcpClient client)
    {
        var ep = client.Client.RemoteEndPoint;
        ServerLog.Log($"控制连接: {ep}");
        try
        {
            using var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.UTF8);
            using var writer = new StreamWriter(stream, Encoding.UTF8) { NewLine = "\n", AutoFlush = true };

            string? line;
            while (_running && (line = await reader.ReadLineAsync()) != null)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                HandleControlLine(line, writer);
                if (line.Contains("\"bye\"")) break;
            }
        }
        catch (Exception ex)
        {
            ServerLog.Log($"控制连接异常: {ex.Message}");
        }
        finally
        {
            _pc2Phone = false;
            _phone2Pc = false;
            StopStreams();
            ServerLog.Log($"控制连接断开: {ep}");
        }
    }

    private void HandleControlLine(string line, StreamWriter writer)
    {
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            var t = root.GetProperty("t").GetString();

            switch (t)
            {
                case "hello":
                    writer.WriteLine(
                        $$"""{"t":"welcome","v":1,"sr":48000,"ch":2,"codec":"pcm","frameMs":5,"udpPort":{{_mediaPort}}}""");
                    ServerLog.Log("已发送 welcome");
                    break;

                case "start":
                    _pc2Phone = root.TryGetProperty("pc2phone", out var p2p) && p2p.GetBoolean();
                    _phone2Pc = root.TryGetProperty("phone2pc", out var m2p) && m2p.GetBoolean();
                    if (_pc2Phone) StartCapture(); else StopCapture();
                    if (_phone2Pc) StartPlayback(); else StopPlayback();
                    ServerLog.Log($"start: pc2phone={_pc2Phone} phone2pc={_phone2Pc}");
                    break;

                case "ping":
                    var id = root.GetProperty("id").GetInt32();
                    writer.WriteLine($$"""{"t":"pong","id":{{id}}}""");
                    break;

                case "bye":
                    ServerLog.Log("收到 bye");
                    break;

                default:
                    ServerLog.Log($"未知消息: {line}");
                    break;
            }
        }
        catch (Exception ex)
        {
            ServerLog.Log($"控制消息解析失败: {ex.Message} | {line}");
        }
    }

    // ---------- PC 音频采集 (WASAPI 环回) ----------

    private void StartCapture()
    {
        if (_capture != null) return;
        try
        {
            // 探测设备真实混音格式 (WASAPI loopback 数据可能按此格式返回, 而非我们设置的格式)
            try
            {
                var devEnum = new NAudio.CoreAudioApi.MMDeviceEnumerator();
                var device = devEnum.GetDefaultAudioEndpoint(NAudio.CoreAudioApi.DataFlow.Render, NAudio.CoreAudioApi.Role.Multimedia);
                var mix = device.AudioClient.MixFormat;
                ServerLog.Log($"默认播放设备: {device.FriendlyName} | 混音格式: {mix.Encoding} {mix.SampleRate}Hz {mix.Channels}ch bits={mix.BitsPerSample}");
            }
            catch (Exception ex)
            {
                ServerLog.Log($"混音格式探测失败: {ex.Message}");
            }

            if (_dumpPath != null)
            {
                _dumpStream = new FileStream(_dumpPath, FileMode.Create, FileAccess.Write);
                _dumpBytes = 0;
                ServerLog.Log($"原始采集数据将写入: {_dumpPath}");
            }

            var fmt = new WaveFormat(48000, 16, 2);
            _capture = new WasapiLoopbackCapture();
            _capture.WaveFormat = fmt;
            _capture.DataAvailable += OnCaptureData;
            _capture.RecordingStopped += (_, _) => { };
            _capture.StartRecording();
            ServerLog.Log($"WASAPI 环回采集已启动, 请求格式 {fmt.SampleRate}/{fmt.Channels}ch, NAudio报告格式 {_capture.WaveFormat.SampleRate}/{_capture.WaveFormat.Channels}ch");
        }
        catch (Exception ex)
        {
            ServerLog.Log($"采集启动失败: {ex.Message} (可能需要先在系统设置中允许录音访问)");
        }
    }

    private void StopCapture()
    {
        var c = _capture;
        _capture = null;
        if (c != null)
        {
            try { c.StopRecording(); c.Dispose(); } catch { /* ignore */ }
            ServerLog.Log("已停止采集");
        }
        var d = _dumpStream;
        _dumpStream = null;
        if (d != null)
        {
            try { d.Flush(); d.Close(); } catch { /* ignore */ }
            ServerLog.Log($"原始数据落盘完成: {_dumpBytes} 字节");
        }
    }

    private void OnCaptureData(object? sender, WaveInEventArgs e)
    {
        // 诊断: 原始数据落盘
        var dump = _dumpStream;
        if (dump != null)
        {
            try
            {
                dump.Write(e.Buffer, 0, e.BytesRecorded);
                _dumpBytes += e.BytesRecorded;
            }
            catch { /* ignore */ }
        }

        var endpoint = _phoneEndpoint;
        if (endpoint == null || !_pc2Phone) return; // 还不知道手机端点, 丢弃

        // 余数结转: 上次不足一帧的尾部和本次拼接, 保证不丢数据
        int carryLen = _carry.Length;
        var data = new byte[carryLen + e.BytesRecorded];
        if (carryLen > 0) Array.Copy(_carry, data, carryLen);
        Array.Copy(e.Buffer, 0, data, carryLen, e.BytesRecorded);

        int offset = 0;
        while (offset + Proto.FrameBytes <= data.Length)
        {
            var pkt = BuildPacket(_outSeq++, 0, data.AsSpan(offset, Proto.FrameBytes));
            try
            {
                _udp?.Send(pkt, pkt.Length, endpoint);
                Interlocked.Increment(ref _sentFrames);
            }
            catch { /* 网络瞬时繁忙 */ }
            offset += Proto.FrameBytes;
        }

        _carry = offset < data.Length ? data[offset..data.Length] : Array.Empty<byte>();

        // 每 5 秒输出一次统计
        var now = DateTime.Now;
        if (now - _lastStatLog > TimeSpan.FromSeconds(5))
        {
            _lastStatLog = now;
            ServerLog.Log($"统计: 已发送帧={Interlocked.Read(ref _sentFrames)} 已收手机字节={Interlocked.Read(ref _recvBytes)} 落盘={_dumpBytes} 手机端点={endpoint} 麦克风输出={_micOutputDeviceName}");
        }
    }

    // ---------- 手机麦克风播放 ----------

    private void StartPlayback()
    {
        lock (_outLock)
        {
            if (_out != null) return;
            if (_micOutputDeviceId == null)
            {
                ServerLog.Log("手机麦克风数据已接收，但本地监听关闭；如需在电脑软件中使用，请选择虚拟音频线输出设备");
                return;
            }
            try
            {
                _outBuf = new BufferedWaveProvider(new WaveFormat(48000, 16, 1))
                {
                    BufferDuration = TimeSpan.FromMilliseconds(400),
                    DiscardOnBufferOverflow = true,
                    ReadFully = true
                };
                using var enumerator = new MMDeviceEnumerator();
                _micOutputDevice = enumerator.GetDevice(_micOutputDeviceId);
                _out = new WasapiOut(_micOutputDevice, AudioClientShareMode.Shared, true, 40);
                _out.Init(_outBuf);
                _out.Play();
                ServerLog.Log($"手机麦克风已输出到: {_micOutputDeviceName} (48kHz 单声道)");
            }
            catch (Exception ex)
            {
                ServerLog.Log($"手机麦克风输出启动失败: {ex.Message}");
                _outBuf = null;
                _out = null;
                try { _micOutputDevice?.Dispose(); } catch { /* ignore */ }
                _micOutputDevice = null;
            }
        }
    }

    private void StopPlayback()
    {
        lock (_outLock)
        {
            var o = _out;
            var device = _micOutputDevice;
            _out = null;
            _outBuf = null;
            _micOutputDevice = null;
            if (o != null)
            {
                try { o.Stop(); o.Dispose(); } catch { /* ignore */ }
                ServerLog.Log("已停止手机麦克风输出");
            }
            try { device?.Dispose(); } catch { /* ignore */ }
        }
    }

    private void StopStreams()
    {
        StopCapture();
        StopPlayback();
    }

    // ---------- 工具 ----------

    private static byte[] BuildPacket(ushort seq, byte flags, ReadOnlySpan<byte> payload)
    {
        var pkt = new byte[8 + payload.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(pkt, Proto.Magic);
        pkt[2] = Proto.Version;
        pkt[3] = flags;
        BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(4), seq);
        BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(6), (ushort)payload.Length);
        payload.CopyTo(pkt.AsSpan(8));
        return pkt;
    }
}

// ---------------------------------------------------------------------------

public record ServerStats
{
    public bool Running;
    public long SentFrames;
    public long RecvBytes;
    public string PhoneEndpoint = "";
    public bool Pc2Phone;
    public bool Phone2Pc;
    public string MicOutputName = "";
    public bool MicOutputActive;
}

public record AudioOutputDeviceInfo(string Id, string Name, bool IsDefault, bool IsVirtual)
{
    public string DisplayName => IsVirtual
        ? $"虚拟音频设备（推荐）— {Name}"
        : IsDefault ? $"默认扬声器（可能产生回声）— {Name}" : $"物理输出（可能产生回声）— {Name}";
}
