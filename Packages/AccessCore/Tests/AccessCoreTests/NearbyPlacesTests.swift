import Foundation
import Testing
@testable import AccessCore

/// Captured from `POST /scans/synthetic-walk/nearby` on a worker-processed scan, plus an upper-floor
/// place, an unreachable connector and a malformed entry.
private let nearbyJSON = Data(#"""
{"bearing_reference":"true_north","notices":["This scan's navigation graph has not been reviewed."],"results":[{"accessible_route":"none","bearing_deg":248.199,"category":"entrance","compass":"W","detail":{"access_point_kind":"destination","confidence":0.6},"distance_m":0.539,"id":"place:synthetic-walk:place-entrance-61e55a942d","kind":"place","level_delta":0,"level_id":"L0","lon_lat":[-84.39632161434713,33.7755892202159],"name":"Entrance","position_m":[1.2,0.0,2.0],"reachable":true,"refs":{"place_id":"place-entrance-61e55a942d","scan_id":"synthetic-walk"},"relative_direction":"behind","route_to":{"place_id":"place-entrance-61e55a942d"},"scan_id":"synthetic-walk","walking_distance_m":0.591,"walking_duration_s":0.493},{"accessible_route":"accessible","bearing_deg":56.327,"category":"room","compass":"NE","detail":{"access_point_kind":"destination","confidence":0.67},"distance_m":1.811,"id":"place:synthetic-walk:place-room-d9ac8e80fe","kind":"place","level_delta":0,"level_id":"L0","lon_lat":[-84.39629992434978,33.775600035932605],"name":"Room","position_m":[-0.004,0.0,-0.007],"reachable":true,"refs":{"place_id":"place-room-d9ac8e80fe","scan_id":"synthetic-walk"},"relative_direction":"left","route_to":{"place_id":"place-room-d9ac8e80fe"},"scan_id":"synthetic-walk","walking_distance_m":1.931,"walking_duration_s":1.61},{"accessible_route":"accessible","bearing_deg":74.13,"category":"exit","compass":"E","detail":{"access_point_kind":"destination","confidence":0.7},"distance_m":3.639,"id":"place:synthetic-walk:place-exit-0860a38e69","kind":"place","level_delta":0,"level_id":"L0","lon_lat":[-84.39627838565286,33.775599955084225],"name":"EXIT","position_m":[0.005,2.0,-2.0],"reachable":true,"refs":{"place_id":"place-exit-0860a38e69","scan_id":"synthetic-walk"},"relative_direction":"ahead","route_to":{"place_id":"place-exit-0860a38e69"},"scan_id":"synthetic-walk","walking_distance_m":3.923,"walking_duration_s":3.27},{"accessible_route":"unverified","bearing_deg":278.5,"category":"restaurant","compass":"W","distance_m":3.2,"id":"place:synthetic-walk:mcd","kind":"place","level_delta":1,"level_id":"L1","name":"McDonald's","position_m":[0.0,3.5,-1.5],"reachable":true,"refs":{"place_id":"mcd","scan_id":"synthetic-walk"},"relative_direction":"left","route_to":{"place_id":"mcd"},"scan_id":"synthetic-walk","serves_level_ids":[],"walking_distance_m":15.4,"walking_duration_s":24.0},{"accessible_route":"none","bearing_deg":30.0,"category":"elevator","compass":"NE","distance_m":8.4,"id":"connector:synthetic-walk:connector-000@n1","kind":"connector","level_delta":0,"level_id":"L0","position_m":[4.0,0.0,-3.0],"reachable":false,"refs":{"connector_id":"connector-000","scan_id":"synthetic-walk"},"route_to":{"node_id":"synthetic-walk:n1"},"scan_id":"synthetic-walk","serves_level_ids":["L0","L1"]},{"category":"room","distance_m":1,"id":"broken","kind":"place","level_id":"L0","position_m":[1,2],"scan_id":"x"}],"scope":{"scan_id":"synthetic-walk"},"total_matches":6}
"""#.utf8)

private final class NearbyMockProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        Self.lastBody = body
        let (status, data) = Self.responder?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                           headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct NearbyPlacesTests {
    private func client() -> (BackendClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NearbyMockProtocol.self]
        let session = URLSession(configuration: config)
        return (BackendClient(baseURL: URL(string: "http://backend.invalid")!, session: session), session)
    }

    @Test func decodesTheServerResponseAndSkipsMalformedResults() throws {
        let results = try JSONDecoder().decode(NearbyResults.self, from: nearbyJSON)
        #expect(results.bearingReference == "true_north")
        #expect(!results.results.contains { $0.id == "broken" })
        let entrance = try #require(results.results.first { $0.title == "Entrance" })
        #expect(entrance.sourceID == "place-entrance-61e55a942d")
        #expect(entrance.position == SIMD3(1.2, 0, 2))
        #expect(entrance.reachable)
        #expect(entrance.relativeDirection == "behind")
        let mcd = try #require(results.results.first { $0.title == "McDonald's" })
        #expect(mcd.levelDelta == 1)
        #expect(mcd.summary == "1 floor up · 15 m · Left")
        let elevator = try #require(results.results.first { $0.category == "elevator" })
        #expect(elevator.title == "Elevator")
        #expect(elevator.servesLevelIDs == ["L0", "L1"])
        #expect(elevator.summary == "Not connected · 8 m away · NE")
        // Elevator at (4, -3): facing −z from (4, 0) it is ahead; facing +x it is to the left.
        #expect(elevator.relativeDirection(from: SIMD2(4, 0), headingRadians: 0) == "ahead")
        #expect(elevator.relativeDirection(from: SIMD2(4, 0), headingRadians: .pi / 2) == "left")
        #expect(elevator.relativeDirection(from: SIMD2(4, 0), headingRadians: .pi) == "behind")
        #expect(elevator.relativeDirection(from: SIMD2(4, -3), headingRadians: 0) == nil)
        #expect(mcd.summary(direction: "right") == "1 floor up · 15 m · Right")
    }

    @Test func pinsOnlyThisFloorAndNeverDuplicateKeptPlaces() throws {
        let results = try JSONDecoder().decode(NearbyResults.self, from: nearbyJSON)
        let pins = results.pins(scanID: "synthetic-walk", excluding: [])
        #expect(!pins.contains { $0.name == "McDonald's" }, "another floor is listed, not pinned")
        let entrance = try #require(pins.first { $0.name == "Entrance" })
        // Same ID the scan review gives a kept analysis place, so the two never both appear.
        #expect(entrance.id == AccessPoint.detectedID(scanID: "synthetic-walk", placeID: "place-entrance-61e55a942d"))
        #expect(entrance.position == SIMD3(1.2, 0, 2))
        #expect(pins.first { $0.name == "Elevator" }?.kind == .elevator)
        let kept = results.pins(scanID: "synthetic-walk", excluding: [entrance])
        #expect(!kept.contains { $0.id == entrance.id })
        #expect(kept.count == pins.count - 1)
    }

    @Test func encodesTheSearchTheServerExpects() throws {
        let search = NearbySearch(origin: SIMD3(1, 0, 1.5), query: "  mcdonalds  ", radiusMeters: 9000, limit: 500,
                                  headingDegrees: 90)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(search)) as? [String: Any])
        #expect((object["at"] as? [String: Any])?["position_m"] as? [Double] == [1, 0, 1.5])
        #expect(object["query"] as? String == "mcdonalds")
        #expect(object["radius_m"] as? Double == 5000)
        #expect(object["limit"] as? Int == 100)
        #expect(object["heading_degrees"] as? Double == 90)
        let blank = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(NearbySearch(origin: .zero, query: " "))) as? [String: Any])
        #expect(blank["query"] == nil)
    }

    @Test func clientPostsTheSearchAndTreatsUnprocessedScansAsEmpty() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        NearbyMockProtocol.responder = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/scans/synthetic-walk/nearby")
            return (200, nearbyJSON)
        }
        let found = try await client.nearby(scanID: "synthetic-walk", search: NearbySearch(origin: SIMD3(1, 0, 1.5)))
        #expect(found?.results.isEmpty == false)
        let sent = try #require(NearbyMockProtocol.lastBody)
        #expect(String(decoding: sent, as: UTF8.self).contains("position_m"))

        NearbyMockProtocol.responder = { _ in
            (409, Data(#"{"error":{"code":"navigation_data_missing","message":"Process it first."}}"#.utf8))
        }
        #expect(try await client.nearby(scanID: "fresh", search: NearbySearch(origin: .zero)) == nil)

        NearbyMockProtocol.responder = { _ in (503, Data(#"{"error":{"code":"busy","message":"Busy."}}"#.utf8)) }
        await #expect(throws: BackendClientError.self) {
            try await client.nearby(scanID: "fresh", search: NearbySearch(origin: .zero))
        }
        await #expect(throws: BackendClientError.self) {
            try await client.nearby(scanID: "x", search: NearbySearch(origin: SIMD3(.nan, 0, 0)))
        }
    }
}
