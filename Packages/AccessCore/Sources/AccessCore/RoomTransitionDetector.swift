import Foundation
import simd

/// A measured, walkable door or opening in the shared AR coordinate system.
/// `observedAt` advances only when RoomPlan supplies a new measurement, not on camera polls.
public struct RoomTransitionPortal: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case door, opening }

    public var id: UUID
    public var kind: Kind
    public var center: SIMD3<Float>
    /// The surface's horizontal width axis, projected into the X/Z plane.
    public var horizontalAxis: SIMD2<Float>
    public var width: Float
    public var height: Float
    public var observedAt: TimeInterval

    public init(id: UUID, kind: Kind, center: SIMD3<Float>, horizontalAxis: SIMD2<Float>,
                width: Float, height: Float, observedAt: TimeInterval) {
        self.id = id; self.kind = kind; self.center = center
        self.horizontalAxis = horizontalAxis; self.width = width; self.height = height
        self.observedAt = observedAt
    }
}

public struct RoomTransition: Sendable, Equatable {
    public let portalID: UUID
    public let kind: RoomTransitionPortal.Kind
    public let position: SIMD3<Float>
    public let timestamp: TimeInterval
}

/// Detects a deliberate crossing of a stable RoomPlan door or opening.
/// Room size, distance travelled, and capture duration never produce an event.
public struct RoomTransitionDetector: Sendable {
    private struct Crossing: Sendable {
        var started: TimeInterval
        var clearSince: TimeInterval?
    }

    private struct Candidate: Sendable {
        var portal: RoomTransitionPortal
        var firstObservedAt: TimeInterval
        var lastObservedAt: TimeInterval
        var observationCount: Int
        var armedSide: Float?
        var crossing: Crossing?
    }

    private struct CameraSample: Sendable {
        var position: SIMD3<Float>
        var timestamp: TimeInterval
    }

    private struct Completed: Sendable {
        var portal: RoomTransitionPortal
        var timestamp: TimeInterval
    }

    private var candidates: [UUID: Candidate] = [:]
    private var previousCamera: CameraSample?
    private var completed: [Completed] = []

    public init() {}

    /// Call at the start of a new whole scan, or when its coordinate system changes.
    public mutating func reset() {
        candidates.removeAll(); previousCamera = nil; completed.removeAll()
    }

    /// Call during processing, interruptions, or a room handoff. A fresh stable measurement
    /// and approach are required afterward; recent crossings remain suppressed across handoffs.
    public mutating func suspend() {
        candidates.removeAll(); previousCamera = nil
    }

    /// Supply only current RoomPlan measurements, including openings as well as doors.
    /// Invalid or interrupted tracking discards every pending crossing. The floor height is
    /// used to reject raised openings, such as windows, even when misclassified as an opening.
    public mutating func update(portals: [RoomTransitionPortal], position: SIMD3<Float>,
                                floorY: Float, timestamp: TimeInterval,
                                trackingIsNormal: Bool) -> RoomTransition? {
        guard trackingIsNormal, finite(position), floorY.isFinite, timestamp.isFinite else {
            suspend(); return nil
        }
        if let previousCamera, timestamp <= previousCamera.timestamp {
            // Polling the same AR frame is harmless; out-of-order poses break continuity.
            if timestamp < previousCamera.timestamp { suspend() }
            return nil
        }

        let previous = previousCamera
        previousCamera = CameraSample(position: position, timestamp: timestamp)
        completed.removeAll { timestamp - $0.timestamp > 60 }
        var motionIsContinuous = previous != nil
        if let previous {
            let elapsed = timestamp - previous.timestamp
            let travel = simd_distance(position, previous.position)
            if elapsed > 0.75 || travel > 1.2 || travel / Float(elapsed) > 3.5 {
                clearApproaches()
                motionIsContinuous = false
            }
        }

        // Duplicated IDs are ambiguous. Bound work even if an upstream source is malformed.
        let counts = Dictionary(grouping: portals, by: \.id).mapValues(\.count)
        let observed = portals.filter { counts[$0.id] == 1 }
            .sorted { $0.id.uuidString < $1.id.uuidString }.prefix(128)
        var currentIDs: Set<UUID> = []
        for incoming in observed {
            guard let measurement = validated(incoming, floorY: floorY, timestamp: timestamp) else { continue }
            currentIDs.insert(measurement.id)
            var candidate: Candidate
            if let old = candidates[measurement.id], measurementsAgree(old.portal, measurement),
               measurement.observedAt >= old.lastObservedAt {
                candidate = old
                if measurement.observedAt > old.lastObservedAt {
                    candidate.observationCount = min(candidate.observationCount + 1, 3)
                    candidate.lastObservedAt = measurement.observedAt
                }
                // Keep the original plane fixed: geometry refinement cannot move the plane
                // through a stationary camera and manufacture a crossing.
            } else {
                candidate = Candidate(portal: measurement, firstObservedAt: measurement.observedAt,
                                      lastObservedAt: measurement.observedAt, observationCount: 1)
            }
            guard candidate.observationCount >= 3,
                  candidate.lastObservedAt - candidate.firstObservedAt >= 0.6 - 1e-6,
                  !isCoolingDown(candidate.portal, timestamp: timestamp) else {
                candidate.armedSide = nil; candidate.crossing = nil
                candidates[measurement.id] = candidate
                continue
            }

            let portal = candidate.portal
            let offset = horizontal(position) - horizontal(portal.center)
            let depth = simd_dot(offset, normal(portal))
            let lateral = simd_dot(offset, portal.horizontalAxis)
            let withinHeight = position.y >= portal.center.y - portal.height / 2 + 0.05
                && position.y <= portal.center.y + portal.height / 2 - 0.05

            if !withinHeight || abs(lateral) > portal.width / 2 + 0.3 || abs(depth) > 3 {
                candidate.armedSide = nil; candidate.crossing = nil
            } else if motionIsContinuous {
                if candidate.armedSide == nil, abs(depth) >= 0.65 {
                    candidate.armedSide = depth >= 0 ? 1 : -1
                }
                if let side = candidate.armedSide {
                    let signedDepth = depth * side
                    if signedDepth >= 0.08 { candidate.crossing = nil }
                    if candidate.crossing == nil, let previous,
                       crossed(portal, from: previous.position, to: position, side: side) {
                        candidate.crossing = Crossing(started: timestamp)
                    }
                    if var crossing = candidate.crossing {
                        if signedDepth <= -0.45 {
                            if crossing.clearSince == nil { crossing.clearSince = timestamp }
                        } else {
                            crossing.clearSince = nil
                        }
                        candidate.crossing = crossing
                        if let clearSince = crossing.clearSince,
                           timestamp - crossing.started >= 0.45 - 1e-6,
                           timestamp - clearSince >= 0.25 - 1e-6 {
                            completed.append(Completed(portal: portal, timestamp: timestamp))
                            if completed.count > 128 { completed.removeFirst(completed.count - 128) }
                            clearApproaches()
                            return RoomTransition(portalID: portal.id, kind: portal.kind,
                                                  position: position, timestamp: timestamp)
                        }
                    }
                }
            }
            candidates[portal.id] = candidate
        }
        // Losing a measurement breaks its continuity, even if the last plane was nearby.
        candidates = candidates.filter { currentIDs.contains($0.key) }
        return nil
    }

    private mutating func clearApproaches() {
        for id in candidates.keys {
            candidates[id]?.armedSide = nil
            candidates[id]?.crossing = nil
        }
    }

    private func validated(_ incoming: RoomTransitionPortal, floorY: Float,
                           timestamp: TimeInterval) -> RoomTransitionPortal? {
        guard finite(incoming.center), incoming.horizontalAxis.x.isFinite,
              incoming.horizontalAxis.y.isFinite, incoming.width.isFinite,
              incoming.height.isFinite, incoming.observedAt.isFinite,
              incoming.width >= 0.65, incoming.width <= 12,
              incoming.height >= 1.65, incoming.height <= 6.5,
              incoming.center.y - incoming.height / 2 <= floorY + 0.35,
              incoming.center.y - incoming.height / 2 >= floorY - 0.35,
              timestamp - incoming.observedAt >= -0.05,
              timestamp - incoming.observedAt <= 1.5 else { return nil }
        let axisLength = simd_length(incoming.horizontalAxis)
        guard axisLength >= 0.9, axisLength <= 1.1 else { return nil }
        var portal = incoming
        portal.horizontalAxis /= axisLength
        if portal.horizontalAxis.x < 0
            || (abs(portal.horizontalAxis.x) < 1e-5 && portal.horizontalAxis.y < 0) {
            portal.horizontalAxis = -portal.horizontalAxis
        }
        return portal
    }

    private func measurementsAgree(_ a: RoomTransitionPortal, _ b: RoomTransitionPortal) -> Bool {
        a.kind == b.kind && simd_distance(a.center, b.center) <= 0.12
            && abs(a.width - b.width) <= 0.15 && abs(a.height - b.height) <= 0.15
            && abs(simd_dot(a.horizontalAxis, b.horizontalAxis)) >= cos(Float.pi / 36)
    }

    private func crossed(_ portal: RoomTransitionPortal, from: SIMD3<Float>,
                         to: SIMD3<Float>, side: Float) -> Bool {
        let axisNormal = normal(portal)
        let start = simd_dot(horizontal(from) - horizontal(portal.center), axisNormal) * side
        let end = simd_dot(horizontal(to) - horizontal(portal.center), axisNormal) * side
        guard start >= 0, end < 0, start - end > 1e-5 else { return false }
        let intersection = from + (to - from) * (start / (start - end))
        let lateral = simd_dot(horizontal(intersection) - horizontal(portal.center), portal.horizontalAxis)
        return abs(lateral) <= portal.width / 2 - 0.08
            && intersection.y >= portal.center.y - portal.height / 2 + 0.05
            && intersection.y <= portal.center.y + portal.height / 2 - 0.05
    }

    private func isCoolingDown(_ portal: RoomTransitionPortal, timestamp: TimeInterval) -> Bool {
        completed.contains { old in
            let elapsed = timestamp - old.timestamp
            if elapsed < 1.5 { return true }
            if old.portal.id == portal.id && elapsed < 6 { return true }
            // RoomPlan can assign a different ID (or both a door and opening) on the
            // next capture. Suppress the same physical portal across that handoff.
            return elapsed < 6
                && abs(simd_dot(old.portal.horizontalAxis, portal.horizontalAxis)) >= 0.98
                && abs(simd_dot(horizontal(old.portal.center) - horizontal(portal.center), normal(portal))) <= 0.35
                && abs(simd_dot(horizontal(old.portal.center) - horizontal(portal.center), portal.horizontalAxis))
                    <= min(old.portal.width, portal.width) / 2
                && abs(old.portal.center.y - portal.center.y) <= 0.35
        }
    }

    private func normal(_ portal: RoomTransitionPortal) -> SIMD2<Float> {
        SIMD2(-portal.horizontalAxis.y, portal.horizontalAxis.x)
    }

    private func horizontal(_ position: SIMD3<Float>) -> SIMD2<Float> { SIMD2(position.x, position.z) }
    private func finite(_ position: SIMD3<Float>) -> Bool {
        position.x.isFinite && position.y.isFinite && position.z.isFinite
    }
}
