import SwiftUI

struct SettingsView: View {
	@Environment(AppSettings.self) private var settings
	@Environment(\.dismiss) private var dismiss

	private static let bitrates = [0, 10_000, 15_000, 20_000, 25_000, 30_000]

	var body: some View {
		@Bindable var settings = settings
		NavigationStack {
			Form {
				Section("영상") {
					Picker("해상도", selection: $settings.stream.resolution) {
						ForEach(StreamSettings.Resolution.allCases) { Text($0.label).tag($0) }
					}
					Picker("프레임", selection: $settings.stream.fps) {
						Text("30 fps").tag(30)
						Text("60 fps").tag(60)
					}
					Picker("코덱", selection: $settings.stream.codec) {
						ForEach(StreamSettings.Codec.allCases) { Text($0.label).tag($0) }
					}
					Picker("비트레이트", selection: $settings.stream.bitrate) {
						ForEach(Self.bitrates, id: \.self) { kbps in
							Text(kbps == 0 ? "기본값" : "\(kbps / 1000) Mbps").tag(kbps)
						}
					}
				}

				Section {
					TextField("base64", text: $settings.accountID)
						.font(.body.monospaced())
						.plainTextInput()
				} header: {
					Text("PSN 계정 ID")
				} footer: {
					Text("새 PS5를 등록할 때만 사용합니다.")
				}
			}
			.navigationTitle("설정")
			.inlineNavigationTitle()
			.toolbar {
				Button("완료") { dismiss() }
			}
		}
	}
}
