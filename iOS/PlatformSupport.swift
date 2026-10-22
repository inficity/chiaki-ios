import AVFoundation
import SwiftUI

// Shared/ 코드가 쓰는 플랫폼별 API의 iOS 구현. macOS/PlatformSupport.swift와 같은 이름을 맞춘다.

extension View {
	func numberInput() -> some View { keyboardType(.numberPad) }
	func decimalInput() -> some View { keyboardType(.decimalPad) }

	func plainTextInput() -> some View {
		textInputAutocapitalization(.never).autocorrectionDisabled()
	}

	func inlineNavigationTitle() -> some View { navigationBarTitleDisplayMode(.inline) }

	/// 스트리밍 중에는 상태 막대와 홈 인디케이터를 숨긴다
	func immersiveStream() -> some View {
		statusBarHidden().persistentSystemOverlays(.hidden)
	}

	func streamPresenter<Item: Identifiable, Content: View>(
		item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
	) -> some View {
		fullScreenCover(item: item, content: content)
	}
}

extension ToolbarItemPlacement {
	static var platformLeading: ToolbarItemPlacement { .topBarLeading }
}

enum IdleSleep {
	static func prevent(_ enabled: Bool) {
		UIApplication.shared.isIdleTimerDisabled = enabled
	}
}

/// AVSampleBufferDisplayLayer를 SwiftUI에 붙인다
struct VideoLayerView: UIViewRepresentable {
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
