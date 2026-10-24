import Foundation
import SMProtocol
import Security

/// Paired Macs, kept in the Keychain (they carry device tokens), readable after first unlock and
/// never synced or backed up to another device.
enum ServerStore {
  private static let service = "local.sessionmonitor.mobile"
  private static let account = "paired-servers"

  static func load() -> [PairedServer] {
    var result: CFTypeRef?
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ]
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return [] }
    return (try? JSONDecoder().decode([PairedServer].self, from: data)) ?? []
  }

  static func save(_ servers: [PairedServer]) throws {
    let data = try JSONEncoder().encode(servers)
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
