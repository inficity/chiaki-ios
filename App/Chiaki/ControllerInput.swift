import ChiakiCore
import GameController

/// 연결된 게임패드(DualSense/DualShock 4/MFi) 입력을 ChiakiControllerState로 바꿔 넘긴다.
final class ControllerInput {
	var onChange: ((ChiakiControllerState) -> Void)?

	private var controller: GCController?
	private var observers: [NSObjectProtocol] = []
	private var state = ChiakiControllerState()
	private var touchIDs: [Int8?] = [nil, nil]

	// PS5 터치패드 좌표 범위
	private static let touchpadWidth: Float = 1919
	private static let touchpadHeight: Float = 1079

	func start() {
		chiaki_controller_state_set_idle(&state)
		let center = NotificationCenter.default
		observers = [
			center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] note in
				self?.attach(note.object as? GCController)
			},
			center.addObserver(forName: .GCControllerDidStopBeingCurrent, object: nil, queue: .main) { [weak self] _ in
				self?.attach(GCController.current)
			},
		]
		attach(GCController.current)
	}

	func stop() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers = []
		attach(nil)
	}

	private func attach(_ newController: GCController?) {
		controller?.extendedGamepad?.valueChangedHandler = nil
		controller = newController
		chiaki_controller_state_set_idle(&state)
		touchIDs = [nil, nil]
		onChange?(state)

		guard let pad = newController?.extendedGamepad else { return }
		// PS 버튼과 만들기(공유) 버튼을 iOS가 가로채지 않고 PS5로 보내게 한다
		pad.buttonHome?.preferredSystemGestureState = .disabled
		pad.buttonOptions?.preferredSystemGestureState = .disabled
		pad.valueChangedHandler = { [weak self] pad, _ in
			guard let self else { return }
			self.update(from: pad)
			self.onChange?(self.state)
		}
		update(from: pad)
		onChange?(state)
	}

	private func update(from pad: GCExtendedGamepad) {
		var buttons: UInt32 = 0
		func map(_ input: GCControllerButtonInput?, _ button: ChiakiControllerButton) {
			if input?.isPressed == true { buttons |= button.rawValue }
		}
		map(pad.buttonA, CHIAKI_CONTROLLER_BUTTON_CROSS)
		map(pad.buttonB, CHIAKI_CONTROLLER_BUTTON_MOON)
		map(pad.buttonX, CHIAKI_CONTROLLER_BUTTON_BOX)
		map(pad.buttonY, CHIAKI_CONTROLLER_BUTTON_PYRAMID)
		map(pad.dpad.left, CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT)
		map(pad.dpad.right, CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT)
		map(pad.dpad.up, CHIAKI_CONTROLLER_BUTTON_DPAD_UP)
		map(pad.dpad.down, CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN)
		map(pad.leftShoulder, CHIAKI_CONTROLLER_BUTTON_L1)
		map(pad.rightShoulder, CHIAKI_CONTROLLER_BUTTON_R1)
		map(pad.leftThumbstickButton, CHIAKI_CONTROLLER_BUTTON_L3)
		map(pad.rightThumbstickButton, CHIAKI_CONTROLLER_BUTTON_R3)
		map(pad.buttonMenu, CHIAKI_CONTROLLER_BUTTON_OPTIONS)
		map(pad.buttonOptions, CHIAKI_CONTROLLER_BUTTON_SHARE)
		map(pad.buttonHome, CHIAKI_CONTROLLER_BUTTON_PS)

		state.l2_state = UInt8(pad.leftTrigger.value * 255)
		state.r2_state = UInt8(pad.rightTrigger.value * 255)
		// GameController는 위가 +, PS 입력은 아래가 +
		state.left_x = Self.axis(pad.leftThumbstick.xAxis.value)
		state.left_y = Self.axis(-pad.leftThumbstick.yAxis.value)
		state.right_x = Self.axis(pad.rightThumbstick.xAxis.value)
		state.right_y = Self.axis(-pad.rightThumbstick.yAxis.value)

		if let dualSense = pad as? GCDualSenseGamepad {
			map(dualSense.touchpadButton, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
			updateTouch(0, dualSense.touchpadPrimary)
			updateTouch(1, dualSense.touchpadSecondary)
		} else if let dualShock = pad as? GCDualShockGamepad {
			map(dualShock.touchpadButton, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
			updateTouch(0, dualShock.touchpadPrimary)
			updateTouch(1, dualShock.touchpadSecondary)
		}
		state.buttons = buttons
	}

	/// 터치패드 손가락 하나. 손을 떼면 좌표가 (0, 0)으로 돌아온다.
	private func updateTouch(_ slot: Int, _ pad: GCControllerDirectionPad) {
		let x = pad.xAxis.value
		let y = pad.yAxis.value
		let touching = x != 0 || y != 0
		let px = UInt16((x + 1) / 2 * Self.touchpadWidth)
		let py = UInt16((1 - (y + 1) / 2) * Self.touchpadHeight)
		switch (touching, touchIDs[slot]) {
		case (true, nil):
			let id = chiaki_controller_state_start_touch(&state, px, py)
			touchIDs[slot] = id >= 0 ? id : nil
		case (true, let id?):
			chiaki_controller_state_set_touch_pos(&state, UInt8(id), px, py)
		case (false, let id?):
			chiaki_controller_state_stop_touch(&state, UInt8(id))
			touchIDs[slot] = nil
		case (false, nil):
			break
		}
	}

	private static func axis(_ value: Float) -> Int16 {
		Int16(clamping: Int(value * Float(Int16.max)))
	}
}
