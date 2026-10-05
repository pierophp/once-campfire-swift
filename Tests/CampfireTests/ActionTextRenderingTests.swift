import Foundation
import XCTest
@testable import CampfireCore

final class ActionTextRenderingTests: XCTestCase {
    private struct Corpus: Decodable {
        let cases: [Case]
        let users: [User]
        struct User: Decodable {
            let id: Int
            let name: String
            let title: String
            let attachableGlobalID: String
            let userPath: String
            let avatarPath: String
            enum CodingKeys: String, CodingKey { case id, name, title; case attachableGlobalID = "attachable_sgid"; case userPath = "user_path"; case avatarPath = "avatar_path" }
            var mentionUser: ActionTextMentionUser { ActionTextMentionUser(id: id, name: name, title: title, attachableGlobalID: attachableGlobalID, path: userPath, avatarPath: avatarPath) }
        }
        struct Case: Decodable {
            let name: String
            let body: String
            let presentation: Outcome
            let plainText: Outcome
            enum CodingKeys: String, CodingKey { case name, body, presentation; case plainText = "plain_text" }
        }
        struct Outcome: Decodable { let ok: String? }
    }

    func testPresentationAndPlainTextMatchRailsReferenceVectors() throws {
        let corpus = try corpus()
        let renderer = try referenceRenderer(corpus)

        for vector in corpus.cases where vector.name != "lexxy mention" && vector.plainText.ok != nil {
            XCTAssertEqual(renderer.render(vector.body), vector.presentation.ok, vector.name)
            XCTAssertEqual(renderer.plainText(vector.body), vector.plainText.ok, vector.name)
        }
    }

    func testMentionRequiresAValidSignedGlobalIDAndMatchesRailsReference() throws {
        let reference = try corpus()
        let renderer = try referenceRenderer(reference)
        let vector = try XCTUnwrap(reference.cases.first(where: { $0.name == "lexxy mention" }))

        XCTAssertEqual(renderer.plainText(vector.body), vector.plainText.ok)
        XCTAssertEqual(renderer.render(vector.body), vector.presentation.ok)
        let deleted = try XCTUnwrap(reference.cases.first(where: { $0.name == "sgid deleted user" }))
        XCTAssertEqual(renderer.plainText(deleted.body), deleted.plainText.ok)
        XCTAssertEqual(renderer.render(deleted.body), deleted.presentation.ok)
    }

    private func referenceRenderer(_ corpus: Corpus) throws -> ActionTextRenderer {
        let railsData = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "rails_compat", withExtension: "json", subdirectory: "Fixtures")))
        let rails = try XCTUnwrap(JSONSerialization.jsonObject(with: railsData) as? [String: Any])
        let secret = try XCTUnwrap(rails["secret_key_base"] as? String)
        let resolver = TestMentionResolver(users: Dictionary(uniqueKeysWithValues: corpus.users.map { ($0.id, $0.mentionUser) }))
        return ActionTextRenderer(secretKeyBase: secret, userResolver: resolver, now: { "2026-10-05T12:00:00.000Z" })
    }

    private func corpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "action_text_reference", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    func testRenderingDropsUnsafeAttributesAndStylesAtThePublicSeam() {
        let renderer = ActionTextRenderer()
        let html = renderer.render(#"<p><a name="body" href="javascript:alert(1)">link</a> <span style="color: red; background-image: url(javascript:alert(2))">text</span></p>"#)
        XCTAssertFalse(html.contains("name="))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertFalse(html.contains("style="))
        XCTAssertTrue(html.contains("<a>link</a>"))
        XCTAssertTrue(html.contains("<span>text</span>"))
    }

    func testMalformedAndOverDeepMarkupFallBackWithoutCrashing() {
        let renderer = ActionTextRenderer()
        XCTAssertEqual(renderer.render(String(repeating: "<b>", count: 401) + "deep"), "")
        XCTAssertEqual(renderer.render(String(repeating: "<b>", count: 600) + "deep"), "")
        XCTAssertEqual(renderer.plainText(String(repeating: "<b>", count: 401) + "deep"), "")
    }
}

private struct TestMentionResolver: ActionTextUserResolving {
    let users: [Int: ActionTextMentionUser]
    func user(id: Int) -> ActionTextMentionUser? { users[id] }
}
