import Foundation

/// iPhone/iPad/Mac이 공유하는 설정 저장소 (iCloud 키-값 저장소).
/// UserDefaults에도 같이 써서 iCloud에 로그인하지 않았거나 동기화 전이어도 동작한다.
enum CloudSettings {
	private static var store: NSUbiquitousKeyValueStore { .default }
	private static var local: UserDefaults { .standard }

	/// 앱 시작 시 한 번: iCloud에서 최신 값을 받아오기 시작한다
	static func start() {
		store.synchronize()
	}

	static func data(forKey key: String) -> Data? {
		store.data(forKey: key) ?? local.data(forKey: key)
	}

	static func string(forKey key: String) -> String? {
		store.string(forKey: key) ?? local.string(forKey: key)
	}

	/// iCloud에 아직 값이 없을 때 (이전 버전에서 넘어온 경우 등)
	static func isMissingInCloud(_ key: String) -> Bool {
		store.object(forKey: key) == nil
	}

	static func set(_ value: Any?, forKey key: String) {
		store.set(value, forKey: key)
		local.set(value, forKey: key)
	}

	/// 다른 기기에서 값이 바뀌면 메인 스레드에서 changedKeys와 함께 호출된다
	static func observe(_ handler: @escaping (_ changedKeys: Set<String>) -> Void) -> NSObjectProtocol {
		NotificationCenter.default.addObserver(
			forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
		) { note in
			let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
			// iCloud 값을 이 기기 UserDefaults에도 반영해 둔다
			for key in keys { local.set(store.object(forKey: key), forKey: key) }
			handler(Set(keys))
		}
	}
}
