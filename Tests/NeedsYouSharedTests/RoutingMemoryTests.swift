import XCTest
@testable import NeedsYouShared

final class RoutingMemoryTests: XCTestCase {
    func testKeepsLast200() {
        var m = RoutingMemory()
        for i in 0..<250 { m.add(words: "w\(i)", key: "k", name: "n", source: "asked") }
        XCTAssertEqual(m.entries.count, 200)
        XCTAssertEqual(m.entries.first?.words, "w50")
    }

    func testLookupFindsSameWordsOnlyAmongOpenChats() {
        var m = RoutingMemory()
        m.add(words: RoutingMemory.words(rest: "the bakery thing, did the landlord reply"), key: "title:portuguese bakery", name: "Portuguese bakery", source: "asked")
        m.add(words: "sun dial", key: "folder:sundial", name: "sundial", source: "asked")
        XCTAssertEqual(m.lookup("the bakery thing did the landlord", among: ["title:portuguese bakery", "folder:sundial"]), "title:portuguese bakery")
        XCTAssertNil(m.lookup("the bakery thing did the landlord", among: ["folder:sundial"]))
        XCTAssertEqual(m.lookup("sun dial", among: ["folder:sundial"]), "folder:sundial")
        XCTAssertNil(m.lookup("recipe box", among: ["folder:sundial"]))
    }

    func testNewestWins() {
        var m = RoutingMemory()
        m.add(words: "voice app", key: "a", name: "a", source: "asked")
        m.add(words: "voice app", key: "b", name: "b", source: "asked")
        XCTAssertEqual(m.lookup("voice app", among: ["a", "b"]), "b")
        XCTAssertEqual(m.examples(among: ["a", "b"]).map(\.key), ["b"])
    }

    func testRoundTrip() throws {
        var m = RoutingMemory()
        m.add(words: "x y", key: "k", name: "n", source: "sent", at: Date(timeIntervalSince1970: 1_700_000_000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID()).json")
        m.save(url)
        XCTAssertEqual(RoutingMemory.load(url), m)
    }
}
