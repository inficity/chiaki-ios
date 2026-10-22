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
	/// PSN 계정 ID (base64). 등록할 때만 쓴다.
	var accountID: String { didSet { save() } }
	var stream: StreamSettings { didSet { save() } }

	private static let accountKey = "psnAccountID"
	private static let streamKey = "streamSettings"

	init() {
		let defaults = UserDefaults.standard
		accountID = defaults.string(forKey: Self.accountKey) ?? ""
		stream = defaults.data(forKey: Self.streamKey)
			.flatMap { try? JSONDecoder().decode(StreamSettings.self, from: $0) } ?? StreamSettings()
	}

	private func save() {
		let defaults = UserDefaults.standard
		defaults.set(accountID, forKey: Self.accountKey)
		defaults.set(try? JSONEncoder().encode(stream), forKey: Self.streamKey)
	}
}
