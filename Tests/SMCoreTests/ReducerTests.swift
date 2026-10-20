import Foundation
import Testing

@testable import SMCore

private let epoch = Date(timeIntervalSince1970: 1_000)
private func event(_ type: EventType, sid: String = "one", seconds: Double = 0) -> AgentEvent {
  AgentEvent(
    sessionId: sid, agentPid: 123, cwd: "/tmp/project", at: epoch.addingTimeInterval(seconds),
    type: type)
}

@Suite struct ReducerTests {
  @Test(arguments: [
    EventType.sessionStart(reason: "startup"), .promptSubmitted,
    .toolStart(name: "Bash", summary: "true"),
    .toolStart(name: "AskUserQuestion", summary: nil),
    .toolStart(name: "ExitPlanMode", summary: nil),
    .toolEnd(name: "Bash"), .permissionRequested(tool: "Bash", message: nil),
    .notification(kind: "permission_prompt", message: "Permission"),
    .notification(kind: "idle_prompt", message: nil),
    .notification(kind: "custom", message: nil), .subagentStart, .subagentStop, .compacting, .stop,
    .sessionEnd(reason: "exit"),
  ]) func transitionTable(_ type: EventType) throws {
    var initial = try SessionReducer.reduce(nil, event(.promptSubmitted))
    initial.runningSubagents = 1
    let result = try SessionReducer.reduce(initial, event(type, seconds: 1))
    switch type {
    case .sessionStart: #expect(result.state == .idle)
    case .promptSubmitted:
      #expect(result.state == .working)
      #expect(!result.unread)
    case .toolStart(let name, _):
      #expect(
        result.state
          == (["AskUserQuestion", "ExitPlanMode"].contains(name) ? .needsInput : .working))
      #expect(result.currentTool != nil)
    case .permissionRequested:
      #expect(result.state == .needsPermission)
    case .notification(kind: "idle_prompt", message: _): #expect(result.state == .needsInput)
    case .stop:
      #expect(result.state == .done)
      #expect(result.unread)
      #expect(result.currentTool == nil)
    case .sessionEnd:
      #expect(result.state == .ended)
      #expect(result.endedAt == epoch.addingTimeInterval(1))
    case .compacting:
      #expect(result.state == .working)
      #expect(result.currentTool == "压缩上下文")
    case .subagentStart: #expect(result.runningSubagents == 2)
    case .subagentStop: #expect(result.runningSubagents == 0)
    default: #expect(result.state == .working)
    }
  }

  @Test func staleEventIsExplicitError() throws {
    let s = try SessionReducer.reduce(nil, event(.stop, seconds: 5))
    #expect(throws: MonitorError.self) {
      try SessionReducer.reduce(s, event(.promptSubmitted, seconds: 2.9))
    }
    let accepted = try SessionReducer.reduce(s, event(.promptSubmitted, seconds: 3))
    #expect(accepted.lastEventAt == epoch.addingTimeInterval(5))
  }

  @Test func permissionExitAllowlist() throws {
    let s = try SessionReducer.reduce(nil, event(.permissionRequested(tool: "Bash", message: nil)))
    for type in [
      EventType.sessionStart(reason: "compact"), .subagentStart, .subagentStop, .compacting,
      .notification(kind: "idle_prompt", message: nil),
    ] {
      #expect(try SessionReducer.reduce(s, event(type, seconds: 1)).state == .needsPermission)
    }
    for type in [
      EventType.toolEnd(name: "Bash"), .toolStart(name: "Read", summary: nil), .stop,
      .promptSubmitted, .sessionEnd(reason: nil),
    ] {
      #expect(try SessionReducer.reduce(s, event(type, seconds: 1)).state != .needsPermission)
    }
  }

  @Test func repeatedPermissionPreservesWaitingTime() throws {
    let s = try SessionReducer.reduce(nil, event(.permissionRequested(tool: "Bash", message: nil)))
    let result = try SessionReducer.reduce(
      s, event(.notification(kind: "permission_prompt", message: "updated"), seconds: 8))
    #expect(result.stateSince == epoch)
    #expect(result.attentionMessage == "updated")
  }

  @Test func inputToolPermissionSequenceFromRealCapture() throws {
    var s: Session?
    for type in [
      EventType.toolStart(name: "AskUserQuestion", summary: nil),
      .permissionRequested(tool: "AskUserQuestion", message: nil),
      .notification(kind: "permission_prompt", message: "needs permission"),
    ] {
      s = try SessionReducer.reduce(s, event(type))
      #expect(s?.state == .needsInput)
      // The generic permission_prompt text must not replace the specific question prompt.
      #expect(s?.attentionMessage == "等待回答问题")
    }
    #expect(
      try SessionReducer.reduce(s, event(.toolEnd(name: "AskUserQuestion"))).state == .working)
  }

  @Test func samePIDNewSessionResetsEnrichment() throws {
    var s = try SessionReducer.reduce(nil, event(.stop))
    s.title = "old"
    s.lastAssistantSnippet = "old"
    s.runningSubagents = 3
    s.currentTool = "old"
    let result = try SessionReducer.reduce(
      s, event(.sessionStart(reason: "clear"), sid: "two", seconds: 1))
    #expect(result.id == s.id)
    #expect(result.currentSessionId == "two")
    #expect(result.title == nil)
    #expect(result.lastAssistantSnippet == nil)
    #expect(result.runningSubagents == 0)
    #expect(result.currentTool == nil)
  }

  @Test func subagentFloorAndBackgroundCompletion() throws {
    var s = try SessionReducer.reduce(nil, event(.subagentStop))
    #expect(s.runningSubagents == 0)
    s = try SessionReducer.reduce(s, event(.subagentStart))
    s = try SessionReducer.reduce(s, event(.stop))
    #expect(s.state == .done)
    #expect(s.runningSubagents == 1)
  }

  @Test func idleNotificationDoesNotChangeDoneOrIdle() throws {
    for type in [EventType.sessionStart(reason: nil), .stop] {
      let s = try SessionReducer.reduce(nil, event(type))
      #expect(
        try SessionReducer.reduce(s, event(.notification(kind: "idle_prompt", message: nil))).state
          == s.state)
    }
  }

  @Test func projectWorktreeAndSorting() throws {
    #expect(Session.projectName(cwd: "/work/project/.claude/worktrees/a") == "project")
    #expect(Session.projectName(cwd: "/work/project/.worktrees/a") == "project")
    let types: [EventType] = [
      .promptSubmitted, .stop, .permissionRequested(tool: "Bash", message: nil),
      .toolStart(name: "AskUserQuestion", summary: nil),
    ]
    let sessions = try types.map { try SessionReducer.reduce(nil, event($0)) }.sorted(
      by: Session.ordered)
    #expect(sessions.map(\.state) == [.needsPermission, .needsInput, .done, .working])
  }

  @MainActor @Test func markReadDoesNotReorder() throws {
    let store = SessionStore()
    let base = Date(timeIntervalSince1970: 1_000)
    for (pid, type) in [(1, EventType.stop), (2, .promptSubmitted), (3, .stop)] {
      try store.apply(AgentEvent(sessionId: "s\(pid)", agentPid: Int32(pid), at: base.addingTimeInterval(Double(pid)), type: type))
    }
    let before = store.sessions.map(\.id)
    store.markRead("claude:3")
    #expect(store.sessions.map(\.id) == before)
    store.markAllRead()
    #expect(store.sessions.map(\.id) == before)
  }
}

@Suite struct ReviewReducerTests {
  @Test func latePermissionNotificationCannotReopenWait() throws {
    var s = try SessionReducer.reduce(nil, event(.permissionRequested(tool: "Bash", message: nil)))
    s = try SessionReducer.reduce(s, event(.toolEnd(name: "Bash"), seconds: 1))
    s = try SessionReducer.reduce(
      s, event(.notification(kind: "permission_prompt", message: "late"), seconds: 6))
    #expect(s.state == .working)
    #expect(s.attentionMessage == nil)
  }
  @Test func clearStartupResumeReleaseStuckPermission() throws {
    let waiting = try SessionReducer.reduce(
      nil, event(.permissionRequested(tool: "Bash", message: "waiting")))
    for reason in ["startup", "resume", "clear"] {
      let result = try SessionReducer.reduce(
        waiting, event(.sessionStart(reason: reason), seconds: 1))
      #expect(result.state == .idle)
      #expect(result.attentionMessage == nil)
    }
    #expect(
      try SessionReducer.reduce(
        waiting, event(.sessionStart(reason: "compact"), sid: "changed", seconds: 1)
      ).state == .idle)
    #expect(
      try SessionReducer.reduce(waiting, event(.sessionStart(reason: "compact"), seconds: 1)).state
        == .needsPermission)
  }
  @Test func backgroundToolsCannotChangeMainMetadataOrUnread() throws {
    for stateEvent in [
      EventType.stop, .permissionRequested(tool: "Bash", message: "waiting"),
      .sessionStart(reason: "startup"), .promptSubmitted,
    ] {
      let initial = try SessionReducer.reduce(nil, event(stateEvent))
      for type in [
        EventType.toolStart(name: "Bash", summary: "child"), .toolEnd(name: "Bash"), .stop,
        .permissionRequested(tool: "Bash", message: "child"),
      ] {
        var child = event(type, seconds: 1)
        child.agentId = "background"
        child.cwd = "/wrong-child-directory"
        child.transcriptPath = "/child.jsonl"
        let result = try SessionReducer.reduce(initial, child)
        #expect(result.state == initial.state)
        #expect(result.unread == initial.unread)
        #expect(result.stateSince == initial.stateSince)
        #expect(result.cwd == initial.cwd)
        #expect(result.transcriptPath == initial.transcriptPath)
        #expect(result.lastEventAt == child.at)
        if initial.state != .working { #expect(result.currentTool == initial.currentTool) }
      }
    }
  }
  @Test func childLifecycleAfterStopPreservesCompletion() throws {
    var s = try SessionReducer.reduce(nil, event(.stop))
    s = try SessionReducer.reduce(s, event(.subagentStop, seconds: 1))
    #expect(s.state == .done && s.unread && s.runningSubagents == 0)
    s = try SessionReducer.reduce(s, event(.subagentStart, seconds: 2))
    #expect(s.state == .done && s.unread && s.runningSubagents == 1)
    let idle = try SessionReducer.reduce(nil, event(.sessionStart(reason: "startup")))
    #expect(try SessionReducer.reduce(idle, event(.subagentStart)).state == .working)
  }
}
