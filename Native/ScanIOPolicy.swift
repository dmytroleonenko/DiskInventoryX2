import Foundation
import Darwin

/// Materialization is scoped to a synchronous thread; automount stays disabled for this process.
struct ScanIOPolicy {
    func perform<Value>(_ operation: () throws -> Value) throws -> Value {
        // XNU only supports PROCESS scope for trigger resolution. Never restoring it
        // avoids one concurrent filesystem operation re-enabling another one's mounts.
        guard setiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_PROCESS, IOPOL_VFS_TRIGGER_RESOLVE_OFF) == 0 else {
            throw policyError()
        }
        let materialization = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard materialization >= 0 else { throw policyError() }
        guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw policyError()
        }
        defer { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, materialization) }
        return try operation()
    }

    private func policyError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
