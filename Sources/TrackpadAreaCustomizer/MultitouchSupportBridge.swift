import Foundation

typealias MTDeviceRef = UnsafeMutableRawPointer
typealias MTContactFrameCallback = @convention(c) (
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
func MTDeviceCreateList() -> CFArray?

@_silgen_name("MTRegisterContactFrameCallback")
func MTRegisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactFrameCallback)

@_silgen_name("MTUnregisterContactFrameCallback")
func MTUnregisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTContactFrameCallback)

@_silgen_name("MTDeviceStart")
func MTDeviceStart(_ device: MTDeviceRef, _ mode: Int32) -> Int32

@_silgen_name("MTDeviceStop")
func MTDeviceStop(_ device: MTDeviceRef) -> Int32

var globalTouchState: TouchState?

let mtContactFrameCallback: MTContactFrameCallback = { _, touchesRaw, count, _, _ in
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
