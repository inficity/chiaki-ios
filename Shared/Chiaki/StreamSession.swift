import ChiakiCore
import Foundation
import Observation
import os

/// 1초마다 갱신하는 스트리밍 품질 수치
struct StreamStats: Equatable {
	/// 받은 영상 프레임 수 (초당)
	var fps = 0
	/// libchiaki가 복구하지 못하고 버린 프레임 수 (지난 1초)
	var framesLost = 0
	/// 프레임 사이 최대 간격(ms). 60fps면 정상 17ms 안팎, 크면 화면이 멈칫한다
	var maxGapMs = 0
	var bitrateMbps = 0.0
	/// 혼잡 제어가 계산한 패킷 손실률(%)
	var packetLossPercent = 0.0
	var rttMs = 0.0
	var mtuIn = 0
	var mtuOut = 0
	/// 오디오 버퍼가 비어서 끊긴 횟수 (지난 1초)
	var audioUnderruns = 0
	/// 오디오가 밀려서 버린 양(ms, 지난 1초)
	var audioDroppedMs = 0
}

/// 영상 콜백 스레드에서 세는 값
private struct VideoCounters {
	var frames = 0
	var lost = 0
	var maxGapNs: UInt64 = 0
	var lastFrameNs: UInt64 = 0
}

/// ChiakiSession 하나(PS5와의 스트리밍 연결 1회)를 감싼다.
/// libchiaki 콜백은 각자의 스레드에서 오고, UI 상태는 메인 스레드에서만 바꾼다.
@Observable
final class StreamSession: Identifiable {
	enum State: Equatable {
		case connecting
		case streaming
		/// PS5에 로그인 암호가 걸려 있을 때
		case loginPIN(incorrect: Bool)
		/// message가 nil이면 정상 종료
		case ended(message: String?)
	}

	private(set) var state: State = .connecting
	/// 스트리밍 중 1초마다 갱신
	private(set) var stats: StreamStats?
	let hostName: String
	@ObservationIgnored private let counters = OSAllocatedUnfairLock(initialState: VideoCounters())
	@ObservationIgnored private var statsTask: Task<Void, Never>?

	@ObservationIgnored let video: VideoRenderer
	@ObservationIgnored private let audio = AudioPlayer()
	@ObservationIgnored private let input = ControllerInput()
	@ObservationIgnored private let session: UnsafeMutablePointer<ChiakiSession>
	@ObservationIgnored private let opus: UnsafeMutablePointer<ChiakiOpusDecoder>
	/// 콜백에 넘기는 self. join이 끝날 때까지 객체가 살아 있게 붙잡는다.
	@ObservationIgnored private var retainedSelf: Unmanaged<StreamSession>?
	@ObservationIgnored private var stopped = false

	init(host: ConsoleHost, registration: RegisteredConsole, settings: StreamSettings) throws {
		hostName = registration.nickname.isEmpty ? host.name : registration.nickname
		video = VideoRenderer(hevc: settings.codec == .hevc)

		var info = ChiakiConnectInfo()
		info.ps5 = true
		info.video_profile = settings.videoProfile
		info.video_profile_auto_downgrade = true
		info.enable_keyboard = false
		info.enable_dualsense = false
		info.enable_idr_on_fec_failure = true
		info.packet_loss_max = 0.05
		withUnsafeMutableBytes(of: &info.regist_key) { $0.copyBytes(from: registration.registKey.prefix($0.count)) }
		withUnsafeMutableBytes(of: &info.morning) { $0.copyBytes(from: registration.morning.prefix($0.count)) }

		session = .allocate(capacity: 1)
		session.initialize(to: ChiakiSession())
		opus = .allocate(capacity: 1)
		opus.initialize(to: ChiakiOpusDecoder())

		// chiaki_session_init이 호스트 문자열을 복사한다
		let err = host.address.withCString { address in
			info.host = address
			return chiaki_session_init(session, &info, ChiakiLogger.shared.log)
		}
		guard err == CHIAKI_ERR_SUCCESS else {
			session.deallocate()
			opus.deallocate()
			throw ChiakiError(code: err)
		}
		chiaki_opus_decoder_init(opus, ChiakiLogger.shared.log)
	}

	func start() {
		guard retainedSelf == nil, !stopped else { return }
		let user = Unmanaged.passRetained(self)
		retainedSelf = user
		let ctx = user.toOpaque()

		chiaki_session_set_event_cb(session, { event, user in
			guard let event, let user else { return }
			Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue().handle(event.pointee)
		}, ctx)

		chiaki_session_set_video_sample_cb(session, { buf, size, framesLost, _, user in
			guard let buf, let user else { return false }
			let me = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			me.countFrame(lost: Int(framesLost))
			return me.video.submit(UnsafeBufferPointer(start: buf, count: size))
		}, ctx)
		video.onNeedsKeyframe = { [session] in _ = chiaki_session_request_idr(session) }

		chiaki_opus_decoder_set_cb(opus, { channels, rate, user in
			guard let user else { return }
			Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
				.audio.configure(channels: Int(channels), rate: Double(rate))
		}, { buf, samples, user in
			guard let buf, let user else { return }
			Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
				.audio.push(buf, frames: samples)
		}, ctx)
		var sink = ChiakiAudioSink()
		chiaki_opus_decoder_get_sink(opus, &sink)
		chiaki_session_set_audio_sink(session, &sink)

		input.onChange = { [session] state in
			var state = state
			_ = chiaki_session_set_controller_state(session, &state)
		}

		let err = chiaki_session_start(session)
		if err != CHIAKI_ERR_SUCCESS {
			state = .ended(message: ChiakiError(code: err).localizedDescription)
			retainedSelf = nil
			user.release()
		}
	}

	/// 가상 입력(화면 터치 패드, 에이전트). 실제 패드·키보드 입력과 합쳐서 보낸다.
	func setVirtualInput(_ state: ChiakiControllerState?, from source: VirtualInputSource) {
		input.set(state, for: source)
	}

	/// 화면의 PS 버튼. macOS가 패드의 PS 버튼을 가져갈 때 대신 쓴다.
	func pressPS() {
		input.tap(CHIAKI_CONTROLLER_BUTTON_PS)
	}

	func submitLoginPIN(_ pin: String) {
		let bytes = Array(pin.utf8)
		_ = chiaki_session_set_login_pin(session, bytes, bytes.count)
		state = .connecting
	}

	/// 세션을 끝내고 자원을 정리한다. 여러 번 불러도 된다.
	func stop() {
		guard !stopped else { return }
		stopped = true
		// 세션 메모리를 해제하기 전에 입력이 더 들어가지 않게 끊는다
		input.onChange = nil
		input.stop()
		statsTask?.cancel()
		statsTask = nil
		let started = retainedSelf
		retainedSelf = nil
		let session = session
		let opus = opus
		DispatchQueue.global(qos: .userInitiated).async { [audio] in
			if started != nil {
				chiaki_session_stop(session)
				chiaki_session_join(session)
			}
			chiaki_session_fini(session)
			chiaki_opus_decoder_fini(opus)
			audio.stop()
			session.deallocate()
			opus.deallocate()
			started?.release()
		}
	}

	// MARK: - 통계

	/// 영상 콜백 스레드에서 프레임마다
	private func countFrame(lost: Int) {
		let now = DispatchTime.now().uptimeNanoseconds
		counters.withLock { c in
			c.frames += 1
			c.lost += lost
			if c.lastFrameNs > 0 { c.maxGapNs = max(c.maxGapNs, now - c.lastFrameNs) }
			c.lastFrameNs = now
		}
	}

	private func startStats() {
		statsTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(1))
				guard let self, !self.stopped else { return }
				self.sampleStats()
			}
		}
	}

	/// 메인 스레드에서 1초마다. 세션 필드는 chiaki 스레드가 쓰는 값을 그대로 읽는다 (데스크톱 GUI와 같은 방식).
	private func sampleStats() {
		let videoStats = counters.withLock { c -> VideoCounters in
			let snapshot = c
			c.frames = 0
			c.lost = 0
			c.maxGapNs = 0
			return snapshot
		}
		let audioStats = audio.takeStats()
		stats = StreamStats(
			fps: videoStats.frames,
			framesLost: videoStats.lost,
			maxGapMs: Int(videoStats.maxGapNs / 1_000_000),
			bitrateMbps: session.pointee.stream_connection.measured_bitrate,
			packetLossPercent: session.pointee.stream_connection.congestion_control.packet_loss * 100,
			rttMs: Double(session.pointee.rtt_us) / 1000,
			mtuIn: Int(session.pointee.mtu_in),
			mtuOut: Int(session.pointee.mtu_out),
			audioUnderruns: audioStats.underruns,
			audioDroppedMs: audioStats.droppedMs)
	}

	/// chiaki 세션 스레드에서 호출된다
	private func handle(_ event: ChiakiEvent) {
		switch event.type {
		case CHIAKI_EVENT_CONNECTED:
			DispatchQueue.main.async {
				guard !self.stopped else { return }
				self.state = .streaming
				self.input.start()
				self.startStats()
			}
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			let incorrect = event.login_pin_request.pin_incorrect
			DispatchQueue.main.async { self.state = .loginPIN(incorrect: incorrect) }
		case CHIAKI_EVENT_QUIT:
			let quit = event.quit
			var message: String?
			if chiaki_quit_reason_is_error(quit.reason) {
				message = String(cString: chiaki_quit_reason_string(quit.reason))
				if let detail = quit.reason_str { message! += "\n" + String(cString: detail) }
			}
			DispatchQueue.main.async {
				if !self.stopped { self.input.stop() }
				self.state = .ended(message: message)
			}
		default:
			break
		}
	}
}
