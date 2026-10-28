import Darwin

/// IPv4 ranges the Mac accepts connections from (DEV_SPEC §17.3), shared with clients so they
/// only try addresses the Mac will accept.
public enum RemoteAddressRange {
  public static func isAllowedV4(_ a: UInt32) -> Bool {
    func within(_ base: UInt32, _ bits: UInt32) -> Bool { a >> (32 - bits) == base >> (32 - bits) }
    return within(0x7F00_0000, 8)  // 127/8
      || within(0x0A00_0000, 8)  // 10/8
      || within(0xAC10_0000, 12)  // 172.16/12
      || within(0xC0A8_0000, 16)  // 192.168/16
      || within(0xA9FE_0000, 16)  // 169.254/16
      || within(0x6440_0000, 10)  // 100.64/10 (Tailscale CGNAT range)
  }

  public static func isTailscaleV4(_ a: UInt32) -> Bool { a >> 22 == 0x6440_0000 >> 22 }

  /// A Tailscale address: 100.64/10 or fd7a:115c:a1e0::/48.
  static func isTailscale(_ host: String) -> Bool {
    var v4 = in_addr()
    if inet_pton(AF_INET, host, &v4) == 1 { return isTailscaleV4(UInt32(bigEndian: v4.s_addr)) }
    return host.lowercased().hasPrefix("fd7a:115c:a1e0:")
  }

  /// LAN addresses before Tailscale ones, each group in its given order: when both answer, the
  /// LAN is the direct path, even if Tailscale answered last time.
  static func preferringLAN(_ hosts: [String]) -> [String] {
    hosts.filter { !isTailscale($0) } + hosts.filter(isTailscale)
  }
}
