import AccessCore
import SwiftUI

/// Building connections have their own floor frames. Show explicit transitions rather
/// than drawing an invented line between two independently scanned maps.
struct BuildingDirectionsView: View {
    let venueID: String
    let graphID: String
    let buildingName: String
    var baseURL: URL? = nil
    var isDemo = false

    @AppStorage("navigation.routePreference") private var savedPreference = RoutePreference.stepFree.rawValue
    @State private var demoPreference = RoutePreference.stepFree
    @State private var graph: BuildingRouteGraph?
    @State private var route: BuildingRoute?
    @State private var from = ""
    @State private var to = ""
    @State private var message: String?
    @State private var isLoading = false
    @State private var isRouting = false
    @State private var routeTask: Task<Void, Never>?
    @State private var generation = 0
    @State private var hasRequestedRoute = false
    @State private var needsGraphRefresh = false
    @Environment(\.dismiss) private var dismiss

    private var preference: RoutePreference {
        isDemo ? demoPreference : RoutePreference(rawValue: savedPreference) ?? .stepFree
    }

    private var selection: Binding<RoutePreference> {
        Binding(get: { preference }, set: {
            if isDemo { demoPreference = $0 } else { savedPreference = $0.rawValue }
        })
    }

    private var places: [BuildingRouteNode] {
        graph?.nodes.filter { !($0.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) } ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                if isDemo {
                    Section {
                        Label("Example building", systemImage: "play.rectangle")
                        Text("Try both route options for the same destination.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section { RoutePreferencePicker(selection: selection) }
                if isLoading {
                    Section { ProgressView("Loading building directions…") }
                } else if graph != nil, places.count >= 2 {
                    Section {
                        Picker("From", selection: $from) {
                            ForEach(places) { node in Text(placeTitle(node)).tag(node.id) }
                        }
                        Picker("To", selection: $to) {
                            ForEach(places) { node in Text(placeTitle(node)).tag(node.id) }
                        }
                        Button("Find route", systemImage: "arrow.triangle.turn.up.right.diamond") { findRoute() }
                            .disabled(from.isEmpty || to.isEmpty || from == to || isRouting)
                    }
                }
                if isRouting {
                    Section { ProgressView("Finding a route…") }
                } else if let route {
                    Section {
                        Label("About \(duration(route.estimatedSeconds)) · \(preference.title)",
                              systemImage: preference == .stepFree ? "figure.roll" : "figure.walk")
                            .font(.headline)
                        ForEach(Array(route.segments.enumerated()), id: \.offset) { index, segment in
                            routeRow(segment, number: index + 1)
                        }
                    } header: {
                        Text("Directions")
                    } footer: {
                        Text("Travel time is an estimate. Check signs and current availability as you go.")
                    }
                }
                if let message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if needsGraphRefresh {
                            Button("Refresh directions") { Task { await load() } }
                        } else if graph == nil {
                            Button("Try again") { Task { await load() } }
                        } else if hasRequestedRoute {
                            Button("Try again") { findRoute() }
                        }
                    }
                }
            }
            .navigationTitle("Between floors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await load() }
        .onChange(of: preference) { _, _ in selectionChanged() }
        .onChange(of: from) { _, _ in selectionChanged() }
        .onChange(of: to) { _, _ in selectionChanged() }
        .onDisappear { generation += 1; routeTask?.cancel(); isLoading = false }
    }

    private func client() throws -> BuildingRouteClient {
        if let baseURL { return try BuildingRouteClient(baseURL: baseURL) }
        return try BuildingRouteClient()
    }

    @MainActor private func load() async {
        guard !isLoading else { return }
        generation += 1
        let requestID = generation
        routeTask?.cancel()
        isLoading = true
        isRouting = false
        hasRequestedRoute = false
        needsGraphRefresh = false
        graph = nil
        route = nil
        message = nil
        needsGraphRefresh = false
        do {
            let loaded = try await client().loadGraph(graphID: graphID, venueID: venueID, allowDemo: isDemo)
            guard !Task.isCancelled, requestID == generation else { return }
            graph = loaded
            from = places.first?.id ?? ""
            to = places.last?.id ?? ""
            if places.count < 2 { message = "More destinations need to be mapped before building directions are available." }
        } catch {
            guard !Task.isCancelled, requestID == generation else { return }
            if case BuildingRouteClientError.graphUnavailable = error {
                message = "Directions between floors aren’t available for \(buildingName) yet. You can still explore each floor."
            } else { message = error.localizedDescription }
        }
        isLoading = false
    }

    @MainActor private func selectionChanged() {
        // Loading the building is independent of a user's route choice.
        guard !isLoading, places.count >= 2 else { return }
        let shouldRecalculate = hasRequestedRoute
        generation += 1
        routeTask?.cancel()
        route = nil
        isRouting = false
        if graph != nil { message = nil }
        if shouldRecalculate { findRoute() }
    }

    @MainActor private func findRoute() {
        generation += 1
        routeTask?.cancel()
        route = nil
        message = nil
        guard let graph, from != to, !from.isEmpty, !to.isEmpty else { isRouting = false; return }
        hasRequestedRoute = true
        isRouting = true
        let requestID = generation
        let start = from, destination = to, choice = preference
        routeTask = Task {
            do {
                let result = try await client().route(graph: graph, from: start, to: destination, preference: choice)
                guard !Task.isCancelled, requestID == generation else { return }
                route = result
                isRouting = false
            } catch {
                guard !Task.isCancelled, requestID == generation else { return }
                message = error.localizedDescription
                if error is BuildingRouteError {
                    needsGraphRefresh = true
                } else if let error = error as? BuildingRouteClientError {
                    switch error {
                    case .invalidResponse, .graphUnavailable: needsGraphRefresh = true
                    default: break
                    }
                }
                isRouting = false
            }
        }
    }

    private func routeRow(_ segment: BuildingRouteSegment, number: Int) -> some View {
        let destination = graph?.node(id: segment.to)
        let title: String
        let symbol: String
        switch segment.geometry {
        case .surface(_, _, let points):
            let meters = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
                total + sqrt(pow(pair.1.x - pair.0.x, 2) + pow(pair.1.y - pair.0.y, 2) + pow(pair.1.z - pair.0.z, 2))
            }
            title = "Continue \(Int(meters.rounded())) m to \(destination?.label ?? "the next connection")"
            symbol = "arrow.up"
        case .transition(_, let kind, _):
            title = "Take the \(kind.title.lowercased()) to \(floorTitle(segment.toFloorID) ?? destination?.label ?? "the next floor")"
            switch kind {
            case .elevator: symbol = "arrow.up.arrow.down"
            case .stairs: symbol = "figure.stairs"
            case .escalator: symbol = "figure.stair.stepper"
            case .ramp: symbol = "figure.roll"
            }
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(Color.accentColor)
            Text(title).font(.subheadline)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number). \(title)")
    }

    private func placeTitle(_ node: BuildingRouteNode) -> String {
        guard let floor = floorTitle(node.floorID) else { return node.label ?? "Mapped location" }
        return "\(node.label ?? "Mapped location") · \(floor)"
    }

    private func floorTitle(_ id: String) -> String? {
        switch id.lowercased() {
        case "ground": return "Ground floor"
        case "upper": return "Upper floor"
        case "basement": return "Basement"
        default:
            if let level = Int(id), (-20...200).contains(level) { return "Floor \(level)" }
            return nil
        }
    }

    private func duration(_ seconds: Double) -> String {
        if seconds >= 86_400 { return "over a day" }
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) sec" }
        return "\(Int((seconds / 60).rounded(.up))) min"
    }
}

#if DEBUG && targetEnvironment(simulator)
struct BuildingDirectionsPreview: View {
    var body: some View {
        BuildingDirectionsView(venueID: "demo-building", graphID: "demo-building", buildingName: "Example building",
                               baseURL: URL(string: "http://127.0.0.1:18763"), isDemo: true)
    }
}
#endif
