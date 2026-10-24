import Foundation
import SMProtocol

/// Why a remote action was not performed; the message is shown on the phone as is.
public struct RemoteRejection: Error, LocalizedError, Sendable, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// Input into, and pictures of, the tmux pane a session runs in (DEV_SPEC §17.5). Only sessions
/// with a tmux pane qualify; every action first proves the pane still hosts that session.
public enum TmuxRemote {
  public static func canSend(_ session: Session) -> Bool {
    session.terminal.tmuxPane != nil && session.pid != nil && session.state != .ended
  }

  struct Target: Sendable {
    let executable: String
    let base: [String]
    let pane: String
  }

  /// Resolves the pane and checks its shell is an ancestor of the session's process, so a pane
  /// reused by another program never receives the input.
  static func target(for session: Session) async throws -> Target {
    guard let pane = session.terminal.tmuxPane, let pid = session.pid else {
      throw RemoteRejection("该会话不在 tmux 中，只能查看")
    }
    guard session.state != .ended else { throw RemoteRejection("会话已结束") }
    guard pane.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil else {
      throw MonitorError.invalid("tmux pane identifier")
    }
    let executable = try Jumper.tmuxExecutable()
    let base = session.terminal.tmuxSocket.map { ["-S", $0] } ?? []
    let output: String
    do {
      output = try await Jumper.runTmux(executable, base + ["display-message", "-p", "-t", pane, "#{pane_pid}"]).stdout
    } catch { throw RemoteRejection("tmux 窗格 \(pane) 已不存在") }
    guard let panePID = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw MonitorError.invalid("tmux pane_pid output")
    }
    guard try isAncestor(panePID, of: pid) else {
      throw RemoteRejection("tmux 窗格 \(pane) 里运行的已不是这个会话，已拒绝发送")
    }
    return Target(executable: executable, base: base, pane: pane)
  }

  static func isAncestor(_ ancestor: Int32, of pid: Int32, parent: (Int32) throws -> Int32 = { try ProcessIdentity.read($0).parent }) throws -> Bool {
    var current = pid
    for _ in 0..<64 {
      if current == ancestor { return true }
      if current <= 1 { return false }
      current = try parent(current)
    }
    return false
  }

  /// The visible pane text, wrapped lines joined, trailing blank lines dropped.
  public static func capture(_ session: Session) async throws -> String {
    let target = try await target(for: session)
    return try await capture(target)
  }

  static func capture(_ target: Target) async throws -> String {
    let text = try await Jumper.runTmux(
      target.executable, target.base + ["capture-pane", "-p", "-J", "-t", target.pane]
    ).stdout
    var lines = text.components(separatedBy: "\n")
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    return lines.joined(separator: "\n")
  }

  public struct Screen: Sendable, Equatable {
    /// Lines as laid out in the pane, with SGR escapes.
    public let styled: String
    public let plain: String
    public let columns: Int
  }

  /// The pane as the user sees it: original line breaks (no joining), colors kept.
  public static func screen(_ session: Session) async throws -> Screen {
    let target = try await target(for: session)
    let width = try await Jumper.runTmux(
      target.executable, target.base + ["display-message", "-p", "-t", target.pane, "#{pane_width}"]
    ).stdout
    let text = try await Jumper.runTmux(
      target.executable, target.base + ["capture-pane", "-p", "-e", "-t", target.pane]
    ).stdout
    var lines = text.components(separatedBy: "\n")
    while let last = lines.last, ANSI.strip(last).trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    let styled = lines.joined(separator: "\n")
    return Screen(
      styled: styled, plain: ANSI.strip(styled),
      columns: Int(width.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 80)
  }

  /// Bracketed paste of the text, then Enter (R0: both agents submit it unchanged). Refused while
  /// a numbered menu is on screen: Enter would pick its default option (R0 incident).
  /// `submitted` tells whether the agent took the prompt (a hook moved the session to working).
  /// An Enter that arrives while the TUI is still absorbing the paste is lost (seen in R1), so
  /// Enter waits for the text to show, and is repeated once if the text is still in the input.
  public static func sendText(
    _ text: String, to session: Session, submitted: @escaping @Sendable () async -> Bool
  ) async throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RemoteRejection("消息为空")
    }
    guard text.count <= RemoteProtocol.maxMessageLength else {
      throw RemoteRejection("消息过长（上限 \(RemoteProtocol.maxMessageLength) 字）")
    }
    let target = try await target(for: session)
    if !PaneMenuParser.parse(try await capture(target)).isEmpty {
      throw RemoteRejection("终端正显示一个选择菜单，请先选择菜单选项")
    }
    let buffer = "smremote-\(UUID().uuidString.prefix(8))"
    _ = try await Jumper.runTmux(target.executable, target.base + ["set-buffer", "-b", buffer, "--", text])
    _ = try await Jumper.runTmux(
      target.executable, target.base + ["paste-buffer", "-p", "-d", "-b", buffer, "-t", target.pane])
    let probe = inputProbe(text)
    func pending() async throws -> Bool {
      guard let probe else { return false }
      return try await capture(target).components(separatedBy: "\n").suffix(10)
        .contains { $0.contains(probe) }
    }
    for _ in 0..<10 where try await !pending() { try await Task.sleep(for: .milliseconds(100)) }
    try await Task.sleep(for: .milliseconds(250))
    for attempt in 0..<2 {
      _ = try await Jumper.runTmux(target.executable, target.base + ["send-keys", "-t", target.pane, "Enter"])
      for _ in 0..<8 {
        if await submitted() { return }
        try await Task.sleep(for: .milliseconds(250))
      }
      guard attempt == 0, try await pending() else { return }
    }
  }

  /// A piece of the message that identifies it in the input box: its last non-empty line, cut
  /// short (the box may wrap it). Nil when nothing usable remains.
  static func inputProbe(_ text: String) -> String? {
    guard let line = text.components(separatedBy: "\n").last(where: {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }) else { return nil }
    let probe = String(line.trimmingCharacters(in: .whitespaces).prefix(16))
    return probe.count >= 2 ? probe : nil
  }

  public static func sendKey(_ key: RemoteKey, to session: Session) async throws {
    let target = try await target(for: session)
    _ = try await Jumper.runTmux(target.executable, target.base + ["send-keys", "-t", target.pane, key.rawValue])
  }
}

/// Finds the numbered choice list the agent is waiting on (permission prompt, question, update
/// notice). A list counts only with a selection marker on one option (`❯` Claude, `›` Codex) and
/// near the bottom of the screen, so numbered lists in replies are not mistaken for menus.
public enum PaneMenuParser {
  static let option = try! NSRegularExpression(pattern: #"^\s*(?:([❯›>])\s*)?(\d{1,2})\.\s+(\S.*?)\s*$"#)

  public static func parse(_ text: String) -> [MenuOption] {
    let lines = Array(text.components(separatedBy: "\n").suffix(40))
    var blocks: [(options: [MenuOption], lastLine: Int)] = []
    var current: [MenuOption] = []
    var lastLine = -1
    func close() {
      if current.count >= 2, current.filter(\.selected).count == 1 { blocks.append((current, lastLine)) }
      current = []
    }
    for (index, line) in lines.enumerated() {
      let range = NSRange(line.startIndex..., in: line)
      if let match = option.firstMatch(in: line, range: range),
        let numberRange = Range(match.range(at: 2), in: line),
        let labelRange = Range(match.range(at: 3), in: line),
        let number = Int(line[numberRange])
      {
        let item = MenuOption(
          number: number, label: String(line[labelRange]),
          selected: match.range(at: 1).location != NSNotFound)
        if number == 1 {
          close()
          current = [item]
          lastLine = index
        } else if current.last?.number == number - 1 {
          current.append(item)
          lastLine = index
        } else {
          close()
        }
      } else if !current.isEmpty, index == lastLine + 1, line.hasPrefix("   "),
        !line.trimmingCharacters(in: .whitespaces).isEmpty
      {
        // A long option continues on the next, more indented line.
        current[current.count - 1].label += " " + line.trimmingCharacters(in: .whitespaces)
        lastLine = index
      }
    }
    close()
    guard let block = blocks.last, lines.count - 1 - block.lastLine <= 8 else { return [] }
    return block.options
  }
}

enum ANSI {
  /// CSI sequences (colors, cursor…) and OSC sequences (titles, links).
  static let pattern = try! NSRegularExpression(
    pattern: "\u{1B}\\[[0-9;:?<=>]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]")

  static func strip(_ text: String) -> String {
    pattern.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
  }
}

