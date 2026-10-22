import Foundation
import Observation

/// 직접 입력한 PS5 (Tailscale subnet router 너머의 LAN IP)
struct ConsoleHost: Identifiable, Codable, Hashable {
	var id = UUID()
	var name: String
	var address: String
}

enum ProbeState: Equatable {
	case checking
	case waking
	case online(ConsoleStatus)
	case unreachable(String)
}

@MainActor @Observable
final class HostStore {
	private(set) var hosts: [ConsoleHost] = []
	private(set) var states: [ConsoleHost.ID: ProbeState] = [:]
	private(set) var registrations: [ConsoleHost.ID: RegisteredConsole] = [:]

	private static let defaultsKey = "hosts"

	init() {
		if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
		   let saved = try? JSONDecoder().decode([ConsoleHost].self, from: data) {
			hosts = saved
		}
		for host in hosts {
			if let data = Keychain.get(host.id.uuidString),
			   let registration = try? JSONDecoder().decode(RegisteredConsole.self, from: data) {
				registrations[host.id] = registration
			}
		}
	}

	func add(_ host: ConsoleHost) {
		hosts.append(host)
		save()
		Task { await refresh(host) }
	}

	func remove(at offsets: IndexSet) {
		for i in offsets { forget(hosts[i]) }
		hosts.remove(atOffsets: offsets)
		save()
	}

	func remove(_ host: ConsoleHost) {
		if let i = hosts.firstIndex(of: host) { remove(at: [i]) }
	}

	func setRegistration(_ registration: RegisteredConsole?, for host: ConsoleHost) {
		registrations[host.id] = registration
		if let registration, let data = try? JSONEncoder().encode(registration) {
			Keychain.set(data, for: host.id.uuidString)
		} else {
			Keychain.delete(host.id.uuidString)
		}
	}

	func refreshAll() async {
		await withTaskGroup(of: Void.self) { group in
			for host in hosts {
				group.addTask { await self.refresh(host) }
			}
		}
	}

	func refresh(_ host: ConsoleHost) async {
		states[host.id] = .checking
		do {
			let status = try await ConsoleProbe.probe(address: host.address)
			states[host.id] = .online(status)
		} catch {
			states[host.id] = .unreachable(error.localizedDescription)
		}
	}

	/// 켜기 패킷을 보내고 PS5가 준비될 때까지 기다린다. 준비되면 true.
	func wake(_ host: ConsoleHost) async -> Bool {
		guard let registration = registrations[host.id] else { return false }
		states[host.id] = .waking
		do {
			try ConsoleWaker.wake(address: host.address, registration: registration)
		} catch {
			states[host.id] = .unreachable(error.localizedDescription)
			return false
		}
		// PS5가 휴식 모드에서 깨어나는 데 보통 10~20초 걸린다
		for _ in 0..<20 {
			try? await Task.sleep(for: .seconds(2))
			if let status = try? await ConsoleProbe.probe(address: host.address, timeout: 1), status.power == .ready {
				states[host.id] = .online(status)
				return true
			}
		}
		await refresh(host)
		return false
	}

	private func forget(_ host: ConsoleHost) {
		states[host.id] = nil
		setRegistration(nil, for: host)
	}

	private func save() {
		if let data = try? JSONEncoder().encode(hosts) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
	}
}
