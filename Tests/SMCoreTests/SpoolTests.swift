import Foundation
import Testing

@testable import SMCore

private actor ReplayRecorder {
  var items: [HookEnvelope] = []
  func append(_ envelope: HookEnvelope) { items.append(envelope) }
}

@Suite struct SpoolTests {
  private func envelope(_ id: String) -> HookEnvelope {
    HookEnvelope(source: "claude", agentPid: nil, payload: .object(["session_id": .string(id)]))
  }
  @Test func queueReplayAndClear() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    for id in ["a", "b", "c"] { try SpoolQueue.append(envelope(id), directory: directory) }
    let recorder = ReplayRecorder()
    try await SpoolReplayer(directory: directory).replay { await recorder.append($0) }
    #expect(await recorder.items.count == 3)
    #expect(try Data(contentsOf: directory.appendingPathComponent("spool.jsonl")).isEmpty)
  }

  @Test func failedRecordAndRemainderArePreserved() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    try SpoolQueue.append(envelope("a"), directory: directory)
    let path = directory.appendingPathComponent("spool.jsonl")
    let handle = try FileHandle(forWritingTo: path)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("invalid-json\n".utf8))
    try handle.close()
    try SpoolQueue.append(envelope("b"), directory: directory)
    let recorder = ReplayRecorder()
    await #expect(throws: (any Error).self) {
      try await SpoolReplayer(directory: directory).replay { await recorder.append($0) }
    }
    #expect(await recorder.items.count == 1)
    let remaining = try String(contentsOf: path, encoding: .utf8)
    #expect(remaining.hasPrefix("invalid-json\n"))
    #expect(remaining.contains("\"b\""))
  }

  @Test func consumerFailureKeepsUnappliedRecord() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    try SpoolQueue.append(envelope("a"), directory: directory)
    let before = try Data(contentsOf: directory.appendingPathComponent("spool.jsonl"))
    await #expect(throws: MonitorError.self) {
      try await SpoolReplayer(directory: directory).replay { _ in
        throw MonitorError.invalid("consumer failed")
      }
    }
    #expect(try Data(contentsOf: directory.appendingPathComponent("spool.jsonl")) == before)
  }

  @Test func queueCapIsExplicitFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    try SpoolQueue.append(envelope("a"), directory: directory)
    let path = directory.appendingPathComponent("spool.jsonl")
    let handle = try FileHandle(forWritingTo: path)
    try handle.truncate(atOffset: UInt64(SpoolQueue.limit))
    try handle.close()
    #expect(throws: MonitorError.self) {
      try SpoolQueue.append(envelope("b"), directory: directory)
    }
    #expect(
      try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int == SpoolQueue.limit
    )
  }
}
