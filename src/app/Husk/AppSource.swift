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
    let name: String; let identifier: String; let apps: [SourceAppCodable]
}
private struct SourceAppCodable: Codable {
    let name, bundleIdentifier, version, downloadURL, iconURL, localizedDescription: String
}

// MARK: - Manager
@MainActor
final class SourceManager: ObservableObject {
    static let shared = SourceManager()

    @Published var sources: [AppSource] = []
    @Published var loadingSources: Set<String> = Set<String>()
    @Published var fetchErrors: [String: String] = [String: String]()
    @Published var downloadProgress: [String: Double] = [String: Double]()

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
        return URLSession(configuration: cfg)
    }()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "HuskSourceURLs"), !saved.isEmpty {
            sourceURLs = saved
        }
    }

    // Fetch everything (called on first appear / manual refresh)
    func fetchSources() async {
        for urlString in sourceURLs {
            if !sources.contains(where: { $0.identifier == urlString }) || loadingSources.isEmpty {
                await fetchSource(urlString: urlString)
            }
        }
    }

    // Add a new source and fetch ONLY that one
    func addSource(urlString: String) async {
        guard !sourceURLs.contains(urlString) else { return }
        sourceURLs.append(urlString)
        await fetchSource(urlString: urlString)
    }

    // Fetch a single source by URL
    func fetchSource(urlString: String) async {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            fetchErrors[urlString] = "Use a valid HTTPS source URL without credentials."
            return
        }

        loadingSources.insert(urlString)
        fetchErrors.removeValue(forKey: urlString)

        defer { loadingSources.remove(urlString) }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), http.url?.scheme == "https", data.count <= 32 << 20 else {
                throw URLError(.badServerResponse)
            }

            // Try F-Droid v1 format
            if let fdroid = try? JSONDecoder().decode(FDroidIndex.self, from: data) {
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
                let source = AppSource(name: fdroid.repo.name, identifier: urlString, apps: apps)
                upsert(source: source)
            }
            // Fallback: Husk simple format
            else if let simple = try? JSONDecoder().decode(HuskSimpleSource.self, from: data) {
                let apps = simple.apps.map {
                    SourceApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                              version: $0.version, downloadURL: $0.downloadURL,
                              iconURL: $0.iconURL, localizedDescription: $0.localizedDescription)
                }
                let source = AppSource(name: simple.name, identifier: urlString, apps: apps)
                upsert(source: source)
            } else {
                fetchErrors[urlString] = "Unrecognized source format"
                HuskLog.log("sources", "Unrecognized format at \(urlString)")
            }
        } catch {
            fetchErrors[urlString] = error.localizedDescription
            HuskLog.log("sources", "Failed to fetch \(urlString): \(error)")
        }
    }

    func removeSource(urlString: String) {
        sourceURLs.removeAll { $0 == urlString }
        sources.removeAll { $0.identifier == urlString }
        fetchErrors.removeValue(forKey: urlString)
    }

    private func upsert(source: AppSource) {
        let source = AppSource(name: source.name, identifier: source.identifier, apps: source.apps.filter {
            $0.bundleIdentifier.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$", options: .regularExpression) != nil
        })
        if let idx = sources.firstIndex(where: { $0.identifier == source.identifier }) {
            sources[idx] = source
        } else {
            sources.append(source)
        }
    }

    // MARK: - APK Download + Install

    func downloadAndInstall(app: SourceApp) {
        guard downloadProgress[app.bundleIdentifier] == nil else { return }
        guard let url = URL(string: app.downloadURL), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else {
            fetchErrors[app.bundleIdentifier] = "The app download must use HTTPS."
            return
        }
        downloadProgress[app.bundleIdentifier] = 0
        fetchErrors.removeValue(forKey: app.bundleIdentifier)
        Task {
            defer { downloadProgress.removeValue(forKey: app.bundleIdentifier) }
            do {
                // Await the download so its temporary file is still alive when moved.
                let (localURL, response) = try await session.download(from: url)
                defer { try? FileManager.default.removeItem(at: localURL) }
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode), http.url?.scheme == "https" else {
                    throw URLError(.badServerResponse)
                }
                let handle = try FileHandle(forReadingFrom: localURL)
                let signature = try handle.read(upToCount: 4)
                try handle.close()
                guard signature == Data([0x50, 0x4b, 0x03, 0x04]) else {
                    throw URLError(.cannotDecodeContentData)
                }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let downloadDir = docs.appendingPathComponent("Downloaded_APKs", isDirectory: true)
                try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
                // Catalog metadata is untrusted; never turn it into a filesystem path.
                let dest = downloadDir.appendingPathComponent(UUID().uuidString + ".apk")
                try FileManager.default.moveItem(at: localURL, to: dest)
                downloadProgress[app.bundleIdentifier] = 1
                AndroidHost.shared.install([dest])
            } catch {
                fetchErrors[app.bundleIdentifier] = error.localizedDescription
                HuskLog.log("sources", "Download failed: \(error.localizedDescription)")
            }
        }
    }
}