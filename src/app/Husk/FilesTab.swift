// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The guest's storage, browsable.
///
/// Husk could already push a file into Android's Download folder and never show
/// you what happened to it, which is a one-way street: you cannot check a game
/// found its data pack, or get a screenshot back, or see why an install failed
/// on a file that is not where you think it is. Everything here is `stat` and
/// `find` over the same bridge the rest of the app uses — no agent, no adb.
struct FilesTab: View {
    static let root = "/sdcard"

    @ObservedObject private var host = AndroidHost.shared
    @ObservedObject private var router = Router.shared

    var body: some View {
        NavigationStack(path: $router.files) {
            DirectoryView(path: Self.root, title: "الملفات")
                .navigationDestination(for: String.self) { path in
                    DirectoryView(path: path,
                                  title: (path as NSString).lastPathComponent)
                }
        }
    }
}

/// One directory — مصمم من الصفر بأسلوب تطبيق الملفات في آيفون: قائمة مجمّعة
/// أصلية، شريط التخزين في الأعلى، وسحب للتحديث.
struct DirectoryView: View {
    let path: String
    let title: String

    @ObservedObject private var host = AndroidHost.shared
    @State private var entries: [AndroidHost.GuestEntry] = []
    @State private var space: (free: Int64, total: Int64)?
    @State private var loading = true
    @State private var failure: String?
    @State private var importing = false
    @State private var showImportSheet = false
    @State private var installing: AndroidHost.GuestEntry?

    var body: some View {
        List {
            if path != FilesTab.root {
                Section {
                    Label(path, systemImage: "folder")
                        .font(.technical(12))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            if let space {
                Section { storage(space) }
            }
            if loading && entries.isEmpty {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 30)
                        .listRowBackground(Color.clear)
                }
            } else if let failure {
                Section {
                    EmptyState(title: "تعذّر قراءة هذا المجلد",
                               message: failure, systemImage: "lock.fill")
                        .listRowBackground(Color.clear)
                }
            } else if entries.isEmpty {
                Section {
                    EmptyState(title: "المجلد فارغ",
                               message: "لا يوجد شيء هنا بعد.",
                               systemImage: "folder",
                               actionTitle: "استيراد ملفات",
                               action: { showImportSheet = true })
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(entries, id: \.id) { e in row(e) }
                } header: {
                    Text("\(entries.count) عنصر")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(path == FilesTab.root ? .large : .inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showImportSheet = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 20))
                }
                .accessibilityLabel("استيراد")
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(destination: path) {
                showImportSheet = false
                // فتح منتقي الملفات أثناء إغلاق الورقة كان يفشل أحيانًا؛ ننتظر
                // انتهاء حركة الإغلاق أولًا.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { importing = true }
            }
            .presentationDetents([.height(340)])
        }
        .huskFilePicker(isPresented: $importing) { urls in
            host.sendFiles(urls, to: path)
        }
        .confirmationDialog("ثبّت \(installing?.name ?? "")؟",
                            isPresented: Binding(get: { installing != nil },
                                                 set: { if !$0 { installing = nil } }),
                            titleVisibility: .visible) {
            Button("تثبيت") {
                if let apk = installing { host.installFromGuest(apk.path, name: apk.name) }
                installing = nil
            }
            Button("إلغاء", role: .cancel) { installing = nil }
        } message: {
            Text("يثبّته أندرويد من مكانه الحالي — لا يُنسخ شيء.")
        }
        .task(id: path) { load() }
        .refreshable { load() }
    }

    @ViewBuilder private func row(_ e: AndroidHost.GuestEntry) -> some View {
        if e.isDirectory {
            NavigationLink(value: e.path) {
                fileLabel(icon: "folder.fill", color: .blue, name: e.name,
                          detail: e.modified.map(Self.when))
            }
        } else {
            let isAPK = e.name.lowercased().hasSuffix(".apk")
            Button {
                if isAPK { installing = e }
            } label: {
                HStack {
                    fileLabel(icon: icon(for: e.name), color: color(for: e.name),
                              name: e.name, detail: subtitle(e))
                    if isAPK {
                        Spacer()
                        Text("تثبيت").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func fileLabel(icon: String, color: Color, name: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 16)).foregroundStyle(Theme.text).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func color(for name: String) -> Color {
        let n = name.lowercased()
        if n.hasSuffix(".apk") { return .green }
        if n.hasSuffix(".png") || n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") || n.hasSuffix(".webp") { return .orange }
        if n.hasSuffix(".mp4") || n.hasSuffix(".mkv") { return .purple }
        if n.hasSuffix(".mp3") || n.hasSuffix(".ogg") || n.hasSuffix(".wav") { return .pink }
        return .gray
    }

    private func storage(_ s: (free: Int64, total: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("التخزين")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(AppDetailView.bytes(s.total - s.free)) من "
                   + "\(AppDetailView.bytes(s.total))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceHigh)
                    Capsule().fill(LinearGradient(colors: [.blue, .indigo],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * used(s))
                }
            }
            .frame(height: 8)
            Text("متاح \(AppDetailView.bytes(s.free))")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 6)
    }

    private func used(_ s: (free: Int64, total: Int64)) -> CGFloat {
        guard s.total > 0 else { return 0 }
        return min(max(CGFloat(s.total - s.free) / CGFloat(s.total), 0.02), 1)
    }

    private func subtitle(_ e: AndroidHost.GuestEntry) -> String {
        let size = AppDetailView.bytes(e.size)
        guard let m = e.modified else { return size }
        return "\(size) · \(Self.when(m))"
    }

    private func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.hasSuffix(".apk") { return "shippingbox.fill" }
        if n.hasSuffix(".png") || n.hasSuffix(".jpg") || n.hasSuffix(".jpeg")
            || n.hasSuffix(".webp") { return "photo" }
        if n.hasSuffix(".mp4") || n.hasSuffix(".mkv") { return "film" }
        if n.hasSuffix(".mp3") || n.hasSuffix(".ogg") || n.hasSuffix(".wav") {
            return "music.note"
        }
        if n.hasSuffix(".zip") || n.hasSuffix(".obb") { return "archivebox" }
        if n.hasSuffix(".txt") || n.hasSuffix(".log") || n.hasSuffix(".json") {
            return "doc.text"
        }
        return "doc"
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = Calendar.current.isDateInToday(d) ? .short : .none
        return f.string(from: d)
    }

    private func load() {
        loading = true
        let where_ = path
        Task.detached {
            var rows: [AndroidHost.GuestEntry] = []
            var why: String?
            do { rows = try AndroidHost.shared.list(where_) }
            catch { why = error.localizedDescription }
            let s = AndroidHost.shared.freeSpace(at: where_)
            await MainActor.run {
                entries = rows
                space = s
                failure = rows.isEmpty ? why : nil
                loading = false
            }
        }
    }
}

/// ورقة الاستيراد: هدف واحد وزر واحد.
struct ImportSheet: View {
    let destination: String
    let onBrowse: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Button(action: onBrowse) {
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down.on.square.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.accent)
                            .symbolRenderingMode(.hierarchical)
                        Text("اختر ملفات من الآيفون")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("تُنسخ إلى \((destination as NSString).lastPathComponent). "
                           + "ملفات APK تُثبَّت من هنا أيضًا.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .huskCard()
                }
                .buttonStyle(CardButtonStyle())

                Button("تصفّح الملفات", action: onBrowse)
                    .buttonStyle(PrimaryButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .background(Theme.backdrop)
            .navigationTitle("استيراد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
            }
        }
    }
}
