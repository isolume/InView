import AccessCore
import CoreLocation
import SwiftUI

/// Editing the geographic placement never changes the saved AR coordinates or route.
struct BuildingPlacementView: View {
    let map: VenueMap
    var currentMapPosition: (() -> SIMD2<Float>?)? = nil
    let onSave: (BuildingMapReference) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reference: BuildingMapReference?
    @State private var cameraTarget: MapboxPlacementCameraTarget?
    @State private var heading: Double
    @State private var query = ""
    @State private var searchPresented = false
    @State private var results: PlacementSearchResults?
    @State private var searchTask: Task<Void, Never>?
    @State private var error: String?
    @StateObject private var location = PlacementLocation()

    init(map: VenueMap, currentMapPosition: (() -> SIMD2<Float>?)? = nil,
         onSave: @escaping (BuildingMapReference) throws -> Void) {
        self.map = map
        self.currentMapPosition = currentMapPosition
        self.onSave = onSave
        let existing = map.geographicReference.flatMap { (try? $0.validate()) != nil ? $0 : nil }
        _reference = State(initialValue: existing)
        _heading = State(initialValue: existing?.headingDegrees ?? 0)
        if let existing {
            _cameraTarget = State(initialValue: .init(latitude: existing.latitude, longitude: existing.longitude))
        }
    }

    var body: some View {
        NavigationStack {
            placementMap
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Move and turn the outline to match the building.")
                    HStack {
                        Button("Rotate left", systemImage: "rotate.left") { turn(-15) }.labelStyle(.iconOnly)
                        Slider(value: $heading, in: 0...359)
                            .accessibilityLabel("Building orientation")
                        Button("Rotate right", systemImage: "rotate.right") { turn(15) }.labelStyle(.iconOnly)
                    }
                    if location.isLoading { ProgressView("Finding your location…") }
                    if let message = error ?? location.error {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .background(.regularMaterial)
            }
            .navigationTitle("Place building")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Current location", systemImage: "location.fill") { location.request() }
                        .labelStyle(.iconOnly).disabled(location.isLoading)
                    Button("Done", action: save).disabled(reference == nil)
                }
            }
            .searchable(text: $query, isPresented: $searchPresented, prompt: "Address")
            .onSubmit(of: .search, search)
            .sheet(item: $results) { response in
                NavigationStack {
                    List(response.items.indices, id: \.self) { index in
                        let item = response.items[index]
                        Button {
                            place(at: item.coordinate)
                            results = nil
                            searchPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).foregroundStyle(.primary)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("Search results").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { results = nil } } }
                }
            }
            .onChange(of: heading) { _, value in reference?.headingDegrees = value }
            .onChange(of: location.fix) { _, fix in
                guard let fix else { return }
                var origin = BuildingMapReference(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                                  headingDegrees: heading, horizontalAccuracyM: fix.horizontalAccuracy)
                if let position = currentMapPosition?(), let coordinate = try? origin.coordinate(for: -position) {
                    origin.latitude = coordinate.latitude
                    origin.longitude = coordinate.longitude
                }
                reference = origin
                cameraTarget = .init(latitude: origin.latitude, longitude: origin.longitude)
            }
            .onDisappear { searchTask?.cancel(); location.stop() }
        }
    }

    @ViewBuilder
    private var placementMap: some View {
        if let token = AppConfig.mapboxAccessToken {
            MapboxPlacementCanvas(map: map, reference: $reference, heading: heading,
                                  cameraTarget: cameraTarget, accessToken: token)
        } else {
            ContentUnavailableView {
                Label("Map isn’t connected", systemImage: "map")
            } description: {
                Text("Building placement isn’t available in this build.")
            }
        }
    }

    private func turn(_ change: Double) { heading = (heading + change + 360).truncatingRemainder(dividingBy: 360) }

    private func place(at coordinate: CLLocationCoordinate2D) {
        reference = BuildingMapReference(latitude: coordinate.latitude, longitude: coordinate.longitude, headingDegrees: heading)
        cameraTarget = .init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private func save() {
        guard let reference else { return }
        do { try reference.validate(); try onSave(reference); dismiss() }
        catch { self.error = "Couldn’t save the building’s position. Try again." }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        guard let token = AppConfig.mapboxAccessToken else {
            error = "Address search isn’t connected."
            return
        }
        guard text.count <= 256, !text.contains(";"), text.split(whereSeparator: \.isWhitespace).count <= 20 else {
            error = "Try a shorter address."
            return
        }
        error = nil
        searchTask = Task { @MainActor in
            do {
                let items = try await PlacementGeocoding.search(text, near: reference, accessToken: token)
                try Task.checkCancellation()
                if items.isEmpty { error = "No places found. Try another address." }
                else { results = PlacementSearchResults(items: items) }
            } catch { if !Task.isCancelled { self.error = "Search is unavailable. Try again when you’re connected." } }
        }
    }
}

private struct PlacementSearchResults: Identifiable {
    let id = UUID()
    let items: [PlacementSearchItem]
}

private struct PlacementSearchItem {
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
}

/// The chosen coordinate is saved with the scan, so request permanent geocoding.
/// Address text and account tokens never enter logs or saved map metadata.
private enum PlacementGeocoding {
    static func search(_ query: String, near reference: BuildingMapReference?, accessToken: String) async throws -> [PlacementSearchItem] {
        var components = URLComponents(string: "https://api.mapbox.com/search/geocode/v6/forward")!
        var parameters = [URLQueryItem(name: "q", value: query),
                          URLQueryItem(name: "access_token", value: accessToken),
                          URLQueryItem(name: "permanent", value: "true"),
                          URLQueryItem(name: "autocomplete", value: "false"),
                          URLQueryItem(name: "limit", value: "5"),
                          URLQueryItem(name: "types", value: "address,street,place,locality,neighborhood")]
        if let reference {
            parameters.append(.init(name: "proximity", value: "\(reference.longitude),\(reference.latitude)"))
        }
        components.queryItems = parameters
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let collection = try JSONDecoder().decode(Response.self, from: data)
        return collection.features.compactMap { feature in
            let position = feature.properties.coordinates
            guard position.latitude.isFinite, position.longitude.isFinite,
                  (-90...90).contains(position.latitude), (-180...180).contains(position.longitude) else { return nil }
            return PlacementSearchItem(name: feature.properties.namePreferred ?? feature.properties.name ?? "Location",
                                       subtitle: feature.properties.placeFormatted ?? "",
                                       coordinate: CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude))
        }
    }

    private struct Response: Decodable { let features: [ResultFeature] }
    private struct ResultFeature: Decodable { let properties: Properties }
    private struct Properties: Decodable {
        let name: String?
        let namePreferred: String?
        let placeFormatted: String?
        let coordinates: Position
        enum CodingKeys: String, CodingKey {
            case name, coordinates
            case namePreferred = "name_preferred"
            case placeFormatted = "place_formatted"
        }
    }
    private struct Position: Decodable { let longitude: Double; let latitude: Double }
}

@MainActor
private final class PlacementLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var fix: CLLocation?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private let manager = CLLocationManager()
    private var requested = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func request() {
        requested = true
        error = nil
        isLoading = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: finishWithError("Location is unavailable. Search for the building instead.")
        }
    }

    func stop() { requested = false; isLoading = false; manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requested else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .restricted, .denied: finishWithError("Location is unavailable. Search for the building instead.")
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard requested else { return }
        guard let fresh = locations.last, fresh.horizontalAccuracy >= 0, fresh.horizontalAccuracy <= 100,
              abs(fresh.timestamp.timeIntervalSinceNow) < 15 else {
            finishWithError("Couldn’t get a recent location. Search for the building instead.")
            return
        }
        fix = fresh
        stop()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard requested else { return }
        finishWithError("Couldn’t find your location. Search for the building instead.")
    }

    private func finishWithError(_ message: String) { error = message; stop() }
}
