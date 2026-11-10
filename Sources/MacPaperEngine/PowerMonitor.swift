import AppKit
import IOKit.ps
import MacPaperCore

/// Tracks every machine-wide reason to stop animating. Entirely notification-driven.
final class PowerMonitor {
    var onChange: (() -> Void)?

    private var screensAsleep = false
    private var systemAsleep = false
    private var sessionInactive = false
    private var locked = false
    private var onBattery = false
    private var runLoopSource: CFRunLoopSource?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }

        observe(.default, .NSProcessInfoPowerStateDidChange) { _ in }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { _ in }

        watchPowerSource()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ change: @escaping (PowerMonitor) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            change(self)
            self.onChange?()
        }
    }

    private func watchPowerSource() {
        refreshPowerSource()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.refreshPowerSource()
            monitor.onChange?()
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    private func refreshPowerSource() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return }
        onBattery = (type as String) == kIOPSBatteryPowerValue
    }

    func pauseReason(for settings: WallpaperSettings) -> String? {
        if systemAsleep || screensAsleep { return "Display is asleep" }
        if locked || sessionInactive { return "Screen is locked" }
        if settings.pauseInLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return "Low Power Mode" }
        if settings.pauseOnBattery, onBattery { return "On battery power" }
        if settings.pauseWhenHot {
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical { return "Mac is running hot" }
        }
        return nil
    }
}

enum DesktopCoverage {
    private static let columns = 14
    private static let rows = 9

    /// Displays whose usable area is entirely hidden behind ordinary windows. Handles full-screen
    /// apps, zoomed windows and tiled layouts alike. Only window bounds are read, which needs no
    /// Screen Recording permission.
    static func coveredDisplays(in screens: [NSScreen]) -> Set<CGDirectDisplayID> {
        autoreleasepool {
            guard let primary = NSScreen.screens.first,
                  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else {
                return []
            }

            let ownPID = ProcessInfo.processInfo.processIdentifier
            var windows: [CGRect] = []
            for info in list {
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                      ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.9,
                      let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dictionary) else { continue }
                windows.append(rect)
            }
            guard !windows.isEmpty else { return [] }

            var covered = Set<CGDirectDisplayID>()
            for screen in screens {
                // The usable area excludes the menu bar and Dock, which stay translucent.
                let visible = screen.visibleFrame
                let area = CGRect(x: visible.minX,
                                  y: primary.frame.maxY - visible.maxY,
                                  width: visible.width,
                                  height: visible.height)
                if isCovered(area, by: windows) { covered.insert(screen.displayID) }
            }
            return covered
        }
    }

    private static func isCovered(_ area: CGRect, by windows: [CGRect]) -> Bool {
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: area.minX + area.width * (CGFloat(column) + 0.5) / CGFloat(columns),
                                    y: area.minY + area.height * (CGFloat(row) + 0.5) / CGFloat(rows))
                if !windows.contains(where: { $0.contains(point) }) { return false }
            }
        }
        return true
    }
}
