import SwiftUI

struct AddHostView: View {
	let onAdd: (ConsoleHost) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var name = "PS5"
	@State private var address = ""

	private var isValid: Bool {
		var addr = in_addr()
		return !name.isEmpty && inet_pton(AF_INET, address, &addr) == 1
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("이름", text: $name)
					TextField("IP 주소 (예: 192.168.0.20)", text: $address)
						.keyboardType(.decimalPad)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				} footer: {
					Text("스팀덱 chiaki-ng에 수동으로 넣은 것과 같은 PS5 LAN IP를 입력하세요.")
				}
			}
			.navigationTitle("PS5 추가")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("취소") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("추가") {
						onAdd(ConsoleHost(name: name, address: address))
						dismiss()
					}
					.disabled(!isValid)
				}
			}
		}
	}
}
