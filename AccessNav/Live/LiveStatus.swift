import AccessCore
import Combine
import Foundation

/// Polls the server for which access points the crew has reported out of service.
@MainActor
final class LiveStatus: ObservableObject {
    @Published private(set) var statuses: [UUID: PointStatus] = [:]
    @Published private(set) var isReachable = false

    var isConfigured: Bool { client != nil }

    var outOfService: Set<UUID> {
        Set(statuses.values.filter { $0.state == .outOfService }.map(\.pointId))
    }

    private static let pollInterval: TimeInterval = 2

    private let client = ServerClient()
    private var timer: Timer?
    private var isFetching = false

    func start() {
        guard client != nil, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let client, !isFetching else { return }
        isFetching = true
        Task { [weak self] in
            let result = try? await client.statuses()
            guard let self else { return }
            self.isFetching = false
            self.isReachable = result != nil
            guard let result else { return }
            let latest = Dictionary(result.map { ($0.pointId, $0) }, uniquingKeysWith: { $0.reportedAt > $1.reportedAt ? $0 : $1 })
            if latest != self.statuses { self.statuses = latest }
        }
    }
}
