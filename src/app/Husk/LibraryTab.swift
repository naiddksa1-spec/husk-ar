// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// المكتبة — أُعيد تصميمها من الصفر كشاشة رئيسية بأسلوب آيفون:
/// بطاقة حالة كبيرة في الأعلى، ثم شبكة أيقونات مثل الشاشة الرئيسية، وبحث
/// أصلي من شريط التنقل.
///
/// The catalogue is written to disk the first time the guest reports its apps,
/// so the grid is on screen the instant the app opens.
struct LibraryTab: View {
    @ObservedObject private var host = AndroidHost.shared
    @ObservedObject private var runner = QemuRunner.shared
    @ObservedObject private var router = Router.shared

    let onOpenGuest: () -> Void
    let onStartAndroid: () -> Void
    let started: Bool

    @State private var importing = false
    @State private var query = ""
    @State private var filter = "All"

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 18,
                                    alignment: .top)]

    var body: some View {
        NavigationStack(path: $router.library) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    statusCard
                    if let busy = host.busy { busyBanner(busy) }
                    if !categories.isEmpty { chips }
                    grid
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Theme.backdrop)
            .navigationTitle("التطبيقات")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "ابحث في تطبيقاتك")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if started {
                        Button(action: onOpenGuest) {
                            Image(systemName: "iphone.gen3")
                        }
                        .accessibilityLabel("عرض أندرويد")
                    }
                    Button { importing = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 20))
                    }
                    .accessibilityLabel("تثبيت APK")
                }
            }
            .navigationDestination(for: AndroidHost.Package.self) { app in
                AppDetailView(app: app, onOpenGuest: onOpenGuest)
            }
            .huskFilePicker(isPresented: $importing) { urls in
                HuskLog.log("ui", "importing \(urls.count) file(s): "
                          + urls.map(\.lastPathComponent).joined(separator: ", "))
                host.install(urls)
            }
        }
    }

    // MARK: status

    private enum Phase { case ready, booting, stopped, noJIT }

    private var phase: Phase {
        if host.isReady { return .ready }
        if started { return .booting }
        return JITBootstrap.isDebuggerAttached ? .stopped : .noJIT
    }

    /// بطاقة واحدة كبيرة تقول حالة أندرويد وتعرض الإجراء الوحيد المهم الآن.
    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(statusTint.opacity(0.15)).frame(width: 52, height: 52)
                if phase == .booting {
                    ProgressView().tint(statusTint)
                } else {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(statusTint)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if phase == .booting, runner.bootProgress > 0 {
                    ProgressView(value: Double(runner.bootProgress), total: 100)
                        .progressViewStyle(.linear).tint(statusTint)
                    Text("\(runner.bootProgress)٪ · \(host.status)")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim).lineLimit(1)
                } else {
                    Text(statusDetail)
                        .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let title = statusAction {
                Button(title) {
                    if started { onOpenGuest() } else { onStartAndroid() }
                }
                .buttonStyle(PillButtonStyle(filled: phase != .ready))
            }
        }
        .padding(16)
        .huskElevated()
    }

    private var statusTint: Color {
        switch phase {
        case .ready: return Theme.good
        case .booting: return Theme.accent
        case .stopped: return Theme.accent
        case .noJIT: return Theme.warn
        }
    }

    private var statusSymbol: String {
        switch phase {
        case .ready: return "checkmark"
        case .booting: return "hourglass"
        case .stopped: return "power"
        case .noJIT: return "bolt.slash.fill"
        }
    }

    private var statusTitle: String {
        switch phase {
        case .ready: return "أندرويد يعمل"
        case .booting: return "جارٍ تشغيل أندرويد"
        case .stopped: return "أندرويد متوقف"
        case .noJIT: return "يلزم تفعيل JIT"
        }
    }

    private var statusDetail: String {
        switch phase {
        case .ready: return "\(host.packages.count) تطبيق جاهز للفتح"
        case .booting: return host.status
        case .stopped: return "شغّله لفتح تطبيقاتك."
        case .noJIT: return "افتح IOS APP من StikDebug ليعمل أندرويد."
        }
    }

    private var statusAction: String? {
        switch phase {
        case .ready: return "عرض"
        case .booting: return "عرض"
        case .stopped: return "تشغيل"
        case .noJIT: return "تفعيل"
        }
    }

    private func busyBanner(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .huskCard()
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "الكل", selected: filter == "All") { filter = "All" }
                ForEach(categories, id: \.self) { c in
                    Chip(title: plural(c), selected: filter == c) { filter = c }
                }
            }
        }
    }

    // MARK: grid

    @ViewBuilder private var grid: some View {
        if !shown.isEmpty {
            LazyVGrid(columns: columns, alignment: .center, spacing: 22) {
                ForEach(shown) { app in
                    NavigationLink(value: app) {
                        AppCard(app: app, dimmed: !host.isReady)
                    }
                    .buttonStyle(CardButtonStyle())
                    .contextMenu {
                        Button {
                            host.launch(app.name) { onOpenGuest() }
                        } label: { Label("فتح", systemImage: "play.fill") }
                        .disabled(!host.isReady || host.busy != nil)
                        Button {
                            router.library.append(app)
                        } label: { Label("التفاصيل", systemImage: "info.circle") }
                        Button {
                            UIPasteboard.general.string = app.name
                        } label: { Label("نسخ اسم الحزمة", systemImage: "doc.on.doc") }
                    }
                }
            }
        } else if !query.isEmpty {
            EmptyState(title: "لا نتائج",
                       message: "لا يوجد تطبيق مثبّت باسم “\(query)”.",
                       systemImage: "magnifyingglass")
        } else if host.packages.isEmpty {
            EmptyState(title: "لا تطبيقات بعد",
                       message: "ثبّت ملف APK وسيظهر هنا. الحزم المقسّمة مدعومة — "
                              + "اختر كل القطع معًا.",
                       systemImage: "square.grid.3x3.square",
                       actionTitle: "تثبيت APK",
                       action: { importing = true })
        }
    }

    // MARK: what to show

    private var categories: [String] {
        let set = Set(host.packages.compactMap(\.category))
        return ["Game", "App", "Tool"].filter { set.contains($0) }
    }

    private func plural(_ c: String) -> String {
        c == "Game" ? "الألعاب" : c == "App" ? "التطبيقات" : "الأدوات"
    }

    private var shown: [AndroidHost.Package] {
        var list = host.packages
        if filter != "All" { list = list.filter { $0.category == filter } }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.label.localizedCaseInsensitiveContains(q)
                || $0.name.localizedCaseInsensitiveContains(q)
        }
    }
}

/// تطبيق واحد كما في الشاشة الرئيسية للآيفون: أيقونة واسم تحتها.
struct AppCard: View {
    let app: AndroidHost.Package
    var dimmed = false

    var body: some View {
        VStack(spacing: 7) {
            AppIcon(path: app.iconPath, size: 64)
                .shadow(color: Theme.shadow, radius: 6, y: 3)
                .opacity(dimmed ? 0.55 : 1)
            Text(app.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(maxWidth: 84)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
