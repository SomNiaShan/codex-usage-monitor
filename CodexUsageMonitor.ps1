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

$script:uiLanguage = "zh"

function T {
    param([string]$Key)

    if ($script:uiLanguage -eq "en") {
        switch ($Key) {
            "Title" { return "Codex Quota" }
            "Waiting" { return "Waiting for usage data" }
            "NoData" { return "No usage data found" }
            "QuotaName" { return "Remaining quota" }
            "Pin" { return "Pin" }
            "OpenLogs" { return "Open log folder" }
            "Exit" { return "Exit" }
            "PrimaryFallback" { return "Primary" }
            "SecondaryFallback" { return "Secondary" }
            "RemainingPrefix" { return "Remaining " }
            "ResetUnknown" { return "reset --" }
            "ResetFormat" { return "reset {0:MM-dd HH:mm}" }
            "QuotaLowTitle" { return "Codex quota reminder" }
            "QuotaLowMessage" { return "Codex remaining quota is very low: {0}." }
            "UnknownPlan" { return "unknown plan" }
            "UnknownLimit" { return "unknown limit" }
            default { return $Key }
        }
    }

    switch ($Key) {
        "Title" { return "Codex " + (U "\u5269\u4f59\u989d\u5ea6") }
        "Waiting" { return U "\u7b49\u5f85\u7528\u91cf\u6570\u636e" }
        "NoData" { return U "\u6ca1\u6709\u627e\u5230\u7528\u91cf\u6570\u636e" }
        "QuotaName" { return U "\u5269\u4f59\u989d\u5ea6" }
        "Pin" { return U "\u9876" }
        "OpenLogs" { return U "\u6253\u5f00\u65e5\u5fd7\u6587\u4ef6\u5939" }
        "Exit" { return U "\u9000\u51fa" }
        "PrimaryFallback" { return U "\u4e3b\u989d\u5ea6" }
        "SecondaryFallback" { return U "\u6b21\u989d\u5ea6" }
        "RemainingPrefix" { return U "\u5269\u4f59 " }
        "ResetUnknown" { return U "\u91cd\u7f6e --" }
        "ResetFormat" { return (U "\u91cd\u7f6e") + " {0:MM-dd HH:mm}" }
        "QuotaLowTitle" { return "Codex " + (U "\u989d\u5ea6\u63d0\u9192") }
        "QuotaLowMessage" { return "Codex " + (U "\u5269\u4f59\u989d\u5ea6\u8fc7\u4f4e\uff1a{0}\u3002") }
        "UnknownPlan" { return "unknown plan" }
        "UnknownLimit" { return "unknown limit" }
        default { return $Key }
    }
}

function Get-LanguageButtonText {
    if ($script:uiLanguage -eq "en") {
        return U "\u6587"
    }

    return "EN"
}

function Get-UiFontFamily {
    $preferredFonts = @("Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI")
    try {
        $installedFonts = [System.Drawing.Text.InstalledFontCollection]::new().Families.Name
        foreach ($font in $preferredFonts) {
            if ($installedFonts -contains $font) {
                return $font
            }
        }
    }
    catch {
        return "Segoe UI"
    }

    return "Segoe UI"
}

function New-UiFont {
    param(
        [int]$Size = 9,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )

    return New-Object System.Drawing.Font($script:uiFontFamily, $Size, $Style)
}

$script:uiFontFamily = Get-UiFontFamily

$AppTitle = "Codex " + (U "\u7528\u91cf\u76d1\u63a7")

$consoleWindow = [CodexUsageWindowTools]::GetConsoleWindow()
if ($consoleWindow -ne [IntPtr]::Zero) {
    [CodexUsageWindowTools]::ShowWindow($consoleWindow, 0) | Out-Null
}

$CodexRoot = Join-Path $env:USERPROFILE ".codex"
$SessionsRoot = Join-Path $CodexRoot "sessions"
$LogsDatabasePath = Join-Path $CodexRoot "logs_2.sqlite"
$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$RateLimitReaderPath = Join-Path $ScriptDirectory "Read-CodexRateLimits.py"
$RefreshSeconds = 10
$ClockRefreshMilliseconds = 1000

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
    if ($null -eq $EpochSeconds) { return (T "ResetUnknown") }
    try {
        $local = [DateTimeOffset]::FromUnixTimeSeconds([int64]$EpochSeconds).LocalDateTime
        return ((T "ResetFormat") -f $local)
    }
    catch {
        return (T "ResetUnknown")
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
        if ($script:uiLanguage -eq "en") {
            return ("{0:N0}-week quota" -f ($minutes / 10080))
        }
        return ("{0:N0}{1}" -f ($minutes / 10080), (U "\u5468\u989d\u5ea6"))
    }
    if ($minutes -ge 1440 -and ($minutes % 1440) -eq 0) {
        if ($script:uiLanguage -eq "en") {
            return ("{0:N0}-day quota" -f ($minutes / 1440))
        }
        return ("{0:N0}{1}" -f ($minutes / 1440), (U "\u5929\u989d\u5ea6"))
    }
    if ($minutes -ge 60 -and ($minutes % 60) -eq 0) {
        if ($script:uiLanguage -eq "en") {
            return ("{0:N0}-hour quota" -f ($minutes / 60))
        }
        return ("{0:N0}{1}" -f ($minutes / 60), (U "\u5c0f\u65f6\u989d\u5ea6"))
    }
    if ($script:uiLanguage -eq "en") {
        return ("{0:N0}-minute quota" -f $minutes)
    }
    return ("{0:N0}{1}" -f $minutes, (U "\u5206\u949f\u989d\u5ea6"))
}

function Get-PythonExecutable {
    $candidates = @(
        (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        return $python.Source
    }

    return $null
}

function Get-ResetEpoch {
    param($Limit)
    if ($null -eq $Limit) { return $null }
    if ($null -ne $Limit.resets_at) { return $Limit.resets_at }
    if ($null -ne $Limit.reset_at) { return $Limit.reset_at }
    return $null
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

function Get-LatestSqliteRateLimitEvent {
    if (-not (Test-Path -LiteralPath $LogsDatabasePath)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $RateLimitReaderPath)) {
        return $null
    }

    $python = Get-PythonExecutable
    if ($null -eq $python) {
        return $null
    }

    try {
        $json = & $python $RateLimitReaderPath $LogsDatabasePath 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
            return $null
        }

        $snapshot = $json | ConvertFrom-Json
        if ($null -eq $snapshot -or $null -eq $snapshot.rate_limits) {
            return $null
        }

        return [pscustomobject]@{
            Event       = [pscustomobject]@{
                timestamp = $snapshot.timestamp
                payload   = [pscustomobject]@{
                    rate_limits = $snapshot.rate_limits
                }
            }
            SessionFile = $null
            Source      = "codex.rate_limits"
        }
    }
    catch {
        return $null
    }
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
    $label.Font = New-UiFont $Size $Style
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

$windowWidth = 252
$windowHeight = 190
$outerPadding = 12
$contentWidth = $windowWidth - ($outerPadding * 2)
$buttonGap = 2
$titleButtonGap = 6
$closeButtonWidth = 20
$pinButtonWidth = 34
$languageButtonWidth = 32
$topButtonHeight = 24
$closeButtonX = $windowWidth - $outerPadding - $closeButtonWidth
$pinButtonX = $closeButtonX - $buttonGap - $pinButtonWidth
$languageButtonX = $pinButtonX - $buttonGap - $languageButtonWidth
$titleWidth = $languageButtonX - $outerPadding - $titleButtonGap
$valueWidth = 124
$nameValueGap = 8
$valueX = $windowWidth - $outerPadding - $valueWidth
$nameWidth = $valueX - $outerPadding - $nameValueGap

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppTitle
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ClientSize = New-Object System.Drawing.Size($windowWidth, $windowHeight)
$form.TopMost = $true
$form.Opacity = 1.0
$form.BackColor = [System.Drawing.Color]::FromArgb(21, 23, 26)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230, 235, 242)
$form.Font = New-UiFont 9
$form.ShowInTaskbar = $true

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($screen.Right - $form.Width - 22), ($screen.Top + 70))

$accent = [System.Drawing.Color]::FromArgb(94, 167, 255)
$muted = [System.Drawing.Color]::FromArgb(152, 160, 170)
$good = [System.Drawing.Color]::FromArgb(74, 222, 128)
$warn = [System.Drawing.Color]::FromArgb(251, 191, 36)
$bad = [System.Drawing.Color]::FromArgb(248, 113, 113)
$script:quotaAlertActive = $false
$script:statusState = "Waiting"

$title = New-Label $outerPadding 12 $titleWidth 26 (T "Title") 12 ([System.Drawing.FontStyle]::Bold)
$status = New-Label $outerPadding 39 $contentWidth 18 (T "Waiting") 8 ([System.Drawing.FontStyle]::Regular) $muted
$close = New-Object System.Windows.Forms.Button
$close.SetBounds($closeButtonX, 12, $closeButtonWidth, $topButtonHeight)
$close.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$close.FlatAppearance.BorderSize = 0
$close.Text = "x"
$close.ForeColor = $muted
$close.BackColor = [System.Drawing.Color]::FromArgb(31, 34, 38)
$close.Font = New-UiFont 9 ([System.Drawing.FontStyle]::Bold)
$close.Add_Click({ $form.Close() })

$languageButton = New-Object System.Windows.Forms.Button
$languageButton.SetBounds($languageButtonX, 12, $languageButtonWidth, $topButtonHeight)
$languageButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$languageButton.FlatAppearance.BorderSize = 0
$languageButton.Text = Get-LanguageButtonText
$languageButton.ForeColor = $muted
$languageButton.BackColor = [System.Drawing.Color]::FromArgb(31, 34, 38)
$languageButton.Font = New-UiFont 8 ([System.Drawing.FontStyle]::Bold)
$languageButton.Add_Click({
    $script:uiLanguage = if ($script:uiLanguage -eq "en") { "zh" } else { "en" }
    Update-StaticText
    Update-UsageView
})

$pin = New-Object System.Windows.Forms.Button
$pin.SetBounds($pinButtonX, 12, $pinButtonWidth, $topButtonHeight)
$pin.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pin.FlatAppearance.BorderSize = 0
$pin.Text = T "Pin"
$pin.ForeColor = $accent
$pin.BackColor = [System.Drawing.Color]::FromArgb(31, 34, 38)
$pin.Font = New-UiFont 8 ([System.Drawing.FontStyle]::Bold)
$pin.Add_Click({
    $form.TopMost = -not $form.TopMost
    $pin.ForeColor = if ($form.TopMost) { $accent } else { $muted }
})

$primaryName = New-Label $outerPadding 64 $nameWidth 18 (Format-WindowName 300 (T "PrimaryFallback")) 9 ([System.Drawing.FontStyle]::Bold)
$primaryValue = New-Label $valueX 64 $valueWidth 18 "--" 9 ([System.Drawing.FontStyle]::Bold) $good
$primaryValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$primaryBar = New-Bar $outerPadding 88 $contentWidth
$primaryDetail = New-Label $outerPadding 102 $contentWidth 18 (T "ResetUnknown") 8 ([System.Drawing.FontStyle]::Regular) $muted

$secondaryName = New-Label $outerPadding 128 $nameWidth 18 (Format-WindowName 10080 (T "SecondaryFallback")) 9 ([System.Drawing.FontStyle]::Bold)
$secondaryValue = New-Label $valueX 128 $valueWidth 18 "--" 9 ([System.Drawing.FontStyle]::Bold) $good
$secondaryValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$secondaryBar = New-Bar $outerPadding 152 $contentWidth
$secondaryDetail = New-Label $outerPadding 166 $contentWidth 18 (T "ResetUnknown") 8 ([System.Drawing.FontStyle]::Regular) $muted

$form.Controls.AddRange(@(
    $title, $status, $close, $languageButton, $pin,
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
$openSessions = $menu.Items.Add((T "OpenLogs"))
$openSessions.Add_Click({
    if (Test-Path -LiteralPath $SessionsRoot) {
        Start-Process explorer.exe -ArgumentList "`"$SessionsRoot`""
    }
})
$exitItem = $menu.Items.Add((T "Exit"))
$exitItem.Add_Click({ $form.Close() })
$form.ContextMenuStrip = $menu

function Update-StaticText {
    $title.Text = T "Title"
    Update-StatusClock
    $pin.Text = T "Pin"
    $languageButton.Text = Get-LanguageButtonText
    $openSessions.Text = T "OpenLogs"
    $exitItem.Text = T "Exit"
    $primaryName.Text = Format-WindowName 300 (T "PrimaryFallback")
    $secondaryName.Text = Format-WindowName 10080 (T "SecondaryFallback")
    $primaryDetail.Text = T "ResetUnknown"
    $secondaryDetail.Text = T "ResetUnknown"
}

function Update-StatusClock {
    $timeText = "{0:HH:mm:ss}" -f (Get-Date)
    switch ($script:statusState) {
        "Waiting" {
            $status.Text = "{0} | {1}" -f (T "Waiting"), $timeText
            return
        }
        "NoData" {
            $status.Text = "{0} | {1}" -f (T "NoData"), $timeText
            return
        }
        default {
            $status.Text = $timeText
            return
        }
    }
}

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

function Get-EventTimestamp {
    param($TokenEvent)

    if ($null -eq $TokenEvent -or $null -eq $TokenEvent.Event -or $null -eq $TokenEvent.Event.timestamp) {
        return [DateTimeOffset]::MinValue
    }

    try {
        return [DateTimeOffset]::Parse([string]$TokenEvent.Event.timestamp)
    }
    catch {
        return [DateTimeOffset]::MinValue
    }
}

function Get-CurrentRateLimitEvent {
    $rateLimitEvent = Get-LatestSqliteRateLimitEvent
    $tokenCountEvent = Get-LatestTokenCountEvent

    if ($null -eq $rateLimitEvent) {
        return $tokenCountEvent
    }
    if ($null -eq $tokenCountEvent) {
        return $rateLimitEvent
    }

    if ((Get-EventTimestamp $tokenCountEvent) -gt (Get-EventTimestamp $rateLimitEvent)) {
        return $tokenCountEvent
    }

    return $rateLimitEvent
}

function Update-UsageView {
    $tokenEvent = Get-CurrentRateLimitEvent

    if ($null -eq $tokenEvent) {
        $script:statusState = "NoData"
        Update-StatusClock
        $status.ForeColor = $warn
        $primaryValue.Text = "--"
        $secondaryValue.Text = "--"
        $primaryName.Text = Format-WindowName 300 (T "PrimaryFallback")
        $secondaryName.Text = Format-WindowName 10080 (T "SecondaryFallback")
        $primaryDetail.Text = T "ResetUnknown"
        $secondaryDetail.Text = T "ResetUnknown"
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

    $primaryName.Text = Format-WindowName $primary.window_minutes (T "PrimaryFallback")
    $secondaryName.Text = Format-WindowName $secondary.window_minutes (T "SecondaryFallback")

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

    $primaryValue.Text = (T "RemainingPrefix") + (Format-Percent $primaryRemain)
    $primaryValue.ForeColor = Pick-UsageColor $primaryRemain
    $primaryDetail.Text = Format-ResetTime (Get-ResetEpoch $primary)
    Set-BarValue $primaryBar $primaryRemain

    $secondaryValue.Text = (T "RemainingPrefix") + (Format-Percent $secondaryRemain)
    $secondaryValue.ForeColor = Pick-UsageColor $secondaryRemain
    $secondaryDetail.Text = Format-ResetTime (Get-ResetEpoch $secondary)
    Set-BarValue $secondaryBar $secondaryRemain

    $script:statusState = "Clock"
    Update-StatusClock
    $status.ForeColor = $muted

    if ($null -ne $quotaRemain -and $quotaRemain -lt 5) {
        if (-not $script:quotaAlertActive) {
            $script:quotaAlertActive = $true
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                ((T "QuotaLowMessage") -f (Format-Percent $quotaRemain)),
                (T "QuotaLowTitle"),
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

$clockTimer = New-Object System.Windows.Forms.Timer
$clockTimer.Interval = $ClockRefreshMilliseconds
$clockTimer.Add_Tick({
    Update-StatusClock
})

$form.Add_Shown({
    Update-StatusClock
    Update-UsageView
    $clockTimer.Start()
    $timer.Start()
})

$form.Add_FormClosing({
    $timer.Stop()
    $clockTimer.Stop()
    if ($null -ne $script:singleInstanceMutex) {
        $script:singleInstanceMutex.ReleaseMutex()
        $script:singleInstanceMutex.Dispose()
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
