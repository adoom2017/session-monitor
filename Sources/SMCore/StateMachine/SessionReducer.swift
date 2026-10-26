import Foundation

public enum SessionReducer {
  public static func reduce(_ previous: Session?, _ event: AgentEvent) throws -> Session {
    if let previous {
      guard previous.id == event.key else {
        throw MonitorError.invalid("reducer identity mismatch")
      }
      guard event.at >= previous.lastEventAt.addingTimeInterval(-2) else {
        throw MonitorError.staleEvent(previous.id)
      }
      if previous.currentSessionId != event.sessionId, event.at < previous.lastEventAt {
        throw MonitorError.staleEvent(previous.id)
      }
    }
    var s = previous ?? Session(event: event)
    let priorState = s.state
    // Lifecycle hooks carry the child's ID too; they account for children separately.
    if event.agentId != nil, event.type != .subagentStart, event.type != .subagentStop {
      s.lastEventAt = max(s.lastEventAt, event.at)
      if s.state == .working {
        if case .toolStart(let name, let summary) = event.type {
          s.currentTool = singleLine(name + (summary.map { ": " + $0 } ?? ""), limit: 80)
        } else if case .toolEnd = event.type {
          s.currentTool = nil
        }
      }
      return s
    }
    let sessionChanged = s.currentSessionId != event.sessionId
    if event.agentId == nil {
      if s.currentSessionId != event.sessionId {
        s.currentSessionId = event.sessionId
        s.title = nil
        s.lastAssistantSnippet = nil
        s.currentTool = nil
        s.attentionMessage = nil
        s.runningSubagents = 0
        s.model = nil
        s.gitBranch = nil
        s.usage = nil
        s.transcriptPath = event.transcriptPath
        s.unread = false
        s.state = .idle
        s.endedAt = nil
      }
      if let cwd = event.cwd {
        s.cwd = cwd
        s.projectName = Session.projectName(cwd: cwd)
      }
      if let path = event.transcriptPath { s.transcriptPath = path }
      s.terminal.merge(event.terminal)
      s.source = .hooks
    }
    s.lastEventAt = max(s.lastEventAt, event.at)
    switch event.type {
    case .sessionStart(let reason):
      if sessionChanged || reason != "compact" {
        s.state = .idle
        s.endedAt = nil
        s.currentTool = nil
        s.attentionMessage = nil
        s.unread = false
      }
    case .promptSubmitted:
      s.state = .working
      s.unread = false
      s.attentionMessage = nil
      s.currentTool = nil
      s.endedAt = nil
    case .toolStart(let name, let summary):
      s.currentTool = singleLine(name + (summary.map { ": " + $0 } ?? ""), limit: 80)
      if name == "AskUserQuestion" || name == "ExitPlanMode" {
        s.state = .needsInput
        s.attentionMessage = name == "AskUserQuestion" ? "等待回答问题" : "等待确认计划"
      } else {
        s.state = .working
        s.attentionMessage = nil
      }
    case .toolEnd:
      s.state = .working
      s.attentionMessage = nil
      s.currentTool = nil
    case .permissionRequested(let tool, let message):
      if tool == "AskUserQuestion" || tool == "ExitPlanMode" {
        s.state = .needsInput
        s.attentionMessage = tool == "AskUserQuestion" ? "等待回答问题" : "等待确认计划"
      } else {
        s.state = .needsPermission
        s.attentionMessage = singleLine(message ?? "请求权限: \(tool ?? "未知工具")", limit: 80)
      }
    case .notification(let kind, let message):
      if kind == "permission_prompt" {
        // needsInput keeps its specific prompt ("等待回答问题"); the generic text would read as a permission request.
        if s.state == .needsPermission, let message {
          s.attentionMessage = singleLine(message, limit: 80)
        }
      } else if kind == "idle_prompt", s.state == .working {
        s.state = .needsInput
        s.attentionMessage = singleLine(message ?? "等待输入", limit: 80)
      }
    case .subagentStart:
      s.runningSubagents += 1
      if s.state == .idle { s.state = .working }
    case .subagentStop:
      s.runningSubagents = max(0, s.runningSubagents - 1)
    case .compacting:
      if priorState == .working {
        s.state = .working
        s.currentTool = "压缩上下文"
      }
    case .stop:
      s.state = .done
      s.unread = true
      s.currentTool = nil
      s.attentionMessage = nil
      if let message = event.assistantMessage, !message.isEmpty {
        s.lastAssistantSnippet = singleLine(plainText(message), limit: 120)
      }
    case .interrupted:
      s.state = .idle
      s.unread = false
      s.currentTool = nil
      s.attentionMessage = nil
    case .sessionEnd:
      s.state = .ended
      s.endedAt = event.at
      s.currentTool = nil
      s.attentionMessage = nil
    }
    if s.state != priorState { s.stateSince = event.at }
    return s
  }
}
