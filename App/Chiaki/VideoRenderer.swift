import AVFoundation
import CoreMedia

/// chiaki가 넘겨주는 Annex B 비트스트림(H.264/HEVC)을 AVSampleBufferDisplayLayer에 바로 넣는다.
/// 디코딩은 레이어가 하드웨어(VideoToolbox)로 처리하고, 프레임은 도착하는 즉시 표시한다.
final class VideoRenderer {
	let layer = AVSampleBufferDisplayLayer()

	/// 디코더가 망가졌을 때 호출된다. 세션은 IDR 프레임을 요청해서 복구한다.
	var onNeedsKeyframe: (() -> Void)?

	private let hevc: Bool
	private var formatDescription: CMVideoFormatDescription?
	private var vps: Data?
	private var sps: Data?
	private var pps: Data?

	init(hevc: Bool) {
		self.hevc = hevc
		layer.videoGravity = .resizeAspect
		layer.backgroundColor = CGColor(gray: 0, alpha: 1)
	}

	/// chiaki 영상 스레드에서 프레임마다 호출된다.
	/// false를 돌려주면 chiaki는 이 프레임을 참조 프레임으로 쓰지 않는다.
	func submit(_ frame: UnsafeBufferPointer<UInt8>) -> Bool {
		let renderer = layer.sampleBufferRenderer
		if renderer.status == .failed {
			// 앱이 백그라운드에 다녀오면 디코더가 끊긴다. 비우고 키프레임부터 다시 받는다.
			renderer.flush(removingDisplayedImage: false, completionHandler: nil)
			onNeedsKeyframe?()
			return false
		}

		var sample = Data(capacity: frame.count + 32)
		var parametersChanged = false
		forEachNAL(in: frame) { nal in
			let type = hevc ? (nal[0] >> 1) & 0x3f : nal[0] & 0x1f
			switch (hevc, type) {
			case (true, 32):
				if update(&vps, nal) { parametersChanged = true }
			case (true, 33), (false, 7):
				if update(&sps, nal) { parametersChanged = true }
			case (true, 34), (false, 8):
				if update(&pps, nal) { parametersChanged = true }
			default:
				// AVCC/HVCC: 시작 코드 대신 4바이트 길이
				var length = UInt32(nal.count).bigEndian
				withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
				sample.append(contentsOf: nal)
			}
		}

		if parametersChanged || formatDescription == nil {
			formatDescription = makeFormatDescription()
		}
		// 해상도가 바뀔 때 오는 헤더는 파라미터 셋만 들어 있다
		if sample.isEmpty { return true }
		guard let formatDescription, let buffer = makeSampleBuffer(sample, formatDescription) else { return false }
		renderer.enqueue(buffer)
		return true
	}

	private func update(_ slot: inout Data?, _ nal: UnsafeBufferPointer<UInt8>) -> Bool {
		let data = Data(nal)
		guard slot != data else { return false }
		slot = data
		return true
	}

	private func makeFormatDescription() -> CMVideoFormatDescription? {
		let sets: [Data]
		if hevc {
			guard let vps, let sps, let pps else { return nil }
			sets = [vps, sps, pps]
		} else {
			guard let sps, let pps else { return nil }
			sets = [sps, pps]
		}

		let joined = sets.reduce(Data(), +)
		return joined.withUnsafeBytes { raw -> CMVideoFormatDescription? in
			let base = raw.bindMemory(to: UInt8.self).baseAddress!
			var pointers: [UnsafePointer<UInt8>] = []
			var offset = 0
			for set in sets {
				pointers.append(base + offset)
				offset += set.count
			}
			let sizes = sets.map(\.count)
			var description: CMVideoFormatDescription?
			let status = hevc
				? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
					allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
					parameterSetPointers: pointers, parameterSetSizes: sizes,
					nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
				: CMVideoFormatDescriptionCreateFromH264ParameterSets(
					allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
					parameterSetPointers: pointers, parameterSetSizes: sizes,
					nalUnitHeaderLength: 4, formatDescriptionOut: &description)
			return status == noErr ? description : nil
		}
	}

	private func makeSampleBuffer(_ data: Data, _ format: CMVideoFormatDescription) -> CMSampleBuffer? {
		var block: CMBlockBuffer?
		guard CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
			blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
			dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
			let block else { return nil }
		let copied = data.withUnsafeBytes {
			CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
				offsetIntoDestination: 0, dataLength: data.count)
		}
		guard copied == noErr else { return nil }

		var sample: CMSampleBuffer?
		var size = data.count
		guard CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
			sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
			sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
			let sample else { return nil }

		// 타임스탬프 없이 즉시 표시: 지연을 늘리는 재생 버퍼를 쓰지 않는다
		if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
		   CFArrayGetCount(attachments) > 0 {
			let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
			CFDictionarySetValue(dict,
				Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
				Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
		}
		return sample
	}
}

/// Annex B 버퍼에서 시작 코드(00 00 01 / 00 00 00 01)로 구분된 NAL 유닛을 하나씩 넘긴다.
private func forEachNAL(in buffer: UnsafeBufferPointer<UInt8>, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
	let n = buffer.count
	var payloadStart = -1
	var i = 0
	func emit(until end: Int) {
		guard payloadStart >= 0 else { return }
		var end = end
		// 뒤쪽 0 바이트는 trailing_zero_8bits이거나 다음 4바이트 시작 코드의 일부
		while end > payloadStart && buffer[end - 1] == 0 { end -= 1 }
		if end > payloadStart {
			body(UnsafeBufferPointer(rebasing: buffer[payloadStart..<end]))
		}
	}
	while i + 2 < n {
		if buffer[i] == 0 && buffer[i + 1] == 0 && buffer[i + 2] == 1 {
			emit(until: i)
			i += 3
			payloadStart = i
		} else {
			i += 1
		}
	}
	emit(until: n)
}
