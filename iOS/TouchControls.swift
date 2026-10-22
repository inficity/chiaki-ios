import ChiakiCore
import SwiftUI
import UIKit

/// 화면 터치 패드의 입력 상태. 바뀔 때마다 StreamSession의 .touch 소스로 넘겨 실제 패드 입력과 합친다.
final class TouchPadModel {
	enum Stick { case left, right }

	private let session: StreamSession
	private var state = ChiakiControllerState()
	private var touchID: Int8?
	private let haptics = UIImpactFeedbackGenerator(style: .light)

	// PS5 터치패드 좌표 범위
	private static let touchpadWidth: CGFloat = 1919
	private static let touchpadHeight: CGFloat = 1079

	init(session: StreamSession) {
		self.session = session
		chiaki_controller_state_set_idle(&state)
	}

	func setButton(_ button: ChiakiControllerButton, _ pressed: Bool) {
		let before = state.buttons
		if pressed { state.buttons |= button.rawValue } else { state.buttons &= ~button.rawValue }
		if pressed && state.buttons != before { haptics.impactOccurred() }
		push()
	}

	func setTrigger(left: Bool, _ pressed: Bool) {
		if pressed { haptics.impactOccurred() }
		if left { state.l2_state = pressed ? 255 : 0 } else { state.r2_state = pressed ? 255 : 0 }
		push()
	}

	/// x, y: -1...1, 아래·오른쪽이 +
	func setStick(_ stick: Stick, x: CGFloat, y: CGFloat) {
		let ax = Int16(clamping: Int(x * CGFloat(Int16.max)))
		let ay = Int16(clamping: Int(y * CGFloat(Int16.max)))
		switch stick {
		case .left: state.left_x = ax; state.left_y = ay
		case .right: state.right_x = ax; state.right_y = ay
		}
		push()
	}

	/// point: 터치패드 영역 안의 비율 좌표(0...1), nil이면 손을 뗌
	func setTouch(_ point: CGPoint?) {
		switch (point, touchID) {
		case (let p?, nil):
			let id = chiaki_controller_state_start_touch(&state, Self.px(p.x), Self.py(p.y))
			touchID = id >= 0 ? id : nil
		case (let p?, let id?):
			chiaki_controller_state_set_touch_pos(&state, UInt8(id), Self.px(p.x), Self.py(p.y))
		case (nil, let id?):
			chiaki_controller_state_stop_touch(&state, UInt8(id))
			touchID = nil
		case (nil, nil):
			return
		}
		push()
	}

	func tap(_ button: ChiakiControllerButton) {
		setButton(button, true)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.setButton(button, false) }
	}

	func reset() {
		chiaki_controller_state_set_idle(&state)
		touchID = nil
		session.setVirtualInput(nil, from: .touch)
	}

	private func push() {
		session.setVirtualInput(state, from: .touch)
	}

	private static func px(_ x: CGFloat) -> UInt16 { UInt16(min(max(x, 0), 1) * touchpadWidth) }
	private static func py(_ y: CGFloat) -> UInt16 { UInt16(min(max(y, 0), 1) * touchpadHeight) }
}

/// 컨트롤러 없이 화면으로 조작하는 가상 패드
struct TouchControlsView: View {
	@State private var model: TouchPadModel

	init(session: StreamSession) {
		_model = State(initialValue: TouchPadModel(session: session))
	}

	var body: some View {
		VStack(spacing: 0) {
			// 위쪽: 숄더 버튼과 터치패드. 오른쪽 위 닫기/PS 버튼 자리를 비워 둔다.
			HStack(alignment: .top, spacing: 10) {
				VStack(spacing: 8) {
					trigger("L2", left: true)
					shoulder("L1", CHIAKI_CONTROLLER_BUTTON_L1)
				}
				Spacer(minLength: 16)
				TouchpadArea(model: model)
					.frame(maxWidth: 260, maxHeight: 64)
				Spacer(minLength: 16)
				VStack(spacing: 8) {
					trigger("R2", left: false)
					shoulder("R1", CHIAKI_CONTROLLER_BUTTON_R1)
				}
			}
			.padding(.top, 64)

			Spacer()

			HStack(alignment: .bottom) {
				VStack(alignment: .leading, spacing: 16) {
					DPad(model: model)
					HStack(alignment: .bottom, spacing: 8) {
						StickPad(model: model, stick: .left)
						RoundButton(label: "L3", size: 34) { model.setButton(CHIAKI_CONTROLLER_BUTTON_L3, $0) }
					}
				}
				Spacer()
				HStack(spacing: 18) {
					RoundButton(symbol: "square.and.arrow.up", size: 34) { model.setButton(CHIAKI_CONTROLLER_BUTTON_SHARE, $0) }
					RoundButton(symbol: "playstation.logo", size: 40) { model.setButton(CHIAKI_CONTROLLER_BUTTON_PS, $0) }
					RoundButton(symbol: "line.3.horizontal", size: 34) { model.setButton(CHIAKI_CONTROLLER_BUTTON_OPTIONS, $0) }
				}
				.padding(.bottom, 8)
				Spacer()
				VStack(alignment: .trailing, spacing: 16) {
					FaceButtons(model: model)
					HStack(alignment: .bottom, spacing: 8) {
						RoundButton(label: "R3", size: 34) { model.setButton(CHIAKI_CONTROLLER_BUTTON_R3, $0) }
						StickPad(model: model, stick: .right)
					}
				}
			}
		}
		.padding(.horizontal, 24)
		.padding(.bottom, 16)
		.onDisappear { model.reset() }
	}

	private func shoulder(_ label: String, _ button: ChiakiControllerButton) -> some View {
		PillButton(label: label) { model.setButton(button, $0) }
	}

	private func trigger(_ label: String, left: Bool) -> some View {
		PillButton(label: label) { model.setTrigger(left: left, $0) }
	}
}

// MARK: - 부품

private let controlFill = Color.white.opacity(0.18)
private let controlPressed = Color.white.opacity(0.45)
private let controlStroke = Color.white.opacity(0.35)

/// 누르는 동안 true, 떼면 false를 한 번씩 알린다
private struct PressGesture: ViewModifier {
	let onChange: (Bool) -> Void
	@State private var pressed = false

	func body(content: Content) -> some View {
		content
			.environment(\.isTouchPressed, pressed)
			.gesture(DragGesture(minimumDistance: 0)
				.onChanged { _ in
					if !pressed { pressed = true; onChange(true) }
				}
				.onEnded { _ in
					pressed = false
					onChange(false)
				})
	}
}

private struct TouchPressedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
	var isTouchPressed: Bool {
		get { self[TouchPressedKey.self] }
		set { self[TouchPressedKey.self] = newValue }
	}
}

private struct RoundButton: View {
	var label: String? = nil
	var symbol: String? = nil
	var size: CGFloat = 48
	var tint: Color = .white
	let onChange: (Bool) -> Void

	var body: some View {
		Face(label: label, symbol: symbol, size: size, tint: tint)
			.modifier(PressGesture(onChange: onChange))
	}

	private struct Face: View {
		let label: String?
		let symbol: String?
		let size: CGFloat
		let tint: Color
		@Environment(\.isTouchPressed) private var pressed

		var body: some View {
			Circle()
				.fill(pressed ? controlPressed : controlFill)
				.overlay(Circle().stroke(controlStroke, lineWidth: 1))
				.overlay {
					if let symbol {
						Image(systemName: symbol).font(.system(size: size * 0.4, weight: .semibold))
					} else if let label {
						Text(label).font(.system(size: size * 0.36, weight: .bold))
					}
				}
				.foregroundStyle(tint)
				.frame(width: size, height: size)
				.contentShape(Circle())
		}
	}
}

private struct PillButton: View {
	let label: String
	let onChange: (Bool) -> Void

	var body: some View {
		Face(label: label).modifier(PressGesture(onChange: onChange))
	}

	private struct Face: View {
		let label: String
		@Environment(\.isTouchPressed) private var pressed

		var body: some View {
			Capsule()
				.fill(pressed ? controlPressed : controlFill)
				.overlay(Capsule().stroke(controlStroke, lineWidth: 1))
				.overlay(Text(label).font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
				.frame(width: 72, height: 34)
				.contentShape(Capsule())
		}
	}
}

/// △ ○ ✕ □ 다이아몬드 배치
private struct FaceButtons: View {
	let model: TouchPadModel
	private let size: CGFloat = 52

	var body: some View {
		Grid(horizontalSpacing: 4, verticalSpacing: 4) {
			GridRow {
				Color.clear.frame(width: size, height: size)
				button("triangle", .green, CHIAKI_CONTROLLER_BUTTON_PYRAMID)
				Color.clear.frame(width: size, height: size)
			}
			GridRow {
				button("square", .pink, CHIAKI_CONTROLLER_BUTTON_BOX)
				Color.clear.frame(width: size, height: size)
				button("circle", .red, CHIAKI_CONTROLLER_BUTTON_MOON)
			}
			GridRow {
				Color.clear.frame(width: size, height: size)
				button("xmark", .blue, CHIAKI_CONTROLLER_BUTTON_CROSS)
				Color.clear.frame(width: size, height: size)
			}
		}
	}

	private func button(_ symbol: String, _ tint: Color, _ button: ChiakiControllerButton) -> some View {
		RoundButton(symbol: symbol, size: size, tint: tint) { model.setButton(button, $0) }
	}
}

/// 방향 버튼: 손가락을 미끄러뜨려 방향을 바꿀 수 있고 대각선도 된다
private struct DPad: View {
	let model: TouchPadModel
	private let size: CGFloat = 150
	@State private var active: Set<Direction> = []

	private enum Direction: CaseIterable {
		case up, down, left, right
		var button: ChiakiControllerButton {
			switch self {
			case .up: CHIAKI_CONTROLLER_BUTTON_DPAD_UP
			case .down: CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN
			case .left: CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT
			case .right: CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT
			}
		}
	}

	var body: some View {
		let arm = size / 3
		ZStack {
			ForEach(Array(Direction.allCases.enumerated()), id: \.offset) { _, direction in
				RoundedRectangle(cornerRadius: 8)
					.fill(active.contains(direction) ? controlPressed : controlFill)
					.overlay(RoundedRectangle(cornerRadius: 8).stroke(controlStroke, lineWidth: 1))
					.frame(width: arm, height: arm)
					.offset(offset(direction, arm))
			}
		}
		.frame(width: size, height: size)
		.contentShape(Rectangle())
		.gesture(DragGesture(minimumDistance: 0)
			.onChanged { update(directions(at: $0.location)) }
			.onEnded { _ in update([]) })
	}

	private func offset(_ direction: Direction, _ arm: CGFloat) -> CGSize {
		switch direction {
		case .up: CGSize(width: 0, height: -arm)
		case .down: CGSize(width: 0, height: arm)
		case .left: CGSize(width: -arm, height: 0)
		case .right: CGSize(width: arm, height: 0)
		}
	}

	/// 가운데 데드존 밖에서 각도로 방향을 고른다 (대각선은 두 방향)
	private func directions(at point: CGPoint) -> Set<Direction> {
		let dx = point.x - size / 2
		let dy = point.y - size / 2
		guard hypot(dx, dy) > size * 0.12 else { return [] }
		let angle = atan2(-dy, dx) * 180 / .pi // 오른쪽 0°, 위 90°
		var result: Set<Direction> = []
		if (-67.5...67.5).contains(angle) { result.insert(.right) }
		if (22.5...157.5).contains(angle) { result.insert(.up) }
		if angle >= 112.5 || angle <= -112.5 { result.insert(.left) }
		if (-157.5 ... -22.5).contains(angle) { result.insert(.down) }
		return result
	}

	private func update(_ next: Set<Direction>) {
		guard next != active else { return }
		for direction in active.subtracting(next) { model.setButton(direction.button, false) }
		for direction in next.subtracting(active) { model.setButton(direction.button, true) }
		active = next
	}
}

/// 아날로그 스틱: 처음 닿은 곳이 아니라 원의 중심을 기준으로 기울기를 잰다
private struct StickPad: View {
	let model: TouchPadModel
	let stick: TouchPadModel.Stick
	private let size: CGFloat = 130
	@State private var knob: CGSize = .zero

	var body: some View {
		let radius = size / 2
		ZStack {
			Circle()
				.fill(controlFill)
				.overlay(Circle().stroke(controlStroke, lineWidth: 1))
			Circle()
				.fill(controlPressed)
				.frame(width: size * 0.42, height: size * 0.42)
				.offset(knob)
		}
		.frame(width: size, height: size)
		.contentShape(Circle())
		.gesture(DragGesture(minimumDistance: 0)
			.onChanged { value in
				var dx = value.location.x - radius
				var dy = value.location.y - radius
				let length = hypot(dx, dy)
				if length > radius {
					dx *= radius / length
					dy *= radius / length
				}
				knob = CGSize(width: dx, height: dy)
				model.setStick(stick, x: dx / radius, y: dy / radius)
			}
			.onEnded { _ in
				knob = .zero
				model.setStick(stick, x: 0, y: 0)
			})
	}
}

/// PS5 터치패드: 끌면 손가락 위치, 짧게 탭하면 터치패드 버튼 클릭
private struct TouchpadArea: View {
	let model: TouchPadModel
	@State private var started: Date?
	@State private var moved = false

	var body: some View {
		GeometryReader { geometry in
			RoundedRectangle(cornerRadius: 12)
				.fill(started != nil ? controlPressed : controlFill)
				.overlay(RoundedRectangle(cornerRadius: 12).stroke(controlStroke, lineWidth: 1))
				.overlay(Text("터치패드").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7)))
				.contentShape(Rectangle())
				.gesture(DragGesture(minimumDistance: 0)
					.onChanged { value in
						if started == nil { started = Date() }
						if hypot(value.translation.width, value.translation.height) > 8 { moved = true }
						let size = geometry.size
						model.setTouch(CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
					}
					.onEnded { _ in
						model.setTouch(nil)
						if let started, !moved, Date().timeIntervalSince(started) < 0.25 {
							model.tap(CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
						}
						started = nil
						moved = false
					})
		}
	}
}
