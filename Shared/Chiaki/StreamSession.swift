import ChiakiCore
import Foundation
import Observation

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
	let hostName: String

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

		chiaki_session_set_video_sample_cb(session, { buf, size, _, _, user in
			guard let buf, let user else { return false }
			let me = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
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

	/// chiaki 세션 스레드에서 호출된다
	private func handle(_ event: ChiakiEvent) {
		switch event.type {
		case CHIAKI_EVENT_CONNECTED:
			DispatchQueue.main.async {
				guard !self.stopped else { return }
				self.state = .streaming
				self.input.start()
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
