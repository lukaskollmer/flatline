import AppKit
import Utilities

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print(formatGreeting(for: "world"))
        _ = Settings.load()
    }

    func unusedDelegateHelper() {} // expect: unused
}

/// Only referenced from Info.plist (NSPrincipalClass).
final class CustomApplication: NSApplication {}

/// Only referenced from a xib (customClass).
final class XibView: NSView {}

final class UnusedController: NSViewController {} // expect: unused
