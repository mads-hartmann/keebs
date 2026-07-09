import AppKit
import CoreGraphics
import Foundation

private enum KeyCode {
    static let space: CGKeyCode = 49
    static let g: CGKeyCode = 5
    static let v: CGKeyCode = 9
    static let x: CGKeyCode = 7

    static let escape: CGKeyCode = 53
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

private final class KeebsDaemon {
    private let debug: Bool
    private let trace: Bool
    private let tapLocation: EventTapLocation
    private var markMode = false
    private var suppressCtrlSpaceKeyUp = false
    private var suppressCtrlGKeyUp = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(debug: Bool, trace: Bool, tapLocation: EventTapLocation) {
        self.debug = debug
        self.trace = trace
        self.tapLocation = tapLocation
    }

    func start() -> Never {
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
        installAppActivationObserver()
        installEventTap()
        log("started with \(tapLocation.description) tap")
        CFRunLoopRun()
        fatalError("CFRunLoopRun returned unexpectedly")
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
        }
    }

    private func installEventTap() {
        let mask = Self.eventMask([
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
            return Unmanaged.passUnretained(event)

        case .keyDown:
            return handleKeyDown(proxy: proxy, event: event)

        case .keyUp:
            return handleKeyUp(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(proxy: CGEventTapProxy, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.keyCode
        let flags = event.flags
        traceKey("down", keyCode: keyCode, flags: flags)

        if isCtrlSpace(keyCode: keyCode, flags: flags) {
            markMode.toggle()
            suppressCtrlSpaceKeyUp = true
            log(markMode ? "mark mode on" : "mark mode off")
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
        let keyCode = event.keyCode
        traceKey("up", keyCode: keyCode, flags: event.flags)

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

    private func deactivateMarkMode(reason: String) {
        guard markMode else {
            return
        }

        markMode = false
        log("mark mode off: \(reason)")
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

private let arguments = Arguments(CommandLine.arguments)
private let daemon = KeebsDaemon(
    debug: arguments.debug,
    trace: arguments.trace,
    tapLocation: arguments.tapLocation
)
daemon.start()
