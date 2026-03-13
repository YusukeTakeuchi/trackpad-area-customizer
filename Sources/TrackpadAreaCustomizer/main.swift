import ApplicationServices
import Foundation

private enum Corner: String {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"

    var isLeftSide: Bool {
        self == .topLeft || self == .bottomLeft
    }

    var isTopSide: Bool {
        self == .topLeft || self == .topRight
    }

    static func parse(_ rawValue: String) -> Corner? {
        switch rawValue.lowercased() {
        case "top-left", "tl":
            return .topLeft
        case "top-right", "tr":
            return .topRight
        case "bottom-left", "bl":
            return .bottomLeft
        case "bottom-right", "br":
            return .bottomRight
        default:
            return nil
        }
    }
}

private struct Config {
    let zoneWidthRatio: Double
    let zoneHeightRatio: Double
    let corner: Corner
    let maxTouchAgeMillis: Double
    let debug: Bool

    static let `default` = Config(
        zoneWidthRatio: 0.33,
        zoneHeightRatio: 0.33,
        corner: .topLeft,
        maxTouchAgeMillis: 120,
        debug: false
    )

    static func parse() -> Config {
        var config = Self.default
        var iterator = CommandLine.arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--zone-width":
                if let value = iterator.next(), let ratio = Double(value), ratio > 0, ratio <= 1 {
                    config = Config(
                        zoneWidthRatio: ratio,
                        zoneHeightRatio: config.zoneHeightRatio,
                        corner: config.corner,
                        maxTouchAgeMillis: config.maxTouchAgeMillis,
                        debug: config.debug
                    )
                }
            case "--zone-height":
                if let value = iterator.next(), let ratio = Double(value), ratio > 0, ratio <= 1 {
                    config = Config(
                        zoneWidthRatio: config.zoneWidthRatio,
                        zoneHeightRatio: ratio,
                        corner: config.corner,
                        maxTouchAgeMillis: config.maxTouchAgeMillis,
                        debug: config.debug
                    )
                }
            case "--corner":
                if let value = iterator.next(), let corner = Corner.parse(value) {
                    config = Config(
                        zoneWidthRatio: config.zoneWidthRatio,
                        zoneHeightRatio: config.zoneHeightRatio,
                        corner: corner,
                        maxTouchAgeMillis: config.maxTouchAgeMillis,
                        debug: config.debug
                    )
                }
            case "--max-touch-age-ms":
                if let value = iterator.next(), let millis = Double(value), millis > 0 {
                    config = Config(
                        zoneWidthRatio: config.zoneWidthRatio,
                        zoneHeightRatio: config.zoneHeightRatio,
                        corner: config.corner,
                        maxTouchAgeMillis: millis,
                        debug: config.debug
                    )
                }
            case "--debug":
                config = Config(
                    zoneWidthRatio: config.zoneWidthRatio,
                    zoneHeightRatio: config.zoneHeightRatio,
                    corner: config.corner,
                    maxTouchAgeMillis: config.maxTouchAgeMillis,
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
      --zone-width <0.0-1.0>      Horizontal size ratio of the corner zone (default: 0.33)
      --zone-height <0.0-1.0>     Vertical size ratio of the corner zone (default: 0.33)
      --corner <name>             top-left|top-right|bottom-left|bottom-right (default: top-left)
      --max-touch-age-ms <ms>     Max age of touch sample used for click mapping (default: 120)
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
            "Running: zoneWidth=\(config.zoneWidthRatio), zoneHeight=\(config.zoneHeightRatio), " +
                "corner=\(config.corner.rawValue), maxTouchAgeMs=\(config.maxTouchAgeMillis), " +
                "debug=\(config.debug)"
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

        let isHorizontalHit: Bool
        if config.corner.isLeftSide {
            isHorizontalHit = snapshot.x <= config.zoneWidthRatio
        } else {
            isHorizontalHit = snapshot.x >= (1.0 - config.zoneWidthRatio)
        }

        let isVerticalHit: Bool
        if config.corner.isTopSide {
            isVerticalHit = snapshot.y >= (1.0 - config.zoneHeightRatio)
        } else {
            isVerticalHit = snapshot.y <= config.zoneHeightRatio
        }

        let shouldApply = isHorizontalHit && isVerticalHit
        return ClickDecision(
            shouldApplyCommand: shouldApply,
            debugMessage: String(
                format: "leftMouseDown: corner=%@ x=%.3f y=%.3f horizontalHit=%@ verticalHit=%@ applyCmd=%@",
                config.corner.rawValue,
                snapshot.x,
                snapshot.y,
                isHorizontalHit ? "true" : "false",
                isVerticalHit ? "true" : "false",
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
