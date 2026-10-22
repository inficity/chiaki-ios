import ChiakiCore
import GameController

/// 게임패드(DualSense/DualShock 4/MFi)와 키보드 입력을 합쳐 ChiakiControllerState로 넘긴다.
final class ControllerInput {
	var onChange: ((ChiakiControllerState) -> Void)?

	private var controller: GCController?
	private var keyboard: GCKeyboard?
	private var observers: [NSObjectProtocol] = []
	private var padState = ChiakiControllerState()
	private var touchIDs: [Int8?] = [nil, nil]
	private var pressedKeys: Set<GCKeyCode> = []

	// PS5 터치패드 좌표 범위
	private static let touchpadWidth: Float = 1919
	private static let touchpadHeight: Float = 1079

	func start() {
		chiaki_controller_state_set_idle(&padState)
		let center = NotificationCenter.default
		observers = [
			center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] note in
				self?.attach(note.object as? GCController)
			},
			center.addObserver(forName: .GCControllerDidStopBeingCurrent, object: nil, queue: .main) { [weak self] _ in
				self?.attach(GCController.current)
			},
			center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] note in
				self?.attachKeyboard(note.object as? GCKeyboard)
			},
		]
		attach(GCController.current)
		attachKeyboard(GCKeyboard.coalesced)
	}

	func stop() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers = []
		attach(nil)
		attachKeyboard(nil)
	}

	private func publish() {
		var keys = keyboardState()
		var out = ChiakiControllerState()
		chiaki_controller_state_or(&out, &padState, &keys)
		onChange?(out)
	}

	// MARK: - 게임패드

	private func attach(_ newController: GCController?) {
		controller?.extendedGamepad?.valueChangedHandler = nil
		controller = newController
		chiaki_controller_state_set_idle(&padState)
		touchIDs = [nil, nil]
		publish()

		guard let pad = newController?.extendedGamepad else { return }
		// PS 버튼과 만들기(공유) 버튼을 OS가 가로채지 않고 PS5로 보내게 한다
		pad.buttonHome?.preferredSystemGestureState = .disabled
		pad.buttonOptions?.preferredSystemGestureState = .disabled
		pad.valueChangedHandler = { [weak self] pad, _ in
			self?.update(from: pad)
			self?.publish()
		}
		update(from: pad)
		publish()
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

		padState.l2_state = UInt8(pad.leftTrigger.value * 255)
		padState.r2_state = UInt8(pad.rightTrigger.value * 255)
		// GameController는 위가 +, PS 입력은 아래가 +
		padState.left_x = Self.axis(pad.leftThumbstick.xAxis.value)
		padState.left_y = Self.axis(-pad.leftThumbstick.yAxis.value)
		padState.right_x = Self.axis(pad.rightThumbstick.xAxis.value)
		padState.right_y = Self.axis(-pad.rightThumbstick.yAxis.value)

		if let dualSense = pad as? GCDualSenseGamepad {
			map(dualSense.touchpadButton, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
			updateTouch(0, dualSense.touchpadPrimary)
			updateTouch(1, dualSense.touchpadSecondary)
		} else if let dualShock = pad as? GCDualShockGamepad {
			map(dualShock.touchpadButton, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
			updateTouch(0, dualShock.touchpadPrimary)
			updateTouch(1, dualShock.touchpadSecondary)
		}
		padState.buttons = buttons
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
			let id = chiaki_controller_state_start_touch(&padState, px, py)
			touchIDs[slot] = id >= 0 ? id : nil
		case (true, let id?):
			chiaki_controller_state_set_touch_pos(&padState, UInt8(id), px, py)
		case (false, let id?):
			chiaki_controller_state_stop_touch(&padState, UInt8(id))
			touchIDs[slot] = nil
		case (false, nil):
			break
		}
	}

	// MARK: - 키보드

	/// 키보드 배치. 맥과 iPad 하드웨어 키보드에서 쓴다.
	static let keyButtons: [(GCKeyCode, ChiakiControllerButton)] = [
		(.returnOrEnter, CHIAKI_CONTROLLER_BUTTON_CROSS),
		(.spacebar, CHIAKI_CONTROLLER_BUTTON_CROSS),
		(.deleteOrBackspace, CHIAKI_CONTROLLER_BUTTON_MOON),
		(.keyF, CHIAKI_CONTROLLER_BUTTON_BOX),
		(.keyR, CHIAKI_CONTROLLER_BUTTON_PYRAMID),
		(.upArrow, CHIAKI_CONTROLLER_BUTTON_DPAD_UP),
		(.downArrow, CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN),
		(.leftArrow, CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT),
		(.rightArrow, CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT),
		(.keyQ, CHIAKI_CONTROLLER_BUTTON_L1),
		(.keyE, CHIAKI_CONTROLLER_BUTTON_R1),
		(.one, CHIAKI_CONTROLLER_BUTTON_L3),
		(.two, CHIAKI_CONTROLLER_BUTTON_R3),
		(.keyO, CHIAKI_CONTROLLER_BUTTON_OPTIONS),
		(.keyY, CHIAKI_CONTROLLER_BUTTON_SHARE),
		(.tab, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD),
		(.keyH, CHIAKI_CONTROLLER_BUTTON_PS),
	]

	private func attachKeyboard(_ newKeyboard: GCKeyboard?) {
		keyboard?.keyboardInput?.keyChangedHandler = nil
		keyboard = newKeyboard
		pressedKeys = []
		newKeyboard?.keyboardInput?.keyChangedHandler = { [weak self] _, _, key, pressed in
			guard let self else { return }
			if pressed { self.pressedKeys.insert(key) } else { self.pressedKeys.remove(key) }
			self.publish()
		}
	}

	/// WASD: 왼쪽 스틱, IJKL: 오른쪽 스틱, Z/C: L2/R2, 나머지는 keyButtons
	private func keyboardState() -> ChiakiControllerState {
		var state = ChiakiControllerState()
		chiaki_controller_state_set_idle(&state)
		guard !pressedKeys.isEmpty else { return state }

		func held(_ key: GCKeyCode) -> Float { pressedKeys.contains(key) ? 1 : 0 }
		for (key, button) in Self.keyButtons where pressedKeys.contains(key) {
			state.buttons |= button.rawValue
		}
		state.l2_state = pressedKeys.contains(.keyZ) ? 255 : 0
		state.r2_state = pressedKeys.contains(.keyC) ? 255 : 0
		state.left_x = Self.axis(held(.keyD) - held(.keyA))
		state.left_y = Self.axis(held(.keyS) - held(.keyW))
		state.right_x = Self.axis(held(.keyL) - held(.keyJ))
		state.right_y = Self.axis(held(.keyK) - held(.keyI))
		return state
	}

	private static func axis(_ value: Float) -> Int16 {
		Int16(clamping: Int(value * Float(Int16.max)))
	}
}
