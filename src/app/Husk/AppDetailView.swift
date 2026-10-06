// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Where the tabs and their stacks are steered from.
///
/// One app can send you to another tab — an app's page offers to show its files
/// — and a tab that is also a navigation stack cannot be pushed from outside
/// itself without somewhere to keep the path. This is that somewhere.
@MainActor final class Router: ObservableObject {
    static let shared = Router()

    @Published var tab: HuskTab = .library
    /// The app pages pushed on top of the library.
    @Published var library: [AndroidHost.Package] = []
    /// Directories pushed on top of the Files root.
    @Published var files: [String] = []
    /// يزداد كلما طلبت شاشة ما إظهار أندرويد (يراقبه ContentView).
    @Published var guestRequests = 0

    func requestGuest() { guestRequests += 1 }

    /// Show a directory in the Files tab, from anywhere.
    func openFiles(at path: String) {
        files = path == FilesTab.root ? [] : [path]
        tab = .files
    }
}

/// صفحة تطبيق واحد — مصممة من الصفر على طريقة App Store: رأس بأيقونة كبيرة
/// وزر "فتح" كبسولي، شريط معلومات أفقي، ثم الإجراءات في مجموعة.
struct AppDetailView: View {
    let app: AndroidHost.Package
    let onOpenGuest: () -> Void

    @ObservedObject private var host = AndroidHost.shared
    @ObservedObject private var router = Router.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false

    private var live: AndroidHost.Package {
        host.packages.first { $0.name == app.name } ?? app
    }
    private var canOpen: Bool { host.isReady && host.busy == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                infoStrip
                if !host.isReady {
                    Label("سيُفتح فور استجابة أندرويد.", systemImage: "clock")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textDim)
                }
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Theme.backdrop)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
        .confirmationDialog("إلغاء تثبيت \(live.label)؟", isPresented: $confirmUninstall,
                            titleVisibility: .visible) {
            Button("إلغاء التثبيت", role: .destructive) {
                host.uninstall(app.name)
                dismiss()
            }
            Button("إلغاء", role: .cancel) { }
        } message: {
            Text("ستُحذف بياناته معه. احفظ أندرويد بعد ذلك، وإلا ضاع "
               + "التغيير عند التشغيل التالي.")
        }
    }

    // MARK: pieces

    private var menu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = app.name
            } label: { Label("نسخ اسم الحزمة", systemImage: "doc.on.doc") }
            Button { appInfo() } label: {
                Label("العرض في إعدادات أندرويد", systemImage: "gearshape")
            }
            .disabled(!canOpen)
            Divider()
            Button(role: .destructive) { confirmUninstall = true } label: {
                Label("إلغاء التثبيت", systemImage: "trash")
            }
            .disabled(!canOpen)
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("المزيد")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            AppIcon(path: live.iconPath, size: 112)
                .shadow(color: Theme.shadow, radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(live.label)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(live.name)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 10)
                HStack {
                    Button {
                        host.launch(app.name) { onOpenGuest() }
                    } label: {
                        Text(canOpen ? "فتح" : "انتظار")
                    }
                    .buttonStyle(PillButtonStyle(filled: true))
                    .disabled(!canOpen)
                    .opacity(canOpen ? 1 : 0.5)
                    Spacer()
                    ShareLink(item: app.name) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17))
                    }
                }
            }
            .frame(minHeight: 112)
        }
    }

    /// شريط المعلومات الأفقي، كما تحت رأس صفحة App Store.
    private var infoStrip: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    stat("الإصدار", live.version ?? "—", "number")
                    statDivider
                    stat("الحجم", live.sizeBytes.map(Self.bytes) ?? "—", "internaldrive")
                    statDivider
                    stat("المعمارية", live.bitness ?? "—", "cpu")
                    statDivider
                    stat("الفئة", live.category.map(Self.categoryName) ?? "—", "square.grid.2x2")
                    statDivider
                    stat("آخر استخدام", live.lastUsed.map(Self.when) ?? "لم يُفتح", "clock")
                }
                .padding(.vertical, 12)
            }
            Divider()
        }
    }

    private var statDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1 / UIScreen.main.scale, height: 34)
    }

    private func stat(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .textCase(.uppercase)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textDim)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
        .frame(minWidth: 96)
        .padding(.horizontal, 6)
    }

    private var actions: some View {
        RowGroup {
            Button { router.openFiles(at: "/sdcard/Android/data/\(app.name)") } label: {
                HuskRow(systemImage: "folder.fill", title: "فتح في الملفات", iconColor: .blue)
            }
            .buttonStyle(.plain)
            RowDivider()
            Button { appInfo() } label: {
                HuskRow(systemImage: "info", title: "معلومات التطبيق في أندرويد",
                        iconColor: .gray)
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            RowDivider()
            Button { confirmUninstall = true } label: {
                HuskRow(systemImage: "trash.fill", title: "إلغاء التثبيت", tint: .red,
                        showsChevron: false, iconColor: .red)
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
        }
    }

    static func categoryName(_ c: String) -> String {
        c == "Game" ? "لعبة" : c == "App" ? "تطبيق" : c == "Tool" ? "أداة" : c
    }

    /// Android's own page for the app — permissions, storage, force stop. It
    /// is a screen Android already has and Husk should not be reimplementing.
    private func appInfo() {
        let pkg = app.name
        guard AndroidHost.isValidPackage(pkg) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? GuestBridge.shared.shell(
                "am start -a android.settings.APPLICATION_DETAILS_SETTINGS "
              + "-d package:\(pkg)", timeout: 30)
        }
        onOpenGuest()
    }

    // MARK: formatting

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func when(_ date: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "'اليوم،' h:mm a"
        } else if Calendar.current.isDateInYesterday(date) {
            f.dateFormat = "'أمس،' h:mm a"
        } else {
            f.dateStyle = .medium
            f.timeStyle = .none
        }
        return f.string(from: date)
    }
}
