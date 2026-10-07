import XCTest
@testable import DeviceHubProKit

final class SavedLibraryTests: XCTestCase {
    private func temporaryFile() -> LibraryFile {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedLibraryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return LibraryFile(url: folder.appendingPathComponent("library.json"))
    }

    // MARK: Named library rules

    func testNamesStayUniqueIgnoringCase() {
        var library = NamedLibrary<SavedPush>()
        library.add(SavedPush(name: "Order", bundleIdentifier: "a", payload: "{}"))
        let second = library.add(SavedPush(name: "order", bundleIdentifier: "a", payload: "{}"))
        XCTAssertEqual(second.name, "order 2")
        XCTAssertFalse(library.isNameAvailable("  ORDER "))
        XCTAssertFalse(library.isNameAvailable("   "))
    }

    func testRenameDuplicateAndDelete() throws {
        var library = NamedLibrary<SavedPush>()
        let one = library.add(SavedPush(name: "One", bundleIdentifier: "a", payload: "{}"))
        let two = library.add(SavedPush(name: "Two", bundleIdentifier: "a", payload: "{}"))
        XCTAssertFalse(library.rename(id: two.id, to: "one"))
        XCTAssertTrue(library.rename(id: two.id, to: " Deux "))
        XCTAssertEqual(library.item(id: two.id)?.name, "Deux")

        let copy = try XCTUnwrap(library.duplicate(id: one.id))
        XCTAssertEqual(copy.name, "One copy")
        XCTAssertNotEqual(copy.id, one.id)
        XCTAssertEqual(library.items.map(\.name), ["One", "One copy", "Deux"])
        let again = try XCTUnwrap(library.duplicate(id: one.id))
        XCTAssertEqual(again.name, "One copy 2")

        XCTAssertTrue(library.delete(id: one.id))
        XCTAssertFalse(library.delete(id: one.id))
        XCTAssertNil(library.item(id: one.id))
    }

    func testUpdateKeepsPositionAndRefusesAClashingName() {
        var library = NamedLibrary<SavedLink>()
        let a = library.add(SavedLink(name: "A", url: "x://a"))
        library.add(SavedLink(name: "B", url: "x://b"))
        var edited = a
        edited.url = "x://changed"
        edited.name = "b"
        XCTAssertTrue(library.update(edited))
        XCTAssertEqual(library.items.first?.url, "x://changed")
        XCTAssertEqual(library.items.first?.name, "A")
    }

    // MARK: Persistence

    func testPushLibraryRoundTripsThroughTheFile() {
        let file = temporaryFile()
        let items = [
            SavedPush(name: "Alert", bundleIdentifier: "com.example.app", payload: "{\"aps\":{\"alert\":\"Hi\"}}"),
            SavedPush(name: "Badge", bundleIdentifier: "", payload: "{\"aps\":{\"badge\":1}}"),
        ]
        XCTAssertTrue(file.save(items))
        XCTAssertEqual(file.load(SavedPush.self), items)
    }

    func testAMissingOrCorruptFileLoadsEmptyAndABadEntryIsDropped() throws {
        let file = temporaryFile()
        XCTAssertEqual(file.load(SavedLink.self), [])
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        XCTAssertEqual(file.load(SavedLink.self), [])

        let good = SavedLink(name: "Good", url: "myapp://x", group: "myapp")
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        try Data("{\"schema\":1,\"items\":[{\"name\":5},\(goodJSON)]}".utf8).write(to: file.url)
        XCTAssertEqual(file.load(SavedLink.self), [good])
    }

    // MARK: Templates and payload text

    func testEveryBuiltInTemplateIsAValidPayloadWithItsMarker() throws {
        XCTAssertEqual(PushTemplate.builtIn.count, 6)
        XCTAssertEqual(Set(PushTemplate.builtIn.map(\.id)).count, 6)
        for template in PushTemplate.builtIn {
            _ = try SimulatorPushPayload(template.payload)
            let object = try JSONSerialization.jsonObject(with: Data(template.payload.utf8)) as? [String: Any]
            let aps = try XCTUnwrap(object?["aps"] as? [String: Any])
            switch template.id {
            case "silent":
                XCTAssertEqual(aps["content-available"] as? Int, 1)
                XCTAssertNil(aps["alert"])
            case "rich":
                XCTAssertEqual(aps["mutable-content"] as? Int, 1)
                XCTAssertNotNil(aps["category"])
            case "badge": XCTAssertNotNil(aps["badge"])
            case "sound": XCTAssertEqual(aps["sound"] as? String, "default")
            case "title-subtitle-body":
                let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
                XCTAssertNotNil(alert["title"])
                XCTAssertNotNil(alert["subtitle"])
                XCTAssertNotNil(alert["body"])
            default: XCTAssertNotNil(aps["alert"])
            }
        }
    }

    func testSmartQuotesAreStraightenedAndBadJSONNamesItsProblem() {
        let curly = "{ \u{201C}aps\u{201D}: { \u{201C}badge\u{201D}: 1 } }"
        XCTAssertNotNil(PushPayloadText.problem(in: curly))
        XCTAssertNil(PushPayloadText.problem(in: PushPayloadText.straightened(curly)))
        XCTAssertEqual(PushPayloadText.problem(in: "{}"), "\(SimulatorPushPayload.Problem.missingAPS)")
        XCTAssertEqual(PushPayloadText.problem(in: ""), "\(SimulatorPushPayload.Problem.empty)")
    }

    // MARK: Links

    func testSuggestedGroupIsTheSchemeOfADeepLinkOnly() {
        XCTAssertEqual(SavedLink.suggestedGroup(for: "MyApp://open?x=1"), "myapp")
        XCTAssertNil(SavedLink.suggestedGroup(for: "https://example.com"))
        XCTAssertNil(SavedLink.suggestedGroup(for: "no scheme"))
        XCTAssertNil(SavedLink.suggestedGroup(for: ":x"))
    }

    func testSectionsSortGroupsAndPutUngroupedLast() {
        let links = [
            SavedLink(name: "1", url: "u", group: "zeta"),
            SavedLink(name: "2", url: "u"),
            SavedLink(name: "3", url: "u", group: "alpha"),
            SavedLink(name: "4", url: "u", group: "zeta"),
        ]
        let sections = SavedLink.sections(links)
        XCTAssertEqual(sections.map(\.group), ["alpha", "zeta", nil])
        XCTAssertEqual(sections[1].links.map(\.name), ["1", "4"])
    }
}
