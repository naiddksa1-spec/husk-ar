// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Which way the app may turn. The app follows the device, except while a landscape game is on screen:
/// Geometry Dash is a landscape game, and a fixed-size surface cannot follow a rotation.
enum HuskOrientation {
    static var standard: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : [.portrait, .landscapeLeft, .landscapeRight]
    }
    static var mask: UIInterfaceOrientationMask = standard

    /// Allow only `new`, and turn the screen to it if it is not already there.
    ///
    /// A game's screen asks as it appears, while its full-screen cover is still being presented, and iOS can refuse then
    /// ("Supported: portrait") because it has not yet asked the cover what it allows. So a refusal is retried a few times,
    /// a moment apart, for as long as `new` is still what is wanted.
    @MainActor static func set(_ new: UIInterfaceOrientationMask, attempt: Int = 0) {
        mask = new
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            var vc = scene.keyWindow?.rootViewController
            while let v = vc { v.setNeedsUpdateOfSupportedInterfaceOrientations(); vc = v.presentedViewController }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { error in
                HuskLog.log("ui", "orientation change refused (attempt \(attempt + 1)): \(error.localizedDescription)")
                guard attempt < 5 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if mask == new { set(new, attempt: attempt + 1) }
                }
            }
        }
    }
}

final class HuskAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        HuskOrientation.mask
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The download session reconnects to whatever was running before Husk was closed or relaunched in the background.
        _ = Downloads.shared
        return true
    }

    /// iOS woke Husk because background downloads finished or need attention: handle them, then say so.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.sessionID else { completionHandler(); return }
        HuskLog.log("downloads", "woken for background download events")
        Downloads.shared.backgroundCompletion = completionHandler
    }
}

@main
struct HuskApp: App {
    @UIApplicationDelegateAdaptor(HuskAppDelegate.self) private var appDelegate

    init() {
        // CRITICAL ORDER (P0 crash fix):
        // 1. Logging first so every subsequent line is captured.
        // 2. Trap guard IMMEDIATELY after logging — before any code that could
        //    issue a brk or touch executable-memory paths. An unserviced brk
        //    without the guard is a fatal SIGTRAP (instant crash, no log).
        // 3. Only then note launch state / UserDefaults / file cleanup.
        //
        // Previous order could reach UserDefaults or IncomingFiles before the
        // handler was installed on some TrollStore / Dopamine / LiveContainer
        // paths, producing the "crashes on launch with no logs" reports.

        HuskLog.start()
        HuskLog.logFootprint("app-launch")

        // Trap guard must be live before anything that might probe JIT.
        JITBootstrap.installTrapGuard()

        // Snapshot whether we were already marked debugged at process start
        // (jailbreak "Allow JIT in Apps", TrollStore residual, etc.).
        JITBootstrap.noteLaunchState()
        HuskLog.log("jit",
            "debugged at launch: \(JITBootstrap.debuggedAtLaunch); "
          + "TrollStore install: \(JITBootstrap.isInstalledWithTrollStore); "
          + "jailbreak: \(JITBootstrap.isJailbroken); "
          + "can grant its own JIT: \(JITBootstrap.canGrantOwnJIT); "
          + "device TXM: \(JITBootstrap.deviceEnforcesTXM)")

        // Safe one-time defaults migration. Never fatal.
        do {
            let d = UserDefaults.standard
            if !d.bool(forKey: "husk.autoStart.offByDefault") {
                d.set(false, forKey: "husk.autoStart")
                d.set(true, forKey: "husk.autoStart.offByDefault")
            }
        }

        // Leftover shared-APK copies. Best-effort only — never crash launch.
        IncomingFiles.clearLeftovers()

        // Game controllers for the native runtime. Async, non-blocking.
        Task { @MainActor in
            HuskGamepads.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // An APK shared to Husk, or opened in it from Files.
                .onOpenURL { IncomingFiles.shared.receive($0) }
        }
    }
}
