param(
    [string]$Version = "dev"
)

$ErrorActionPreference = "Stop"

$workspace = if ($PSScriptRoot) {
    $PSScriptRoot
}
else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

$dist = Join-Path $workspace "dist"
$sourcePath = Join-Path $dist "CodexUsageMonitorLauncher.cs"
$exePath = Join-Path $dist "CodexUsageMonitor.exe"
$iconPath = Join-Path $workspace "assets\codex-usage-monitor.ico"

if (Test-Path -LiteralPath $dist) {
    $resolved = (Resolve-Path -LiteralPath $dist).Path
    if (-not $resolved.StartsWith($workspace, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside workspace: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $dist | Out-Null

function Convert-FileToCSharpString {
    param([string]$RelativePath)

    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $workspace $RelativePath))
    $base64 = [Convert]::ToBase64String($bytes)
    $chunks = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $base64.Length; $i += 760) {
        $len = [Math]::Min(760, $base64.Length - $i)
        $chunks.Add('        "' + $base64.Substring($i, $len) + '"')
    }

    return ($chunks -join " +`r`n")
}

$monitorPayload = Convert-FileToCSharpString "CodexUsageMonitor.ps1"
$iconPayload = Convert-FileToCSharpString "assets\codex-usage-monitor.ico"

$source = @"
using System;
using System.Diagnostics;
using System.IO;

namespace CodexUsageMonitorLauncher
{
    internal static class Program
    {
        private const string Version = "$Version";

        [STAThread]
        private static void Main()
        {
            string installDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CodexUsageMonitor");
            string appDir = Path.Combine(installDir, "app");
            string assetsDir = Path.Combine(appDir, "assets");

            Directory.CreateDirectory(assetsDir);
            WritePayload(Path.Combine(appDir, "CodexUsageMonitor.ps1"), MonitorPayload);
            WritePayload(Path.Combine(assetsDir, "codex-usage-monitor.ico"), IconPayload);

            string scriptPath = Path.Combine(appDir, "CodexUsageMonitor.ps1");
            var startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\"",
                CreateNoWindow = true,
                UseShellExecute = false,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            Process.Start(startInfo);
        }

        private static void WritePayload(string path, string base64)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllBytes(path, Convert.FromBase64String(base64));
        }

        private const string MonitorPayload =
$monitorPayload;

        private const string IconPayload =
$iconPayload;
    }
}
"@

[System.IO.File]::WriteAllText($sourcePath, $source, [System.Text.Encoding]::UTF8)

$cscCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)

$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($null -eq $csc) {
    throw "Could not find csc.exe from .NET Framework."
}

$compilerOutput = & $csc /nologo /target:winexe /optimize+ /win32icon:$iconPath /out:$exePath $sourcePath 2>&1
if ($LASTEXITCODE -ne 0) {
    $compilerOutput | Write-Host
    throw "csc.exe failed with exit code $LASTEXITCODE."
}

Get-Item -LiteralPath $exePath
