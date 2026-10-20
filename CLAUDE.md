# AGENTS.md

本仓库实现 macOS 悬浮窗 SessionMonitor，集中展示多个 Claude Code / Codex 会话状态。

- 需求与设计：`docs/DEV_SPEC.md`（唯一需求来源）
- 验收清单：`docs/ACCEPTANCE.md`（review 逐条核对）
- 实现中的决策记录：`docs/DECISIONS.md`
- 按里程碑 M0 → M3 顺序推进，M0（真实 hook payload 采集）必须先做。
- 修改用户的 `~/.claude/settings.json` / `~/.codex/hooks.json` 前必须备份，结束后恢复临时改动。
