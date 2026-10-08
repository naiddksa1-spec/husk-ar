// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

// MARK: - Internal Model
struct AppSource: Identifiable, Equatable {
    let name: String
    let identifier: String
    var apps: [SourceApp]
    var id: String { identifier }
}

struct SourceApp: Identifiable, Equatable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let downloadURL: String
    let iconURL: String
    let localizedDescription: String
    var id: String { bundleIdentifier }
}

// MARK: - F-Droid v1 Schema
private struct FDroidIndex: Codable {
    let repo: FDroidRepo
    let apps: [FDroidApp]
    let packages: [String: [FDroidPackage]]
}
private struct FDroidRepo: Codable { let name: String; let address: String }
private struct FDroidApp: Codable {
    let packageName: String
    let name: String?
    let summary: String?
    let description: String?
    let icon: String?
    let localized: [String: FDroidLocalized]?
}
private struct FDroidLocalized: Codable {
    let name: String?
    let summary: String?
    let description: String?
    let icon: String?
}
private struct FDroidPackage: Codable { let apkName: String; let versionName: String }

// MARK: - Husk Simple Schema
private struct HuskSimpleSource: Codable {
    let name: String
    let identifier: String
    let apps: [SourceAppCodable]
}
private struct SourceAppCodable: Codable {
    let name, bundleIdentifier, version, downloadURL, iconURL, localizedDescription: String
}

private enum SourcePolicy {
    static let maxIndexBytes = 64 * 1024 * 1024
    static let maxAPKBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let chunkBytes = 256 * 1024

    enum Failure: LocalizedError {
        case insecureURL
        case badResponse
        case tooLarge
        case invalidPackage

        var errorDescription: String? {
            switch self {
            case .insecureURL: return "Only HTTPS repository, icon, and APK URLs are accepted."
            case .badResponse: return "The server returned an invalid or unsuccessful HTTPS response."
            case .tooLarge: return "The download exceeds the safe size limit."
            case .invalidPackage: return "The repository entry has an invalid package identifier or download URL."
            }
        }
    }

    static func httpsURL(_ string: String) -> URL? {
        guard string.utf8.count <= 4096,
              let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    static func relativeHTTPSURL(_ string: String, to base: URL) -> URL? {
        guard string.utf8.count <= 4096,
              let candidate = URL(string: string, relativeTo: base)?.absoluteURL,
              candidate.scheme?.lowercased() == "https",
              candidate.host != nil, candidate.user == nil, candidate.password == nil else { return nil }
        return candidate
    }

    static func packageID(_ value: String) -> Bool {
        guard value.utf8.count <= 255 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 16 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.utf8.first,
                  (65...90).contains(first) || (97...122).contains(first) else { return false }
            return part.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 95
            }
        }
    }

    static func clean(_ text: String?, limit: Int) -> String {
        guard let text else { return "" }
        let filtered = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        let sanitized = String(String.UnicodeScalarView(filtered))
        return String(sanitized.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stream response bytes into a private temporary file, enforcing a hard limit
    /// while receiving them. Redirects to non-HTTPS URLs are rejected.
    static func download(_ url: URL, session: URLSession, limit: Int64,
                         progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw Failure.insecureURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
              response.url?.scheme?.lowercased() == "https",
              response.url?.user == nil, response.url?.password == nil else { throw Failure.badResponse }
        let expected = response.expectedContentLength
        guard expected <= 0 || expected <= limit else { throw Failure.tooLarge }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("husk-\(UUID().uuidString.lowercased()).part")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        var shouldRemove = true
        defer {
            try? handle.close()
            if shouldRemove { try? FileManager.default.removeItem(at: temporary) }
        }

        var buffer = Data()
        buffer.reserveCapacity(chunkBytes)
        var received: Int64 = 0
        do {
            for try await byte in stream {
                guard received + Int64(buffer.count) < limit else { throw Failure.tooLarge }
                buffer.append(byte)
                if buffer.count >= chunkBytes {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(received, expected)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
            }
            guard received > 0 else { throw Failure.badResponse }
            try handle.synchronize()
            try handle.close()
            progress(received, expected)
            shouldRemove = false
            return temporary
        } catch {
            throw error
        }
    }
}

// MARK: - Manager
@MainActor
final class SourceManager: ObservableObject {
    static let shared = SourceManager()

    @Published var sources: [AppSource] = []
    @Published var loadingSources: Set<String> = Set<String>()
    @Published var fetchErrors: [String: String] = [String: String]()
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadErrors: [String: String] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    var isLoading: Bool { !loadingSources.isEmpty }

    @Published var sourceURLs: [String] = [
        "https://f-droid.org/repo/index-v1.json"
    ] {
        didSet { UserDefaults.standard.set(sourceURLs, forKey: "HuskSourceURLs") }
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg)
    }()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "HuskSourceURLs"), !saved.isEmpty {
            sourceURLs = saved
        }
    }

    func fetchSources() async {
        for urlString in sourceURLs where !sources.contains(where: { $0.identifier == urlString }) {
            await fetchSource(urlString: urlString)
        }
    }

    func addSource(urlString: String) async {
        guard let url = SourcePolicy.httpsURL(urlString) else {
            fetchErrors[urlString] = SourcePolicy.Failure.insecureURL.localizedDescription
            return
        }
        let canonical = url.absoluteString
        guard !sourceURLs.contains(canonical) else { return }
        sourceURLs.append(canonical)
        await fetchSource(urlString: canonical)
    }

    func fetchSource(urlString: String) async {
        guard let url = SourcePolicy.httpsURL(urlString) else {
            fetchErrors[urlString] = SourcePolicy.Failure.insecureURL.localizedDescription
            return
        }

        loadingSources.insert(urlString)
        fetchErrors.removeValue(forKey: urlString)
        defer { loadingSources.remove(urlString) }

        do {
            let data = try await SourcePolicy.download(url, session: session,
                                                       limit: Int64(SourcePolicy.maxIndexBytes)) { _, _ in }
            defer { try? FileManager.default.removeItem(at: data) }
            // A source removed while this request is suspended must not be
            // resurrected when its response eventually completes.
            guard sourceURLs.contains(urlString) else { return }
            let index = try Data(contentsOf: data, options: [.mappedIfSafe])
            if let fdroid = try? JSONDecoder().decode(FDroidIndex.self, from: index) {
                try install(fdroid, sourceURL: urlString)
            } else if let simple = try? JSONDecoder().decode(HuskSimpleSource.self, from: index) {
                try install(simple, sourceURL: urlString)
            } else {
                fetchErrors[urlString] = "Unrecognized source format"
                HuskLog.log("sources", "Unrecognized format at \(urlString)")
            }
        } catch {
            fetchErrors[urlString] = error.localizedDescription
            HuskLog.log("sources", "Failed to fetch \(urlString): \(error.localizedDescription)")
        }
    }

    private func install(_ index: FDroidIndex, sourceURL: String) throws {
        guard let base = SourcePolicy.httpsURL(index.repo.address) else {
            throw SourcePolicy.Failure.insecureURL
        }
        var baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if baseComponents?.path.hasSuffix("/") == false { baseComponents?.path += "/" }
        guard let directoryBase = baseComponents?.url else { throw SourcePolicy.Failure.insecureURL }

        var apps: [SourceApp] = []
        apps.reserveCapacity(min(index.apps.count, 50_000))
        for fApp in index.apps.prefix(100_000) {
            guard SourcePolicy.packageID(fApp.packageName),
                  let packages = index.packages[fApp.packageName],
                  let latest = packages.first,
                  let download = SourcePolicy.relativeHTTPSURL(latest.apkName, to: directoryBase) else { continue }
            let loc = fApp.localized?["en-US"] ?? fApp.localized?.values.first
            let appName = SourcePolicy.clean(fApp.name ?? loc?.name ?? fApp.packageName, limit: 100)
            let summary = SourcePolicy.clean(fApp.summary ?? loc?.summary ?? fApp.description ?? loc?.description, limit: 360)
            let icon = (fApp.icon ?? loc?.icon).flatMap { SourcePolicy.relativeHTTPSURL($0, to: directoryBase)?.absoluteString } ?? ""
            apps.append(SourceApp(name: appName.isEmpty ? fApp.packageName : appName,
                                  bundleIdentifier: fApp.packageName,
                                  version: SourcePolicy.clean(latest.versionName, limit: 80),
                                  downloadURL: download.absoluteString,
                                  iconURL: icon,
                                  localizedDescription: summary))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        upsert(source: AppSource(name: SourcePolicy.clean(index.repo.name, limit: 100),
                                 identifier: sourceURL, apps: apps))
    }

    private func install(_ simple: HuskSimpleSource, sourceURL: String) throws {
        let apps: [SourceApp] = simple.apps.prefix(50_000).compactMap { item in
            guard SourcePolicy.packageID(item.bundleIdentifier),
                  let download = SourcePolicy.httpsURL(item.downloadURL) else { return nil }
            let icon = SourcePolicy.httpsURL(item.iconURL)?.absoluteString ?? ""
            return SourceApp(name: SourcePolicy.clean(item.name, limit: 100),
                             bundleIdentifier: item.bundleIdentifier,
                             version: SourcePolicy.clean(item.version, limit: 80),
                             downloadURL: download.absoluteString,
                             iconURL: icon,
                             localizedDescription: SourcePolicy.clean(item.localizedDescription, limit: 360))
        }
        upsert(source: AppSource(name: SourcePolicy.clean(simple.name, limit: 100),
                                 identifier: sourceURL, apps: apps))
    }

    func removeSource(urlString: String) {
        sourceURLs.removeAll { $0 == urlString }
        sources.removeAll { $0.identifier == urlString }
        fetchErrors.removeValue(forKey: urlString)
    }

    private func upsert(source: AppSource) {
        if let idx = sources.firstIndex(where: { $0.identifier == source.identifier }) {
            sources[idx] = source
        } else {
            sources.append(source)
        }
    }

    // MARK: - APK Download + Install

    func downloadAndInstall(app: SourceApp) {
        guard let url = SourcePolicy.httpsURL(app.downloadURL),
              SourcePolicy.packageID(app.bundleIdentifier) else {
            downloadErrors[app.bundleIdentifier] = SourcePolicy.Failure.invalidPackage.localizedDescription
            return
        }
        let key = app.bundleIdentifier
        guard downloadTasks[key] == nil else { return }
        downloadErrors.removeValue(forKey: key)
        downloadProgress[key] = 0.01
        HuskLog.log("sources", "Downloading \(app.name)")

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.downloadProgress.removeValue(forKey: key)
                self.downloadTasks.removeValue(forKey: key)
            }
            do {
                let temporary = try await SourcePolicy.download(url, session: self.session,
                    limit: SourcePolicy.maxAPKBytes) { received, total in
                        guard total > 0 else { return }
                        Task { @MainActor [weak self] in
                            self?.downloadProgress[key] = min(0.99, Double(received) / Double(total))
                        }
                    }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Downloaded_APKs", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).apk")
                try FileManager.default.copyItem(at: temporary, to: destination)
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: destination)
                    throw CancellationError()
                }
                AndroidHost.shared.install([destination])
            } catch is CancellationError {
                self.downloadErrors.removeValue(forKey: key)
            } catch {
                self.downloadErrors[key] = error.localizedDescription
                HuskLog.log("sources", "Download failed for \(key): \(error.localizedDescription)")
            }
        }
        downloadTasks[key] = task
    }

    func cancelDownload(bundleIdentifier: String) {
        downloadTasks[bundleIdentifier]?.cancel()
    }
}
