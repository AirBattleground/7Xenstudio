// Steady CFR clock: a real-time-priority thread waiting on mach_absolute_time deadlines (no display link, no drift).
import Foundation
import Darwin
import CoreMedia

enum MachTime {
    static let info: mach_timebase_info_data_t = { var i = mach_timebase_info_data_t(); mach_timebase_info(&i); return i }()
    static func ticks(seconds: Double) -> UInt64 { UInt64(max(0, seconds) * 1e9 * Double(info.denom) / Double(info.numer)) }
    static func seconds(ticks: UInt64) -> Double { Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9 }
    static var now: UInt64 { mach_absolute_time() }
}

struct ClockTick {
    var firstIndex: Int64
    var due: Int            // frames to emit now (>1 means we woke late and are catching up)
    var lateSeconds: Double // wake-up lateness vs the first due frame's deadline
    var skipped: Int        // frames given up because we were > maxCatchUp behind (real skips)
}

final class FrameClock {
    let fps: Double
    let period: Double
    private(set) var originTicks: UInt64 = 0
    private var thread: Thread?
    private var flag = ManagedFlag()
    var maxCatchUp = 4

    init(fps: Double) { self.fps = fps; self.period = 1.0 / fps }

    /// Exact CFR presentation time of frame `index` (relative to origin).
    func pts(_ index: Int64) -> CMTime {
        let scale = Int32(round(fps * 1000))
        return CMTime(value: index * 1000, timescale: scale)
    }

    func start(handler: @escaping (ClockTick) -> Void) {
        stop()
        let flag = ManagedFlag(); self.flag = flag
        originTicks = MachTime.now + MachTime.ticks(seconds: 0.003)
        let origin = originTicks, period = self.period, maxCatchUp = self.maxCatchUp
        let t = Thread {
            Self.makeRealtime(periodSeconds: period)
            var next: Int64 = 0
            while !flag.value {
                mach_wait_until(origin + MachTime.ticks(seconds: Double(next) * period))
                if flag.value { break }
                let elapsed = MachTime.seconds(ticks: MachTime.now &- origin)
                var lastDue = Int64(floor((elapsed + 0.001) / period))
                if lastDue < next { lastDue = next }
                var count = Int(lastDue - next + 1)
                var skipped = 0
                if count > maxCatchUp { skipped = count - 1; next += Int64(count - 1); count = 1 }
                handler(ClockTick(firstIndex: next, due: count, lateSeconds: max(0, elapsed - Double(next) * period), skipped: skipped))
                next += Int64(count)
            }
        }
        t.name = "studio.frameclock"; t.qualityOfService = .userInteractive
        thread = t; t.start()
    }

    func stop() { flag.value = true; thread = nil }

    private static func makeRealtime(periodSeconds: Double) {
        var p = thread_time_constraint_policy_data_t(
            period: UInt32(MachTime.ticks(seconds: periodSeconds)),
            computation: UInt32(MachTime.ticks(seconds: 0.002)),
            constraint: UInt32(MachTime.ticks(seconds: min(0.006, periodSeconds * 0.5))),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &p) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }
}

final class ManagedFlag { var value = false }

/// Rolling window of samples with percentile queries.
final class Window {
    private var buf: [Double]; private var n = 0, i = 0
    private let lock = NSLock()
    init(_ cap: Int = 600) { buf = Array(repeating: 0, count: cap) }
    func add(_ v: Double) { lock.lock(); buf[i] = v; i = (i + 1) % buf.count; n = min(n + 1, buf.count); lock.unlock() }
    func percentile(_ p: Double) -> Double {
        lock.lock(); let s = Array(buf[0..<n]).sorted(); lock.unlock()
        guard !s.isEmpty else { return 0 }
        return s[min(s.count - 1, Int(ceil(p * Double(s.count))) - 1 < 0 ? 0 : Int(ceil(p * Double(s.count))) - 1)]
    }
    func mean() -> Double { lock.lock(); defer { lock.unlock() }; return n == 0 ? 0 : buf[0..<n].reduce(0, +) / Double(n) }
}
