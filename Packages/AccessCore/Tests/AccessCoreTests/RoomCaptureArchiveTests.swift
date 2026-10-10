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
}
