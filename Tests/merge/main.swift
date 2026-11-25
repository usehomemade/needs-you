// Merge self-test (HM-1331): synthetic two-mic mixes with a 37 ms offset and
// 100 ppm clock drift, scored against the true sources. No audio files needed.
// Run: ./scripts/test-merge.sh
import Foundation

var rng = SplitMix(seed: 42)
let n = 16_000 * 30
// "Voice": noise in syllable-length bursts with pauses (speech-like, spiky).
var voice = [Float](repeating: 0, count: n)
var i = 0
while i < n {
    let len = 1_600 + Int(rng.uniform() * 4_000), gap = 800 + Int(rng.uniform() * 6_000)
    var lp: Float = 0
    for j in 0..<len where i + j < n {
        lp = 0.7 * lp + 0.3 * Float(rng.gauss())
        voice[i + j] = 0.3 * lp * sin(Float.pi * Float(j) / Float(len))
    }
    i += len + gap
}
// "Game": steady chords plus noise, always on.
let game: [Float] = (0..<n).map { t in
    let x = Float(t) / 16_000
    return 0.08 * (sin(2 * .pi * 220 * x) + sin(2 * .pi * 277 * x) + sin(2 * .pi * 330 * x)) + 0.05 * Float(rng.gauss())
}

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

let plain = TwoMic.selfTestNumbers(voice: voice, game: game)
print(plain.text)
check(abs(plain.lag) < 1, "plain: offset found within 1 sample")
check(abs(plain.drift) < 5, "plain: drift found within 5 ppm")
check(plain.confidence > TwoMic.minConfidence, "plain: confident")
check(plain.unrelated < 0.1, "unrelated signals are not aligned")
check(plain.iva > plain.mac + 10, "plain: AuxIVA beats the Mac mic by 10 dB")
check(plain.nlms > plain.mac + 5, "plain: noise reference beats the Mac mic by 5 dB")
check(abs(plain.roundTrip - plain.mac) < 0.5, "STFT round trip is lossless")

let room = TwoMic.selfTestNumbers(voice: voice, game: game, room: true)
print(room.text)
check(abs(room.drift) < 10, "room: drift found within 10 ppm")
check(room.confidence > TwoMic.minConfidence, "room: confident")
check(room.iva > room.mac - 1, "room: AuxIVA no worse than the Mac mic")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
