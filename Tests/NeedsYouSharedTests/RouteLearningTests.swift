import XCTest
@testable import NeedsYouShared

/// Meaning arithmetic and learned matches (HM-1408), with made-up vectors.
final class MeaningTests: XCTestCase {
    func testCosine() {
        XCTAssertEqual(Meaning.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(Meaning.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(Meaning.cosine([1, 0], [1, 0, 0]), 0) // different models never compare
    }
    func testClosestPartCountsAndChatsWithoutPartsAreLeftOut() {
        let msg: [Float] = [1, 0, 0]
        let chats: [[[Float]]] = [[[0, 1, 0], [0.9, 0.1, 0]], [], [[0, 0, 1]]]
        let r = Meaning.rank(msg, chats)
        XCTAssertEqual(r.map(\.index), [0, 2])
        XCTAssertGreaterThan(r[0].sim, 0.9)
        XCTAssertEqual(Meaning.rank(msg, chats, excluding: [0]).map(\.index), [2])
    }
    func testLeaderNeedsALead() {
        let s = { (a: [(Int, Double)]) in a.map { Meaning.Score(index: $0.0, sim: $0.1) } }
        XCTAssertEqual(Meaning.leader(s([(1, 0.5), (0, 0.4)])), 1)
        XCTAssertNil(Meaning.leader(s([(1, 0.5), (0, 0.48)])))
        XCTAssertNil(Meaning.leader(s([(1, 0.2)]))) // nothing is about it
        XCTAssertEqual(Meaning.veryClear(s([(1, 0.55), (0, 0.4)])), 1)
        XCTAssertNil(Meaning.veryClear(s([(1, 0.5), (0, 0.42)])))
    }
}

final class RouteLearningTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testWeightFallsWithDistanceAndAge() {
        XCTAssertEqual(RouteLearning.weight(sim: 1, age: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(RouteLearning.weight(sim: 0.4, age: 0), 0) // under the floor
        XCTAssertEqual(RouteLearning.weight(sim: 1, age: RouteLearning.halfLifeDays * 86_400), 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(RouteLearning.weight(sim: 0.9, age: 0), RouteLearning.weight(sim: 0.6, age: 0))
    }

    func testVotesOnlyForOpenChatsAndSameLanguage() {
        var l = RouteLearning()
        l.add(text: "did the landlord answer", key: "folder:bakery", name: "bakery", source: "picked", lang: "en", vector: [1, 0, 0], at: now)
        l.add(text: "the landlord again", key: "folder:bakery", name: "bakery", source: "meaning", lang: "en", vector: [0.95, 0.05, 0], at: now)
        l.add(text: "book the hotel", key: "title:trip planner", name: "trip planner", source: "named", lang: "en", vector: [0, 1, 0], at: now)
        l.add(text: "der Vermieter", key: "folder:bakery", name: "bakery", source: "picked", lang: "de", vector: [1, 0, 0], at: now)
        let v = l.votes([1, 0, 0], lang: "en", among: ["folder:bakery", "title:trip planner"], now: now)
        XCTAssertEqual(v.map(\.key), ["folder:bakery"])
        XCTAssertEqual(v[0].count, 2)
        XCTAssertEqual(v[0].example, "did the landlord answer")
        XCTAssertEqual(RouteLearning.leader(v), "folder:bakery")
        XCTAssertTrue(l.votes([1, 0, 0], lang: "en", among: ["title:trip planner"], now: now).isEmpty)
    }

    func testRecentMatchOutweighsOldOne() {
        var l = RouteLearning()
        l.add(text: "the printer", key: "a", name: "a", source: "picked", lang: "en", vector: [1, 0], at: now.addingTimeInterval(-60 * 86_400))
        l.add(text: "the printer", key: "b", name: "b", source: "picked", lang: "en", vector: [1, 0], at: now)
        let v = l.votes([1, 0], lang: "en", among: ["a", "b"], now: now)
        XCTAssertEqual(v.first?.key, "b")
        XCTAssertEqual(RouteLearning.leader(v), "b")
    }

    func testNoLeaderWhenTwoChatsVoteAlike() {
        let v = [RouteLearning.Vote(key: "a", weight: 1, count: 1, example: "", bestSim: 1),
                 RouteLearning.Vote(key: "b", weight: 0.8, count: 1, example: "", bestSim: 1)]
        XCTAssertNil(RouteLearning.leader(v))
    }

    func testKeepsNewest500AndShortText() {
        var l = RouteLearning()
        for i in 0..<520 { l.add(text: "m\(i)", key: "k", name: "n", source: "picked", lang: "en", vector: [1]) }
        XCTAssertEqual(l.matches.count, 500)
        XCTAssertEqual(l.matches.first?.text, "m20")
        l.add(text: Array(repeating: "word", count: 40).joined(separator: " "), key: "k", name: "n", source: "picked", lang: "en", vector: [1])
        XCTAssertEqual(l.matches.last?.text.split(separator: " ").count, 14)
    }

    func testRoundTripAndLegacy() throws {
        var l = RouteLearning()
        l.add(text: "x y", key: "k", name: "n", source: "named", lang: "en", vector: [0.5, 0.25], at: now)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rl-\(UUID()).json")
        l.save(url)
        XCTAssertEqual(RouteLearning.load(url), l)
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID()).json")
        try #"{"entries":[{"words":"sun dial","key":"folder:sundial","name":"sundial","source":"asked","at":"2026-11-20T10:00:00Z"}]}"#.write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(RouteLearning.Legacy.load(legacy).map(\.key), ["folder:sundial"])
        XCTAssertNil(RouteLearning.load(legacy)) // an old file is not read as the new one
    }
}

/// "Which chat?" as a conversation (HM-1408): no round limit, "none of them" is not a cancel.
final class ClarifyConversationTests: XCTestCase {
    static func scores(_ s: [(Int, Double)]) -> [Meaning.Score] { s.map { Meaning.Score(index: $0.0, sim: $0.1) } }
    typealias R = ClarifyConversation.Reading

    func testNumberPicksOfferedChat() {
        var c = ClarifyConversation(message: "book it", offered: [3, 1])
        XCTAssertEqual(c.next(R(), pressed: 2, meaning: []), .send(1))
    }
    func testSpokenOfferedChatSends() {
        var c = ClarifyConversation(message: "book it", offered: [3, 1])
        c.asked("Which chat?"); c.answered("the second one")
        XCTAssertEqual(c.next(R(chat: 1, sure: true, byNumber: true), meaning: []), .send(1))
    }
    /// HM-1425: "needs-you?" answered with a description of another chat never sends to the offered one.
    func testDescribingAnotherChatNeverSendsToTheOfferedOne() {
        var c = ClarifyConversation(message: "tell me when the bakery work is done", offered: [0])
        c.asked("I'm not sure which chat you meant. orchard?")
        c.answered("No, the bakery chat in my home folder. It's called bakery general in herdr.")
        // The model picks the offered chat but is unsure; his name for it ranks chat 3.
        let step = c.next(R(chat: 0, about: "bakery general"), meaning: Self.scores([(0, 0.53), (3, 0.51), (2, 0.49)]), byName: 3)
        XCTAssertEqual(step, .confirm(3))
        XCTAssertNotEqual(step, .send(0))
    }
    func testUnsurePickOfOfferedChatDoesNotSend() {
        var c = ClarifyConversation(message: "m", offered: [0, 1])
        c.asked("Which chat? 1, orchard. Or 2, bakery?"); c.answered("the one in the garden")
        XCTAssertEqual(c.next(R(chat: 0), meaning: Self.scores([(0, 0.40), (1, 0.39)])), .ask([0, 1]))
    }
    func testSurePickNeedsASecondSignal() {
        var c = ClarifyConversation(message: "m", offered: [0, 1])
        c.asked("Which chat? 1, orchard. Or 2, bakery?"); c.answered("orchard")
        // Sure, and nothing backs it: ask "Send it to orchard?" instead of sending.
        XCTAssertEqual(c.next(R(chat: 0, sure: true), meaning: []), .confirm(0))
        var d = ClarifyConversation(message: "m", offered: [0, 1])
        d.asked("Which chat? 1, orchard. Or 2, bakery?"); d.answered("orchard")
        XCTAssertEqual(d.next(R(chat: 0, sure: true), meaning: [], byName: 0), .send(0))
        // His name for it points at another chat: no send.
        var e = ClarifyConversation(message: "m", offered: [0, 1])
        e.asked("Which chat? 1, orchard. Or 2, bakery?"); e.answered("orchard, no, the pantry one")
        XCTAssertNotEqual(e.next(R(chat: 0, sure: true), meaning: [], byName: 2), .send(0))
    }
    func testNameNoChatHasSaysSoAndKeepsGoing() {
        var c = ClarifyConversation(message: "m", offered: [0])
        c.asked("orchard?"); c.answered("no, the lighthouse one")
        XCTAssertEqual(c.next(R(chat: 0, yesNo: .no, named: "lighthouse"), meaning: Self.scores([(1, 0.4), (2, 0.39)]), missingName: "lighthouse"),
                       .notFound("lighthouse"))
        XCTAssertEqual(c.offered, [])
        XCTAssertEqual(c.rejected, [0])
        c.asked("I can't find a chat called lighthouse. Which one?"); c.answered("the bakery one")
        XCTAssertEqual(c.next(R(chat: 2), meaning: Self.scores([(2, 0.5), (1, 0.3)]), byName: 2), .confirm(2))
    }
    func testMissingNameStillOffersAChatTwoSignalsAgreeOn() {
        var c = ClarifyConversation(message: "m", offered: [0])
        c.asked("orchard?"); c.answered("no, the one in my home folder, called lighthouse")
        XCTAssertEqual(c.next(R(yesNo: .no, named: "lighthouse"), meaning: Self.scores([(1, 0.37), (0, 0.02)]), byName: 1, missingName: "lighthouse"),
                       .confirm(1))
    }
    func testYesToTheOneOfferedSends() {
        var c = ClarifyConversation(message: "m", offered: [4])
        c.asked("orchard?"); c.answered("yes")
        XCTAssertEqual(c.next(R(chat: 4, yesNo: .yes), meaning: Self.scores([(1, 0.5), (4, 0.3)])), .send(4))
    }
    func testYesNamingAnotherChatLooksAgain() {
        var c = ClarifyConversation(message: "m", offered: [4])
        c.asked("orchard?"); c.answered("yes, the bakery one")
        XCTAssertEqual(c.next(R(chat: 1, yesNo: .yes), meaning: Self.scores([(1, 0.5), (4, 0.3)]), byName: 1), .confirm(1))
    }
    /// Names: herdr tab and workspace labels find a chat; a mishearing next to them is dropped.
    func testNameMatchUsesWorkspaceAndTab() {
        let chats = [
            ChatCandidate(title: "orchard", folder: "orchard"),
            ChatCandidate(title: "Sourdough starter notes", label: "bakery", aliases: ["general", "bakery general"]),
            ChatCandidate(title: "Trip planner", label: "summer-trips", aliases: ["general", "summer-trips general"]),
            ChatCandidate(title: "Claude Code", label: "auto-updates", aliases: ["bakery", "auto-updates bakery"]),
        ]
        XCTAssertEqual(ClarifyConversation.nameMatch("bakery general", chats), .chat(1))
        XCTAssertEqual(ClarifyConversation.nameMatch("Bakery General", chats), .chat(1))
        XCTAssertEqual(ClarifyConversation.nameMatch("bakery general inherder", chats), .chat(1))
        XCTAssertEqual(ClarifyConversation.nameMatch("lighthouse", chats), .missing)
        XCTAssertEqual(ClarifyConversation.nameMatch("general", chats), .unclear)
        XCTAssertEqual(ClarifyConversation.spokenName("Bakery General", in: "no, it's called bakery general in herdr"), "bakery general")
        XCTAssertEqual(ClarifyConversation.spokenName("lighthouse", in: "the bakery one"), "")
    }
    func testNoneOfThemIsNotCancelAndSearchesTheRest() {
        var c = ClarifyConversation(message: "make it a conversation", offered: [0, 1])
        c.asked("Which chat? 1, trip planner. Or 2, bakery?"); c.answered("none of them, the one about the voice router")
        // Meaning (over his answers) finds chat 4 clearly; the offered ones are out.
        let step = c.next(R(noneOfThese: true, about: "the voice router"), meaning: Self.scores([(0, 0.6), (4, 0.55), (2, 0.3)]))
        XCTAssertEqual(step, .confirm(4))
        XCTAssertEqual(c.confirming, 4)
        XCTAssertEqual(c.rejected, [0, 1])
        XCTAssertEqual(c.searchText(about: "the voice router"), "none of them, the one about the voice router. the voice router")
    }
    func testYesSendsNoKeepsGoing() {
        var c = ClarifyConversation(message: "m", offered: [0])
        c.asked("Which chat?"); c.answered("the game boy one")
        XCTAssertEqual(c.next(R(chat: 2), meaning: Self.scores([(2, 0.5), (0, 0.3)])), .confirm(2))
        c.asked("Send it to Game Boy?"); c.answered("no")
        // No, and nothing clear: ask again, without the rejected chat, closest first.
        XCTAssertEqual(c.next(R(yesNo: .no), meaning: Self.scores([(2, 0.5), (3, 0.41), (0, 0.40), (1, 0.2)])), .ask([3, 0, 1]))
        c.asked("Which chat then?"); c.answered("the racer save file")
        XCTAssertEqual(c.next(R(chat: 3, sure: true), meaning: Self.scores([(3, 0.5), (0, 0.3)])), .send(3)) // offered last time, meaning backs it
    }
    func testConfirmYes() {
        var c = ClarifyConversation(message: "m", offered: [0, 1])
        _ = c.next(R(noneOfThese: true), meaning: Self.scores([(2, 0.6), (3, 0.3)]))
        XCTAssertEqual(c.next(R(yesNo: .yes), meaning: []), .send(2))
    }
    func testModelPickWithoutBackingAsksWithItFirst() {
        var c = ClarifyConversation(message: "m", offered: [0])
        c.asked("Which chat?"); c.answered("the other one")
        XCTAssertEqual(c.next(R(chat: 3), meaning: Self.scores([(1, 0.42), (2, 0.40), (3, 0.39)])), .ask([3, 1, 2]))
    }
    func testNameAndMeaningAgreeConfirms() {
        var c = ClarifyConversation(message: "m", offered: [0])
        XCTAssertEqual(c.next(R(), meaning: Self.scores([(2, 0.42), (1, 0.40)]), byName: 2), .confirm(2))
    }
    func testOnlyExplicitStopCancels() {
        var c = ClarifyConversation(message: "m", offered: [0, 1])
        XCTAssertEqual(c.next(R(cancel: true), meaning: []), .cancel)
    }
    func testNoRoundLimit() {
        var c = ClarifyConversation(message: "m", offered: [0, 1])
        for n in 0..<12 {
            c.asked("Which chat then?"); c.answered("hmm \(n)")
            if case .cancel = c.next(R(), meaning: Self.scores([(0, 0.3), (1, 0.3)])) { XCTFail("gave up after \(n + 1) answers") }
        }
        XCTAssertEqual(c.exchanges.count, 12)
        XCTAssertTrue(c.transcript.hasPrefix("His message: \u{201C}m\u{201D}"))
    }
}
