#if DEBUG
import Foundation
import Security

/// 서명된 앱에서 iCloud 키체인과 키-값 저장소가 실제로 동작하는지 확인한다.
/// 실행: <앱 실행 파일> -cloudSelfTest  (결과를 출력하고 종료)
enum CloudSelfTest {
	static func run() -> Never {
		let account = "selftest-\(UUID().uuidString)"
		let payload = Data("chiaki".utf8)

		let synced = Keychain.set(payload, for: account)
		let readBack = Keychain.get(account) == payload
		Keychain.delete(account)
		let deleted = Keychain.get(account) == nil
		print("keychain: iCloud=\(synced) read=\(readBack) delete=\(deleted)")

		// 이전 버전처럼 동기화하지 않는 항목을 만든 뒤, 읽을 때 iCloud 키체인으로 옮겨지는지
		let legacyAccount = "selftest-legacy-\(UUID().uuidString)"
		let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "ChiakiRemote.registration",
			kSecAttrAccount as String: legacyAccount,
			kSecValueData as String: payload]
		SecItemAdd(legacy as CFDictionary, nil)
		let migratedRead = Keychain.get(legacyAccount) == payload
		var leftover = legacy
		leftover.removeValue(forKey: kSecValueData as String)
		let legacyRemoved = SecItemCopyMatching(leftover as CFDictionary, nil) == errSecItemNotFound
		Keychain.delete(legacyAccount)
		print("migration: read=\(migratedRead) legacyRemoved=\(legacyRemoved)")

		CloudSettings.start()
		let key = "selftest"
		CloudSettings.set("ok", forKey: key)
		let kvs = NSUbiquitousKeyValueStore.default.string(forKey: key) == "ok"
		CloudSettings.set(nil, forKey: key)
		let signedIn = FileManager.default.ubiquityIdentityToken != nil
		print("kvstore: write/read=\(kvs) iCloudSignedIn=\(signedIn)")

		let pass = synced && readBack && deleted && kvs && migratedRead && legacyRemoved
		print(pass ? "PASS" : "FAIL")
		exit(pass ? 0 : 1)
	}
}
#endif
