import Foundation

protocol ScanPermissionsPreparing: Sendable {
    func prepare(_ request: ScanRequest) -> AsyncThrowingStream<ScanPermissionEvent, Error>
}
