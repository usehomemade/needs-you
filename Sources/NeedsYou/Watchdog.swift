import Darwin
import Foundation
import NeedsYouShared

/// Main-thread watchdog (HM-1418). The owner saw the whole app stop answering (even
/// Settings) after a reply or a send, until a restart. This leaves evidence for the next
/// time: when the main thread has not answered for 2 s, audio.log gets a "watchdog:" line
/// with how long, the last step the app marked, and the main thread's stack; again at 10,
/// 30, 120 s... while it stays stuck, and once more when it answers again.
///
/// The stack is read the way a sampler does: the main thread is suspended for a moment,
/// its frame pointers are copied into a buffer allocated beforehand (no allocation and no
/// locks while it is suspended), then it is resumed and the addresses are named.
enum Watchdog {
    private static let lock = NSLock()
    /// When the request that is waiting now was sent (nil: none waiting).
    private static var askedAt: TimeInterval?
    private static var step = ""
    private static var stepAt: TimeInterval = 0
    private static var mainThread: thread_act_t = 0
    private static var stackLow: UInt = 0, stackHigh: UInt = 0
    private static var started = false

    private static let maxFrames = 48
    private static let frames = UnsafeMutablePointer<UInt>.allocate(capacity: 48)

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Once, on the main thread, at launch.
    static func start() {
        guard Thread.isMainThread, !started else { return }
        started = true
        mainThread = mach_thread_self()
        let me = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(me))
        let t = Thread { loop() }
        t.name = "needs-you.watchdog"
        t.qualityOfService = .utility
        t.start()
    }

    /// What the main thread is about to do, shown if it blocks there ("ax: scan Ghostty").
    static func mark(_ s: String) {
        lock.lock(); step = s; stepAt = now; lock.unlock()
    }

    private static func loop() {
        var watch = StallWatch()
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            lock.lock()
            let t = now
            let waited = askedAt.map { t - $0 } ?? 0
            if askedAt == nil {
                askedAt = t
                DispatchQueue.main.async { lock.lock(); askedAt = nil; lock.unlock() }
            }
            let s = step, sAge = t - stepAt
            lock.unlock()
            switch watch.check(waited: waited) {
            case .blocked(let secs, let report)?:
                let last = s.isEmpty ? "none" : String(format: "\u{201C}%@\u{201D} %.1f s ago", s, sAge)
                var line = String(format: "watchdog: main thread blocked %.1f s (report %d); last step %@", secs, report, last)
                let stack = mainStack()
                if !stack.isEmpty { line += "; main stack: " + stack.joined(separator: " < ") }
                Isolation.note(line)
            case .recovered(let secs)?:
                Isolation.note(String(format: "watchdog: main thread free again after about %.1f s", secs))
            case nil:
                break
            }
        }
    }

    // MARK: Stack

    private static func mainStack() -> [String] {
        #if arch(arm64)
        var n = 0
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { p in
            p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            frames[0] = strip(UInt(state.__pc)); frames[1] = strip(UInt(state.__lr)); n = 2
            var fp = UInt(state.__fp)
            while n < maxFrames, fp >= stackLow, fp &+ 16 <= stackHigh, fp % 8 == 0 {
                guard let at = UnsafePointer<UInt>(bitPattern: fp) else { break }
                let next = at[0], ret = strip(at[1])
                if ret == 0 { break }
                frames[n] = ret; n += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        // Resumed: naming the addresses may take locks the main thread holds.
        var out: [String] = []
        for i in 0..<n where i != 1 || frames[1] != frames[0] {
            out.append(name(frames[i]))
        }
        // Collapse the run loop and AppKit plumbing at the bottom: the top is what matters.
        if let i = out.firstIndex(where: { $0.contains("NSApplication run") || $0.contains("CFRunLoopRun") }) { out = Array(out.prefix(i + 1)) }
        return out
        #else
        return []
        #endif
    }

    private static func strip(_ a: UInt) -> UInt { a & 0x0000_7FFF_FFFF_FFFF }

    private static func name(_ addr: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: addr), &info) != 0 else { return String(format: "0x%lx", addr) }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let sym = info.dli_sname else { return image }
        let raw = String(cString: sym)
        let off = addr &- UInt(bitPattern: info.dli_saddr)
        return "\(image) \(demangle(raw)) +\(off)"
    }

    @_silgen_name("swift_demangle")
    private static func swiftDemangle(_ name: UnsafePointer<CChar>?, _ length: Int, _ out: UnsafeMutablePointer<CChar>?,
                                      _ outLength: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

    private static func demangle(_ s: String) -> String {
        guard s.hasPrefix("$s") || s.hasPrefix("_$s") else { return s }
        let d: String? = s.withCString { c in
            guard let r = swiftDemangle(c, strlen(c), nil, nil, 0) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        // Keep it on one line and short: "AXDelivery.scan(_:)" not the full signature.
        guard var t = d else { return s }
        if t.count > 160 { t = String(t.prefix(160)) + "\u{2026}" }
        return t
    }
}
