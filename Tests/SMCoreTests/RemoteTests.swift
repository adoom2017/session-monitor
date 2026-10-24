import Foundation
import SMProtocol
import Testing

@testable import SMCore

@Suite struct RemoteTests {
  func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sm-remote-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func onlyLocalAndTailscalePeersAreAllowed() {
    for host in [
      "127.0.0.1", "10.1.2.3", "172.16.0.9", "172.31.255.1", "192.168.1.20", "169.254.3.4",
      "100.64.0.1", "100.127.255.254", "::1", "fe80::1%en0", "fd7a:115c:a1e0::1", "::ffff:192.168.1.2",
    ] {
      #expect(RemoteAddressPolicy.isAllowed(host), "\(host)")
    }
    for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "100.63.255.255", "2001:4860::8888", "example.com", ""] {
      #expect(!RemoteAddressPolicy.isAllowed(host), "\(host)")
    }
  }

  @Test func pairingCodesAreSingleUseAndExpire() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let devices = try RemoteDevices(directory: dir)
    let now = Date()
    let code = devices.newPairingCode(now: now)
    #expect(code.count == 8)
    #expect(throws: MonitorError.self) { try devices.pair(code: "WRONG123", name: "x", now: now) }
    let (device, token) = try devices.pair(code: code.lowercased(), name: "iPhone", now: now)
    #expect(throws: MonitorError.self) { try devices.pair(code: code, name: "again", now: now) }
    #expect(devices.authenticate(token: token)?.id == device.id)
    #expect(devices.authenticate(token: token + "x") == nil)
    // Persisted without the token itself.
    let stored = try String(contentsOf: dir.appendingPathComponent("remote/devices.json"), encoding: .utf8)
    #expect(!stored.contains(token))
    let mode = try FileManager.default.attributesOfItem(
      atPath: dir.appendingPathComponent("remote/devices.json").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(try RemoteDevices(directory: dir).authenticate(token: token)?.name == "iPhone")
    try devices.revoke(id: device.id)
    #expect(devices.authenticate(token: token) == nil)
    let late = devices.newPairingCode(now: now)
    #expect(throws: MonitorError.self) {
      try devices.pair(code: late, name: "late", now: now.addingTimeInterval(RemoteDevices.codeLifetime + 1))
    }
  }

  /// Screens captured in R0 (Claude Code 2.1.308, Codex 0.164.0).
  @Test func menusAreParsedFromRealScreens() {
    let claude = """
      ⏺ Creating empty probe file
        ⎿  $ touch r0-probe.txt
      ────────────────────────────────
       Bash command
       touch r0-probe.txt
       Do you want to proceed?
       ❯ 1. Yes
         2. Yes, and always allow access to
            /private/tmp/r0/claude from this project
         3. Yes, and switch to auto mode · auto mode handles these prompts for you
         4. No
       Esc to cancel · Tab to amend
      """
    let options = PaneMenuParser.parse(claude)
    #expect(options.map(\.number) == [1, 2, 3, 4])
    #expect(options[0].selected && !options[3].selected)
    #expect(options[1].label == "Yes, and always allow access to /private/tmp/r0/claude from this project")
    #expect(options[3].label == "No")

    let codex = """
      • Running rtk proxy touch smr0-probe.txt
        Would you like to run the following command?
        $ rtk proxy touch smr0-probe.txt
      › 1. Yes, proceed (y)
        2. Yes, and don't ask again for commands that start with `rtk proxy touch smr0-probe.txt` (p)
        3. No, and tell Codex what to do differently (esc)
        Press enter to confirm or esc to cancel
      """
    #expect(PaneMenuParser.parse(codex).map(\.label).last == "No, and tell Codex what to do differently (esc)")

    let update = """
        Update available · 0.163.0 → 0.164.0
      › 1. Update now (runs `brew upgrade --cask codex`)
        2. Skip
        3. Skip until next version
        enter continue · esc skip
      """
    #expect(PaneMenuParser.parse(update).count == 3)
  }

  @Test func numberedListsInRepliesAreNotMenus() {
    let idle = """
      ⏺ 建议按以下顺序处理：
        1. 先修复测试
        2. 再更新文档
        3. 最后发布
      ✻ Worked for 4s
      ────────────────────────────────
      ❯
      ────────────────────────────────
        ⏸ manual mode on
      """
    #expect(PaneMenuParser.parse(idle).isEmpty)
    // A menu scrolled far above the bottom is no longer pending.
    let old = """
      ❯ 1. Yes
        2. No
      """ + String(repeating: "\noutput line", count: 12)
    #expect(PaneMenuParser.parse(old).isEmpty)
  }

  @Test func paneAncestryIsChecked() throws {
    let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 1]
    let lookup: (Int32) throws -> Int32 = { parents[$0] ?? 1 }
    #expect(try TmuxRemote.isAncestor(400, of: 500, parent: lookup))
    #expect(try TmuxRemote.isAncestor(500, of: 500, parent: lookup))
    #expect(try !TmuxRemote.isAncestor(999, of: 500, parent: lookup))
  }

  @Test func transcriptsBecomeConversationEntries() throws {
    func line(_ json: String) -> Data { Data(json.utf8) }
    let user = TranscriptParser.entries(
      line(#"{"type":"user","uuid":"u1","timestamp":"2026-10-24T10:14:38.575Z","message":{"role":"user","content":"只回复两个字：收到"}}"#),
      kind: .claude, offset: 0)
    #expect(user == [TranscriptEntry(id: "u1", role: .user, text: "只回复两个字：收到", at: user.first?.at)])
    #expect(user.first?.at != nil)
    let assistant = TranscriptParser.entries(
      line(#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"收到"},{"type":"tool_use","name":"Bash","input":{"command":"touch x"}}]}}"#),
      kind: .claude, offset: 0)
    #expect(assistant.map(\.role) == [.assistant, .tool])
    #expect(assistant.last?.text == "Bash: touch x")
    for skipped in [
      #"{"type":"user","isSidechain":true,"message":{"content":"sub"}}"#,
      #"{"type":"user","isMeta":true,"message":{"content":"meta"}}"#,
      #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
      #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
    ] {
      #expect(TranscriptParser.entries(line(skipped), kind: .claude, offset: 0).isEmpty)
    }
    let codexUser = TranscriptParser.entries(
      line(#"{"timestamp":"2026-10-22T05:05:35.100Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"x1","content":[{"type":"text","text":"review 一下"}]}}}"#),
      kind: .codex, offset: 0)
    #expect(codexUser.first?.text == "review 一下" && codexUser.first?.role == .user)
    let codexAgent = TranscriptParser.entries(
      line(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m1","content":[{"type":"Text","text":"我先读取"}]}}}"#),
      kind: .codex, offset: 0)
    #expect(codexAgent.first?.role == .assistant)
    let command = TranscriptParser.entries(
      line(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"e1","command":["/bin/zsh","-lc","git status"],"exit_code":1}}}"#),
      kind: .codex, offset: 0)
    #expect(command.first?.text == "Bash: git status（退出码 1）")
  }

  @Test func transcriptFeedReadsIncrementally() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("t.jsonl")
    func message(_ n: Int) -> String {
      #"{"type":"user","uuid":"u\#(n)","message":{"content":"消息 \#(n)"}}"# + "\n"
    }
    try (1...60).map(message).joined().write(to: url, atomically: true, encoding: .utf8)
    let feed = TranscriptFeed(url: url, kind: .claude)
    let first = try feed.initial(limit: 50)
    #expect(first.count == 50 && first.first?.text == "消息 11" && first.last?.text == "消息 60")
    #expect(try feed.poll(limit: 50).entries.isEmpty)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    // A half-written line is held back until it is complete.
    try handle.write(contentsOf: Data((message(61) + #"{"type":"user","uuid":"u62","#).utf8))
    #expect(try feed.poll(limit: 50).entries.map(\.text) == ["消息 61"])
    try handle.write(contentsOf: Data(#""message":{"content":"消息 62"}}"#.utf8 + [10]))
    try handle.close()
    #expect(try feed.poll(limit: 50).entries.map(\.text) == ["消息 62"])
    try message(1).write(to: url, atomically: true, encoding: .utf8)
    let replaced = try feed.poll(limit: 50)
    #expect(replaced.reset && replaced.entries.map(\.text) == ["消息 1"])
  }

  @Test func sessionDTOHidesProcessDetails() {
    var event = AgentEvent(
      kind: .codex, sessionId: "s1", agentPid: 4242, cwd: "/work/app", at: Date(), type: .promptSubmitted,
      terminal: TerminalInfo(tty: "/dev/ttys011"))
    var dto = RemoteHub.dto(Session(event: event))
    #expect(!dto.id.contains("4242") && dto.remoteInput == false)
    let encoded = String(decoding: try! RemoteProtocol.encoder().encode(dto), as: UTF8.self)
    #expect(!encoded.contains("4242") && !encoded.contains("ttys011") && !encoded.contains("/work/app"))
    event.terminal.tmuxPane = "%6"
    dto = RemoteHub.dto(Session(event: event))
    #expect(dto.remoteInput)
  }

  @Test func pairingLinkRoundTrips() throws {
    let payload = PairingPayload(serverName: "Mac", hosts: ["192.168.1.2", "100.100.1.1"], port: 47821, fingerprint: "ab", code: "ABCD2345")
    #expect(try PairingPayload(url: payload.url) == payload)
    #expect(throws: RemoteClientError.self) { try PairingPayload(url: URL(string: "https://example.com")!) }
  }

  /// End to end over TLS on loopback: pairing, snapshot, updates, pinning and revocation.
  @MainActor @Test func pairedClientReceivesSessionsAndUnpairedIsRefused() async throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore()
    try store.apply(AgentEvent(sessionId: "s1", agentPid: 4242, cwd: "/work/demo", at: Date(), type: .promptSubmitted))
    var audit: [String] = []
    let hub = try RemoteHub(store: store, directory: dir) { audit.append($0) }
    try await hub.start(serverName: "Test Mac", port: 0, advertise: false)
    defer { hub.stop() }
    for _ in 0..<50 where hub.status.port == nil { try await Task.sleep(for: .milliseconds(100)) }
    let port = try #require(hub.status.port)
    var payload = try #require(hub.pairingPayload())
    payload.hosts = ["127.0.0.1"]

    // Wrong fingerprint: refused before any data is exchanged.
    await #expect(throws: RemoteClientError.fingerprintMismatch) {
      _ = try await RemoteConnection.connect(
        hosts: payload.hosts, port: port, fingerprint: String(repeating: "0", count: 64),
        hello: Hello(deviceName: "evil", token: nil, pairingCode: payload.code))
    }
    let (connection, welcome) = try await RemoteConnection.connect(
      hosts: payload.hosts, port: port, fingerprint: payload.fingerprint,
      hello: Hello(deviceName: "Test Phone", token: nil, pairingCode: payload.code))
    let token = try #require(welcome.token)
    var messages = connection.messages.makeAsyncIterator()
    guard case .snapshot(let sessions)? = try await messages.next() else { Issue.record("no snapshot"); return }
    #expect(sessions.count == 1 && sessions[0].projectName == "demo" && sessions[0].state == .working)

    try store.apply(AgentEvent(sessionId: "s1", agentPid: 4242, at: Date().addingTimeInterval(1), type: .stop))
    guard case .sessionUpdated(let updated)? = try await messages.next() else { Issue.record("no update"); return }
    #expect(updated.state == .done)

    // Sending to a session outside tmux is refused with a reason.
    try await connection.send(.sendMessage(requestId: "r1", sessionId: updated.id, text: "hi"))
    guard case .actionResult("r1", .rejected, let reason)? = try await messages.next() else {
      Issue.record("no rejection"); return
    }
    #expect(reason?.contains("tmux") == true)
    connection.close()

    // The code was used up; the token works until revoked.
    await #expect(throws: RemoteClientError.self) {
      _ = try await RemoteConnection.connect(
        hosts: payload.hosts, port: port, fingerprint: payload.fingerprint,
        hello: Hello(deviceName: "again", token: nil, pairingCode: payload.code))
    }
    let (second, _) = try await RemoteConnection.connect(
      hosts: payload.hosts, port: port, fingerprint: payload.fingerprint,
      hello: Hello(deviceName: "Test Phone", token: token, pairingCode: nil))
    second.close()
    try hub.revoke(deviceID: welcome.deviceId)
    await #expect(throws: RemoteClientError.self) {
      _ = try await RemoteConnection.connect(
        hosts: payload.hosts, port: port, fingerprint: payload.fingerprint,
        hello: Hello(deviceName: "Test Phone", token: token, pairingCode: nil))
    }
    #expect(audit.contains { $0.contains("已配对设备「Test Phone」") })
    #expect(audit.contains { $0.contains("被拒绝") })
  }
}
