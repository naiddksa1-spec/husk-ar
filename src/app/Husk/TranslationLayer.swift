// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Experimental: Android apps without booting Android.
///
/// Husk runs an APK by booting a whole Android system under QEMU and showing
/// one app's surface. That works, and it costs a kernel, an init, a system
/// server and minutes of emulated CPU before the first frame. Android
/// Translation Layer, on Linux, shows the other way: keep only the app's own
/// code -- its Dex and its native libraries -- and run it against a rewrite of
/// the Android framework on the host itself, so there is nothing to boot.
///
/// Doing that on iOS is a long road, and docs/04-translation-layer.md is the
/// map. What exists so far is the first stretch: apps can be added here and
/// each gets a report of what running it would take, and the phone can be
/// asked the questions the design rests on. Nothing opens an app yet, and
/// nothing here changes how the rest of Husk runs.
enum TranslationLayer {
    static let enabledKey = "husk.translationLayer"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Whether the technical detail is shown: library reports, device checks, logs. Off, the screens carry
    /// only what is needed to add an app, switch the layer on and run it. Set in Settings > About.
    static let devInfoKey = "husk.devInfo"

    /// One folder per app. Kept apart from Android's apps: those live on the
    /// guest's disk, and this runtime has no guest.
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranslationLayer", isDirectory: true)
    }
}

// MARK: - What the C side reports

/// One app, as src/translation-layer/husk-tl-scan.c sees it.
struct TLReport: Decodable {
    let ok: Bool
    let error: String?
    let verdict: String
    let summary: String
    let engine: String?
    let hasManifest: Bool
    let dexCount: Int
    let dexBytes: Int64
    let abis: [String]
    let systemLibraries: [String]
    let libraries: [TLLibrary]
}

extension TLReport {
    /// The engine the native runtime drives this app with, if it can: Unity (IL2CPP) games and cocos2d-x games.
    var nativeEngine: TLNativeEngine? {
        guard ok, !abis.isEmpty, abis.contains("arm64-v8a") else { return nil }
        if engine?.hasPrefix("Unity") == true { return .unity }
        if engine == "Cocos" { return .cocos }
        if engine == "Minecraft" { return .minecraft }
        return nil
    }

    /// Games from those engines run through the native runtime, which handles what the scan flags per library
    /// (raw system calls, thread-register use, pages shared between segments). A report made before that
    /// runtime existed still says "needs work", so the app judges by the engine, not by the stored words.
    var runsOnNativeRuntime: Bool { nativeEngine != nil }

    /// "Unity" or "Cocos2d-x", for words on screen.
    var nativeEngineName: String { nativeEngine == .cocos ? "Cocos2d-x" : nativeEngine == .minecraft ? "Minecraft" : "Unity" }

    var displaySummary: String {
        guard runsOnNativeRuntime else { return summary }
        let flagged = libraries.filter { $0.abi == "arm64-v8a" && $0.status != "ok" }.count
        let total = libraries.filter { $0.abi == "arm64-v8a" }.count
        var text = "لعبة \(nativeEngineName). تعمل عبر بيئة التشغيل الأصلية في Husk، التي تحمّل مكتباتها الـ \(total) من نوع arm64 بنفسها."
        if nativeEngine == .cocos || nativeEngine == .minecraft { text += " إنها لعبة أفقية: Husk يدير الشاشة لأجلها." }
        if flagged > 0 {
            text += " \(flagged) منها تستخدم حيلًا لم يستطع المحمّل القديم التعامل معها؛ بيئة التشغيل الأصلية تتعامل معها أيضًا، "
                  + "باستثناء كود الحماية من العبث الاختياري، الذي تتجاوزه."
        }
        return text
    }
}

/// One arm64 library. Everything past `notes` is absent when the file could
/// not be read as an arm64 library at all.
struct TLLibrary: Decodable, Identifiable {
    let name: String
    let abi: String
    let apk: String
    let bytes: Int64
    let compressed: Bool
    let status: String
    let notes: [String]
    let maxAlign: Int?
    let pages: Int?
    let execPages: Int?
    let writePages: Int?
    let conflictPages: Int?
    let layout: String?
    let svc: Int?
    let tpidrReads: Int?
    let tpidrWrites: Int?
    let tls: Bool?
    let textrel: Bool?
    let relocations: Int?
    let tlsRelocations: Int?
    let unsupportedRelocations: Int?
    let packing: String?
    let imports: Int?
    let soname: String?
    let needed: [String]?

    var id: String { "\(apk)/\(abi)/\(name)" }
}

/// One answer from husk-tl-probe.c.
struct TLCheck: Decodable, Identifiable {
    let id: String
    let title: String
    let status: String
    let detail: String
}

struct TLApp: Identifiable {
    /// The folder's name.
    let id: String
    var label: String
    var iconPath: String?
    var apks: [String]
    var report: TLReport?
}

// MARK: - Store

/// The apps added for the translation layer, and the phone's answers.
@MainActor
final class TranslationLayerStore: ObservableObject {
    static let shared = TranslationLayerStore()

    @Published private(set) var apps: [TLApp] = []
    /// What is being done right now, in words.
    @Published private(set) var busy: String?
    @Published private(set) var checks: [TLCheck] = []
    @Published private(set) var checking = false
    @Published var lastError: String?

    private init() { reload() }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: TranslationLayer.root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        apps = dirs.compactMap(Self.load).sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Keep a copy of one app -- one APK, or a base APK and its splits,
    /// picked together -- and report on it.
    func add(_ urls: [URL], move: Bool = false) {
        guard !urls.isEmpty, busy == nil else { return }
        busy = urls.count == 1 ? "جارٍ إضافة \(urls[0].lastPathComponent)…"
                               : "جارٍ إضافة \(urls.count) ملفات APK…"
        Task.detached(priority: .userInitiated) {
            let failure = Self.ingest(urls, move: move)
            await MainActor.run {
                self.busy = nil
                self.lastError = failure
                self.reload()
                if failure == nil, move { self.adoptDroppedAPKs() }      // the next one waiting, if several were put there
            }
        }
    }

    /// APKs put straight into Husk's folder (Files > On My iPhone > Husk, which the app shares) are taken in as apps, one each, and
    /// moved rather than copied, so a big one costs no second copy's worth of storage. This is the way in that needs no file picker.
    func adoptDroppedAPKs() {
        guard busy == nil, let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dropped = ((try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "apk" }
        guard let first = dropped.first else { return }
        HuskLog.log("tl", "adopting \(dropped.count) APK(s) found in the Husk folder")
        add([first], move: true)
    }

    func remove(_ app: TLApp) {
        let dir = TranslationLayer.root.appendingPathComponent(app.id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        HuskLog.log("tl", "removed \(app.label)")
        reload()
    }

    func runChecks() {
        guard !checking else { return }
        checking = true
        Task.detached(priority: .userInitiated) {
            // Generated code only runs where MAP_JIT is already known to
            // execute -- the same measurement Settings > JIT shows.
            let mayExecute = JITBootstrap.mapJITWorks
            HuskLog.log("tl", "running device checks (may execute: \(mayExecute))")
            let raw = husk_tl_run_checks(mayExecute)
            let json = raw.map { String(cString: $0) } ?? "[]"
            husk_tl_free(raw)
            let parsed = (try? JSONDecoder().decode([TLCheck].self, from: Data(json.utf8))) ?? []
            HuskLog.log("tl", "device checks: \(json)")
            await MainActor.run {
                self.checks = parsed
                self.checking = false
            }
        }
    }

    // MARK: files

    nonisolated private static func load(_ dir: URL) -> TLApp? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let apks = files.filter { $0.lowercased().hasSuffix(".apk") }.sorted()
            .map { dir.appendingPathComponent($0).path }
        guard let first = apks.first else { return nil }

        let saved = try? String(contentsOf: dir.appendingPathComponent("label.txt"),
                                encoding: .utf8)
        let label = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let icon = dir.appendingPathComponent("icon.png").path
        let report = (try? Data(contentsOf: dir.appendingPathComponent("report.json")))
            .flatMap { try? JSONDecoder().decode(TLReport.self, from: $0) }
        return TLApp(id: dir.lastPathComponent,
                     label: label.isEmpty ? (first as NSString).lastPathComponent : label,
                     iconPath: fm.fileExists(atPath: icon) ? icon : nil,
                     apks: apks, report: report)
    }

    /// Copy, name, scan. Returns what went wrong, if anything did.
    nonisolated private static func ingest(_ urls: [URL], move: Bool = false) -> String? {
        let fm = FileManager.default
        let dir = TranslationLayer.root.appendingPathComponent(UUID().uuidString,
                                                               isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in urls {
                // Security-scoped: the picker's URL is only readable inside this pair.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var name = url.lastPathComponent
                if !name.lowercased().hasSuffix(".apk") { name += ".apk" }
                let dest = dir.appendingPathComponent(name)
                if move {
                    try fm.moveItem(at: url, to: dest)
                } else {
                    // Coordinated, so a file that lives in iCloud and is not on the phone yet is downloaded first
                    // (a plain copy of it fails, or finds nothing).
                    var coordinationError: NSError?
                    var copyError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                        do { try fm.copyItem(at: readable, to: dest) } catch { copyError = error }
                    }
                    if let failure = coordinationError ?? copyError { throw failure }
                }
            }
        } catch {
            try? fm.removeItem(at: dir)
            HuskLog.log("tl", "FAILED to add: \(error.localizedDescription)")
            return "تعذّر على Husk نسخه: \(error.localizedDescription)"
        }

        let apks = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".apk") }.sorted()
            .map { dir.appendingPathComponent($0).path }
        describe(apks, into: dir)
        let json = scan(apks)
        try? Data(json.utf8).write(to: dir.appendingPathComponent("report.json"))
        HuskLog.log("tl", "report for \(dir.lastPathComponent): \(json)")
        return nil
    }

    /// The app's own name and icon, from its manifest and resource table --
    /// the same reading the library does for apps inside Android, done here on
    /// the file directly.
    nonisolated private static func describe(_ apks: [String], into dir: URL) {
        // The base APK carries the label and the icon; a config split's
        // manifest names neither. The base is usually called base.apk, and
        // otherwise usually the biggest.
        func size(_ path: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?
                .intValue ?? 0
        }
        let ordered = apks.sorted { a, b in
            let aBase = (a as NSString).lastPathComponent == "base.apk"
            let bBase = (b as NSString).lastPathComponent == "base.apk"
            return aBase != bBase ? aBase : size(a) > size(b)
        }
        for apk in ordered {
            guard let manifest = entry(apk, "AndroidManifest.xml", limit: 8 << 20),
                  let arsc = entry(apk, "resources.arsc", limit: 64 << 20) else { continue }
            let info = ApkMetadata.read(manifest: manifest, resources: arsc)
            guard info.label != nil || info.iconEntry != nil else { continue }

            if let label = info.label {
                try? label.write(to: dir.appendingPathComponent("label.txt"),
                                 atomically: true, encoding: .utf8)
            }
            // An adaptive icon is an instruction, not a picture: follow it to
            // the layer it draws in front.
            var iconEntry = info.iconEntry
            if let xml = iconEntry, xml.hasSuffix(".xml") {
                iconEntry = nil
                if let data = entry(apk, xml, limit: 4 << 20),
                   let layer = ApkMetadata.adaptiveLayer(data),
                   let bitmap = ApkMetadata.bitmap(for: layer, resources: arsc),
                   !bitmap.hasSuffix(".xml") {
                    iconEntry = bitmap
                }
            }
            // Stored as PNG whatever it was, so the icon view needs no WebP.
            if let iconEntry, let data = entry(apk, iconEntry, limit: 16 << 20),
               let png = UIImage(data: data)?.pngData() {
                try? png.write(to: dir.appendingPathComponent("icon.png"))
            }
            HuskLog.log("tl", "\((apk as NSString).lastPathComponent): "
                            + "label=\(info.label ?? "?") icon=\(iconEntry ?? "?")")
            return
        }
    }

    nonisolated static func entry(_ apk: String, _ name: String, limit: Int) -> Data? {
        var length = 0
        guard let bytes = husk_tl_read_entry(apk, name, limit, &length) else { return nil }
        defer { husk_tl_free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    nonisolated static func scan(_ paths: [String]) -> String {
        let owned = paths.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let pointers = owned.map { UnsafePointer<CChar>($0) }
        let raw = pointers.withUnsafeBufferPointer {
            husk_tl_scan($0.baseAddress, Int32($0.count))
        }
        defer { husk_tl_free(raw) }
        return raw.map { String(cString: $0) } ?? "{}"
    }
}

// MARK: - Settings

struct TranslationLayerSettings: View {
    @ObservedObject private var store = TranslationLayerStore.shared
    @State private var enabled = TranslationLayer.isEnabled
    @State private var importing = false
    @AppStorage(TranslationLayer.devInfoKey) private var devInfo = false

    var body: some View {
        Form {
            Section {
                Toggle("Android Translation Layer", isOn: $enabled)
                    .onChange(of: enabled) { v in
                        UserDefaults.standard.set(v, forKey: TranslationLayer.enabledKey)
                        HuskLog.log("ui", v ? "translation layer on" : "translation layer off")
                    }
            } header: {
                Text("تجريبي")
            } footer: {
                if !devInfo {
                    Text("يشغّل بعض تطبيقات أندرويد، مثل ألعاب Unity و cocos2d-x، مباشرة على آيفونك دون تشغيل "
                       + "أندرويد. تجريبي، ويحتاج تفعيل JIT.")
                } else {
                Text("يشغّل كود التطبيق نفسه مباشرة، مقابل إعادة كتابة لإطار "
                   + "عمل أندرويد، بدلًا من إقلاع نظام أندرويد كامل — نفس "
                   + "نهج Android Translation Layer على لينكس، أُعيد بناؤه لـ iOS. "
                   + "يستطيع تشغيل ألعاب Unity و cocos2d-x (تجريبي) ويُبلغ عما تحتاجه التطبيقات الأخرى، "
                   + "ويفحص هذا الآيفون للتحقق مما يعتمد عليه التصميم. "
                   + "أندرويد نفسه لا يتأثر في الحالتين.")
                }
            }

            if enabled {
                appsSection
                if devInfo {
                    checksSection
                    progressSection
                }
            }
        }
        .huskForm()
        .navigationTitle("Translation Layer")
        .huskFilePicker(isPresented: $importing) { urls in
            HuskLog.log("ui", "translation layer: adding \(urls.count) file(s): "
                      + urls.map(\.lastPathComponent).joined(separator: ", "))
            store.add(urls)
        }
        .onAppear { store.adoptDroppedAPKs() }
        .alert("تعذّرت إضافة التطبيق", isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } })) {
            Button("حسنًا", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var appsSection: some View {
        Section {
            ForEach(store.apps) { app in
                NavigationLink {
                    TLAppReportView(app: app)
                } label: {
                    TLAppRow(app: app)
                }
            }
            if let busy = store.busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(busy).foregroundStyle(Theme.textDim)
                }
            }
            Button {
                importing = true
            } label: {
                Label("إضافة APK", systemImage: "plus")
            }
            .disabled(store.busy != nil)
        } header: {
            Text("التطبيقات")
        } footer: {
            Text("يحتفظ Husk بنسخته الخاصة، منفصلة عن نسخة أندرويد. اختر ملف APK الأساسي "
               + "وقطعه المنقسمة معًا لإضافتها كتطبيق واحد.")
        }
    }

    private var checksSection: some View {
        Section {
            ForEach(store.checks) { check in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(check.title).foregroundStyle(Theme.text)
                        Spacer(minLength: 8)
                        TLCheckTag(status: check.status)
                    }
                    Text(check.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
            }
            Button {
                store.runChecks()
            } label: {
                Label(store.checking ? "جارٍ الفحص…"
                      : store.checks.isEmpty ? "تشغيل الفحوصات" : "إعادة التشغيل",
                      systemImage: "stethoscope")
            }
            .disabled(store.checking)
        } header: {
            Text("هذا الآيفون")
        } footer: {
            Text("الكود الأصلي لأندرويد يتوقع أمورًا من المعالج والذاكرة "
               + "لا يجيب عنها إلا الهاتف — وأهمها: هل يمكن لكود مكتبة "
               + "أن يعمل وبياناته قابلة للكتابة بجانبه مباشرة. فعّل JIT أولًا، وإلا "
               + "تُتخطّى فحوصات الذاكرة. النتائج تذهب إلى سجل النظام أيضًا.")
        }
    }

    private var progressSection: some View {
        Section {
            DetailRow(label: "تقارير التطبيقات", value: "يعمل", mono: false)
            DetailRow(label: "فحوصات الجهاز", value: "يعمل", mono: false)
            DetailRow(label: "محمّل المكتبات", value: "يعمل", mono: false)
            DetailRow(label: "بيئة تشغيل أندرويد", value: "ألعاب Unity و cocos2d-x", mono: false)
            DetailRow(label: "فتح التطبيقات", value: "ألعاب Unity و cocos2d-x (تجريبي)", mono: false)
        } header: {
            Text("أين وصلنا")
        } footer: {
            Text("الخطة بالترتيب موجودة في docs/04-translation-layer.md ضمن سورس Husk.")
        }
    }
}

/// A verdict, as words and a colour.
struct TLVerdict {
    let title: String
    let tint: Color

    init(_ report: TLReport?) {
        if report?.runsOnNativeRuntime == true {
            title = "\(report!.nativeEngineName): التشغيل الأصلي"; tint = Theme.good
            return
        }
        switch report?.verdict {
        case "java"?:           title = "جافا فقط";                  tint = Theme.good
        case "native"?:         title = "كود أصلي، يُحمّل بسلاسة";   tint = Theme.good
        case "nativeWithWork"?: title = "كود أصلي، يحتاج عملًا";     tint = .orange
        case "noArm64"?:        title = "لا يوجد كود arm64";          tint = .red
        case "unreadable"?:     title = "تعذّرت قراءته";              tint = .red
        default:                title = "لم يُفحص";                   tint = Theme.textDim
        }
    }
}

/// What a person who is not debugging needs to know about an app: can it be run, or is it only an experiment.
struct TLPlainStatus {
    let title: String
    let tint: Color

    init(_ report: TLReport?) {
        if report?.runsOnNativeRuntime == true { title = "جاهز للتشغيل"; tint = Theme.good }
        else { title = "تجريبي"; tint = Theme.textDim }
    }
}

private struct TLAppRow: View {
    let app: TLApp
    @AppStorage(TranslationLayer.devInfoKey) private var devInfo = false

    var body: some View {
        let verdict = TLVerdict(app.report)
        let plain = TLPlainStatus(app.report)
        HStack(spacing: 12) {
            AppIcon(path: app.iconPath, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.label).foregroundStyle(Theme.text).lineLimit(1)
                Text(devInfo ? verdict.title : plain.title)
                    .font(.system(size: 12))
                    .foregroundStyle(devInfo ? verdict.tint : plain.tint)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TLCheckTag: View {
    let status: String

    var body: some View {
        switch status {
        case "pass":    Tag(text: "ناجح", tint: Theme.good)
        case "fail":    Tag(text: "فاشل", tint: .red)
        case "warn":    Tag(text: "جزئيًا", tint: .orange)
        case "skip":    Tag(text: "متخطّى")
        default:        Tag(text: "معلومة", tint: Theme.accent)
        }
    }
}

// MARK: - One app's report

struct TLAppReportView: View {
    let app: TLApp

    @ObservedObject private var store = TranslationLayerStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var showAttempt = false
    @AppStorage(TranslationLayer.devInfoKey) private var devInfo = false

    var body: some View {
        let verdict = TLVerdict(app.report)
        let plain = TLPlainStatus(app.report)
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIcon(path: app.iconPath, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.label)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(devInfo ? verdict.title : plain.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(devInfo ? verdict.tint : plain.tint)
                    }
                }
                .padding(.vertical, 4)
                if devInfo, let report = app.report {
                    Text(report.displaySummary)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button {
                    showAttempt = true
                } label: {
                    HStack {
                        Label("تجربة تشغيل (Translation Layer)", systemImage: "play.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.textDim.opacity(0.5))
                    }
                }
            } footer: {
                if devInfo {
                    Text("يحمّل الكود الأصلي arm64 في ذاكرة JIT على Apple Silicon ويقود "
                       + "دورة حياة NativeActivity. التطبيقات ذات Java/Dex تتطلب ART (المرحلة 2).")
                } else {
                    Text("فعّل JIT أولًا. أغلق اللعبة بزر «إغلاق» في الأعلى.")
                }
            }

            if devInfo, let report = app.report {
                Section {
                    if let engine = report.engine {
                        DetailRow(label: "صُنع بـ", value: engine, mono: false)
                    }
                    DetailRow(label: "Dex", value: dex(report), mono: false)
                    DetailRow(label: "ABIs", value: report.abis.isEmpty
                              ? "لا يوجد" : report.abis.joined(separator: ", "))
                    DetailRow(label: "ملفات APK", value: "\(app.apks.count)", mono: false)
                } header: {
                    Text("ما هو")
                }

                if !report.systemLibraries.isEmpty {
                    Section {
                        Text(report.systemLibraries.joined(separator: "  "))
                            .font(.technical(12))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    } header: {
                        Text("مكتبات أندرويد التي يحتاجها")
                    } footer: {
                        Text("مكتباته الخاصة ترتبط بهذه، وهو لا يحملها معه. كل واحدة منها شيء يجب أن توفره طبقة الترجمة.")
                    }
                }

                ForEach(report.libraries) { lib in
                    Section {
                        TLLibraryRows(lib: lib)
                    } header: {
                        Text(lib.name).textCase(nil)
                    }
                }
            }

            Section {
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("إزالة", systemImage: "trash")
                }
            } footer: {
                Text("يحذف نسخة Husk من ملفات APK. أي شيء مثبت في أندرويد لا يُمس.")
            }
        }
        .huskForm()
        .navigationTitle(app.label)
        .confirmationDialog("إزالة \(app.label)؟", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("إزالة", role: .destructive) {
                store.remove(app)
                dismiss()
            }
            Button("إلغاء", role: .cancel) { }
        }
        // A native-runtime game is swiped, and a sheet takes a swipe down for itself: it goes full screen.
        .sheet(isPresented: Binding(get: { showAttempt && app.report?.runsOnNativeRuntime != true },
                                    set: { showAttempt = $0 })) {
            TLAttemptView(app: app)
        }
        .fullScreenCover(isPresented: Binding(get: { showAttempt && app.report?.runsOnNativeRuntime == true },
                                              set: { showAttempt = $0 })) {
            TLAttemptView(app: app)
        }
    }

    private func dex(_ report: TLReport) -> String {
        let files = report.dexCount == 1 ? "ملف واحد" : "\(report.dexCount) ملفات"
        let size = ByteCountFormatter.string(fromByteCount: report.dexBytes, countStyle: .file)
        return "\(files), \(size)"
    }
}

private struct TLLibraryRows: View {
    let lib: TLLibrary

    private var statusTitle: String {
        switch lib.status {
        case "ok":      return "يُحمّل كما هو"
        case "work":    return "يحتاج عملًا في المحمّل"
        default:        return "تعذّر تحميله"
        }
    }

    private func relocationText(_ count: Int) -> String {
        guard let packing = lib.packing, packing != "none" else { return "\(count)" }
        return "\(count) (\(packing))"
    }

    private var statusTint: Color {
        switch lib.status {
        case "ok":      return Theme.good
        case "work":    return .orange
        default:        return .red
        }
    }

    var body: some View {
        HStack {
            Tag(text: statusTitle, tint: statusTint)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: lib.bytes, countStyle: .file))
                .foregroundStyle(Theme.textDim)
        }
        ForEach(lib.notes, id: \.self) { note in
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let layout = lib.layout {
            DetailRow(label: "صفحات 16 KiB", value: layout)
        }
        if let relocations = lib.relocations {
            DetailRow(label: "إعادة التموضع", value: relocationText(relocations))
        }
        if let imports = lib.imports {
            DetailRow(label: "الرموز المستوردة", value: "\(imports)")
        }
        if let svc = lib.svc, svc > 0 {
            DetailRow(label: "استدعاءات النظام", value: "\(svc)")
        }
        if let reads = lib.tpidrReads {
            DetailRow(label: "قراءات سجل الخيط", value: "\(reads)")
        }
        if lib.tls == true {
            DetailRow(label: "التخزين المحلي للخيط", value: "نعم", mono: false)
        }
    }
}

// MARK: - Live Attempt Execution & Screen

@MainActor
final class TLAttemptRunner: ObservableObject {
    @Published var isRunning = false
    @Published var isDone = false
    @Published var exitCode: Int? = nil
    @Published var frameCount = 0
    @Published var logText: String = ""

    private var timer: Timer?

    var statusText: String {
        if isRunning { return "جارٍ تنفيذ المحاولة…" }
        guard let code = exitCode else { return "جاهز" }
        switch code {
        case 2:  return "نجاح: رسم الضيف إطارات!"
        case 1:  return "تم التحميل: حُمّلت المكتبات الأصلية (بدون رسم)"
        default: return "مرفوض: تعذّر التنفيذ"
        }
    }

    var statusColor: Color {
        if isRunning { return Theme.accent }
        guard let code = exitCode else { return Theme.textDim }
        switch code {
        case 2:  return Theme.good
        case 1:  return .orange
        default: return .red
        }
    }

    var subStatusText: String {
        if isRunning {
            return "\(frameCount) إطار مرسَل · جارٍ قيادة دورة الحياة"
        }
        if let code = exitCode {
            return "رمز الخروج \(code) · \(frameCount) إطار مرسوم"
        }
        return "لم يبدأ بعد"
    }

    private var pollTicks: Int = 0

    /// `seconds` of 0 is no limit: the run goes on until it is stopped. It used to stop itself after two minutes.
    func start(apks: [String], seconds: Int = 0) {
        guard !isRunning else { return }
        isRunning = true
        isDone = false
        exitCode = nil
        frameCount = 0
        logText = ""
        pollTicks = 0

        DispatchQueue.global(qos: .userInitiated).async {
            let owned = apks.map { strdup($0) }
            defer { owned.forEach { free($0) } }
            let pointers = owned.map { UnsafePointer<CChar>($0) }
            let rc = pointers.withUnsafeBufferPointer {
                husk_tl_attempt_start($0.baseAddress, Int32($0.count), Int32(seconds))
            }
            if rc != 0 {
                Task { @MainActor in
                    self.isRunning = false
                    self.isDone = true
                    self.exitCode = -1
                    self.poll()
                }
                return
            }

            Task { @MainActor in
                // Ten times a second is plenty for a status line and a log. The
                // screen no longer comes through here: it presents itself from a
                // display link, so this timer is no longer on the frame's path.
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.poll()
                }
            }
        }
    }

    func stop() {
        husk_tl_attempt_stop()
        poll()
    }

    private func poll() {
        pollTicks += 1
        if pollTicks % 5 == 0 {
            updateLog()
        }
        let n = Int(husk_tl_attempt_frames())
        if n != frameCount { frameCount = n }

        var code: Int32 = 0
        if husk_tl_attempt_done(&code) {
            timer?.invalidate()
            timer = nil
            isRunning = false
            isDone = true
            exitCode = Int(code)
            updateLog()
            frameCount = Int(husk_tl_attempt_frames())
        }
    }

    private func updateLog() {
        if let cLog = husk_tl_attempt_log() {
            let text = String(cString: cLog)
            free(cLog)
            if text != self.logText {
                self.logText = text
            }
        }
    }
}

/// Unity and cocos2d-x games run through the native runtime (src/translation-layer-next); everything else through
/// the older prototype loader.
struct TLAttemptView: View {
    let app: TLApp
    @State private var trustedThisLaunch = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if !trustedThisLaunch {
            VStack(spacing: 20) {
                Text("تنبيه أمني: التشغيل الأصلي غير معزول")
                    .font(.headline)
                Text("كود هذا APK يعمل داخل Husk وقد يصل إلى بياناته. استخدم أندرويد داخل الضيف للملفات غير الموثوقة. هذا الإذن لهذه المحاولة فقط.")
                    .multilineTextAlignment(.center)
                Button("تثبيت داخل أندرويد بدلاً من التشغيل الأصلي") {
                    AndroidHost.shared.install(app.apks.map { URL(fileURLWithPath: $0) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button("أثق بهذا APK: تشغيل أصلي تجريبي") {
                    trustedThisLaunch = true
                }
                .buttonStyle(.bordered)
                Button("إلغاء") { dismiss() }
            }
            .padding()
        } else if app.report?.nativeEngine == .cocos || app.report?.nativeEngine == .minecraft {
            TLCocosAttemptView(app: app)
        } else if app.report?.runsOnNativeRuntime == true {
            TLUnityAttemptView(app: app)
        } else {
            TLClassicAttemptView(app: app)
        }
    }
}

struct TLClassicAttemptView: View {
    let app: TLApp
    @StateObject private var runner = TLAttemptRunner()
    @Environment(\.dismiss) private var dismiss
    /// Whether the log is open. Remembered, so a game opened again comes back the
    /// way it was left.
    @AppStorage("husk.tl.showLog") private var showLogSetting = true
    @AppStorage(TranslationLayer.devInfoKey) private var devInfo = false
    /// The log is detail: without developer info it stays shut and its bar is not shown at all.
    private var showLog: Bool { get { showLogSetting && devInfo } nonmutating set { showLogSetting = newValue } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(runner.statusText)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(runner.statusColor)
                        Text(runner.subStatusText)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    if runner.isRunning {
                        Button("إيقاف") {
                            runner.stop()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button("إعادة التشغيل") {
                            runner.start(apks: app.apks)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(Theme.surface)

                Divider()

                // The game takes whatever the log leaves. With the log open it is a
                // fixed 380 points; closed, it fills the rest of the screen.
                if runner.isRunning || runner.frameCount > 0 {
                    TLScreenView()
                        .frame(maxWidth: .infinity, maxHeight: showLog ? 380 : .infinity)
                        .background(Color.black)
                    Divider()
                }

                if devInfo {
                // The log's bar, always there: it is the way back in once the log
                // is closed, so it cannot be part of what closes.
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { showLog.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showLog ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 12)
                            Text("سجلّ المحاولة")
                                .font(.technical(11, weight: .bold))
                        }
                        .foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if showLog {
                        Button {
                            UIPasteboard.general.string = runner.logText
                        } label: {
                            Label("نسخ", systemImage: "doc.on.doc")
                                .font(.system(size: 12))
                        }
                    } else {
                        Text("انقر للعرض")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim.opacity(0.7))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !showLog { withAnimation(.snappy(duration: 0.25)) { showLog = true } }
                }

                }

                if showLog {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(runner.logText.isEmpty ? "جارٍ بدء المحاولة…" : runner.logText)
                                .font(.technical(11))
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .textSelection(.enabled)
                                .id("bottom")
                        }
                        .background(Theme.bg)
                        .onChange(of: runner.logText) { _ in
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle(app.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") {
                        runner.stop()
                        dismiss()
                    }
                }
            }
            .onAppear {
                runner.start(apks: app.apks)
            }
            .onDisappear {
                runner.stop()
            }
        }
    }
}

