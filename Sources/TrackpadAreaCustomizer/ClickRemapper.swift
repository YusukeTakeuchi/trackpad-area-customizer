import ApplicationServices
import Foundation

private final class ClickDecisionEngine {
    struct ClickDecision {
        let action: TriggerAction?
        let debugMessage: String
        let shouldRestartTracker: Bool
    }

    private let config: Config
    private let touchState: TouchState
    private var activeMissClickPassthroughRuleIndex: Int?
    private static let snapshotTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(config: Config, touchState: TouchState) {
        self.config = config
        self.touchState = touchState
    }

    func resetMissClickPassthroughState() {
        activeMissClickPassthroughRuleIndex = nil
    }

    func evaluateClick(debugLog: (String) -> Void) -> ClickDecision {
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
}

private enum InputActionPerformer {
    static func sendShortcut(_ shortcut: KeyboardShortcut, debugLog: (String) -> Void) {
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

    static func applyClickFlags(_ flags: CGEventFlags, to event: CGEvent) {
        guard !flags.isEmpty else {
            return
        }
        var eventFlags = event.flags
        eventFlags.formUnion(flags)
        event.flags = eventFlags
    }
}

final class ClickRemapper {
    private let config: Config
    private let touchState: TouchState
    private let tracker: MultitouchTracker
    private let decisionEngine: ClickDecisionEngine

    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pendingUpBehavior = PendingUpBehavior.none

    private enum PendingUpBehavior {
        case none
        case modifiedClick(ModifiedClickAction)
        case suppress
    }

    init(config: Config) {
        self.config = config
        let touchState = TouchState()
        self.touchState = touchState
        self.tracker = MultitouchTracker(touchState: touchState)
        self.decisionEngine = ClickDecisionEngine(config: config, touchState: touchState)
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
                "highlightStatusItem=\(config.highlightStatusItem), " +
                "debug=\(config.debug)"
        )

        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            self.source = nil
        }
        pendingUpBehavior = .none
        decisionEngine.resetMissClickPassthroughState()
        tracker.stop()
    }

    func isTouchInsideAnyRuleArea() -> Bool {
        guard let snapshot = touchState.recentSnapshot(maxAgeMillis: config.maxTouchAgeMillis) else {
            return false
        }

        return config.areaRules.contains { rule in
            rule.matches(x: snapshot.x, y: snapshot.y)
        }
    }

    private func debugLog(_ message: String) {
        guard config.debug else {
            return
        }
        print("[debug] \(message)")
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            pendingUpBehavior = .none
            decisionEngine.resetMissClickPassthroughState()
            debugLog("eventTap was disabled; re-enabled")
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown {
            let decision = decisionEngine.evaluateClick(debugLog: debugLog)
            debugLog(decision.debugMessage)
            if decision.shouldRestartTracker {
                pendingUpBehavior = .none
                decisionEngine.resetMissClickPassthroughState()
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
                InputActionPerformer.applyClickFlags(clickAction.flags, to: event)
            case .keyboardShortcut(let shortcut):
                InputActionPerformer.sendShortcut(shortcut, debugLog: debugLog)
                pendingUpBehavior = .suppress
                debugLog("leftMouseDown: sent shortcut=\(shortcut.displayString)")
                return nil
            }
        } else if type == .leftMouseUp {
            switch pendingUpBehavior {
            case .none:
                debugLog("leftMouseUp: passthrough")
            case .modifiedClick(let clickAction):
                InputActionPerformer.applyClickFlags(clickAction.flags, to: event)
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

    deinit {
        stop()
    }
}
