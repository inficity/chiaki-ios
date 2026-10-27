import AVFoundation
import os

/// Opus 디코더가 내놓는 16비트 PCM을 짧은 링 버퍼를 거쳐 바로 재생한다.
/// 버퍼가 목표보다 많이 쌓이면 오래된 샘플을 버려서 지연이 늘어나지 않게 한다.
final class AudioPlayer {
	private let engine = AVAudioEngine()
	private var ring: PCMRing?
	private var source: AVAudioSourceNode?
	private var sampleRate = 48_000.0

	/// chiaki 오디오 스레드에서 스트림 형식이 정해지면 호출된다.
	func configure(channels: Int, rate: Double) {
		stop()
#if os(iOS)
		let session = AVAudioSession.sharedInstance()
		try? session.setCategory(.playback, mode: .default)
		try? session.setPreferredIOBufferDuration(0.005)
		try? session.setActive(true)
#endif

		let ring = PCMRing(channels: channels, capacityFrames: Int(rate / 2),
			targetFrames: Int(rate * 0.04), maxFrames: Int(rate * 0.1))
		guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else { return }
		let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
			ring.read(into: UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(frameCount))
			return noErr
		}
		engine.attach(source)
		engine.connect(source, to: engine.mainMixerNode, format: format)
		do {
			try engine.start()
		} catch {
			engine.detach(source)
			return
		}
		self.ring = ring
		self.source = source
		sampleRate = rate
	}

	/// 지난번 호출 이후 버퍼가 비어 끊긴 횟수와, 밀려서 버린 양(ms)
	func takeStats() -> (underruns: Int, droppedMs: Int) {
		guard let (underruns, dropped) = ring?.takeStats() else { return (0, 0) }
		return (underruns, Int(Double(dropped) / sampleRate * 1000))
	}

	/// samples: 채널이 섞인(interleaved) PCM, frames: 채널당 샘플 수
	func push(_ samples: UnsafePointer<Int16>, frames: Int) {
		ring?.write(samples, frames: frames)
	}

	func stop() {
		engine.stop()
		if let source { engine.detach(source) }
		source = nil
		ring = nil
	}
}

/// 오디오 렌더 스레드와 chiaki 스레드가 함께 쓰는 링 버퍼
private final class PCMRing {
	private let channels: Int
	private let capacity: Int
	private let target: Int
	private let max: Int
	private let storage: UnsafeMutablePointer<Int16>
	private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
	private var readPos = 0
	private var count = 0
	/// 처음엔 목표량이 찰 때까지 무음을 낸다 (시작 직후 끊김 방지)
	private var primed = false
	private var underruns = 0
	private var droppedFrames = 0

	init(channels: Int, capacityFrames: Int, targetFrames: Int, maxFrames: Int) {
		self.channels = channels
		capacity = capacityFrames
		target = targetFrames
		max = maxFrames
		storage = .allocate(capacity: capacityFrames * channels)
		lock.initialize(to: os_unfair_lock())
	}

	deinit {
		storage.deallocate()
		lock.deallocate()
	}

	func write(_ samples: UnsafePointer<Int16>, frames: Int) {
		os_unfair_lock_lock(lock)
		defer { os_unfair_lock_unlock(lock) }
		for f in 0..<frames {
			if count == capacity { drop(1); droppedFrames += 1 }
			let pos = (readPos + count) % capacity
			for c in 0..<channels {
				storage[pos * channels + c] = samples[f * channels + c]
			}
			count += 1
		}
		if count > max {
			droppedFrames += count - target
			drop(count - target)
		}
	}

	func takeStats() -> (Int, Int) {
		os_unfair_lock_lock(lock)
		defer { os_unfair_lock_unlock(lock) }
		defer { underruns = 0; droppedFrames = 0 }
		return (underruns, droppedFrames)
	}

	func read(into buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
		os_unfair_lock_lock(lock)
		defer { os_unfair_lock_unlock(lock) }
		if !primed && count >= target { primed = true }
		for f in 0..<frames {
			let available = primed && count > 0
			for c in 0..<min(channels, buffers.count) {
				let out = buffers[c].mData!.assumingMemoryBound(to: Float.self)
				out[f] = available ? Float(storage[readPos * channels + c]) / 32768 : 0
			}
			if available {
				readPos = (readPos + 1) % capacity
				count -= 1
			}
		}
		if count == 0 && primed {
			// 재생 중에 버퍼가 비었다: 네트워크로 오디오가 늦게 왔다
			primed = false
			underruns += 1
		}
	}

	private func drop(_ frames: Int) {
		readPos = (readPos + frames) % capacity
		count -= frames
	}
}
