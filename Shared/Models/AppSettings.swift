import ChiakiCore
import Foundation
import Observation

struct StreamSettings: Codable, Equatable {
	enum Resolution: String, Codable, CaseIterable, Identifiable {
		case p720, p1080
		var id: Self { self }
		var label: String { self == .p720 ? "720p" : "1080p" }
		var preset: ChiakiVideoResolutionPreset {
			self == .p720 ? CHIAKI_VIDEO_RESOLUTION_PRESET_720p : CHIAKI_VIDEO_RESOLUTION_PRESET_1080p
		}
	}

	enum Codec: String, Codable, CaseIterable, Identifiable {
		case h264, hevc
		var id: Self { self }
		var label: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
		var chiaki: ChiakiCodec { self == .h264 ? CHIAKI_CODEC_H264 : CHIAKI_CODEC_H265 }
	}

	var resolution: Resolution = .p1080
	var fps = 60
	var codec: Codec = .hevc
	/// kbps. 0이면 해상도별 chiaki 기본값
	var bitrate = 0

	var videoProfile: ChiakiConnectVideoProfile {
		var profile = ChiakiConnectVideoProfile()
		chiaki_connect_video_profile_preset(&profile, resolution.preset,
			fps == 30 ? CHIAKI_VIDEO_FPS_PRESET_30 : CHIAKI_VIDEO_FPS_PRESET_60)
		if bitrate > 0 { profile.bitrate = UInt32(bitrate) }
		profile.codec = codec.chiaki
		return profile
	}
}

@Observable
final class AppSettings {
	/// PSN 계정 ID (base64). 등록할 때만 쓴다. iCloud로 다른 기기와 공유한다.
	var accountID: String {
		didSet { if accountID != oldValue { CloudSettings.set(accountID, forKey: Self.accountKey) } }
	}
	/// 영상 설정은 기기마다 다르게 쓰는 게 자연스러워서 (iPhone 720p, Mac 1080p 등) 공유하지 않는다
	var stream: StreamSettings {
		didSet { UserDefaults.standard.set(try? JSONEncoder().encode(stream), forKey: Self.streamKey) }
	}

	private static let accountKey = "psnAccountID"
	private static let streamKey = "streamSettings"
	@ObservationIgnored private var cloudObserver: NSObjectProtocol?

	init() {
		CloudSettings.start()
		accountID = CloudSettings.string(forKey: Self.accountKey) ?? ""
		stream = UserDefaults.standard.data(forKey: Self.streamKey)
			.flatMap { try? JSONDecoder().decode(StreamSettings.self, from: $0) } ?? StreamSettings()
		if CloudSettings.isMissingInCloud(Self.accountKey) && !accountID.isEmpty {
			CloudSettings.set(accountID, forKey: Self.accountKey)
		}
		cloudObserver = CloudSettings.observe { [weak self] keys in
			guard keys.contains(Self.accountKey), let self else { return }
			let value = CloudSettings.string(forKey: Self.accountKey) ?? ""
			if value != self.accountID { self.accountID = value }
		}
	}
}
