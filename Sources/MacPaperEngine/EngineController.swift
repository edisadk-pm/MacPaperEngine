import AppKit
import MacPaperCore

final class EngineDelegate: NSObject, NSApplicationDelegate {
    private let controller = EngineController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.prepare()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

/// Owns one desktop window per display and decides what each one plays.
final class EngineController: NSObject {
    private var state = Store.loadState()
    private var stats = Store.loadStats()
    private var hosts: [String: DesktopHost] = [:]
    private let power = PowerMonitor()
    private lazy var menu = StatusMenu(controller: self)

    private var userPaused = false
    private var tickTimer: Timer?
    private var coverageTimer: Timer?
    private lazy var lockScreen = LockScreenSync { [weak self] in self?.lockScreenChanged() }
    private var lastTick = CACurrentMediaTime()
    private var lastStatsSave = CACurrentMediaTime()
    private var statsDirty = false
    private var lastStatus: EngineStatus?

    func start() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(settingsChanged),
                                name: IPC.settingsChanged, object: nil,
                                suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(statusRequested),
                                name: IPC.statusRequested, object: nil,
                                suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(quitRequested),
                                name: IPC.quitEngine, object: nil,
                                suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(pauseToggleRequested),
                                name: IPC.togglePause, object: nil,
                                suspensionBehavior: .deliverImmediately)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Covered-desktop checks run immediately on these, and on the slow tick otherwise.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(desktopMayHaveChanged),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(desktopMayHaveChanged),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        power.onChange = { [weak self] in self?.powerChanged() }

        reconcile()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func shutdown() {
        flushStats()
        hosts.values.forEach { $0.close() }
        hosts.removeAll()
    }

    // MARK: - Reconciling windows with settings

    @objc private func settingsChanged() {
        state = Store.loadState()
        reconcile()
    }

    @objc private func screensChanged() {
        reconcile()
    }

    @objc private func statusRequested() {
        lastStatus = nil
        evaluatePause()
    }

    @objc private func pauseToggleRequested() {
        togglePausedByUser()
        menu.update(status: lastStatus ?? EngineStatus(state: .idle, detail: ""))
    }

    @objc private func quitRequested() {
        NSApp.terminate(nil)
    }

    @objc private func desktopMayHaveChanged() {
        evaluatePause()
    }

    private func powerChanged() {
        evaluatePause()
        // A decoder can die across sleep. Check as soon as the machine is back.
        hosts.values.forEach { $0.recoverIfNeeded() }
    }

    private func reconcile() {
        menu.setVisible(state.settings.showMenuBarIcon)

        var active = Set<String>()
        if state.settings.enabled {
            for screen in NSScreen.screens {
                let uuid = screen.displayUUID
                guard let wallpaper = state.wallpaper(forDisplay: uuid),
                      isAvailable(wallpaper) else { continue }
                active.insert(uuid)
                let host = hosts[uuid] ?? DesktopHost()
                hosts[uuid] = host
                host.update(screen: screen, wallpaper: wallpaper, settings: state.settings)
            }
        }

        for (uuid, host) in hosts where !active.contains(uuid) {
            host.close()
            hosts[uuid] = nil
        }

        evaluatePause()
        releaseFreedMemorySoon()
        lockScreen.update(state: state, mainDisplay: NSScreen.screens.first?.displayUUID)
    }

    private func lockScreenChanged() {
        lastStatus = nil
        evaluatePause()
    }

    private func isAvailable(_ wallpaper: Wallpaper) -> Bool {
        wallpaper.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private func releaseFreedMemorySoon() {
        // Hands pages freed by a torn-down player back to the OS instead of keeping them in malloc.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    // MARK: - Pausing

    func togglePausedByUser() {
        userPaused.toggle()
        evaluatePause()
    }

    var isPausedByUser: Bool { userPaused }

    private func evaluatePause() {
        let settings = state.settings
        let globalReason = userPaused ? "Paused by you" : power.pauseReason(for: settings)

        // Pictures cost nothing while shown, so only moving wallpapers are paused or watched.
        let animated = hosts.values.filter(\.isAnimated)

        var covered = Set<CGDirectDisplayID>()
        if !animated.isEmpty, globalReason == nil, settings.pauseWhenCovered {
            covered = DesktopCoverage.coveredDisplays(in: NSScreen.screens)
        }

        var anyPlaying = false
        for host in animated {
            let paused = globalReason != nil || covered.contains(host.displayID)
            host.setPaused(paused)
            anyPlaying = anyPlaying || !paused
        }

        updateCoveragePolling(needed: animated.contains { covered.contains($0.displayID) })

        let status: EngineStatus
        if !settings.enabled {
            status = EngineStatus(state: .off, detail: "Wallpaper is off")
        } else if hosts.isEmpty {
            status = EngineStatus(state: .idle, detail: "No wallpaper selected")
        } else if animated.isEmpty {
            status = EngineStatus(state: .still, detail: "Showing")
        } else if anyPlaying {
            status = EngineStatus(state: .playing, detail: "Playing")
        } else {
            status = EngineStatus(state: .paused, detail: globalReason ?? "Desktop is covered", pausedByUser: userPaused)
        }

        if status != lastStatus {
            lastStatus = status
            menu.update(status: status)
            IPC.post(IPC.statusChanged, object: IPC.encode(status))
        }
    }

    /// Nothing announces a window being moved or minimized, so while the desktop is hidden this
    /// checks often enough that the wallpaper is already moving when it comes back into view.
    private func updateCoveragePolling(needed: Bool) {
        if needed, coverageTimer == nil {
            let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.evaluatePause() }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            coverageTimer = timer
        } else if !needed {
            coverageTimer?.invalidate()
            coverageTimer = nil
        }
    }

    // MARK: - Tick

    private func tick() {
        lockScreen.repairIfNeeded()

        let now = CACurrentMediaTime()
        // Clamped so that time spent asleep is not counted as played.
        let elapsed = min(now - lastTick, 5)
        lastTick = now

        guard !hosts.isEmpty else { return }
        evaluatePause()

        for host in hosts.values {
            host.recoverIfNeeded()
            guard host.isAnimated, let id = host.wallpaperID else { continue }
            if host.isPaused {
                stats.pausedSeconds += elapsed
            } else {
                stats.playSeconds[id, default: 0] += elapsed
            }
            statsDirty = true
        }

        if now - lastStatsSave > 60 { flushStats() }
    }

    private func flushStats() {
        lastStatsSave = CACurrentMediaTime()
        guard statsDirty else { return }
        statsDirty = false
        Store.save(stats)
    }
}
