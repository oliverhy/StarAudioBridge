// StarAudioBridge PC Server — 图形界面
// 状态 / 统计 / 日志 / 启停 / 托盘最小化
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

sealed class MainForm : Form
{
    private readonly AudioBridgeServer _server;
    private readonly int _ctrlPort;
    private readonly int _mediaPort;
    private readonly Label _statusLabel = new();
    private readonly Label _addrLabel = new();
    private readonly Label _statsLabel = new();
    private readonly ComboBox _micOutputCombo = new();
    private readonly Label _micOutputHint = new();
    private readonly ListBox _logBox = new();
    private readonly Button _btnToggle = new();
    private readonly NotifyIcon _tray;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly int _maxLog = 500;
    private bool _allowClose;
    private bool _loadingAudioDevices;

    public MainForm(AudioBridgeServer server, int ctrlPort, int mediaPort)
    {
        _server = server;
        _ctrlPort = ctrlPort;
        _mediaPort = mediaPort;

        Text = "StarAudioBridge 电脑音频桥";
        Width = 640;
        Height = 580;
        MinimumSize = new Size(520, 420);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 9f);

        BuildUi();
        LoadAudioOutputDevices();

        _timer = new System.Windows.Forms.Timer { Interval = 500 };
        _timer.Tick += (_, _) => RefreshStats();
        _timer.Start();

        _tray = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "StarAudioBridge 电脑音频桥",
            Visible = true
        };
        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("显示窗口", null, (_, _) => ShowWindow());
        trayMenu.Items.Add("退出", null, (_, _) => ExitApp());
        _tray.ContextMenuStrip = trayMenu;
        _tray.DoubleClick += (_, _) => ShowWindow();

        ServerLog.OnLine += OnLogLine;
        FormClosing += (_, e) =>
        {
            if (!_allowClose) { e.Cancel = true; Hide(); }
        };

        RefreshStats();
    }

    private void BuildUi()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 1,
            RowCount = 6
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));   // 标题
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));   // 状态+地址
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 72));   // 手机麦克风输出
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 86));   // 统计
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));   // 日志
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));   // 按钮

        var title = new Label
        {
            Text = "StarAudioBridge — 电脑音频桥",
            Font = new Font(Font.FontFamily, 13f, FontStyle.Bold),
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        };
        root.Controls.Add(title);

        _statusLabel.Dock = DockStyle.Fill;
        _statusLabel.AutoSize = false;
        _statusLabel.Font = new Font(Font.FontFamily, 10f, FontStyle.Bold);
        _addrLabel.Dock = DockStyle.Fill;
        _addrLabel.AutoSize = false;
        _addrLabel.ForeColor = Color.DimGray;
        var addrPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false
        };
        addrPanel.Controls.Add(_statusLabel);
        addrPanel.Controls.Add(_addrLabel);
        root.Controls.Add(addrPanel);

        var outputPanel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Padding = new Padding(0, 4, 0, 0)
        };
        outputPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        outputPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        var outputRow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false
        };
        outputRow.Controls.Add(new Label
        {
            Text = "手机麦克风输出：",
            AutoSize = true,
            Padding = new Padding(0, 6, 0, 0)
        });
        _micOutputCombo.Width = 390;
        _micOutputCombo.DropDownWidth = 540;
        _micOutputCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        _micOutputCombo.SelectedIndexChanged += (_, _) => ApplySelectedAudioDevice();
        outputRow.Controls.Add(_micOutputCombo);
        var refreshDevices = new Button { Text = "刷新", Width = 58, Height = 27 };
        refreshDevices.Click += (_, _) => LoadAudioOutputDevices();
        outputRow.Controls.Add(refreshDevices);
        outputPanel.Controls.Add(outputRow);
        _micOutputHint.Dock = DockStyle.Fill;
        _micOutputHint.AutoSize = false;
        _micOutputHint.ForeColor = Color.DarkGreen;
        outputPanel.Controls.Add(_micOutputHint);
        root.Controls.Add(outputPanel);

        _statsLabel.Dock = DockStyle.Fill;
        _statsLabel.AutoSize = false;
        root.Controls.Add(_statsLabel);

        _logBox.Dock = DockStyle.Fill;
        _logBox.HorizontalScrollbar = true;
        _logBox.Font = new Font("Consolas", 9f);
        root.Controls.Add(_logBox);

        _btnToggle.Text = "停止服务";
        _btnToggle.Width = 110;
        _btnToggle.Click += (_, _) => ToggleServer();
        var btnHide = new Button { Text = "隐藏到托盘", Width = 110 };
        btnHide.Click += (_, _) => Hide();
        var btnExit = new Button { Text = "退出", Width = 110 };
        btnExit.Click += (_, _) => ExitApp();
        var btnPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false
        };
        btnPanel.Controls.Add(_btnToggle);
        btnPanel.Controls.Add(btnHide);
        btnPanel.Controls.Add(btnExit);
        root.Controls.Add(btnPanel);

        Controls.Add(root);
    }

    private void ShowWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    private void ExitApp()
    {
        _allowClose = true;
        _tray.Visible = false;
        Application.Exit();
    }

    private void ToggleServer()
    {
        if (_server.Running)
        {
            _server.Stop();
            _btnToggle.Text = "启动服务";
            ServerLog.Log("服务已停止 (GUI)");
        }
        else
        {
            _server.Start();
            _btnToggle.Text = "停止服务";
        }
        RefreshStats();
    }

    private void LoadAudioOutputDevices()
    {
        _loadingAudioDevices = true;
        try
        {
            var choices = new List<MicOutputChoice>
            {
                new(null, "关闭本地监听（推荐，避免回声）", false)
            };
            choices.AddRange(_server.GetAudioOutputDevices()
                .Select(device => new MicOutputChoice(device.Id, device.DisplayName, device.IsVirtual)));

            _micOutputCombo.DataSource = choices;
            _micOutputCombo.DisplayMember = nameof(MicOutputChoice.DisplayName);
            int virtualIndex = choices.FindIndex(choice => choice.IsVirtual);
            _micOutputCombo.SelectedIndex = virtualIndex >= 0 ? virtualIndex : 0;
        }
        catch (Exception ex)
        {
            ServerLog.Log($"枚举音频输出设备失败: {ex.Message}");
            _micOutputCombo.DataSource = new[] { new MicOutputChoice(null, "关闭本地监听（设备枚举失败）", false) };
            _micOutputCombo.DisplayMember = nameof(MicOutputChoice.DisplayName);
            _micOutputCombo.SelectedIndex = 0;
        }
        finally
        {
            _loadingAudioDevices = false;
        }
        ApplySelectedAudioDevice();
    }

    private void ApplySelectedAudioDevice()
    {
        if (_loadingAudioDevices || _micOutputCombo.SelectedItem is not MicOutputChoice choice) return;
        _server.SetMicOutputDevice(choice.Id, choice.DisplayName);
        if (choice.Id == null)
        {
            _micOutputHint.Text = "已阻断电脑扬声器回放。要作为电脑麦克风使用，请安装并选择虚拟音频线。";
            _micOutputHint.ForeColor = Color.DarkGreen;
        }
        else if (choice.IsVirtual)
        {
            _micOutputHint.Text = "防回声路由已启用：请在通话/录音软件里选择该虚拟设备对应的录音端点。";
            _micOutputHint.ForeColor = Color.DarkGreen;
        }
        else
        {
            _micOutputHint.Text = "警告：物理扬声器会产生延迟监听和回环；建议改选虚拟音频线或使用耳机。";
            _micOutputHint.ForeColor = Color.DarkOrange;
        }
        RefreshStats();
    }

    private void OnLogLine(string line)
    {
        if (IsHandleCreated)
            BeginInvoke(new Action(() => AppendLog(line)));
        else
            AppendLog(line);
    }

    private void AppendLog(string line)
    {
        _logBox.BeginUpdate();
        _logBox.Items.Add(line);
        if (_logBox.Items.Count > _maxLog) _logBox.Items.RemoveAt(0);
        _logBox.TopIndex = _logBox.Items.Count - 1;
        _logBox.EndUpdate();
    }

    private void RefreshStats()
    {
        var s = _server.GetStats();
        _statusLabel.Text = (s.Running ? "● 运行中" : "○ 已停止")
            + (s.PhoneEndpoint != "未连接" ? $"    手机已连接: {s.PhoneEndpoint}" : "    等待手机连接...");
        var ips = GetLocalIPv4();
        _addrLabel.Text = $"控制 TCP {_ctrlPort}   媒体 UDP {_mediaPort}   本机IP: {string.Join(", ", ips)}";
        _statsLabel.Text =
            $"PC→手机: {(s.Pc2Phone ? "开" : "关")}    手机→PC: {(s.Phone2Pc ? "开" : "关")}    已发送帧: {s.SentFrames}    已收麦克风: {(s.RecvBytes / 1024f / 1024f):F1} MB\n" +
            $"手机麦克风输出: {s.MicOutputName}    状态: {(s.MicOutputActive ? "正在输出" : "未监听/等待数据")}    (手机 App 里可自动发现本机)";
    }

    private static string[] GetLocalIPv4()
        => NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
            .Select(a => a.ToString())
            .ToArray();

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            ServerLog.OnLine -= OnLogLine;
            _timer.Dispose();
            _tray.Dispose();
        }
        base.Dispose(disposing);
    }
}

sealed record MicOutputChoice(string? Id, string DisplayName, bool IsVirtual);
