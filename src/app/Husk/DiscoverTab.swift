import SwiftUI

struct DiscoverTab: View {
    @ObservedObject private var manager = SourceManager.shared
    @ObservedObject private var host = AndroidHost.shared

    @State private var showingSources = false
    @State private var showingAddSource = false
    @State private var newSourceURL = ""
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop

                if manager.isLoading && manager.sources.isEmpty {
                    ProgressView("جارٍ جلب المستودعات…")
                        .foregroundStyle(Theme.textDim)
                } else if manager.sources.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Theme.textDim)
                        Text("لا مستودعات")
                            .font(.headline).foregroundStyle(Theme.text)
                        Text("أضف مصدرًا لبدء اكتشاف التطبيقات.")
                            .foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                        if let error = manager.fetchErrors.values.sorted().first {
                            Text(error).font(.callout).foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                        Button {
                            showingAddSource = true
                        } label: {
                            Label("إضافة مصدر", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 24) {
                            sourcesHeader
                            if !debouncedSearchText.isEmpty,
                               manager.sources.allSatisfy({ filteredApps(for: $0).isEmpty }) {
                                EmptyState(title: "لا نتائج",
                                    message: "جرّب اسم التطبيق أو اسم الحزمة.",
                                    systemImage: "magnifyingglass")
                            }
                            ForEach(manager.sources) { source in
                                let filtered = filteredApps(for: source)
                                if !filtered.isEmpty {
                                    sourceSection(source, apps: filtered)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("اكتشف")
            .searchable(text: $searchText, prompt: "ابحث في \(totalAppCount) تطبيق…")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button { Task { await manager.fetchSources(force: true) } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button { showingAddSource = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSources) { sourcesSheet }
            .sheet(isPresented: $showingAddSource) { addSourceSheet }
            .alert("تعذّر تنزيل التطبيق", isPresented: Binding(
                get: { !manager.downloadErrors.isEmpty },
                set: { if !$0 { manager.downloadErrors.removeAll() } })) {
                Button("حسنًا") { manager.downloadErrors.removeAll() }
            } message: {
                Text(manager.downloadErrors.values.sorted().first ?? "")
            }
            .onAppear {
                if manager.sources.isEmpty && !manager.isLoading {
                    Task { await manager.fetchSources() }
                }
            }
            .task(id: searchText) {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    debouncedSearchText = searchText
                } catch {}
            }
        }
    }

    private var totalAppCount: Int {
        manager.sources.reduce(0) { $0 + $1.apps.count }
    }

    // MARK: - Source Header Chips

    private var sourcesHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(manager.sourceURLs, id: \.self) { url in
                    let isLoading = manager.loadingSources.contains(url)
                    let hasError = manager.fetchErrors[url] != nil
                    let source = manager.sources.first(where: { $0.identifier == url })
                    Button { showingSources = true } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source?.name ?? (isLoading ? "جارٍ التحميل…" : "فشل"))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(hasError ? .red : Theme.text)
                                Text(isLoading ? "جارٍ الجلب…" : "\(source?.apps.count ?? 0) تطبيق")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textDim)
                            }
                            if isLoading { ProgressView().scaleEffect(0.7) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.surfaceHigh)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
                Button { showingAddSource = true } label: {
                    Label("إضافة مصدر", systemImage: "plus")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.accentSoft)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func filteredApps(for source: AppSource) -> [SourceApp] {
        if debouncedSearchText.isEmpty { return source.apps }
        let query = debouncedSearchText.lowercased()
        return source.apps.filter {
            $0.name.lowercased().contains(query) ||
            $0.bundleIdentifier.lowercased().contains(query)
        }
    }

    private func sourceSection(_ source: AppSource, apps: [SourceApp]) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text(source.name)
                .font(.title2.bold()).foregroundStyle(Theme.text).padding(.horizontal, 4)

            let displayApps = debouncedSearchText.isEmpty ? Array(apps.prefix(50)) : apps
            ForEach(displayApps) { app in
                appRow(app)
                Divider()
            }

            if debouncedSearchText.isEmpty && apps.count > 50 {
                Text("ابحث لرؤية \(apps.count - 50) تطبيق آخر…")
                    .font(.footnote).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.bottom, 4)
            }
        }
        .padding(.vertical, 8)
    }

    private func appRow(_ app: SourceApp) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: URL(string: app.iconURL)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else if phase.error != nil {
                    Image(systemName: "app.dashed").font(.title).foregroundStyle(Theme.textDim)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 50, height: 50)
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.headline).foregroundStyle(Theme.text)
                Text(app.localizedDescription)
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
            }

            Spacer()

            let isInstalled = host.packages.contains { $0.id == app.bundleIdentifier }
            let progress = manager.downloadProgress[app.bundleIdentifier]

            if isInstalled {
                Button("فتح") {
                    guard SourceValidation.package(app.bundleIdentifier) else { return }
                    host.launch(app.bundleIdentifier) {
                        Router.shared.tab = .library
                        Router.shared.wantsGuestScreen = true
                    }
                }
                .disabled(!host.isReady || host.busy != nil)
                .frame(minHeight: 44)
                .font(.subheadline.bold())
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.surfaceHigh).foregroundStyle(Theme.text)
                .cornerRadius(16)
            } else if let progress = progress {
                Button { manager.cancelDownload(app.id) } label: {
                  ZStack {
                    Circle().stroke(Theme.surfaceHigh, lineWidth: 3).frame(width: 28, height: 28)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 28, height: 28).rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                  }
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("إلغاء تنزيل \(app.name)")
            } else {
                Button("تنزيل") { manager.downloadAndInstall(app: app) }
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .cornerRadius(16)
            }
        }
    }

    // MARK: - Add Source Sheet

    private var addSourceSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("رابط المصدر")
                        .font(.headline).foregroundStyle(Theme.text)
                    TextField("https://f-droid.org/repo/index-v1.json", text: $newSourceURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding().background(Theme.surfaceHigh).cornerRadius(12)
                    Text("الصق رابط فهرس مستودع متوافق مع F-Droid.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("جاهزة")
                        .font(.headline).foregroundStyle(Theme.text)
                    ForEach([
                        ("F-Droid", "https://f-droid.org/repo/index-v1.json"),
                        ("IzzyOnDroid", "https://apt.izzysoft.de/fdroid/repo/index-v1.json"),
                        ("Guardian Project", "https://guardianproject.info/fdroid/repo/index-v1.json"),
                    ], id: \.0) { name, url in
                        Button { newSourceURL = url } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).font(.subheadline.bold()).foregroundStyle(Theme.text)
                                    Text(url).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                                }
                                Spacer()
                                if newSourceURL == url {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                            .padding().background(Theme.surfaceHigh).cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .padding()
            .background(Theme.backdrop.ignoresSafeArea())
            .navigationTitle("إضافة مصدر")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("إلغاء") { newSourceURL = ""; showingAddSource = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("إضافة") {
                        let url = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        newSourceURL = ""
                        showingAddSource = false
                        guard SourceValidation.httpsURL(url) != nil else { return }
                        Task { await manager.addSource(urlString: url) }
                    }
                    .disabled(SourceValidation.httpsURL(newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    .bold()
                }
            }
        }
    }

    // MARK: - Manage Sources Sheet

    private var sourcesSheet: some View {
        NavigationStack {
            List {
                Section("المستودعات النشطة") {
                    ForEach(manager.sourceURLs, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 2) {
                            if let source = manager.sources.first(where: { $0.identifier == url }) {
                                Text(source.name).font(.subheadline.bold()).foregroundStyle(Theme.text)
                                Text("\(source.apps.count) تطبيق").font(.caption).foregroundStyle(Theme.textDim)
                            }
                            Text(url).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        let urls = offsets.map { manager.sourceURLs[$0] }
                        for url in urls { manager.removeSource(urlString: url) }
                    }
                }
            }
            .navigationTitle("المستودعات")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("تم") { showingSources = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSources = false; showingAddSource = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}
