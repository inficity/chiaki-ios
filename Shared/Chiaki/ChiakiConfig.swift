import Foundation

/// chiaki-ng 설정 파일에서 등록된 콘솔을 읽는다.
/// "Export settings to file"로 만든 .ini와 Steam Deck의 Chiaki.conf 모두 Qt QSettings INI 형식이다:
/// 배열은 [registered_hosts] 아래 "1\키", 바이트 배열은 @ByteArray(...) 안에 Qt 이스케이프.
struct ChiakiConfig {
	struct Console: Identifiable {
		var id: Data { mac }
		var nickname: String
		var mac: Data
		var target: UInt32
		var registKey: Data
		var morning: Data
		/// [manual_hosts]에 같은 MAC으로 등록된 IP. 집 LAN에서 자동 검색으로만 쓰던 콘솔은 없다.
		var address: String?

		var isPS5: Bool { target >= 1_000_000 }
	}

	var consoles: [Console]
	var accountID: String?

	init(contentsOf url: URL) throws {
		let data = try Data(contentsOf: url)
		// Qt 6은 UTF-8, Qt 5 시절 파일은 Latin-1일 수 있다
		guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
			throw ChiakiConfigError.unreadable
		}
		try self.init(text: text)
	}

	init(text: String) throws {
		let ini = QtIni(text: text)

		var addresses: [Data: String] = [:]
		for entry in ini.array("manual_hosts") where entry["registered"] == "true" {
			if let mac = entry["registered_mac"].flatMap(QtIni.bytes), let host = entry["host"].map(QtIni.string) {
				addresses[mac] = host
			}
		}

		consoles = ini.array("registered_hosts").compactMap { entry in
			guard let mac = entry["server_mac"].flatMap(QtIni.bytes), mac.count == 6,
			      let registKey = entry["rp_regist_key"].flatMap(QtIni.bytes), !registKey.isEmpty, registKey.count <= 16,
			      let morning = entry["rp_key"].flatMap(QtIni.bytes), morning.count == 16,
			      let target = entry["target"].flatMap({ UInt32(QtIni.string($0)) })
			else { return nil }
			return Console(
				nickname: entry["server_nickname"].map(QtIni.string) ?? "PS5",
				mac: mac, target: target,
				registKey: registKey + Data(count: 16 - registKey.count),
				morning: morning,
				address: addresses[mac])
		}
		guard !consoles.isEmpty else { throw ChiakiConfigError.noConsoles }

		let account = ini.sections["settings"]?["psn_account_id"].map(QtIni.string) ?? ""
		accountID = account.isEmpty ? nil : account
	}
}

enum ChiakiConfigError: LocalizedError {
	case unreadable
	case noConsoles

	var errorDescription: String? {
		switch self {
		case .unreadable: "파일을 읽을 수 없습니다."
		case .noConsoles: "등록된 콘솔이 없습니다. chiaki-ng의 \"Export settings to file\"로 만든 파일이나 Chiaki.conf를 고르세요."
		}
	}
}

/// QSettings INI 형식 (QSettingsPrivate::iniEscapedString / iniUnescapedStringList와 같은 규칙)
struct QtIni {
	private(set) var sections: [String: [String: String]] = [:]

	init(text: String) {
		var current = "General"
		for raw in text.split(whereSeparator: \.isNewline) {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
			if line.hasPrefix("[") && line.hasSuffix("]") {
				current = String(line.dropFirst().dropLast())
				continue
			}
			guard let eq = line.firstIndex(of: "=") else { continue }
			let key = line[..<eq].trimmingCharacters(in: .whitespaces)
			let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
			sections[current, default: [:]][key] = value
		}
	}

	/// beginReadArray: "size" 개수만큼 "1\키", "2\키" … 를 묶는다
	func array(_ name: String) -> [[String: String]] {
		guard let section = sections[name], let size = section["size"].flatMap({ Int($0) }), size > 0 else { return [] }
		return (1...size).map { index in
			let prefix = "\(index)\\"
			var entry: [String: String] = [:]
			for (key, value) in section where key.hasPrefix(prefix) {
				entry[String(key.dropFirst(prefix.count))] = value
			}
			return entry
		}
	}

	static func string(_ raw: String) -> String {
		var scalars = String.UnicodeScalarView()
		for value in unescape(raw) {
			if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
		}
		let text = String(scalars)
		return text.hasPrefix("@@") ? String(text.dropFirst()) : text
	}

	/// @ByteArray(...) 값을 바이트로. 바이트 배열은 Latin-1 문자 하나가 한 바이트다.
	static func bytes(_ raw: String) -> Data? {
		let values = unescape(raw)
		let prefix = Array("@ByteArray(".unicodeScalars.map(\.value))
		guard values.count > prefix.count, Array(values.prefix(prefix.count)) == prefix,
		      values.last == UInt32(UInt8(ascii: ")")) else { return nil }
		let body = values.dropFirst(prefix.count).dropLast()
		guard body.allSatisfy({ $0 <= 0xFF }) else { return nil }
		return Data(body.map { UInt8($0) })
	}

	/// 따옴표를 걷어내고 역슬래시 이스케이프를 푼다.
	/// \x와 8진수 이스케이프는 숫자를 끝까지 읽는다: Qt가 쓸 때 뒤따르는 16진수 문자도 이스케이프하기 때문에 안전하다.
	static func unescape(_ raw: String) -> [UInt32] {
		let chars = Array(raw.unicodeScalars)
		var out: [UInt32] = []
		out.reserveCapacity(chars.count)
		var i = 0
		while i < chars.count {
			let c = chars[i]
			if c == "\"" {
				i += 1
				continue
			}
			guard c == "\\", i + 1 < chars.count else {
				out.append(c.value)
				i += 1
				continue
			}
			i += 1
			let e = chars[i]
			switch e {
			case "a": out.append(0x07)
			case "b": out.append(0x08)
			case "f": out.append(0x0C)
			case "n": out.append(0x0A)
			case "r": out.append(0x0D)
			case "t": out.append(0x09)
			case "v": out.append(0x0B)
			case "x":
				i += 1
				var value: UInt32 = 0
				while i < chars.count, let digit = hexValue(chars[i]) {
					value = value * 16 + digit
					i += 1
				}
				out.append(value)
				continue
			case "0"..."7":
				var value: UInt32 = 0
				while i < chars.count, ("0"..."7").contains(chars[i]) {
					value = value * 8 + (chars[i].value - 0x30)
					i += 1
				}
				out.append(value)
				continue
			default:
				// \" \\ \' \? 등은 문자 그대로
				out.append(e.value)
			}
			i += 1
		}
		return out
	}

	private static func hexValue(_ c: Unicode.Scalar) -> UInt32? {
		switch c.value {
		case 0x30...0x39: c.value - 0x30
		case 0x41...0x46: c.value - 0x41 + 10
		case 0x61...0x66: c.value - 0x61 + 10
		default: nil
		}
	}
}
