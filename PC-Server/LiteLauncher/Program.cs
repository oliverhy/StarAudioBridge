using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class Program
{
    private const string AppFileName = "StarAudioBridge.Server.App.exe";
    private const string RuntimeDownloadUrl =
        "https://aka.ms/dotnet-core-applaunch?framework=Microsoft.WindowsDesktop.App&framework_version=8.0.0&arch=x64&rid=win-x64&os=win10";

    [STAThread]
    private static int Main(string[] args)
    {
        if (!HasDesktopRuntime8())
        {
            MessageBox.Show(
                "StarAudioBridge 轻量版需要 .NET 8 Desktop Runtime (x64)。\n\n" +
                "点击“确定”后将打开微软官方下载页面。安装完成后，请重新运行本程序。",
                "需要安装 .NET 8 Desktop Runtime",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            OpenRuntimeDownloadPage();
            return 2;
        }

        string appPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, AppFileName);
        if (!File.Exists(appPath))
        {
            MessageBox.Show(
                "未找到 " + AppFileName + "。\n\n请完整解压轻量版 ZIP 后再运行。",
                "StarAudioBridge 文件不完整",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 3;
        }

        try
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = appPath;
            startInfo.Arguments = BuildArguments(args);
            startInfo.WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory;
            startInfo.UseShellExecute = false;
            Process.Start(startInfo);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "启动 PC 服务端失败：\n" + ex.Message,
                "StarAudioBridge 启动失败",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 4;
        }
    }

    private static bool HasDesktopRuntime8()
    {
        HashSet<string> roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        AddRoot(roots, Environment.GetEnvironmentVariable("DOTNET_ROOT_X64"));
        AddRoot(roots, Environment.GetEnvironmentVariable("DOTNET_ROOT"));
        AddRoot(roots, Environment.GetEnvironmentVariable("ProgramW6432"), "dotnet");
        AddRoot(roots, Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "dotnet");

        foreach (string root in roots)
        {
            string frameworkDirectory = Path.Combine(root, "shared", "Microsoft.WindowsDesktop.App");
            if (!Directory.Exists(frameworkDirectory))
            {
                continue;
            }

            try
            {
                foreach (string versionDirectory in Directory.GetDirectories(frameworkDirectory))
                {
                    string versionName = Path.GetFileName(versionDirectory);
                    Version version;
                    if (Version.TryParse(versionName, out version) && version.Major == 8)
                    {
                        return true;
                    }
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        return false;
    }

    private static void AddRoot(ISet<string> roots, string basePath)
    {
        if (!string.IsNullOrWhiteSpace(basePath))
        {
            roots.Add(basePath.Trim());
        }
    }

    private static void AddRoot(ISet<string> roots, string basePath, string child)
    {
        if (!string.IsNullOrWhiteSpace(basePath))
        {
            roots.Add(Path.Combine(basePath.Trim(), child));
        }
    }

    private static void OpenRuntimeDownloadPage()
    {
        try
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = RuntimeDownloadUrl;
            startInfo.UseShellExecute = true;
            Process.Start(startInfo);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "无法自动打开浏览器，请手动访问：\n\n" + RuntimeDownloadUrl + "\n\n" + ex.Message,
                "无法打开下载页面",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private static string BuildArguments(IEnumerable<string> args)
    {
        List<string> quoted = new List<string>();
        foreach (string arg in args)
        {
            quoted.Add(QuoteArgument(arg));
        }
        return string.Join(" ", quoted.ToArray());
    }

    private static string QuoteArgument(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (value.IndexOfAny(new[] { ' ', '\t', '\"' }) < 0)
        {
            return value;
        }

        StringBuilder result = new StringBuilder();
        result.Append('\"');
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '\"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('\"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }

        result.Append('\\', backslashes * 2);
        result.Append('\"');
        return result.ToString();
    }
}
