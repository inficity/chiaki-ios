import SwiftUI

struct HostListView: View {
	@Environment(HostStore.self) private var store
	@State private var showingAdd = false

	var body: some View {
		NavigationStack {
			List {
				ForEach(store.hosts) { host in
					HostRow(host: host, state: store.states[host.id])
						.contentShape(Rectangle())
						.onTapGesture { Task { await store.refresh(host) } }
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
				Button("추가", systemImage: "plus") { showingAdd = true }
			}
			.refreshable { await store.refreshAll() }
			.task { await store.refreshAll() }
			.sheet(isPresented: $showingAdd) {
				AddHostView { store.add($0) }
			}
		}
	}
}

private struct HostRow: View {
	let host: ConsoleHost
	let state: ProbeState?

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "playstation.logo")
				.font(.title2)
				.foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 2) {
				Text(host.name).font(.headline)
				Text(host.address).font(.caption.monospaced()).foregroundStyle(.secondary)
				if case .online(let status) = state, let app = status.runningApp {
					Text(app).font(.caption).foregroundStyle(.secondary)
				}
			}
			Spacer()
			StatusBadge(state: state)
		}
		.padding(.vertical, 4)
	}
}

private struct StatusBadge: View {
	let state: ProbeState?

	var body: some View {
		switch state {
		case .checking, nil:
			ProgressView()
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
