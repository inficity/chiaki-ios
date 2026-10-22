import SwiftUI
import UniformTypeIdentifiers

/// 파일 선택기에서 고른 chiaki-ng 설정 파일
struct ChiakiImportRequest: Identifiable {
	let id = UUID()
	let config: ChiakiConfig
	let url: URL

	static let contentTypes: [UTType] = [.data]

	/// 파일 선택기 결과를 읽는다. iOS에서는 보안 범위 접근이 필요하다.
	static func load(_ url: URL) throws -> ChiakiImportRequest {
		let accessing = url.startAccessingSecurityScopedResource()
		defer { if accessing { url.stopAccessingSecurityScopedResource() } }
		return ChiakiImportRequest(config: try ChiakiConfig(contentsOf: url), url: url)
	}
}

/// chiaki-ng(예: Steam Deck)에 등록된 PS5를 PIN 없이 가져온다
struct ImportView: View {
	let request: ChiakiImportRequest

	@Environment(HostStore.self) private var store
	@Environment(AppSettings.self) private var settings
	@Environment(\.dismiss) private var dismiss
	@State private var addresses: [Data: String] = [:]
	@State private var selected: Set<Data> = []
	@State private var imported: [ConsoleHost]?
	@State private var fileRemoved = false

	private var ps5s: [ChiakiConfig.Console] { request.config.consoles.filter(\.isPS5) }
	private var skipped: Int { request.config.consoles.count - ps5s.count }

	var body: some View {
		NavigationStack {
			Form {
				if let imported {
					resultSections(imported)
				} else {
					selectionSections
				}
			}
			.navigationTitle("chiaki-ng에서 가져오기")
			.inlineNavigationTitle()
			.toolbar {
				if imported == nil {
					ToolbarItem(placement: .cancellationAction) {
						Button("취소") { dismiss() }
					}
					ToolbarItem(placement: .confirmationAction) {
						Button("가져오기") { runImport() }
							.disabled(!canImport)
					}
				} else {
					ToolbarItem(placement: .confirmationAction) {
						Button("완료") { dismiss() }
					}
				}
			}
			.onAppear {
				for console in ps5s {
					addresses[console.mac] = console.address ?? ""
					selected.insert(console.mac)
				}
			}
		}
	}

	@ViewBuilder
	private var selectionSections: some View {
		Section {
			ForEach(ps5s) { console in
				Toggle(isOn: Binding {
					selected.contains(console.mac)
				} set: {
					if $0 { selected.insert(console.mac) } else { selected.remove(console.mac) }
				}) {
					VStack(alignment: .leading, spacing: 4) {
						Text(console.nickname).font(.headline)
						TextField("IP 주소", text: Binding {
							addresses[console.mac] ?? ""
						} set: {
							addresses[console.mac] = $0
						})
						.font(.callout.monospaced())
						.decimalInput()
						.plainTextInput()
					}
				}
			}
		} header: {
			Text("등록된 PS5")
		} footer: {
			Text("등록 키를 그대로 가져와서 PIN 등록 없이 접속합니다. PS5에서는 chiaki-ng와 같은 기기로 보입니다.")
		}
		if skipped > 0 {
			Section {
				Text("PS4 \(skipped)대는 지원하지 않아서 건너뜁니다.")
					.foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder
	private func resultSections(_ imported: [ConsoleHost]) -> some View {
		Section {
			Label("PS5 \(imported.count)대를 가져왔습니다", systemImage: "checkmark.circle.fill")
				.foregroundStyle(.green)
		} footer: {
			Text("iCloud로 다른 기기에도 넘어갑니다.")
		}
		Section {
			if fileRemoved {
				Label("원본 파일을 휴지통으로 옮겼습니다", systemImage: "trash")
			} else {
				Button("원본 파일을 휴지통으로", systemImage: "trash", role: .destructive) { trashSource() }
			}
		} footer: {
			Text("\(request.url.lastPathComponent)에는 PS5 원격 접속 키가 그대로 들어 있습니다.")
		}
	}

	private var canImport: Bool {
		!selected.isEmpty && selected.allSatisfy { mac in
			var addr = in_addr()
			return inet_pton(AF_INET, addresses[mac] ?? "", &addr) == 1
		}
	}

	private func runImport() {
		var consoles = ps5s.filter { selected.contains($0.mac) }
		for i in consoles.indices { consoles[i].address = addresses[consoles[i].mac] }
		if let account = request.config.accountID, settings.accountID.isEmpty {
			settings.accountID = account
		}
		imported = store.importConsoles(consoles)
	}

	private func trashSource() {
		let url = request.url
		let accessing = url.startAccessingSecurityScopedResource()
		defer { if accessing { url.stopAccessingSecurityScopedResource() } }
		fileRemoved = (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
	}
}
