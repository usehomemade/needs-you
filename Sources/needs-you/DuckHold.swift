import AVFoundation
import Foundation

/// `needs-you duck-hold` (started by the app, HM-1413): lowers other apps' audio
/// until stdin closes. It runs Apple's voice processing with a silent output and
/// throws the mic audio away; macOS ducks other audio while that unit runs, the
/// same way it does while Needs You speaks.
///
/// It is a process of its own because voice processing in the app would take the
/// mic away from the plain engines that record him (they get no audio meanwhile).
/// When the app goes away (stdin closes, or the parent is gone), it exits and
/// macOS brings the audio back.
enum DuckHold {
    static func run() -> Never {
        let e = AVAudioEngine()
        let silent = AVAudioPlayerNode()
        e.attach(silent)
        e.connect(silent, to: e.mainMixerNode, format: nil)
        e.mainMixerNode.outputVolume = 0
        let input = e.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let f = input.outputFormat(forBus: 0)
            guard f.sampleRate > 0, f.channelCount > 0 else {
                throw NSError(domain: "NeedsYou", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { _, _ in }
            e.prepare()
            try e.start()
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
        print("ducking")
        fflush(stdout)
        let parent = getppid()
        func done() -> Never {
            input.removeTap(onBus: 0)
            e.stop()
            exit(0)
        }
        DispatchQueue.global().async {
            var b: UInt8 = 0
            while read(0, &b, 1) > 0 {}
            done()
        }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { if getppid() != parent { done() } }
        t.resume()
        dispatchMain()
    }
}
