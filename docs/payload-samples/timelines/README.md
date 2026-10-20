# 真实时间线回归样本

来自 2026-10-19 M0 的两次完整 Claude CLI 采集，全部事件按 meta.receivedAt 排序，不抽样、不重排。共 tools-permissions 29 条、startup-clear-exit 10 条。payload 使用 scripts/m0.py 的同一脱敏规则，保留 agent_id 的稳定别名。provenance 记录原始文件、SHA-256 和 UTC 接收时间；原始正文留在忽略的 .m0/ 中。

envelope 是为重放而生成的包装：agentPid 来自当时 parentChain 中 sessionFileExists=true 的祖先进程，退出时为空，env 为空（原始采集未记录终端环境）。这些字段不冒充原始 hook payload。测试通过 ClaudeSource.normalize → SessionStore.apply 重放，不启动原 PID 的进程。

## codex-probe（Codex CLI 0.163.0，2026-10-19）

- `codex-probe.jsonl`：一次真实 Codex 测试会话的 19 个 hook payload（由 `sm-hook codex` 的采集模式保存）。payload 保持原样（提示词是测试时写的探针文本），外层 envelope 按采集时间重建；`env` 是 tmux 场景的代表值，因为采集模式只保存 payload，不保存环境变量。
- `codex-probe-rollout.jsonl`：同一会话 rollout 文件中的回合生命周期行（`task_started`/`task_complete`/`turn_aborted`），只保留类型、时间和 reason。最后一轮是按 Esc 中断的，没有触发任何 hook，只能从 rollout 的 `turn_aborted` 看出来。
