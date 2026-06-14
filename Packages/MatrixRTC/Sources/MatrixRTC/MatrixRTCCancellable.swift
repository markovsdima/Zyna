public protocol MatrixRTCCancellable: Sendable {
    func cancel()
}

public struct MatrixRTCNoopCancellable: MatrixRTCCancellable {
    public init() {}

    public func cancel() {}
}
