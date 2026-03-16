import Foundation

final class TouchState {
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
