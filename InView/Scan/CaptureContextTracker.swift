import AccessCore
import CoreLocation
import CoreMotion
import Foundation

@MainActor
final class CaptureContextTracker: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private var location: CLLocation?
    private var heading: CLHeading?
    private var relativeAltitude: Double?
    private var pressureKPa: Double?
    private(set) var isRunning = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 3
        locationManager.headingFilter = 3
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginLocationUpdates()
        default:
            break
        }
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                self?.relativeAltitude = data.relativeAltitude.doubleValue
                self?.pressureKPa = data.pressure.doubleValue
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        altimeter.stopRelativeAltitudeUpdates()
    }

    func sample() -> CaptureEnvironmentSample? {
        guard isRunning else { return nil }
        let validLocation = location.flatMap { $0.horizontalAccuracy >= 0 ? $0 : nil }
        let validHeading = heading.flatMap { $0.headingAccuracy >= 0 ? $0 : nil }
        guard validLocation != nil || validHeading != nil || relativeAltitude != nil else { return nil }
        let altitude = validLocation.flatMap { $0.verticalAccuracy >= 0 ? $0.altitude : nil }
        let course = validLocation.flatMap { $0.course >= 0 ? $0.course : nil }
        let speed = validLocation.flatMap { $0.speed >= 0 ? $0.speed : nil }
        let headingDegrees = validHeading.flatMap { $0.trueHeading >= 0 ? $0.trueHeading : $0.magneticHeading }
        return CaptureEnvironmentSample(
            recordedAtUnixSeconds: Date().timeIntervalSince1970,
            latitude: validLocation?.coordinate.latitude,
            longitude: validLocation?.coordinate.longitude,
            horizontalAccuracyM: validLocation?.horizontalAccuracy,
            altitudeM: altitude,
            verticalAccuracyM: validLocation?.verticalAccuracy,
            courseDegrees: course,
            speedMps: speed,
            headingDegrees: headingDegrees,
            headingAccuracyDegrees: validHeading?.headingAccuracy,
            relativeAltitudeM: relativeAltitude,
            pressureKPa: pressureKPa
        )
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRunning else { return }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            beginLocationUpdates()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading
    }

    private func beginLocationUpdates() {
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { locationManager.startUpdatingHeading() }
    }
}
