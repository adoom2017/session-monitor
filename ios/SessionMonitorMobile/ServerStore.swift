import Foundation
import SMProtocol
import Security

/// Paired Macs, kept in the Keychain (they carry device tokens), readable after first unlock and
/// never synced or backed up to another device.
enum ServerStore {
  private static let service = "local.sessionmonitor.mobile"
  private static let account = "paired-servers"

  static func load() -> [PairedServer] {
    guard let data = read(account) else { return [] }
    return (try? JSONDecoder().decode([PairedServer].self, from: data)) ?? []
  }

  static func save(_ servers: [PairedServer]) throws {
    try write(JSONEncoder().encode(servers), to: account)
  }

  /// This install's id (Hello.clientId), created on first use. Kept in the Keychain so the Mac
  /// still recognizes the phone after the app is reinstalled.
  static func clientID() -> String {
    if let data = read("client-id"), let id = String(data: data, encoding: .utf8), !id.isEmpty { return id }
    let id = UUID().uuidString
    try? write(Data(id.utf8), to: "client-id")
    return id
  }

  private static func read(_ account: String) -> Data? {
    var result: CFTypeRef?
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ]
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  private static func write(_ data: Data, to account: String) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
    ]
    let update: [CFString: Any] = [
      kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
        NSLocalizedDescriptionKey: "无法保存配对信息（\(status)）"
      ])
    }
  }
}
