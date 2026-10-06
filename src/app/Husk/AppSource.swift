import Foundation
import CryptoKit

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
    /// بصمة SHA-256 المعلنة في الفهرس، إن وُجدت. يُرفض أي APK لا يطابقها.
    var sha256: String? = nil
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
    let apkName: String; let versionName: String
    let hash: String?; let hashType: String?
}

// MARK: - Husk Simple Schema
private struct HuskSimpleSource: Codable {
    let name: String; let identifier: String; let apps: [SourceAppCodable]
}
private struct SourceAppCodable: Codable {
    let name, bundleIdentifier, version, downloadURL, iconURL, localizedDescription: String
    let sha256: String?
}

/// ما يُستخرج من فهرس مستودع، بعيدًا عن الخيط الرئيسي.
private enum SourceParser {
    /// فهرس F-Droid قد يتجاوز عشرات الميغابايت؛ فكّه على الخيط الرئيسي كان
    /// يجمّد الواجهة لثوانٍ عند فتح تبويب اكتشف.
    static func parse(_ data: Data, identifier: String) -> AppSource? {
        let decoder = JSONDecoder()
        if let fdroid = try? decoder.decode(FDroidIndex.self, from: data) {
            let baseURL = fdroid.repo.address
            var apps: [SourceApp] = []
            apps.reserveCapacity(fdroid.apps.count)
            for fApp in fdroid.apps {
                guard AndroidHost.isValidPackage(fApp.packageName),
                      let pkgs = fdroid.packages[fApp.packageName], let latest = pkgs.first,
                      !latest.apkName.contains("/"), !latest.apkName.contains("..")
                else { continue }
                let loc = fApp.localized?["en-US"] ?? fApp.localized?.values.first
                let appName = fApp.name ?? loc?.name ?? fApp.packageName
                let appSummary = fApp.summary ?? loc?.summary ?? fApp.description ?? loc?.description ?? ""
                let appIcon = fApp.icon ?? loc?.icon
                let iconURL = appIcon.map { "\(baseURL)/icons/\($0)" } ?? ""
                let digest = (latest.hashType?.lowercased() == "sha256") ? latest.hash : nil
                apps.append(SourceApp(
                    name: appName,
                    bundleIdentifier: fApp.packageName,
                    version: latest.versionName,
                    downloadURL: "\(baseURL)/\(latest.apkName)",
                    iconURL: iconURL,
                    localizedDescription: appSummary,
                    sha256: digest?.lowercased()
                ))
            }
            apps.sort { $0.name.lowercased() < $1.name.lowercased() }
            return AppSource(name: fdroid.repo.name, identifier: identifier, apps: apps)
        }
        if let simple = try? decoder.decode(HuskSimpleSource.self, from: data) {
            let apps = simple.apps
                .filter { AndroidHost.isValidPackage($0.bundleIdentifier) }
                .map {
                    SourceApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                              version: $0.version, downloadURL: $0.downloadURL,
                              iconURL: $0.iconURL, localizedDescription: $0.localizedDescription,
                              sha256: $0.sha256?.lowercased())
                }
            return AppSource(name: simple.name, identifier: identifier, apps: apps)
        }
        return nil
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
            if !loadingSources.contains(urlString) {
                await fetchSource(urlString: urlString)
            }
        }
    }

    // Add a new source and fetch ONLY that one
    func addSource(urlString raw: String) async {
        let urlString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, !sourceURLs.contains(urlString) else { return }
        guard let u = URL(string: urlString), u.scheme?.lowercased() == "https", u.host != nil else {
            AndroidHost.shared.toast = Toast(title: "رابط غير صالح",
                                             detail: "يجب أن يبدأ المستودع بـ https://", good: false)
            return
        }
        sourceURLs.append(urlString)
        await fetchSource(urlString: urlString)
    }

    // Fetch a single source by URL
    func fetchSource(urlString: String) async {
        // أمان: المستودع يحدد أي ملف APK سيُثبَّت، فلا يُقبل إلا عبر HTTPS.
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https",
              url.host != nil else {
            fetchErrors[urlString] = "رابط غير صالح (يجب أن يبدأ بـ https://)"
            return
        }

        loadingSources.insert(urlString)
        fetchErrors.removeValue(forKey: urlString)

        defer { loadingSources.remove(urlString) }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                fetchErrors[urlString] = "الخادم ردّ بالرمز \(http.statusCode)"
                return
            }
            let parsed = await Task.detached(priority: .userInitiated) {
                SourceParser.parse(data, identifier: urlString)
            }.value
            if let source = parsed {
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
        if let idx = sources.firstIndex(where: { $0.identifier == source.identifier }) {
            sources[idx] = source
        } else {
            sources.append(source)
        }
    }

    // MARK: - APK Download + Install

    /// يبقي مراقبات التقدّم حيّة؛ كانت تُرمى فورًا فلا يتحرك شريط التقدّم أبدًا.
    private var progressObservers: [String: NSKeyValueObservation] = [:]

    func downloadAndInstall(app: SourceApp) {
        guard downloadProgress[app.bundleIdentifier] == nil else { return }
        guard AndroidHost.isValidPackage(app.bundleIdentifier),
              let url = URL(string: app.downloadURL), url.scheme?.lowercased() == "https" else {
            HuskLog.log("sources", "refusing download for \(app.bundleIdentifier): not https or bad package")
            AndroidHost.shared.toast = Toast(title: "رُفض التنزيل",
                                             detail: "رابط التطبيق غير آمن (ليس HTTPS).", good: false)
            return
        }
        downloadProgress[app.bundleIdentifier] = 0.01
        HuskLog.log("sources", "Downloading \(app.name)")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadDir = docs.appendingPathComponent("Downloaded_APKs", isDirectory: true)
        // أمان: الاسم مبني من بيانات المستودع، فيُنظَّف حتى لا يخرج من المجلد.
        let safeVersion = app.version.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let dest = downloadDir.appendingPathComponent("\(app.bundleIdentifier)-\(safeVersion).apk")
        let expected = app.sha256
        let id = app.bundleIdentifier

        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            // يجب نقل الملف هنا، قبل أن يعود هذا الإغلاق: النظام يحذف الملف المؤقت
            // فور عودته، والنسخة السابقة كانت تنقله لاحقًا داخل Task فتجده محذوفًا.
            var failure: String?
            if let error { failure = error.localizedDescription }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = "الخادم ردّ بالرمز \(http.statusCode)"
            } else if let localURL {
                do {
                    try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
                    if let expected {
                        let got = try Self.sha256(of: localURL)
                        guard got == expected else {
                            throw NSError(domain: "husk", code: 10, userInfo: [NSLocalizedDescriptionKey:
                                "بصمة الملف لا تطابق المستودع — قد يكون معدّلًا"])
                        }
                    }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: localURL, to: dest)
                } catch { failure = error.localizedDescription }
            } else { failure = "لم يصل أي ملف" }

            Task { @MainActor in
                self.downloadProgress.removeValue(forKey: id)
                self.progressObservers[id] = nil
                if let failure {
                    HuskLog.log("sources", "Download failed for \(id): \(failure)")
                    AndroidHost.shared.toast = Toast(title: "فشل التنزيل", detail: failure, good: false)
                } else {
                    if expected == nil { HuskLog.log("sources", "\(id): source published no sha256") }
                    AndroidHost.shared.install([dest])
                }
            }
        }
        progressObservers[id] = task.progress.observe(\.fractionCompleted) { progress, _ in
            let f = progress.fractionCompleted
            Task { @MainActor in
                if self.downloadProgress[id] != nil { self.downloadProgress[id] = max(0.01, f) }
            }
        }
        task.resume()
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
