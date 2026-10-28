import Foundation
@testable import SMProtocol
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
    let (device, token, _) = try devices.pair(code: code.lowercased(), name: "iPhone", now: now)
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

  @Test func styledScreensAreStrippedForMenus() {
    let styled = "\u{1B}[1m Do you want to proceed?\u{1B}[0m\n \u{1B}[38;5;153m❯ 1. Yes\u{1B}[39m\n   2. No\n\u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{07}"
    let plain = ANSI.strip(styled)
    #expect(plain == " Do you want to proceed?\n ❯ 1. Yes\n   2. No\nlink")
    #expect(PaneMenuParser.parse(plain).map(\.label) == ["Yes", "No"])
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
    #expect(command.map(\.role) == [.tool, .toolResult])
    #expect(command.first?.text == "Bash: git status" && command.last?.text.hasPrefix("退出码 1") == true)
    // Tool results and thinking are part of the full history.
    let result = TranscriptParser.entries(
      line(#"{"type":"user","uuid":"r1","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"line 1\nline 2"}]}}"#),
      kind: .claude, offset: 0)
    #expect(result.first?.role == .toolResult && result.first?.text == "line 1" && result.first?.detail == "line 1\nline 2")
    let thinking = TranscriptParser.entries(
      line(#"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"thinking","thinking":"先看日志"}]}}"#),
      kind: .claude, offset: 0)
    #expect(thinking.first?.role == .thinking)
    let interrupted = TranscriptParser.entries(
      line(#"{"type":"user","uuid":"i1","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#),
      kind: .claude, offset: 0)
    #expect(interrupted == [TranscriptEntry(id: "i1", role: .event, text: "已中断", at: nil)])
  }

  @Test func transcriptFeedPagesHistoryAndFollowsTheFile() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("t.jsonl")
    func message(_ n: Int) -> String {
      #"{"type":"user","uuid":"u\#(n)","message":{"content":"消息 \#(n)"}}"# + "\n"
    }
    try (1...250).map(message).joined().write(to: url, atomically: true, encoding: .utf8)
    let feed = TranscriptFeed(url: url, kind: .claude)
    try feed.load()
    let first = feed.latest(100)
    #expect(first.entries.count == 100 && first.entries.first?.text == "消息 151" && first.hasOlder)
    let older = feed.page(before: "u151", count: 100)
    #expect(older.entries.first?.text == "消息 51" && older.entries.last?.text == "消息 150" && older.hasOlder)
    let oldest = feed.page(before: "u51", count: 100)
    #expect(oldest.entries.count == 50 && !oldest.hasOlder)
    #expect(try feed.poll().entries.isEmpty)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    // A half-written line is held back until it is complete.
    try handle.write(contentsOf: Data((message(251) + #"{"type":"user","uuid":"u252","#).utf8))
    #expect(try feed.poll().entries.map(\.text) == ["消息 251"])
    try handle.write(contentsOf: Data(#""message":{"content":"消息 252"}}"#.utf8 + [10]))
    try handle.close()
    #expect(try feed.poll().entries.map(\.text) == ["消息 252"])
    #expect(feed.latest(1).entries.first?.text == "消息 252")
    try message(1).write(to: url, atomically: true, encoding: .utf8)
    let replaced = try feed.poll()
    #expect(replaced.reset && feed.latest(100).entries.map(\.text) == ["消息 1"])
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
    await #expect(throws: RemoteClientError.rejected("配对码无效或已过期")) {
      _ = try await RemoteConnection.connect(
        hosts: payload.hosts, port: port, fingerprint: payload.fingerprint,
        hello: Hello(deviceName: "again", token: nil, pairingCode: payload.code))
    }
    let (second, _) = try await RemoteConnection.connect(
      hosts: payload.hosts, port: port, fingerprint: payload.fingerprint,
      hello: Hello(deviceName: "Test Phone", token: token, pairingCode: nil))
    second.close()
    try hub.revoke(deviceID: welcome.deviceId)
    // The reason must reach the client (not just a reset), so it stops retrying and re-pairs.
    await #expect(throws: RemoteClientError.rejected("此设备未配对或已被吊销，请重新配对")) {
      _ = try await RemoteConnection.connect(
        hosts: payload.hosts, port: port, fingerprint: payload.fingerprint,
        hello: Hello(deviceName: "Test Phone", token: token, pairingCode: nil))
    }
    #expect(audit.contains { $0.contains("已配对设备「Test Phone」") })
    #expect(audit.contains { $0.contains("被拒绝") })
  }
}

extension RemoteTests {
  /// Off the LAN the saved LAN addresses no longer answer: they must not hold back the address
  /// that does (Tailscale) by their timeouts, nor a refusal that stops the retries.
  @MainActor @Test func staleAddressesDoNotDelayTheOneThatAnswers() async throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let hub = try RemoteHub(store: SessionStore(), directory: dir) { _ in }
    try await hub.start(serverName: "Test Mac", port: 0, advertise: false)
    defer { hub.stop() }
    for _ in 0..<50 where hub.status.port == nil { try await Task.sleep(for: .milliseconds(100)) }
    let port = try #require(hub.status.port)
    let payload = try #require(hub.pairingPayload())

    // 192.0.2.1 (TEST-NET) does not answer; one by one it took the full 6 s timeout.
    let started = ContinuousClock.now
    let (connection, welcome) = try await RemoteConnection.connect(
      hosts: ["192.0.2.1", "127.0.0.1"], port: port, fingerprint: payload.fingerprint,
      hello: Hello(deviceName: "Test Phone", token: nil, pairingCode: payload.code))
    connection.close()
    #expect(welcome.host == "127.0.0.1")
    #expect(ContinuousClock.now - started < .seconds(3))

    await #expect(throws: RemoteClientError.rejected("此设备未配对或已被吊销，请重新配对")) {
      _ = try await RemoteConnection.connect(
        hosts: ["127.0.0.2", "127.0.0.1"], port: port, fingerprint: payload.fingerprint,
        hello: Hello(deviceName: "Test Phone", token: "not-a-token", pairingCode: nil))
    }
  }

  /// Real case (R4, 2026-10-24): a new session's hooks name its transcript before the first
  /// prompt creates it. Subscribing then must wait for the file, not fail for good.
  @MainActor @Test func transcriptSubscriptionWaitsForTheFile() async throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let transcript = dir.appendingPathComponent("s1.jsonl")
    let store = SessionStore()
    try store.apply(
      AgentEvent(
        sessionId: "s1", agentPid: 4242, cwd: "/work/demo", transcriptPath: transcript.path, at: Date(),
        type: .sessionStart(reason: nil)))
    let hub = try RemoteHub(store: store, directory: dir) { _ in }
    try await hub.start(serverName: "Test Mac", port: 0, advertise: false)
    defer { hub.stop() }
    for _ in 0..<50 where hub.status.port == nil { try await Task.sleep(for: .milliseconds(100)) }
    let port = try #require(hub.status.port)
    let payload = try #require(hub.pairingPayload())
    let (connection, _) = try await RemoteConnection.connect(
      hosts: ["127.0.0.1"], port: port, fingerprint: payload.fingerprint,
      hello: Hello(deviceName: "Test", token: nil, pairingCode: payload.code))
    defer { connection.close() }
    var messages = connection.messages.makeAsyncIterator()
    guard case .snapshot(let sessions)? = try await messages.next(), let id = sessions.first?.id else {
      Issue.record("no snapshot"); return
    }
    try await connection.send(.subscribeTranscript(sessionId: id))
    guard case .transcript(_, let empty, true, _)? = try await messages.next() else {
      Issue.record("no empty transcript"); return
    }
    #expect(empty.isEmpty)
    try (#"{"type":"user","uuid":"u1","message":{"content":"第一条"}}"# + "\n")
      .write(to: transcript, atomically: true, encoding: .utf8)
    while let message = try await messages.next() {
      if case .transcript(_, let entries, true, _) = message, !entries.isEmpty {
        #expect(entries.map(\.text) == ["第一条"])
        return
      }
      if case .error(let text) = message { Issue.record("error: \(text)"); return }
    }
  }
}

extension RemoteTests {
  /// Real case (2026-10-26): pairing again after the Mac changed networks listed the phone twice.
  @Test func pairingAgainReplacesTheSamePhone() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let devices = try RemoteDevices(directory: dir)
    // Paired by an older app: no client id until it connects again.
    let first = try devices.pair(code: devices.newPairingCode(), name: "iPhone")
    #expect(devices.authenticate(token: first.token, clientId: "phone-a")?.clientId == "phone-a")
    let other = try devices.pair(code: devices.newPairingCode(), name: "iPad", clientId: "pad")
    let second = try devices.pair(code: devices.newPairingCode(), name: "iPhone", clientId: "phone-a")
    #expect(second.replaced == [first.device.id])
    #expect(devices.authenticate(token: first.token) == nil)
    // An entry that never sent its client id is found by the token the phone still holds.
    let third = try devices.pair(
      code: devices.newPairingCode(), name: "iPhone", clientId: "phone-b", replacingToken: second.token)
    #expect(third.replaced == [second.device.id])
    #expect(try RemoteDevices(directory: dir).all.map(\.name).sorted() == ["iPad", "iPhone"])
    #expect(devices.authenticate(token: other.token)?.name == "iPad")
  }

  /// Older apps and Macs omit the new optional fields; both directions must still decode.
  @Test func welcomeAndHelloStayCompatible() throws {
    let decoder = RemoteProtocol.decoder()
    let old = #"{"welcome":{"version":1,"serverName":"Mac","deviceId":"d1"}}"#
    guard case .welcome(1, "Mac", "d1", nil, nil, nil) = try decoder.decode(ServerMessage.self, from: Data(old.utf8)) else {
      Issue.record("old welcome"); return
    }
    let hello = #"{"hello":{"_0":{"version":1,"deviceName":"iPhone","token":"t"}}}"#
    guard case .hello(let decoded) = try decoder.decode(ClientMessage.self, from: Data(hello.utf8)) else {
      Issue.record("old hello"); return
    }
    #expect(decoded.token == "t" && decoded.clientId == nil && decoded.replacingToken == nil)
    let welcome = RemoteConnection.Welcome(serverName: "Mac", deviceId: "d", token: nil, host: "100.1.2.3", hosts: ["192.168.5.9", "100.1.2.3"], features: [])
    #expect(welcome.addresses(previous: ["192.168.1.2"]) == ["100.1.2.3", "192.168.5.9"])
    let silent = RemoteConnection.Welcome(serverName: "Mac", deviceId: "d", token: nil, host: "192.168.1.2", hosts: nil, features: [])
    #expect(silent.addresses(previous: ["10.0.0.1", "192.168.1.2"]) == ["192.168.1.2", "10.0.0.1"])
  }

  /// End to end: the welcome carries the Mac's addresses, pairing again replaces the old entry
  /// and drops its connection, and Bonjour finds the Mac by its fingerprint.
  @MainActor @Test func repairingAndDiscovery() async throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let hub = try RemoteHub(store: SessionStore(), directory: dir) { _ in }
    try await hub.start(serverName: "Test Mac \(UUID().uuidString.prefix(4))", port: 0, advertise: true)
    defer { hub.stop() }
    for _ in 0..<50 where hub.status.port == nil { try await Task.sleep(for: .milliseconds(100)) }
    let port = try #require(hub.status.port)
    let first = try #require(hub.pairingPayload())
    let (old, welcome) = try await RemoteConnection.connect(
      hosts: ["127.0.0.1"], port: port, fingerprint: first.fingerprint,
      hello: Hello(deviceName: "Phone", token: nil, pairingCode: first.code, clientId: "c1"))
    #expect(welcome.hosts == first.hosts)
    let second = try #require(hub.pairingPayload())
    let (connection, again) = try await RemoteConnection.connect(
      hosts: ["127.0.0.1"], port: port, fingerprint: second.fingerprint,
      hello: Hello(deviceName: "Phone", token: nil, pairingCode: second.code, clientId: "c1"))
    defer { connection.close() }
    #expect(hub.devices.all.map(\.id) == [again.deviceId])
    var messages = old.messages.makeAsyncIterator()
    var reason: String?
    while let message = try? await messages.next() {
      if case .error(let text) = message { reason = text }
    }
    #expect(reason == "此设备已重新配对")

    let found = await RemoteDiscovery.find(fingerprint: second.fingerprint, timeout: 5)
    #expect(!found.isEmpty)
    // Only addresses the Mac accepts, even when it also sits on a network outside those ranges.
    #expect(found.allSatisfy { first.hosts.contains($0) }, "\(found) vs \(first.hosts)")
    #expect(await RemoteDiscovery.find(fingerprint: String(repeating: "0", count: 64), timeout: 1).isEmpty)
  }
}

extension RemoteTests {
  /// The welcome lists "usage"; asking returns the ledger's rows of the requested days, and
  /// session rows carry their thread's usage.
  @MainActor @Test func usageIsServedToClientsThatAsk() async throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore()
    try store.apply(AgentEvent(sessionId: "s1", agentPid: 4242, cwd: "/work/demo", at: Date(), type: .promptSubmitted))
    let usage = SessionUsage(total: TokenUsage(input: 10, output: 5), model: "m", contextTokens: 100, contextWindow: 1000)
    store.applyUsage(usage, id: "claude:4242", sessionID: "s1")
    let hub = try RemoteHub(store: store, directory: dir) { _ in }
    let today = UsageReport.dayKey(Date())
    hub.usageRows = {
      [UsageRow(day: "2020-01-01", agent: "claude", model: "m", project: "old", usage: TokenUsage(output: 1)),
       UsageRow(day: today, agent: "codex", model: "g", project: "demo", usage: TokenUsage(input: 7))]
    }
    try await hub.start(serverName: "Test Mac", port: 0, advertise: false)
    defer { hub.stop() }
    for _ in 0..<50 where hub.status.port == nil { try await Task.sleep(for: .milliseconds(100)) }
    let port = try #require(hub.status.port)
    let payload = try #require(hub.pairingPayload())
    let (connection, welcome) = try await RemoteConnection.connect(
      hosts: ["127.0.0.1"], port: port, fingerprint: payload.fingerprint,
      hello: Hello(deviceName: "Test", token: nil, pairingCode: payload.code))
    defer { connection.close() }
    #expect(welcome.features.contains("usage"))
    var messages = connection.messages.makeAsyncIterator()
    guard case .snapshot(let sessions)? = try await messages.next() else { Issue.record("no snapshot"); return }
    #expect(sessions.first?.usage == usage)
    try await connection.send(.requestUsage(days: 30))
    while let message = try await messages.next() {
      if case .usage(let rows) = message {
        #expect(rows.map(\.project) == ["demo"])
        return
      }
    }
    Issue.record("no usage")
  }
}
