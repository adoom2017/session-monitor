import Darwin
import Foundation
import SMCore

do {
  guard CommandLine.arguments.count == 2 else {
    throw MonitorError.invalid("usage: sm-hook <claude|codex|pi|agy|agy-context>")
  }
  let command = CommandLine.arguments[1]
  let home: URL
  if let configured = ProcessInfo.processInfo.environment["HOME"] {
    home = URL(fileURLWithPath: configured, isDirectory: true)
  } else {
    throw MonitorError.invalid("HOME is unset")
  }
  // Bounded stdin; invalid or missing payloads are errors, never successful no-ops.
  let input = FileHandle.standardInput.readData(ofLength: 1_048_577)
  guard !input.isEmpty, input.count <= 1_048_576 else {
    throw MonitorError.invalid("stdin size must be 1...1MB")
  }
  if command == "agy-context" {
    if let agent = try ProcessIdentity.findAgent(kind: .agy, home: home) {
      try AgyContext.record(input, home: home, pid: agent.pid)
    }
    try AgyQuota.record(input, home: home)
    exit(EXIT_SUCCESS)
  }
  guard let kind = AgentKind(rawValue: command) else {
    throw MonitorError.invalid("usage: sm-hook <claude|codex|pi|agy|agy-context>")
  }
  let payload = try JSONDecoder().decode(JSONValue.self, from: input)
  guard payload.object != nil else { throw MonitorError.invalid("hook payload must be an object") }
  // Phase-two payload capture: while ~/.session-monitor/capture/<kind>/ exists, keep the raw
  // payload and the hook's ancestor chain (which process runs hooks). Best effort, local only.
  let captureDirectory = home.appendingPathComponent(".session-monitor/capture/\(kind.rawValue)")
  if FileManager.default.fileExists(atPath: captureDirectory.path) {
    do {
      var chain: [String] = []
      var pid = getppid()
      for _ in 0..<8 where pid > 1 {
        let process = try ProcessIdentity.read(pid)
        chain.append("\(process.pid) \(process.executable) tty=\(process.tty ?? "-")")
        pid = process.parent
      }
      let eventKey = kind == .agy ? "hookEventName" : "hook_event_name"
      let event = payload[eventKey]?.string ?? "unknown"
      let stamp = Int(Date().timeIntervalSince1970 * 1000)
      let base = captureDirectory.appendingPathComponent("\(stamp)-\(event)-\(UUID().uuidString.prefix(8))")
      try input.write(to: base.appendingPathExtension("json"), options: [.withoutOverwriting])
      try Data((chain.joined(separator: "\n") + "\n").utf8).write(
        to: base.appendingPathExtension("chain"), options: [.withoutOverwriting])
    } catch {
      FileHandle.standardError.write(Data("sm-hook: capture failed: \(error.localizedDescription)\n".utf8))
    }
  }
  let agent = try ProcessIdentity.findAgent(kind: kind, home: home)
  // The global Antigravity config is shared with the desktop product.
  // Empty stdout + exit 0 is observation-only passthrough on all agy hooks (including PreToolUse).
  if kind == .agy, agent == nil {
    exit(EXIT_SUCCESS)
  }
  let environment = ProcessInfo.processInfo.environment
  var values: [String: String?] = [:]
  for key in ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "ITERM_SESSION_ID"] {
    values.updateValue(environment[key], forKey: key)
  }
  values.updateValue(agent?.tty, forKey: "TTY")
  var envelope = HookEnvelope(
    source: kind.rawValue, agentPid: agent?.pid, env: values, payload: payload)
  let runtime = home.appendingPathComponent(".session-monitor")
  if agent == nil {
    let warning = "agent ancestor not found; using session_id identity"
    envelope.diagnostics = [warning]
    envelope.diagnosticLevel = .info
  } else if agent?.matchedByName == true {
    let warning = "ancestor session file missing; agent PID located by executable name"
    envelope.diagnostics = [warning]
    envelope.diagnosticLevel = .info
  }
  do {
    try SocketClient.send(
      JSONEncoder().encode(envelope), to: runtime.appendingPathComponent("sm.sock").path)
  } catch {
    let warning = "socket delivery failed (\(error.localizedDescription)); event queued to spool"
    envelope.diagnostics = (envelope.diagnostics ?? []) + [warning]
    // App not running is expected; the event is preserved, so this is a warning, not an error.
    envelope.diagnosticLevel = .warning
    do { try SpoolQueue.append(envelope, directory: runtime) } catch let spoolError {
      throw MonitorError.invalid(
        "\(warning); spool write also failed: \(spoolError.localizedDescription)")
    }
  }
  // Delivery is committed before best-effort diagnostics; logging cannot lose events.
  for diagnostic in envelope.diagnostics ?? [] {
    do { try HookDiagnostics.record(diagnostic, directory: runtime) } catch {
      FileHandle.standardError.write(
        Data(("hook diagnostic log failed: \(error.localizedDescription)\n").utf8))
    }
  }
} catch {
  let message = "sm-hook: \(error.localizedDescription)\n"
  if let home = ProcessInfo.processInfo.environment["HOME"] {
    do {
      try HookDiagnostics.record(
        error.localizedDescription,
        directory: URL(fileURLWithPath: home).appendingPathComponent(".session-monitor"))
    } catch {
      FileHandle.standardError.write(
        Data((message + "hook diagnostic log also failed: \(error.localizedDescription)\n").utf8))
    }
  } else {
    FileHandle.standardError.write(Data(message.utf8))
  }
  exit(EXIT_FAILURE)
}
