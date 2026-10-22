import ChiakiCore
import Foundation

/// PS5 discovery 응답에서 뽑아낸 정보
struct ConsoleStatus: Equatable {
	enum Power { case ready, standby, unknown }

	var power: Power
	var hostName: String?
	var hostID: String?
	var systemVersion: String?
	var runningApp: String?
}

enum ProbeError: LocalizedError {
	case invalidAddress
	case noResponse

	var errorDescription: String? {
		switch self {
		case .invalidAddress: "IP 주소 형식이 올바르지 않습니다."
		case .noResponse: "응답이 없습니다."
		}
	}
}

/// 콘솔 IP로 discovery 패킷(SRCH)을 직접 보내 상태를 확인한다.
/// Tailscale 너머로는 브로드캐스트가 전달되지 않으므로 항상 유니캐스트로 보낸다.
enum ConsoleProbe {
	static func probe(address: String, timeout: TimeInterval = 2) async throws -> ConsoleStatus {
		try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(with: Result { try probeBlocking(address: address, timeout: timeout) })
			}
		}
	}

	/// discovery 스레드 콜백에서 결과를 받아오는 상자
	private final class Reply {
		let done = DispatchSemaphore(value: 0)
		var status: ConsoleStatus?
	}

	private static func probeBlocking(address: String, timeout: TimeInterval) throws -> ConsoleStatus {
		var addr = sockaddr_in()
		addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = in_port_t(UInt16(CHIAKI_DISCOVERY_PORT_PS5).bigEndian)
		guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { throw ProbeError.invalidAddress }

		let discovery = UnsafeMutablePointer<ChiakiDiscovery>.allocate(capacity: 1)
		let thread = UnsafeMutablePointer<ChiakiDiscoveryThread>.allocate(capacity: 1)
		defer {
			discovery.deallocate()
			thread.deallocate()
		}

		try ChiakiError.check(chiaki_discovery_init(discovery, ChiakiLogger.shared.log, sa_family_t(AF_INET)))
		defer { chiaki_discovery_fini(discovery) }

		let reply = Reply()
		let replyPtr = Unmanaged.passRetained(reply)
		defer { replyPtr.release() }

		try ChiakiError.check(chiaki_discovery_thread_start_oneshot(thread, discovery, { host, user in
			guard let host, let user else { return }
			let reply = Unmanaged<Reply>.fromOpaque(user).takeUnretainedValue()
			// host 포인터는 콜백 동안만 유효하므로 여기서 복사한다
			let h = host.pointee
			let power: ConsoleStatus.Power = switch h.state {
			case CHIAKI_DISCOVERY_HOST_STATE_READY: .ready
			case CHIAKI_DISCOVERY_HOST_STATE_STANDBY: .standby
			default: .unknown
			}
			reply.status = ConsoleStatus(
				power: power,
				hostName: h.host_name.map { String(cString: $0) },
				hostID: h.host_id.map { String(cString: $0) },
				systemVersion: h.system_version.map { String(cString: $0) },
				runningApp: h.running_app_name.map { String(cString: $0) })
			reply.done.signal()
		}, replyPtr.toOpaque()))
		defer { chiaki_discovery_thread_stop(thread) }

		let version = strdup(CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5)
		defer { free(version) }
		var packet = ChiakiDiscoveryPacket()
		packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH
		packet.protocol_version = version

		// UDP라 유실될 수 있으니 응답이 올 때까지 몇 번 다시 보낸다
		let attempts = 3
		for _ in 0..<attempts {
			let err = withUnsafeMutablePointer(to: &addr) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					chiaki_discovery_send(discovery, &packet, $0, MemoryLayout<sockaddr_in>.size)
				}
			}
			try ChiakiError.check(err)
			if reply.done.wait(timeout: .now() + timeout / Double(attempts)) == .success {
				return reply.status!
			}
		}
		throw ProbeError.noResponse
	}
}
