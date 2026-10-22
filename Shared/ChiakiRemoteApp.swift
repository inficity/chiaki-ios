import ChiakiCore
import SwiftUI

@main
struct ChiakiRemoteApp: App {
	@State private var store = HostStore()
	@State private var settings = AppSettings()

	init() {
		let err = chiaki_lib_init()
		precondition(err == CHIAKI_ERR_SUCCESS, "chiaki_lib_init 실패: \(String(cString: chiaki_error_string(err)))")
#if DEBUG
		if CommandLine.arguments.contains("-cloudSelfTest") { CloudSelfTest.run() }
#endif
	}

	var body: some Scene {
		WindowGroup {
			HostListView()
				.environment(store)
				.environment(settings)
		}
#if os(macOS)
		.defaultSize(width: 1280, height: 760)
#endif
	}
}
