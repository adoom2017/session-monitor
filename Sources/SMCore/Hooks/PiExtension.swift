import Foundation

/// The Pi extension Codewhistle installs at `~/.pi/agent/extensions/codewhistle.ts`.
/// Pi has no hook configuration: this module forwards its lifecycle events to sm-hook in the
/// same payload shape Claude and Codex use, so the reducer and UI stay agent-agnostic.
/// The marker line identifies the file as ours (status/uninstall/sync never touch foreign files).
public enum PiExtension {
  public static let marker = "codewhistle-pi-extension"

  public static let source = #"""
// codewhistle-pi-extension — installed by 码哨 (Codewhistle). Delete this file to stop reporting.
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const hook = join(homedir(), ".session-monitor", "bin", "sm-hook");

// Only the fields the panel shows: tool arguments can hold whole files and exceed sm-hook's
// 1 MB input limit.
function toolInput(args: unknown): Record<string, string> {
  const result: Record<string, string> = {};
  if (!args || typeof args !== "object") return result;
  const source = args as Record<string, unknown>;
  for (const key of ["command", "path", "file_path", "pattern", "query", "url", "description", "prompt"]) {
    const value = source[key];
    if (typeof value === "string") result[key] = value.length > 2000 ? value.slice(0, 2000) : value;
  }
  return result;
}

function assistantText(message: any): string {
  const content = message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n");
}

export default function (pi: ExtensionAPI) {
  let lastAssistant = "";

  function send(ctx: ExtensionContext, event: string, extra: Record<string, unknown> = {}) {
    const payload: Record<string, unknown> = {
      session_id: ctx.sessionManager.getSessionId(),
      hook_event_name: event,
      cwd: ctx.cwd,
      transcript_path: ctx.sessionManager.getSessionFile(),
      ...extra,
    };
    if (ctx.model) {
      payload.model = ctx.model.id;
      const window = (ctx.model as any).contextWindow;
      if (typeof window === "number") payload.context_window = window;
    }
    // Synchronous so event order matches Pi's lifecycle. A missing hook or stopped app must not
    // affect Pi: errors are ignored here (sm-hook spools events when the app is not running).
    spawnSync(hook, ["pi"], {
      input: JSON.stringify(payload),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 3000,
    });
  }

  pi.on("session_start", async (event, ctx) => {
    lastAssistant = "";
    send(ctx, "SessionStart", { source: event.reason });
  });

  pi.on("before_agent_start", async (_event, ctx) => {
    lastAssistant = "";
    send(ctx, "UserPromptSubmit");
  });

  pi.on("tool_execution_start", async (event, ctx) => {
    send(ctx, "PreToolUse", { tool_name: event.toolName, tool_input: toolInput(event.args) });
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    send(ctx, "PostToolUse", { tool_name: event.toolName });
  });

  pi.on("turn_end", async (event) => {
    const text = assistantText((event as any).message);
    if (text) lastAssistant = text;
  });

  pi.on("agent_settled", async (event, ctx) => {
    send(ctx, event.aborted ? "Interrupt" : "Stop",
      event.aborted ? {} : { last_assistant_message: lastAssistant });
  });

  // Pi's dialogs (select/confirm/input/editor) block the turn waiting for the user.
  pi.on("ui_prompt_start", async (event, ctx) => {
    send(ctx, "PermissionRequest", {
      tool_name: "AskUserQuestion",
      message: (event as any).title ?? (event as any).kind ?? "等待选择",
    });
  });
  pi.on("ui_prompt_end", async (_event, ctx) => {
    send(ctx, "PromptEnded", { state: ctx.isIdle() ? "idle" : "working" });
  });

  pi.on("session_before_compact", async (_event, ctx) => {
    send(ctx, "PreCompact");
  });
  pi.on("session_compact", async (event, ctx) => {
    send(ctx, "PostCompact", { state: event.reason === "manual" ? "idle" : "working" });
  });
  pi.on("session_compact_failed", async (event, ctx) => {
    send(ctx, "PostCompact", { state: event.reason === "manual" ? "idle" : "working" });
  });

  pi.on("session_shutdown", async (event, ctx) => {
    send(ctx, "SessionEnd", { reason: event.reason });
  });
}
"""#
}
