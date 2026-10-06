// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// What Husk asks on a first install, and remembers.
///
/// Deliberately versioned rather than a plain "seen it" flag: a later build that
/// adds a question needs to be able to ask it, and existing installs must not be
/// dragged back through the whole flow for one new answer. Bumping
/// `Onboarding.version` is what re-opens it.
enum Onboarding {
    /// Raise this when a question is added that existing installs must answer.
    static let version = 1

    private static let key = "husk.onboardingVersion"

    static var needed: Bool {
        UserDefaults.standard.integer(forKey: key) < version
    }

    static func complete() {
        UserDefaults.standard.set(version, forKey: key)
    }

    /// Start the guest as soon as the app opens, when JIT is available.
    static var autoStart: Bool {
        UserDefaults.standard.bool(forKey: "husk.autoStart")
    }
}

/// الترحيب — مصمم من الصفر على نمط شاشات "مرحبًا" في تطبيقات آبل: عنوان كبير،
/// قائمة مزايا برموز ملوّنة، ثم الخيارات كمفاتيح أصلية، وزر ثابت في الأسفل.
struct OnboardingView: View {
    let onDone: () -> Void

    @State private var page = 0
    @State private var autoStart = true
    @State private var landscape = UserDefaults.standard.bool(forKey: "husk.landscapeGuest")
    @State private var sound = UserDefaults.standard.bool(forKey: "husk.sound")
    @State private var autoSave =
        UserDefaults.standard.object(forKey: "husk.autoSave") as? Bool ?? true

    private let pages = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                choices.tag(1)
                ready.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.3), value: page)

            VStack(spacing: 14) {
                HStack(spacing: 7) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Theme.text : Theme.textFaint)
                            .frame(width: 7, height: 7)
                    }
                }
                Button {
                    if page < pages - 1 {
                        withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                    } else {
                        save()
                        onDone()
                    }
                } label: {
                    Text(page < pages - 1 ? "متابعة" : "ابدأ")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
            }
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(Theme.backdrop)
        .interactiveDismissDisabled()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(autoStart, forKey: "husk.autoStart")
        d.set(landscape, forKey: "husk.landscapeGuest")
        d.set(sound, forKey: "husk.sound")
        d.set(autoSave, forKey: "husk.autoSave")
        Onboarding.complete()
        HuskLog.log("ui", "setup complete: autoStart=\(autoStart) landscape=\(landscape) "
                        + "sound=\(sound) autoSave=\(autoSave)")
    }

    // MARK: pages

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .center, spacing: 18) {
                    HuskMark(size: 96)
                        .shadow(color: Theme.shadow, radius: 16, y: 8)
                    Text("مرحبًا بك في\nIOS APP")
                        .font(.system(size: 34, weight: .bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 50)

                VStack(alignment: .leading, spacing: 26) {
                    feature("shippingbox.fill", .green, "تطبيقات أندرويد حقيقية",
                            "ثبّت أي ملف APK وافتحه بملء الشاشة على آيفونك.")
                    feature("bolt.fill", .orange, "سريع مع JIT",
                            "يترجم المعالج كتلةً بكتلة، ويحفظ الجهاز ليعود خلال ثوانٍ.")
                    feature("lock.shield.fill", .blue, "معزول وآمن",
                            "أندرويد يعمل داخل التطبيق فقط، ولا يصل إلى ملفات آيفونك.")
                }
                .padding(.horizontal, 34)
            }
            .padding(.bottom, 20)
        }
    }

    private func feature(_ icon: String, _ color: Color, _ title: String,
                         _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(color)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 15))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var choices: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Text("كيف تريد أن يعمل؟")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("يمكنك تغيير هذه الخيارات لاحقًا من الإعدادات.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textDim)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
                .listRowBackground(Color.clear)
            }
            Section {
                choice("bolt.fill", .orange, "تشغيل أندرويد عند الفتح",
                       "يُقلع فور فتح التطبيق عندما يكون JIT متاحًا.", $autoStart)
                choice("rectangle.landscape.rotate", .blue, "شاشة أفقية",
                       "تناسب الألعاب، والتطبيقات العمودية تظهر داخل إطار.", $landscape)
                choice("speaker.wave.2.fill", .pink, "الصوت",
                       "لا يمكن حفظ أندرويد أثناء تفعيله.", $sound)
                choice("externaldrive.fill.badge.checkmark", .green, "الحفظ التلقائي",
                       "يستعيد الجهاز خلال ثوانٍ بدل الإقلاع من جديد.", $autoSave)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func choice(_ icon: String, _ color: Color, _ title: String,
                        _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 14) {
                SettingsIcon(systemImage: icon, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.good)
        .padding(.vertical, 4)
    }

    private var ready: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 76))
                .foregroundStyle(Theme.good)
                .symbolRenderingMode(.hierarchical)
            Text("كل شيء جاهز")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("يحتاج IOS APP إلى JIT لتشغيل أندرويد، ولا يمنحه في iOS إلا أداة "
               + "تصحيح مثل StikDebug. إن لم يكن مفعّلًا ستخبرك المكتبة وتعرض فتحه.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
    }
}
