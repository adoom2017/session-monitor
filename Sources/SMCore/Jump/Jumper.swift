import Foundation

public enum JumpTarget: Sendable, Equatable {
  case tmux(pane: String, socket: String?, termProgram: String?)
  case iTerm(uuid: String)
  /// Not in tmux and no iTerm session id: locate the terminal tab by tty and/or directory.
  case local(cwd: String?, tty: String?, termProgram: String?)
  case app(termProgram: String)
}

/// What the activator may use to focus the exact tab after choosing the terminal app.
public enum FocusHint: Sendable, Equatable {
  case none
  case tmux(TmuxSelection)
  case local(cwd: String?, tty: String?)
}

/// A terminal tab/session as reported by the terminal's AppleScript API.
public struct TerminalCandidate: Sendable, Equatable {
  public var id: String
  public var tty: String?
  public var cwd: String?
  public var name: String
  public init(id: String, tty: String? = nil, cwd: String? = nil, name: String) {
    self.id = id
    self.tty = tty
    self.cwd = cwd
    self.name = name
  }
}

public enum LocalMatch: Sendable, Equatable {
  case match(String)
  case ambiguous(Int)
  case none
}

public struct TmuxClient: Sendable, Equatable {
  public var tty: String
  public var activity: Int64
  public var session: String
  /// Terminal's self-identification from tmux `client_termtype`, e.g. "ghostty 1.3.1", "iTerm2 3.7.4".
  public var termType: String = ""
}

/// What to do when no terminal tab is attached to the target tmux session.
public enum DetachedTmuxAction: String, Sendable, CaseIterable {
  /// Switch the most recently active tmux client (another tab) to the session.
  case switchRecent
  /// Open a new terminal tab that attaches to the session.
  case newTab
}

/// Thrown when the user dismisses the detached-session choice; not an error to report.
public struct JumpCancelled: Error { public init() {} }

/// Where the selected pane is now displayed: the tmux client (outer terminal tab) showing it.
public struct TmuxSelection: Sendable, Equatable {
  public var session: String
  public var switchedClient: Bool
  public var clientTTY: String
  public var termType: String
  /// No tab shows the session yet: the activator must open one running `attachCommand`.
  public var openInNewTab: Bool
  public var attachCommand: String
  public init(
    session: String, switchedClient: Bool, clientTTY: String, termType: String,
    openInNewTab: Bool = false, attachCommand: String = ""
  ) {
    self.session = session
    self.switchedClient = switchedClient
    self.clientTTY = clientTTY
    self.termType = termType
    self.openInNewTab = openInNewTab
    self.attachCommand = attachCommand
  }
}

public enum Jumper {
  /// Apps launched by Finder/LaunchServices get an almost empty environment (no TERM, no LANG).
  /// tmux then assumes a non-UTF-8 client and replaces non-printable characters in format output
  /// (tabs become "_"), breaking parsing and non-ASCII names. `-u` (verified to be the decisive
  /// fix on tmux 3.8) plus a UTF-8 locale makes every call independent of how the app started.
  public static func runTmux(
    _ executable: String, _ arguments: [String], inheritEnvironment: Bool = true
  ) async throws -> CommandResult {
    var environment = ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]
    if !inheritEnvironment { environment["HOME"] = NSHomeDirectory() }
    return try await ProcessRunner.run(
      executable, arguments: ["-u"] + arguments, environment: environment,
      inheritEnvironment: inheritEnvironment)
  }

  /// The first AppleScript call per terminal waits on macOS's Automation consent prompt.
  public static let appleScriptTimeout: TimeInterval = 30

  public static func target(for session: Session) throws -> JumpTarget {
    if let pane = session.terminal.tmuxPane {
      guard pane.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil else {
        throw MonitorError.invalid("tmux pane identifier")
      }
      return .tmux(
        pane: pane, socket: session.terminal.tmuxSocket, termProgram: session.terminal.termProgram)
    }
    if let value = session.terminal.itermSessionId {
      let id = String(value.split(separator: ":").last ?? "")
      guard UUID(uuidString: id) != nil else { throw MonitorError.invalid("iTerm session UUID") }
      return .iTerm(uuid: id)
    }
    if session.cwd != nil || session.terminal.tty != nil || session.pid != nil {
      return .local(
        cwd: session.cwd, tty: session.terminal.tty, termProgram: session.terminal.termProgram)
    }
    guard let program = session.terminal.termProgram else {
      throw MonitorError.invalid("no exact jump target for \(session.id)")
    }
    return .app(termProgram: program)
  }

  public static func tmuxExecutable(
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
  ) throws -> String {
    let candidates =
      ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
      + path.split(separator: ":").map { String($0) + "/tmux" }
    guard let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { throw MonitorError.invalid("tmux executable not found") }
    return result
  }

  /// Selects `pane` without hijacking other tabs.
  /// - If a client is already attached to the pane's session (one terminal tab per session), only
  ///   window/pane are selected inside that session; no client is switched.
  /// - Otherwise the most recently active client is switched to the pane (single-window workflow).
  /// Returns the session name, which `set-titles-string "#S"` makes the outer tab's title.
  @discardableResult
  public static func selectTmux(
    pane: String, socket: String?,
    whenDetached: @MainActor (_ session: String) async throws -> DetachedTmuxAction = { _ in .switchRecent }
  ) async throws -> TmuxSelection {
    let executable = try await Task.detached(priority: .utility) { try tmuxExecutable() }.value
    let base = socket.map { ["-S", $0] } ?? []
    let session = try await Jumper.runTmux(executable, base + ["display-message", "-p", "-t", pane, "#{session_name}"]
    ).stdout.trimmingCharacters(in: .newlines)
    guard !session.isEmpty else { throw MonitorError.invalid("tmux pane has no session") }
    let clients = try await Jumper.runTmux(executable, base + [
        "list-clients", "-F", "#{client_tty}\t#{client_activity}\t#{client_session}\t#{client_termtype}",
      ])
    let parsed = try parseClients(clients.stdout)
    let recent = parsed.max(by: { $0.activity < $1.activity })
    var selection: TmuxSelection
    if let attached = parsed.filter({ $0.session == session }).max(by: { $0.activity < $1.activity }) {
      selection = TmuxSelection(
        session: session, switchedClient: false, clientTTY: attached.tty,
        termType: attached.termType)
    } else {
      // Without any client there is nothing to switch, so a new tab is the only option.
      let action = recent == nil ? .newTab : try await whenDetached(session)
      switch action {
      case .switchRecent:
        guard let recent else { throw MonitorError.invalid("tmux has no attached client") }
        _ = try await Jumper.runTmux(executable, base + ["switch-client", "-c", recent.tty, "-t", pane])
        selection = TmuxSelection(
          session: session, switchedClient: true, clientTTY: recent.tty, termType: recent.termType)
      case .newTab:
        selection = TmuxSelection(
          session: session, switchedClient: false, clientTTY: "", termType: recent?.termType ?? "",
          openInNewTab: true,
          attachCommand: attachCommand(executable: executable, socket: socket, session: session))
      }
    }
    // Inside the session, so a newly attached tab also lands on the pane.
    for arguments in [["select-window", "-t", pane], ["select-pane", "-t", pane]] {
      _ = try await Jumper.runTmux(executable, base + arguments)
    }
    return selection
  }

  /// Shell command typed into the new tab; `=name` makes tmux match the session name exactly.
  public static func attachCommand(executable: String, socket: String?, session: String) -> String {
    ([executable] + (socket.map { ["-S", $0] } ?? []) + ["attach-session", "-t", "=" + session])
      .map(shellQuote).joined(separator: " ")
  }

  public static func shellQuote(_ value: String) -> String {
    if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "/._-=%+:@".contains($0) }) {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Opens a tab (or a window when none exists) in the given terminal and types `command`.
  /// The command is passed as argv, never interpolated into the script.
  public static func openTab(bundle: String, command: String) async throws {
    let script: String
    switch bundle {
    case "com.mitchellh.ghostty":
      script = """
        on run argv
          tell application id "com.mitchellh.ghostty"
            -- `command` runs via the shell; `initial input` was dropped before the shell was
            -- ready (verified on Ghostty 1.3.1). The tab closes when tmux detaches.
            set cfg to new surface configuration
            set command of cfg to (item 1 of argv)
            if (count of windows) > 0 then
              new tab in front window with configuration cfg
            else
              new window with configuration cfg
            end if
            activate
          end tell
        end run
        """
    case "com.googlecode.iterm2":
      script = """
        on run argv
          -- `command` parses shell quoting; `write text` into a brand-new tab was lost before
          -- the shell started (verified on iTerm2 3.7.4).
          tell application id "com.googlecode.iterm2"
            if (count of windows) > 0 then
              tell current window to create tab with default profile command (item 1 of argv)
            else
              create window with default profile command (item 1 of argv)
            end if
            activate
          end tell
        end run
        """
    default:
      throw MonitorError.unsupported("opening a new tab in \(bundle)")
    }
    _ = try await ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script, command], timeout: Jumper.appleScriptTimeout)
  }


  public static func parseClients(_ output: String) throws -> [TmuxClient] {
    try output.split(separator: "\n").map { line in
      let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
      guard fields.count >= 3, let activity = Int64(fields[1]) else {
        throw MonitorError.invalid("tmux client list")
      }
      return TmuxClient(
        tty: String(fields[0]), activity: activity, session: String(fields[2]),
        termType: fields.count == 4 ? String(fields[3]) : "")
    }
  }

  /// Focuses the Ghostty terminal whose title equals `title` (needs Ghostty 1.3+ AppleScript).
  /// Returns whether Ghostty reports that terminal as focused in its front window afterwards.
  @discardableResult
  public static func focusGhostty(title: String) async throws -> Bool {
    try await focusGhosttyTerminal(by: "name", value: title)
  }

  /// Looping `repeat with w in windows` yields index-based references ("item 2 of every window")
  /// that point at another window once a selection reorders windows. So the loop only collects
  /// string ids, and every command then uses stable `window id` / `tab id` / `terminal id`
  /// specifiers. `focus` alone does not raise a window in another tab group, hence
  /// `activate window` + `select tab` + `focus`. Values are passed as argv, never interpolated.
  static func focusGhosttyTerminal(by mode: String, value: String) async throws -> Bool {
    let script = """
      on run argv
        set mode to item 1 of argv
        set target to item 2 of argv
        tell application id "com.mitchellh.ghostty"
          set sid to missing value
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in terminals of t
                if sid is missing value then
                  if mode is "id" then
                    set found to ((id of s) is target)
                  else
                    set found to ((name of s) is target)
                  end if
                  if found then
                    set sid to id of s
                    set wid to id of w
                    set tid to id of t
                  end if
                end if
              end repeat
            end repeat
          end repeat
          if sid is missing value then error "Ghostty terminal " & target & " not found"
          set win to window id wid
          activate window win
          select tab (tab id tid of win)
          focus terminal id sid
          activate
          delay 0.2
          return ((id of focused terminal of selected tab of front window) is sid) as text
        end tell
      end run
      """
    let result = try await ProcessRunner.run(
      "/usr/bin/osascript", arguments: ["-e", script, mode, value], timeout: Jumper.appleScriptTimeout)
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
  }





  /// The tmux pane whose pty is `tty` on the default server (nil when not inside tmux).
  public static func tmuxPane(forTTY tty: String) async throws -> String? {
    let executable: String
    do { executable = try await Task.detached(priority: .utility) { try tmuxExecutable() }.value } catch {
      return nil  // tmux not installed: the process cannot be in a tmux pane.
    }
    let result: CommandResult
    do {
      result = try await Jumper.runTmux(executable, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
    } catch { return nil }  // No tmux server running.
    for line in result.stdout.split(separator: "\n") {
      let fields = line.split(separator: " ")
      if fields.count == 2, fields[0] == tty { return String(fields[1]) }
    }
    return nil
  }

  public static func activeTmuxPane(socket: String?) async throws -> String {
    let base = socket.map { ["-S", $0] } ?? []
    let executable = try await Task.detached(priority: .utility) { try tmuxExecutable() }.value
    let result = try await Jumper.runTmux(executable, base + ["display", "-p", "#{pane_id}"])
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func selectITerm(uuid: String) async throws {
    guard UUID(uuidString: uuid) != nil else { throw MonitorError.invalid("iTerm UUID") }
    try await selectITermSession(property: "id", value: uuid)
  }

  /// Exact match: a tmux client's tty is the tty of the iTerm2 session hosting it.
  public static func selectITerm(tty: String) async throws {
    guard tty.hasPrefix("/dev/") else { throw MonitorError.invalid("iTerm tty") }
    try await selectITermSession(property: "tty", value: tty)
  }

  /// Values are passed as argv, never interpolated into the script.
  private static func selectITermSession(property: String, value: String) async throws {
    let script = """
      on run argv
        set mode to item 1 of argv
        set target to item 2 of argv
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if mode is "id" then
                  set found to (unique id of s is target)
                else
                  set found to (tty of s is target)
                end if
                if found then
                  -- innermost first: selecting the window reorders windows and would
                  -- invalidate index-based references to t and s
                  select s
                  select t
                  select w
                  activate
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        error "Target iTerm session not found"
      end run
      """
    _ = try await ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script, property, value], timeout: Jumper.appleScriptTimeout)
  }
}

extension Jumper {
  /// tty is exact; directory may be shared, so ties are broken by a Claude-set title ("✳ …").
  public static func pickLocal(_ candidates: [TerminalCandidate], cwd: String?, tty: String?)
    -> LocalMatch
  {
    if let tty {
      let byTTY = candidates.filter { $0.tty == tty }
      if byTTY.count == 1 { return .match(byTTY[0].id) }
    }
    guard let cwd = normalizedPath(cwd) else { return .none }
    let byDirectory = candidates.filter { normalizedPath($0.cwd) == cwd }
    if byDirectory.count == 1 { return .match(byDirectory[0].id) }
    if byDirectory.isEmpty { return .none }
    let claude = byDirectory.filter { isClaudeTitle($0.name) }
    if claude.count == 1 { return .match(claude[0].id) }
    return .ambiguous(byDirectory.count)
  }

  /// Claude Code titles its terminal "✳ <topic>" when idle and a spinner glyph while busy.
  public static func isClaudeTitle(_ name: String) -> Bool {
    guard let first = name.trimmingCharacters(in: .whitespaces).unicodeScalars.first else {
      return false
    }
    return "✳✶✻✽✢·".unicodeScalars.contains(first) || (0x2800...0x28FF).contains(first.value)
  }

  static func normalizedPath(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
  }

  /// Fields are separated by ASCII US (31) and records by RS (30), which titles cannot contain.
  static func parseCandidates(_ output: String, fields: [WritableKeyPath<TerminalCandidate, String?>])
    -> [TerminalCandidate]
  {
    output.split(separator: "\u{1E}").compactMap { record in
      let values = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .newlines)
      }
      guard values.count == fields.count + 2, !values[0].isEmpty else { return nil }
      var candidate = TerminalCandidate(id: values[0], name: values[1])
      for (index, key) in fields.enumerated() {
        let value = values[index + 2]
        candidate[keyPath: key] = value.isEmpty || value == "missing value" ? nil : value
      }
      return candidate
    }
  }

  public static func ghosttyTerminals() async throws -> [TerminalCandidate] {
    let script = """
      set out to ""
      tell application id "com.mitchellh.ghostty"
        repeat with s in terminals
          set out to out & (id of s) & (character id 31) & (name of s) & (character id 31) & (working directory of s) & (character id 30)
        end repeat
      end tell
      return out
      """
    let result = try await ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script], timeout: Jumper.appleScriptTimeout)
    return parseCandidates(result.stdout, fields: [\.cwd])
  }

  @discardableResult
  public static func focusGhostty(id: String) async throws -> Bool {
    try await focusGhosttyTerminal(by: "id", value: id)
  }



  public static func iTermSessions() async throws -> [TerminalCandidate] {
    let script = """
      set out to ""
      tell application id "com.googlecode.iterm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              set p to ""
              try
                tell s to set p to (variable named "path")
              end try
              if p is missing value then set p to ""
              set out to out & (unique id of s) & (character id 31) & (name of s) & (character id 31) & (tty of s) & (character id 31) & p & (character id 30)
            end repeat
          end repeat
        end repeat
      end tell
      return out
      """
    let result = try await ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script], timeout: Jumper.appleScriptTimeout)
    // iTerm2's "path" variable stays at the start directory without shell integration (verified
    // on 3.7.4), so prefer the kernel's cwd of the foreground process on each session's tty.
    return parseCandidates(result.stdout, fields: [\.tty, \.cwd]).map { candidate in
      var updated = candidate
      if let tty = candidate.tty, let cwd = ProcessIdentity.foregroundCwd(tty: tty) {
        updated.cwd = cwd
      }
      return updated
    }
  }
}

public enum TerminalPolicy {
  public static let preferredBundles = [
    "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal",
  ]
  public static func bundleID(_ program: String) -> String? {
    switch program {
    case "ghostty": "com.mitchellh.ghostty"
    case "iTerm.app": "com.googlecode.iterm2"
    case "Apple_Terminal": "com.apple.Terminal"
    case "vscode": "com.microsoft.VSCode"
    case CodexSource.desktopProgram: CodexSource.desktopBundleID
    default: nil
    }
  }
  /// Maps tmux `client_termtype` ("ghostty 1.3.1", "iTerm2 3.7.4") to the hosting app.
  public static func bundleID(termType: String) -> String? {
    let name = termType.split(separator: " ").first.map { $0.lowercased() } ?? ""
    switch name {
    case "ghostty": return "com.mitchellh.ghostty"
    case "iterm2": return "com.googlecode.iterm2"
    default: return nil
    }
  }

  public static func activationBundle(program: String?, running: Set<String>) throws -> String {
    if let program, program != "tmux" {
      guard let bundle = bundleID(program) else {
        throw MonitorError.unsupported("terminal \(singleLine(program, limit: 80))")
      }
      guard running.contains(bundle) else {
        throw MonitorError.invalid("target terminal is not running")
      }
      return bundle
    }
    guard let bundle = preferredBundles.first(where: running.contains) else {
      throw MonitorError.invalid("no supported terminal is running")
    }
    return bundle
  }
}

/// Shared by the App and integration tests, including the failure/clipboard path.
@MainActor public enum JumpCoordinator {
  public static func jump(
    _ session: Session,
    activate: (_ program: String?, _ hint: FocusHint) async throws -> Void,
    whenDetached: @MainActor (_ tmuxSession: String) async throws -> DetachedTmuxAction = { _ in .switchRecent },
    report: (any Error, String) async -> Void,
    failed: () -> Void,
    copy: (String) -> Void
  ) async {
    func secondary() async throws {
      if let id = session.terminal.itermSessionId {
        do {
          try await Jumper.selectITerm(uuid: String(id.split(separator: ":").last ?? ""))
          return
        } catch { await report(error, "iTerm 定位也失败，仅激活终端") }
      }
      try await activate(session.terminal.termProgram, .local(cwd: session.cwd, tty: localTTY()))
    }
    // Sessions known only from their session file have no hook env; the pid still gives the tty.
    func localTTY() -> String? {
      if let tty = session.terminal.tty { return tty }
      guard let pid = session.pid else { return nil }
      do { return try ProcessIdentity.read(pid).tty } catch { return nil }
    }
    do {
      switch try Jumper.target(for: session) {
      case .tmux(let pane, let socket, let program):
        do {
          let selection = try await Jumper.selectTmux(
            pane: pane, socket: socket, whenDetached: whenDetached)
          try await activate(program, .tmux(selection))
        } catch is JumpCancelled {
          return
        } catch {
          await report(error, "tmux 精确跳转失败，将尝试其他定位方式")
          try await secondary()
        }
      case .iTerm(let uuid):
        do { try await Jumper.selectITerm(uuid: uuid) } catch {
          await report(error, "iTerm 精确定位失败，仅激活终端")
          try await activate(
            session.terminal.termProgram ?? "iTerm.app", .local(cwd: session.cwd, tty: localTTY()))
        }
      case .local(let cwd, _, let program):
        try await activate(program, .local(cwd: cwd, tty: localTTY()))
      case .app(let program): try await activate(program, .none)
      }
    } catch {
      await report(error, "会话跳转失败，已复制 cwd")
      failed()
      if let cwd = session.cwd { copy(cwd) }
    }
  }
}
