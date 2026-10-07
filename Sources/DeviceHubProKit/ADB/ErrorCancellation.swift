import Foundation

extension Error {
    /// The failure is only a cancelled task (a view's `.task` ended, a refresh was
    /// superseded): nothing went wrong, so nothing should be shown as an error.
    public var isCancellation: Bool {
        if self is CancellationError { return true }
        if let url = self as? URLError, url.code == .cancelled { return true }
        let ns = self as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError
    }
}
