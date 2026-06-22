# Codex 用量监控浮窗

Windows 上的 Codex Desktop 剩余额度浮窗。

使用桌面快捷方式 `Codex 用量监控` 启动。

每 10 秒刷新一次。

读取内容：

- 只读 `%USERPROFILE%\.codex\logs_2.sqlite` 里的最新 `codex.rate_limits` 事件。
- 同时读取 `%USERPROFILE%\.codex\sessions` 下 `rollout-*.jsonl` 里的最新 `token_count` 事件，并使用时间更新的一条。
- 显示 `rate_limits.primary` 和 `rate_limits.secondary`。
- 优先使用 `limit_id = codex` 的额度池。

说明：

- 只读，不会修改 Codex 文件，也不会使用你的 auth token。
- 大号数字显示两个限额窗口里更紧的剩余百分比。
- 进度条显示剩余额度：满条表示未使用，额度消耗后会变短。
- 剩余低于 20% 变黄，低于 5% 变红并弹出一次提醒。
- 按住标题区域可以拖动窗口。
- `EN/文` 按钮用于在英文和中文界面之间切换。
- `顶` 按钮用于切换置顶。
- 右键菜单可以打开日志文件夹或退出。
