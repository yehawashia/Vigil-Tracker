import SwiftUI
import VigilMobile

@main
struct VigilMobileApp: App {
    @StateObject private var state = DeviceState(services: IOSServices.shared)

    var body: some Scene {
        WindowGroup {
            VigilRootView(state: state) { onCode in AnyView(QRScannerSheet(onCode: onCode)) }
        }
    }
}
