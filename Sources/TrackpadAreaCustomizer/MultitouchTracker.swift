import Foundation

final class MultitouchTracker {
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
