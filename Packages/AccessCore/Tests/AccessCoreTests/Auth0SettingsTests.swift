import Foundation
import Testing
@testable import AccessCore

struct Auth0SettingsTests {
    private let clientID = "fzUUl4rl0YTRzUGLhdGe6uMp4Ue55Nfx"

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
