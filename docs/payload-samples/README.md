# 真实 hook payload 样本

这里是从本机真实 Claude Code / Codex hook 输入导出的**脱敏**样本，供 `Tests/SMCoreTests` 做 golden 测试和时间线回放。

- `claude-<event>-<capture-id>.json`：单个 Claude hook 事件；同名 `.provenance.json` 记录 CLI 版本、场景标签、采集时间、原始输入的 SHA-256 和父进程链。
- `timelines/`：按时间顺序排列的完整事件序列（Claude 两次会话、Codex 一次会话及其 rollout 生命周期片段），说明见 `timelines/README.md`。

提示词等正文已替换或删除；未脱敏的原始输入不进仓库。
