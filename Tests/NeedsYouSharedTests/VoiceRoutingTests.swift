import XCTest
@testable import NeedsYouShared

final class VoiceRoutingTests: XCTestCase {
    private func langs(_ text: String) -> [String] { VoiceRouting.segments(text).map(\.language) }

    override func setUp() {
        UserDefaults.standard.set("Neşe", forKey: "userName")
        UserDefaults.standard.set(["tr": "Neşe", "de": "Nesche", "de.system": "Neshe", "ru": "Неше"], forKey: VoiceRouting.nameSpellingsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "userName")
        UserDefaults.standard.removeObject(forKey: VoiceRouting.nameSpellingsKey)
    }

    func testSingleLanguages() {
        XCTAssertEqual(langs("Hi Neşe, the staging deploy is green. Shall I promote it to production?"), ["en"])
        XCTAssertEqual(langs("Merhaba Neşe, staging dağıtımı başarıyla tamamlandı. Şimdi üretime almamı ister misin?"), ["tr"])
        XCTAssertEqual(langs("Hallo Neşe, das Deployment auf Staging ist fertig. Soll ich es jetzt in Produktion bringen?"), ["de"])
        XCTAssertEqual(langs("Bonjour Neşe, le déploiement est terminé. Je le mets en production maintenant ?"), ["fr"])
        XCTAssertEqual(langs("Ciao Neşe, il rilascio è finito. Lo metto in produzione adesso?"), ["it"])
        XCTAssertEqual(langs("Привет, Неше, развёртывание готово. Выкатить в продакшен?"), ["ru"])
    }

    func testMixedTextSwitchesPerSentence() {
        let s = VoiceRouting.segments("The deploy is green. Testler geçti, her şey yolunda. Die Datenbank ist auch fertig. Shall I merge it?")
        XCTAssertEqual(s.map(\.language), ["en", "tr", "de", "en"])
        XCTAssertEqual(s[1].text, "Testler geçti, her şey yolunda.")
    }

    func testAdjacentSentencesInOneLanguageMerge() {
        let s = VoiceRouting.segments("Testler geçti. Şimdi üretime alıyorum. Done, all green on staging now.")
        XCTAssertEqual(s, [VoiceRouting.Segment("tr", "Testler geçti. Şimdi üretime alıyorum."),
                           VoiceRouting.Segment("en", "Done, all green on staging now.")])
    }

    func testShortSentencesInherit() {
        // "Okay." and "Danke!" say nothing on their own.
        XCTAssertEqual(langs("Okay. Das Deployment ist fertig und die Tests sind grün. Danke!"), ["de"])
        XCTAssertEqual(langs("Tamam. Testler geçti ve dağıtım bitti."), ["tr"])
        XCTAssertEqual(langs("Okay."), ["en"])
        XCTAssertEqual(langs("Danke schön!"), ["de"])
    }

    func testEnglishWithForeignNamesStaysEnglish() {
        XCTAssertEqual(langs("Neşe, the herdr pane for orchard is open in Coolify."), ["en"])
        XCTAssertEqual(langs("Staging deploy for Neşe is done."), ["en"])
    }

    func testNoTextIsLost() {
        let text = "The deploy is green.  Testler geçti!\nDie Tests sind durch. Merge?"
        let joined = VoiceRouting.split(text).joined()
        XCTAssertEqual(joined, text)
        XCTAssertEqual(VoiceRouting.segments("").count, 0)
    }

    func testNamePerLanguage() {
        XCTAssertEqual(VoiceRouting.spoken("Hallo Neşe, herdr ist offen.", language: "de"), "Hallo Nesche, Hörder ist offen.")
        XCTAssertEqual(VoiceRouting.spoken("Hallo Neşe.", language: "de", systemVoice: true), "Hallo Neshe.")
        XCTAssertEqual(VoiceRouting.spoken("Merhaba Nese.", language: "tr"), "Merhaba Neşe.")
        XCTAssertEqual(VoiceRouting.spoken("Привет, Neşe.", language: "ru"), "Привет, Неше.")
        XCTAssertEqual(VoiceRouting.spoken("Hi Neşe.", language: "en"), "Hi Neşe.")
        // Not inside other words.
        XCTAssertEqual(VoiceRouting.spoken("Neşeli kam.", language: "de"), "Neşeli kam.")
    }

    func testSettingsParsing() {
        XCTAssertEqual(VoiceRouting.parse("de,tr,xx"), ["tr", "de"])
        XCTAssertEqual(VoiceRouting.store(["ru", "tr"]), "tr,ru")
        XCTAssertEqual(VoiceRouting.voiceLabel("F2"), "Female 2")
        XCTAssertEqual(VoiceRouting.voiceLabel("M5"), "Male 5")
    }

    func testWavRoundTripAndJoin() {
        let a = WAV.Audio(samples: (0..<2205).map { sin(Float($0) * 0.05) * 0.5 }, sampleRate: 22_050)
        let back = WAV.decode(WAV.encode(a))
        XCTAssertEqual(back?.sampleRate, 22_050)
        XCTAssertEqual(back?.samples.count, 2205)
        XCTAssertEqual(back?.samples[100] ?? 0, a.samples[100], accuracy: 0.001)
        let j = WAV.join([a, WAV.Audio(samples: [Float](repeating: 0.1, count: 4410), sampleRate: 44_100)], rate: 24_000, gap: 0.1)
        XCTAssertEqual(j.sampleRate, 24_000)
        XCTAssertEqual(j.duration, 0.1 + 0.1 + 0.1, accuracy: 0.002)
        XCTAssertNil(WAV.decode(Data("not a wav".utf8)))
    }
}
