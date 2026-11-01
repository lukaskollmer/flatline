import CIndexStore
import Foundation

public struct IndexStoreError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// A dynamically loaded copy of libIndexStore.
public final class IndexStoreLibrary: @unchecked Sendable {
    public let path: String
    let api: flatline_indexstore_functions_t
    private let handle: UnsafeMutableRawPointer

    public init(path: String) throws {
        var api = flatline_indexstore_functions_t()
        var message = [CChar](repeating: 0, count: 1024)
        guard let handle = flatline_indexstore_open(path, &api, &message, message.count) else {
            throw IndexStoreError(message.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        self.path = path
        self.api = api
        self.handle = handle
    }

    deinit {
        flatline_indexstore_close(handle)
    }

    public var formatVersion: Int {
        Int(api.format_version())
    }

    /// Converts an `indexstore_error_t` out-parameter into a thrown error.
    func check<T>(_ body: (UnsafeMutablePointer<indexstore_error_t?>) -> T?) throws -> T {
        var error: indexstore_error_t?
        if let result = body(&error) {
            return result
        }
        guard let error else {
            throw IndexStoreError("unknown index store error")
        }
        let description = api.error_get_description(error).map { String(cString: $0) } ?? "unknown index store error"
        api.error_dispose(error)
        throw IndexStoreError(description)
    }
}

extension indexstore_string_ref_t {
    var string: String {
        guard let data, length > 0 else { return "" }
        return data.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }
}
