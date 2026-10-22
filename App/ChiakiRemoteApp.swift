import ChiakiCore
import SwiftUI

@main
struct ChiakiRemoteApp: App {
	@State private var store = HostStore()

	init() {
		let err = chiaki_lib_init()
		precondition(err == CHIAKI_ERR_SUCCESS, "chiaki_lib_init 실패: \(String(cString: chiaki_error_string(err)))")
	}

	var body: some Scene {
		WindowGroup {
			HostListView()
				.environment(store)
		}
	}
}
