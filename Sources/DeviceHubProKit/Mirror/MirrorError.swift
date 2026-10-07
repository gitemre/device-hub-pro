import Foundation

public enum MirrorError: Error, CustomStringConvertible {
    case couldNotCreateSharedMemory(String)
    case streamFailed(String)

    public var description: String {
        switch self {
        case .couldNotCreateSharedMemory(let path):
            return "could not create shared memory region at \(path)"
        case .streamFailed(let reason):
            return "stream failed: \(reason)"
        }
    }
}
