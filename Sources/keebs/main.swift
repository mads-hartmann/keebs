import AppKit
import CoreGraphics
import Darwin
import Foundation

private let capsLockToControlHIDMapping = """
{"UserKeyMapping":[{
  "HIDKeyboardModifierMappingSrc":0x700000039,
  "HIDKeyboardModifierMappingDst":0x7000000e0
}]}
"""

@discardableResult
private func setHIDMapping(_ mapping: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    process.arguments = ["property", "--set", mapping]
    process.standardOutput = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func currentHIDMapping() -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    process.arguments = ["property", "--get", "UserKeyMapping"]
    process.standardOutput = output

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    } catch {
        return nil
    }
}

private func HIDMappingIsEmpty(_ output: String) -> Bool {
    let compact = output.filter { !$0.isWhitespace }
    return compact == "()" || compact == "(null)"
}

private func clearHIDMapping() {
    setHIDMapping("{\"UserKeyMapping\":[]}")
}

private func runHIDWatchdog(parentPID: pid_t) -> Never {
    signal(SIGHUP, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    while kill(parentPID, 0) == 0 || errno == EPERM {
        Thread.sleep(forTimeInterval: 0.25)
    }

    clearHIDMapping()
    exit(0)
}

private enum KeyCode {
    static let a: CGKeyCode = 0
    static let s: CGKeyCode = 1
    static let space: CGKeyCode = 49
    static let c: CGKeyCode = 8
    static let e: CGKeyCode = 14
    static let g: CGKeyCode = 5
    static let i: CGKeyCode = 34
    static let k: CGKeyCode = 40
    static let n: CGKeyCode = 45
    static let p: CGKeyCode = 35
    static let b: CGKeyCode = 11
    static let d: CGKeyCode = 2
    static let f: CGKeyCode = 3
    static let h: CGKeyCode = 4
    static let j: CGKeyCode = 38
    static let l: CGKeyCode = 37
    static let r: CGKeyCode = 15
    static let t: CGKeyCode = 17
    static let v: CGKeyCode = 9
    static let w: CGKeyCode = 13
    static let x: CGKeyCode = 7

    static let escape: CGKeyCode = 53
    static let rightCommand: CGKeyCode = 54
    static let deleteOrBackspace: CGKeyCode = 51
    static let deleteForward: CGKeyCode = 117

    static let home: CGKeyCode = 115
    static let pageUp: CGKeyCode = 116
    static let end: CGKeyCode = 119
    static let pageDown: CGKeyCode = 121
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    static let downArrow: CGKeyCode = 125
    static let upArrow: CGKeyCode = 126

    static let navigation: Set<CGKeyCode> = [
        home,
        pageUp,
        end,
        pageDown,
        leftArrow,
        rightArrow,
        downArrow,
        upArrow
    ]
}

private struct KeyChord {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
}

private struct KeyMapping {
    let from: KeyChord
    let to: KeyChord
    let allowsOtherModifiers: Bool

    init(
        _ fromKeyCode: CGKeyCode,
        _ fromModifiers: CGEventFlags = [],
        to toKeyCode: CGKeyCode,
        _ toModifiers: CGEventFlags = [],
        allowsOtherModifiers: Bool = false
    ) {
        from = KeyChord(keyCode: fromKeyCode, modifiers: fromModifiers)
        to = KeyChord(keyCode: toKeyCode, modifiers: toModifiers)
        self.allowsOtherModifiers = allowsOtherModifiers
    }

    func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard keyCode == from.keyCode else {
            return false
        }

        let modifiers = flags.intersection(.keyMappingModifiers)
        return allowsOtherModifiers
            ? modifiers.contains(from.modifiers)
            : modifiers == from.modifiers
    }

    func apply(to event: CGEvent) {
        let preservedModifiers = event.flags.subtracting(from.modifiers)
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(to.keyCode))
        event.flags = preservedModifiers.union(to.modifiers)
    }
}

// These chord mappings replace the remaining basic rules in ~/.config/karabiner.
// They deliberately run before mark mode (Shift Lock) in the event pipeline.
private let keyMappings: [KeyMapping] = [
    KeyMapping(KeyCode.h, [.maskCommand, .maskControl], to: KeyCode.leftArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.j, [.maskCommand, .maskControl], to: KeyCode.downArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.k, [.maskCommand, .maskControl], to: KeyCode.upArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.l, [.maskCommand, .maskControl], to: KeyCode.rightArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.a, [.maskCommand, .maskControl], to: KeyCode.leftArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.s, [.maskCommand, .maskControl], to: KeyCode.downArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.w, [.maskCommand, .maskControl], to: KeyCode.upArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.d, [.maskCommand, .maskControl], to: KeyCode.rightArrow, allowsOtherModifiers: true),

    KeyMapping(KeyCode.d, .maskAlternate, to: KeyCode.deleteForward, .maskAlternate),
    KeyMapping(KeyCode.p, .maskControl, to: KeyCode.upArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.b, .maskControl, to: KeyCode.leftArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.f, .maskControl, to: KeyCode.rightArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.g, .maskControl, to: KeyCode.escape, allowsOtherModifiers: true),
    KeyMapping(KeyCode.n, .maskControl, to: KeyCode.downArrow, allowsOtherModifiers: true),
    KeyMapping(KeyCode.b, .maskAlternate, to: KeyCode.leftArrow, .maskAlternate),
    KeyMapping(KeyCode.f, .maskAlternate, to: KeyCode.rightArrow, .maskAlternate),
    KeyMapping(KeyCode.v, .maskControl, to: KeyCode.pageDown, allowsOtherModifiers: true),
    KeyMapping(KeyCode.v, .maskAlternate, to: KeyCode.pageUp, allowsOtherModifiers: true)
]

private enum HyperMode: Equatable {
    case inactive
    case top
    case layer(HyperLayer)

    var isActive: Bool {
        self != .inactive
    }
}

private enum HyperLayer {
    case raycast
    case applications
}

private struct OpenCommand {
    let label: String
    let arguments: [String]
}

private struct HUDOption {
    let key: String
    let label: String
}

private struct HUDContent {
    let title: String
    let options: [HUDOption]
}

private final class KeebsDaemon {
    private let debug: Bool
    private let trace: Bool
    private let tapLocation: EventTapLocation
    private let hud = KeebsHUD()
    private let launchQueue = DispatchQueue(label: "com.mads-hartmann.keebs.open")
    private var markMode = false
    private var hyperMode = HyperMode.inactive
    private var rightCommandIsDown = false
    private var suppressedHyperKeyUps = Set<CGKeyCode>()
    private var suppressCtrlSpaceKeyUp = false
    private var suppressCtrlGKeyUp = false
    private var activeKeyMappings: [CGKeyCode: KeyMapping] = [:]
    private var hardwareMappingInstalled = false
    private var HIDWatchdog: Process?
    private var terminationSignalSources: [DispatchSourceSignal] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(debug: Bool, trace: Bool, tapLocation: EventTapLocation) {
        self.debug = debug
        self.trace = trace
        self.tapLocation = tapLocation
    }

    func start() -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()

        guard checkAccessibilityPermission(), checkListenEventPermission() else {
            fputs(
                """
                keebs needs Accessibility permission to listen to and modify key events.
                Enable it in System Settings > Privacy & Security > Accessibility and Input Monitoring, then run keebs again.

                """,
                stderr
            )
            exit(1)
        }

        checkPostEventPermission()
        installCapsLockMapping()
        installTerminationHandlers()
        installAppActivationObserver()
        installEventTap()
        log("started with \(tapLocation.description) tap")
        CFRunLoopRun()
        fatalError("CFRunLoopRun returned unexpectedly")
    }

    private func installCapsLockMapping() {
        guard let currentMapping = currentHIDMapping() else {
            fputs("warning: could not read the current macOS HID key mapping; Caps Lock was not remapped\n", stderr)
            return
        }

        guard HIDMappingIsEmpty(currentMapping) else {
            fputs("warning: an existing macOS HID key mapping is active; Caps Lock was not remapped\n", stderr)
            return
        }

        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        watchdog.arguments = ["--hid-watchdog", String(ProcessInfo.processInfo.processIdentifier)]

        do {
            try watchdog.run()
        } catch {
            fputs("warning: could not start the HID cleanup watchdog; Caps Lock was not remapped\n", stderr)
            return
        }

        HIDWatchdog = watchdog
        guard setHIDMapping(capsLockToControlHIDMapping) else {
            kill(watchdog.processIdentifier, SIGKILL)
            HIDWatchdog = nil
            fputs("warning: could not map Caps Lock to Control\n", stderr)
            return
        }

        hardwareMappingInstalled = true
        log("installed lifecycle-scoped Caps Lock -> Left Control mapping")
    }

    private func installTerminationHandlers() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.removeCapsLockMapping()
                exit(0)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func removeCapsLockMapping() {
        guard hardwareMappingInstalled else {
            return
        }

        clearHIDMapping()
        hardwareMappingInstalled = false
        log("removed Caps Lock -> Left Control mapping")
    }

    private func checkAccessibilityPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }

    private func checkListenEventPermission() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }

        return CGRequestListenEventAccess()
    }

    private func checkPostEventPermission() {
        guard !CGPreflightPostEventAccess() else {
            return
        }

        if !CGRequestPostEventAccess() {
            fputs(
                """
                warning: keebs does not have event posting permission.
                Most mark-mode behavior can still work, but Ctrl-g may not be able to emit Escape.

                """,
                stderr
            )
        }
    }

    private func installAppActivationObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deactivateMarkMode(reason: "app switch")
            self?.deactivateHyperMode(reason: "app switch")
        }
    }

    private func installEventTap() {
        let mask = Self.eventMask([
            .flagsChanged,
            .keyDown,
            .keyUp,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ])

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: tapLocation.cgLocation,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            fputs(
                """
                failed to create event tap.
                Check Accessibility permission, or try restarting keebs after other keyboard tools are running.

                """,
                stderr
            )
            exit(1)
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func eventMask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                log("event tap re-enabled after \(type)")
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            deactivateMarkMode(reason: "mouse click")
            deactivateHyperMode(reason: "mouse click")
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            return handleFlagsChanged(event)

        case .keyDown:
            return handleKeyDown(proxy: proxy, event: event)

        case .keyUp:
            return handleKeyUp(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.keyCode
        traceKey("flags", keyCode: keyCode, flags: event.flags)

        guard keyCode == KeyCode.rightCommand else {
            return Unmanaged.passUnretained(event)
        }

        if rightCommandIsDown {
            rightCommandIsDown = false
        } else {
            rightCommandIsDown = true
            if hyperMode.isActive {
                deactivateHyperMode(reason: "right-command pressed again")
            } else {
                activateHyperTopLayer()
            }
        }

        return nil
    }

    private func handleKeyDown(proxy: CGEventTapProxy, event: CGEvent) -> Unmanaged<CGEvent>? {
        let originalKeyCode = event.keyCode
        traceKey("down", keyCode: originalKeyCode, flags: event.flags)

        if hyperMode.isActive {
            return handleHyperKeyDown(event)
        }

        if rightCommandIsDown {
            suppressedHyperKeyUps.insert(originalKeyCode)
            return nil
        }

        if let mapping = activeKeyMappings[originalKeyCode]
            ?? matchingKeyMapping(keyCode: originalKeyCode, flags: event.flags)
        {
            activeKeyMappings[originalKeyCode] = mapping
            mapping.apply(to: event)
            traceKey("mapped", keyCode: event.keyCode, flags: event.flags)
        }

        let keyCode = event.keyCode
        let flags = event.flags

        if isCtrlSpace(keyCode: keyCode, flags: flags) {
            setMarkMode(!markMode, reason: "ctrl-space")
            suppressCtrlSpaceKeyUp = true
            return nil
        }

        if isCtrlG(keyCode: keyCode, flags: flags) {
            deactivateMarkMode(reason: "ctrl-g")
            suppressCtrlGKeyUp = true
            postEscape(proxy: proxy)
            return nil
        }

        if markMode {
            if isNavigation(keyCode) {
                log("adding shift to navigation key \(keyCode)")
                event.addShift()
                return Unmanaged.passUnretained(event)
            }

            if shouldDeactivateAndPassThrough(keyCode: keyCode, flags: flags) {
                deactivateMarkMode(reason: "pass-through key \(keyCode)")
                return Unmanaged.passUnretained(event)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let originalKeyCode = event.keyCode
        traceKey("up", keyCode: originalKeyCode, flags: event.flags)

        if suppressedHyperKeyUps.remove(originalKeyCode) != nil {
            return nil
        }

        if hyperMode.isActive || rightCommandIsDown {
            return nil
        }

        if let mapping = activeKeyMappings.removeValue(forKey: originalKeyCode) {
            mapping.apply(to: event)
            traceKey("mapped up", keyCode: event.keyCode, flags: event.flags)
        }

        let keyCode = event.keyCode

        if suppressCtrlSpaceKeyUp, keyCode == KeyCode.space {
            suppressCtrlSpaceKeyUp = false
            return nil
        }

        if suppressCtrlGKeyUp, keyCode == KeyCode.g {
            suppressCtrlGKeyUp = false
            return nil
        }

        if markMode, isNavigation(keyCode) {
            event.addShift()
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func matchingKeyMapping(keyCode: CGKeyCode, flags: CGEventFlags) -> KeyMapping? {
        keyMappings.first { $0.matches(keyCode: keyCode, flags: flags) }
    }

    private func handleHyperKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.keyCode
        suppressedHyperKeyUps.insert(keyCode)

        switch hyperMode {
        case .inactive:
            return nil

        case .top:
            if keyCode == KeyCode.r {
                setHyperMode(.layer(.raycast), reason: "raycast layer")
                return nil
            }

            if keyCode == KeyCode.a {
                setHyperMode(.layer(.applications), reason: "applications layer")
                return nil
            }

            deactivateHyperMode(reason: "unknown top-layer key \(keyCode)")
            return nil

        case .layer(let layer):
            guard let command = hyperCommand(layer: layer, keyCode: keyCode) else {
                deactivateHyperMode(reason: "unknown \(layer) key \(keyCode)")
                return nil
            }

            launch(command)
            deactivateHyperMode(reason: "launched \(command.label)")
            return nil
        }
    }

    private func isCtrlSpace(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        keyCode == KeyCode.space
            && flags.contains(.maskControl)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
    }

    private func isCtrlG(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        keyCode == KeyCode.g
            && flags.contains(.maskControl)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
    }

    private func isNavigation(_ keyCode: CGKeyCode) -> Bool {
        KeyCode.navigation.contains(keyCode)
    }

    private func shouldDeactivateAndPassThrough(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        if keyCode == KeyCode.escape
            || keyCode == KeyCode.deleteOrBackspace
            || keyCode == KeyCode.deleteForward
        {
            return true
        }

        if flags.contains(.maskCommand), keyCode == KeyCode.x || keyCode == KeyCode.v {
            return true
        }

        return isLikelyTypingKey(keyCode: keyCode, flags: flags)
    }

    private func isLikelyTypingKey(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else {
            return false
        }

        return eventKeyProducesCharacters(keyCode: keyCode)
    }

    private func eventKeyProducesCharacters(keyCode: CGKeyCode) -> Bool {
        // Hardware-independent-ish US ANSI key ranges for letters, digits,
        // punctuation, tab, return, and space. This is intentionally broad:
        // typing should leave mark mode instead of becoming shifted typing.
        switch keyCode {
        case 0...50:
            return !KeyCode.navigation.contains(keyCode)
        default:
            return false
        }
    }

    private func postEscape(proxy: CGEventTapProxy) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.escape, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.escape, keyDown: false)

        keyDown?.flags = []
        keyUp?.flags = []

        if let keyDown {
            keyDown.tapPostEvent(proxy)
        }
        if let keyUp {
            keyUp.tapPostEvent(proxy)
        }
    }

    private func activateHyperTopLayer() {
        deactivateMarkMode(reason: "hyper started")
        setHyperMode(.top, reason: "right-command down")
    }

    private func deactivateHyperMode(reason: String) {
        guard hyperMode.isActive else {
            return
        }

        setHyperMode(.inactive, reason: reason)
    }

    private func setHyperMode(_ mode: HyperMode, reason: String) {
        guard hyperMode != mode else {
            return
        }

        hyperMode = mode

        if let content = hudContent(for: mode) {
            hud.show(content)
        } else {
            hud.hide()
        }

        log("hyper mode \(hyperModeDescription(mode)): \(reason)")
    }

    private func hudContent(for mode: HyperMode) -> HUDContent? {
        switch mode {
        case .inactive:
            return nil
        case .top:
            return HUDContent(
                title: "Hyper",
                options: [
                    HUDOption(key: "r", label: "Raycast"),
                    HUDOption(key: "a", label: "Applications")
                ]
            )
        case .layer(.raycast):
            return HUDContent(
                title: "Raycast",
                options: [
                    HUDOption(key: "w", label: "Windows"),
                    HUDOption(key: "c", label: "Clipboard"),
                    HUDOption(key: "k", label: "Confetti"),
                    HUDOption(key: "s", label: "Snippets"),
                    HUDOption(key: "i", label: "Screenshots"),
                    HUDOption(key: "n", label: "Notes")
                ]
            )
        case .layer(.applications):
            return HUDContent(
                title: "Applications",
                options: [
                    HUDOption(key: "t", label: "Ghostty"),
                    HUDOption(key: "e", label: "Code")
                ]
            )
        }
    }

    private func hyperCommand(layer: HyperLayer, keyCode: CGKeyCode) -> OpenCommand? {
        switch (layer, keyCode) {
        case (.raycast, KeyCode.w):
            return OpenCommand(
                label: "Raycast Windows",
                arguments: ["-g", "raycast://extensions/raycast/navigation/switch-windows"]
            )
        case (.raycast, KeyCode.c):
            return OpenCommand(
                label: "Raycast Clipboard",
                arguments: ["-g", "raycast://extensions/raycast/clipboard-history/clipboard-history"]
            )
        case (.raycast, KeyCode.k):
            return OpenCommand(
                label: "Raycast Confetti",
                arguments: ["-g", "raycast://extensions/raycast/raycast/confetti"]
            )
        case (.raycast, KeyCode.s):
            return OpenCommand(
                label: "Raycast Snippets",
                arguments: ["-g", "raycast://extensions/raycast/snippets/search-snippets"]
            )
        case (.raycast, KeyCode.i):
            return OpenCommand(
                label: "Raycast Screenshots",
                arguments: ["-g", "raycast://extensions/raycast/screenshots/search-screenshots"]
            )
        case (.raycast, KeyCode.n):
            return OpenCommand(
                label: "Raycast Notes",
                arguments: ["-g", "raycast://extensions/raycast/raycast-notes/raycast-notes"]
            )
        case (.applications, KeyCode.t):
            return OpenCommand(label: "Ghostty", arguments: ["-a", "Ghostty"])
        case (.applications, KeyCode.e):
            return OpenCommand(label: "Visual Studio Code", arguments: ["-a", "Visual Studio Code"])
        default:
            return nil
        }
    }

    private func launch(_ command: OpenCommand) {
        launchQueue.async { [debug] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = command.arguments

            do {
                try process.run()
                if debug {
                    fputs("[keebs] launched \(command.label)\n", stderr)
                }
            } catch {
                fputs("[keebs] failed to launch \(command.label): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func hyperModeDescription(_ mode: HyperMode) -> String {
        switch mode {
        case .inactive:
            return "off"
        case .top:
            return "top"
        case .layer(.raycast):
            return "raycast"
        case .layer(.applications):
            return "applications"
        }
    }

    private func deactivateMarkMode(reason: String) {
        guard markMode else {
            return
        }

        setMarkMode(false, reason: reason)
    }

    private func setMarkMode(_ isActive: Bool, reason: String) {
        guard markMode != isActive else {
            return
        }

        markMode = isActive
        if isActive {
            hud.show(
                HUDContent(
                    title: "Mark",
                    options: [
                        HUDOption(key: "shift", label: "Navigation")
                    ]
                )
            )
        } else {
            hud.hide()
        }
        log("mark mode \(isActive ? "on" : "off"): \(reason)")
    }

    private func log(_ message: String) {
        guard debug else {
            return
        }

        fputs("[keebs] \(message)\n", stderr)
    }

    private func traceKey(_ phase: String, keyCode: CGKeyCode, flags: CGEventFlags) {
        guard trace else {
            return
        }

        fputs(
            "[keebs] key \(phase): code=\(keyCode) flags=\(flags.keebsDescription)\n",
            stderr
        )
    }
}

private final class KeebsHUD {
    private var panel: NSPanel?
    private var hudView: KeebsHUDView?

    func show(_ content: HUDContent) {
        DispatchQueue.main.async {
            self.ensurePanel()
            self.update(content)
            self.positionPanel()
            self.panel?.orderFrontRegardless()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.panel?.orderOut(nil)
        }
    }

    private func update(_ content: HUDContent) {
        let panelSize = KeebsHUDView.preferredSize(for: content)
        hudView?.content = content
        hudView?.frame = NSRect(origin: .zero, size: panelSize)
        panel?.setContentSize(panelSize)
    }

    private func ensurePanel() {
        guard panel == nil else {
            return
        }

        let content = HUDContent(title: "", options: [])
        let panelSize = KeebsHUDView.preferredSize(for: content)
        let hudView = KeebsHUDView(frame: NSRect(origin: .zero, size: panelSize), content: content)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.contentView = hudView

        self.hudView = hudView
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel else {
            return
        }

        let panelSize = panel.frame.size
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - panelSize.height - 72
        )

        panel.setFrameOrigin(origin)
    }
}

private final class KeebsHUDView: NSView {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 8
    static let fontSize: CGFloat = NSFont.smallSystemFontSize + 1

    var content: HUDContent {
        didSet {
            needsDisplay = true
        }
    }

    static func preferredSize(for content: HUDContent) -> NSSize {
        let textSize = attributedText(for: content).size()
        return NSSize(
            width: ceil(textSize.width) + horizontalPadding * 2,
            height: ceil(textSize.height) + verticalPadding * 2
        )
    }

    override var isFlipped: Bool {
        true
    }

    init(frame frameRect: NSRect, content: HUDContent) {
        self.content = content
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let backgroundPath = NSBezierPath(roundedRect: backgroundBounds, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.08, alpha: 0.86).setFill()
        backgroundPath.fill()

        NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()

        let text = Self.attributedText(for: content)
        let textSize = text.size()
        let textRect = NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - textSize.height) / 2,
            width: ceil(textSize.width),
            height: ceil(textSize.height)
        )

        text.draw(in: textRect)
    }

    private static func attributedText(for content: HUDContent) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: fontSize)
        let optionText = content.options
            .map { "\($0.key) \($0.label)" }
            .joined(separator: "   ")
        let text = optionText.isEmpty ? content.title : "\(content.title): \(optionText)"

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white
            ]
        )
    }
}

private extension NSFont {
    static func menuBarFont(ofSize size: CGFloat) -> NSFont {
        if let font = NSFont(name: ".AppleSystemUIFont", size: size) {
            return font
        }

        return NSFont.systemFont(ofSize: size == 0 ? NSFont.smallSystemFontSize : size)
    }
}

private enum EventTapLocation: String {
    case annotated
    case session

    var cgLocation: CGEventTapLocation {
        switch self {
        case .annotated:
            return .cgAnnotatedSessionEventTap
        case .session:
            return .cgSessionEventTap
        }
    }

    var description: String {
        switch self {
        case .annotated:
            return "annotated session"
        case .session:
            return "session"
        }
    }
}

private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let daemon = Unmanaged<KeebsDaemon>.fromOpaque(userInfo).takeUnretainedValue()
    return daemon.handle(proxy: proxy, type: type, event: event)
}

private extension CGEvent {
    var keyCode: CGKeyCode {
        CGKeyCode(getIntegerValueField(.keyboardEventKeycode))
    }

    func addShift() {
        flags.insert(.maskShift)
    }
}

private extension CGEventFlags {
    static let keyMappingModifiers: CGEventFlags = [
        .maskShift,
        .maskControl,
        .maskAlternate,
        .maskCommand,
        .maskSecondaryFn
    ]

    var keebsDescription: String {
        var parts: [String] = []

        if contains(.maskShift) {
            parts.append("shift")
        }
        if contains(.maskControl) {
            parts.append("control")
        }
        if contains(.maskAlternate) {
            parts.append("option")
        }
        if contains(.maskCommand) {
            parts.append("command")
        }
        if contains(.maskSecondaryFn) {
            parts.append("fn")
        }

        if parts.isEmpty {
            parts.append("none")
        }

        return parts.joined(separator: "+")
    }
}

private struct Arguments {
    let debug: Bool
    let trace: Bool
    let tapLocation: EventTapLocation

    init(_ rawArguments: [String]) {
        trace = rawArguments.contains("--trace")
        debug = trace || rawArguments.contains("--debug")

        if let tapIndex = rawArguments.firstIndex(of: "--tap"),
           rawArguments.indices.contains(rawArguments.index(after: tapIndex)),
           let location = EventTapLocation(rawValue: rawArguments[rawArguments.index(after: tapIndex)])
        {
            tapLocation = location
        } else {
            tapLocation = .annotated
        }
    }
}

if let watchdogIndex = CommandLine.arguments.firstIndex(of: "--hid-watchdog"),
   CommandLine.arguments.indices.contains(CommandLine.arguments.index(after: watchdogIndex)),
   let parentPID = pid_t(CommandLine.arguments[CommandLine.arguments.index(after: watchdogIndex)])
{
    runHIDWatchdog(parentPID: parentPID)
} else {
    let arguments = Arguments(CommandLine.arguments)
    let daemon = KeebsDaemon(
        debug: arguments.debug,
        trace: arguments.trace,
        tapLocation: arguments.tapLocation
    )
    daemon.start()
}
