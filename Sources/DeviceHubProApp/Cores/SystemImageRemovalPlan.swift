import DeviceHubProKit

/// What Settings ▸ Android system images says before an image is removed:
/// how much it frees and which emulators stop starting without it. An
/// emulator running on the image blocks the removal (sdkmanager would pull
/// the image out from under it). Pure, for tests.
struct SystemImageRemovalPlan: Equatable, Identifiable {
    let package: String
    let title: String
    let message: String
    /// Why the image cannot be removed now; nil when it can.
    let blockedReason: String?

    var id: String { package }

    /// - Parameters:
    ///   - users: the emulators built on the image, by display name, in order.
    ///   - runningUsers: those of `users` running now.
    static func make(
        image: SystemImage,
        sizeText: String,
        users: [String],
        runningUsers: [String]
    ) -> SystemImageRemovalPlan {
        let frees = sizeText == "…" ? "" : "This frees \(sizeText). "
        let message: String
        switch users.count {
        case 0:
            message = frees + "No emulator uses this image; it is downloaded again when you create one that needs it."
        case 1:
            message = frees + "\(users[0]) uses it and will not start until the image is downloaded again."
        default:
            message = frees + "These emulators use it and will not start until the image is downloaded again: "
                + users.joined(separator: ", ") + "."
        }
        let blocked: String? = runningUsers.isEmpty
            ? nil
            : "Shut down \(runningUsers.joined(separator: ", ")) first: \(runningUsers.count == 1 ? "it runs" : "they run") on this image."
        return SystemImageRemovalPlan(
            package: image.package,
            title: "Remove \(image.friendlyLabel)?",
            message: message,
            blockedReason: blocked
        )
    }
}
