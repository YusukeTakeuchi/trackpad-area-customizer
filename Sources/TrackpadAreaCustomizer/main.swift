import ApplicationServices
import Foundation

private struct Config {
    let leftZoneRatio: Double
    let topZoneRatio: Double
    let maxTouchAgeMillis: Double
    let invertY: Bool
    let debug: Bool

    static let `default` = Config(
        leftZoneRatio: 0.33,
        topZoneRatio: 0.33,
        maxTouchAgeMillis: 120,
        invertY: false,
        debug: false
    )

    static func parse() -> Config {
        var config = Self.default
        var iterator = CommandLine.arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--left-zone":
                if let value = iterator.next(), let ratio = Double(value), ratio > 0, ratio <= 1 {
                    config = Config(
                        leftZoneRatio: ratio,
                        topZoneRatio: config.topZoneRatio,
                        maxTouchAgeMillis: config.maxTouchAgeMillis,
                        invertY: config.invertY,
                        debug: config.debug
                    )
                }
            case "--top-zone":
                if let value = iterator.next(), let ratio = Double(value), ratio > 0, ratio <= 1 {
                    config = Config(
                        leftZoneRatio: config.leftZoneRatio,
                        topZoneRatio: ratio,
                        maxTouchAgeMillis: config.maxTouchAgeMillis,
                        invertY: config.invertY,
                        debug: config.debug
                    )
                }
            case "--max-touch-age-ms":
                if let value = iterator.next(), let millis = Double(value), millis > 0 {
                    config = Config(
                        leftZoneRatio: config.leftZoneRatio,
                        topZoneRatio: config.topZoneRatio,
                        maxTouchAgeMillis: millis,
                        invertY: config.invertY,
                        debug: config.debug
                    )
                }
            case "--invert-y":
                config = Config(
                    leftZoneRatio: config.leftZoneRatio,
                    topZoneRatio: config.topZoneRatio,
                    maxTouchAgeMillis: config.maxTouchAgeMillis,
                    invertY: true,
                    debug: config.debug
                )
            case "--debug":
                config = Config(
                    leftZoneRatio: config.leftZoneRatio,
                    topZoneRatio: config.topZoneRatio,
                    maxTouchAgeMillis: config.maxTouchAgeMillis,
                    invertY: config.invertY,
                    debug: true
                )
            case "--help":
                printUsageAndExit()
            default:
                continue
            }
        }

        return config
    }
}

private func printUsageAndExit() -> Never {
    let usage = """
    Usage:
      trackpad-area-customizer [options]

    Options:
      --left-zone <0.0-1.0>       Horizontal ratio from left edge (default: 0.33)
      --top-zone <0.0-1.0>        Vertical ratio from top edge (default: 0.33)
      --max-touch-age-ms <ms>     Max age of touch sample used for click mapping (default: 120)
      --invert-y                  Use this if top/bottom is reversed on your device
      --debug                     Print debug log for each click event
      --help                      Show this message
    """
    print(usage)
    exit(0)
}

private final class TouchState {
    struct Snapshot {
        let x: Double
        let y: Double
        let time: CFAbsoluteTime
    }

    private let lock = NSLock()
    private var latestSnapshot: Snapshot?

    func update(x: Double, y: Double) {
        let snapshot = Snapshot(x: x, y: y, time: CFAbsoluteTimeGetCurrent())
        lock.lock()
        latestSnapshot = snapshot
        lock.unlock()
    }

    func latest(maxAgeMillis: Double) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let snapshot = latestSnapshot else {
            return nil
        }
        let ageMillis = (CFAbsoluteTimeGetCurrent() - snapshot.time) * 1_000
        return ageMillis <= maxAgeMillis ? snapshot : nil
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
    private var pendingCommandForCurrentClick = false

    private struct ClickDecision {
        let shouldApplyCommand: Bool
        let debugMessage: String
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
            "Running: left=\(config.leftZoneRatio), top=\(config.topZoneRatio), " +
                "maxTouchAgeMs=\(config.maxTouchAgeMillis), invertY=\(config.invertY), debug=\(config.debug)"
        )
        return true
    }

    private func evaluateClick() -> ClickDecision {
        guard let snapshot = touchState.latest(maxAgeMillis: config.maxTouchAgeMillis) else {
            return ClickDecision(
                shouldApplyCommand: false,
                debugMessage: "leftMouseDown: no recent touch snapshot"
            )
        }

        let isLeft = snapshot.x <= config.leftZoneRatio
        let isTop: Bool
        if config.invertY {
            isTop = snapshot.y <= config.topZoneRatio
        } else {
            isTop = snapshot.y >= (1.0 - config.topZoneRatio)
        }
        let shouldApply = isLeft && isTop
        return ClickDecision(
            shouldApplyCommand: shouldApply,
            debugMessage: String(
                format: "leftMouseDown: x=%.3f y=%.3f isLeft=%@ isTop=%@ applyCmd=%@",
                snapshot.x,
                snapshot.y,
                isLeft ? "true" : "false",
                isTop ? "true" : "false",
                shouldApply ? "true" : "false"
            )
        )
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
            pendingCommandForCurrentClick = false
            debugLog("eventTap was disabled; re-enabled")
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown {
            let decision = evaluateClick()
            debugLog(decision.debugMessage)
            pendingCommandForCurrentClick = decision.shouldApplyCommand
            if decision.shouldApplyCommand {
                var flags = event.flags
                flags.insert(.maskCommand)
                event.flags = flags
            }
        } else if type == .leftMouseUp {
            if pendingCommandForCurrentClick {
                var flags = event.flags
                flags.insert(.maskCommand)
                event.flags = flags
                debugLog("leftMouseUp: applyCmd=true (from leftMouseDown)")
            } else {
                debugLog("leftMouseUp: applyCmd=false")
            }
            pendingCommandForCurrentClick = false
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
