// CoffeeCup — a menu bar keep-awake utility, inspired by KeepingYouAwake.
//
// Why this exists: KeepingYouAwake delegates to a child `/usr/bin/caffeinate`
// process. If that child dies or its assertion is dropped by powerd, the app
// keeps showing "active" while the Mac is free to sleep. CoffeeCup instead:
//
//   1. Holds IOPMAssertions in-process (display + system idle sleep).
//   2. Runs a watchdog that asks powerd which assertions this PID actually
//      owns, and re-creates anything that has gone missing.
//   3. Periodically declares user activity, which resets the idle timer the
//      same way real input does (defeats screensaver/lock timers too).
//   4. Re-asserts after wake, screen wake, session switches and display changes.
//   5. Opts out of App Nap so the watchdog timer is never throttled.

import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

// MARK: - Logging

final class Log {
    static let shared = Log()
    private let url: URL
    private let queue = DispatchQueue(label: "CoffeeCup.log")
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoffeeCup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("CoffeeCup.log")
        // Keep the log small: truncate when over 1 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    var fileURL: URL { url }

    func write(_ message: String) {
        let line = "\(fmt.string(from: Date())) \(message)\n"
        queue.async { [url] in
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    // One identifier, so each new status replaces the last instead of piling up.
    private let identifier = "CoffeeCup.status"

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "showNotifications") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "showNotifications")
            if newValue { requestAuthorization() }
        }
    }

    func setUp() {
        center.delegate = self
        if enabled { requestAuthorization() }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                Log.shared.write("Notification authorization error: \(error.localizedDescription)")
            } else if !granted {
                Log.shared.write("Notifications not allowed (System Settings → Notifications → CoffeeCup)")
            }
        }
    }

    func post(_ title: String, _ body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { Log.shared.write("Notification error: \(error.localizedDescription)") }
        }
    }

    // Show banners even when CoffeeCup counts as the active app (e.g. right after a menu click).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

// MARK: - Power assertions

final class AwakeEngine {
    private(set) var isActive = false
    private(set) var expiresAt: Date?
    private(set) var lastVerified: Date?
    private(set) var repairCount = 0

    var allowDisplaySleep = UserDefaults.standard.bool(forKey: "allowDisplaySleep") {
        didSet {
            UserDefaults.standard.set(allowDisplaySleep, forKey: "allowDisplaySleep")
            if isActive {
                endProcessActivity()
                beginProcessActivity()
                rebuildAssertions(reason: "display preference changed")
            }
        }
    }

    var onChange: (() -> Void)?
    var onExpire: (() -> Void)?

    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0
    private var processActivity: NSObjectProtocol?
    private var watchdog: Timer?
    private var expiryTimer: Timer?

    private let displayName = "CoffeeCup: prevent display sleep"
    private let systemName = "CoffeeCup: prevent system sleep"
    private let activityName = "CoffeeCup: user activity"

    private let watchdogInterval: TimeInterval = 20
    private let pid = ProcessInfo.processInfo.processIdentifier

    // MARK: Public

    func activate(for duration: TimeInterval?) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let duration {
            expiresAt = Date().addingTimeInterval(duration)
            let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                self?.expire()
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            expiryTimer = t
        } else {
            expiresAt = nil
        }

        isActive = true
        rebuildAssertions(reason: "activated (\(duration.map { "\(Int($0))s" } ?? "indefinite"))")

        beginProcessActivity()
        startWatchdog()
        onChange?()
    }

    func deactivate() {
        isActive = false
        expiresAt = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        releaseAll()
        endProcessActivity()
        Log.shared.write("Deactivated")
        onChange?()
    }

    private func expire() {
        guard isActive else { return }
        Log.shared.write("Timer expired")
        deactivate()
        onExpire?()
    }

    // Opting out of App Nap keeps our timers firing on schedule; these
    // options also create their own idle-sleep assertions as a backup.
    private func beginProcessActivity() {
        guard processActivity == nil else { return }
        var opts: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if !allowDisplaySleep { opts.insert(.idleDisplaySleepDisabled) }
        processActivity = ProcessInfo.processInfo.beginActivity(
            options: opts, reason: "CoffeeCup is keeping the Mac awake")
    }

    private func endProcessActivity() {
        if let a = processActivity {
            ProcessInfo.processInfo.endActivity(a)
            processActivity = nil
        }
    }

    /// Called on wake / session / display events: drop and re-create everything.
    func reassert(reason: String) {
        guard isActive else { return }
        if let expiresAt, expiresAt <= Date() {
            expire()
            return
        }
        rebuildAssertions(reason: reason)
        // Restart the watchdog: a timer may have been stalled across sleep.
        startWatchdog()
    }

    // MARK: Assertions

    private func rebuildAssertions(reason: String) {
        releaseAll()
        if !allowDisplaySleep {
            displayAssertion = create(kIOPMAssertPreventUserIdleDisplaySleep, displayName)
        }
        systemAssertion = create(kIOPMAssertPreventUserIdleSystemSleep, systemName)
        declareUserActivity()
        lastVerified = Date()
        Log.shared.write("Assertions created: \(reason)")
        onChange?()
    }

    private func create(_ type: String, _ name: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(type as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            name as CFString, &id)
        if r != kIOReturnSuccess {
            Log.shared.write("ERROR creating \(type): 0x\(String(r, radix: 16))")
            return 0
        }
        return id
    }

    private func declareUserActivity() {
        // Re-using the same ID refreshes the existing declaration.
        let r = IOPMAssertionDeclareUserActivity(activityName as CFString,
                                                 kIOPMUserActiveLocal, &activityAssertion)
        if r != kIOReturnSuccess {
            Log.shared.write("ERROR declaring user activity: 0x\(String(r, radix: 16))")
        }
    }

    private func releaseAll() {
        for id in [displayAssertion, systemAssertion, activityAssertion] where id != 0 {
            IOPMAssertionRelease(id)
        }
        displayAssertion = 0
        systemAssertion = 0
        activityAssertion = 0
    }

    // MARK: Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.verify()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    /// Asks powerd which assertions this process really owns. If any of ours
    /// are missing (released, timed out, or powerd restarted), rebuild them.
    private func verify() {
        guard isActive else { return }
        if let expiresAt, expiresAt <= Date() {
            expire()
            return
        }

        let owned = ownedAssertionNames()
        var missing: [String] = []
        if !allowDisplaySleep && !owned.contains(displayName) { missing.append("display") }
        if !owned.contains(systemName) { missing.append("system") }

        if missing.isEmpty {
            declareUserActivity()
            lastVerified = Date()
            onChange?()
        } else {
            repairCount += 1
            Log.shared.write("Watchdog: missing \(missing.joined(separator: ", ")) — repairing (#\(repairCount))")
            rebuildAssertions(reason: "watchdog repair")
        }
    }

    private func ownedAssertionNames() -> Set<String> {
        var dictRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictRef) == kIOReturnSuccess,
              let dict = dictRef?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            // If we can't query, assume the worst and let the caller repair.
            return []
        }
        let mine = dict.first { $0.key.int32Value == pid }?.value ?? []
        return Set(mine.compactMap { $0[kIOPMAssertionNameKey as String] as? String })
    }
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = AwakeEngine()
    private var statusItem: NSStatusItem!

    private let durations: [(String, TimeInterval?)] = [
        ("Indefinitely", nil),
        ("15 Minutes", 15 * 60),
        ("30 Minutes", 30 * 60),
        ("1 Hour", 3600),
        ("2 Hours", 2 * 3600),
        ("4 Hours", 4 * 3600),
        ("8 Hours", 8 * 3600),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        engine.onChange = { [weak self] in self?.refreshIcon() }
        engine.onExpire = {
            Notifier.shared.post("CoffeeCup timer ended", "Your Mac can sleep normally again.")
        }
        Notifier.shared.setUp()
        observeSystemEvents()

        Log.shared.write("Launched, pid \(ProcessInfo.processInfo.processIdentifier), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        if UserDefaults.standard.object(forKey: "activateOnLaunch") as? Bool ?? true {
            engine.activate(for: nil)
        }
        refreshIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.deactivate()
    }

    // MARK: Events

    private func observeSystemEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.didWakeNotification, "system wake"),
            (NSWorkspace.screensDidWakeNotification, "screens wake"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session active"),
        ]
        for (name, label) in events {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Log.shared.write("Event: \(label)")
                // Small delay: powerd is still settling immediately after wake.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.engine.reassert(reason: label)
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.engine.reassert(reason: "display configuration changed")
        }
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            showMenu()
        } else {
            toggle()
        }
    }

    // Launch-time activation and quitting stay silent; only user actions notify.
    private func activate(for duration: TimeInterval?, label: String) {
        engine.activate(for: duration)
        if let duration {
            let f = DateFormatter()
            f.timeStyle = .short
            let until = f.string(from: Date().addingTimeInterval(duration))
            Notifier.shared.post("CoffeeCup is on", "Your Mac will stay awake for \(label.lowercased()) (until \(until)).")
        } else {
            Notifier.shared.post("CoffeeCup is on", "Your Mac will stay awake until you turn it off.")
        }
    }

    private func deactivate() {
        engine.deactivate()
        Notifier.shared.post("CoffeeCup is off", "Your Mac can sleep normally again.")
    }

    private func showMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let name = engine.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: engine.isActive ? "Awake" : "Idle")
        img?.isTemplate = true
        button.image = img
        button.toolTip = statusLine()
    }

    private func statusLine() -> String {
        guard engine.isActive else { return "CoffeeCup: inactive" }
        var s = "Keeping awake"
        if let e = engine.expiresAt {
            let mins = max(0, Int(e.timeIntervalSinceNow / 60))
            s += mins >= 60 ? " — \(mins / 60)h \(mins % 60)m left" : " — \(mins)m left"
        } else {
            s += " — indefinitely"
        }
        return s
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if engine.isActive, let v = engine.lastVerified {
            let f = DateFormatter()
            f.timeStyle = .medium
            var detail = "Verified with powerd at \(f.string(from: v))"
            if engine.repairCount > 0 { detail += " · \(engine.repairCount) repair(s)" }
            let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: engine.isActive ? "Deactivate" : "Activate",
                                action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let durationItem = NSMenuItem(title: "Activate for Duration", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, (title, _)) in durations.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(activateDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            sub.addItem(item)
        }
        durationItem.submenu = sub
        menu.addItem(durationItem)

        menu.addItem(.separator())

        let displaySleep = NSMenuItem(title: "Allow Display Sleep",
                                      action: #selector(toggleDisplaySleep), keyEquivalent: "")
        displaySleep.target = self
        displaySleep.state = engine.allowDisplaySleep ? .on : .off
        menu.addItem(displaySleep)

        let notify = NSMenuItem(title: "Show Notifications",
                                action: #selector(toggleNotifications), keyEquivalent: "")
        notify.target = self
        notify.state = Notifier.shared.enabled ? .on : .off
        menu.addItem(notify)

        let onLaunch = NSMenuItem(title: "Activate on Launch",
                                  action: #selector(toggleActivateOnLaunch), keyEquivalent: "")
        onLaunch.target = self
        onLaunch.state = (UserDefaults.standard.object(forKey: "activateOnLaunch") as? Bool ?? true) ? .on : .off
        menu.addItem(onLaunch)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let logItem = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let quit = NSMenuItem(title: "Quit CoffeeCup", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggle() {
        engine.isActive ? deactivate() : activate(for: nil, label: "Indefinitely")
    }

    @objc private func activateDuration(_ sender: NSMenuItem) {
        let (label, duration) = durations[sender.tag]
        activate(for: duration, label: label)
    }

    @objc private func toggleNotifications() {
        Notifier.shared.enabled.toggle()
    }

    @objc private func toggleDisplaySleep() {
        engine.allowDisplaySleep.toggle()
    }

    @objc private func toggleActivateOnLaunch() {
        let current = UserDefaults.standard.object(forKey: "activateOnLaunch") as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: "activateOnLaunch")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.shared.write("Login item error: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change login item"
            alert.informativeText = "\(error.localizedDescription)\n\nMake sure CoffeeCup.app is in /Applications."
            alert.runModal()
        }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(Log.shared.fileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
