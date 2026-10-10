import Foundation
import Testing
@testable import AccessCore

private func coverageMaskFrame(timestamp: TimeInterval = 1, width: Int = 256, height: Int = 192,
                               depth: Float = 2) -> CaptureDepthFrame {
    .init(id: "mask-depth", timestampSeconds: timestamp,
          mapFromCamera: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
          camera: .init(imageWidth: width, imageHeight: height, fx: 200, fy: 200,
                        cx: Float(width / 2), cy: Float(height / 2)),
          depth: .init(width: width, height: height, valuesM: Array(repeating: depth, count: width * height),
                       confidence: Array(repeating: 2, count: width * height)))
}

@Test func coverageMaskFadesNewSavedEvidenceAndNeverMarksUnsavedDepth() throws {
    let saved = coverageMaskFrame()
    var coverage = DepthScanCoverage()
    #expect(try #require(coverage.snapshot().mask(for: saved)).alpha.allSatisfy { $0 == 0 })
    coverage.recordSavedFrame(saved)
    let snapshot = coverage.snapshot()
    #expect(try #require(snapshot.mask(for: saved)).alpha.allSatisfy { $0 == 0 })
    var live = saved; live.timestampSeconds = 1.175
    let half = try #require(snapshot.mask(for: live))
    #expect(half.width == 256 && half.height == 192 && half.alpha.count == 256 * 192)
    #expect(half.alpha.max() == 28)
    live.timestampSeconds = 2
    let complete = try #require(snapshot.mask(for: live))
    #expect(complete.alpha.max() == 55)
    #expect(complete.alpha.filter { $0 > 0 }.count > 40_000)
    live.timestampSeconds = 0.5
    #expect(try #require(snapshot.mask(for: live)).alpha.allSatisfy { $0 == 0 })
}

@Test func coverageMaskClearsOcclusionAndConfidenceHolesImmediatelyWithoutBleed() throws {
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(coverageMaskFrame())
    var live = coverageMaskFrame(timestamp: 2)
    // A two-pixel foreground object and a single confidence hole are smaller than
    // the sampling patch: they must still stay clear, as must unsupported neighbors.
    let foreground = 100 * 256 + 128
    live.depth.valuesM[foreground] = 1
    live.depth.valuesM[foreground + 1] = 1
    let hole = 105 * 256 + 129
    live.depth.confidence?[hole] = 0
    let mask = try #require(coverage.snapshot().mask(for: live))
    for index in [foreground, foreground + 1, foreground - 1, foreground - 256, foreground + 256,
                  hole, hole - 1, hole + 1, hole - 256, hole + 256] {
        #expect(mask.alpha[index] == 0)
    }
    #expect(mask.alpha[90 * 256 + 120] == 55)
    live = coverageMaskFrame(timestamp: 2, depth: 1)
    #expect(try #require(coverage.snapshot().mask(for: live)).alpha.allSatisfy { $0 == 0 })
}

@Test func coverageMaskPatchesCannotInflateASparseSavedSurfaceOrExtendAcrossDepthEdges() throws {
    var saved = coverageMaskFrame()
    // Retain one tiny observed patch in an otherwise unobserved wall.
    for row in 0..<192 {
        for column in 0..<256 where !(99...103).contains(row) || !(126...130).contains(column) {
            saved.depth.valuesM[row * 256 + column] = nil
        }
    }
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(saved)
    let live = coverageMaskFrame(timestamp: 2)
    let snapshot = coverage.snapshot()
    let mask = try #require(snapshot.mask(for: live))
    let geometry = try #require(CoverageFrameGeometry(live))
    for row in 1..<191 {
        for column in 1..<255 where mask.alpha[row * 256 + column] > 0 {
            let measured = try #require(geometry.supportedSample(column: column, row: row))
            #expect(snapshot.contains(point: measured.point, normal: measured.normal))
        }
    }
    #expect(mask.alpha[90 * 256 + 128] == 0)
    #expect(mask.alpha[110 * 256 + 128] == 0)
    var changed = live
    for row in 0..<192 { for column in 128..<256 { changed.depth.valuesM[row * 256 + column] = 1 } }
    let edgeMask = try #require(snapshot.mask(for: changed))
    for row in 0..<192 { #expect(edgeMask.alpha[row * 256 + 127] == 0 && edgeMask.alpha[row * 256 + 128] == 0) }
}

@Test func coverageMaskRejectsMalformedInputsAndCapsOutputAllocation() {
    let snapshot = DepthScanCoverage().snapshot()
    var frame = coverageMaskFrame(); frame.camera.imageHeight += 1
    #expect(snapshot.mask(for: frame) == nil)
    frame = coverageMaskFrame(); frame.depth.confidence?.removeLast()
    #expect(snapshot.mask(for: frame) == nil)
    frame = coverageMaskFrame(width: 513)
    #expect(snapshot.mask(for: frame) == nil)
    #expect(DepthScanCoverage.samples(from: frame).isEmpty)
    frame = coverageMaskFrame(); frame.mapFromCamera[12] = .nan
    #expect(snapshot.mask(for: frame) == nil)
}

@Test func coverageMaskNativeFrameBenchmarkHasBoundedBytesAndAlpha() throws {
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(coverageMaskFrame())
    let snapshot = coverage.snapshot()
    let live = coverageMaskFrame(timestamp: 2)
    let start = Date()
    let mask = try #require(snapshot.mask(for: live))
    print("Coverage 256x192 mask: \(Date().timeIntervalSince(start))s, \(mask.alpha.count) bytes")
    #expect(mask.alpha.count == 49_152)
    #expect(mask.alpha.allSatisfy { $0 <= 55 })
}

@Test func coverageMaskDoesNotMarkTheUnseenOppositeSideOfAThinSurface() throws {
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(coverageMaskFrame())
    var live = coverageMaskFrame(timestamp: 2)
    // The back face is within the positional tolerance, but was never observed.
    live.mapFromCamera = [-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, -1, 0, 0, 0, -4.01, 1]
    #expect(try #require(coverage.snapshot().mask(for: live)).alpha.allSatisfy { $0 == 0 })
}

@Test func coverageMaskLargeRetainedSnapshotBenchmarkAndCopyPreserveEvidence() throws {
    var coverage = DepthScanCoverage()
    var saved = coverageMaskFrame()
    var index = 0
    while coverage.retainedCellCount < 60_000 && index < 100 {
        saved.timestampSeconds = Double(index)
        saved.mapFromCamera[12] = Float(index) * 3
        coverage.recordSavedFrame(saved)
        index += 1
    }
    let snapshot = coverage.snapshot()
    #expect(snapshot.count == 60_000)
    var live = saved; live.timestampSeconds += 1
    let maskStart = Date()
    let mask = try #require(snapshot.mask(for: live))
    let maskTime = Date().timeIntervalSince(maskStart)
    #expect(mask.alpha.contains(55))
    #expect(snapshot.count == 60_000 && snapshot.sampleCount <= 240_000)
    saved.mapFromCamera[12] += 3; saved.timestampSeconds += 2
    let copyStart = Date()
    coverage.recordSavedFrame(saved)
    let copyTime = Date().timeIntervalSince(copyStart)
    #expect(snapshot.count == 60_000 && coverage.snapshot().count == 60_000)
    print("Coverage \(snapshot.count) bins / \(snapshot.sampleCount) samples: mask \(maskTime)s, first copy+record \(copyTime)s")
}


@Test func cancelledCoverageMaskDoesNotPublishPartialDisplayEvidence() async {
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(coverageMaskFrame())
    let snapshot = coverage.snapshot()
    let live = coverageMaskFrame(timestamp: 2)
    let gate = AsyncStream<Void>.makeStream()
    let task = Task {
        var iterator = gate.stream.makeAsyncIterator()
        _ = await iterator.next()
        return snapshot.mask(for: live)
    }
    task.cancel()
    gate.continuation.finish()
    #expect(await task.value == nil)
}

@Test func coverageMaskHasNoSeedGridGapsOnAContinuouslyMeasuredWall() throws {
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(coverageMaskFrame())
    let mask = try #require(coverage.snapshot().mask(for: coverageMaskFrame(timestamp: 2)))
    for row in 1..<191 { for column in 1..<255 { #expect(mask.alpha[row * 256 + column] == 55) } }
}

@Test func coverageFeatherSoftensInwardAndPreservesUncapturedHoles() {
    var alpha = [UInt8](repeating: 55, count: 15 * 15)
    for i in 0..<15 {
        alpha[i] = 0; alpha[14 * 15 + i] = 0
        alpha[i * 15] = 0; alpha[i * 15 + 14] = 0
    }
    alpha[7 * 15 + 7] = 0
    let mask = DepthScanCoverageMask(width: 15, height: 15, alpha: alpha).feathered()
    #expect(mask.alpha[7 * 15 + 7] == 0)
    #expect(mask.alpha[7 * 15 + 6] > 0 && mask.alpha[7 * 15 + 6] < mask.alpha[7 * 15 + 5])
    #expect(mask.alpha[3 * 15 + 3] == 55)
    #expect(mask.alpha[7 * 15 + 6] == mask.alpha[6 * 15 + 7])
    #expect(mask.alpha[6 * 15 + 6] == mask.alpha[6 * 15 + 8])
    for i in alpha.indices { #expect(mask.alpha[i] <= alpha[i]) }
}
