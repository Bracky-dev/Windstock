import SwiftUI
import UIKit

/// UIKit delegate, not a SwiftUI `App`.
///
/// The launcher has to be a plain UIKit app because it ends up handing its own
/// process to the guest: UnityAppController wants to *be* the application
/// delegate and to own the window. The window itself is built in
/// SceneDelegate -- the iOS 27 SDK refuses to launch an app that has not
/// adopted scenes.
@objc(WSAppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// One model shared with whatever scene connects.
    static let sharedModel = LauncherModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        WSLog("launcher", "Windstock Launcher starting"
              + (WSContainerIsSafeMode() ? " (SAFE MODE: container redirect off)" : ""))
        let container = WSContainerCurrentHome().map { String(cString: $0) } ?? "not redirected"
        WSLog("launcher", "container: \(container)")

        UNUserNotificationCenterShim.install()
        return true
    }
}

/// Foreground notification presentation. Small enough not to deserve its own
/// file, but it has to exist or nothing shows while the launcher is open.
import UserNotifications

final class UNUserNotificationCenterShim: NSObject, UNUserNotificationCenterDelegate {
    private static let shared = UNUserNotificationCenterShim()

    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
