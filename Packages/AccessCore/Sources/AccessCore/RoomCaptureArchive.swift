import Foundation

/// Native sensor inputs may contain values JSON cannot represent. Keep them losslessly,
/// and distinguish serialization failures from failures writing to the device.
public enum RoomCaptureArchive {
    public enum Failure: Error {
        case encoding(Error)
        case storage(Error)

        public var underlyingError: Error {
            switch self {
            case .encoding(let error), .storage(let error): return error
            }
        }

        public var isOutOfSpace: Bool {
            guard case .storage(let error) = self else { return false }
            var current = error as NSError
            for _ in 0..<8 {
                if current.domain == NSCocoaErrorDomain && current.code == CocoaError.fileWriteOutOfSpace.rawValue {
                    return true
                }
                if current.domain == NSPOSIXErrorDomain && current.code == Int(POSIXError.ENOSPC.rawValue) {
                    return true
                }
                guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
                current = underlying
            }
            return false
        }
    }

    public static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try Task.checkCancellation()
        let data: Data
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            data = try encoder.encode(value)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.encoding(error)
        }
        try Task.checkCancellation()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure.storage(error)
        }
    }
}
