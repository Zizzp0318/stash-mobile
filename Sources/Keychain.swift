import Foundation
import Security

/// token 存在 Keychain 而不是 UserDefaults。
///
/// 为什么值得多写这 40 行：token 等于整个素材库的读写权限，URL 里带 `?t=` 就已经
/// 比 header 更容易泄漏了；再把它明文丢进 UserDefaults（会被 iTunes/iCloud 备份带走、
/// 越狱机上直接可读）就是把「库里所有照片」的钥匙放在门口鞋柜上。
///
/// `kSecAttrAccessibleAfterFirstUnlock`：设备重启后**首次解锁前**读不到，解锁后可用。
/// 不用 `WhenUnlocked`，是因为后台续传需要在上锁状态下读 token。
enum Keychain {
    private static let service = "com.zizzp.stashmobile"

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(q as CFDictionary)
    }
}
