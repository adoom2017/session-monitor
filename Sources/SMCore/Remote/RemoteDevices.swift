import CryptoKit
import Foundation

public struct RemoteDevice: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  /// SHA-256 of the device token (hex); the token itself is never stored on the Mac.
  public var tokenHash: String
  public var pairedAt: Date
  public var lastSeen: Date?
}

/// Paired phones and the current one-time pairing code (DEV_SPEC §17.3). Persisted in
/// `<directory>/remote/devices.json` (0600). Thread-safe.
public final class RemoteDevices: @unchecked Sendable {
  public static let codeLifetime: TimeInterval = 300
  /// No 0/O/1/I/L: the code may be typed by hand.
  static let codeAlphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

  private let lock = NSLock()
  private let file: URL
  private var devices: [RemoteDevice]
  private var code: (value: String, expires: Date)?

  public init(directory: URL) throws {
    file = try RemoteFiles.folder(directory).appendingPathComponent("devices.json")
    if let data = FileManager.default.contents(atPath: file.path) {
      devices = try JSONDecoder().decode([RemoteDevice].self, from: data)
    } else {
      devices = []
    }
  }

  public var all: [RemoteDevice] { lock.withLock { devices } }

  /// A fresh code; the previous one stops working.
  public func newPairingCode(now: Date = Date()) -> String {
    let value = String((0..<8).map { _ in Self.codeAlphabet.randomElement()! })
    lock.withLock { code = (value, now.addingTimeInterval(Self.codeLifetime)) }
    return value
  }

  public func cancelPairingCode() { lock.withLock { code = nil } }

  /// Consumes the code (single use) and registers the device. Returns the device and its token.
  public func pair(code candidate: String, name: String, now: Date = Date()) throws -> (RemoteDevice, String) {
    try lock.withLock {
      guard let current = code, now < current.expires,
        candidate.uppercased() == current.value
      else { throw MonitorError.invalid("配对码无效或已过期") }
      code = nil
      let token = RemoteFiles.randomToken(bytes: 32)
      let device = RemoteDevice(
        id: UUID().uuidString, name: String(name.prefix(60)), tokenHash: Self.hash(token),
        pairedAt: now, lastSeen: now)
      devices.append(device)
      try save()
      return (device, token)
    }
  }

  public func authenticate(token: String, now: Date = Date()) -> RemoteDevice? {
    let hash = Self.hash(token)
    return lock.withLock {
      guard let index = devices.firstIndex(where: { $0.tokenHash == hash }) else { return nil }
      devices[index].lastSeen = now
      try? save()  // lastSeen is informational; a failed write must not lock the device out
      return devices[index]
    }
  }

  public func revoke(id: String) throws {
    try lock.withLock {
      devices.removeAll { $0.id == id }
      try save()
    }
  }

  public func revokeAll() throws {
    try lock.withLock {
      devices.removeAll()
      code = nil
      try save()
    }
  }

  private func save() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try RemoteFiles.writePrivate(encoder.encode(devices), to: file)
  }

  static func hash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
