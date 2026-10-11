import AccessCore
import Foundation
import simd

/// Keeps the 3D map's live pins in step with the scan server's nearby search: what is around the
/// person (or the scan start) on a saved, processed scan, positioned in the map's own coordinates.
@MainActor
final class LivePlaceSearch: ObservableObject {
    /// Server results in rank order, every floor (other floors are listed, not pinned).
    @Published private(set) var results: [NearbyPlace] = []
    /// Pins for the current floor, excluding places already on the saved map.
    @Published private(set) var pins: [AccessPoint] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    /// The query the current results answer (trimmed; empty when browsing).
    @Published private(set) var answeredQuery: String?

    /// Refresh when the person has moved this far since the last search.
    static let refreshDistance: Float = 3
    private static let debounce: Duration = .milliseconds(350)

    private struct Key: Equatable {
        var scanID: String
        var query: String
        var origin: SIMD3<Float>
    }

    private var lastKey: Key?
    private var task: Task<Void, Never>?
    private var resultsByPin: [UUID: NearbyPlace] = [:]

    /// The server result behind a live pin, for distances and directions in place rows.
    func result(for pin: AccessPoint) -> NearbyPlace? { resultsByPin[pin.id] }

    /// Searches around `origin` unless an equivalent search already answered. Pass a nil scan ID to clear.
    func update(scanID: String?, origin: SIMD3<Float>, query: String, existing: [AccessPoint]) {
        guard let scanID, let baseURL = AppConfig.backendURL else {
            clear()
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Key(scanID: scanID, query: trimmed, origin: origin)
        if let lastKey, lastKey.scanID == key.scanID, lastKey.query == key.query,
           simd_distance(lastKey.origin, key.origin) < Self.refreshDistance {
            // Same search: only re-filter against the saved map, which may have gained places.
            // Positions arrive every frame, so publish only when something actually changed.
            let kept = pins.filter { pin in !existing.contains { $0.id == pin.id } }
            if kept.count != pins.count { pins = kept }
            return
        }
        task?.cancel()
        let typing = lastKey?.query != key.query && lastKey?.scanID == key.scanID
        lastKey = key
        isLoading = true
        task = Task { [weak self] in
            if typing { try? await Task.sleep(for: Self.debounce) }
            guard !Task.isCancelled else { return }
            let client = BackendClient(baseURL: baseURL, accessToken: AppConfig.backendToken)
            do {
                let found = try await client.nearby(scanID: scanID,
                                                    search: NearbySearch(origin: origin, query: trimmed))
                guard !Task.isCancelled, let self else { return }
                self.apply(found, scanID: scanID, existing: existing)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoading = false
                self.message = error.localizedDescription
                // Retry the same search on the next update rather than caching a failure.
                self.lastKey = nil
            }
        }
    }

    func clear() {
        // Called on every position update when there's nothing to search; writing equal values
        // would still redraw the whole map screen each time.
        guard lastKey != nil || task != nil || !results.isEmpty || !pins.isEmpty || isLoading
            || message != nil || answeredQuery != nil else { return }
        task?.cancel()
        task = nil
        lastKey = nil
        results = []; pins = []; resultsByPin = [:]
        isLoading = false; message = nil; answeredQuery = nil
    }

    private func apply(_ found: NearbyResults?, scanID: String, existing: [AccessPoint]) {
        isLoading = false
        answeredQuery = lastKey?.query
        guard let found else {
            results = []; pins = []; resultsByPin = [:]
            message = "Nearby places appear after this scan is processed. Use Find places when reviewing a scan."
            return
        }
        results = found.results
        pins = found.pins(scanID: scanID, excluding: existing)
        var byPin: [UUID: NearbyPlace] = [:]
        for result in found.results { byPin[result.accessPoint(scanID: scanID).id] = result }
        resultsByPin = byPin
        message = found.results.isEmpty ? nil : found.notices.first { $0.contains("from the mapped paths") }
    }
}
