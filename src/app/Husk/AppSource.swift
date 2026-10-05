import Foundation

// MARK: - Internal Model
struct AppSource: Identifiable, Equatable, Sendable {
    let name: String
    let identifier: String
    var apps: [SourceApp]
    var id: String { identifier }
}

struct SourceApp: Identifiable, Equatable, Sendable {
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
    let name: String; let identifier: String; let apps: [SourceAppCodable]
}
private struct SourceAppCodable: Codable {
    let name, bundleIdentifier, version, downloadURL, iconURL, localizedDescription: String
}

/// Limit disk downloads as they arrive, including unknown/chunked lengths.
/// HTTPS transport is not a replacement for signed repository metadata.
private final class SourceDownloadPolicy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static func secureURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.secureURL(url.absoluteString) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let limit: Int64 = downloadTask.taskDescription == "apk" ? 1_073_741_824 : 67_108_864
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Completion-handler/async download APIs handle the file themselves.
    }
}

// MARK: - Manager
@MainActor
final class SourceManager: ObservableObject {
    static let shared = SourceManager()

    @Published var sources: [AppSource] = []
    @Published var loadingSources: Set<String> = Set<String>()
    @Published var fetchErrors: [String: String] = [String: String]()
    @Published var downloadProgress: [String: Double] = [String: Double]()
    private var downloads: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]

    var isLoading: Bool { !loadingSources.isEmpty }

    @Published var sourceURLs: [String] = [
        "https://f-droid.org/repo/index-v1.json"
    ] {
        didSet {
            UserDefaults.standard.set(sourceURLs, forKey: "HuskSourceURLs")
        }
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg, delegate: SourceDownloadPolicy(), delegateQueue: nil)
    }()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "HuskSourceURLs"), !saved.isEmpty {
            sourceURLs = saved
        }
    }

    // Fetch everything (called on first appear / manual refresh)
    func fetchSources() async {
        let urls = sourceURLs
        // Bounded concurrency: do not make a slow source delay every other one.
        for offset in stride(from: 0, to: urls.count, by: 4) {
            await withTaskGroup(of: Void.self) { group in
                for url in urls[offset..<min(offset + 4, urls.count)] {
                    group.addTask { await self.fetchSource(urlString: url) }
                }
            }
        }
    }

    // Add a new source and fetch ONLY that one
    func addSource(urlString: String) async {
        guard !sourceURLs.contains(urlString) else { return }
        guard SourceDownloadPolicy.secureURL(urlString) != nil else {
            fetchErrors[urlString] = "المصدر يحتاج رابط HTTPS صالح"
            return
        }
        sourceURLs.append(urlString)
        await fetchSource(urlString: urlString)
    }

    // Fetch a single source by URL
    func fetchSource(urlString: String) async {
        guard !loadingSources.contains(urlString) else { return }
        guard let url = SourceDownloadPolicy.secureURL(urlString) else {
            fetchErrors[urlString] = "رابط غير صالح"
            return
        }

        loadingSources.insert(urlString)
        fetchErrors.removeValue(forKey: urlString)

        defer { loadingSources.remove(urlString) }

        do {
            let (local, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: local) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  SourceDownloadPolicy.secureURL(response.url?.absoluteString ?? "") != nil else {
                throw URLError(.badServerResponse)
            }
            let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= 67_108_864 else { throw URLError(.dataLengthExceedsMaximum) }
            let source = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: local, options: .mappedIfSafe)
                return try Self.decodeSource(data, identifier: urlString)
            }.value
            // A source may have been removed while its download was in flight.
            if sourceURLs.contains(urlString) { upsert(source: source) }
        } catch {
            fetchErrors[urlString] = error.localizedDescription
            HuskLog.log("sources", "Failed to fetch source: \(error.localizedDescription)")
        }
    }

    nonisolated private static func decodeSource(_ data: Data, identifier: String) throws -> AppSource {
            // Try F-Droid v1 format
            if let fdroid = try? JSONDecoder().decode(FDroidIndex.self, from: data) {
                guard fdroid.apps.count <= 10_000 else { throw URLError(.dataLengthExceedsMaximum) }
                let baseURL = fdroid.repo.address
                var apps: [SourceApp] = []
                for fApp in fdroid.apps {
                    guard let pkgs = fdroid.packages[fApp.packageName], let latest = pkgs.first else { continue }
                    let loc = fApp.localized?["en-US"] ?? fApp.localized?.values.first
                    let appName = fApp.name ?? loc?.name ?? fApp.packageName
                    let appSummary = fApp.summary ?? loc?.summary ?? fApp.description ?? loc?.description ?? ""
                    let appIcon = fApp.icon ?? loc?.icon
                    let iconURL = appIcon.map { "\(baseURL)/icons/\($0)" } ?? ""
                    
                    apps.append(SourceApp(
                        name: appName,
                        bundleIdentifier: fApp.packageName,
                        version: latest.versionName,
                        downloadURL: "\(baseURL)/\(latest.apkName)",
                        iconURL: iconURL,
                        localizedDescription: appSummary
                    ))
                }
                apps.sort { $0.name.lowercased() < $1.name.lowercased() }
                return AppSource(name: fdroid.repo.name, identifier: identifier, apps: apps)
            }
            // Fallback: Husk simple format
            else if let simple = try? JSONDecoder().decode(HuskSimpleSource.self, from: data) {
                guard simple.apps.count <= 10_000 else { throw URLError(.dataLengthExceedsMaximum) }
                let apps = simple.apps.map {
                    SourceApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                              version: $0.version, downloadURL: $0.downloadURL,
                              iconURL: $0.iconURL, localizedDescription: $0.localizedDescription)
                }
                return AppSource(name: simple.name, identifier: identifier, apps: apps)
            } else {
                throw NSError(domain: "husk.sources", code: 1, userInfo:
                    [NSLocalizedDescriptionKey: "صيغة المصدر غير معروفة"])
            }
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
        guard downloads[app.bundleIdentifier] == nil else { return }
        guard let url = SourceDownloadPolicy.secureURL(app.downloadURL) else {
            HuskLog.log("sources", "Rejected APK URL: HTTPS required")
            return
        }
        downloadProgress[app.bundleIdentifier] = 0.01
        HuskLog.log("sources", "Downloading \(app.name)")

        let task = session.downloadTask(with: url) { localURL, response, error in
            // URLSession deletes localURL when this callback returns. Move it
            // now, not in the subsequently scheduled MainActor task.
            let result: Result<URL, Error>
            do {
                if let error { throw error }
                guard let localURL, let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      SourceDownloadPolicy.secureURL(http.url?.absoluteString ?? "") != nil else {
                    throw URLError(.badServerResponse)
                }
                let fm = FileManager.default
                let size = (try fm.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0, size <= 1_073_741_824 else { throw URLError(.dataLengthExceedsMaximum) }
                let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let downloadDir = docs.appendingPathComponent("Downloaded_APKs", isDirectory: true)
                try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)
                let dest = downloadDir.appendingPathComponent(UUID().uuidString + ".apk")
                try fm.moveItem(at: localURL, to: dest)
                result = .success(dest)
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in
                self.downloadProgress.removeValue(forKey: app.bundleIdentifier)
                self.downloads.removeValue(forKey: app.bundleIdentifier)
                self.observations.removeValue(forKey: app.bundleIdentifier)
                switch result {
                case .success(let dest):
                    AndroidHost.shared.install([dest])
                case .failure(let error):
                    HuskLog.log("sources", "Download failed: \(error.localizedDescription)")
                }
            }
        }
        task.taskDescription = "apk"
        downloads[app.bundleIdentifier] = task
        observations[app.bundleIdentifier] = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if self.downloads[app.bundleIdentifier] != nil {
                    self.downloadProgress[app.bundleIdentifier] = fraction
                }
            }
        }
        task.resume()
    }
}
