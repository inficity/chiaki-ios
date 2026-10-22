import SwiftUI

struct RegisterView: View {
	let host: ConsoleHost

	@Environment(HostStore.self) private var store
	@Environment(AppSettings.self) private var settings
	@Environment(\.dismiss) private var dismiss
	@State private var accountID = ""
	@State private var pin = ""
	@State private var isRegistering = false
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("예: AbCdEfGhIjk=", text: $accountID)
						.font(.body.monospaced())
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				} header: {
					Text("PSN 계정 ID")
				} footer: {
					Text("스팀덱 chiaki-ng 설정의 PSN Account-ID와 같은 base64 값입니다. 한 번 입력하면 저장됩니다.")
				}

				Section {
					TextField("8자리 숫자", text: $pin)
						.font(.body.monospaced())
						.keyboardType(.numberPad)
				} header: {
					Text("PIN")
				} footer: {
					Text("PS5에서 설정 › 시스템 › 리모트 플레이 › 기기 연결을 열면 표시됩니다. 스팀덱 등록은 그대로 유지됩니다.")
				}

				if let errorMessage {
					Section {
						Label(errorMessage, systemImage: "exclamationmark.triangle")
							.foregroundStyle(.red)
					}
				}
			}
			.navigationTitle("\(host.name) 등록")
			.navigationBarTitleDisplayMode(.inline)
			.disabled(isRegistering)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("취소") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					if isRegistering {
						ProgressView()
					} else {
						Button("등록") { register() }
							.disabled(accountID.isEmpty || pin.count != 8)
					}
				}
			}
			.onAppear { accountID = settings.accountID }
		}
	}

	private func register() {
		isRegistering = true
		errorMessage = nil
		Task {
			do {
				let registration = try await ConsoleRegistrar.register(address: host.address, accountID: accountID, pin: pin)
				settings.accountID = accountID.trimmingCharacters(in: .whitespaces)
				store.setRegistration(registration, for: host)
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
			}
			isRegistering = false
		}
	}
}
