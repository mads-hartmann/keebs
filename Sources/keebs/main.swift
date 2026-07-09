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
    private let hud = MarkModeHUD()
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

        setMarkMode(false, reason: reason)
    }

    private func setMarkMode(_ isActive: Bool, reason: String) {
        guard markMode != isActive else {
            return
        }

        markMode = isActive
        if isActive {
            hud.show()
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

private final class MarkModeHUD {
    private var panel: NSPanel?
    private let panelSize = MarkModeHUDView.preferredSize

    func show() {
        DispatchQueue.main.async {
            self.ensurePanel()
            self.positionPanel()
            self.panel?.orderFrontRegardless()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        guard panel == nil else {
            return
        }

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
        panel.contentView = MarkModeHUDView(frame: NSRect(origin: .zero, size: panelSize))

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel else {
            return
        }

        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - panelSize.height - 72
        )

        panel.setFrameOrigin(origin)
    }
}

private final class MarkModeHUDView: NSView {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 8
    static let fontSize: CGFloat = NSFont.smallSystemFontSize + 1

    static var preferredSize: NSSize {
        let textSize = attributedText().size()
        return NSSize(
            width: ceil(textSize.width) + horizontalPadding * 2,
            height: ceil(textSize.height) + verticalPadding * 2
        )
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
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

        let text = Self.attributedText()
        let textSize = text.size()
        let textRect = NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - textSize.height) / 2,
            width: ceil(textSize.width),
            height: ceil(textSize.height)
        )

        text.draw(in: textRect)
    }

    private static func attributedText() -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: fontSize)
        return NSAttributedString(
            string: "Shift lock on",
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
