// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Where the apps are.
///
/// A launcher, not a view onto the bridge. The catalogue is written to disk the
/// first time the guest reports its apps, so the grid is on screen the instant
/// Husk opens — a minute before Android can answer for itself. Everything you
/// can do without the guest (look, read, decide) works straight away; the one
/// thing that needs it, opening an app, waits, and says so.
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
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 124 : 76), spacing: 12)]
    }

    var body: some View {
        NavigationStack(path: $router.library) {
            ZStack {
                Theme.homeWallpaper
                content
            }
            .navigationBarHidden(true)
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

    // MARK: content

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Label("مدار", systemImage: "circle.hexagongrid")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.95))
                    Spacer()
                    Button { importing = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 46, height: 46)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .foregroundStyle(.white)
                    .buttonStyle(CardButtonStyle())
                    .accessibilityLabel("إضافة ملف APK")
                }

                homeClock
                quickAccess

                // Always there, not behind a button. Searching is what you do
                // with a list of apps; making it a mode you enter first is a
                // step between you and the thing you came for.
                if !host.packages.isEmpty {
                    Text("تطبيقاتك")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    searchField
                }
                if !host.isReady { machineStrip }
                if let busy = host.busy { busyStrip(busy) }
                if !categories.isEmpty { chips }

                if !shown.isEmpty {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shown) { app in
                            Button {
                                if host.isReady && host.busy == nil {
                                    host.launch(app.name) { onOpenGuest() }
                                } else {
                                    router.library.append(app)
                                }
                            } label: {
                                AppCard(app: app, dimmed: !host.isReady)
                            }
                            .buttonStyle(CardButtonStyle())
                            .contextMenu {
                                Button {
                                    host.launch(app.name) { onOpenGuest() }
                                } label: { Label("تشغيل", systemImage: "play.fill") }
                                .disabled(!host.isReady || host.busy != nil)
                                Button {
                                    router.library.append(app)
                                } label: { Label("التفاصيل", systemImage: "info.circle") }
                            }
                        }
                    }
                } else if !query.isEmpty {
                    Text("لا يوجد تطبيق مثبّت باسم «\(query)».")
                        .font(.body).foregroundStyle(.white)
                        .padding(24)
                } else if host.packages.isEmpty && host.isReady {
                    EmptyState(title: "لا تطبيقات بعد",
                               message: "ثبّت ملف APK وسيظهر هنا. الحزم المقسّمة "
                                      + "مدعومة أيضًا — اختر كل القطع معًا.",
                               systemImage: "square.grid.2x2",
                               actionTitle: "تثبيت APK",
                               action: { importing = true })
                        .huskCard()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 34)
        }
    }

    private var homeClock: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 64 : 82,
                                  weight: .light, design: .rounded))
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.body.weight(.medium)).foregroundStyle(.white)
                Label(host.isReady ? "أندرويد متصل" : "جهازك الثاني، بطريقتك",
                      systemImage: host.isReady ? "checkmark.circle.fill" : "sparkles")
                    .font(.footnote).foregroundStyle(.white.opacity(0.90))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
        }
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HuskMark(size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.isReady ? "أندرويد متصل" : "مساحة أندرويد")
                        .font(.headline)
                    Text(host.isReady ? "افتح الشاشة أو اختر تطبيقاً بالأسفل."
                         : "شغّل الضيف للوصول إلى تطبيقاتك.")
                        .font(.subheadline).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button(action: started ? onOpenGuest : onStartAndroid) {
                    Label(started ? "عرض أندرويد" : "تشغيل أندرويد",
                          systemImage: started ? "rectangle.inset.filled" : "power")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.white)
                        .background(Theme.action, in: Capsule())
                }
                Button { router.tab = .files } label: {
                    Image(systemName: "folder.fill")
                        .frame(width: 46, height: 44)
                        .foregroundStyle(Theme.champagne)
                        .background(Theme.surfaceHigh, in: Capsule())
                }
                .accessibilityLabel("فتح الملفات")
            }
            .buttonStyle(CardButtonStyle())
        }
        .padding(18)
        .madarGlass(radius: 26)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textDim)
            TextField("ابحث في التطبيقات", text: $query)
                .focused($searchFocused)
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .huskCard(RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous),
                  high: true)
    }

    /// One line about the machine, only while it cannot open anything.
    private var machineStrip: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 32, height: 32)
                if started {
                    ProgressView().scaleEffect(0.6).tint(Theme.accent)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(started ? "جارٍ تشغيل أندرويد" : "أندرويد لا يعمل")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if started, runner.bootProgress > 0 {
                    ProgressView(value: Double(runner.bootProgress), total: 100)
                        .progressViewStyle(.linear).tint(Theme.accent)
                        .frame(height: 3)
                } else {
                    Text(started ? host.status
                                 : JITBootstrap.isDebuggerAttached
                                   ? "تطبيقاتك هنا؛ شغّله لفتحها."
                                   : "يحتاج Husk إلى JIT، ولا يمنحه إلا مصحح.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button(started ? "عرض" : JITBootstrap.isDebuggerAttached ? "تشغيل" : "JIT") {
                if started { onOpenGuest() } else { onStartAndroid() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAction)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.action, in: Capsule())
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .huskCard(RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous))
    }

    private func busyStrip(_ text: String) -> some View {
        HStack(spacing: 11) {
            ProgressView().tint(Theme.accent)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .huskCard(RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous),
                  high: true)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "الكل", selected: filter == "All") { filter = "All" }
                ForEach(categories, id: \.self) { c in
                    Chip(title: plural(c), selected: filter == c) { filter = c }
                }
            }
            .padding(.horizontal, 1)
        }
    }

    // MARK: what to show

    /// The categories Android actually reported. When it reported none — which
    /// for sideloaded APKs is the usual answer — there are no chips at all
    /// rather than a row of filters that all show the same thing.
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

/// One app, as a card: its icon, its name, and what kind of thing it is.
struct AppCard: View {
    let app: AndroidHost.Package
    var dimmed = false

    var body: some View {
        VStack(spacing: 9) {
            AppIcon(path: app.iconPath, size: 58)
                .opacity(dimmed ? 0.7 : 1)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            Text(app.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.40), radius: 3, y: 1)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.vertical, 10)
        .accessibilityLabel(app.label)
    }
}
