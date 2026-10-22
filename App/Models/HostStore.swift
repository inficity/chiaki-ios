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
	case online(ConsoleStatus)
	case unreachable(String)
}

@MainActor @Observable
final class HostStore {
	private(set) var hosts: [ConsoleHost] = []
	private(set) var states: [ConsoleHost.ID: ProbeState] = [:]

	private static let defaultsKey = "hosts"

	init() {
		if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
		   let saved = try? JSONDecoder().decode([ConsoleHost].self, from: data) {
			hosts = saved
		}
	}

	func add(_ host: ConsoleHost) {
		hosts.append(host)
		save()
		Task { await refresh(host) }
	}

	func remove(at offsets: IndexSet) {
		for i in offsets { states[hosts[i].id] = nil }
		hosts.remove(atOffsets: offsets)
		save()
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

	private func save() {
		if let data = try? JSONEncoder().encode(hosts) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
	}
}
