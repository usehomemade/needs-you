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
        XCTAssertEqual(c.next(R(chat: 1), meaning: []), .send(1))
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
        XCTAssertEqual(c.next(R(chat: 3), meaning: Self.scores([(3, 0.5), (0, 0.3)])), .send(3)) // offered last time
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
