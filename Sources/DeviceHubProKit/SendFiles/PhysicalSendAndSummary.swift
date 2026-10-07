import Foundation
import UniformTypeIdentifiers

/// Send Files for a physical iPhone: apps
/// install and links open as before; every other file or folder is copied into
/// an app's data container (`devicectl device copy to`, `Documents/<name>`).
/// Photos cannot be added to a physical iPhone with public tools, so media
/// files are copied into the app like any other file.
public enum PhysicalSendRouting {
    public struct Plan: Sendable, Equatable {
        /// Apps (`.app`, `.ipa`) and links: what the stage always took.
        public var existing: [URL]
        /// Files and folders to copy into the app.
        public var files: [URL]
        /// Push payloads (`.apns`) and profiles (`.mobileconfig`): no public
        /// tool sends them, so nothing runs (`unsupportedNote`).
        public var unsupported: [URL] = []
    }

    public static func plan(_ urls: [URL]) -> Plan {
        var plan = Plan(existing: [], files: [])
        for url in urls {
            guard url.isFileURL else {
                plan.existing.append(url)
                continue
            }
            switch url.pathExtension.lowercased() {
            case SimulatorPushFile.fileExtension, ConfigurationProfile.fileExtension: plan.unsupported.append(url)
            case "app", "ipa": plan.existing.append(url)
            default: plan.files.append(url)
            }
        }
        return plan
    }

    /// Where an item lands in the app's data container: `Documents/<name>`.
    public static func containerPath(for item: URL) -> String {
        "Documents/" + item.lastPathComponent
    }

    /// What a physical iPhone says to a `.apns` push payload or a `.mobileconfig`
    /// profile: no public tool sends either.
    public static let unsupportedNote = "Push payloads and profiles can't be sent to a physical iPhone with public tools"

    /// The sentence the drop overlay shows when photos or videos are among
    /// the files.
    public static let photosNote = "Photos can't be added to a physical iPhone; choose an app's Documents."
}

/// The device a drop or the Send Files panel is aimed at, for the overlay's
/// words.
public enum SendFilesTarget: Sendable, Equatable {
    case android(destination: AndroidSendDestination)
    case simulator(filesDestination: SimulatorFilesDestination, filesAppName: String?)
    case physical(appName: String?)
}

/// The words of the drop overlay and the status line: what a drop will do,
/// counted from the files (a folder is one item).
public enum SendFilesSummary {
    /// An Android device cannot be sent a push payload from a file.
    public static let androidPushNote = "Push notifications can't be sent to Android this way"

    enum Kind { case photo, video, contact, app, certificate, push, profile, other, folder, link }

    static func kind(of url: URL) -> Kind {
        guard url.isFileURL else { return .link }
        let ext = url.pathExtension.lowercased()
        if ["apk", "apks", "app", "ipa"].contains(ext) { return .app }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return AndroidSendRouting.isInstallable(url) ? .app : .folder
        }
        if SimulatorDropRouting.certificateExtensions.contains(ext) { return .certificate }
        if ext == SimulatorPushFile.fileExtension { return .push }
        if ext == ConfigurationProfile.fileExtension { return .profile }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .vCard) { return .contact }
        return .other
    }

    static func noun(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural ?? singular + "s")"
    }

    /// "Add 3 photos to Photos", "Copy 2 files to Downloads", "Install app",
    /// or several joined with commas; "Nothing to send" when empty.
    ///
    /// `pushApp` names the app a `.apns` file goes to (its payload's
    /// `Simulator Target Bundle`, as the app is called); nil when the file
    /// names none and the user will be asked.
    public static func describe(
        _ urls: [URL],
        target: SendFilesTarget,
        pushApp: (URL) -> String? = { _ in nil }
    ) -> String {
        var counts: [Kind: Int] = [:]
        for url in urls { counts[kind(of: url), default: 0] += 1 }
        func count(_ kinds: Kind...) -> Int { kinds.reduce(0) { $0 + counts[$1, default: 0] } }
        var parts: [String] = []
        let apps = count(.app)
        if apps > 0 { parts.append(apps == 1 ? "Install app" : "Install \(apps) apps") }
        if count(.link) > 0 { parts.append("Open link") }
        let photos = count(.photo)
        let videos = count(.video)
        let contacts = count(.contact)
        let certificates = count(.certificate)
        let pushes = count(.push)
        let profiles = count(.profile)
        let others = count(.other)
        let folders = count(.folder)
        switch target {
        case .android(let destination):
            if pushes > 0 { parts.append(androidPushNote) }
            let all = photos + videos + contacts + certificates + profiles + others + folders
            if all > 0 {
                parts.append("Copy \(copyNoun(photos: photos, videos: videos, folders: folders, total: all)) to \(destination.title)")
            }
        case .simulator(let filesDestination, let appName):
            if photos + videos > 0 {
                parts.append("Add \(mediaNoun(photos: photos, videos: videos)) to Photos")
            }
            if contacts > 0 { parts.append("Add \(noun(contacts, "contact card")) to Contacts") }
            if certificates > 0 { parts.append("Trust \(noun(certificates, "certificate"))") }
            if profiles > 0 { parts.append(ConfigurationProfile.overlayNote) }
            if pushes > 0 {
                let named = urls.filter { kind(of: $0) == .push }.map(pushApp)
                if pushes == 1 {
                    parts.append("Send push notification to " + (named[0] ?? "an app (choose one)"))
                } else {
                    let apps = Set(named.compactMap { $0 })
                    parts.append(apps.count == 1 && !named.contains(where: { $0 == nil })
                        ? "Send \(pushes) push notifications to \(apps.first!)"
                        : "Send \(pushes) push notifications")
                }
            }
            let files = others + folders
            if files > 0 {
                let place: String
                switch filesDestination {
                case .filesApp: place = "Files (On My iPhone)"
                case .appDocuments: place = (appName ?? "the app") + "’s Documents"
                }
                parts.append("Copy \(copyNoun(photos: 0, videos: 0, folders: folders, total: files)) to \(place)")
            }
        case .physical(let appName):
            if pushes + profiles > 0 { parts.append(PhysicalSendRouting.unsupportedNote) }
            let all = photos + videos + contacts + certificates + others + folders
            if all > 0 {
                var text = "Copy \(copyNoun(photos: photos, videos: videos, folders: folders, total: all)) to "
                text += appName.map { "\($0)’s Documents" } ?? "an app’s Documents (choose one)"
                parts.append(text)
                if photos + videos > 0 { parts.append(PhysicalSendRouting.photosNote) }
            }
        }
        return parts.isEmpty ? "Nothing to send" : parts.joined(separator: ", ")
    }

    private static func mediaNoun(photos: Int, videos: Int) -> String {
        if videos == 0 { return noun(photos, "photo") }
        if photos == 0 { return noun(videos, "video") }
        return "\(photos + videos) photos and videos"
    }

    /// "3 photos", "2 videos", "4 photos and videos", "1 folder", "5 files" or
    /// "5 items" (a folder among them).
    private static func copyNoun(photos: Int, videos: Int, folders: Int, total: Int) -> String {
        if photos == total { return noun(photos, "photo") }
        if videos == total { return noun(videos, "video") }
        if photos + videos == total { return "\(total) photos and videos" }
        if folders == total { return noun(folders, "folder") }
        return folders == 0 ? noun(total, "file") : noun(total, "item")
    }
}
