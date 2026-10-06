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

struct OnboardingView: View {
    let onDone: () -> Void

    @State private var page = 0
    @State private var autoStart = true
    @State private var landscape = UserDefaults.standard.bool(forKey: "husk.landscapeGuest")
    @State private var sound = UserDefaults.standard.bool(forKey: "husk.sound")
    @State private var autoSave =
        UserDefaults.standard.object(forKey: "husk.autoSave") as? Bool ?? true
    @Environment(\.colorScheme) private var scheme

    private let pages = 3

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    choices.tag(1)
                    ready.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // One control, always in the same place. A flow that moves its
                // own button around is harder to get through than one that does
                // not, and this is the first thing anyone sees.
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        ForEach(0..<pages, id: \.self) { i in
                            Capsule()
                                .fill(i == page ? Theme.accent : Color.secondary.opacity(0.3))
                                .frame(width: i == page ? 18 : 6, height: 6)
                                .animation(.easeOut(duration: 0.22), value: page)
                        }
                    }
                    Button {
                        if page < pages - 1 {
                            withAnimation(.easeOut(duration: 0.22)) { page += 1 }
                        } else {
                            save()
                            onDone()
                        }
                    } label: {
                        Text(page < pages - 1 ? "متابعة" : "ابدأ استخدام ios app")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 28)
                }
                .padding(.bottom, 28)
            }
        }
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
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            if let art = HuskAppIcon.current.preview(dark: scheme == .dark) {
                Image(uiImage: art)
                    .resizable().scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
            }
            Text("ios app")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("تطبيقاتك.\nمساحة جديدة.")
                .font(.system(size: 44, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("مكتبة بسيطة على آيفونك لتشغيل تطبيقات أندرويد. "
               + "استورد APK، نظّم ملفاتك، وافتح تطبيقاتك من مكان واحد.")
                .font(.system(size: 17))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Label("يتطلب JIT وبيئة أندرويد منفصلة", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var choices: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("خلّه على طريقتك")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 34).padding(.bottom, 6)

                choice(icon: "bolt.fill", title: "تشغيل أندرويد عند الفتح",
                       detail: "يُقلع نظام الضيف فور فتح ios app، عندما يكون JIT "
                             + "متاحًا. إيقافه يعني أنك تشغّله بنفسك.",
                       isOn: $autoStart)

                choice(icon: "rectangle.landscape.rotate", title: "شاشة أفقية",
                       detail: "يمنح أندرويد شاشة أفقية تملؤها الألعاب "
                             + "جيدًا، وتظهر تطبيقات الوضع العمودي داخل إطار.",
                       isOn: $landscape)

                choice(icon: "speaker.wave.2.fill", title: "الصوت",
                       detail: "يضيف جهاز صوت. لا يمكن حفظ أندرويد أثناء "
                             + "تفعيله، لذا يبدأ كل تشغيل من الصفر.",
                       isOn: $sound)

                choice(icon: "externaldrive.badge.checkmark", title: "الحفظ التلقائي",
                       detail: "يحفظ الجهاز بعد استقرار أندرويد، فتستعيده "
                             + "التشغيلات التالية خلال ثوانٍ بدل الإقلاع من جديد.",
                       isOn: $autoSave)
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private func choice(icon: String, title: String, detail: String,
                        isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9,
                                                                   style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().tint(Theme.accent)
        }
        .padding(16)
        .huskCard()
    }

    private var ready: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 62))
                .foregroundStyle(Theme.accent)
            Text("جاهز").font(.largeTitle.weight(.semibold))
            Text("يحتاج ios app إلى JIT لتشغيل أندرويد، ولا يمنحه في iOS إلا أداة "
               + "تصحيح الأخطاء. إن لم يكن مفعّلًا، ستخبرك المكتبة بذلك وتعرض "
               + "عليك فتح StikDebug.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer()
        }
    }
}
