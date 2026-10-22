import Foundation
import Security

/// 콘솔 등록 키(regist key, morning)는 접속 자격 증명이므로 UserDefaults 대신 Keychain에 둔다.
enum Keychain {
	private static let service = "ChiakiRemote.registration"

	static func set(_ data: Data, for account: String) {
		let query = baseQuery(account)
		SecItemDelete(query as CFDictionary)
		var add = query
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		SecItemAdd(add as CFDictionary, nil)
	}

	static func get(_ account: String) -> Data? {
		var query = baseQuery(account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
		return result as? Data
	}

	static func delete(_ account: String) {
		SecItemDelete(baseQuery(account) as CFDictionary)
	}

	private static func baseQuery(_ account: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: account]
	}
}
