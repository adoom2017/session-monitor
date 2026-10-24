import Foundation
import SMProtocol

// Command-line phone client for testing SessionMonitor's phone access (DEV_SPEC §17, R1).
//
//   sm-remote pair '<sessionmonitor://pair?...>' [--name NAME]
//   sm-remote list
//   sm-remote watch
//   sm-remote transcript <session-id> [--follow]
//   sm-remote pane <session-id>
//   sm-remote send <session-id> <text>
//   sm-remote key <session-id> <Escape|Enter|Up|Down|Tab|1-9>
//
// The pairing is kept in ~/.sm-remote.json (0600), or $SM_REMOTE_CONFIG.

let configURL = URL(
  fileURLWithPath: ProcessInfo.processInfo.environment["SM_REMOTE_CONFIG"]
    ?? NSHomeDirectory() + "/.sm-remote.json")

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("sm-remote: " + message + "\n").utf8))
  exit(1)
}

func loadServer() -> PairedServer {
  guard let data = FileManager.default.contents(atPath: configURL.path),
    let server = try? JSONDecoder().decode(PairedServer.self, from: data)
  else { fail("not paired; run: sm-remote pair '<link>'") }
  return server
}

func saveServer(_ server: PairedServer) throws {
  let data = try JSONEncoder().encode(server)
  FileManager.default.createFile(atPath: configURL.path, contents: data, attributes: [.posixPermissions: 0o600])
}

func connect(_ server: PairedServer) async throws -> RemoteConnection {
  let (connection, _) = try await RemoteConnection.connect(
    hosts: server.hosts, port: server.port, fingerprint: server.fingerprint,
    hello: Hello(deviceName: Host.current().localizedName ?? "sm-remote", token: server.token, pairingCode: nil))
  return connection
}

func describe(_ s: RemoteSession) -> String {
  let input = s.remoteInput ? "tmux" : "view-only"
  var line = "\(s.id)  [\(s.agent)] \(s.name)  \(s.state.rawValue)  \(input)"
  if let tool = s.currentTool { line += "  tool=\(tool)" }
  if let attention = s.attentionMessage { line += "  \(attention)" }
  return line
}

func describe(_ message: ServerMessage) -> String {
  switch message {
  case .welcome(_, let name, let device, _): return "welcome \(name) device=\(device)"
  case .snapshot(let sessions): return "snapshot\n" + sessions.map { "  " + describe($0) }.joined(separator: "\n")
  case .sessionUpdated(let s): return "updated  " + describe(s)
  case .sessionRemoved(let id): return "removed  \(id)"
  case .transcript(let id, let entries, let reset, let hasOlder):
    return "transcript \(id) reset=\(reset) older=\(hasOlder)\n"
      + entries.map { "  [\($0.role.rawValue)] \($0.text.replacingOccurrences(of: "\n", with: "\n      "))" }
      .joined(separator: "\n")
  case .transcriptOlder(let id, let entries, let hasOlder):
    return "older \(id) \(entries.count) entries, more=\(hasOlder)"
  case .pane(let pane):
    let menu = pane.menu.map { "  \($0.selected ? "›" : " ") \($0.number). \($0.label)" }.joined(separator: "\n")
    return "pane \(pane.sessionId)\n\(pane.text)\n--- menu (\(pane.menu.count))\n\(menu)"
  case .actionResult(let id, let status, let message): return "result \(id) \(status.rawValue) \(message ?? "")"
  case .error(let message): return "error \(message)"
  }
}

/// Prints messages until `stop` returns true for one of them.
func run(_ connection: RemoteConnection, until stop: (ServerMessage) -> Bool) async throws {
  for try await message in connection.messages {
    print(describe(message))
    if stop(message) { return }
  }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: see the header of Sources/sm-remote/main.swift") }

do {
  switch command {
  case "pair":
    guard args.count >= 2, let url = URL(string: args[1]) else { fail("usage: sm-remote pair '<link>'") }
    let payload = try PairingPayload(url: url)
    let name = args.firstIndex(of: "--name").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
      ?? "sm-remote"
    let (connection, welcome) = try await RemoteConnection.connect(
      hosts: payload.hosts, port: payload.port, fingerprint: payload.fingerprint,
      hello: Hello(deviceName: name, token: nil, pairingCode: payload.code))
    guard let token = welcome.token else { fail("server did not issue a token") }
    // Put the address that answered first for later connections.
    let hosts = [welcome.host] + payload.hosts.filter { $0 != welcome.host }
    try saveServer(
      PairedServer(
        serverName: welcome.serverName, hosts: hosts, port: payload.port,
        fingerprint: payload.fingerprint, deviceId: welcome.deviceId, token: token))
    print("paired with \(welcome.serverName) via \(welcome.host) (device \(welcome.deviceId))")
    connection.close()
  case "list":
    let connection = try await connect(loadServer())
    try await run(connection) { if case .snapshot = $0 { true } else { false } }
    connection.close()
  case "watch":
    let connection = try await connect(loadServer())
    try await run(connection) { _ in false }
  case "transcript":
    guard args.count >= 2 else { fail("usage: sm-remote transcript <id>") }
    let connection = try await connect(loadServer())
    try await connection.send(.subscribeTranscript(sessionId: args[1]))
    let follow = args.contains("--follow")
    try await run(connection) {
      if case .transcript = $0 { return !follow }
      if case .error = $0 { return true }
      return false
    }
    connection.close()
  case "pane":
    guard args.count >= 2 else { fail("usage: sm-remote pane <id>") }
    let connection = try await connect(loadServer())
    try await connection.send(.subscribePane(sessionId: args[1]))
    try await run(connection) {
      if case .pane = $0 { return true }
      if case .error = $0 { return true }
      return false
    }
    connection.close()
  case "send", "key":
    guard args.count >= 3 else { fail("usage: sm-remote \(command) <id> <value>") }
    let connection = try await connect(loadServer())
    let request = UUID().uuidString
    if command == "send" {
      try await connection.send(.sendMessage(requestId: request, sessionId: args[1], text: args[2]))
    } else {
      guard let key = RemoteKey(rawValue: args[2]) else { fail("unknown key \(args[2])") }
      try await connection.send(.sendKey(requestId: request, sessionId: args[1], key: key))
    }
    var status: ActionStatus?
    try await run(connection) {
      if case .actionResult(request, let value, _) = $0 {
        status = value
        return true
      }
      return false
    }
    connection.close()
    if status == .rejected { exit(2) }
  default:
    fail("unknown command \(command)")
  }
} catch {
  fail(error.localizedDescription)
}
