import ChiakiCore
import GameController
import os

/// 실제 패드·키보드가 아닌 입력 소스. 각자 상태를 넣으면 실제 입력과 합쳐서 PS5로 간다.
enum VirtualInputSource: Hashable {
	/// 화면 터치 패드
	case touch
	/// 에이전트(MCP) 조작
	case agent
}

/// 게임패드(DualSense/DualShock 4/MFi), 키보드, 가상 입력(터치·에이전트)을 합쳐 ChiakiControllerState로 넘긴다.
/// 버튼은 OR, 트리거는 큰 값, 스틱은 절댓값이 큰 쪽이 이긴다 (chiaki_controller_state_or).
final class ControllerInput {
	var onChange: ((ChiakiControllerState) -> Void)?

	private var controller: GCController?
	private var keyboard: GCKeyboard?
	private var observers: [NSObjectProtocol] = []
	private var padState = ChiakiControllerState()
	private var touchIDs: [Int8?] = [nil, nil]
	private var pressedKeys: Set<GCKeyCode> = []
	private var homePressed = false
	private var tappedButtons: UInt32 = 0
	private var virtualStates: [VirtualInputSource: ChiakiControllerState] = [:]
	private static let log = Logger(subsystem: "ChiakiRemote", category: "input")

	// PS5 터치패드 좌표 범위
	private static let touchpadWidth: Float = 1919
	private static let touchpadHeight: Float = 1079

	init() {
		// 0으로 채운 상태는 터치 id 0(손가락이 (0,0)에 닿음)이라 idle(-1)로 시작해야 한다
		chiaki_controller_state_set_idle(&padState)
	}

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

	// MARK: - 최소 누름 시간

	/// 버튼을 이보다 짧게 누르면 뗌을 늦춰서 보낸다.
	/// libchiaki는 버튼을 눌림/뗌 이벤트로만 보내서, 아주 짧은 탭은 눌림과 뗌이 PS5의 한 프레임 안에 들어가
	/// 게임이 버튼 상태를 읽을 때 놓친다. 60fps 기준 3프레임.
	static let minimumHold: TimeInterval = 0.05

	private var lastRawButtons: UInt32 = 0
	private var pressStarts: [UInt32: TimeInterval] = [:]
	private var holdRepublish: DispatchWorkItem?
	/// 최소 시간을 채우려고 뗌을 늦춘 횟수 (통계용)
	private var shortTaps = 0

	/// 지난번 호출 이후 짧은 입력을 보정한 횟수
	func takeShortTapCount() -> Int {
		defer { shortTaps = 0 }
		return shortTaps
	}

	private func publish() {
		var state = mergedState()
		state.buttons = applyMinimumHold(state.buttons, now: ProcessInfo.processInfo.systemUptime)
		onChange?(state)
	}

	/// 막 떼졌지만 최소 시간이 안 된 버튼은 눌린 채로 두고, 시간이 차면 다시 보낸다
	func applyMinimumHold(_ raw: UInt32, now: TimeInterval) -> UInt32 {
		for bit in Self.bits(raw & ~lastRawButtons) { pressStarts[bit] = now }
		for bit in Self.bits(lastRawButtons & ~raw) where now - (pressStarts[bit] ?? 0) < Self.minimumHold {
			shortTaps += 1
		}
		lastRawButtons = raw

		var held: UInt32 = 0
		var nextRelease = TimeInterval.infinity
		for (bit, start) in pressStarts where raw & bit == 0 {
			let releaseAt = start + Self.minimumHold
			if now < releaseAt {
				held |= bit
				nextRelease = min(nextRelease, releaseAt)
			} else {
				pressStarts[bit] = nil
			}
		}

		holdRepublish?.cancel()
		holdRepublish = nil
		if held != 0 {
			let work = DispatchWorkItem { [weak self] in self?.publish() }
			holdRepublish = work
			DispatchQueue.main.asyncAfter(deadline: .now() + (nextRelease - now), execute: work)
		}
		return raw | held
	}

	private static func bits(_ mask: UInt32) -> [UInt32] {
		(0..<32).map { UInt32(1) << $0 }.filter { mask & $0 != 0 }
	}

	/// 지금 PS5로 보낼 합쳐진 상태
	func mergedState() -> ChiakiControllerState {
		var keys = keyboardState()
		var out = ChiakiControllerState()
		chiaki_controller_state_or(&out, &padState, &keys)
		for var state in virtualStates.values {
			var merged = ChiakiControllerState()
			chiaki_controller_state_or(&merged, &out, &state)
			out = merged
		}
		out.buttons |= tappedButtons
		return out
	}

	/// 가상 입력 소스의 상태를 바꾼다. nil이면 그 소스를 뺀다.
	func set(_ state: ChiakiControllerState?, for source: VirtualInputSource) {
		virtualStates[source] = state
		publish()
	}

	/// 화면 버튼 등에서 버튼을 잠깐 눌렀다 뗀다
	func tap(_ button: ChiakiControllerButton, duration: TimeInterval = 0.15) {
		tappedButtons |= button.rawValue
		publish()
		DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
			guard let self else { return }
			self.tappedButtons &= ~button.rawValue
			self.publish()
		}
	}

	// MARK: - 게임패드

	/// 실제 패드에서 눌린 버튼 (PS 대체 조합 적용 전)
	private var padButtons: UInt32 = 0

	private func attach(_ newController: GCController?) {
		// 같은 패드가 다시 current가 되는 알림은 무시한다. 상태를 비우면 누르고 있던 버튼이 떼진다.
		guard newController !== controller else { return }
		detachHandlers()
		controller = newController
		chiaki_controller_state_set_idle(&padState)
		padButtons = 0
		touchIDs = [nil, nil]
		publish()

		guard let pad = newController?.extendedGamepad else { return }
		// PS 버튼과 만들기(공유) 버튼을 OS가 가로채지 않고 PS5로 보내게 한다
		// physicalInputProfile 쪽 요소에도 같이 건다 (Apple 문서가 안내하는 경로)
		let profileButtons = newController?.physicalInputProfile.buttons
		for element in [pad.buttonHome, pad.buttonOptions, profileButtons?[GCInputButtonHome], profileButtons?[GCInputButtonShare]] {
			element?.preferredSystemGestureState = .disabled
		}
		let home = profileButtons?[GCInputButtonHome] ?? pad.buttonHome
		Self.log.notice("controller \(newController?.vendorName ?? "?", privacy: .public) (\(newController?.productCategory ?? "?", privacy: .public)): home=\(home != nil, privacy: .public) boundToSystem=\(home?.isBoundToSystemGesture ?? false, privacy: .public) gesture=\(home?.preferredSystemGestureState.rawValue ?? -1, privacy: .public)")

		installHandlers(pad)
		publish()
	}

	private func buttonBindings(_ pad: GCExtendedGamepad) -> [(GCControllerButtonInput?, ChiakiControllerButton)] {
		var bindings: [(GCControllerButtonInput?, ChiakiControllerButton)] = [
			(pad.buttonA, CHIAKI_CONTROLLER_BUTTON_CROSS),
			(pad.buttonB, CHIAKI_CONTROLLER_BUTTON_MOON),
			(pad.buttonX, CHIAKI_CONTROLLER_BUTTON_BOX),
			(pad.buttonY, CHIAKI_CONTROLLER_BUTTON_PYRAMID),
			(pad.dpad.left, CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT),
			(pad.dpad.right, CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT),
			(pad.dpad.up, CHIAKI_CONTROLLER_BUTTON_DPAD_UP),
			(pad.dpad.down, CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN),
			(pad.leftShoulder, CHIAKI_CONTROLLER_BUTTON_L1),
			(pad.rightShoulder, CHIAKI_CONTROLLER_BUTTON_R1),
			(pad.leftThumbstickButton, CHIAKI_CONTROLLER_BUTTON_L3),
			(pad.rightThumbstickButton, CHIAKI_CONTROLLER_BUTTON_R3),
			(pad.buttonMenu, CHIAKI_CONTROLLER_BUTTON_OPTIONS),
			(pad.buttonOptions, CHIAKI_CONTROLLER_BUTTON_SHARE),
			(pad.buttonHome, CHIAKI_CONTROLLER_BUTTON_PS),
		]
		if let dualSense = pad as? GCDualSenseGamepad {
			bindings.append((dualSense.touchpadButton, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD))
		} else if let dualShock = pad as? GCDualShockGamepad {
			bindings.append((dualShock.touchpadButton, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD))
		}
		return bindings
	}

	private func touchpads(_ pad: GCExtendedGamepad) -> [GCControllerDirectionPad] {
		if let dualSense = pad as? GCDualSenseGamepad { return [dualSense.touchpadPrimary, dualSense.touchpadSecondary] }
		if let dualShock = pad as? GCDualShockGamepad { return [dualShock.touchpadPrimary, dualShock.touchpadSecondary] }
		return []
	}

	/// 요소마다 핸들러를 건다. 핸들러가 받는 값(이벤트 시점의 값)으로 상태를 바꾼다.
	/// 패드 전체 핸들러에서 현재 값을 다시 읽으면, 메인 스레드가 늦게 처리할 때 짧게 누른 버튼이
	/// 눌림·뗌 두 이벤트 모두 '떼짐'으로 읽혀서 입력이 사라진다.
	private func installHandlers(_ pad: GCExtendedGamepad) {
		for (input, button) in buttonBindings(pad) {
			if input?.isPressed == true { padButtons |= button.rawValue }
			input?.pressedChangedHandler = { [weak self] _, _, pressed in
				self?.setPadButton(button, pressed)
			}
		}
		applyPadButtons()

		padState.l2_state = UInt8(pad.leftTrigger.value * 255)
		padState.r2_state = UInt8(pad.rightTrigger.value * 255)
		pad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
			self?.padState.l2_state = UInt8(value * 255)
			self?.publish()
		}
		pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
			self?.padState.r2_state = UInt8(value * 255)
			self?.publish()
		}

		// GameController는 위가 +, PS 입력은 아래가 +
		setStick(left: true, pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
		setStick(left: false, pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
		pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
			self?.setStick(left: true, x, y)
			self?.publish()
		}
		pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
			self?.setStick(left: false, x, y)
			self?.publish()
		}

		for (slot, touchpad) in touchpads(pad).enumerated() {
			touchpad.valueChangedHandler = { [weak self] _, x, y in
				self?.updateTouch(slot, x, y)
				self?.publish()
			}
		}
	}

	private func detachHandlers() {
		guard let pad = controller?.extendedGamepad else { return }
		for (input, _) in buttonBindings(pad) { input?.pressedChangedHandler = nil }
		pad.leftTrigger.valueChangedHandler = nil
		pad.rightTrigger.valueChangedHandler = nil
		pad.leftThumbstick.valueChangedHandler = nil
		pad.rightThumbstick.valueChangedHandler = nil
		for touchpad in touchpads(pad) { touchpad.valueChangedHandler = nil }
	}

	private func setPadButton(_ button: ChiakiControllerButton, _ pressed: Bool) {
		if pressed { padButtons |= button.rawValue } else { padButtons &= ~button.rawValue }
		if button == CHIAKI_CONTROLLER_BUTTON_PS, pressed != homePressed {
			homePressed = pressed
			Self.log.notice("PS button \(pressed ? "down" : "up", privacy: .public)")
		}
		applyPadButtons()
		publish()
	}

	/// macOS 26은 PS(홈) 버튼을 앱보다 먼저 가져가 게임 센터를 띄운다.
	/// 대신 터치패드 + OPTIONS를 같이 누르면 PS 버튼으로 보낸다.
	private func applyPadButtons() {
		let psCombo = CHIAKI_CONTROLLER_BUTTON_TOUCHPAD.rawValue | CHIAKI_CONTROLLER_BUTTON_OPTIONS.rawValue
		padState.buttons = padButtons & psCombo == psCombo
			? padButtons & ~psCombo | CHIAKI_CONTROLLER_BUTTON_PS.rawValue
			: padButtons
	}

	private func setStick(left: Bool, _ x: Float, _ y: Float) {
		if left {
			padState.left_x = Self.axis(x)
			padState.left_y = Self.axis(-y)
		} else {
			padState.right_x = Self.axis(x)
			padState.right_y = Self.axis(-y)
		}
	}

	/// 터치패드 손가락 하나. 손을 떼면 좌표가 (0, 0)으로 돌아온다.
	private func updateTouch(_ slot: Int, _ x: Float, _ y: Float) {
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
