import Darwin
import Foundation

/// Which peers may connect (DEV_SPEC §17.3): loopback, private LAN, link-local and Tailscale.
public enum RemoteAddressPolicy {
  public static func isAllowed(_ host: String) -> Bool {
    let bare = String(host.split(separator: "%", maxSplits: 1).first ?? "")
    var v4 = in_addr()
    if inet_pton(AF_INET, bare, &v4) == 1 { return isAllowedV4(UInt32(bigEndian: v4.s_addr)) }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, bare, &v6) == 1 else { return false }
    let b = withUnsafeBytes(of: v6) { Array($0) }
    if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }  // ::1
    if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {  // ::ffff:a.b.c.d
      return isAllowedV4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
    }
    if b[0] & 0xFE == 0xFC { return true }  // fc00::/7 ULA, includes Tailscale fd7a:115c:a1e0::/48
    if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }  // fe80::/10 link-local
    return false
  }

  static func isAllowedV4(_ a: UInt32) -> Bool {
    func within(_ base: UInt32, _ bits: UInt32) -> Bool { a >> (32 - bits) == base >> (32 - bits) }
    return within(0x7F00_0000, 8)  // 127/8
      || within(0x0A00_0000, 8)  // 10/8
      || within(0xAC10_0000, 12)  // 172.16/12
      || within(0xC0A8_0000, 16)  // 192.168/16
      || within(0xA9FE_0000, 16)  // 169.254/16
      || within(0x6440_0000, 10)  // 100.64/10 (Tailscale CGNAT range)
  }

  static func isTailscaleV4(_ a: UInt32) -> Bool { a >> 22 == 0x6440_0000 >> 22 }

  /// IPv4 addresses a phone can use: LAN (private ranges) and Tailscale, each sorted.
  public static func localAddresses() -> (lan: [String], tailscale: [String]) {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return ([], []) }
    defer { freeifaddrs(head) }
    var lan: Set<String> = []
    var tailscale: Set<String> = []
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let entry = pointer.pointee
      guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
        entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
      else { continue }
      let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
      }
      var raw = in_addr(s_addr: value.bigEndian)
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil else { continue }
      let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      if isTailscaleV4(value) {
        tailscale.insert(text)
      } else if isAllowedV4(value), value >> 16 != 0xA9FE {  // link-local is not worth offering
        lan.insert(text)
      }
    }
    return (lan.sorted(), tailscale.sorted())
  }
}
