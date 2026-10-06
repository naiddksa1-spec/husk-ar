// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// اكتشف — مصمم من الصفر على طريقة App Store: مستودعاتك كبطاقات أفقية في
/// الأعلى، ثم التطبيقات في قوائم مجمّعة مع زر "تنزيل" كبسولي لكل تطبيق.
struct DiscoverTab: View {
    @ObservedObject private var manager = SourceManager.shared
    @ObservedObject private var host = AndroidHost.shared

    /// ورقة واحدة بحالات، بدل ورقتين: فتح ورقة أثناء إغلاق أخرى كان يفشل
    /// بصمت في iOS (زر + داخل "المستودعات" لم يكن يفتح شيئًا).
    private enum SheetKind: String, Identifiable { case sources, add; var id: String { rawValue } }
    @State private var sheet: SheetKind?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if manager.isLoading && manager.sources.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("جارٍ جلب المستودعات…")
                            .font(.system(size: 15)).foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if manager.sources.isEmpty {
                    EmptyState(title: "لا مستودعات",
                               message: manager.fetchErrors.values.first
                                   ?? "أضف مستودعًا متوافقًا مع F-Droid لاكتشاف التطبيقات.",
                               systemImage: "shippingbox",
                               actionTitle: "إضافة مستودع",
                               action: { sheet = .add })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            sourcesStrip
                            ForEach(manager.sources) { source in
                                let filtered = filteredApps(for: source)
                                if !filtered.isEmpty {
                                    sourceSection(source, apps: filtered)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 32)
                    }
                    .refreshable { await manager.fetchSources() }
                }
            }
            .background(Theme.backdrop)
            .navigationTitle("اكتشف")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "ابحث في \(totalAppCount) تطبيق")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { sheet = .sources } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("المستودعات")
                    Button { sheet = .add } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 20))
                    }
                    .accessibilityLabel("إضافة مستودع")
                }
            }
            .sheet(item: $sheet) { kind in
                switch kind {
                case .sources: SourcesSheet(onAdd: { sheet = .add })
                case .add: AddSourceSheet()
                }
            }
            .task {
                if manager.sources.isEmpty && !manager.isLoading {
                    await manager.fetchSources()
                }
            }
            .task(id: searchText) {
                do {
                    try await Task.sleep(nanoseconds: 220_000_000)
                    debouncedSearchText = searchText
                } catch {}
            }
        }
    }

    private var totalAppCount: Int {
        manager.sources.reduce(0) { $0 + $1.apps.count }
    }

    // MARK: sources strip

    private var sourcesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(manager.sourceURLs, id: \.self) { url in
                    let isLoading = manager.loadingSources.contains(url)
                    let hasError = manager.fetchErrors[url] != nil
                    let source = manager.sources.first(where: { $0.identifier == url })
                    Button { sheet = .sources } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SettingsIcon(systemImage: hasError ? "exclamationmark"
                                                                   : "shippingbox.fill",
                                             color: hasError ? .red : .indigo, size: 32)
                                Spacer()
                                if isLoading { ProgressView().controlSize(.small) }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source?.name ?? (isLoading ? "جارٍ التحميل…" : "تعذّر الجلب"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text(isLoading ? "جارٍ الجلب…" : "\(source?.apps.count ?? 0) تطبيق")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textDim)
                            }
                        }
                        .padding(14)
                        .frame(width: 170, alignment: .leading)
                        .huskCard()
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
        }
    }

    // MARK: sections

    private func filteredApps(for source: AppSource) -> [SourceApp] {
        if debouncedSearchText.isEmpty { return source.apps }
        let query = debouncedSearchText.lowercased()
        return source.apps.filter {
            $0.name.lowercased().contains(query) ||
            $0.bundleIdentifier.lowercased().contains(query)
        }
    }

    private func sourceSection(_ source: AppSource, apps: [SourceApp]) -> some View {
        let display = debouncedSearchText.isEmpty ? Array(apps.prefix(50)) : Array(apps.prefix(200))
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: source.name, trailing: "\(apps.count)")
            VStack(spacing: 0) {
                ForEach(Array(display.enumerated()), id: \.element.id) { i, app in
                    DiscoverRow(app: app)
                    if i < display.count - 1 {
                        Divider().padding(.leading, 86)
                    }
                }
            }
            .huskCard()
            if apps.count > display.count {
                Text("ابحث لرؤية \(apps.count - display.count) تطبيق آخر")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

/// صف تطبيق واحد في اكتشف.
private struct DiscoverRow: View {
    let app: SourceApp
    @ObservedObject private var manager = SourceManager.shared
    @ObservedObject private var host = AndroidHost.shared

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: app.iconURL)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(uiColor: .systemGray5)
                        Image(systemName: "app.fill").foregroundStyle(Theme.textFaint)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 56 * 0.2237, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 56 * 0.2237, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(app.localizedDescription.isEmpty ? app.version : app.localizedDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var action: some View {
        let isInstalled = host.packages.contains { $0.id == app.bundleIdentifier }
        if isInstalled {
            Button("فتح") {
                host.launch(app.bundleIdentifier) { Router.shared.requestGuest() }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(!host.isReady || host.busy != nil)
        } else if let progress = manager.downloadProgress[app.bundleIdentifier] {
            ZStack {
                Circle().stroke(Theme.surfaceHigh, lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 8, height: 8)
            }
            .frame(width: 30, height: 30)
            .frame(minWidth: 74)
        } else {
            Button("تنزيل") { manager.downloadAndInstall(app: app) }
                .buttonStyle(PillButtonStyle())
        }
    }
}

// MARK: - Sheets

private struct AddSourceSheet: View {
    @ObservedObject private var manager = SourceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    private let presets = [
        ("F-Droid", "https://f-droid.org/repo/index-v1.json"),
        ("IzzyOnDroid", "https://apt.izzysoft.de/fdroid/repo/index-v1.json"),
        ("Guardian Project", "https://guardianproject.info/fdroid/repo/index-v1.json"),
    ]

    private var valid: Bool {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return false }
        return u.scheme?.lowercased() == "https" && u.host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/index-v1.json", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("رابط المستودع")
                } footer: {
                    Text(url.isEmpty || valid
                         ? "الصق رابط فهرس مستودع متوافق مع F-Droid. يُقبل HTTPS فقط."
                         : "الرابط يجب أن يبدأ بـ https://")
                }
                Section("مستودعات معروفة") {
                    ForEach(presets, id: \.0) { name, link in
                        Button { url = link } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).foregroundStyle(Theme.text)
                                    Text(link).font(.caption).foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if url == link {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                } else if manager.sourceURLs.contains(link) {
                                    Text("مضاف").font(.caption).foregroundStyle(Theme.textDim)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("إضافة مستودع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إضافة") {
                        let link = url
                        dismiss()
                        Task { await manager.addSource(urlString: link) }
                    }
                    .disabled(!valid)
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SourcesSheet: View {
    let onAdd: () -> Void
    @ObservedObject private var manager = SourceManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(manager.sourceURLs, id: \.self) { url in
                        HStack(spacing: 12) {
                            SettingsIcon(systemImage: manager.fetchErrors[url] == nil
                                                      ? "shippingbox.fill" : "exclamationmark",
                                         color: manager.fetchErrors[url] == nil ? .indigo : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                if let source = manager.sources.first(where: { $0.identifier == url }) {
                                    Text(source.name).font(.body.weight(.medium))
                                    Text("\(source.apps.count) تطبيق")
                                        .font(.caption).foregroundStyle(Theme.textDim)
                                }
                                if let error = manager.fetchErrors[url] {
                                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                                }
                                Text(url).font(.caption2).foregroundStyle(Theme.textFaint).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    // كانت تحذف الرابط فقط وتُبقي تطبيقاته معروضة.
                    .onDelete { offsets in
                        for url in offsets.map({ manager.sourceURLs[$0] }) {
                            manager.removeSource(urlString: url)
                        }
                    }
                } header: {
                    Text("المستودعات النشطة")
                } footer: {
                    Text("اسحب لليسار لحذف مستودع.")
                }
            }
            .navigationTitle("المستودعات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }.bold()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { onAdd() } label: { Image(systemName: "plus") }
                }
            }
        }
    }
}
