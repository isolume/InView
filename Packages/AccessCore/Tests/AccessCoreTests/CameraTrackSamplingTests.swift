import Foundation
import Testing
@testable import AccessCore

@Test func timerRunsAtTheRequestedRate() throws {
    for rate in [1.0, 5, 10, 30, 60] {
        let sampling = try #require(CameraTrackSampling(rateHz: rate))
        #expect(abs(sampling.timerInterval - 1 / rate) < 1e-12)
        #expect(sampling.interval == sampling.timerInterval)
    }
}

@Test func invalidRatesAreRejected() {
    for rate in [0.0, -10, .nan, .infinity, 61] {
        #expect(CameraTrackSampling(rateHz: rate) == nil)
    }
}

@Test func acceptedSpacingFollowsTheIntervalAndDecimation() throws {
    var sampling = try #require(CameraTrackSampling(rateHz: 10))
    #expect(sampling.accepts(timestamp: 5, after: nil))
    #expect(!sampling.accepts(timestamp: 5.05, after: 5))
    #expect(sampling.accepts(timestamp: 5.08, after: 5))
    sampling.decimate()
    #expect(abs(sampling.interval - 0.2) < 1e-12)
    #expect(abs(sampling.timerInterval - 0.1) < 1e-12)  // The timer keeps its base rate.
    #expect(!sampling.accepts(timestamp: 5.1, after: 5))
    #expect(sampling.accepts(timestamp: 5.15, after: 5))
}

@Test func newCoordinateFrameRestoresDenseSampling() throws {
    var sampling = try #require(CameraTrackSampling(rateHz: 10))
    sampling.decimate()
    sampling.decimate()
    #expect(!sampling.accepts(timestamp: 40.08, after: 40))
    sampling.reset()
    #expect(sampling.accepts(timestamp: 40.08, after: 40))
    #expect(sampling.interval == sampling.timerInterval)
}
