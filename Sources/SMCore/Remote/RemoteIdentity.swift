import Foundation
import SMProtocol
import Security

/// The server's TLS identity: a self-signed certificate whose fingerprint clients pin at pairing.
/// Kept in `<directory>/remote/identity.p12` (0600) with a random passphrase beside it. RSA, not
/// P-256: SecPKCS12Import rejects the EC keys LibreSSL writes (DECISIONS 2026-10-24).
public struct RemoteIdentity: @unchecked Sendable {
  public let identity: SecIdentity
  public let fingerprint: String

  public static func loadOrCreate(directory: URL) throws -> RemoteIdentity {
    let folder = try RemoteFiles.folder(directory)
    let p12 = folder.appendingPathComponent("identity.p12")
    let pass = folder.appendingPathComponent("identity.pass")
    if !FileManager.default.fileExists(atPath: p12.path) {
      try create(p12: p12, passFile: pass)
    }
    let passphrase = try String(contentsOf: pass, encoding: .utf8)
    return try load(p12: Data(contentsOf: p12), passphrase: passphrase)
  }

  static func load(p12 data: Data, passphrase: String) throws -> RemoteIdentity {
    var items: CFArray?
    var options: [CFString: Any] = [kSecImportExportPassphrase: passphrase]
    // Without this, macOS stores the key in the login keychain, and every rebuilt (re-signed) app
    // then waits on a keychain access prompt during the TLS handshake (seen in R1).
    if #available(macOS 15, *) { options[kSecImportToMemoryOnly] = true }
    let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
    guard status == errSecSuccess,
      let first = (items as? [[String: Any]])?.first,
      let value = first[kSecImportItemIdentity as String]
    else { throw MonitorError.system("SecPKCS12Import", status) }
    let identity = value as! SecIdentity
    var certificate: SecCertificate?
    let copied = SecIdentityCopyCertificate(identity, &certificate)
    guard copied == errSecSuccess, let certificate else {
      throw MonitorError.system("SecIdentityCopyCertificate", copied)
    }
    return RemoteIdentity(
      identity: identity,
      fingerprint: RemoteFingerprint.sha256Hex(SecCertificateCopyData(certificate) as Data))
  }

  /// Regenerating invalidates every pairing (the fingerprint changes).
  public static func reset(directory: URL) throws {
    let folder = try RemoteFiles.folder(directory)
    for name in ["identity.p12", "identity.pass"] {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  private static func create(p12: URL, passFile: URL) throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sm-identity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: work) }
    let key = work.appendingPathComponent("key.pem").path
    let cert = work.appendingPathComponent("cert.pem").path
    let out = work.appendingPathComponent("identity.p12").path
    let passphrase = RemoteFiles.randomToken(bytes: 24)
    let openssl = "/usr/bin/openssl"
    _ = try ProcessRunner.runSync(
      openssl,
      arguments: [
        "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-keyout", key, "-out", cert,
        "-days", "3650", "-subj", "/CN=SessionMonitor",
      ], timeout: 30)
    // Legacy PBE/MAC algorithms: what SecPKCS12Import reads from LibreSSL output.
    _ = try ProcessRunner.runSync(
      openssl,
      arguments: [
        "pkcs12", "-export", "-inkey", key, "-in", cert, "-out", out, "-passout", "pass:" + passphrase,
        "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
      ], timeout: 30)
    try RemoteFiles.writePrivate(Data(passphrase.utf8), to: passFile)
    try RemoteFiles.writePrivate(Data(contentsOf: URL(fileURLWithPath: out)), to: p12)
  }
}

enum RemoteFiles {
  static func folder(_ directory: URL) throws -> URL {
    let folder = directory.appendingPathComponent("remote")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    return folder
  }

  static func randomToken(bytes count: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  /// Atomic replace with 0600 from the start (never briefly world-readable).
  static func writePrivate(_ data: Data, to url: URL) throws {
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
    try? FileManager.default.removeItem(at: temp)
    let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw MonitorError.system("open \(temp.lastPathComponent)", errno) }
    let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    Darwin.close(fd)
    guard count == data.count else { throw MonitorError.system("write \(url.lastPathComponent)", errno) }
    guard rename(temp.path, url.path) == 0 else {
      throw MonitorError.system("rename \(url.lastPathComponent)", errno)
    }
  }
}
