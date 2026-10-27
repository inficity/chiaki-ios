import GameController
import SwiftUI

struct StreamView: View {
	let session: StreamSession
	/// 스트리밍 화면을 닫는다 (iOS 전체 화면 커버, 맥 창 오버레이 공통)
	let onClose: () -> Void

	@State private var showsControls = true
	@State private var hideTask: Task<Void, Never>?
	@State private var loginPIN = ""
	/// 화면 터치 패드: 처음엔 연결된 컨트롤러가 없을 때만 보인다
	@State private var showsTouchControls = PlatformFeatures.touchControls && GCController.controllers().isEmpty
	@AppStorage("showStreamStats") private var showsStats = false

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()
			VideoLayerView(layer: session.video.layer)
				.ignoresSafeArea()
				.contentShape(Rectangle())
				// 터치 패드를 쓰는 동안에는 빈 곳을 눌러도 메뉴를 띄우지 않는다 (⋯ 버튼으로 연다)
				.onTapGesture { if !touchControlsVisible { revealControls() } }
			if touchControlsVisible {
				// 안전 영역은 터치 레이어가 직접 계산한다
				TouchControlsView(session: session) { revealControls() }
					.ignoresSafeArea()
			}
			overlay
		}
		// 통계는 누를 수 없는 글자라 홈 인디케이터 위에 둬도 된다
		.overlay(alignment: .bottom) {
			if showsStats, let stats = session.stats {
				StatsOverlay(stats: stats)
					.padding(.bottom, 24)
					.allowsHitTesting(false)
			}
		}
		// 터치 패드를 쓸 때는 오른쪽 위가 R1/R2 자리라 화면 가운데에 띄운다
		.overlay(alignment: touchControlsVisible ? .center : .topTrailing) {
			if showsControls {
				HStack(spacing: 12) {
					if session.state == .streaming {
						controlButton(showsStats ? "chart.bar.fill" : "chart.bar") {
							showsStats.toggle()
							revealControls()
						}
						.help("연결 품질 통계")
					}
					if PlatformFeatures.touchControls && session.state == .streaming {
						controlButton(showsTouchControls ? "gamecontroller.fill" : "gamecontroller") {
							showsTouchControls.toggle()
							revealControls()
						}
					}
					if session.state == .streaming && !touchControlsVisible {
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
		// 패드를 연결하면 터치 패드를 숨기고, 다 끊기면 다시 띄운다
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
			if PlatformFeatures.touchControls { showsTouchControls = false }
		}
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
			if PlatformFeatures.touchControls && GCController.controllers().isEmpty { showsTouchControls = true }
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

	private var touchControlsVisible: Bool {
		session.state == .streaming && showsTouchControls
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

/// 연결 품질 숫자. 문제 구간은 노란색으로 표시한다
private struct StatsOverlay: View {
	let stats: StreamStats

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 12) {
				item("\(stats.fps) fps", warn: stats.fps < 50)
				item(String(format: "%.1f Mbps", stats.bitrateMbps))
				item(String(format: "RTT %.0f ms", stats.rttMs), warn: stats.rttMs > 40)
				item("MTU \(stats.mtuIn)/\(stats.mtuOut)")
			}
			HStack(spacing: 12) {
				item(String(format: "손실 %.1f%%", stats.packetLossPercent), warn: stats.packetLossPercent > 1)
				item("프레임 손실 \(stats.framesLost)", warn: stats.framesLost > 0)
				item("최대 간격 \(stats.maxGapMs) ms", warn: stats.maxGapMs > 50)
				item("오디오 끊김 \(stats.audioUnderruns) · 버림 \(stats.audioDroppedMs) ms",
				     warn: stats.audioUnderruns > 0 || stats.audioDroppedMs > 0)
			}
		}
		.font(.caption2.monospacedDigit().weight(.medium))
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
	}

	private func item(_ text: String, warn: Bool = false) -> some View {
		Text(text).foregroundStyle(warn ? .yellow : .white)
	}
}
