import Foundation
import Testing
@testable import AccessCore

@Test func normalLiDARKeyframesKeepSixWithinTheMemoryBudget() throws {
    let budget = DepthKeyframeBudget()
    let cost = try #require(budget.frameCost(width: 256, height: 192, depthBytesPerRow: 1_024,
                                            confidenceBytesPerRow: 256))
    #expect(cost * 6 <= budget.maximumRetainedBytes)
    // An arbitrarily long scan cannot increase the amount of retained sensor data.
    #expect(budget.retainedSuffixCount(costs: Array(repeating: cost, count: 10_000)) == 6)
}

@Test func higherResolutionDepthEvictsWholeOlderKeyframes() throws {
    let budget = DepthKeyframeBudget()
    let cost = try #require(budget.frameCost(width: 512, height: 512, depthBytesPerRow: 2_048,
                                            confidenceBytesPerRow: 512))
    #expect(cost <= budget.maximumRetainedBytes)
    #expect(cost * 2 > budget.maximumRetainedBytes)
    #expect(budget.retainedSuffixCount(costs: Array(repeating: cost, count: 100)) == 1)
}

@Test func depthBudgetIncludesNativeRowPaddingAndDecodedConfidence() throws {
    let budget = DepthKeyframeBudget()
    let unpadded = try #require(budget.frameCost(width: 256, height: 192, depthBytesPerRow: 1_024,
                                                confidenceBytesPerRow: 256))
    let padded = try #require(budget.frameCost(width: 256, height: 192, depthBytesPerRow: 1_088,
                                              confidenceBytesPerRow: 320))
    #expect(padded - unpadded == 192 * (64 + 64))
    let depthOnly = try #require(budget.frameCost(width: 256, height: 192, depthBytesPerRow: 1_024,
                                                 confidenceBytesPerRow: nil))
    #expect(unpadded - depthOnly == 256 * 192 * (1 + MemoryLayout<Int>.stride))
}

@Test func depthFramesMustFitBeforeNativeBuffersAreCopied() {
    let budget = DepthKeyframeBudget()
    #expect(budget.frameCost(width: 512, height: 513, depthBytesPerRow: 2_048,
                             confidenceBytesPerRow: 512) == nil)
    #expect(budget.frameCost(width: 512, height: 512, depthBytesPerRow: 8_192,
                             confidenceBytesPerRow: nil) == nil)
    let tinyArchive = DepthKeyframeBudget(maximumRetainedBytes: 1_000)
    #expect(tinyArchive.frameCost(width: 256, height: 192, depthBytesPerRow: 1_024,
                                  confidenceBytesPerRow: 256) == nil)
}

@Test func depthBudgetRejectsInvalidDimensionsStridesAndOverflow() {
    let budget = DepthKeyframeBudget()
    #expect(budget.frameCost(width: 0, height: 192, depthBytesPerRow: 1_024,
                             confidenceBytesPerRow: nil) == nil)
    #expect(budget.frameCost(width: 256, height: -1, depthBytesPerRow: 1_024,
                             confidenceBytesPerRow: nil) == nil)
    #expect(budget.frameCost(width: 256, height: 192, depthBytesPerRow: 1_023,
                             confidenceBytesPerRow: 256) == nil)
    #expect(budget.frameCost(width: 256, height: 192, depthBytesPerRow: 1_024,
                             confidenceBytesPerRow: 255) == nil)
    #expect(budget.frameCost(width: 256, height: 192, depthBytesPerRow: Int.max,
                             confidenceBytesPerRow: nil) == nil)
    let largeBudget = DepthKeyframeBudget(maximumPixels: Int.max, maximumNativeFrameBytes: Int.max,
                                          maximumRetainedBytes: Int.max)
    #expect(largeBudget.frameCost(width: Int.max, height: 2, depthBytesPerRow: Int.max,
                                  confidenceBytesPerRow: nil) == nil)
}

@Test func keyframeEvictionKeepsTheLatestContiguousCompleteFrames() {
    let budget = DepthKeyframeBudget(maximumRetainedBytes: 100)
    #expect(budget.retainedSuffixCount(costs: [60, 20, 30, 40]) == 3)
    #expect(budget.retainedSuffixCount(costs: [20, 101]) == 0)
    #expect(budget.retainedSuffixCount(costs: []) == 0)
    let overflowBudget = DepthKeyframeBudget(maximumRetainedBytes: Int.max)
    #expect(overflowBudget.retainedSuffixCount(costs: [1, Int.max]) == 1)
}
