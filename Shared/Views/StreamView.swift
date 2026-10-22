import SwiftUI

struct StreamView: View {
	let session: StreamSession
	/// 스트리밍 화면을 닫는다 (iOS 전체 화면 커버, 맥 창 오버레이 공통)
	let onClose: () -> Void

	@State private var showsControls = true
	@State private var hideTask: Task<Void, Never>?
	@State private var loginPIN = ""

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()
			VideoLayerView(layer: session.video.layer)
				.ignoresSafeArea()
				.contentShape(Rectangle())
				.onTapGesture { revealControls() }
			overlay
		}
		.overlay(alignment: .topTrailing) {
			if showsControls {
				HStack(spacing: 12) {
					if session.state == .streaming {
						// macOS가 패드의 PS 버튼을 가져갈 때를 위한 대체 버튼
						controlButton("playstation.logo") {
							session.pressPS()
							revealControls()
						}
						.help("PS 버튼 (패드: 터치패드 + OPTIONS)")
					}
					controlButton("xmark") {
						session.stop()
						onClose()
					}
				}
				.padding()
				.transition(.opacity)
			}
		}
		.immersiveStream()
		.alert("PS5 로그인 암호", isPresented: loginPINBinding) {
			SecureField("4자리", text: $loginPIN)
				.numberInput()
			Button("확인") {
				session.submitLoginPIN(loginPIN)
				loginPIN = ""
			}
			Button("취소", role: .cancel) {
				session.stop()
				onClose()
			}
		} message: {
			if case .loginPIN(incorrect: true) = session.state {
				Text("암호가 틀렸습니다. 다시 입력하세요.")
			}
		}
		.onAppear {
			IdleSleep.prevent(true)
			session.start()
			revealControls()
		}
		.onDisappear {
			IdleSleep.prevent(false)
			session.stop()
		}
		.onChange(of: session.state) { _, state in
			if case .ended(message: nil) = state { onClose() }
		}
	}

	@ViewBuilder
	private var overlay: some View {
		switch session.state {
		case .connecting, .loginPIN:
			VStack(spacing: 12) {
				ProgressView().controlSize(.large)
				Text("\(session.hostName)에 연결하는 중…")
			}
			.foregroundStyle(.white)
		case .ended(let message?):
			VStack(spacing: 16) {
				Image(systemName: "exclamationmark.triangle.fill")
					.font(.largeTitle)
					.foregroundStyle(.yellow)
				Text("연결이 끊겼습니다").font(.headline)
				Text(message)
					.font(.callout)
					.multilineTextAlignment(.center)
					.foregroundStyle(.secondary)
				Button("닫기") { onClose() }
					.buttonStyle(.borderedProminent)
			}
			.padding(24)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
			.padding()
		case .streaming, .ended:
			EmptyView()
		}
	}

	private var loginPINBinding: Binding<Bool> {
		Binding {
			if case .loginPIN = session.state { true } else { false }
		} set: { _ in }
	}

	private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.headline)
				.frame(width: 20, height: 20)
				.padding(12)
				.background(.ultraThinMaterial, in: Circle())
		}
		.buttonStyle(.plain)
	}

	/// 화면을 탭하면 닫기 버튼을 잠깐 보여준다
	private func revealControls() {
		withAnimation { showsControls = true }
		hideTask?.cancel()
		hideTask = Task {
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation { showsControls = false }
		}
	}
}
