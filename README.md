# Codex Usage Monitor

一个非官方的 Windows 桌面浮窗，用来查看 Codex Desktop 的剩余额度。

An unofficial Windows floating window for checking local Codex Desktop usage quota.

This project is not affiliated with OpenAI. The bundled app icon is an original icon inspired by the Codex visual style, not an official OpenAI asset.

## Features

- Shows primary and secondary quota windows with remaining percentage bars.
- Updates quota data every 10 seconds.
- Updates the clock every second.
- Supports Chinese and English UI.
- Stays on top by default, with a `Pin` toggle.
- Reads quota through the local Codex `app-server` RPC; it does not write to Codex files or read auth tokens directly.

## Install

1. Download `CodexUsageMonitor.exe` from the latest release.
2. Double-click it.

The single-file launcher extracts the supporting files to `%LOCALAPPDATA%\CodexUsageMonitor\app` and starts the monitor without flashing a console window.

## What It Reads

- `codex app-server --stdio`
  - `account/rateLimits/read`

The app uses only Codex's local app-server RPC as its quota data source.

## Requirements

- Windows
- Codex Desktop or Codex CLI installed and logged in
- `codex.exe` available from `PATH` or from common OpenAI IDE extension folders
- Windows PowerShell

## Privacy

This tool is read-only.

It does not:

- send telemetry
- modify Codex files
- read or use Codex auth tokens

It asks the locally installed Codex app-server for `account/rateLimits/read`. Codex itself may contact OpenAI using its existing login state to refresh account quota data.

## Usage Notes

- Drag the title/status area to move the window.
- Right-click the window to open the Codex log folder or exit.
- The language button shows the target language: `EN` in Chinese UI, `文` in English UI.
- The progress bars show remaining quota: full bar means unused, shorter bar means more quota has been consumed.
- Remaining quota below 20% turns yellow; below 5% turns red and shows a one-time reminder.

## License

MIT. See [LICENSE](LICENSE).
