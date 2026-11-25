import Accelerate
import Foundation

/// Two-mic experiments (HM-1331): the Mac mic and the iPhone mic have separate
/// clocks, unknown positions and Continuity latency. Align first (GCC-PHAT
/// offset + drift fit), then combine: per-band SNR weighting, 2-channel AuxIVA,
/// or the far mic as a noise reference (frequency-domain NLMS).
/// Small deterministic random source for the self-test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double { sqrt(-2 * log(max(uniform(), 1e-12))) * cos(2 * .pi * uniform()) }
}

enum TwoMic {
    struct Alignment {
        var lag: Double        // samples: b[n + lag] lines up with a[n]
        var drift: Double      // extra samples of lag per sample (clock ratio - 1)
        var confidence: Double // 0...1
    }

    static let minConfidence = 0.35
    /// GCC-PHAT peak heights: unrelated sound gives ~0.013, two mics in an echoey
    /// room hearing the same thing ~0.04-0.07, a dry mix 0.3+.
    static let peakFloor = 0.03
    static func peakScore(_ p: Double) -> Double { max(0, min(1, (p - 0.02) / 0.04)) }
    static let rate = 16_000.0

    // MARK: Alignment

    /// Finds how `b` lines up with `a`: offset from GCC-PHAT on several stretches,
    /// drift from a line fit through those offsets.
    static func align(_ a: [Float], _ b: [Float], maxLag: Int = 48_000) -> Alignment? {
        let n = min(a.count, b.count)
        guard n >= 16_000 else { return nil }
        // Short takes: 3 stretches of a third each; long recordings: 8 s stretches every ~20 s.
        let seg = min(8 * 16_000, max(16_000, n / 3))
        let count = n - seg < 16_000 ? 1 : max(3, min(12, (n - seg) / (20 * 16_000) + 1))
        var points: [(t: Double, lag: Double, peak: Double)] = []
        for k in 0..<count {
            let start = count == 1 ? 0 : k * (n - seg) / (count - 1)
            if let r = gccPhat(Array(a[start..<start + seg]), Array(b[start..<min(b.count, start + seg)]), maxLag: maxLag) {
                points.append((Double(start + seg / 2), r.lag, r.peak))
            }
        }
        guard !points.isEmpty else { return nil }
        // Keep points that agree with the median lag (rejects stretches with no shared sound).
        let med = points.map(\.lag).sorted()[points.count / 2]
        let good = points.filter { abs($0.lag - med) < 160 && $0.peak > peakFloor }
        guard !good.isEmpty else { return Alignment(lag: med, drift: 0, confidence: 0) }
        var drift = 0.0, lag0 = good.map(\.lag).reduce(0, +) / Double(good.count)
        if good.count >= 3 {
            let mt = good.map(\.t).reduce(0, +) / Double(good.count)
            let ml = lag0
            let num = good.reduce(0) { $0 + ($1.t - mt) * ($1.lag - ml) }
            let den = good.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) }
            if den > 0 { drift = num / den; lag0 = ml - drift * mt }
        }
        let peak = good.map(\.peak).reduce(0, +) / Double(good.count)
        let agree = Double(good.count) / Double(points.count)
        let coarse = Alignment(lag: lag0, drift: drift, confidence: peakScore(peak) * agree)
        return refine(a, b, coarse) ?? coarse
    }

    /// Second pass: on the roughly aligned signal, short 2 s stretches every 0.5 s
    /// give many precise residual lags; a robust line through them corrects the
    /// offset and the drift (a few samples of error is enough to spoil separation).
    static func refine(_ a: [Float], _ b: [Float], _ c: Alignment) -> Alignment? {
        let n = min(a.count, b.count)
        let b1 = apply(c, to: b, length: n)
        let seg = 32_000, step = 8_000
        guard n >= seg else { return nil }
        var pts: [(t: Double, lag: Double, peak: Double)] = []
        var start = 0
        while start + seg <= n {
            if let r = gccPhat(Array(a[start..<start + seg]), Array(b1[start..<start + seg]), maxLag: 64) {
                pts.append((Double(start + seg / 2), r.lag, r.peak))
            }
            start += step
        }
        let strong = pts.filter { $0.peak > peakFloor }
        guard strong.count >= 3 else { return nil }
        // RANSAC line: his voice and the game sit at different distances, so the
        // residual lags form two parallel lines; take the one most stretches agree on.
        var bestIn: [(t: Double, lag: Double, peak: Double)] = []
        for i in 0..<strong.count {
            for j in (i + 1)..<strong.count where strong[j].t - strong[i].t > 32_000 {
                let slope = (strong[j].lag - strong[i].lag) / (strong[j].t - strong[i].t)
                guard abs(slope) < 500e-6 else { continue }
                let inl = strong.filter { abs($0.lag - (strong[i].lag + slope * ($0.t - strong[i].t))) < 1.5 }
                if inl.count > bestIn.count { bestIn = inl }
            }
        }
        // Chance lines through unrelated noise rarely gather more than a few points.
        guard bestIn.count >= max(5, pts.count / 6) else { return nil }
        let mt = bestIn.map(\.t).reduce(0, +) / Double(bestIn.count)
        let ml = bestIn.map(\.lag).reduce(0, +) / Double(bestIn.count)
        let den = bestIn.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) }
        let r1 = den > 0 ? bestIn.reduce(0) { $0 + ($1.t - mt) * ($1.lag - ml) } / den : 0
        let r0 = ml - r1 * mt
        let share = Double(bestIn.count) / Double(pts.count)
        return Alignment(lag: c.lag + r0, drift: c.drift + r1,
                         confidence: c.confidence > 0 ? min(1, share / 0.3) : 0)
    }

    /// Generalized cross-correlation with phase transform; lag with sub-sample peak.
    static func gccPhat(_ a: [Float], _ b: [Float], maxLag: Int) -> (lag: Double, peak: Double)? {
        let len = a.count + b.count
        var size = 1; while size < len { size <<= 1 }
        guard let fwd = vDSP.DFT(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let inv = vDSP.DFT(count: size, direction: .inverse, transformType: .complexComplex, ofType: Float.self) else { return nil }
        let zeros = [Float](repeating: 0, count: size)
        var ar = a + [Float](repeating: 0, count: size - a.count), br = b + [Float](repeating: 0, count: size - b.count)
        var (Ar, Ai) = fwd.transform(inputReal: ar, inputImaginary: zeros)
        let (Br, Bi) = fwd.transform(inputReal: br, inputImaginary: zeros)
        ar = []; br = []
        // R = conj(A) * B / |conj(A) * B|
        for i in 0..<size {
            let re = Ar[i] * Br[i] + Ai[i] * Bi[i]
            let im = Ar[i] * Bi[i] - Ai[i] * Br[i]
            let m = max(sqrt(re * re + im * im), 1e-12)
            Ar[i] = re / m; Ai[i] = im / m
        }
        let (cr, _) = inv.transform(inputReal: Ar, inputImaginary: Ai)
        var best = 0, bestV: Float = -.infinity
        var sumAbs: Float = 0
        for l in -maxLag...maxLag {
            let idx = l >= 0 ? l : size + l
            let v = cr[idx]
            sumAbs += abs(v)
            if v > bestV { bestV = v; best = l }
        }
        func at(_ l: Int) -> Float { cr[l >= 0 ? l : size + l] }
        // Parabolic interpolation around the peak.
        let y0 = at(best - 1), y1 = at(best), y2 = at(best + 1)
        let denom = y0 - 2 * y1 + y2
        let frac = denom != 0 ? Double(0.5 * (y0 - y2) / denom) : 0
        let norm = Double(bestV) / Double(size)
        _ = sumAbs
        return (Double(best) + max(-0.5, min(0.5, frac)), norm)
    }

    /// `b` resampled onto `a`'s timeline: out[n] = b[n + lag + drift * n].
    static func apply(_ al: Alignment, to b: [Float], length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        for n in 0..<length {
            let p = Double(n) + al.lag + al.drift * Double(n)
            let i = Int(floor(p)); let f = Float(p - Double(i))
            if i >= 0 && i + 1 < b.count { out[n] = b[i] * (1 - f) + b[i + 1] * f }
        }
        return out
    }

    static func shift(_ b: [Float], by lag: Int, length: Int) -> [Float] {
        apply(Alignment(lag: Double(lag), drift: 0, confidence: 1), to: b, length: length)
    }

    // MARK: Low cut

    /// Bins below ~94 Hz. Speech has nothing there, and game/music bass
    /// swamps everything else, so every method drops them (zero-phase, no filter).
    static func dropLow(_ S: inout Spec) {
        let lowBins = Int(94 * Double(S.frame) / rate) + 1
        for t in 0..<S.re.count { for k in 0..<lowBins { S.re[t][k] = 0; S.im[t][k] = 0 } }
    }
    static func lowCut(_ x: [Float]) -> [Float] { var S = stft(x); dropLow(&S); return istft(S, length: x.count) }

    // MARK: STFT

    static let frame = 512
    /// Longer frames for separation and noise cancelling: a room's echo lasts well
    /// past 32 ms, and a per-band 2x2 model only holds when the frame covers it.
    static let ivaFrame = 1024

    struct Spec { var re: [[Float]]; var im: [[Float]]; var frame = 512 } // [frame][bin]

    static func window(_ size: Int) -> [Float] { (0..<size).map { sqrt(0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size))) } }

    static func stft(_ x: [Float], frame: Int = frame) -> Spec {
        let hop = frame / 2, window = window(frame)
        let dft = vDSP.DFT(count: frame, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
        let zeros = [Float](repeating: 0, count: frame)
        var re: [[Float]] = [], im: [[Float]] = []
        var i = 0
        let bins = frame / 2 + 1
        while i + frame <= x.count {
            let seg = vDSP.multiply(Array(x[i..<i + frame]), window)
            let (r, m) = dft.transform(inputReal: seg, inputImaginary: zeros)
            re.append(Array(r[0..<bins])); im.append(Array(m[0..<bins]))
            i += hop
        }
        return Spec(re: re, im: im, frame: frame)
    }

    static func istft(_ s: Spec, length: Int) -> [Float] {
        let frame = s.frame, hop = frame / 2, window = window(frame)
        let dft = vDSP.DFT(count: frame, direction: .inverse, transformType: .complexComplex, ofType: Float.self)!
        var out = [Float](repeating: 0, count: length)
        let bins = frame / 2 + 1
        for t in 0..<s.re.count {
            var r = [Float](repeating: 0, count: frame), m = [Float](repeating: 0, count: frame)
            for k in 0..<bins { r[k] = s.re[t][k]; m[k] = s.im[t][k] }
            for k in 1..<(frame / 2) { r[frame - k] = s.re[t][k]; m[frame - k] = -s.im[t][k] }
            let (y, _) = dft.transform(inputReal: r, inputImaginary: m)
            let base = t * hop
            for j in 0..<frame where base + j < length { out[base + j] += y[j] * window[j] / Float(frame) }
        }
        return out
    }

    // MARK: (a) Per-band SNR-weighted combining

    static func snrWeighted(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = min(a.count, b.count)
        var A = stft(Array(a.prefix(n))), B = stft(Array(b.prefix(n)))
        dropLow(&A); dropLow(&B)
        let T = A.re.count, K = frame / 2 + 1
        guard T > 4 else { return Array(a.prefix(n)) }
        func floorOf(_ S: Spec) -> [Float] {
            (0..<K).map { k in
                let p = (0..<T).map { S.re[$0][k] * S.re[$0][k] + S.im[$0][k] * S.im[$0][k] }.sorted()
                return max(p[T * 20 / 100], 1e-10)
            }
        }
        let na = floorOf(A), nb = floorOf(B)
        var out = A
        for t in 0..<T {
            for k in 0..<K {
                let pa = A.re[t][k] * A.re[t][k] + A.im[t][k] * A.im[t][k]
                let pb = B.re[t][k] * B.re[t][k] + B.im[t][k] * B.im[t][k]
                let sa = max(pa / na[k] - 1, 0), sb = max(pb / nb[k] - 1, 0)
                let wa = (sa + 1e-3) / (sa + sb + 2e-3), wb = 1 - wa
                // Magnitudes weighted by SNR; phase from the cleaner mic.
                let mag = wa * sqrt(pa) + wb * sqrt(pb)
                let (pr, pi) = sa >= sb ? (A.re[t][k], A.im[t][k]) : (B.re[t][k], B.im[t][k])
                let pm = max(sqrt(pr * pr + pi * pi), 1e-12)
                out.re[t][k] = mag * pr / pm; out.im[t][k] = mag * pi / pm
            }
        }
        return istft(out, length: n)
    }

    // MARK: (b) 2-channel AuxIVA

    /// Two outputs, each projected back onto mic `a`'s scale.
    static func auxIVA(_ a: [Float], _ b: [Float], iterations: Int = 30, frame: Int = ivaFrame) -> [[Float]] {
        let n = min(a.count, b.count)
        var X0 = stft(Array(a.prefix(n)), frame: frame), X1 = stft(Array(b.prefix(n)), frame: frame)
        dropLow(&X0); dropLow(&X1)
        let X = [X0, X1]
        let T = X[0].re.count, K = frame / 2 + 1
        guard T > 4 else { return [Array(a.prefix(n)), Array(b.prefix(n))] }
        // W[k] = 2x2 complex, stored as (re, im) for w00 w01 w10 w11.
        var Wr = [[Float]](repeating: [1, 0, 0, 1], count: K), Wi = [[Float]](repeating: [0, 0, 0, 0], count: K)
        func demix(_ k: Int, _ t: Int) -> (Float, Float, Float, Float) {
            let x0r = X[0].re[t][k], x0i = X[0].im[t][k], x1r = X[1].re[t][k], x1i = X[1].im[t][k]
            let w = Wr[k], v = Wi[k]
            let y0r = w[0] * x0r - v[0] * x0i + w[1] * x1r - v[1] * x1i
            let y0i = w[0] * x0i + v[0] * x0r + w[1] * x1i + v[1] * x1r
            let y1r = w[2] * x0r - v[2] * x0i + w[3] * x1r - v[3] * x1i
            let y1i = w[2] * x0i + v[2] * x0r + w[3] * x1i + v[3] * x1r
            return (y0r, y0i, y1r, y1i)
        }
        for _ in 0..<iterations {
            for s in 0..<2 {
                // r_s(t): source norm over all bins (spherical Laplacian model).
                var r = [Float](repeating: 0, count: T)
                for t in 0..<T {
                    var e: Float = 0
                    for k in 0..<K { let y = demix(k, t); e += s == 0 ? y.0 * y.0 + y.1 * y.1 : y.2 * y.2 + y.3 * y.3 }
                    r[t] = max(sqrt(e), 1e-6)
                }
                for k in 0..<K {
                    // V = mean_t x x^H / r(t)   (Hermitian 2x2: v00 real, v11 real, v01 complex)
                    var v00: Float = 0, v11: Float = 0, v01r: Float = 0, v01i: Float = 0
                    for t in 0..<T {
                        let x0r = X[0].re[t][k], x0i = X[0].im[t][k], x1r = X[1].re[t][k], x1i = X[1].im[t][k]
                        let g = 1 / r[t]
                        v00 += g * (x0r * x0r + x0i * x0i); v11 += g * (x1r * x1r + x1i * x1i)
                        v01r += g * (x0r * x1r + x0i * x1i); v01i += g * (x0i * x1r - x0r * x1i)
                    }
                    let inv = 1 / Float(T); v00 *= inv; v11 *= inv; v01r *= inv; v01i *= inv
                    v00 += 1e-6; v11 += 1e-6
                    // M = W V; w_s = M^{-1} e_s (row s of W becomes conj of that column)
                    let w = Wr[k], u = Wi[k]
                    func mul(_ ar: Float, _ ai: Float, _ br: Float, _ bi: Float) -> (Float, Float) { (ar * br - ai * bi, ar * bi + ai * br) }
                    // V entries: V00=v00, V01=v01, V10=conj(v01), V11=v11
                    let m00 = add(mul(w[0], u[0], v00, 0), mul(w[1], u[1], v01r, -v01i))
                    let m01 = add(mul(w[0], u[0], v01r, v01i), mul(w[1], u[1], v11, 0))
                    let m10 = add(mul(w[2], u[2], v00, 0), mul(w[3], u[3], v01r, -v01i))
                    let m11 = add(mul(w[2], u[2], v01r, v01i), mul(w[3], u[3], v11, 0))
                    // inverse of M, column s
                    let det = sub(mul(m00.0, m00.1, m11.0, m11.1), mul(m01.0, m01.1, m10.0, m10.1))
                    let dm = max(det.0 * det.0 + det.1 * det.1, 1e-20)
                    let idet = (det.0 / dm, -det.1 / dm)
                    var c0: (Float, Float), c1: (Float, Float)
                    if s == 0 { c0 = mul(m11.0, m11.1, idet.0, idet.1); c1 = mul(-m10.0, -m10.1, idet.0, idet.1) }
                    else { c0 = mul(-m01.0, -m01.1, idet.0, idet.1); c1 = mul(m00.0, m00.1, idet.0, idet.1) }
                    // normalize: w^H V w
                    let q = v00 * (c0.0 * c0.0 + c0.1 * c0.1) + v11 * (c1.0 * c1.0 + c1.1 * c1.1)
                        + 2 * ((c0.0 * c1.0 + c0.1 * c1.1) * v01r - (c0.0 * c1.1 - c0.1 * c1.0) * v01i)
                    let sc = 1 / max(sqrt(max(q, 1e-20)), 1e-10)
                    // row s of W = conj(w_s)^T
                    Wr[k][2 * s] = c0.0 * sc; Wi[k][2 * s] = -c0.1 * sc
                    Wr[k][2 * s + 1] = c1.0 * sc; Wi[k][2 * s + 1] = -c1.1 * sc
                }
            }
        }
        // Outputs, projected back to mic a: y_s * A[0][s], A = W^{-1}.
        var outs: [Spec] = [X[0], X[0]]
        for k in 0..<K {
            let w = Wr[k], u = Wi[k]
            let det = sub((w[0] * w[3] - u[0] * u[3], w[0] * u[3] + u[0] * w[3]), (w[1] * w[2] - u[1] * u[2], w[1] * u[2] + u[1] * w[2]))
            let dm = max(det.0 * det.0 + det.1 * det.1, 1e-20)
            let idet = (det.0 / dm, -det.1 / dm)
            // A = adj(W)/det: A00 = w11/det, A01 = -w01/det
            let a00 = (w[3] * idet.0 - u[3] * idet.1, w[3] * idet.1 + u[3] * idet.0)
            let a01 = (-(w[1] * idet.0 - u[1] * idet.1), -(w[1] * idet.1 + u[1] * idet.0))
            for t in 0..<T {
                let y = demix(k, t)
                outs[0].re[t][k] = y.0 * a00.0 - y.1 * a00.1; outs[0].im[t][k] = y.0 * a00.1 + y.1 * a00.0
                outs[1].re[t][k] = y.2 * a01.0 - y.3 * a01.1; outs[1].im[t][k] = y.2 * a01.1 + y.3 * a01.0
            }
        }
        return outs.map { istft($0, length: n) }
    }

    private static func add(_ a: (Float, Float), _ b: (Float, Float)) -> (Float, Float) { (a.0 + b.0, a.1 + b.1) }
    private static func sub(_ a: (Float, Float), _ b: (Float, Float)) -> (Float, Float) { (a.0 - b.0, a.1 - b.1) }

    // MARK: (c) Far mic as noise reference

    /// Frequency-domain NLMS: removes from `near` what can be predicted from `far`.
    static func noiseReference(near: [Float], far: [Float], mu: Float = 0.08, frame: Int = ivaFrame) -> [Float] {
        let n = min(near.count, far.count)
        var N = stft(Array(near.prefix(n)), frame: frame), F = stft(Array(far.prefix(n)), frame: frame)
        dropLow(&N); dropLow(&F)
        let T = N.re.count, K = frame / 2 + 1
        var out = N
        var hr = [Float](repeating: 0, count: K), hi = [Float](repeating: 0, count: K)
        var pf = [Float](repeating: 1e-6, count: K)
        for t in 0..<T {
            for k in 0..<K {
                let fr = F.re[t][k], fi = F.im[t][k]
                let er = N.re[t][k] - (hr[k] * fr - hi[k] * fi)
                let ei = N.im[t][k] - (hr[k] * fi + hi[k] * fr)
                out.re[t][k] = er; out.im[t][k] = ei
                pf[k] = max(0.9 * pf[k] + 0.1 * (fr * fr + fi * fi), fr * fr + fi * fi)
                // Adapt only where the far mic dominates (noise); adapting while he talks
                // would teach the filter to cancel his own voice (it leaks into the far mic).
                let pn = N.re[t][k] * N.re[t][k] + N.im[t][k] * N.im[t][k]
                let g = pn < fr * fr + fi * fi ? mu / (pf[k] + 1e-8) : 0
                hr[k] += g * (fr * er + fi * ei); hi[k] += g * (fr * ei - fi * er)
            }
        }
        return istft(out, length: n)
    }

    // MARK: Self-test

    /// Synthetic check: his voice and the game reach two mics with different gains;
    /// mic b is 37 ms late and its clock runs 100 ppm fast. Reports how well each
    /// method recovers him (SIR against the true sources) and the alignment found.
    /// `room: true` adds a different echoey room path (direct sound + 150 ms decaying
    /// tail) from each source to each mic, which is much harder than plain gains.
    static func selfTest(voice: [Float], game: [Float], room: Bool = false) -> String {
        selfTestNumbers(voice: voice, game: game, room: room).text
    }

    struct SelfTest {
        var lag = 0.0, drift = 0.0, confidence = 0.0, unrelated = 0.0
        var mac = 0.0, iphone = 0.0, snr = 0.0, iva = 0.0, nlms = 0.0
        var snrTrue = 0.0, ivaTrue = 0.0, nlmsTrue = 0.0, roundTrip = 0.0
        var text = ""
    }

    static func selfTestNumbers(voice: [Float], game: [Float], room: Bool = false) -> SelfTest {
        let n = min(voice.count, 16_000 * 30)
        let v0 = Array(voice.prefix(n))
        let g0 = (0..<n).map { game[$0 % game.count] }
        var rng = SplitMix(seed: 7)
        func path(_ x: [Float], gain: Float, delay: Int) -> [Float] {
            guard room else { return x.map { $0 * gain } }
            let taps = 2_400
            var h = [Float](repeating: 0, count: taps)
            h[delay] = gain
            for i in (delay + 16)..<taps {
                h[i] += gain * 0.05 * Float(rng.gauss()) * exp(-Float(i - delay) / 700)
            }
            let padded = [Float](repeating: 0, count: taps) + x
            return Array(vDSP.convolve(padded, withKernel: h.reversed()).suffix(x.count))
        }
        // What each mic hears of each source. "v"/"g" are his voice and the game as
        // the Mac mic hears them: the target and the interference for the score.
        let v = path(v0, gain: 1, delay: 0), g = path(g0, gain: 0.6, delay: 40)
        let vFar = path(v0, gain: 0.35, delay: 25), gFar = path(g0, gain: 1, delay: 5)
        let a = (0..<n).map { v[$0] + g[$0] }                              // Mac: nearer to him
        let lagTrue = 592.0, driftTrue = 100e-6
        let raw = (0..<n).map { vFar[$0] + gFar[$0] }                      // iPhone: nearer to the TV
        // b[m] = raw[(m - lag) / (1 + drift)]  -> b[n + lag + drift*n] ≈ raw[n]
        let bLen = n + 2_000
        let b = (0..<bLen).map { m -> Float in
            let p = (Double(m) - lagTrue) / (1 + driftTrue)
            let i = Int(floor(p)); let f = Float(p - Double(i))
            return i >= 0 && i + 1 < n ? raw[i] * (1 - f) + raw[i + 1] * f : 0
        }
        guard let al = align(a, b) else { return SelfTest(text: "alignment failed") }
        let bAligned = apply(al, to: b, length: n)
        let vh = lowCut(v), gh = lowCut(g)
        func sir(_ yIn: [Float]) -> Double {
            let y = lowCut(yIn), v = vh, g = gh
            // Least-squares fit y ≈ α v + β g; SIR = |α v|² / |y - α v|².
            var vv = 0.0, gg = 0.0, vg = 0.0, yv = 0.0, yg = 0.0
            for i in 0..<n { let vi = Double(v[i]), gi = Double(g[i]), yi = Double(y[i]); vv += vi * vi; gg += gi * gi; vg += vi * gi; yv += yi * vi; yg += yi * gi }
            let det = vv * gg - vg * vg
            let alpha = det != 0 ? (yv * gg - yg * vg) / det : 0
            var sig = 0.0, res = 0.0
            for i in 0..<n { let s = alpha * Double(v[i]); sig += s * s; let r = Double(y[i]) - s; res += r * r }
            return 10 * log10(max(sig, 1e-12) / max(res, 1e-12))
        }
        let w = snrWeighted(a, bAligned)
        let iva = auxIVA(a, bAligned)
        let nr = noiseReference(near: a, far: bAligned)
        let ivaBest = iva.map(sir).max() ?? -99
        // The same methods with perfect alignment (checks the algorithms themselves).
        let ivaTrue = auxIVA(a, raw).map(sir).max() ?? -99
        let wTrue = sir(snrWeighted(a, raw)), nrTrue = sir(noiseReference(near: a, far: raw))
        let roundTrip = sir(istft(stft(a), length: n))
        let unrelated = align(v0, g0)?.confidence ?? 0
        var r = SelfTest(lag: al.lag - lagTrue, drift: (al.drift - driftTrue) * 1e6, confidence: al.confidence, unrelated: unrelated,
                         mac: sir(a), iphone: sir(bAligned), snr: sir(w), iva: ivaBest, nlms: sir(nr),
                         snrTrue: wTrue, ivaTrue: ivaTrue, nlmsTrue: nrTrue, roundTrip: roundTrip)
        r.text = String(format: (room ? "room: " : "plain gains: ") + "alignment: lag %.1f (true %.0f), drift %.0f ppm (true %.0f), confidence %.2f | SIR dB: Mac %.1f, iPhone %.1f, SNR-weighted %.1f, AuxIVA %.1f, noise-reference %.1f | perfectly aligned: SNR-weighted %.1f, AuxIVA %.1f, noise-reference %.1f | STFT round trip %.1f | confidence on unrelated signals %.2f",
                      al.lag, lagTrue, al.drift * 1e6, driftTrue * 1e6, al.confidence,
                      r.mac, r.iphone, r.snr, r.iva, r.nlms, wTrue, ivaTrue, nrTrue, roundTrip, unrelated)
        return r
    }
}
