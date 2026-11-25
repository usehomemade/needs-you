import AVFoundation
import CoreAudio
import Foundation

/// Test hook: records the Mac mic and the iPhone mic at the same time, raw (16 kHz
/// mono), with the host time of each first sample, for the two-mic experiments.
final class DualRecorder {
    private var engines: [AVAudioEngine] = []
    private var samples: [[Float]] = []
    private var firstHost: [UInt64?] = []
    private let lock = NSLock()
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func record(uids: [String], seconds: Double) async throws -> (samples: [[Float]], hostStart: [Double]) {
        samples = Array(repeating: [], count: uids.count)
        firstHost = Array(repeating: nil, count: uids.count)
        for (k, uid) in uids.enumerated() {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if let device = AudioDevices.inputs().first(where: { $0.id == uid }), let unit = input.audioUnit {
                var id = device.deviceID
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: Self.format) else {
                throw NSError(domain: "NeedsYou", code: 11, userInfo: [NSLocalizedDescriptionKey: "No input on \(uid)"])
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, time in
                guard let self else { return }
                let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 64
                guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: cap) else { return }
                var fed = false
                conv.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buf
                }
                let chunk = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
                self.lock.lock()
                if self.firstHost[k] == nil, time.isHostTimeValid { self.firstHost[k] = time.hostTime }
                self.samples[k] += chunk
                self.lock.unlock()
            }
            engine.prepare()
            try engine.start()
            engines.append(engine)
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        for e in engines { e.inputNode.removeTap(onBus: 0); e.stop() }
        engines = []
        lock.lock(); defer { lock.unlock() }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let host = firstHost.map { h in h.map { Double($0) * Double(tb.numer) / Double(tb.denom) / 1e9 } ?? 0 }
        return (samples, host)
    }
}
