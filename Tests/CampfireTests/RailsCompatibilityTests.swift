import Foundation
import XCTest
import CampfireCore

final class RailsCompatibilityTests: XCTestCase {
    private var rails: [String: Any] {
        get throws { try fixture("rails_compat.json") }
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testKeyGeneratorMatchesRailsGoldenVectors() throws {
        let vectors = try rails
        let generator = RailsKeyGenerator(secretKeyBase: vectors["secret_key_base"] as! String)
        for vector in vectors["key_generator"] as! [[String: Any]] {
            let key = generator.generate(salt: vector["salt"] as! String, length: vector["length"] as! Int)
            XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), vector["key_hex"] as! String)
        }
    }

    func testDerivedKeysRemainIsolatedAcrossGeneratorInstances() throws {
        let vectors = try rails
        let secret = vectors["secret_key_base"] as! String
        let cases = vectors["key_generator"] as! [[String: Any]]
        for _ in 0..<2 {
            for vector in cases.reversed() {
                let salt = vector["salt"] as! String
                let length = vector["length"] as! Int
                let expected = vector["key_hex"] as! String
                let key = RailsKeyGenerator(secretKeyBase: secret).generate(salt: salt, length: length)
                XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), expected)
                if length > 0 {
                    let other = RailsKeyGenerator(secretKeyBase: secret + "-other").generate(salt: salt, length: length)
                    XCTAssertNotEqual(key, other)
                }
            }
        }
    }

    func testSignedCookieReadsAndWritesRailsEnvelope() throws {
        let vectors = try rails
        let secret = vectors["secret_key_base"] as! String
        let key = RailsKeyGenerator(secretKeyBase: secret).generate(salt: "signed cookie", length: 64)
        let verifier = MessageVerifier(secret: key, digest: .sha1)
        let signed = (vectors["signed_cookies"] as! [String: Any])["generate"] as! [[String: Any]]
        let vector = signed[0]
        let raw = verifier.generate(value: vector["value"] as! String, purpose: "cookie.session_token", expiresAt: "2046-01-01T12:00:00.000Z")
        XCTAssertEqual(raw, vector["raw"] as! String)
        XCTAssertEqual(verifier.verify(vector["raw"] as! String, purpose: "cookie.session_token", now: "2026-01-01T12:00:00.000Z"), vector["value"] as? String)
        XCTAssertNil(verifier.verify(vector["raw"] as! String, purpose: "wrong", now: "2026-01-01T12:00:00.000Z"))
        for caseVector in (vectors["signed_cookies"] as! [String: Any])["verify"] as! [[String: Any]] {
            if let expected = caseVector["expected"] as? String {
                XCTAssertEqual(verifier.verifyCookie(caseVector["raw"] as! String, name: caseVector["name"] as! String, now: caseVector["now"] as! String), expected, caseVector["case"] as? String ?? "vector case")
            }
        }
    }

    func testEncryptedCookieDecryptsRailsGoldenVectorAndRoundTrips() throws {
        let vectors = try rails
        let secret = vectors["secret_key_base"] as! String
        let key = RailsKeyGenerator(secretKeyBase: secret).generate(salt: "authenticated encrypted cookie", length: 32)
        let encryptor = MessageEncryptor(key: key)
        let encrypted = (vectors["encrypted_cookies"] as! [String: Any])["generate"] as! [[String: Any]]
        let vector = encrypted[0]
        let raw = vector["raw"] as! String
        let plaintext = try XCTUnwrap(encryptor.decrypt(raw))
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), vector["plaintext"] as? String)
        let parts = raw.components(separatedBy: "--")
        let nonce = try XCTUnwrap(Data(base64Encoded: parts[1]))
        XCTAssertEqual(try encryptor.encrypt(plaintext, nonce: nonce), raw)
        XCTAssertEqual(encryptor.decrypt(try encryptor.encrypt(plaintext)), plaintext)
    }

    func testSignedIdsAndTurboStreamsMatchRailsVectors() throws {
        let vectors = try rails
        let secret = vectors["secret_key_base"] as! String
        let ids = vectors["signed_ids"] as! [String: Any]
        let generatedID = (ids["generate"] as! [[String: Any]])[0]
        let idSigner = RailsSignedID(secretKeyBase: secret)
        XCTAssertEqual(idSigner.generate(model: "User", id: 1, purpose: "avatar"), generatedID["signed_id"] as? String)
        let verifiedID = (ids["verify"] as! [[String: Any]])[0]
        XCTAssertEqual(idSigner.verify(verifiedID["signed_id"] as! String, model: "User", purpose: "avatar", now: verifiedID["now"] as! String), 1)
        let sgid = (vectors["sgids"] as! [String: Any])["generate"] as! [[String: Any]]
        let firstSGID = sgid[0]
        let gidSigner = RailsSignedGlobalID(secretKeyBase: secret)
        XCTAssertEqual(gidSigner.generate(uri: firstSGID["data"] as! String, purpose: firstSGID["purpose"] as! String), firstSGID["sgid"] as? String)
        let sgidVerify = (vectors["sgids"] as! [String: Any])["verify"] as! [[String: Any]]
        let validSGID = sgidVerify[0]
        XCTAssertEqual(gidSigner.locate(validSGID["sgid"] as! String, purpose: validSGID["purpose"] as! String, now: validSGID["now"] as! String), validSGID["expected"] as? String)
        let streams = vectors["turbo_stream_names"] as! [String: Any]
        let generatedStream = (streams["generate"] as! [[String: Any]])[0]
        let streamSigner = RailsTurboStreamSigner(secretKeyBase: secret)
        XCTAssertEqual(streamSigner.sign(generatedStream["stream_name"] as! String), generatedStream["signed"] as? String)
        XCTAssertEqual(streamSigner.verify(generatedStream["signed"] as! String), generatedStream["stream_name"] as? String)
    }

    func testERBEscapingMatchesRubyVectorsAndPreservesPlainText() throws {
        let vectors = try fixture("ruby_core.json")["strings"] as! [[String: Any]]
        for vector in vectors {
            let input = vector["input"] as! String
            XCTAssertEqual(erbEscape(input), vector["html_escape"] as? String)
            XCTAssertEqual(rubyStringToInt(input), vector["to_i"] as? String, "to_i input: \(String(reflecting: input))")
            XCTAssertEqual(rubyStringStrip(input), vector["strip"] as? String, "strip input: \(String(reflecting: input))")

        }
        XCTAssertEqual(erbEscape("plain text"), "plain text")
        XCTAssertEqual(rubyStringToFloat("12.5 items"), "12.5")
        XCTAssertEqual(rubyStringToFloat("5_6.2_5"), "56.25")
        XCTAssertEqual(rubyStringToFloat("1e2"), "100.0")
        XCTAssertEqual(rubyStringToFloat("not a number"), "0.0")
    }

    func testReferenceSessionCookiesVerifyAtTheCookieSeam() throws {
        let vectors = try rails
        let secret = vectors["secret_key_base"] as! String
        let session = vectors["session"] as! [String: Any]
        let key = RailsKeyGenerator(secretKeyBase: secret).generate(salt: "signed cookie", length: 64)
        let verifier = MessageVerifier(secret: key)
        XCTAssertEqual(verifier.verify(session["session_token_raw"] as! String, purpose: "cookie.session_token", now: "2026-01-01T12:00:00.000Z"), session["session_token_value"] as? String)
        let sessionVectors = try fixture("campfire_sessions.json")
        let reference = (sessionVectors["sessions"] as! [[String: Any]])[0]
        XCTAssertEqual(verifier.verify(reference["cookie_value"] as! String, purpose: "cookie.session_token", now: "2026-10-05T12:00:00.000Z"), reference["token"] as? String)
    }

    func testCompatibilitySuiteLoadsSessionAndRouteVectors() throws {
        let sessions = try fixture("campfire_sessions.json")
        let routes = try fixture("campfire_routes.json")
        XCTAssertFalse((sessions["sessions"] as! [[String: Any]]).isEmpty)
        XCTAssertFalse((routes["routes"] as? [[String: Any]] ?? routes["cases"] as? [[String: Any]] ?? []).isEmpty)
    }
}
