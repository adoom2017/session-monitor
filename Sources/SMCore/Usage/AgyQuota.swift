import Darwin
import Foundation

public struct AgyQuotaBucket: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public var remainingFraction: Double?
  public var remainingAmount: Double?
  public var resetAt: Date?
  public var disabled: Bool

  public init(
    id: String,
    remainingFraction: Double? = nil,
    remainingAmount: Double? = nil,
    resetAt: Date? = nil,
    disabled: Bool = false
  ) {
    self.id = id
    self.remainingFraction = remainingFraction
    self.remainingAmount = remainingAmount
    self.resetAt = resetAt
    self.disabled = disabled
  }

  public var displayName: String {
    switch id {
    case "gemini-5h": "Gemini · 5 小时"
    case "gemini-weekly": "Gemini · 周额度"
    case "3p-5h": "Claude / GPT · 5 小时"
    case "3p-weekly": "Claude / GPT · 周额度"
    default: id
    }
  }

  public var shortName: String {
    switch id {
    case "gemini-5h": "5h"
    case "gemini-weekly": "周"
    case "3p-5h": "3P 5h"
    case "3p-weekly": "3P 周"
    default: id
    }
  }

  public var sortOrder: Int {
    switch id {
    case "gemini-5h": 0
    case "gemini-weekly": 1
    case "3p-5h": 2
    case "3p-weekly": 3
    default: 100
    }
  }

  public var remainingPercent: Int? {
    remainingFraction.map { min(100, max(0, Int(($0 * 100).rounded()))) }
  }

  public var valueText: String {
    if let remainingPercent {
      return "\(remainingPercent)%"
    }
    if let remainingAmount {
      let rounded = remainingAmount.rounded()
      if abs(remainingAmount - rounded) < 0.001 {
        return "\(Int(rounded))"
      }
      return String(format: "%.1f", remainingAmount)
    }
    return "—"
  }

  public func resetText(
    now: Date, calendar: Calendar = .current, timeZone: TimeZone = .current
  ) -> String {
    guard let resetAt else {
      return (remainingFraction ?? 0) >= 0.999 ? "未消耗" : "—"
    }
    if resetAt <= now { return "已重置" }
    let seconds = Int(resetAt.timeIntervalSince(now))
    if seconds < 60 { return "<1m" }
    if seconds < 3600 {
      return "\(seconds / 60)m · \(Self.clockString(resetAt, format: "HH:mm", calendar: calendar, timeZone: timeZone))"
    }
    if seconds < 86400 {
      let hours = seconds / 3600
      let mins = (seconds % 3600) / 60
      let duration = mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
      return "\(duration) · \(Self.clockString(resetAt, format: "HH:mm", calendar: calendar, timeZone: timeZone))"
    }
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let duration = hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    return "\(duration) · \(Self.clockString(resetAt, format: "MM/dd HH:mm", calendar: calendar, timeZone: timeZone))"
  }

  public func compactResetText(now: Date) -> String {
    guard let resetAt else { return "" }
    if resetAt <= now { return "已重置" }
    let seconds = Int(resetAt.timeIntervalSince(now))
    if seconds < 60 { return "<1m" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 {
      let hours = seconds / 3600
      let mins = (seconds % 3600) / 60
      return mins > 0 ? "\(hours)h\(mins)m" : "\(hours)h"
    }
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
  }

  private static func clockString(
    _ date: Date, format: String, calendar: Calendar, timeZone: TimeZone
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}

public struct AgyQuotaSnapshot: Codable, Equatable, Sendable {
  public var updatedAt: Date
  public var planTier: String?
  public var buckets: [AgyQuotaBucket]

  public init(updatedAt: Date, planTier: String? = nil, buckets: [AgyQuotaBucket]) {
    self.updatedAt = updatedAt
    self.planTier = planTier
    self.buckets = buckets
  }

  public var activeBuckets: [AgyQuotaBucket] {
    buckets.filter { !$0.disabled }
  }

  public func hasExpiredBucket(at now: Date) -> Bool {
    activeBuckets.contains { bucket in
      guard let resetAt = bucket.resetAt else { return false }
      return resetAt <= now && updatedAt < resetAt
    }
  }
}

public enum AgyQuota {
  private struct StatusLine: Decodable {
    struct RawBucket: Decodable {
      let remaining_fraction: Double?
      let remaining_amount: Double?
      let reset_time: String?
      let reset_in_seconds: Double?
      let disabled: Bool?
    }

    let quota: [String: RawBucket]?
    let plan_tier: String?
  }

  public static func snapshotURL(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    home.appendingPathComponent(".session-monitor/agy-quota.json")
  }

  public static func parse(_ input: Data, now: Date = Date()) throws -> AgyQuotaSnapshot? {
    let status = try JSONDecoder().decode(StatusLine.self, from: input)
    guard let rawQuota = status.quota, !rawQuota.isEmpty else { return nil }
    let buckets = rawQuota.map { id, raw in
      let fraction = raw.remaining_fraction.map { min(1, max(0, $0)) }
      var resetAt = raw.reset_time.flatMap(parseISO8601)
      if let date = resetAt, date.timeIntervalSince1970 <= 0 {
        resetAt = nil
      }
      if resetAt == nil, let seconds = raw.reset_in_seconds, seconds > 0 {
        resetAt = now.addingTimeInterval(seconds)
      }
      return AgyQuotaBucket(
        id: id,
        remainingFraction: fraction,
        remainingAmount: raw.remaining_amount,
        resetAt: resetAt,
        disabled: raw.disabled ?? false
      )
    }.sorted { lhs, rhs in
      if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
      return lhs.id < rhs.id
    }
    let tier = status.plan_tier?.trimmingCharacters(in: .whitespacesAndNewlines)
    return AgyQuotaSnapshot(
      updatedAt: now,
      planTier: (tier?.isEmpty == false) ? tier : nil,
      buckets: buckets
    )
  }

  /// Persists the latest quota from `agy` statusLine; skips unchanged writes within 30s.
  public static func record(
    _ input: Data, home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()
  ) throws {
    guard let snapshot = try parse(input, now: now) else { return }
    if let existing = load(home: home),
      existing.buckets == snapshot.buckets,
      existing.planTier == snapshot.planTier,
      now.timeIntervalSince(existing.updatedAt) < 30
    {
      return
    }
    try save(snapshot, home: home)
  }

  public static func save(
    _ snapshot: AgyQuotaSnapshot, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    let url = snapshotURL(home: home)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot).write(to: url, options: .atomic)
  }

  public static func load(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> AgyQuotaSnapshot? {
    let url = snapshotURL(home: home)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(AgyQuotaSnapshot.self, from: data)
  }

  public static func modificationDate(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Date? {
    let url = snapshotURL(home: home)
    return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  private static func parseISO8601(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: text)
  }
}

public enum AgyQuotaProbe {
  public static let probeMarker = "agy-quota-probe"

  public static func findExecutable(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    var candidates = [
      home.appendingPathComponent(".local/bin/agy").path,
      home.appendingPathComponent(".gemini/bin/agy").path,
      "/opt/homebrew/bin/agy",
      "/usr/local/bin/agy",
    ]
    if let path = environment["PATH"] {
      for dir in path.split(separator: ":") where !dir.isEmpty {
        candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("agy").path)
      }
    }
    let fm = FileManager.default
    return candidates.first { fm.isExecutableFile(atPath: $0) }
  }

  /// Launches a short-lived `agy` PTY session with an inline statusLine capture to fetch quota
  /// even when no interactive `agy` session is running.
  public static func fetch(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    executable: String? = nil,
    timeout: TimeInterval = 12
  ) async throws -> AgyQuotaSnapshot {
    try await Task.detached(priority: .utility) {
      try fetchSync(home: home, executable: executable, timeout: timeout)
    }.value
  }

  private static func fetchSync(home: URL, executable: String?, timeout: TimeInterval) throws -> AgyQuotaSnapshot {
    guard let binary = executable ?? findExecutable(home: home) else {
      throw MonitorError.invalid("未找到 agy 可执行文件")
    }
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("\(probeMarker)-\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: tempDir) }

    let tmpOut = tempDir.appendingPathComponent("payload.tmp")
    let outURL = tempDir.appendingPathComponent("payload.json")
    let settingsURL = tempDir.appendingPathComponent("\(probeMarker)-settings.json")
    let captureCommand = "/bin/cat > \(HookInstaller.shellQuote(tmpOut.path)) && /bin/mv -f \(HookInstaller.shellQuote(tmpOut.path)) \(HookInstaller.shellQuote(outURL.path))"
    let settingsPayload: [String: Any] = [
      "statusLine": [
        "type": "command",
        "command": captureCommand,
        "enabled": true,
      ]
    ]
    let settingsData = try JSONSerialization.data(withJSONObject: settingsPayload)
    try settingsData.write(to: settingsURL, options: .atomic)

    var masterFD: Int32 = -1
    var slaveFD: Int32 = -1
    var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    guard Darwin.openpty(&masterFD, &slaveFD, nil, nil, &winSize) == 0 else {
      throw MonitorError.system("openpty", errno)
    }
    defer {
      if masterFD >= 0 { Darwin.close(masterFD) }
    }

    let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["--settings", settingsURL.path]
    process.currentDirectoryURL = tempDir
    process.standardInput = slaveHandle
    process.standardOutput = slaveHandle
    process.standardError = slaveHandle
    process.environment = ProcessInfo.processInfo.environment.merging([
      "TERM": "xterm-256color",
      "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8",
    ]) { _, new in new }

    do {
      try process.run()
    } catch {
      Darwin.close(slaveFD)
      throw error
    }
    Darwin.close(slaveFD)

    defer { terminate(process) }

    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 8192)
    while Date() < deadline {
      var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&pfd, 1, 150)
      if ready > 0, (pfd.revents & Int16(POLLIN)) != 0 {
        _ = Darwin.read(masterFD, &buffer, buffer.count)
      }
      if fm.fileExists(atPath: outURL.path),
        let data = try? Data(contentsOf: outURL),
        let snapshot = try? AgyQuota.parse(data),
        !snapshot.buckets.isEmpty
      {
        try AgyQuota.save(snapshot, home: home)
        return snapshot
      }
      if !process.isRunning {
        throw MonitorError.invalid("agy 探测进程提前退出，未返回额度")
      }
    }
    throw MonitorError.timeout("Antigravity 额度刷新")
  }

  private static func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let waitUntil = Date().addingTimeInterval(0.5)
    while process.isRunning && Date() < waitUntil {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
  }
}
