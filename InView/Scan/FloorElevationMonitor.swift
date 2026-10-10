import AccessCore
import CoreMotion
import Foundation

/// Elevation suggests a floor change; the volunteer confirms the building's actual floor name.
@MainActor
final class FloorElevationMonitor {
    var onMovement: (() -> Void)?
    var onLanding: ((FloorChangeDetector.Proposal) -> Void)?
    var onUnavailable: (() -> Void)?

    private let altimeter = CMAltimeter()
    private var detector = FloorChangeDetector()
    private var isRunning = false
    private var hasReportedMovement = false
    private var generation = 0

    func start() {
        guard !isRunning else { return }
        guard CMAltimeter.isRelativeAltitudeAvailable(),
              CMAltimeter.authorizationStatus() != .denied,
              CMAltimeter.authorizationStatus() != .restricted else {
            onUnavailable?()
            return
        }
        isRunning = true
        generation += 1
        let request = generation
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == request else { return }
                guard error == nil, let data else {
                    self.stop()
                    self.onUnavailable?()
                    return
                }
                let proposal = self.detector.update(elevationMeters: data.relativeAltitude.doubleValue,
                                                    timestamp: data.timestamp)
                if self.detector.isChangingElevation, !self.hasReportedMovement {
                    self.hasReportedMovement = true
                    self.onMovement?()
                }
                if let proposal { self.onLanding?(proposal) }
            }
        }
    }

    func rebase() {
        detector.rebase()
        hasReportedMovement = false
    }

    func stop() {
        generation += 1
        isRunning = false
        altimeter.stopRelativeAltitudeUpdates()
        detector.reset()
        hasReportedMovement = false
    }
}
