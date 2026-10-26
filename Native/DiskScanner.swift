import Foundation

actor DiskScanner {

    /// Streams bounded progress and a complete recursive index without file reads.
    nonisolated func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanResult, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                do {
                    try await self.produce(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func produce(
        _ request: ScanRequest,
        continuation: AsyncThrowingStream<ScanResult, Error>.Continuation
    ) throws {
        try Task.checkCancellation()
        try ScanTraversal(
            request: request,
            continuation: continuation
        ).run()
    }
}
