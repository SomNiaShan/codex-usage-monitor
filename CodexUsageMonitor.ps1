Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CodexUsageWindowTools
{
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

$ErrorActionPreference = "Stop"

function U {
    param([string]$Escaped)
    return [regex]::Replace($Escaped, "\\u([0-9a-fA-F]{4})", {
        param($Match)
        return [string][char][Convert]::ToInt32($Match.Groups[1].Value, 16)
    })
}

$AppTitle = "Codex " + (U "\u7528\u91cf\u76d1\u63a7")

$consoleWindow = [CodexUsageWindowTools]::GetConsoleWindow()
if ($consoleWindow -ne [IntPtr]::Zero) {
    [CodexUsageWindowTools]::ShowWindow($consoleWindow, 0) | Out-Null
}

$CodexRoot = Join-Path $env:USERPROFILE ".codex"
$SessionsRoot = Join-Path $CodexRoot "sessions"
$RefreshSeconds = 10

$createdNew = $false
$script:singleInstanceMutex = [System.Threading.Mutex]::new($true, "Local\CodexUsageMonitorFloatingQuota", [ref]$createdNew)
if (-not $createdNew) {
    $existingWindow = [CodexUsageWindowTools]::FindWindow($null, $AppTitle)
    if ($existingWindow -ne [IntPtr]::Zero) {
        [CodexUsageWindowTools]::ShowWindowAsync($existingWindow, 9) | Out-Null
        [CodexUsageWindowTools]::SetForegroundWindow($existingWindow) | Out-Null
    }
    exit
}

function Convert-ToPercent {
    param($Value)
    if ($null -eq $Value) { return $null }
    $number = [double]$Value
    if ($number -lt 0) { return 0.0 }
    if ($number -gt 100) { return 100.0 }
    return $number
}

function Format-Percent {
    param($Value)
    if ($null -eq $Value) { return "--" }
    return ("{0:N1}%" -f [double]$Value)
}

function Format-Integer {
    param($Value)
    if ($null -eq $Value) { return "--" }
    return ("{0:N0}" -f [double]$Value)
}

function Format-ResetTime {
    param($EpochSeconds)
    if ($null -eq $EpochSeconds) { return (U "\u91cd\u7f6e --") }
    try {
        $local = [DateTimeOffset]::FromUnixTimeSeconds([int64]$EpochSeconds).LocalDateTime
        return (((U "\u91cd\u7f6e") + " {0:MM-dd HH:mm}") -f $local)
    }
    catch {
        return (U "\u91cd\u7f6e --")
    }
}

function Format-WindowName {
    param(
        $WindowMinutes,
        [string]$Fallback
    )

    if ($null -eq $WindowMinutes) { return $Fallback }
    $minutes = [double]$WindowMinutes
    if ($minutes -ge 10080 -and ($minutes % 10080) -eq 0) {
        return ("{0:N0}" -f ($minutes / 10080)) + (U " \u5468\u7a97\u53e3")
    }
    if ($minutes -ge 1440 -and ($minutes % 1440) -eq 0) {
        return ("{0:N0}" -f ($minutes / 1440)) + (U " \u5929\u7a97\u53e3")
    }
    if ($minutes -ge 60 -and ($minutes % 60) -eq 0) {
        return ("{0:N0}" -f ($minutes / 60)) + (U " \u5c0f\u65f6\u7a97\u53e3")
    }
    return ("{0:N0}" -f $minutes) + (U " \u5206\u949f\u7a97\u53e3")
}

function Get-LatestSessionFile {
    if (-not (Test-Path -LiteralPath $SessionsRoot)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $SessionsRoot -Filter "rollout-*.jsonl" -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Get-LastTokenCountEvent {
    param($SessionFile)
    if ($null -eq $SessionFile -or -not (Test-Path -LiteralPath $SessionFile.FullName)) {
        return $null
    }

    $text = $null
    $stream = $null
    try {
        $maxBytes = 1048576
        $stream = [System.IO.File]::Open($SessionFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $readBytes = [int][Math]::Min($maxBytes, $stream.Length)
        $buffer = New-Object byte[] $readBytes
        $null = $stream.Seek(-1 * $readBytes, [System.IO.SeekOrigin]::End)
        $null = $stream.Read($buffer, 0, $readBytes)
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    $lines = $text -split "`n"

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = ([string]$lines[$i]).Trim()
        if ($line.IndexOf('"token_count"', [System.StringComparison]::Ordinal) -lt 0) {
            continue
        }

        try {
            $event = $line | ConvertFrom-Json
            if ($event.type -eq "event_msg" -and $event.payload.type -eq "token_count") {
                return [pscustomobject]@{
                    Event       = $event
                    SessionFile = $SessionFile
                }
            }
        }
        catch {
            continue
        }
    }

    $fallbackStream = $null
    $reader = $null
    try {
        $fallbackStream = [System.IO.File]::Open($SessionFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fallbackStream, [System.Text.Encoding]::UTF8)
        $lastTokenLine = $null
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.IndexOf('"token_count"', [System.StringComparison]::Ordinal) -ge 0) {
                $lastTokenLine = $line
            }
        }
        if ($null -ne $lastTokenLine) {
            $event = $lastTokenLine | ConvertFrom-Json
            if ($event.type -eq "event_msg" -and $event.payload.type -eq "token_count") {
                return [pscustomobject]@{
                    Event       = $event
                    SessionFile = $SessionFile
                }
            }
        }
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        elseif ($null -ne $fallbackStream) {
            $fallbackStream.Dispose()
        }
    }

    return $null
}

function New-Label {
    param(
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [string]$Text,
        [int]$Size = 9,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::FromArgb(220, 225, 232)
    )

    $label = New-Object System.Windows.Forms.Label
    $label.SetBounds($X, $Y, $W, $H)
    $label.Text = $Text
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::FromArgb(21, 23, 26)
    $label.Font = New-Object System.Drawing.Font("Segoe UI", $Size, $Style)
    $label.AutoSize = $false
    return $label
}

function New-Bar {
    param([int]$X, [int]$Y, [int]$W)

    $track = New-Object System.Windows.Forms.Panel
    $track.SetBounds($X, $Y, $W, 10)
    $track.BackColor = [System.Drawing.Color]::FromArgb(45, 49, 55)

    $fill = New-Object System.Windows.Forms.Panel
    $fill.SetBounds(0, 0, 0, 10)
    $fill.BackColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
    $track.Controls.Add($fill)
    $track.Tag = $fill

    return $track
}

function Set-BarValue {
    param($Bar, $Percent)
    $fill = $Bar.Tag
    if ($null -eq $fill) { return }

    if ($null -eq $Percent) {
        $fill.Width = 0
        return
    }

    $remaining = [double]$Percent
    if ($remaining -lt 0) { $remaining = 0 }
    if ($remaining -gt 100) { $remaining = 100 }

    $fill.Width = [int]([Math]::Round($Bar.ClientSize.Width * $remaining / 100.0))
    $fill.BackColor = Pick-UsageColor $remaining
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppTitle
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ClientSize = New-Object System.Drawing.Size(360, 230)
$form.TopMost = $true
$form.Opacity = 1.0
$form.BackColor = [System.Drawing.Color]::FromArgb(21, 23, 26)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230, 235, 242)
$form.ShowInTaskbar = $true

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($screen.Right - $form.Width - 22), ($screen.Top + 70))

$accent = [System.Drawing.Color]::FromArgb(94, 167, 255)
$muted = [System.Drawing.Color]::FromArgb(152, 160, 170)
$good = [System.Drawing.Color]::FromArgb(74, 222, 128)
$warn = [System.Drawing.Color]::FromArgb(251, 191, 36)
$bad = [System.Drawing.Color]::FromArgb(248, 113, 113)
$script:quotaAlertActive = $false

$title = New-Label 16 12 260 26 ("Codex " + (U "\u5269\u4f59\u989d\u5ea6")) 12 ([System.Drawing.FontStyle]::Bold)
$status = New-Label 16 39 260 18 (U "\u7b49\u5f85\u7528\u91cf\u6570\u636e") 8 ([System.Drawing.FontStyle]::Regular) $muted
$close = New-Object System.Windows.Forms.Button
$close.SetBounds(320, 12, 24, 24)
$close.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$close.FlatAppearance.BorderSize = 0
$close.Text = "x"
$close.ForeColor = $muted
$close.BackColor = [System.Drawing.Color]::FromArgb(31, 34, 38)
$close.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$close.Add_Click({ $form.Close() })

$pin = New-Object System.Windows.Forms.Button
$pin.SetBounds(290, 12, 24, 24)
$pin.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pin.FlatAppearance.BorderSize = 0
$pin.Text = U "\u9876"
$pin.ForeColor = $accent
$pin.BackColor = [System.Drawing.Color]::FromArgb(31, 34, 38)
$pin.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$pin.Add_Click({
    $form.TopMost = -not $form.TopMost
    $pin.ForeColor = if ($form.TopMost) { $accent } else { $muted }
})

$quotaName = New-Label 16 64 160 20 (U "\u5269\u4f59\u989d\u5ea6") 10 ([System.Drawing.FontStyle]::Bold)
$quotaValue = New-Label 176 56 168 32 "--" 18 ([System.Drawing.FontStyle]::Bold) $good
$quotaValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight

$primaryName = New-Label 16 100 210 18 (U "5 \u5c0f\u65f6\u7a97\u53e3") 9 ([System.Drawing.FontStyle]::Bold)
$primaryValue = New-Label 218 100 126 18 "--" 9 ([System.Drawing.FontStyle]::Bold) $good
$primaryValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$primaryBar = New-Bar 16 124 328
$primaryDetail = New-Label 16 138 328 18 ((U "\u5df2\u7528 -- / \u91cd\u7f6e --")) 8 ([System.Drawing.FontStyle]::Regular) $muted

$secondaryName = New-Label 16 164 210 18 (U "1 \u5468\u7a97\u53e3") 9 ([System.Drawing.FontStyle]::Bold)
$secondaryValue = New-Label 218 164 126 18 "--" 9 ([System.Drawing.FontStyle]::Bold) $good
$secondaryValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$secondaryBar = New-Bar 16 188 328
$secondaryDetail = New-Label 16 202 328 18 ((U "\u5df2\u7528 -- / \u91cd\u7f6e --")) 8 ([System.Drawing.FontStyle]::Regular) $muted

$form.Controls.AddRange(@(
    $title, $status, $close, $pin, $quotaName, $quotaValue,
    $primaryName, $primaryValue, $primaryBar, $primaryDetail,
    $secondaryName, $secondaryValue, $secondaryBar, $secondaryDetail
))

$script:dragging = $false
$dragOffset = New-Object System.Drawing.Point(0, 0)
$dragTargets = @($form, $title, $status)
foreach ($target in $dragTargets) {
    $target.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:dragging = $true
            $sender.Capture = $true
            if ($null -ne $timer) {
                $timer.Stop()
            }
            $cursor = [System.Windows.Forms.Cursor]::Position
            $script:dragOffset = New-Object System.Drawing.Point(($cursor.X - $form.Location.X), ($cursor.Y - $form.Location.Y))
        }
    })
    $target.Add_MouseMove({
        param($sender, $e)
        if ($script:dragging) {
            $cursor = [System.Windows.Forms.Cursor]::Position
            $form.Location = New-Object System.Drawing.Point(($cursor.X - $script:dragOffset.X), ($cursor.Y - $script:dragOffset.Y))
        }
    })
    $target.Add_MouseUp({
        param($sender, $e)
        $script:dragging = $false
        $sender.Capture = $false
        if ($null -ne $timer) {
            $timer.Start()
        }
    })
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openSessions = $menu.Items.Add((U "\u6253\u5f00\u65e5\u5fd7\u6587\u4ef6\u5939"))
$openSessions.Add_Click({
    if (Test-Path -LiteralPath $SessionsRoot) {
        Start-Process explorer.exe -ArgumentList "`"$SessionsRoot`""
    }
})
$exitItem = $menu.Items.Add((U "\u9000\u51fa"))
$exitItem.Add_Click({ $form.Close() })
$form.ContextMenuStrip = $menu

function Pick-UsageColor {
    param($RemainingPercent)
    if ($null -eq $RemainingPercent) { return $muted }
    if ($RemainingPercent -lt 5) { return $bad }
    if ($RemainingPercent -lt 20) { return $warn }
    return $good
}

function Get-LatestTokenCountEvent {
    if (-not (Test-Path -LiteralPath $SessionsRoot)) {
        return $null
    }

    $files = Get-ChildItem -LiteralPath $SessionsRoot -Filter "rollout-*.jsonl" -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 20

    $candidates = @()
    foreach ($file in $files) {
        $tokenEvent = Get-LastTokenCountEvent $file
        if ($null -ne $tokenEvent) {
            $eventTime = [DateTimeOffset]::MinValue
            try {
                $eventTime = [DateTimeOffset]::Parse([string]$tokenEvent.Event.timestamp)
            }
            catch {
                $eventTime = [DateTimeOffset]::MinValue
            }

            $limits = $tokenEvent.Event.payload.rate_limits
            $primaryUsed = Convert-ToPercent $limits.primary.used_percent
            $secondaryUsed = Convert-ToPercent $limits.secondary.used_percent
            $remaining = $null
            if ($null -ne $primaryUsed -and $null -ne $secondaryUsed) {
                $remaining = 100.0 - [Math]::Max($primaryUsed, $secondaryUsed)
            }

            $candidates += [pscustomobject]@{
                TokenEvent = $tokenEvent
                EventTime  = $eventTime
                LimitId    = [string]$limits.limit_id
                Remaining  = $remaining
            }
        }
    }

    $codexCandidates = @($candidates | Where-Object { $_.LimitId -eq "codex" })
    if ($codexCandidates.Count -gt 0) {
        return ($codexCandidates | Sort-Object EventTime -Descending | Select-Object -First 1).TokenEvent
    }

    if ($candidates.Count -gt 0) {
        return ($candidates | Sort-Object Remaining, EventTime | Select-Object -First 1).TokenEvent
    }

    return $null
}

function Update-UsageView {
    $tokenEvent = Get-LatestTokenCountEvent

    if ($null -eq $tokenEvent) {
        $status.Text = U "\u6ca1\u6709\u627e\u5230\u7528\u91cf\u6570\u636e"
        $status.ForeColor = $warn
        $quotaValue.Text = "--"
        $primaryValue.Text = "--"
        $secondaryValue.Text = "--"
        $primaryDetail.Text = U "\u5df2\u7528 -- / \u91cd\u7f6e --"
        $secondaryDetail.Text = U "\u5df2\u7528 -- / \u91cd\u7f6e --"
        Set-BarValue $primaryBar $null
        Set-BarValue $secondaryBar $null
        return
    }

    $event = $tokenEvent.Event
    $limits = $event.payload.rate_limits
    $primary = $limits.primary
    $secondary = $limits.secondary

    $primaryUsed = Convert-ToPercent $primary.used_percent
    $secondaryUsed = Convert-ToPercent $secondary.used_percent
    $primaryRemain = if ($null -ne $primaryUsed) { 100.0 - $primaryUsed } else { $null }
    $secondaryRemain = if ($null -ne $secondaryUsed) { 100.0 - $secondaryUsed } else { $null }

    $primaryName.Text = Format-WindowName $primary.window_minutes (U "\u4e3b\u989d\u5ea6\u7a97\u53e3")
    $secondaryName.Text = Format-WindowName $secondary.window_minutes (U "\u6b21\u989d\u5ea6\u7a97\u53e3")

    $quotaRemain = $null
    if ($null -ne $primaryRemain -and $null -ne $secondaryRemain) {
        $quotaRemain = [Math]::Min($primaryRemain, $secondaryRemain)
    }
    elseif ($null -ne $primaryRemain) {
        $quotaRemain = $primaryRemain
    }
    elseif ($null -ne $secondaryRemain) {
        $quotaRemain = $secondaryRemain
    }

    $quotaValue.Text = Format-Percent $quotaRemain
    $quotaValue.ForeColor = Pick-UsageColor $quotaRemain

    $primaryValue.Text = (U "\u5269\u4f59 ") + (Format-Percent $primaryRemain)
    $primaryValue.ForeColor = Pick-UsageColor $primaryRemain
    $primaryDetail.Text = ((U "\u5df2\u7528 {0} / {1}") -f (Format-Percent $primaryUsed), (Format-ResetTime $primary.resets_at))
    Set-BarValue $primaryBar $primaryRemain

    $secondaryValue.Text = (U "\u5269\u4f59 ") + (Format-Percent $secondaryRemain)
    $secondaryValue.ForeColor = Pick-UsageColor $secondaryRemain
    $secondaryDetail.Text = ((U "\u5df2\u7528 {0} / {1}") -f (Format-Percent $secondaryUsed), (Format-ResetTime $secondary.resets_at))
    Set-BarValue $secondaryBar $secondaryRemain

    $plan = if ($limits.plan_type) { $limits.plan_type } else { "unknown plan" }
    $limitId = if ($limits.limit_id) { $limits.limit_id } else { "unknown limit" }
    $status.Text = ("{0}/{1} | {2:HH:mm:ss}" -f $plan, $limitId, (Get-Date))
    $status.ForeColor = $muted

    if ($null -ne $quotaRemain -and $quotaRemain -lt 5) {
        if (-not $script:quotaAlertActive) {
            $script:quotaAlertActive = $true
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                (("Codex " + (U "\u5269\u4f59\u989d\u5ea6\u8fc7\u4f4e\uff1a{0}\u3002")) -f (Format-Percent $quotaRemain)),
                ("Codex " + (U "\u989d\u5ea6\u63d0\u9192")),
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }
    elseif ($null -ne $quotaRemain -and $quotaRemain -ge 5) {
        $script:quotaAlertActive = $false
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $RefreshSeconds * 1000
$timer.Add_Tick({
    if ($script:dragging) {
        return
    }
    Update-UsageView
})

$form.Add_Shown({
    Update-UsageView
    $timer.Start()
})

$form.Add_FormClosing({
    $timer.Stop()
    if ($null -ne $script:singleInstanceMutex) {
        $script:singleInstanceMutex.ReleaseMutex()
        $script:singleInstanceMutex.Dispose()
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
