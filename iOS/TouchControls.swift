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
		guard state.buttons != before else { return }
		if pressed { haptics.impactOccurred() }
		push()
	}

	func setTrigger(left: Bool, _ pressed: Bool) {
		let value: UInt8 = pressed ? 255 : 0
		guard (left ? state.l2_state : state.r2_state) != value else { return }
		if pressed { haptics.impactOccurred() }
		if left { state.l2_state = value } else { state.r2_state = value }
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

/// 컨트롤러 없이 화면으로 조작하는 가상 패드.
/// 여러 손가락을 동시에 쓰고, 시스템이 터치를 가져가도(cancel) 버튼이 확실히 떼지도록 UIKit에서 직접 추적한다.
struct TouchControlsView: UIViewRepresentable {
	let session: StreamSession
	/// 메뉴 버튼(⋯)을 누르면 앱 메뉴를 연다
	let onMenu: () -> Void

	func makeCoordinator() -> TouchPadModel { TouchPadModel(session: session) }

	func makeUIView(context: Context) -> GamepadOverlayView {
		GamepadOverlayView(model: context.coordinator, onMenu: onMenu)
	}

	func updateUIView(_ view: GamepadOverlayView, context: Context) {}

	static func dismantleUIView(_ view: GamepadOverlayView, coordinator: TouchPadModel) {
		coordinator.reset()
	}
}

final class GamepadOverlayView: UIView {
	private let model: TouchPadModel
	private var controls: [PadControl] = []
	/// 손가락마다 처음 잡은 컨트롤
	private var owners: [ObjectIdentifier: PadControl] = [:]

	private let l1, l2, r1, r2, l3, r3, create, options, ps: PadButton
	private let cross, circle, square, triangle: PadButton
	/// 앱 메뉴(닫기·통계·터치 패드 켜고 끄기)를 여는 작은 버튼. PS5로는 아무것도 보내지 않는다.
	private let menu: PadButton
	private let dpad: DPadControl
	private let leftStick, rightStick: StickControl
	private let touchpad: TouchpadControl

	init(model: TouchPadModel, onMenu: @escaping () -> Void) {
		self.model = model
		func button(_ title: String?, _ symbol: String?, _ id: ChiakiControllerButton, tint: UIColor = .white, capsule: Bool = false, slides: Bool = false) -> PadButton {
			PadButton(title: title, symbol: symbol, tint: tint, capsule: capsule, slides: slides) { model.setButton(id, $0) }
		}
		l1 = button("L1", nil, CHIAKI_CONTROLLER_BUTTON_L1, capsule: true)
		r1 = button("R1", nil, CHIAKI_CONTROLLER_BUTTON_R1, capsule: true)
		l2 = PadButton(title: "L2", symbol: nil, tint: .white, capsule: true, slides: false) { model.setTrigger(left: true, $0) }
		r2 = PadButton(title: "R2", symbol: nil, tint: .white, capsule: true, slides: false) { model.setTrigger(left: false, $0) }
		l3 = button("L3", nil, CHIAKI_CONTROLLER_BUTTON_L3)
		r3 = button("R3", nil, CHIAKI_CONTROLLER_BUTTON_R3)
		create = button(nil, "square.and.arrow.up", CHIAKI_CONTROLLER_BUTTON_SHARE)
		options = button(nil, "line.3.horizontal", CHIAKI_CONTROLLER_BUTTON_OPTIONS)
		ps = button(nil, "playstation.logo", CHIAKI_CONTROLLER_BUTTON_PS)
		// 페이스 버튼은 손가락을 미끄러뜨려 옆 버튼으로 옮겨갈 수 있다
		triangle = button(nil, "triangle", CHIAKI_CONTROLLER_BUTTON_PYRAMID, tint: .systemGreen, slides: true)
		circle = button(nil, "circle", CHIAKI_CONTROLLER_BUTTON_MOON, tint: .systemRed, slides: true)
		cross = button(nil, "xmark", CHIAKI_CONTROLLER_BUTTON_CROSS, tint: .systemBlue, slides: true)
		square = button(nil, "square", CHIAKI_CONTROLLER_BUTTON_BOX, tint: .systemPink, slides: true)
		dpad = DPadControl(model: model)
		leftStick = StickControl(model: model, stick: .left)
		rightStick = StickControl(model: model, stick: .right)
		touchpad = TouchpadControl(model: model)
		menu = PadButton(title: nil, symbol: "ellipsis", tint: .white, capsule: false, slides: false) { pressed in
			if pressed { onMenu() }
		}
		super.init(frame: .zero)

		isMultipleTouchEnabled = true
		backgroundColor = .clear
		// 앞에 있을수록 먼저 잡는다. 스틱 영역은 넓어서 다른 버튼이 다 빠진 뒤에 맨 끝에서 받는다.
		controls = [l2, l1, r2, r1, touchpad, create, options, ps, menu, dpad, l3,
		            triangle, circle, cross, square, r3, leftStick, rightStick]
		controls.forEach(addSubview)
	}

	required init?(coder: NSCoder) { fatalError() }

	// MARK: 배치

	/// 안전 영역 안에서 배치한다. 가로 화면 기준 높이 360pt에 맞춘 크기를 화면에 맞게 줄이거나 키운다.
	/// 아래쪽 가운데는 홈 인디케이터(앱 전환 바) 자리라 비워 둔다.
	override func layoutSubviews() {
		super.layoutSubviews()
		// 가로 화면의 좌우 안전 영역 여백(15 Pro 59pt)은 Dynamic Island·노치를 피하려고 넉넉하게 잡혀 있다.
		// 아일랜드는 가장자리에서 약 48pt까지라 그 바깥(여백 - 10pt)까지 버튼을 붙인다. 여백이 없으면 12pt.
		let safe = safeAreaInsets
		let sideLeft = safe.left > 0 ? safe.left - 10 : 12
		let sideRight = safe.right > 0 ? safe.right - 10 : 12
		var area = CGRect(x: sideLeft, y: safe.top + 8,
		                  width: bounds.width - sideLeft - sideRight, height: bounds.height - safe.top - safe.bottom - 16)
		if area.height > area.width {
			// 세로 화면: 영상 아래쪽 절반에 배치
			area = CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
		}
		let u = min(max(min(area.height / 340, area.width / 700), 0.6), 1.3)
		let left = area.minX, right = area.maxX, top = area.minY, bottom = area.maxY

		// 위쪽: 숄더 버튼 (L2 위, L1 아래), 가운데에 만들기·터치패드·OPTIONS, 그 아래 PS
		let pill = CGSize(width: 72 * u, height: 32 * u)
		l2.frame = CGRect(origin: CGPoint(x: left, y: top), size: pill)
		l1.frame = CGRect(origin: CGPoint(x: left, y: top + 40 * u), size: pill)
		r2.frame = CGRect(origin: CGPoint(x: right - pill.width, y: top), size: pill)
		r1.frame = CGRect(origin: CGPoint(x: right - pill.width, y: top + 40 * u), size: pill)

		let padSize = CGSize(width: min(200 * u, area.width * 0.3), height: 52 * u)
		touchpad.frame = CGRect(x: area.midX - padSize.width / 2, y: top, width: padSize.width, height: padSize.height)
		let small = 34 * u
		create.frame = CGRect(x: touchpad.frame.minX - small - 10 * u, y: top + (padSize.height - small) / 2, width: small, height: small)
		options.frame = CGRect(x: touchpad.frame.maxX + 10 * u, y: top + (padSize.height - small) / 2, width: small, height: small)
		ps.frame = CGRect(x: area.midX - small / 2, y: touchpad.frame.maxY + 8 * u, width: small, height: small)
		// OPTIONS와 R2 사이 가운데에 메뉴 버튼
		let menuSize = 28 * u
		menu.frame = CGRect(x: (options.frame.maxX + r2.frame.minX - menuSize) / 2, y: top + (padSize.height - menuSize) / 2,
		                    width: menuSize, height: menuSize)

		// 왼쪽: 방향 버튼(가운데 높이), 그 오른쪽 아래 스틱, 구석에 L3
		let dpadSize = 120 * u
		let stickSize = 112 * u
		let midY = top + (bottom - top) * 0.5
		dpad.frame = CGRect(x: left, y: midY - dpadSize / 2, width: dpadSize, height: dpadSize)
		l3.frame = CGRect(x: left + 4 * u, y: bottom - 38 * u, width: 36 * u, height: 36 * u)

		// 스틱은 숄더 버튼 아래부터 화면 가운데 근처까지 넓은 영역 어디서나 잡힌다 (닿은 곳이 중심).
		// 아래 가운데 홈 인디케이터(앱 전환 바) 주변만 뺀다. 터치패드·PS는 먼저 잡히므로 겹쳐도 된다.
		let zoneTop = l1.frame.maxY + 8 * u
		let centerGap = 12 * u
		let homeIndicator = CGRect(x: bounds.midX - 100, y: bounds.maxY - 60, width: 200, height: 60)
		leftStick.configure(size: stickSize,
			rest: CGPoint(x: left + dpadSize + 4 * u + stickSize * 0.25, y: bottom - stickSize / 2),
			// 보이지 않는 스틱 영역은 화면 끝까지 쓴다 (안전 영역 밖 포함)
			zone: CGRect(x: bounds.minX, y: zoneTop, width: area.midX - centerGap - bounds.minX, height: bounds.maxY - zoneTop),
			excluding: homeIndicator)

		// 오른쪽: 페이스 버튼 다이아몬드(가운데 높이), 그 왼쪽 아래 스틱, 구석에 R3
		let face = 46 * u
		let faceCenter = CGPoint(x: right - face * 1.5, y: midY)
		triangle.frame = CGRect(x: faceCenter.x - face / 2, y: faceCenter.y - face * 1.5, width: face, height: face)
		cross.frame = CGRect(x: faceCenter.x - face / 2, y: faceCenter.y + face * 0.5, width: face, height: face)
		square.frame = CGRect(x: faceCenter.x - face * 1.5, y: faceCenter.y - face / 2, width: face, height: face)
		circle.frame = CGRect(x: faceCenter.x + face * 0.5, y: faceCenter.y - face / 2, width: face, height: face)
		r3.frame = CGRect(x: right - 40 * u, y: bottom - 38 * u, width: 36 * u, height: 36 * u)
		rightStick.configure(size: stickSize,
			rest: CGPoint(x: right - face * 3 - 4 * u - stickSize * 0.25, y: bottom - stickSize / 2),
			zone: CGRect(x: area.midX + centerGap, y: zoneTop, width: bounds.maxX - area.midX - centerGap, height: bounds.maxY - zoneTop),
			excluding: homeIndicator)
	}

	// MARK: 터치

	/// 컨트롤 위가 아니면 터치를 아래 영상으로 넘긴다
	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		control(at: point) != nil
	}

	private func control(at point: CGPoint, slidingOnly: Bool = false) -> PadControl? {
		controls.first { control in
			if slidingOnly, !((control as? PadButton)?.slides ?? false) { return false }
			return control.hits(point)
		}
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			let point = touch.location(in: self)
			guard let control = control(at: point) else { continue }
			owners[ObjectIdentifier(touch)] = control
			control.began(at: point)
		}
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			let key = ObjectIdentifier(touch)
			guard let control = owners[key] else { continue }
			let point = touch.location(in: self)
			if let button = control as? PadButton, button.slides, !button.hitFrame.contains(point) {
				// 페이스 버튼 사이로 미끄러지면 버튼을 갈아탄다
				if let next = self.control(at: point, slidingOnly: true), next !== button {
					button.ended()
					owners[key] = next
					next.began(at: point)
				}
				continue
			}
			control.moved(to: point)
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

	private func release(_ touches: Set<UITouch>) {
		for touch in touches {
			owners.removeValue(forKey: ObjectIdentifier(touch))?.ended()
		}
	}
}

// MARK: - 컨트롤

private let fillColor = UIColor.white.withAlphaComponent(0.16)
private let pressedColor = UIColor.white.withAlphaComponent(0.42)
private let strokeColor = UIColor.white.withAlphaComponent(0.35)

/// 터치 좌표는 모두 오버레이(부모) 좌표계로 받는다
class PadControl: UIView {
	/// 손가락이 조금 빗나가도 눌리게 실제 모양보다 넓게 잡는다
	var hitInset: CGFloat { -8 }
	var hitFrame: CGRect { frame.insetBy(dx: hitInset, dy: hitInset) }

	/// 이 점을 누르면 이 컨트롤이 잡는가
	func hits(_ point: CGPoint) -> Bool { hitFrame.contains(point) }

	init() {
		super.init(frame: .zero)
		isUserInteractionEnabled = false // 터치는 GamepadOverlayView가 나눠 준다
	}

	required init?(coder: NSCoder) { fatalError() }

	func began(at point: CGPoint) {}
	func moved(to point: CGPoint) {}
	func ended() {}

	func local(_ point: CGPoint) -> CGPoint {
		CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
	}

	func styleShape(_ view: UIView, pressed: Bool) {
		view.backgroundColor = pressed ? pressedColor : fillColor
		view.layer.borderColor = strokeColor.cgColor
		view.layer.borderWidth = 1
	}
}

final class PadButton: PadControl {
	let slides: Bool
	private let onChange: (Bool) -> Void
	private let capsule: Bool
	private let label = UILabel()
	private let icon = UIImageView()
	private var pressed = false

	init(title: String?, symbol: String?, tint: UIColor, capsule: Bool, slides: Bool, onChange: @escaping (Bool) -> Void) {
		self.slides = slides
		self.onChange = onChange
		self.capsule = capsule
		super.init()
		label.text = title
		label.textColor = tint
		label.textAlignment = .center
		icon.image = symbol.flatMap { UIImage(systemName: $0) }
		icon.tintColor = tint
		icon.contentMode = .scaleAspectFit
		addSubview(label)
		addSubview(icon)
		styleShape(self, pressed: false)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		layer.cornerRadius = min(bounds.width, bounds.height) / 2
		label.font = .systemFont(ofSize: bounds.height * (capsule ? 0.42 : 0.36), weight: .bold)
		label.frame = bounds
		icon.frame = bounds.insetBy(dx: bounds.width * 0.28, dy: bounds.height * 0.28)
	}

	override func began(at point: CGPoint) { set(true) }
	override func ended() { set(false) }

	private func set(_ value: Bool) {
		guard value != pressed else { return }
		pressed = value
		styleShape(self, pressed: value)
		onChange(value)
	}
}

/// 방향 버튼: 손가락을 미끄러뜨려 방향을 바꿀 수 있고 대각선도 된다
final class DPadControl: PadControl {
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

	private let model: TouchPadModel
	private var arms: [Direction: UIView] = [:]
	private var active: Set<Direction> = []

	init(model: TouchPadModel) {
		self.model = model
		super.init()
		for direction in Direction.allCases {
			let arm = UIView()
			styleShape(arm, pressed: false)
			arms[direction] = arm
			addSubview(arm)
		}
	}

	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		let a = bounds.width / 3
		for (direction, arm) in arms {
			let origin: CGPoint = switch direction {
			case .up: CGPoint(x: a, y: 0)
			case .down: CGPoint(x: a, y: 2 * a)
			case .left: CGPoint(x: 0, y: a)
			case .right: CGPoint(x: 2 * a, y: a)
			}
			arm.frame = CGRect(origin: origin, size: CGSize(width: a, height: a)).insetBy(dx: 2, dy: 2)
			arm.layer.cornerRadius = 8
		}
	}

	override func began(at point: CGPoint) { update(directions(at: local(point))) }
	override func moved(to point: CGPoint) { update(directions(at: local(point))) }
	override func ended() { update([]) }

	/// 가운데 데드존 밖에서 각도로 방향을 고른다 (대각선은 두 방향)
	private func directions(at point: CGPoint) -> Set<Direction> {
		let dx = point.x - bounds.midX
		let dy = point.y - bounds.midY
		guard hypot(dx, dy) > bounds.width * 0.12 else { return [] }
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
		for direction in active.subtracting(next) {
			model.setButton(direction.button, false)
			arms[direction].map { styleShape($0, pressed: false) }
		}
		for direction in next.subtracting(active) {
			model.setButton(direction.button, true)
			arms[direction].map { styleShape($0, pressed: true) }
		}
		active = next
	}
}

/// 아날로그 스틱: 처음 닿은 곳이 아니라 원의 중심을 기준으로 기울기를 잰다
/// 플로팅 아날로그 스틱: 처음 닿은 곳이 중심(앵커)이 되고, 손을 뗄 때까지 그 중심을 기준으로 기울기를 잰다.
/// 손을 떼면 원래 자리로 돌아가 흐리게 표시한다.
final class StickControl: PadControl {
	private let model: TouchPadModel
	private let stick: TouchPadModel.Stick
	private let knob = UIView()
	/// 이 영역 안 어디를 눌러도 스틱이 잡힌다 (부모 좌표)
	private var zone: CGRect = .zero
	/// 영역 안이라도 여기는 잡지 않는다 (홈 인디케이터 주변)
	private var excluded: CGRect = .null
	/// 쉬고 있을 때 스틱을 보여 줄 자리 (부모 좌표)
	private var rest: CGPoint = .zero
	private var anchor: CGPoint?

	override var hitFrame: CGRect { zone }
	override func hits(_ point: CGPoint) -> Bool { zone.contains(point) && !excluded.contains(point) }

	init(model: TouchPadModel, stick: TouchPadModel.Stick) {
		self.model = model
		self.stick = stick
		super.init()
		styleShape(self, pressed: false)
		knob.backgroundColor = pressedColor
		addSubview(knob)
		alpha = 0.5
	}

	required init?(coder: NSCoder) { fatalError() }

	func configure(size: CGFloat, rest: CGPoint, zone: CGRect, excluding excluded: CGRect) {
		self.zone = zone
		self.excluded = excluded
		self.rest = rest
		bounds = CGRect(x: 0, y: 0, width: size, height: size)
		if anchor == nil { center = rest }
		setNeedsLayout()
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		layer.cornerRadius = bounds.width / 2
		let size = bounds.width * 0.42
		knob.bounds = CGRect(x: 0, y: 0, width: size, height: size)
		knob.layer.cornerRadius = size / 2
		if anchor == nil { knob.center = CGPoint(x: bounds.midX, y: bounds.midY) }
	}

	override func began(at point: CGPoint) {
		anchor = point
		center = point
		alpha = 1
		move(point)
	}

	override func moved(to point: CGPoint) { move(point) }

	override func ended() {
		anchor = nil
		center = rest
		alpha = 0.5
		knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
		model.setStick(stick, x: 0, y: 0)
	}

	private func move(_ point: CGPoint) {
		guard let anchor else { return }
		let radius = bounds.width / 2
		var dx = point.x - anchor.x
		var dy = point.y - anchor.y
		let length = hypot(dx, dy)
		if length > radius {
			dx *= radius / length
			dy *= radius / length
		}
		knob.center = CGPoint(x: bounds.midX + dx, y: bounds.midY + dy)
		model.setStick(stick, x: dx / radius, y: dy / radius)
	}
}

/// PS5 터치패드: 끌면 손가락 위치, 짧게 탭하면 터치패드 버튼 클릭
final class TouchpadControl: PadControl {
	private let model: TouchPadModel
	private let label = UILabel()
	private var start: (time: Date, point: CGPoint)?
	private var moved = false

	init(model: TouchPadModel) {
		self.model = model
		super.init()
		styleShape(self, pressed: false)
		label.text = "터치패드"
		label.textColor = UIColor.white.withAlphaComponent(0.7)
		label.textAlignment = .center
		addSubview(label)
	}

	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		layer.cornerRadius = 12
		label.font = .systemFont(ofSize: max(10, bounds.height * 0.24), weight: .semibold)
		label.frame = bounds
	}

	override func began(at point: CGPoint) {
		start = (Date(), point)
		moved = false
		styleShape(self, pressed: true)
		report(point)
	}

	override func moved(to point: CGPoint) {
		if let start, hypot(point.x - start.point.x, point.y - start.point.y) > 8 { moved = true }
		report(point)
	}

	override func ended() {
		model.setTouch(nil)
		styleShape(self, pressed: false)
		if let start, !moved, Date().timeIntervalSince(start.time) < 0.25 {
			model.tap(CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
		}
		start = nil
	}

	private func report(_ point: CGPoint) {
		let p = local(point)
		model.setTouch(CGPoint(x: p.x / bounds.width, y: p.y / bounds.height))
	}
}
