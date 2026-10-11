import Foundation
import Testing
@testable import AccessCore

@Suite struct BackendTransportTests {
    @Test func httpsAlwaysCarriesCredentials() {
        #expect(BackendTransport.allowsCredential(to: URL(string: "https://203.0.113.9")!))
        #expect(BackendTransport.allowsCredential(to: URL(string: "https://scans.example.com/api")!))
    }

    @Test func plainHTTPOnlyOnTheLocalNetwork() {
        for host in ["localhost", "127.0.0.1", "10.0.0.5", "192.168.1.23", "172.16.4.1", "172.31.255.1",
                     "169.254.10.2", "vedantas-macbook.local", "[::1]", "[fe80::1%25en0]", "[fd12::3]"] {
            #expect(BackendTransport.allowsCredential(to: URL(string: "http://\(host):3000")!), "\(host)")
        }
        for host in ["203.0.113.9", "104.238.128.135", "172.32.0.1", "172.15.0.1", "example.com", "8.8.8.8",
                     "192.169.0.1", "[2001:db8::1]"] {
            #expect(!BackendTransport.allowsCredential(to: URL(string: "http://\(host):3000")!), "\(host)")
        }
        #expect(!BackendTransport.allowsCredential(to: URL(string: "ftp://192.168.1.2")!))
    }
}
