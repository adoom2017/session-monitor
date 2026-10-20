import Foundation
import Testing

@testable import SMCore

@Suite struct TmuxTests {
  @Test @MainActor func actualCrossSessionSwitchWithAttachedClient() async throws {
    let executable = try Jumper.tmuxExecutable()
    let directory = URL(fileURLWithPath: "/tmp/sm-tmux-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socket = directory.appendingPathComponent("tmux.sock").path
    func command(_ args: [String]) throws -> CommandResult {
      try ProcessRunner.runSync(executable, arguments: ["-S", socket, "-f", "/dev/null"] + args)
    }
    _ = try command(["new-session", "-d", "-s", "first", "/bin/sleep", "60"])
    defer {
      do {
        _ = try command(["kill-server"])
        try FileManager.default.removeItem(at: directory)
      } catch { Issue.record("tmux cleanup failed: \(error)") }
    }
    _ = try command(["split-window", "-t", "first", "/bin/sleep", "60"])
    _ = try command(["split-window", "-t", "first", "/bin/sleep", "60"])
    _ = try command(["new-session", "-d", "-s", "second", "/bin/sleep", "60"])
    let target = try command(["display-message", "-p", "-t", "second", "#{pane_id}"]).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let client = Process()
    client.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    client.arguments = [
      "-q", "/dev/null", executable, "-S", socket, "attach-session", "-t", "first",
    ]
    client.environment = ProcessInfo.processInfo.environment.merging(["TERM": "xterm-256color"]) {
      _, new in new
    }
    client.standardInput = Pipe()
    client.standardOutput = FileHandle.nullDevice
    client.standardError = FileHandle.nullDevice
    try client.run()
    defer {
      if client.isRunning { client.terminate() }
      client.waitUntilExit()
    }
    var attached = false
    for _ in 0..<30 {
      if !(try command(["list-clients", "-F", "#{client_tty}"]).stdout).trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty {
        attached = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(attached)
    let session = Session(
      event: AgentEvent(
        sessionId: "tmux", agentPid: 42, cwd: "/do-not-copy",
        type: .sessionStart(reason: "startup"),
        terminal: TerminalInfo(tmuxPane: target, tmuxSocket: socket, termProgram: "tmux")))
    var activated: String?
    var copied: String?
    var failed = false
    var errors: [String] = []
    await JumpCoordinator.jump(
      session,
      activate: { program, hint in
        if case .tmux(let tmux) = hint { #expect(tmux.session == "second") } else {
          Issue.record("expected tmux hint")
        }
        activated = try TerminalPolicy.activationBundle(
          program: program, running: ["com.apple.Terminal", "com.mitchellh.ghostty"])
      }, report: { error, _ in errors.append(error.localizedDescription) },
      failed: { failed = true }, copy: { copied = $0 })
    #expect(activated == "com.mitchellh.ghostty")
    #expect(copied == nil)
    #expect(!failed && errors.isEmpty)
    #expect(try await Jumper.activeTmuxPane(socket: socket) == target)
  }

  /// One terminal tab per tmux session: the click must select the pane inside the session that is
  /// already displayed somewhere, and must not switch the most recently active client (another tab).
  @Test @MainActor func attachedSessionIsSelectedWithoutHijackingActiveClient() async throws {
    let executable = try Jumper.tmuxExecutable()
    let directory = URL(fileURLWithPath: "/tmp/sm-tmux-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socket = directory.appendingPathComponent("tmux.sock").path
    func command(_ args: [String]) throws -> String {
      try ProcessRunner.runSync(executable, arguments: ["-S", socket, "-f", "/dev/null"] + args)
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try command(["new-session", "-d", "-s", "first", "/bin/sleep", "60"])
    var clients: [Process] = []
    defer {
      for client in clients {
        if client.isRunning { client.terminate() }
        client.waitUntilExit()
      }
      do {
        _ = try command(["kill-server"])
        try FileManager.default.removeItem(at: directory)
      } catch { Issue.record("tmux cleanup failed: \(error)") }
    }
    _ = try command(["new-session", "-d", "-s", "second", "/bin/sleep", "60"])
    _ = try command(["new-window", "-t", "second", "/bin/sleep", "60"])
    _ = try command(["split-window", "-t", "second:1", "/bin/sleep", "60"])
    // Target: first pane of window 1 in "second", which is neither the active window nor pane.
    let target = try command(["display-message", "-p", "-t", "second:1.0", "#{pane_id}"])
    _ = try command(["select-window", "-t", "second:0"])
    func attach(_ name: String) throws {
      let client = Process()
      client.executableURL = URL(fileURLWithPath: "/usr/bin/script")
      client.arguments = ["-q", "/dev/null", executable, "-S", socket, "attach-session", "-t", name]
      client.environment = ProcessInfo.processInfo.environment.merging(["TERM": "xterm-256color"]) {
        _, new in new
      }
      client.standardInput = Pipe()
      client.standardOutput = FileHandle.nullDevice
      client.standardError = FileHandle.nullDevice
      try client.run()
      clients.append(client)
    }
    func clientCount() throws -> Int {
      try command(["list-clients", "-F", "#{client_tty}"]).split(separator: "\n").count
    }
    try attach("second")
    for _ in 0..<40 where try clientCount() < 1 { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .milliseconds(1100))  // client_activity has 1s resolution
    try attach("first")  // most recently active client, like the tab the user is looking at
    for _ in 0..<40 where try clientCount() < 2 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(try clientCount() == 2)

    let selection = try await Jumper.selectTmux(pane: target, socket: socket)
    #expect(selection.session == "second" && !selection.switchedClient)
    #expect(selection.clientTTY.hasPrefix("/dev/"))
    let sessions = try command(["list-clients", "-F", "#{client_session}"]).split(separator: "\n")
    #expect(sessions.sorted() == ["first", "second"])  // no tab was switched to another session
    #expect(try command(["display-message", "-p", "-t", "second", "#{pane_id}"]) == target)
  }

  @Test func clientListParsing() throws {
    #expect(
      try Jumper.parseClients("/dev/ttys004\t1792398377\tclaude clyntis\n")
        == [TmuxClient(tty: "/dev/ttys004", activity: 1_792_398_377, session: "claude clyntis")])
    #expect(
      try Jumper.parseClients("/dev/ttys013\t1\tsm\tiTerm2 3.7.4")
        == [TmuxClient(tty: "/dev/ttys013", activity: 1, session: "sm", termType: "iTerm2 3.7.4")])
    #expect(TerminalPolicy.bundleID(termType: "iTerm2 3.7.4") == "com.googlecode.iterm2")
    #expect(TerminalPolicy.bundleID(termType: "ghostty 1.3.1") == "com.mitchellh.ghostty")
    #expect(TerminalPolicy.bundleID(termType: "") == nil)
    #expect(throws: MonitorError.self) { try Jumper.parseClients("/dev/ttys004 1792398377") }
  }

  @Test func localMatchingPrefersTTYThenDirectoryThenClaudeTitle() {
    let tabs = [
      TerminalCandidate(id: "a", tty: "/dev/ttys001", cwd: "/work/p", name: "zsh"),
      TerminalCandidate(id: "b", tty: "/dev/ttys002", cwd: "/work/p/", name: "✳ 修复登录"),
      TerminalCandidate(id: "c", tty: "/dev/ttys003", cwd: "/work/q", name: "vim"),
    ]
    #expect(Jumper.pickLocal(tabs, cwd: "/work/p", tty: "/dev/ttys001") == .match("a"))  // tty wins
    #expect(Jumper.pickLocal(tabs, cwd: "/work/q", tty: nil) == .match("c"))
    #expect(Jumper.pickLocal(tabs, cwd: "/work/p", tty: nil) == .match("b"))  // Claude title breaks tie
    #expect(Jumper.pickLocal(tabs, cwd: "/work/p", tty: "/dev/ttys999") == .match("b"))
    #expect(Jumper.pickLocal(tabs, cwd: "/elsewhere", tty: nil) == .none)
    let twins = [
      TerminalCandidate(id: "x", cwd: "/w", name: "zsh"),
      TerminalCandidate(id: "y", cwd: "/w", name: "zsh"),
    ]
    #expect(Jumper.pickLocal(twins, cwd: "/w", tty: nil) == .ambiguous(2))
    // Decomposed vs precomposed Unicode paths are the same directory.
    let accented = [TerminalCandidate(id: "u", cwd: "/w/cafe\u{301}", name: "zsh")]
    #expect(Jumper.pickLocal(accented, cwd: "/w/caf\u{e9}", tty: nil) == .match("u"))
  }

  @Test func claudeTitlesAndCandidateParsing() {
    #expect(Jumper.isClaudeTitle("✳ 媒体云端语义索引"))
    #expect(Jumper.isClaudeTitle("⠂ working"))
    #expect(!Jumper.isClaudeTitle("…/work/patent"))
    #expect(!Jumper.isClaudeTitle(""))
    let output = "id1\u{1F}✳ a\u{1F}/dev/ttys1\u{1F}/w\u{1E}id2\u{1F}b\u{1F}/dev/ttys2\u{1F}missing value\u{1E}\n"
    #expect(
      Jumper.parseCandidates(output, fields: [\.tty, \.cwd]) == [
        TerminalCandidate(id: "id1", tty: "/dev/ttys1", cwd: "/w", name: "✳ a"),
        TerminalCandidate(id: "id2", tty: "/dev/ttys2", cwd: nil, name: "b"),
      ])
  }

  @Test func nonTmuxSessionWithoutITermIDTargetsLocal() throws {
    let session = Session(
      event: AgentEvent(
        sessionId: "s", agentPid: 7, cwd: "/w", type: .sessionStart(reason: "startup"),
        terminal: TerminalInfo(termProgram: "ghostty")))
    #expect(try Jumper.target(for: session) == .local(cwd: "/w", tty: nil, termProgram: "ghostty"))
  }

  @Test func kernelCwdOfOwnProcess() {
    #expect(
      ProcessIdentity.cwd(pid: getpid()).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
    #expect(ProcessIdentity.foregroundCwd(tty: "/dev/does-not-exist") == nil)
  }

  @Test func attachCommandQuoting() {
    #expect(Jumper.shellQuote("SerenPing") == "SerenPing")
    #expect(Jumper.shellQuote("my session") == "'my session'")
    #expect(Jumper.shellQuote("it's") == "'it'\\''s'")
    #expect(Jumper.shellQuote("$(rm -rf ~)") == "'$(rm -rf ~)'")
    #expect(
      Jumper.attachCommand(executable: "/opt/homebrew/bin/tmux", socket: nil, session: "a b")
        == "/opt/homebrew/bin/tmux attach-session -t '=a b'")
    #expect(
      Jumper.attachCommand(executable: "/t", socket: "/tmp/s", session: "x")
        == "/t -S /tmp/s attach-session -t =x")
  }

  /// Target session has no attached client while another session does.
  @Test @MainActor func detachedSessionHonorsChoice() async throws {
    let executable = try Jumper.tmuxExecutable()
    let directory = URL(fileURLWithPath: "/tmp/sm-tmux-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socket = directory.appendingPathComponent("tmux.sock").path
    func command(_ args: [String]) throws -> String {
      try ProcessRunner.runSync(executable, arguments: ["-S", socket, "-f", "/dev/null"] + args)
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try command(["new-session", "-d", "-s", "first", "/bin/sleep", "60"])
    _ = try command(["new-session", "-d", "-s", "second", "/bin/sleep", "60"])
    _ = try command(["new-window", "-t", "second", "/bin/sleep", "60"])
    let target = try command(["display-message", "-p", "-t", "second:1", "#{pane_id}"])
    _ = try command(["select-window", "-t", "second:0"])
    let client = Process()
    client.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    client.arguments = ["-q", "/dev/null", executable, "-S", socket, "attach-session", "-t", "first"]
    client.environment = ProcessInfo.processInfo.environment.merging(["TERM": "xterm-256color"]) {
      _, new in new
    }
    client.standardInput = Pipe()
    client.standardOutput = FileHandle.nullDevice
    client.standardError = FileHandle.nullDevice
    try client.run()
    defer {
      if client.isRunning { client.terminate() }
      client.waitUntilExit()
      do {
        _ = try command(["kill-server"])
        try FileManager.default.removeItem(at: directory)
      } catch { Issue.record("tmux cleanup failed: \(error)") }
    }
    for _ in 0..<40 where try command(["list-clients", "-F", "#{client_tty}"]).isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }

    // Cancel: nothing is switched or selected.
    await #expect(throws: JumpCancelled.self) {
      _ = try await Jumper.selectTmux(pane: target, socket: socket) { _ in throw JumpCancelled() }
    }
    #expect(try command(["list-clients", "-F", "#{client_session}"]) == "first")
    #expect(try command(["display-message", "-p", "-t", "second", "#{pane_id}"]) != target)

    // New tab: the existing client stays put; the pane is preselected for the attaching tab.
    var asked: String?
    let selection = try await Jumper.selectTmux(pane: target, socket: socket) { session in
      asked = session
      return .newTab
    }
    #expect(asked == "second")
    #expect(selection.openInNewTab && !selection.switchedClient)
    #expect(selection.attachCommand.hasSuffix("attach-session -t =second"))
    #expect(try command(["list-clients", "-F", "#{client_session}"]) == "first")
    #expect(try command(["display-message", "-p", "-t", "second", "#{pane_id}"]) == target)

    // Switch: the most recent client is moved to the session (previous behavior).
    let switched = try await Jumper.selectTmux(pane: target, socket: socket) { _ in .switchRecent }
    #expect(switched.switchedClient && !switched.openInNewTab)
    #expect(try command(["list-clients", "-F", "#{client_session}"]) == "second")
  }

  @Test @MainActor func noClientsOpensNewTabWithoutAsking() async throws {
    let executable = try Jumper.tmuxExecutable()
    let directory = URL(fileURLWithPath: "/tmp/sm-tmux-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socket = directory.appendingPathComponent("tmux.sock").path
    defer {
      do {
        _ = try ProcessRunner.runSync(executable, arguments: ["-S", socket, "kill-server"])
        try FileManager.default.removeItem(at: directory)
      } catch { Issue.record("tmux cleanup failed: \(error)") }
    }
    _ = try ProcessRunner.runSync(
      executable, arguments: ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "solo", "/bin/sleep", "60"])
    let pane = try ProcessRunner.runSync(
      executable, arguments: ["-S", socket, "display-message", "-p", "-t", "solo", "#{pane_id}"]
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    var asked = false
    let selection = try await Jumper.selectTmux(pane: pane, socket: socket) { _ in
      asked = true
      return .switchRecent
    }
    #expect(!asked)
    #expect(selection.openInNewTab && selection.termType.isEmpty)
  }

  /// Real failure (release app launched from Finder, 2026-10-20): LaunchServices gives apps no LANG,
  /// and tmux then prints tabs in -F output as "_" and mangles non-ASCII names.
  @Test func tmuxOutputSurvivesLaunchServicesEnvironment() async throws {
    let executable = try Jumper.tmuxExecutable()
    let directory = URL(fileURLWithPath: "/tmp/sm-tmux-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socket = directory.appendingPathComponent("tmux.sock").path
    defer {
      _ = try? ProcessRunner.runSync(executable, arguments: ["-S", socket, "kill-server"])
      try? FileManager.default.removeItem(at: directory)
    }
    _ = try await Jumper.runTmux(
      executable, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "美图", "/bin/sleep", "30"])
    // A Finder-launched app passes an almost empty environment to its child processes.
    let format = "#{session_name}\t#{session_windows}"
    let plain = try await ProcessRunner.run(
      executable, arguments: ["-S", socket, "display-message", "-p", "-t", "美图", format],
      environment: ["HOME": NSHomeDirectory()], inheritEnvironment: false)
    #expect(!plain.stdout.contains("\t"))  // documents the tmux behavior being worked around
    let fixed = try await Jumper.runTmux(
      executable, ["-S", socket, "display-message", "-p", "-t", "美图", format],
      inheritEnvironment: false)
    #expect(fixed.stdout.trimmingCharacters(in: .newlines) == "美图\t1")
  }
}
