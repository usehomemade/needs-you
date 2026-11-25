import Foundation

/// Small WAV helpers for joining speech from several voices (HM-1368).
public enum WAV {
    public struct Audio: Equatable {
        public var samples: [Float]
        public var sampleRate: Int
        public init(samples: [Float], sampleRate: Int) { self.samples = samples; self.sampleRate = sampleRate }
        public var duration: Double { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }
    }

    /// Mono 16-bit PCM WAV.
    public static func encode(_ audio: Audio) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(audio.samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(audio.sampleRate)); u32(UInt32(audio.sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        var pcm = [Int16](repeating: 0, count: audio.samples.count)
        for (i, s) in audio.samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// PCM 16-bit or float 32-bit WAV, first channel. Nil for anything else.
    public static func decode(_ data: Data) -> Audio? {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var o = 12
        var format = 0, channels = 1, rate = 0, bits = 0
        while o + 8 <= data.count {
            let id = String(decoding: data.subdata(in: o..<o + 4), as: UTF8.self)
            let size = u32(o + 4)
            let body = o + 8
            if id == "fmt " && body + 16 <= data.count {
                format = u16(body); channels = max(1, u16(body + 2)); rate = u32(body + 4); bits = u16(body + 14)
                if format == 0xFFFE && body + 26 <= data.count { format = u16(body + 24) } // extensible: sub-format
            } else if id == "data" {
                let end = min(data.count, body + size)
                let frame = channels * bits / 8
                guard frame > 0, rate > 0 else { return nil }
                let n = (end - body) / frame
                var out = [Float](repeating: 0, count: n)
                data.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: body)
                    for i in 0..<n {
                        let p = base.advanced(by: i * frame)
                        if format == 1 && bits == 16 {
                            out[i] = Float(Int16(littleEndian: p.loadUnaligned(as: Int16.self))) / 32768
                        } else if format == 3 && bits == 32 {
                            out[i] = Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)))
                        }
                    }
                }
                guard (format == 1 && bits == 16) || (format == 3 && bits == 32) else { return nil }
                return Audio(samples: out, sampleRate: rate)
            }
            o = body + size + (size & 1)
        }
        return nil
    }

    /// Linear resampling (speech only, so no filter beyond that).
    public static func resample(_ a: Audio, to rate: Int) -> Audio {
        guard a.sampleRate != rate, a.sampleRate > 0, !a.samples.isEmpty else { return Audio(samples: a.samples, sampleRate: rate) }
        let ratio = Double(a.sampleRate) / Double(rate)
        let n = Int(Double(a.samples.count) / ratio)
        var out = [Float](repeating: 0, count: n)
        let last = a.samples.count - 1
        for i in 0..<n {
            let x = Double(i) * ratio
            let j = Int(x)
            let f = Float(x - Double(j))
            out[i] = j >= last ? a.samples[last] : a.samples[j] * (1 - f) + a.samples[j + 1] * f
        }
        return Audio(samples: out, sampleRate: rate)
    }

    /// The parts one after another at `rate`, with `gap` seconds of silence between them.
    public static func join(_ parts: [Audio], rate: Int, gap: Double) -> Audio {
        var out: [Float] = []
        let pause = [Float](repeating: 0, count: Int(Double(rate) * gap))
        for (i, p) in parts.enumerated() {
            if i > 0 { out += pause }
            out += resample(p, to: rate).samples
        }
        return Audio(samples: out, sampleRate: rate)
    }
}
