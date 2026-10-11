import AccessCore
import Foundation

/// Keeps live location sharing running while the map is open: publishes your own position only while
/// someone you chose can see it, and follows one person who is sharing with you.
@MainActor
final class PeopleLocationService: ObservableObject {
    static let shared = PeopleLocationService()

    /// The person being followed, and their latest position when the server has a fresh one.
    @Published private(set) var followed: PersonMatch?
    @Published private(set) var followedLocation: PersonLocation?
    @Published private(set) var followMessage: String?
    /// Whether anyone can currently see you.
    @Published private(set) var isSharing = false

    private var ownPosition: SharedPosition?
    private var loop: Task<Void, Never>?
    private static let interval: Duration = .seconds(5)
    private static let shareRefreshEvery = 6

    func noteOwnPosition(_ position: SharedPosition?) { ownPosition = position }

    func follow(_ person: PersonMatch) {
        followed = person
        followedLocation = nil
        followMessage = "Finding \(person.name)…"
        start()
    }

    func stopFollowing() {
        followed = nil
        followedLocation = nil
        followMessage = nil
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.step(refreshShares: tick % Self.shareRefreshEvery == 0)
                tick += 1
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        ownPosition = nil
        isSharing = false
    }

    private func step(refreshShares: Bool) async {
        guard let token = AccountSession.shared.token, let client = try? CommunityClient() else {
            isSharing = false
            return
        }
        if refreshShares, let shares = try? await client.shares(token: token) {
            isSharing = shares.contains { $0.direction == .outgoing && $0.state == .active }
            if let followed, !shares.contains(where: { $0.canFollow && $0.person.personID == followed.personID }) {
                stopFollowing()
            }
        }
        if isSharing, let position = ownPosition {
            if (try? await client.publish(position, token: token)) == false { isSharing = false }
        }
        if let followed {
            do {
                followedLocation = try await client.location(of: followed.personID, token: token)
                followMessage = nil
            } catch {
                followedLocation = nil
                followMessage = (error as? LocalizedError)?.errorDescription
                    ?? "\(followed.name)’s position isn’t available right now."
            }
        }
    }
}
