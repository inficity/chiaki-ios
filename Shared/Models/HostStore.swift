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

	private static let hostsKey = "hosts"
	@ObservationIgnored private var cloudObserver: NSObjectProtocol?
	/// 이번 실행에서 이 기기 목록을 iCloud로 처음 옮겼다면, 다른 기기 목록이 도착할 때 한 번 더 합친다
	@ObservationIgnored private var mergeNextCloudHosts = false

	init() {
		CloudSettings.start()
		let local = Self.decodeHosts(UserDefaults.standard.data(forKey: Self.hostsKey))
		if CloudSettings.isMissingInCloud(Self.hostsKey) && !local.isEmpty {
			// 이전 버전(기기별 저장)에서 넘어옴
			hosts = local
			mergeNextCloudHosts = true
			save()
		} else {
			hosts = Self.decodeHosts(CloudSettings.data(forKey: Self.hostsKey))
		}
		reloadRegistrations()

		cloudObserver = CloudSettings.observe { [weak self] keys in
			guard keys.contains(Self.hostsKey) else { return }
			MainActor.assumeIsolated { self?.applyCloudHosts() }
		}
	}

	/// 다른 기기에서 PS5 목록이 바뀜
	private func applyCloudHosts() {
		var incoming = Self.decodeHosts(CloudSettings.data(forKey: Self.hostsKey))
		if mergeNextCloudHosts {
			mergeNextCloudHosts = false
			let known = Set(incoming.map(\.id))
			incoming += hosts.filter { !known.contains($0.id) }
			hosts = incoming
			save()
		} else {
			hosts = incoming
		}
		let ids = Set(hosts.map(\.id))
		states = states.filter { ids.contains($0.key) }
		reloadRegistrations()
		Task { await refreshAll() }
	}

	/// 등록 키는 iCloud 키체인으로 따로 동기화되므로 목록과 도착 시점이 다를 수 있다. 볼 때마다 다시 읽는다.
	func reloadRegistrations() {
		var loaded: [ConsoleHost.ID: RegisteredConsole] = [:]
		for host in hosts {
			if let data = Keychain.get(host.id.uuidString),
			   let registration = try? JSONDecoder().decode(RegisteredConsole.self, from: data) {
				loaded[host.id] = registration
			}
		}
		if loaded != registrations { registrations = loaded }
	}

	private static func decodeHosts(_ data: Data?) -> [ConsoleHost] {
		data.flatMap { try? JSONDecoder().decode([ConsoleHost].self, from: $0) } ?? []
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

	/// chiaki-ng에서 가져온 콘솔을 목록에 넣고 등록 키를 저장한다.
	/// 같은 콘솔(MAC)이 이미 있으면 등록만 바꾸고, 그 항목의 IP는 그대로 둔다.
	@discardableResult
	func importConsoles(_ consoles: [ChiakiConfig.Console]) -> [ConsoleHost] {
		var imported: [ConsoleHost] = []
		for console in consoles {
			guard let address = console.address?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { continue }
			let host = hosts.first { registrations[$0.id]?.mac == console.mac }
				?? hosts.first { $0.address == address }
				?? {
					let new = ConsoleHost(name: console.nickname, address: address)
					hosts.append(new)
					return new
				}()
			setRegistration(RegisteredConsole(imported: console), for: host)
			imported.append(host)
		}
		save()
		Task { await refreshAll() }
		return imported
	}

	func refreshAll() async {
		reloadRegistrations()
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
			CloudSettings.set(data, forKey: Self.hostsKey)
		}
	}
}
