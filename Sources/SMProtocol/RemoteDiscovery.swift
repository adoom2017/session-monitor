import Foundation
import Network
import dnssd

/// Finds a paired Mac on the current network by Bonjour, for when the addresses saved at pairing
/// no longer answer (the Mac changed networks). The Mac advertises `RemoteProtocol.serviceType`
/// with its fingerprint tag in the TXT record; the connection that follows still checks the full
/// certificate pin, so a spoofed advertisement gains nothing.
public enum RemoteDiscovery {
  /// IPv4 addresses of the Mac with this certificate fingerprint that it accepts connections on
  /// (LAN or Tailscale ranges); empty when none is found within `timeout`.
  public static func find(fingerprint: String, timeout: TimeInterval = 3) async -> [String] {
    await Search(tag: RemoteProtocol.fingerprintTag(fingerprint)).run(timeout: timeout)
  }

  /// Browse (NWBrowser) → resolve the service to its host name (DNS-SD) → that host's IPv4
  /// addresses (getaddrinfo, over mDNS for .local names). Nothing connects to the Mac.
  private final class Search: @unchecked Sendable {
    private let tag: String
    private let queue = DispatchQueue(label: "sessionmonitor.discovery")
    // Touched only on `queue`.
    private var browser: NWBrowser?
    private var seen: Set<NWEndpoint> = []
    private var resolves: [DNSServiceRef] = []
    private var continuation: CheckedContinuation<[String], Never>?

    init(tag: String) { self.tag = tag }

    func run(timeout: TimeInterval) async -> [String] {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          self.continuation = continuation
          let parameters = NWParameters()
          parameters.includePeerToPeer = false
          let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: RemoteProtocol.serviceType, domain: nil), using: parameters)
          browser.browseResultsChangedHandler = { [self] results, _ in
            for result in results { resolve(result) }
          }
          browser.stateUpdateHandler = { [self] state in
            if case .failed = state { finish([]) }
          }
          self.browser = browser
          browser.start(queue: queue)
          queue.asyncAfter(deadline: .now() + timeout) { [self] in finish([]) }
        }
      }
    }

    private func resolve(_ result: NWBrowser.Result) {
      guard case .bonjour(let txt) = result.metadata, txt[RemoteProtocol.fingerprintTXTKey] == tag,
        case .service(let name, let type, let domain, _) = result.endpoint,
        seen.insert(result.endpoint).inserted
      else { return }
      var ref: DNSServiceRef?
      // The context is this search, which outlives the resolve (finish deallocates it first).
      let context = Unmanaged.passUnretained(self).toOpaque()
      let status = DNSServiceResolve(
        &ref, 0, 0, name, type, domain.isEmpty ? "local." : domain,
        { _, _, _, error, _, host, _, _, _, context in
          guard error == kDNSServiceErr_NoError, let host, let context else { return }
          Unmanaged<Search>.fromOpaque(context).takeUnretainedValue().lookUp(String(cString: host))
        }, context)
      guard status == kDNSServiceErr_NoError, let ref else { return }
      resolves.append(ref)
      DNSServiceSetDispatchQueue(ref, queue)
    }

    /// Called on `queue`; getaddrinfo blocks, so it runs elsewhere.
    private func lookUp(_ host: String) {
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        let addresses = Self.ipv4Addresses(of: host)
        queue.async { [self] in
          if !addresses.isEmpty { finish(addresses) }
        }
      }
    }

    /// The host's IPv4 addresses the Mac accepts connections on. A Mac on two networks has an
    /// address on each, and only some may be in range. Loopback means this device itself.
    static func ipv4Addresses(of host: String) -> [String] {
      var hints = addrinfo()
      hints.ai_family = AF_INET
      hints.ai_socktype = SOCK_STREAM
      var list: UnsafeMutablePointer<addrinfo>?
      guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
      defer { freeaddrinfo(list) }
      var result: [String] = []
      for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
        guard let address = entry.pointee.ai_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        let value = UInt32(bigEndian: raw.s_addr)
        guard RemoteAddressRange.isAllowedV4(value), value >> 24 != 127 else { continue }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil else { continue }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if !result.contains(text) { result.append(text) }
      }
      return result
    }

    private func finish(_ hosts: [String]) {
      guard let continuation else { return }
      self.continuation = nil
      browser?.cancel()
      browser = nil
      for ref in resolves { DNSServiceRefDeallocate(ref) }
      resolves.removeAll()
      continuation.resume(returning: hosts)
    }
  }
}
