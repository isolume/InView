import Foundation
import Testing
@testable import AccessCore

struct Auth0SettingsTests {
    private let clientID = "fzUUl4rl0YTRzUGLhdGe6uMp4Ue55Nfx"

    @Test func sharedBuildDefaultsKeepPasswordOnlySignIn() throws {
        let defaults = try configAssignments("App.xcconfig")
        for key in ["INVIEW_AUTH0_DOMAIN", "INVIEW_AUTH0_CLIENT_ID", "INVIEW_AUTH0_CALLBACK_URL"] {
            #expect(try #require(defaults[key]).isEmpty, "Shared default must not enable Auth0: \(key)")
        }
        // AppConfig passes these values to Auth0Settings; the account UI uses nil for legacy login.
        #expect(settings(from: defaults) == nil)
    }

    @Test func explicitExampleOverridesEnableAuth0SignIn() throws {
        let defaults = try configAssignments("App.xcconfig")
        let example = try configAssignments("Secrets.example.xcconfig", uncommentAuth0: true)
        let configured = defaults.merging(example) { _, override in override }
        let settings = try #require(self.settings(from: configured))
        #expect(settings.domain == "inview.us.auth0.com")
        #expect(settings.clientID == clientID)
        #expect(settings.callbackURL.absoluteString == "inview://inview.us.auth0.com/ios/com.inview.InView/callback")
        // Merely copying the example without opting in must leave password login available.
        let unchanged = defaults.merging(try configAssignments("Secrets.example.xcconfig")) { _, override in override }
        #expect(self.settings(from: unchanged) == nil)
    }

    private func settings(from values: [String: String]) -> Auth0Settings? {
        Auth0Settings(domain: values["INVIEW_AUTH0_DOMAIN"], clientID: values["INVIEW_AUTH0_CLIENT_ID"],
                      callback: values["INVIEW_AUTH0_CALLBACK_URL"], bundleIdentifier: values["PRODUCT_BUNDLE_IDENTIFIER"])
    }

    /// Reads checked-in assignments only: personal Secrets.xcconfig must not influence this regression.
    /// This is not an xcconfig evaluator; the URL escape is the only expansion in these assignments.
    private func configAssignments(_ name: String, uncommentAuth0: Bool = false) throws -> [String: String] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("Config/\(name)"), encoding: .utf8)
        var values: [String: String] = [:]
        for line in source.components(separatedBy: .newlines) {
            var assignment = line.trimmingCharacters(in: .whitespaces)
            if uncommentAuth0, assignment.hasPrefix("// INVIEW_AUTH0_") { assignment.removeFirst(3) }
            guard !assignment.hasPrefix("//"), !assignment.hasPrefix("#"),
                  let separator = assignment.firstIndex(of: "=") else { continue }
            let key = assignment[..<separator].trimmingCharacters(in: .whitespaces)
            values[key] = assignment[assignment.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$()", with: "")
        }
        return values
    }

    @Test func acceptsTheRegisteredCustomSchemeCallback() throws {
        let settings = try #require(Auth0Settings(
            domain: "inview.us.auth0.com", clientID: clientID,
            callback: "inview://inview.us.auth0.com/ios/com.inview.InView/callback"))
        #expect(settings.domain == "inview.us.auth0.com")
        #expect(settings.callbackURL.scheme == "inview")
        #expect(settings.callbackURL.absoluteString == "inview://inview.us.auth0.com/ios/com.inview.InView/callback")
    }

    @Test func tidiesTheDomainAndFallsBackToTheBundleCallback() throws {
        let settings = try #require(Auth0Settings(
            domain: " https://Inview.US.auth0.com/ ", clientID: clientID, bundleIdentifier: "com.vedanta.accessnav"))
        #expect(settings.domain == "inview.us.auth0.com")
        #expect(settings.callbackURL.absoluteString
                == "com.vedanta.accessnav://inview.us.auth0.com/ios/com.vedanta.accessnav/callback")
    }

    @Test func rejectsAnythingHalfConfigured() {
        let callback = "inview://inview.us.auth0.com/ios/com.inview.InView/callback"
        #expect(Auth0Settings(domain: nil, clientID: clientID, callback: callback) == nil)
        #expect(Auth0Settings(domain: "inview.us.auth0.com", clientID: nil, callback: callback) == nil)
        #expect(Auth0Settings(domain: "inview.us.auth0.com", clientID: "short", callback: callback) == nil)
        #expect(Auth0Settings(domain: "localhost", clientID: clientID, callback: callback) == nil)
        #expect(Auth0Settings(domain: "evil.com/path", clientID: clientID, callback: callback) == nil)
        // No callback and no bundle identifier to derive one from.
        #expect(Auth0Settings(domain: "inview.us.auth0.com", clientID: clientID) == nil)
    }

    @Test func refusesCallbacksAWebPageCouldIntercept() {
        let domain = "inview.us.auth0.com"
        for callback in [
            "https://inview.us.auth0.com/ios/com.inview.InView/callback",
            "http://inview.us.auth0.com/ios/com.inview.InView/callback",
            "inview://other.example/ios/com.inview.InView/callback",
            "inview://inview.us.auth0.com/ios/com.inview.InView/other",
            "inview://inview.us.auth0.com/ios/com.inview.InView/callback?x=1",
        ] {
            #expect(Auth0Settings(domain: domain, clientID: clientID, callback: callback) == nil, "\(callback)")
        }
    }
}
