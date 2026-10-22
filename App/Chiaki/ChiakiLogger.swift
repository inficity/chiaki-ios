import ChiakiCore
import Foundation
import os

/// libchiaki 로그를 OSLog로 넘긴다. ChiakiLog는 C 쪽에서 포인터로 계속 참조하므로 앱 수명 동안 유지한다.
final class ChiakiLogger {
	static let shared = ChiakiLogger()

	let log: UnsafeMutablePointer<ChiakiLog>

	private init() {
		log = .allocate(capacity: 1)
		let levels = CHIAKI_LOG_ERROR.rawValue | CHIAKI_LOG_WARNING.rawValue | CHIAKI_LOG_INFO.rawValue
		chiaki_log_init(log, levels, { level, msg, _ in
			guard let msg else { return }
			let text = String(cString: msg)
			switch level {
			case CHIAKI_LOG_ERROR: ChiakiLogger.os.error("\(text, privacy: .public)")
			case CHIAKI_LOG_WARNING: ChiakiLogger.os.warning("\(text, privacy: .public)")
			default: ChiakiLogger.os.info("\(text, privacy: .public)")
			}
		}, nil)
	}

	private static let os = Logger(subsystem: "ChiakiRemote", category: "chiaki")
}

struct ChiakiError: LocalizedError {
	let code: ChiakiErrorCode

	var errorDescription: String? { String(cString: chiaki_error_string(code)) }

	static func check(_ code: ChiakiErrorCode) throws {
		if code != CHIAKI_ERR_SUCCESS { throw ChiakiError(code: code) }
	}
}
