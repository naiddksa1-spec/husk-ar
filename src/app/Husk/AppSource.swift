import Foundation
import Combine

// Repository fields are untrusted, including names used in paths and commands.
enum SourceValidation {
    static func httpsURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return url
    }
    static func package(_ value: String) -> Bool {
        value.count <= 255 && value.range(
            of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#,
            options: .regularExpression) != nil
    }
    static func digest(_ value: String?) -> String? {
        guard let value, value.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return value.lowercased()
    }
    static func fileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.count <= 255
            && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

private final class SourceTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              SourceValidation.httpsURL(url.absoluteString) != nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

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
    var expectedSHA256: String? = nil
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
private struct FDroidPackage: Codable {
    let apkName, versionName: String
    let versionCode: Int64?
    let hash, hashType: String?
}

// MARK: - Husk Simple Schema
private struct HuskSimpleSource: Codable {
    let name: String; let identifier: String; let apps: [SourceAppCodable]
}
private struct SourceAppCodable: Codable {
    let name, bundleIdentifier, version, downloadURL, iconURL, localizedDescription: String
    let sha256: String?
}

// MARK: - Manager
@MainActor
final class SourceManager: ObservableObject {
    static let shared = SourceManager()

    @Published var sources: [AppSource] = []
    @Published var loadingSources: Set<String> = Set<String>()
    @Published var fetchErrors: [String: String] = [String: String]()
    @Published var downloadProgress: [String: Double] = [String: Double]()
    @Published var downloadErrors: [String: String] = [:]
    private var downloads: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private var lastFetch: Date?
    private let transport = SourceTransport()

    var isLoading: Bool { !loadingSources.isEmpty }

    @Published var sourceURLs: [String] = [
        "https://f-droid.org/repo/index-v1.json"
    ] {
        didSet {
            UserDefaults.standard.set(sourceURLs, forKey: "HuskSourceURLs")
        }
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg, delegate: transport, delegateQueue: nil)
    }()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "HuskSourceURLs"), !saved.isEmpty {
            sourceURLs = Array(Set(saved.filter { SourceValidation.httpsURL($0) != nil })).sorted()
        }
    }

    // Fetch everything (called on first appear / manual refresh)
    func fetchSources(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < 300,
           !sources.isEmpty { return }
        lastFetch = Date()
        for urlString in sourceURLs {
            if !sources.contains(where: { $0.identifier == urlString }) || loadingSources.isEmpty {
                await fetchSource(urlString: urlString)
            }
        }
    }

    // Add a new source and fetch ONLY that one
    func addSource(urlString: String) async {
        guard SourceValidation.httpsURL(urlString) != nil else {
            fetchErrors[urlString] = "استخدم رابط HTTPS صالحًا بدون بيانات دخول."
            return
        }
        guard !sourceURLs.contains(urlString) else { return }
        sourceURLs.append(urlString)
        await fetchSource(urlString: urlString)
    }

    // Fetch a single source by URL
    func fetchSource(urlString: String) async {
        guard !loadingSources.contains(urlString) else { return }
        guard let url = SourceValidation.httpsURL(urlString) else {
            fetchErrors[urlString] = "رابط HTTPS غير صالح"
            return
        }

        loadingSources.insert(urlString)
        fetchErrors.removeValue(forKey: urlString)

        defer { loadingSources.remove(urlString) }

        do {
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            try Self.validate(response)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 64 * 1024 * 1024 else {
                throw Self.failure("الفهرس فارغ أو أكبر من 64 MB.")
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)

            // Try F-Droid v1 format
            let fdroidIndex = await Task.detached(priority: .utility) {
                try? JSONDecoder().decode(FDroidIndex.self, from: data)
            }.value
            if let fdroid = fdroidIndex {
                let baseURL = fdroid.repo.address
                guard SourceValidation.httpsURL(baseURL) != nil else {
                    throw Self.failure("المصدر يعلن رابط تنزيل غير آمن.")
                }
                var apps: [SourceApp] = []
                var seen: Set<String> = []
                for fApp in fdroid.apps {
                    guard SourceValidation.package(fApp.packageName),
                          seen.insert(fApp.packageName).inserted,
                          let latest = fdroid.packages[fApp.packageName]?.max(by: {
                              ($0.versionCode ?? 0) < ($1.versionCode ?? 0)
                          }), SourceValidation.fileName(latest.apkName),
                          latest.hashType?.lowercased() == "sha256",
                          let digest = SourceValidation.digest(latest.hash) else { continue }
                    let loc = fApp.localized?["en-US"] ?? fApp.localized?.values.first
                    let appName = fApp.name ?? loc?.name ?? fApp.packageName
                    let appSummary = fApp.summary ?? loc?.summary ?? fApp.description ?? loc?.description ?? ""
                    let appIcon = fApp.icon ?? loc?.icon
                    let iconURL = appIcon.flatMap {
                        SourceValidation.fileName($0) ? "\(baseURL)/icons/\($0)" : nil
                    } ?? ""
                    
                    apps.append(SourceApp(
                        name: appName,
                        bundleIdentifier: fApp.packageName,
                        version: latest.versionName,
                        downloadURL: "\(baseURL)/\(latest.apkName)",
                        iconURL: iconURL,
                        localizedDescription: appSummary,
                        expectedSHA256: digest
                    ))
                }
                apps.sort { $0.name.lowercased() < $1.name.lowercased() }
                let source = AppSource(name: fdroid.repo.name, identifier: urlString, apps: apps)
                upsert(source: source)
            }
            // Fallback: Husk simple format
            else if let simple = await Task.detached(priority: .utility, operation: {
                try? JSONDecoder().decode(HuskSimpleSource.self, from: data)
            }).value {
                var seen: Set<String> = []
                let apps = simple.apps.compactMap { item -> SourceApp? in
                    guard SourceValidation.package(item.bundleIdentifier),
                          SourceValidation.httpsURL(item.downloadURL) != nil,
                          let digest = SourceValidation.digest(item.sha256),
                          seen.insert(item.bundleIdentifier).inserted else { return nil }
                    return SourceApp(name: item.name, bundleIdentifier: item.bundleIdentifier,
                              version: item.version, downloadURL: item.downloadURL,
                              iconURL: SourceValidation.httpsURL(item.iconURL)?.absoluteString ?? "",
                              localizedDescription: item.localizedDescription, expectedSHA256: digest)
                }
                let source = AppSource(name: simple.name, identifier: urlString, apps: apps)
                upsert(source: source)
            } else {
                fetchErrors[urlString] = "صيغة المصدر غير معروفة"
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
        guard sourceURLs.contains(source.identifier) else { return }
        if let idx = sources.firstIndex(where: { $0.identifier == source.identifier }) {
            sources[idx] = source
        } else {
            sources.append(source)
        }
    }

    // MARK: - APK Download + Install

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "ios-app.source", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    nonisolated private static func validate(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode), let url = http.url,
              SourceValidation.httpsURL(url.absoluteString) != nil else {
            throw failure("فشل التنزيل أو رفض الخادم الطلب.")
        }
    }

    func cancelDownload(_ id: String) { downloads[id]?.cancel() }

    func downloadAndInstall(app: SourceApp) {
        guard downloads[app.id] == nil else { return }
        guard let url = SourceValidation.httpsURL(app.downloadURL),
              SourceValidation.package(app.bundleIdentifier),
              let expected = SourceValidation.digest(app.expectedSHA256) else {
            downloadErrors[app.id] = "التنزيل يحتاج HTTPS وبصمة SHA-256 صالحة."
            return
        }
        downloadErrors.removeValue(forKey: app.id)
        downloadProgress[app.bundleIdentifier] = 0.01
        HuskLog.log("sources", "Downloading \(app.name)")

        let task = session.downloadTask(with: url) { localURL, response, error in
            // The temporary URL expires when this callback returns, so move it
            // synchronously before scheduling anything on the main actor.
            let result: Result<URL, Error>
            do {
                if let error { throw error }
                try Self.validate(response)
                guard let localURL else { throw Self.failure("لم يصل ملف التطبيق.") }
                let size = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 2_147_483_648 else {
                    throw Self.failure("ملف APK فارغ أو أكبر من 2 GB.")
                }
                guard DigestWriter.ofFile(at: localURL.path) == expected else {
                    throw Self.failure("بصمة الملف لا تطابق المصدر. لم يُثبّت التطبيق.")
                }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dir = docs.appendingPathComponent("Downloaded_APKs", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(UUID().uuidString + ".apk")
                try FileManager.default.moveItem(at: localURL, to: dest)
                result = .success(dest)
            } catch { result = .failure(error) }
            Task { @MainActor in
                self.observations.removeValue(forKey: app.id)
                self.downloads.removeValue(forKey: app.id)
                self.downloadProgress.removeValue(forKey: app.id)
                switch result {
                case .success(let dest): AndroidHost.shared.install([dest])
                case .failure(let error):
                    if (error as NSError).code != NSURLErrorCancelled {
                        self.downloadErrors[app.id] = error.localizedDescription
                    }
                }
            }
        }
        downloads[app.id] = task
        observations[app.id] = task.progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in
                guard self.downloads[app.id] != nil else { return }
                self.downloadProgress[app.id] = max(0, min(progress.fractionCompleted, 1))
            }
        }
        task.resume()
    }
}
