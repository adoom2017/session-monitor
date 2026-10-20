import Darwin
import Foundation

public struct CommandResult: Sendable {
  public let stdout: String
  public let stderr: String
}

private final class CommandOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var failure: (any Error)?
  func read(_ handle: FileHandle) {
    do {
      while let chunk = try handle.read(upToCount: 8192), !chunk.isEmpty {
        lock.lock()
        if data.count + chunk.count > 65536 {
          failure = MonitorError.invalid("external command output exceeds 64KB")
        } else {
          data.append(chunk)
        }
        lock.unlock()
      }
    } catch {
      lock.lock()
      failure = error
      lock.unlock()
    }
  }
  func result() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    if let failure { throw failure }
    guard let text = String(data: data, encoding: .utf8) else {
      throw MonitorError.invalid("external command output is not UTF-8")
    }
    return text
  }
}

private final class CommandTimeout: @unchecked Sendable {
  private let lock = NSLock()
  private var expired = false
  func fire(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    if process.isRunning {
      expired = true
      kill(process.processIdentifier, SIGKILL)
    }
  }
  var didExpire: Bool {
    lock.lock()
    defer { lock.unlock() }
    return expired
  }
}

public enum ProcessRunner {
  public static func run(
    _ executable: String, arguments: [String], timeout: TimeInterval = 2,
    environment: [String: String] = [:], inheritEnvironment: Bool = true
  ) async throws -> CommandResult {
    try await Task.detached(priority: .utility) {
      try runSync(
        executable, arguments: arguments, timeout: timeout, environment: environment,
        inheritEnvironment: inheritEnvironment)
    }.value
  }

  /// `environment` entries are added to (and override) the inherited environment; with
  /// `inheritEnvironment: false` they are the whole environment.
  public static func runSync(
    _ executable: String, arguments: [String], timeout: TimeInterval = 2,
    environment: [String: String] = [:], inheritEnvironment: Bool = true
  ) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if !inheritEnvironment {
      process.environment = environment
    } else if !environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let group = DispatchGroup()
    let out = CommandOutput()
    let err = CommandOutput()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      out.read(stdout.fileHandleForReading)
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      err.read(stderr.fileHandleForReading)
      group.leave()
    }
    let state = CommandTimeout()
    let timer = DispatchWorkItem { state.fire(process) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
    process.waitUntilExit()
    timer.cancel()
    // A child may inherit the pipe. Never wait indefinitely for its EOF.
    guard group.wait(timeout: .now() + 0.2) == .success else {
      stdout.fileHandleForReading.closeFile()
      stderr.fileHandleForReading.closeFile()
      throw MonitorError.timeout("command output pipe")
    }
    if state.didExpire {
      throw MonitorError.timeout(URL(fileURLWithPath: executable).lastPathComponent)
    }
    let output = try out.result()
    let errorOutput = try err.result()
    guard process.terminationStatus == 0 else {
      let detail = singleLine(errorOutput, limit: 80)
      throw MonitorError.command(
        URL(fileURLWithPath: executable).lastPathComponent + (detail.isEmpty ? "" : " [\(detail)]"),
        process.terminationStatus)
    }
    return CommandResult(stdout: output, stderr: errorOutput)
  }
}
