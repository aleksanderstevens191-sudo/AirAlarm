import SwiftUI
import UserNotifications

@main
struct AirAlarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var alarm = AlarmManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(alarm)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let stop = UNNotificationAction(identifier: AlarmIDs.stopAction, title: "Stop", options: [])
        let snooze = UNNotificationAction(identifier: AlarmIDs.snoozeAction, title: "Snooze 5 min", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: AlarmIDs.notificationCategory,
                                   actions: [stop, snooze],
                                   intentIdentifiers: []),
        ])

        // Create the alarm early so a previously-on alarm is re-armed at launch.
        _ = AlarmManager.shared
        return true
    }

    // Show the (silent) banner even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    // Stop / Snooze buttons on the lock-screen notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case AlarmIDs.stopAction:
                AlarmManager.shared.stopAlarm()
            case AlarmIDs.snoozeAction:
                AlarmManager.shared.snooze()
            default:
                break
            }
        }
    }
}
