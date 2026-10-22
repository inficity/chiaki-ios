import SwiftUI

struct HostListView: View {
	@Environment(HostStore.self) private var store
	@Environment(AppSettings.self) private var settings
	@State private var showingAdd = false
	@State private var showingSettings = false
	@State private var registering: ConsoleHost?
	@State private var streaming: StreamSession?
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack {
			List {
				ForEach(store.hosts) { host in
					Button { open(host) } label: {
						HostRow(host: host, state: store.states[host.id], registered: store.registrations[host.id] != nil)
					}
					.foregroundStyle(.primary)
					.contextMenu { menu(for: host) }
				}
				.onDelete(perform: store.remove)
			}
			.overlay {
				if store.hosts.isEmpty {
					ContentUnavailableView {
						Label("등록된 PS5가 없습니다", systemImage: "playstation.logo")
					} description: {
						Text("Tailscale subnet router 너머의 PS5 LAN IP를 추가하세요.")
					} actions: {
						Button("PS5 추가") { showingAdd = true }
					}
				}
			}
			.navigationTitle("Chiaki")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("설정", systemImage: "gearshape") { showingSettings = true }
				}
				ToolbarItem(placement: .primaryAction) {
					Button("추가", systemImage: "plus") { showingAdd = true }
				}
			}
			.refreshable { await store.refreshAll() }
			.task { await store.refreshAll() }
			.sheet(isPresented: $showingAdd) {
				AddHostView { store.add($0) }
			}
			.sheet(isPresented: $showingSettings) { SettingsView() }
			.sheet(item: $registering) { RegisterView(host: $0) }
			.fullScreenCover(item: $streaming) { session in
				StreamView(session: session)
					.onDisappear { Task { await store.refreshAll() } }
			}
			.alert("접속할 수 없습니다", isPresented: Binding { errorMessage != nil } set: { if !$0 { errorMessage = nil } }) {
				Button("확인", role: .cancel) {}
			} message: {
				Text(errorMessage ?? "")
			}
		}
	}

	@ViewBuilder
	private func menu(for host: ConsoleHost) -> some View {
		Button("상태 새로고침", systemImage: "arrow.clockwise") {
			Task { await store.refresh(host) }
		}
		if store.registrations[host.id] != nil {
			Button("깨우기", systemImage: "power") {
				Task { _ = await store.wake(host) }
			}
			Button("다시 등록", systemImage: "key") { registering = host }
			Button("등록 해제", systemImage: "key.slash", role: .destructive) {
				store.setRegistration(nil, for: host)
			}
		} else {
			Button("등록", systemImage: "key") { registering = host }
		}
		Button("삭제", systemImage: "trash", role: .destructive) { store.remove(host) }
	}

	/// 탭: 미등록이면 등록, 휴식 모드면 깨운 뒤 접속, 켜져 있으면 바로 접속
	private func open(_ host: ConsoleHost) {
		guard store.registrations[host.id] != nil else {
			registering = host
			return
		}
		switch store.states[host.id] {
		case .online(let status) where status.power == .ready:
			startStream(host)
		case .online(let status) where status.power == .standby:
			Task {
				if await store.wake(host) { startStream(host) }
			}
		case .checking, .waking:
			break
		default:
			Task {
				await store.refresh(host)
				if case .online(let status) = store.states[host.id], status.power == .ready { startStream(host) }
			}
		}
	}

	private func startStream(_ host: ConsoleHost) {
		guard let registration = store.registrations[host.id] else { return }
		do {
			streaming = try StreamSession(host: host, registration: registration, settings: settings.stream)
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

private struct HostRow: View {
	let host: ConsoleHost
	let state: ProbeState?
	let registered: Bool

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "playstation.logo")
				.font(.title2)
				.foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 2) {
				Text(host.name).font(.headline)
				Text(host.address).font(.caption.monospaced()).foregroundStyle(.secondary)
				if !registered {
					Text("탭해서 등록").font(.caption).foregroundStyle(.tint)
				} else if case .online(let status) = state, let app = status.runningApp {
					Text(app).font(.caption).foregroundStyle(.secondary)
				}
			}
			Spacer()
			StatusBadge(state: state)
		}
		.padding(.vertical, 4)
		.contentShape(Rectangle())
	}
}

private struct StatusBadge: View {
	let state: ProbeState?

	var body: some View {
		switch state {
		case .checking, nil:
			ProgressView()
		case .waking:
			HStack(spacing: 6) {
				ProgressView()
				badge("깨우는 중", .orange)
			}
		case .online(let status):
			switch status.power {
			case .ready: badge("켜짐", .green)
			case .standby: badge("휴식 모드", .orange)
			case .unknown: badge("알 수 없음", .gray)
			}
		case .unreachable:
			badge("응답 없음", .red)
		}
	}

	private func badge(_ text: String, _ color: Color) -> some View {
		Text(text)
			.font(.caption.weight(.semibold))
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(color.opacity(0.15), in: Capsule())
			.foregroundStyle(color)
	}
}
