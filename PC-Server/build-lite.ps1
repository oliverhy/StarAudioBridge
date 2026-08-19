param(
    [string]$Version = "1.0.2"
)

$ErrorActionPreference = "Stop"

$serverDirectory = $PSScriptRoot
$projectPath = Join-Path $serverDirectory "StarAudioBridge.Server.csproj"
$outputDirectory = Join-Path $serverDirectory ("bin\Release\lite-v" + $Version)
$packageDirectory = Join-Path $outputDirectory "package"
$archivePath = Join-Path $outputDirectory ("StarAudioBridge.Server-win-x64-lite-" + $Version + ".zip")
$launcherSource = Join-Path $serverDirectory "LiteLauncher\Program.cs"
$launcherReadme = Join-Path $serverDirectory "LiteLauncher\README.txt"
$launcherPath = Join-Path $packageDirectory "StarAudioBridge.Server.exe"

$compilerCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$compilerPath = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($compilerPath)) {
    throw "找不到 Windows 自带的 C# 编译器，无法生成轻量版启动器。"
}

New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null

dotnet publish $projectPath `
    -c Release `
    -r win-x64 `
    --self-contained false `
    -p:PublishSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:AssemblyName=StarAudioBridge.Server.App `
    -o $packageDirectory
if ($LASTEXITCODE -ne 0) {
    throw "轻量版主程序发布失败。"
}

& $compilerPath `
    /nologo `
    /target:winexe `
    /platform:x64 `
    /optimize+ `
    /out:$launcherPath `
    /reference:System.Windows.Forms.dll `
    $launcherSource
if ($LASTEXITCODE -ne 0) {
    throw "轻量版启动器编译失败。"
}

Copy-Item -LiteralPath $launcherReadme -Destination (Join-Path $packageDirectory "README.txt") -Force
Compress-Archive -Path (Join-Path $packageDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal -Force

Get-Item -LiteralPath $launcherPath, (Join-Path $packageDirectory "StarAudioBridge.Server.App.exe"), $archivePath |
    Select-Object FullName, Length
