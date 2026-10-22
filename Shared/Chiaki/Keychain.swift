import Foundation
import os
import Security

/// 콘솔 등록 키(regist key, morning)는 접속 자격 증명이므로 Keychain에 둔다.
/// iCloud 키체인으로 동기화해서 iPhone/iPad/Mac이 등록 한 번으로 같이 쓴다.
/// (등록은 기기에 묶이지 않는다: 요청에 기기 ID가 없고, 세션의 기기 ID는 매번 무작위로 만든다)
enum Keychain {
	private static let service = "ChiakiRemote.registration"
	private static let log = Logger(subsystem: "ChiakiRemote", category: "keychain")

	/// iCloud 키체인에 저장했으면 true, 이 기기에만 저장했으면 false
	@discardableResult
	static func set(_ data: Data, for account: String) -> Bool {
		SecItemDelete(syncedQuery(account) as CFDictionary)
		SecItemDelete(legacyQuery(account) as CFDictionary)

		var add = syncedQuery(account)
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		let status = SecItemAdd(add as CFDictionary, nil)
		guard status != errSecSuccess else { return true }

		// 엔타이틀먼트가 없는 빌드 등에서 iCloud 키체인을 못 쓰면 이 기기에만 저장한다
		log.error("iCloud 키체인 저장 실패 (\(status)), 이 기기에만 저장")
		var local = legacyQuery(account)
		local[kSecValueData as String] = data
		SecItemAdd(local as CFDictionary, nil)
		return false
	}

	static func get(_ account: String) -> Data? {
		if let data = copy(syncedQuery(account)) { return data }
		// 이전 버전이 이 기기 전용으로 저장한 항목은 iCloud 키체인으로 옮긴다
		guard let legacy = copy(legacyQuery(account)) else { return nil }
		set(legacy, for: account)
		return legacy
	}

	static func delete(_ account: String) {
		SecItemDelete(syncedQuery(account) as CFDictionary)
		SecItemDelete(legacyQuery(account) as CFDictionary)
	}

	private static func copy(_ query: [String: Any]) -> Data? {
		var query = query
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
		return result as? Data
	}

	private static func syncedQuery(_ account: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: account,
		 kSecAttrSynchronizable as String: true,
		 kSecUseDataProtectionKeychain as String: true]
	}

	/// 이전 버전 형식: 동기화하지 않는 항목 (macOS에서는 로그인 키체인 파일)
	private static func legacyQuery(_ account: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: account]
	}
}
