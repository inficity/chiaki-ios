import AVFoundation
import SwiftUI

struct StreamView: View {
	let session: StreamSession

	@Environment(\.dismiss) private var dismiss
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
				Button {
					session.stop()
					dismiss()
				} label: {
					Image(systemName: "xmark")
						.font(.headline)
						.padding(12)
						.background(.ultraThinMaterial, in: Circle())
				}
				.padding()
				.transition(.opacity)
			}
		}
		.statusBarHidden()
		.persistentSystemOverlays(.hidden)
		.alert("PS5 로그인 암호", isPresented: loginPINBinding) {
			SecureField("4자리", text: $loginPIN)
				.keyboardType(.numberPad)
			Button("확인") {
				session.submitLoginPIN(loginPIN)
				loginPIN = ""
			}
			Button("취소", role: .cancel) {
				session.stop()
				dismiss()
			}
		} message: {
			if case .loginPIN(incorrect: true) = session.state {
				Text("암호가 틀렸습니다. 다시 입력하세요.")
			}
		}
		.onAppear {
			UIApplication.shared.isIdleTimerDisabled = true
			session.start()
			revealControls()
		}
		.onDisappear {
			UIApplication.shared.isIdleTimerDisabled = false
			session.stop()
		}
		.onChange(of: session.state) { _, state in
			if case .ended(message: nil) = state { dismiss() }
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
				Button("닫기") { dismiss() }
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

/// AVSampleBufferDisplayLayer를 SwiftUI에 붙인다
private struct VideoLayerView: UIViewRepresentable {
	let layer: AVSampleBufferDisplayLayer

	func makeUIView(context: Context) -> LayerHostView {
		let view = LayerHostView()
		view.backgroundColor = .black
		view.hosted = layer
		view.layer.addSublayer(layer)
		return view
	}

	func updateUIView(_ view: LayerHostView, context: Context) {}

	final class LayerHostView: UIView {
		var hosted: CALayer?

		override func layoutSubviews() {
			super.layoutSubviews()
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			hosted?.frame = bounds
			CATransaction.commit()
		}
	}
}
