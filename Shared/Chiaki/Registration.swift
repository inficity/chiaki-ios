import ChiakiCore
import Foundation

/// PS5 등록 결과. 스트리밍 접속과 원격 켜기에 쓴다.
struct RegisteredConsole: Codable, Equatable {
	var target: ChiakiTarget.RawValue
	/// rp_regist_key: 16바이트, 남는 부분은 0
	var registKey: Data
	/// rp_key: 세션 암호화에 쓰는 16바이트 키 (ChiakiConnectInfo.morning)
	var morning: Data
	var nickname: String
	var mac: Data

	init(_ host: ChiakiRegisteredHost) {
		target = host.target.rawValue
		registKey = withUnsafeBytes(of: host.rp_regist_key) { Data($0) }
		morning = withUnsafeBytes(of: host.rp_key) { Data($0) }
		nickname = withUnsafeBytes(of: host.server_nickname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
		mac = withUnsafeBytes(of: host.server_mac) { Data($0) }
	}

	/// chiaki-ng 설정에서 가져온 등록 (같은 값이라 PIN 등록을 다시 할 필요가 없다)
	init(imported console: ChiakiConfig.Console) {
		target = console.target
		registKey = console.registKey
		morning = console.morning
		nickname = console.nickname
		mac = console.mac
	}

	/// 원격 켜기 패킷에 넣는 값: regist key를 16진수 문자열로 읽은 것
	var wakeCredential: UInt64? {
		let key = registKey.prefix { $0 != 0 }
		guard key.count <= 8, let hex = String(data: key, encoding: .ascii) else { return nil }
		return UInt64(hex, radix: 16)
	}
}

enum RegistError: LocalizedError {
	case invalidAccountID
	case invalidPIN
	case failed

	var errorDescription: String? {
		switch self {
		case .invalidAccountID: "PSN 계정 ID는 8바이트를 base64로 인코딩한 값이어야 합니다 (예: AbCdEfGhIjk=)."
		case .invalidPIN: "PIN은 PS5 화면에 표시된 8자리 숫자입니다."
		case .failed: "등록에 실패했습니다. PIN이 만료되지 않았는지, 계정 ID가 맞는지 확인하세요."
		}
	}
}

enum ConsoleRegistrar {
	static func register(address: String, accountID: String, pin: String) async throws -> RegisteredConsole {
		guard let account = Data(base64Encoded: accountID.trimmingCharacters(in: .whitespaces)),
		      account.count == Int(CHIAKI_PSN_ACCOUNT_ID_SIZE) else { throw RegistError.invalidAccountID }
		guard pin.count == 8, let pinValue = UInt32(pin) else { throw RegistError.invalidPIN }

		return try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(with: Result {
					try registerBlocking(address: address, account: account, pin: pinValue)
				})
			}
		}
	}

	private final class Reply {
		let done = DispatchSemaphore(value: 0)
		var result: RegisteredConsole?
	}

	private static func registerBlocking(address: String, account: Data, pin: UInt32) throws -> RegisteredConsole {
		// regist 스레드가 끝날 때까지 info.host를 참조하므로 fini 이후에 해제한다
		let host = strdup(address)
		defer { free(host) }

		var info = ChiakiRegistInfo()
		info.target = CHIAKI_TARGET_PS5_1
		info.host = UnsafePointer(host)
		info.broadcast = false
		info.psn_online_id = nil
		info.pin = pin
		withUnsafeMutableBytes(of: &info.psn_account_id) { $0.copyBytes(from: account) }

		let regist = UnsafeMutablePointer<ChiakiRegist>.allocate(capacity: 1)
		regist.initialize(to: ChiakiRegist())
		defer { regist.deallocate() }

		let reply = Reply()
		let replyRef = Unmanaged.passRetained(reply)
		defer { replyRef.release() }

		try ChiakiError.check(chiaki_regist_start(regist, ChiakiLogger.shared.log, &info, { event, user in
			guard let event, let user else { return }
			let reply = Unmanaged<Reply>.fromOpaque(user).takeUnretainedValue()
			if event.pointee.type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS, let host = event.pointee.registered_host {
				reply.result = RegisteredConsole(host.pointee)
			}
			reply.done.signal()
		}, replyRef.toOpaque()))
		defer { chiaki_regist_fini(regist) }

		if reply.done.wait(timeout: .now() + 20) == .timedOut {
			chiaki_regist_stop(regist)
		}
		guard let result = reply.result else { throw RegistError.failed }
		return result
	}
}

enum ConsoleWaker {
	/// 휴식 모드의 PS5에 켜기 패킷을 보낸다. 유니캐스트라 subnet router 너머로도 전달된다.
	static func wake(address: String, registration: RegisteredConsole) throws {
		guard let credential = registration.wakeCredential else { throw RegistError.failed }
		try ChiakiError.check(chiaki_discovery_wakeup(ChiakiLogger.shared.log, nil, address, credential, true))
	}
}
