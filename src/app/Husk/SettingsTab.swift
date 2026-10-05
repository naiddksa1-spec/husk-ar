// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Settings, as a hierarchy rather than one long form.
///
/// Everything used to live on a single scrolling page, so choices that change
/// the machine sat next to choices that change a colour, and the ones with
/// consequences were easy to reach by accident. The grouping here is the
/// concept's: what belongs to the app, what belongs to the emulator, and what
/// the thing actually is.
struct SettingsTab: View {
    @ObservedObject private var runner = QemuRunner.shared
    @ObservedObject private var host = AndroidHost.shared
    @State private var searching = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HuskHeader(mark: true, title: "الإعدادات")
                        HStack(spacing: 16) {
                            HuskMark(size: 58)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("مدار")
                                    .font(.headline)
                                Text("أندرويد على آيفونك")
                                    .font(.subheadline).foregroundStyle(Theme.textDim)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(20)
                        .huskCard()

                        group("عام") {
                            link(LibrarySettings(), "square.grid.2x2", "المكتبة",
                                 "تطبيقاتك وأيقوناتها")
                            RowDivider()
                            link(PerformanceSettings(), "speedometer", "الأداء",
                                 "المعالج الرسومي، الصوت")
                            RowDivider()
                            link(AppearanceSettings(), "paintbrush", "المظهر",
                                 "فاتح أو داكن، أيقونة التطبيق")
                        }

                        group("المحاكي") {
                            link(JITSettings(), "bolt.circle", "JIT والتثبيت اليدوي",
                                 "ذاكرة التنفيذ، بدء التشغيل")
                            RowDivider()
                            link(InputSettings(), "hand.tap", "الإدخال",
                                 "الشاشة، اللمس، لوحة المفاتيح")
                            RowDivider()
                            link(NetworkSettings(), "globe", "الشبكة",
                                 "الإنترنت والجلسات المحفوظة")
                            RowDivider()
                            link(SavedMachineSettings(), "externaldrive",
                                 "الجهاز المحفوظ", "اللقطات والحفظ التلقائي")
                        }

                        group("تجريبي") {
                            link(TranslationLayerSettings(), "testtube.2",
                                 "Android Translation Layer",
                                 "تطبيقات بدون تشغيل أندرويد")
                        }

                        group("حول") {
                            NavigationLink { AboutSettings() } label: {
                                HStack(spacing: 14) {
                                    HuskMark(size: 34)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Husk")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Theme.text)
                                        Text("الإصدار \(Bundle.main.version) "
                                           + "· \(Bundle.main.commit)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.textDim.opacity(0.7))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
            }
            .navigationBarHidden(true)
            .toolbar(.hidden, for: .tabBar)
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textDim)
                .padding(.leading, 4)
            RowGroup { rows() }
        }
    }

    private func link<D: View>(_ destination: D, _ icon: String,
                               _ title: String, _ subtitle: String) -> some View {
        NavigationLink { destination } label: {
            HuskRow(systemImage: icon, title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }
}

/// A Form, on Husk's page rather than the system's.
private struct HuskForm: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.backdrop)
            .tint(Theme.accent)
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func huskForm() -> some View { modifier(HuskForm()) }
}

// MARK: - Library

struct LibrarySettings: View {
    @ObservedObject private var host = AndroidHost.shared
    @State private var working = false

    var body: some View {
        Form {
            Section {
                DetailRow(label: "التطبيقات", value: "\(host.packages.count)", mono: false)
                DetailRow(label: "مع أيقونات",
                          value: "\(host.packages.filter { $0.iconPath != nil }.count)",
                          mono: false)
            } footer: {
                Text("تُحفظ القائمة على الجهاز، فتظهر على الشاشة قبل أن يكمل أندرويد "
                   + "التشغيل.")
            }

            Section {
                Button {
                    working = true
                    Task { await host.refreshPackages(); working = false }
                } label: {
                    Label(working ? "جارٍ التحديث…" : "تحديث من أندرويد",
                          systemImage: "arrow.clockwise")
                }
                .disabled(working || !host.isReady)

                Button {
                    AndroidHost.forgetIcons()
                    working = true
                    Task { await host.refreshPackages(); working = false }
                } label: {
                    Label("إعادة جلب الأيقونات", systemImage: "photo.on.rectangle")
                }
                .disabled(working || !host.isReady)
            } footer: {
                Text("الأسماء والأيقونات من مشغّل أندرويد نفسه، الذي يحتفظ بالنسخة "
                   + "التي يرسمها. إعادة الجلب تتخلص من نسخ Husk وتطلب من جديد.")
            }
        }
        .huskForm()
        .navigationTitle("المكتبة")
    }
}

// MARK: - Performance

struct PerformanceSettings: View {
    @ObservedObject private var runner = QemuRunner.shared
    @State private var gpuMode =
        UserDefaults.standard.object(forKey: "husk.gpuMode") as? Bool ?? true
    @State private var sound = UserDefaults.standard.bool(forKey: "husk.sound")
    @State private var soundDevice =
        UserDefaults.standard.object(forKey: "husk.soundDevice") as? Bool ?? true

    var body: some View {
        Form {
            Section {
                Picker("المعالج الرسومي", selection: $gpuMode) {
                    Text("GPU").tag(true)
                    Text("CPU").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: gpuMode) { v in
                    UserDefaults.standard.set(v, forKey: "husk.gpuMode")
                    HuskLog.log("ui", v ? "GPU renderer selected" : "CPU renderer selected")
                }
            } header: {
                Text("المعالج الرسومي")
            } footer: {
                Text(gpuMode
                     ? "يرسم أندرويد على معالج الرسوميات الحقيقي عبر Metal — بمعدل "
                     + "إطارات أعلى أربع مرات تقريبًا. هذا هو الافتراضي."
                     : "كل بكسل يرسمه المعالج المحاكى. أبطأ بكثير، ولا يستحق "
                     + "الاختيار إلا إذا أساء معالج الرسوميات التصرف.")
            }

            Section {
                DetailRow(label: "معدل الإطارات",
                          value: runner.fps > 0
                                 ? String(format: "%.0f إ/ث", runner.fps) : "—")
                DetailRow(label: "شاشة أندرويد",
                          value: "\(QemuRunner.lastGuestRes.w)×\(QemuRunner.lastGuestRes.h)")
            } header: {
                Text("الآن")
            }

            Section {
                Toggle("الصوت", isOn: $sound)
                    .onChange(of: sound) { v in
                        UserDefaults.standard.set(v, forKey: "husk.sound")
                        HuskLog.log("ui", v ? "sound on" : "sound off")
                    }
                if sound {
                    Toggle("توصيل جهاز الصوت", isOn: $soundDevice)
                        .onChange(of: soundDevice) { v in
                            UserDefaults.standard.set(v, forKey: "husk.soundDevice")
                        }
                }
            } header: {
                Text("الصوت")
            } footer: {
                Text("يضيف جهاز صوت. وبينما هو موصّل لا يمكن حفظ أندرويد — QEMU "
                   + "يرفض التقاط صورة لجهاز عليه جهاز صوت — فيقلع كل تشغيل من "
                   + "الصفر. تشغيله أو إطفاؤه يكلف إقلاعًا باردًا في الحالتين.")
            }
        }
        .huskForm()
        .navigationTitle("الأداء")
    }
}

// MARK: - Input

struct InputSettings: View {
    @State private var landscapeGuest =
        UserDefaults.standard.bool(forKey: "husk.landscapeGuest")
    @State private var customRes = UserDefaults.standard.bool(forKey: "husk.customRes")
    @State private var widthText = InputSettings.stored("husk.resWidth", 720)
    @State private var heightText = InputSettings.stored("husk.resHeight", 1280)

    /// Sizes worth offering without typing. Deliberately short: these are the
    /// shapes a phone guest is actually run at, not a catalogue of every panel
    /// ever made.
    private static let presets: [(name: String, w: Int, h: Int)] = [
        ("صغير — 360 × 800", 360, 800),
        ("HD — 720 × 1280", 720, 1280),
        ("Full HD — 1080 × 1920", 1080, 1920),
        ("أفقي HD — 1280 × 720", 1280, 720),
        ("لوحي — 1280 × 800", 1280, 800),
    ]

    private static func stored(_ key: String, _ fallback: Int) -> String {
        let v = UserDefaults.standard.integer(forKey: key)
        return String(v > 0 ? v : fallback)
    }

    /// What the typed numbers actually come to, or nothing if they are not a
    /// size the guest can be given.
    private var effective: (w: Int, h: Int)? {
        QemuRunner.validResolution(w: Int(widthText) ?? 0, h: Int(heightText) ?? 0)
    }

    var body: some View {
        Form {
            Section {
                Picker("الشاشة", selection: $landscapeGuest) {
                    Text("عمودي").tag(false)
                    Text("أفقي").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(customRes)
                .onChange(of: landscapeGuest) { v in
                    UserDefaults.standard.set(v, forKey: "husk.landscapeGuest")
                    HuskLog.log("ui", v ? "guest panel will be landscape"
                                        : "guest panel will be portrait")
                }
            } header: {
                Text("الشاشة")
            } footer: {
                Text(customRes
                     ? "الدقة المخصصة تحدد الشكل بنفسها، فلا يفعل هذا شيئًا وهي "
                     + "مفعّلة. اكتب مقاسًا عريضًا للوضع الأفقي."
                     : "لا يستطيع أندرويد تغيير شكل الشاشة بعد تشغيلها، فتصبح اللعبة "
                     + "الأفقية على شاشة عمودية شريطًا صغيرًا. إنشاؤها أفقية هو "
                     + "الطريقة الوحيدة لملء الشاشة — أما التطبيقات العمودية "
                     + "فتُحاط بأشرطة سوداء. يكلف إقلاعًا باردًا واحدًا.")
            }

            Section {
                Toggle("دقة مخصصة", isOn: $customRes)
                    .onChange(of: customRes) { v in
                        UserDefaults.standard.set(v, forKey: "husk.customRes")
                        store()
                        HuskLog.log("ui", v ? "custom resolution on: "
                                            + "\(widthText)x\(heightText)"
                                            : "custom resolution off")
                    }

                if customRes {
                    Picker("جاهز", selection: Binding(
                        get: { presetIndex },
                        set: { i in
                            guard i >= 0, i < Self.presets.count else { return }
                            widthText = String(Self.presets[i].w)
                            heightText = String(Self.presets[i].h)
                            store()
                        })) {
                        ForEach(0..<Self.presets.count, id: \.self) { i in
                            Text(Self.presets[i].name).tag(i)
                        }
                        Text("مخصص").tag(-1)
                    }

                    HStack {
                        Text("العرض")
                        Spacer()
                        TextField("720", text: $widthText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.technical())
                            .frame(width: 90)
                            .onChange(of: widthText) { _ in store() }
                    }
                    HStack {
                        Text("الارتفاع")
                        Spacer()
                        TextField("1280", text: $heightText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.technical())
                            .frame(width: 90)
                            .onChange(of: heightText) { _ in store() }
                    }

                    if let size = effective {
                        DetailRow(label: "سيحصل أندرويد على",
                                  value: "\(size.w) × \(size.h)")
                    } else {
                        Text("يجب أن يكون كلا البعدين بين 240 و2560.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                DetailRow(label: "يعمل الآن", value: running)
            } header: {
                Text("الدقة")
            } footer: {
                Text("تُبنى الشاشة عند بدء تشغيل الجهاز، فالتغيير يكلف إقلاعًا "
                   + "باردًا واحدًا، والحفظ التالي يستبدل الجهاز المحفوظ بالمقاس "
                   + "القديم — والعودة تكلف آخر. تُقرَّب المقاسات إلى مضاعفات "
                   + "الثمانية. الأكبر أبطأ: كل بكسل يرسمه هاتف محاكى. كثافة "
                   + "أندرويد لا تتغير مع الشاشة، فالأكبر يعرض أكثر لا أكبر.")
            }

            Section {
                Text("اللمس يعمل دائمًا. لوحة المفاتيح وزر التدوير في الشريط أسفل "
                   + "شاشة الضيف؛ أما يد التحكم والمؤشر فغير موصولَين بعد.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("عناصر التحكم")
            }
        }
        .huskForm()
        .navigationTitle("الإدخال")
    }

    /// The panel the guest actually has, which only means anything while there
    /// is a guest: the stored value is last launch's until one starts.
    private var running: String {
        guard QemuRunner.shared.isRunning else { return "لم يبدأ" }
        return "\(QemuRunner.lastGuestRes.w) × \(QemuRunner.lastGuestRes.h)"
    }

    /// Which preset the typed numbers are, if any.
    private var presetIndex: Int {
        guard let size = effective else { return -1 }
        return Self.presets.firstIndex { $0.w == size.w && $0.h == size.h } ?? -1
    }

    private func store() {
        UserDefaults.standard.set(Int(widthText) ?? 0, forKey: "husk.resWidth")
        UserDefaults.standard.set(Int(heightText) ?? 0, forKey: "husk.resHeight")
    }
}

// MARK: - Network

struct NetworkSettings: View {
    @State private var keepNetwork =
        UserDefaults.standard.object(forKey: "husk.keepNetwork") as? Bool ?? true

    var body: some View {
        Form {
            Section {
                Toggle("إبقاء الشبكة عند الحفظ", isOn: $keepNetwork)
                    .onChange(of: keepNetwork) { v in
                        UserDefaults.standard.set(v, forKey: "husk.keepNetwork")
                    }
            } footer: {
                Text(keepNetwork
                     ? "الحفظ يغلق التطبيقات لكنه يُبقي إطار أندرويد يعمل، فتبقى "
                     + "الشبكة تعمل بعد الاستعادة."
                     : "الحفظ يوقف الإطار أيضًا. يمسح كل موارد معالج الرسوميات، "
                     + "وهذا أكثر ثباتًا — لكن الشبكة قد لا تعود حتى إقلاع بارد.")
            }

            Section {
                Text("يصل أندرويد إلى الإنترنت عبر بطاقة شبكة افتراضية على شبكة "
                   + "QEMU الخاصة. لا شيء على شبكة هاتفك يستطيع رؤية الضيف، "
                   + "والضيف لا يستطيع رؤيتها.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("كيف يتصل")
            }
        }
        .huskForm()
        .navigationTitle("الشبكة")
    }
}

// MARK: - JIT and sideloading

struct JITSettings: View {
    @ObservedObject private var runner = QemuRunner.shared
    @State private var autoStart = Onboarding.autoStart
    @State private var keepAttached = JITBootstrap.keepDebuggerAttached

    var body: some View {
        Form {
            Section {
                DetailRow(label: "المصحح",
                          value: JITBootstrap.isDebuggerAttached ? "متصل" : "غير متصل",
                          mono: false)
                DetailRow(label: "ذاكرة قابلة للتنفيذ",
                          value: JITBootstrap.isLive ? "مُمنَحة" : "غير مُحصَّلة", mono: false)
                // The two routes, named separately. Either one is enough, and
                // when someone reports "JIT does not work" these two rows are
                // the whole diagnosis.
                DetailRow(label: "معالج المصائد",
                          value: JITBootstrap.prewarmed ? "يستجيب" : "لا يستجيب",
                          mono: false)
                // Cached answer only: running the probe from a view body
                // could freeze the app (see JITBootstrap.mapJITWorks).
                DetailRow(label: "MAP_JIT",
                          value: JITBootstrap.deviceEnforcesTXM ? "غير مستخدم (TXM)"
                               : JITBootstrap.mapJITResult.map { $0 ? "يُنفَّذ" : "مرفوض" }
                                 ?? "لم يُختبر",
                          mono: false)
                DetailRow(label: "المصحح بعد الإعداد",
                          value: JITBootstrap.detached ? "منفصل" : "متصل",
                          mono: false)
                if let why = JITBootstrap.lastFailure {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
                if !JITBootstrap.isDebuggerAttached {
                    Button {
                        _ = JITBootstrap.requestAttach()
                    } label: {
                        Label("تفعيل JIT عبر StikDebug", systemImage: "bolt.fill")
                    }
                    Button {
                        _ = JITBootstrap.requestTrollStoreAttach()
                    } label: {
                        Label("تفعيل JIT عبر TrollStore", systemImage: "sparkles")
                    }
                }
            } header: {
                Text("JIT")
            } footer: {
                Text("يحتاج Husk إلى ذاكرة يكتب فيها ثم ينفّذها، وهذا على iOS "
                   + "يتطلب مصححًا متصلًا. هناك طريقتان للحصول عليه: مصحح يلبّي "
                   + "طلبات المصائد، أو تعيين MAP_JIT الذي تسمح به النواة لأي "
                   + "عملية مصحَّحة. أيٌّ منهما يكفي — والمتاح منهما يعتمد على "
                   + "الجهاز وإصدار iOS، لذا يختبر Husk الاثنين بدل الافتراض.")
            }

            Section {
                Toggle("تشغيل أندرويد عند الفتح", isOn: $autoStart)
                    .onChange(of: autoStart) { v in
                        UserDefaults.standard.set(v, forKey: "husk.autoStart")
                    }
            } footer: {
                Text("يقلع الضيف فور فتح Husk عندما يكون JIT متاحًا.")
            }

            Section {
                Toggle("إبقاء المصحح متصلًا", isOn: $keepAttached)
                    .onChange(of: keepAttached) { v in JITBootstrap.keepDebuggerAttached = v }
            } footer: {
                Text("مطفأ افتراضيًا. يفصل Husk عن StikDebug فور امتلاك منطقة "
                   + "JIT، لأن مصححًا علّقه iOS يوقف التطبيق كله في المرة التالية "
                   + "التي يُحتاج فيها. فعّله فقط لجمع سجلات StikDebug الخاصة.")
            }

            Section {
                Text("تُثبَّت ملفات APK من زر + في المكتبة أو من تبويب الملفات. "
                   + "الحزم المقسّمة — ملف أساسي مع قطع الإعداد — يجب اختيارها "
                   + "معًا؛ تثبيت الأساسي وحده يفشل بسبب المكتبات الأصلية الناقصة.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("التثبيت اليدوي")
            }
        }
        .huskForm()
        .navigationTitle("JIT والتثبيت اليدوي")
    }
}

// MARK: - Saved machine

struct SavedMachineSettings: View {
    @ObservedObject private var runner = QemuRunner.shared
    @State private var autoSave =
        UserDefaults.standard.object(forKey: "husk.autoSave") as? Bool ?? true
    @State private var useSnapshot =
        UserDefaults.standard.object(forKey: "husk.downloadSnapshot") as? Bool ?? true
    @State private var askWhichToDelete = false
    @State private var deleteResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("حفظ تلقائي", isOn: $autoSave)
                    .onChange(of: autoSave) { v in
                        UserDefaults.standard.set(v, forKey: "husk.autoSave")
                        HuskLog.log("ui", v ? "automatic saving on" : "automatic saving off")
                    }
                Button {
                    QemuRunner.shared.saveState(reason: "asked from settings")
                } label: {
                    Label(runner.isSavingState ? "جارٍ الحفظ…" : "احفظ الآن",
                          systemImage: "externaldrive.badge.checkmark")
                }
                .disabled(runner.isSavingState)
            } footer: {
                Text("يستعيد Husk جهازًا محفوظًا بدل إقلاعه، فيستغرق ثوانٍ بدل "
                   + "دقائق. تتجمد الصورة أثناء الكتابة. ومع إيقافه لا يُحفظ شيء "
                   + "تلقائيًا — حتى بعد التثبيت.")
            }

            Section {
                Button(role: .destructive) { askWhichToDelete = true } label: {
                    Label("حذف الجهاز المحفوظ", systemImage: "trash")
                }
                .disabled(!QemuRunner.shared.hasSnapshot)
                if let deleteResult {
                    Text(deleteResult).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text(QemuRunner.shared.hasSnapshot
                     ? "المحفوظ حاليًا: "
                     + ((QemuRunner.shared.snapshotDisplay ?? "sw").contains("gl")
                        ? "GPU" : "البرمجيات") + "."
                     : "لا شيء محفوظ، فيقلع أندرويد من الصفر.")
            }

            Section {
                Toggle("تنزيل لقطة مُقلَعة مسبقًا", isOn: $useSnapshot)
                    .onChange(of: useSnapshot) { v in
                        UserDefaults.standard.set(v, forKey: "husk.downloadSnapshot")
                    }
            } footer: {
                Text("يضيف حوالي 2 غيغابايت للتنزيل الأول. التُقطت على معالج "
                   + "البرمجيات، فلا تُستخدم على GPU — الذي يقلع من الصفر مرة "
                   + "ثم يحفظ لقطته.")
            }
        }
        .huskForm()
        .navigationTitle("الجهاز المحفوظ")
        .confirmationDialog("أي جهاز محفوظ؟", isPresented: $askWhichToDelete,
                            titleVisibility: .visible) {
            Button("جهاز GPU", role: .destructive) { forget("gl", "GPU") }
            Button("جهاز البرمجيات", role: .destructive) { forget("sw", "البرمجيات") }
            Button("إلغاء", role: .cancel) { }
        } message: {
            Text("سيقلع أندرويد من الصفر مرة واحدة، ثم يحفظ جهازًا جديدًا.")
        }
    }

    private func forget(_ mode: String, _ name: String) {
        if QemuRunner.shared.forgetSnapshot(mode: mode) {
            deleteResult = "حُذف \(name) المحفوظ. الإقلاع التالي من الصفر."
        } else {
            deleteResult = "لا يوجد \(name) محفوظ، فلم يُحذف شيء."
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @State private var appIcon = HuskAppIcon.current
    @AppStorage(Theme.Appearance.key) private var appearance = Theme.Appearance.dark
    @Environment(\.colorScheme) private var scheme

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 14)]

    var body: some View {
        ZStack {
            Theme.backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("المظهر", selection: $appearance) {
                        ForEach(Theme.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearance) { v in
                        HuskLog.log("ui", "appearance: \(v.rawValue)")
                    }
                    Text("النظام يتبع الهاتف. شاشة الضيف تبقى داكنة في الحالتين "
                       + "— فهي صورة لهاتف آخر.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 18).padding(.top, 12)

                SectionHeader(title: "أيقونة التطبيق")
                    .padding(.horizontal, 22).padding(.top, 14)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(HuskAppIcon.allCases) { icon in
                        Button {
                            appIcon = icon
                            HuskAppIcon.apply(icon)
                        } label: {
                            VStack(spacing: 8) {
                                if let art = icon.preview(dark: scheme == .dark) {
                                    Image(uiImage: art)
                                        .resizable().scaledToFit()
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 14,
                                                                    style: .continuous))
                                }
                                Text(icon.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            // The selected icon is ringed in the accent rather
                            // than filled with it: the artwork is the subject
                            // here, and a tinted panel behind it changes how
                            // the thing you are choosing looks.
                            .background(Theme.surface,
                                        in: RoundedRectangle(cornerRadius: Theme.cardCorner,
                                                             style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner,
                                                      style: .continuous)
                                        .stroke(appIcon == icon ? Theme.accent
                                                                : Theme.hairline,
                                                lineWidth: appIcon == icon ? 2 : 0.5))
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8)

                Text("التلقائي يتبع مظهر النظام — فاتح وداكن وملوّن. البقية تثبّت "
                   + "مظهرًا واحدًا. يعرض iOS تأكيده الخاص بعد التغيير؛ ولا يمكن "
                   + "إيقاف ذلك التنبيه.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28).padding(.vertical, 18)
            }
        }
        .navigationTitle("المظهر")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About

struct AboutSettings: View {
    @ObservedObject private var runner = QemuRunner.shared
    @State private var showLogs = false
    @AppStorage(TranslationLayer.devInfoKey) private var devInfo = false

    var body: some View {
        ZStack {
            Theme.backdrop
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        HuskMark(size: 76)
                        Text("Husk")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("الإصدار \(Bundle.main.version)")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textDim)
                    }
                    .padding(.top, 10)

                    RowGroup {
                        VStack(spacing: 12) {
                            DetailRow(label: "البناء", value: Bundle.main.commit)
                            DetailRow(label: "صورة الضيف", value: GuestImage.imageVersion)
                            DetailRow(label: "المعالج الرسومي",
                                      value: runner.displayKind == .gl ? "GPU"
                                           : runner.displayKind == .software ? "CPU"
                                           : "لم يبدأ")
                        }
                        .padding(14)
                    }

                    RowGroup {
                        Toggle(isOn: $devInfo) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("معلومات المطوّر")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                Text("تفاصيل تقنية في شاشات Android Translation Layer: "
                                   + "تقارير المكتبات وفحوصات الجهاز وسجلات التشغيل.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textDim)
                            }
                        }
                        .padding(14)
                    }

                    Button { showLogs = true } label: {
                        Label("فتح السجل", systemImage: "terminal")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("يشغّل Husk ملفات APK الأصلية دون تعديل في نظام أندرويد "
                       + "حقيقي على آيفونك. يعرض السجل سجل Husk المباشر ومخرجات "
                       + "الضيف التسلسلية ومخرجات QEMU — وهي الملفات الثلاثة التي "
                       + "تُشخَّص منها أي مشكلة.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
        }
        .navigationTitle("حول")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogs) { LogView() }
    }
}

extension Bundle {
    var version: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
    var commit: String {
        (infoDictionary?["HuskBuildCommit"] as? String) ?? "?"
    }
}
