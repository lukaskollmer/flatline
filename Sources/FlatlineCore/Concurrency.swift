import Dispatch

extension Array {
    /// Maps elements on all cores, preserving order.
    public func concurrentMap<T>(_ transform: (Element) -> T) -> [T] {
        guard count > 1 else { return map(transform) }
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        withoutActuallyEscaping(transform) { transform in
            let box = UncheckedSendable((self, transform, buffer))
            DispatchQueue.concurrentPerform(iterations: count) { index in
                let (elements, transform, buffer) = box.value
                (buffer.baseAddress! + index).initialize(to: transform(elements[index]))
            }
        }
        return Array<T>(unsafeUninitializedCapacity: count) { target, initialized in
            _ = target.moveInitialize(fromContentsOf: buffer)
            initialized = count
        }
    }
}

/// Moves a value across a concurrency boundary that the compiler can't
/// check, e.g. into `concurrentPerform`, where each iteration touches
/// distinct state.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
