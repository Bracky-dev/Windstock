import SwiftUI
import UIKit

/// The launcher owns a normal UIWindowScene.
///
/// The guest does not know what a scene is -- it is a 2016 UIKit app that makes
/// a bare UIWindow and calls makeKeyAndVisible. A window with no windowScene
/// never appears on modern iOS, so WSGuestLoader adopts the guest's window onto
/// this scene during the handover. `current` is how it finds the scene.
@objc(WSSceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// The live window scene, read by the container during the handover.
    @objc static weak var currentScene: UIWindowScene?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        SceneDelegate.currentScene = windowScene

        let model = AppDelegate.sharedModel
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: RootView().environmentObject(model))
        window.makeKeyAndVisible()
        self.window = window

        // After the first frame, so the countdown the user sees is a countdown
        // and not a frozen splash.
        DispatchQueue.main.async {
            model.start()
        }
    }
}
