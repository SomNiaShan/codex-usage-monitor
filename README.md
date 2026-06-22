# Codex Usage Monitor

一个非官方的 Windows 桌面浮窗，用来查看 Codex Desktop 的剩余额度。

An unofficial Windows floating window for checking local Codex Desktop usage quota.

## Features

- Shows primary and secondary quota windows with remaining percentage bars.
- Updates quota data every 10 seconds.
- Updates the clock every second.
- Supports Chinese and English UI.
- Stays on top by default, with a `Pin` toggle.
- Reads local Codex data only; it does not write to Codex files and does not use auth tokens.

## Install

1. Download or clone this repository.
2. Run PowerShell in the project folder:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1
   ```

3. Start it from the desktop shortcut `Codex Usage Monitor`.

You can also run it directly:

```powershell
.\Start-CodexUsageMonitor.cmd
```

To remove the desktop shortcut:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1 -Remove
```

## What It Reads

- `%USERPROFILE%\.codex\logs_2.sqlite`
  - latest `codex.rate_limits` events from Codex logs
- `%USERPROFILE%\.codex\sessions\**\rollout-*.jsonl`
  - latest `token_count` events as fallback/current-session data

The app prefers the `limit_id = codex` quota pool when multiple pools are found.

## Requirements

- Windows
- Codex Desktop with local logs under `%USERPROFILE%\.codex`
- Windows PowerShell
- Python, only for reading `logs_2.sqlite`
  - The script first tries Codex's bundled Python runtime.
  - If unavailable, it falls back to `python.exe` from `PATH`.

## Privacy

This tool is local-only and read-only.

It does not:

- send telemetry
- call network APIs
- modify Codex files
- read or use Codex auth tokens

## Usage Notes

- Drag the title/status area to move the window.
- Right-click the window to open the Codex log folder or exit.
- The language button shows the target language: `EN` in Chinese UI, `文` in English UI.
- The progress bars show remaining quota: full bar means unused, shorter bar means more quota has been consumed.
- Remaining quota below 20% turns yellow; below 5% turns red and shows a one-time reminder.

## License

MIT. See [LICENSE](LICENSE).
