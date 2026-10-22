import AVFoundation
import SwiftUI

// Shared/ 코드가 쓰는 플랫폼별 API의 macOS 구현. iOS/PlatformSupport.swift와 같은 이름을 맞춘다.

extension View {
	func numberInput() -> some View { self }
	func decimalInput() -> some View { self }
	func plainTextInput() -> some View { autocorrectionDisabled() }
	func inlineNavigationTitle() -> some View { self }
	func immersiveStream() -> some View { self }

	/// 맥에서는 창 안에 스트리밍 화면을 덮는다. 전체 화면은 창의 전체 화면 버튼(⌃⌘F)으로 전환한다.
	func streamPresenter<Item: Identifiable, Content: View>(
		item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
	) -> some View {
		overlay {
			if let value = item.wrappedValue {
				content(value)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.toolbar(item.wrappedValue == nil ? .automatic : .hidden, for: .windowToolbar)
	}
}

extension ToolbarItemPlacement {
	static var platformLeading: ToolbarItemPlacement { .navigation }
}

enum PlatformFeatures {
	/// 맥은 키보드와 패드로 조작한다
	static let touchControls = false
}

/// 맥에는 화면 터치 패드가 없다 (iOS/TouchControls.swift와 같은 이름)
struct TouchControlsView: View {
	init(session: StreamSession) {}
	var body: some View { EmptyView() }
}

enum IdleSleep {
	private static var activity: NSObjectProtocol?

	/// 화면 잠자기와 App Nap을 막는다. App Nap이 걸리면 타이머가 늦어져 지연이 생긴다.
	static func prevent(_ enabled: Bool) {
		if enabled, activity == nil {
			activity = ProcessInfo.processInfo.beginActivity(
				options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical],
				reason: "PS5 스트리밍")
		} else if !enabled, let current = activity {
			ProcessInfo.processInfo.endActivity(current)
			activity = nil
		}
	}
}

/// AVSampleBufferDisplayLayer를 SwiftUI에 붙인다
struct VideoLayerView: NSViewRepresentable {
	let layer: AVSampleBufferDisplayLayer

	func makeNSView(context: Context) -> LayerHostView {
		let view = LayerHostView()
		view.wantsLayer = true
		view.layer?.backgroundColor = .black
		view.hosted = layer
		view.layer?.addSublayer(layer)
		return view
	}

	func updateNSView(_ view: LayerHostView, context: Context) {}

	final class LayerHostView: NSView {
		var hosted: CALayer?

		override func layout() {
			super.layout()
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			hosted?.frame = bounds
			CATransaction.commit()
		}

		// 키 입력은 GameController(GCKeyboard)로 받는다.
		// 여기서 이벤트를 삼키지 않으면 키를 누를 때마다 경고음이 난다.
		override var acceptsFirstResponder: Bool { true }
		override func keyDown(with event: NSEvent) {}
		override func keyUp(with event: NSEvent) {}
		override func flagsChanged(with event: NSEvent) {}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			window?.makeFirstResponder(self)
		}
	}
}
