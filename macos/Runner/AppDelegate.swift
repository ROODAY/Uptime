import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Set ourselves as the notification center delegate
    if #available(macOS 10.14, *) {
      let center = UNUserNotificationCenter.current()
      center.delegate = self

      // Request notification permissions - alert, sound, badge
      let options: UNAuthorizationOptions = [.alert, .sound, .badge]

      center.requestAuthorization(options: options) { granted, error in
        if let error = error {
          print("[AppDelegate] Notification permission error: \(error)")
        }
        print("[AppDelegate] Notification permission granted: \(granted)")

        // Check current settings
        center.getNotificationSettings { settings in
          print("[AppDelegate] Notification settings: \(settings.authorizationStatus.rawValue)")
        }
      }
    }
  }

  // Handle notifications when app is in foreground
  @available(macOS 10.14, *)
  func userNotificationCenter(_ center: UNUserNotificationCenter,
                              willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }
}
