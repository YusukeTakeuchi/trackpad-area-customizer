import ApplicationServices
import Foundation

private final class TouchState {
    struct Snapshot {
        let x: Double
        let y: Double
        let time: CFAbsoluteTime
    }

    struct LookupResult {
        let recent: Snapshot?
        let latest: Snapshot?
        let recentHistory: [Snapshot]
    }

    private let lock = NSLock()
    private var latestSnapshot: Snapshot?
    private var snapshots: [Snapshot] = []
    private static let maxSnapshotHistory = 128
    static let missClickPassthroughMinimumHistoryCount = maxSnapshotHistory / 4

    func update(x: Double, y: Double) {
        let snapshot = Snapshot(x: x, y: y, time: CFAbsoluteTimeGetCurrent())
        lock.lock()
        latestSnapshot = snapshot
        snapshots.append(snapshot)
        let overflow = snapshots.count - Self.maxSnapshotHistory
        if overflow > 0 {
            snapshots.removeFirst(overflow)
        }
        lock.unlock()
    }

    func lookup(maxAgeMillis: Double, historyAgeMillis: Double) -> LookupResult {
        lock.lock()
        defer { lock.unlock() }

        guard let snapshot = latestSnapshot else {
            return LookupResult(recent: nil, latest: nil, recentHistory: [])
        }
        let now = CFAbsoluteTimeGetCurrent()
        let ageMillis = (now - snapshot.time) * 1_000
        let recentSnapshot = ageMillis <= maxAgeMillis ? snapshot : nil
        let recentHistory = snapshots.filter { (now - $0.time) * 1_000 <= historyAgeMillis }
        return LookupResult(recent: recentSnapshot, latest: snapshot, recentHistory: recentHistory)
    }
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactFrameCallback = @convention(c) (
    Int32,
    UnsafeMutableRawPointer,
    Int32,
    Double,
    Int32
) -> Int32

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var normalized: MTVector
    var size: Float
    var unknown3: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mm: MTVector
    var unknown4: Int32
    var unknown5: Int32
}

@_silgen_name("MTDeviceCreateList")
private func MTDeviceCreateList() -> CFArray?

@_silgen_name("MTRegisterContactFrameCallback")
private func MTRegisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactFrameCallback)

@_silgen_name("MTUnregisterContactFrameCallback")
private func MTUnregisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactFrameCallback)

@_silgen_name("MTDeviceStart")
private func MTDeviceStart(_ device: MTDeviceRef, _ mode: Int32) -> Int32

@_silgen_name("MTDeviceStop")
private func MTDeviceStop(_ device: MTDeviceRef) -> Int32

private var globalTouchState: TouchState?

private let mtContactFrameCallback: MTContactFrameCallback = { _, touchesRaw, count, _, _ in
    guard count > 0, let touchState = globalTouchState else {
        return 0
    }
    let touches = touchesRaw.assumingMemoryBound(to: MTTouch.self)

    for index in 0..<Int(count) {
        let touch = touches[index]
        if touch.state != 0 {
            let x = Double(touch.normalized.position.x)
            let y = Double(touch.normalized.position.y)
            touchState.update(x: x, y: y)
            break
        }
    }

    return 0
}

private final class MultitouchTracker {
    private let touchState: TouchState
    private var devices: [MTDeviceRef] = []

    init(touchState: TouchState) {
        self.touchState = touchState
    }

    func start() -> Bool {
        guard let list = MTDeviceCreateList() else {
            fputs("Could not access MultitouchSupport devices.\n", stderr)
            return false
        }

        globalTouchState = touchState

        let count = CFArrayGetCount(list)
        if count == 0 {
            fputs("No multitouch device found.\n", stderr)
            return false
        }

        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else {
                continue
            }
            let device = UnsafeMutableRawPointer(mutating: raw)
            MTRegisterContactFrameCallback(device, mtContactFrameCallback)
            _ = MTDeviceStart(device, 0)
            devices.append(device)
        }

        return !devices.isEmpty
    }

    func stop() {
        for device in devices {
            MTUnregisterContactFrameCallback(device, mtContactFrameCallback)
            _ = MTDeviceStop(device)
        }
        devices.removeAll()
        globalTouchState = nil
    }

    func restart() -> Bool {
        stop()
        return start()
    }

    deinit {
        stop()
    }
}

private final class ClickRemapper {
    private let config: Config
    private let touchState: TouchState
    private let tracker: MultitouchTracker

    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pendingUpBehavior = PendingUpBehavior.none
    private var activeMissClickPassthroughRuleIndex: Int?
    private static let snapshotTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private enum PendingUpBehavior {
        case none
        case modifiedClick(ModifiedClickAction)
        case suppress
    }

    private struct ClickDecision {
        let action: TriggerAction?
        let debugMessage: String
        let shouldRestartTracker: Bool
    }

    init(config: Config) {
        self.config = config
        self.touchState = TouchState()
        self.tracker = MultitouchTracker(touchState: touchState)
    }

    func start() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let axPromptOptions = [promptKey: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(axPromptOptions) {
            fputs("Accessibility permission is required. Grant it, then restart.\n", stderr)
        }

        guard tracker.start() else {
            return false
        }
        let leftDownMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let leftUpMask = CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: leftDownMask | leftUpMask,
            callback: ClickRemapper.eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            fputs("Failed to create event tap. Allow Input Monitoring and Accessibility, then restart.\n", stderr)
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.source = source

        print(
            "Running: mode=config, rules=\(config.areaRules.count), " +
                "marginRules=\(config.areaRules.filter { $0.missClickMargin > 0 }.count), " +
                "maxTouchAgeMs=\(config.maxTouchAgeMillis), " +
                String(format: "missClickHistoryWindowSec=%.3f, ", config.missClickHistoryWindowMillis / 1_000) +
                "debug=\(config.debug)"
        )

        return true
    }

    private func evaluateClick() -> ClickDecision {
        let lookup = touchState.lookup(
            maxAgeMillis: config.maxTouchAgeMillis,
            historyAgeMillis: config.missClickHistoryWindowMillis
        )
        debugLog("leftMouseDown: recentHistoryCount=\(lookup.recentHistory.count)")
        guard let snapshot = lookup.recent else {
            activeMissClickPassthroughRuleIndex = nil
            let timestamp: String
            if let latestSnapshot = lookup.latest {
                timestamp = Self.snapshotTimestampFormatter.string(
                    from: Date(timeIntervalSinceReferenceDate: latestSnapshot.time)
                )
            } else {
                timestamp = "none"
            }
            return ClickDecision(
                action: nil,
                debugMessage: "leftMouseDown: no recent touch snapshot (lastSnapshotAt=\(timestamp))",
                shouldRestartTracker: true
            )
        }

        let matchedRule = config.areaRules.enumerated().first {
            $0.element.matches(x: snapshot.x, y: snapshot.y)
        }

        if let activeRuleIndex = activeMissClickPassthroughRuleIndex {
            if lookup.recentHistory.count < TouchState.missClickPassthroughMinimumHistoryCount {
                debugLog(
                    String(
                        format: "leftMouseDown(missClick): cleared passthrough state because recentHistoryCount=%d is below threshold=%d",
                        lookup.recentHistory.count,
                        TouchState.missClickPassthroughMinimumHistoryCount
                    )
                )
                activeMissClickPassthroughRuleIndex = nil
            } else if matchedRule?.offset != activeRuleIndex {
                debugLog(
                    String(
                        format: "leftMouseDown(missClick): cleared passthrough state by outside tap (rule=%d)",
                        activeRuleIndex + 1
                    )
                )
                activeMissClickPassthroughRuleIndex = nil
            } else {
                return ClickDecision(
                    action: nil,
                    debugMessage: String(
                        format: "leftMouseDown(missClick): x=%.3f y=%.3f activeRule=%d continuePassthrough=true",
                        snapshot.x,
                        snapshot.y,
                        activeRuleIndex + 1
                    ),
                    shouldRestartTracker: false
                )
            }
        }

        if let (index, rule) = matchedRule {
            if rule.missClickMargin > 0 {
                let recentlyTouchedMargin = lookup.recentHistory.contains {
                    rule.matchesOutsideButWithinMargin(x: $0.x, y: $0.y)
                }
                if recentlyTouchedMargin {
                    activeMissClickPassthroughRuleIndex = index
                    return ClickDecision(
                        action: nil,
                        debugMessage: String(
                            format: "leftMouseDown(rules): x=%.3f y=%.3f matchedRule=%d margin=%.3f recentOuterMarginTouch=true passthrough=latched",
                            snapshot.x,
                            snapshot.y,
                            index + 1,
                            rule.missClickMargin
                        ),
                        shouldRestartTracker: false
                    )
                }
            }
            return ClickDecision(
                action: rule.action,
                debugMessage: String(
                    format: "leftMouseDown(rules): x=%.3f y=%.3f matchedRule=%d action=%@ expr=%@ margin=%.3f",
                    snapshot.x,
                    snapshot.y,
                    index + 1,
                    rule.action.displayString,
                    rule.description,
                    rule.missClickMargin
                ),
                shouldRestartTracker: false
            )
        }

        return ClickDecision(
            action: nil,
            debugMessage: String(
                format: "leftMouseDown(rules): x=%.3f y=%.3f matchedRule=none",
                snapshot.x,
                snapshot.y
            ),
            shouldRestartTracker: false
        )
    }

    private func sendShortcut(_ shortcut: KeyboardShortcut) {
        guard
            let keyDownEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: shortcut.keyCode,
                keyDown: true
            ),
            let keyUpEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: shortcut.keyCode,
                keyDown: false
            )
        else {
            debugLog("failed to create keyboard events for shortcut=\(shortcut.displayString)")
            return
        }

        keyDownEvent.flags = shortcut.flags
        keyUpEvent.flags = shortcut.flags
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
    }

    private func debugLog(_ message: String) {
        guard config.debug else {
            return
        }
        print("[debug] \(message)")
    }

    private func applyClickFlags(_ flags: CGEventFlags, to event: CGEvent) {
        guard !flags.isEmpty else {
            return
        }
        var eventFlags = event.flags
        eventFlags.formUnion(flags)
        event.flags = eventFlags
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            pendingUpBehavior = .none
            activeMissClickPassthroughRuleIndex = nil
            debugLog("eventTap was disabled; re-enabled")
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown {
            let decision = evaluateClick()
            debugLog(decision.debugMessage)
            if decision.shouldRestartTracker {
                pendingUpBehavior = .none
                activeMissClickPassthroughRuleIndex = nil
                if tracker.restart() {
                    debugLog("leftMouseDown: restarted multitouch tracker after missing snapshot")
                } else {
                    fputs("Failed to restart multitouch tracker after missing snapshot.\n", stderr)
                }
                return Unmanaged.passUnretained(event)
            }

            switch decision.action {
            case .none:
                pendingUpBehavior = .none
            case .modifiedClick(let clickAction):
                pendingUpBehavior = .modifiedClick(clickAction)
                applyClickFlags(clickAction.flags, to: event)
            case .keyboardShortcut(let shortcut):
                sendShortcut(shortcut)
                pendingUpBehavior = .suppress
                debugLog("leftMouseDown: sent shortcut=\(shortcut.displayString)")
                return nil
            }
        } else if type == .leftMouseUp {
            switch pendingUpBehavior {
            case .none:
                debugLog("leftMouseUp: passthrough")
            case .modifiedClick(let clickAction):
                applyClickFlags(clickAction.flags, to: event)
                debugLog("leftMouseUp: applyClickAction=\(clickAction.displayString) (from leftMouseDown)")
                pendingUpBehavior = .none
            case .suppress:
                pendingUpBehavior = .none
                debugLog("leftMouseUp: suppressed (shortcut mode)")
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let remapper = Unmanaged<ClickRemapper>.fromOpaque(userInfo).takeUnretainedValue()
        return remapper.handleEvent(type: type, event: event)
    }
}

private let config = Config.parse()
private let remapper = ClickRemapper(config: config)
guard remapper.start() else {
    exit(1)
}
RunLoop.current.run()
