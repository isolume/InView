import Foundation
import Testing
@testable import AccessCore

struct RoomCaptureArchiveTests {
    private struct SensorInput: Codable {
        var samples: [Double]
        var bytes: Data
        var date: Date
        var optional: Float?
    }

    private struct Unencodable: Encodable {
        func encode(to encoder: Encoder) throws {
            throw EncodingError.invalidValue("fixture", .init(codingPath: [], debugDescription: "Serialization failed"))
        }
    }

    private final class EncodingAttempts: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private struct CancelFirstEncoding: Encodable {
        let attempts: EncodingAttempts

        func encode(to encoder: Encoder) throws {
            if attempts.next() == 1 { throw CancellationError() }
            var container = encoder.unkeyedContainer()
            try container.encode(42)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sensorValuesUnsupportedByJSONRoundTripWithoutSubstitution() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = SensorInput(samples: [.infinity, -.infinity, .nan, 0.125],
                                   bytes: Data([0, 255, 17]), date: Date(timeIntervalSince1970: 1234.5), optional: nil)
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(original) }
        let url = root.appending(path: "source/room.plist")
        try RoomCaptureArchive.write(original, to: url)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("bplist00".utf8)))
        let restored = try PropertyListDecoder().decode(SensorInput.self, from: data)
        #expect(restored.samples[0] == .infinity)
        #expect(restored.samples[1] == -.infinity)
        #expect(restored.samples[2].isNaN)
        #expect(restored.samples[3] == 0.125)
        #expect(restored.bytes == original.bytes)
        #expect(restored.date == original.date)
        #expect(restored.optional == nil)
    }

    @Test func serializationFailureDoesNotReplaceAnExistingOriginal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "room.plist")
        try RoomCaptureArchive.write([1, 2, 3], to: url)
        let original = try Data(contentsOf: url)
        do {
            try RoomCaptureArchive.write(Unencodable(), to: url)
            Issue.record("Expected serialization failure")
        } catch let failure as RoomCaptureArchive.Failure {
            guard case .encoding = failure else { Issue.record("Serialization was mislabeled as storage"); return }
            #expect(!failure.isOutOfSpace)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func filesystemFailureIsDistinguishedFromSerialization() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appending(path: "blocked")
        try Data([42]).write(to: parent)
        do {
            try RoomCaptureArchive.write([1, 2, 3], to: parent.appending(path: "room.plist"))
            Issue.record("Expected filesystem failure")
        } catch let failure as RoomCaptureArchive.Failure {
            guard case .storage = failure else { Issue.record("Filesystem failure was mislabeled as encoding"); return }
            #expect(!failure.isOutOfSpace)
        }
        #expect(try Data(contentsOf: parent) == Data([42]))
    }

    @Test func onlyActualFullDiskErrorsRecommendFreeingStorage() {
        let full = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.ENOSPC.rawValue))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        let denied = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        #expect(RoomCaptureArchive.Failure.storage(full).isOutOfSpace)
        #expect(RoomCaptureArchive.Failure.storage(wrapped).isOutOfSpace)
        #expect(!RoomCaptureArchive.Failure.storage(denied).isOutOfSpace)
        #expect(!RoomCaptureArchive.Failure.encoding(full).isOutOfSpace)
    }

    @Test func canceledArchiveDoesNotCreateAFileOrBecomeAStorageError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "room.plist")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try RoomCaptureArchive.write([1, 2, 3], to: url)
        }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func finiteValuesUseJSONAndReturnItsURL() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = SensorInput(samples: [0, 0.125, -2], bytes: Data([0, 255]),
                                   date: Date(timeIntervalSince1970: 1234.5), optional: 3)
        let url = root.appending(path: "source/room.json")
        #expect(try RoomCaptureArchive.writeJSON(original, to: url) == url)
        let restored = try JSONDecoder().decode(SensorInput.self, from: Data(contentsOf: url))
        #expect(restored.samples == original.samples)
        #expect(restored.bytes == original.bytes)
        #expect(restored.date == original.date)
        #expect(restored.optional == original.optional)
        #expect(!FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("plist").path))
    }

    @Test func nonfiniteValuesFallBackToBinaryWithoutSubstitution() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = SensorInput(samples: [.infinity, -.infinity, .nan, 0.125], bytes: Data([0, 255, 17]),
                                   date: Date(timeIntervalSince1970: 1234.5), optional: nil)
        let jsonURL = root.appending(path: "source/room.json")
        let plistURL = jsonURL.deletingPathExtension().appendingPathExtension("plist")
        #expect(try RoomCaptureArchive.writeJSON(original, to: jsonURL) == plistURL)
        let data = try Data(contentsOf: plistURL)
        #expect(data.starts(with: Data("bplist00".utf8)))
        let restored = try PropertyListDecoder().decode(SensorInput.self, from: data)
        #expect(restored.samples[0] == .infinity)
        #expect(restored.samples[1] == -.infinity)
        #expect(restored.samples[2].isNaN)
        #expect(restored.samples[3] == 0.125)
        #expect(restored.bytes == original.bytes)
        #expect(restored.date == original.date)
        #expect(restored.optional == nil)
        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))
    }

    @Test func retriesRemoveOnlyTheSupersededFormatAfterSuccess() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jsonURL = root.appending(path: "room.json")
        let plistURL = root.appending(path: "room.plist")
        #expect(try RoomCaptureArchive.writeJSON([1.0], to: jsonURL) == jsonURL)
        #expect(try RoomCaptureArchive.writeJSON([Double.infinity], to: jsonURL) == plistURL)
        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(try PropertyListDecoder().decode([Double].self, from: Data(contentsOf: plistURL)) == [.infinity])
        #expect(try RoomCaptureArchive.writeJSON([2.0], to: jsonURL) == jsonURL)
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(try JSONDecoder().decode([Double].self, from: Data(contentsOf: jsonURL)) == [2])
    }

    @Test func bothSerializationFailuresPreserveEveryExistingOriginal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jsonURL = root.appending(path: "room.json")
        let plistURL = root.appending(path: "room.plist")
        let json = try JSONEncoder().encode([1])
        let plist = try PropertyListEncoder().encode([2])
        try json.write(to: jsonURL)
        try plist.write(to: plistURL)
        do {
            try RoomCaptureArchive.writeJSON(Unencodable(), to: jsonURL)
            Issue.record("Expected serialization failure")
        } catch let failure as RoomCaptureArchive.Failure {
            guard case .encoding = failure else { Issue.record("Serialization was mislabeled as storage"); return }
        }
        #expect(try Data(contentsOf: jsonURL) == json)
        #expect(try Data(contentsOf: plistURL) == plist)
    }

    @Test func JSONStorageFailureDoesNotFallBackOrReplaceTheAlternate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jsonURL = root.appending(path: "room.json")
        let plistURL = root.appending(path: "room.plist")
        try FileManager.default.createDirectory(at: jsonURL, withIntermediateDirectories: false)
        try RoomCaptureArchive.write([99], to: plistURL)
        let original = try Data(contentsOf: plistURL)
        do {
            try RoomCaptureArchive.writeJSON([1], to: jsonURL)
            Issue.record("Expected filesystem failure")
        } catch let failure as RoomCaptureArchive.Failure {
            guard case .storage = failure else { Issue.record("Storage was mislabeled as encoding"); return }
        }
        #expect(try Data(contentsOf: plistURL) == original)
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
    }

    @Test func alternateCleanupFailureIsStorageAndPreservesUnrelatedContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jsonURL = root.appending(path: "room.json")
        let plistURL = root.appending(path: "room.plist")
        try FileManager.default.createDirectory(at: plistURL, withIntermediateDirectories: false)
        let unrelated = plistURL.appending(path: "keep")
        try Data([99]).write(to: unrelated)
        do {
            try RoomCaptureArchive.writeJSON([1], to: jsonURL)
            Issue.record("Expected cleanup failure")
        } catch let failure as RoomCaptureArchive.Failure {
            guard case .storage = failure else { Issue.record("Cleanup was mislabeled as encoding"); return }
        }
        #expect(try JSONDecoder().decode([Int].self, from: Data(contentsOf: jsonURL)) == [1])
        #expect(try Data(contentsOf: unrelated) == Data([99]))
    }

    @Test func cancellationDuringJSONEncodingNeverRetriesAnotherSerializer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jsonURL = root.appending(path: "room.json")
        let plistURL = root.appending(path: "room.plist")
        let attempts = EncodingAttempts()
        #expect(throws: CancellationError.self) {
            try RoomCaptureArchive.writeJSON(CancelFirstEncoding(attempts: attempts), to: jsonURL)
        }
        #expect(attempts.count == 1)
        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
    }

    @Test func canceledJSONArchivePreservesTheExistingAlternate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jsonURL = root.appending(path: "room.json")
        let plistURL = root.appending(path: "room.plist")
        try RoomCaptureArchive.write([99], to: plistURL)
        let original = try Data(contentsOf: plistURL)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try RoomCaptureArchive.writeJSON([1], to: jsonURL)
        }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: jsonURL.path))
            #expect(try Data(contentsOf: plistURL) == original)
        }
    }
}
