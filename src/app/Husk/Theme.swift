// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

// MARK: - IOS APP design system
//
// أُعيد تصميمه من الصفر بلغة آبل البصرية:
//   • الصفحات "مجمّعة" مثل الإعدادات وApp Store: خلفية systemGroupedBackground
//     وبطاقات بيضاء (أو رمادية داكنة) بلا حدود، بزوايا مستمرة 16 نقطة.
//   • لون التمييز أزرق آبل، ومعه لون الهوية "Graphite" المأخوذ من الأيقونة.
//   • الأزرار الرئيسية كبسولات مثل زر "تنزيل" في App Store.
//   • اللوحات العائمة فوق أندرويد من مادة iOS الضبابية.
//   • الخط هو خط النظام بأوزانه، والأرقام بخط أحادي المسافة.
//
// كل الأسماء العامة (Theme.*، huskCard، HuskRow…) محفوظة حتى تبقى الشاشات
// الفرعية تعمل، لكن شكلها كله تغيّر.

enum Theme {
    // الصفحة
    static let bgUI = UIColor.systemGroupedBackground
    static let bg = Color(uiColor: bgUI)
    /// البطاقة: أبيض في الفاتح، رمادي مرتفع في الداكن.
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// عناصر فوق البطاقة: رقائق، حقول بحث، آبار الأيقونات.
    static let surfaceHigh = Color(uiColor: .tertiarySystemFill)
    static let hairlineUI = UIColor.separator
    static let hairline = Color(uiColor: hairlineUI)

    // النص
    static let textUI = UIColor.label
    static let text = Color(uiColor: textUI)
    static let textDim = Color(uiColor: .secondaryLabel)
    static let textFaint = Color(uiColor: .tertiaryLabel)

    // الألوان
    static let accent = Color(uiColor: .systemBlue)
    static let accentSoft = Color(uiColor: .systemBlue).opacity(0.14)
    /// لون الهوية، من الأيقونة: جرافيت مع لمعة فضية.
    static let graphite = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1)
        : UIColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1) })
    static let good = Color(uiColor: .systemGreen)
    static let warn = Color(uiColor: .systemOrange)
    static let shadow = Color(uiColor: UIColor { $0.userInterfaceStyle == .light
        ? UIColor.black.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.45) })

    // الأشكال
    static let cardCorner: CGFloat = 16
    static let rowCorner: CGFloat = 14

    static var backdrop: some View { bg.ignoresSafeArea() }

    /// The appearance the app is drawn in. يتبع النظام افتراضيًا كأي تطبيق آيفون.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        static let key = "husk.appearance"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "تلقائي"
            case .light: return "فاتح"
            case .dark: return "داكن"
            }
        }

        var style: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }

        static var current: Appearance {
            Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
        }
    }

    /// Through UIKit rather than `.preferredColorScheme`, so "system" really lets go.
    static func apply(_ appearance: Appearance) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = appearance.style
            }
        }
    }
}

// MARK: - Surfaces

extension View {
    /// بطاقة iOS: سطح مرتفع، بلا حدّ، مع ظل خفيف جدًا في الوضع الفاتح.
    @ViewBuilder
    func huskCard<S: Shape>(_ shape: S, high: Bool = false) -> some View {
        self.background(high ? Theme.surfaceHigh : Theme.surface, in: shape)
    }

    func huskCard(high: Bool = false) -> some View {
        huskCard(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous), high: high)
    }

    /// بطاقة بارزة (للحالة والعناصر المميزة) بظل ناعم.
    func huskElevated(corner: CGFloat = 22) -> some View {
        self.background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: Theme.shadow, radius: 14, y: 6)
    }

    /// Chrome over the guest's picture: iOS material, always dark.
    func huskPanel<S: Shape>(_ shape: S) -> some View {
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
    }
}

extension Font {
    /// Technical values -- sizes, counts, hashes -- in a monospaced face.
    static func technical(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Buttons

/// الزر الرئيسي: كبسولة ممتلئة بعرض الشاشة.
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Theme.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(enabled ? Theme.accent : Theme.surfaceHigh,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// زر صغير على شكل كبسولة مثل "تنزيل" و"فتح" في App Store.
struct PillButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(filled ? Color.white : Theme.accent)
            .padding(.horizontal, 18).padding(.vertical, 6)
            .frame(minWidth: 74)
            .background(filled ? Theme.accent : Theme.surfaceHigh, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A card that is also a button: it gives a little under the finger.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// زر دائري للزوايا.
struct CircleButton: View {
    let systemImage: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.white : Theme.accent)
                .frame(width: 34, height: 34)
                .background(active ? Theme.accent : Theme.surfaceHigh, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Identity

/// The app's mark, as drawn by whichever app icon is in use.
struct HuskMark: View {
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let art = HuskAppIcon.current.preview(dark: scheme == .dark) {
                Image(uiImage: art).resizable().scaledToFit()
            } else {
                ZStack {
                    Theme.graphite
                    Image(systemName: "circle.fill")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// مربع أيقونة ملوّن بأسلوب تطبيق الإعدادات.
struct SettingsIcon: View {
    let systemImage: String
    var color: Color = .gray
    var size: CGFloat = 29

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24,
                                                             style: .continuous))
    }
}

// MARK: - Small pieces

/// A filter pill.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Theme.text)
                .padding(.horizontal, 15).padding(.vertical, 7)
                .background(selected ? Theme.text : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: selected)
    }
}

/// A small tag under a title.
struct Tag: View {
    let text: String
    var tint: Color = Theme.textDim

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.surfaceHigh, in: Capsule())
    }
}

/// A label and a value on one line.
struct DetailRow: View {
    let label: String
    let value: String
    var mono: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.text)
            Spacer(minLength: 16)
            Text(value)
                .font(mono ? .technical(15) : .system(size: 15))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 16))
    }
}

/// One row of a grouped card, Settings-style.
struct HuskRow: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = Theme.text
    var showsChevron = true
    /// لون مربع الأيقونة. بدونه تُرسم الأيقونة بلون التمييز بلا مربع.
    var iconColor: Color? = nil

    var body: some View {
        HStack(spacing: 14) {
            if let iconColor {
                SettingsIcon(systemImage: systemImage, color: iconColor)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(tint == Theme.text ? Theme.accent : tint)
                    .frame(width: 29, height: 29)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, subtitle == nil ? 11 : 9)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Rows stacked into one card.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .huskCard(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

/// The hairline between two rows.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, 59)
    }
}

/// عنوان قسم بأسلوب App Store: عريض، ومعه رابط اختياري.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 15)).foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// A small status pill.
struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = Theme.accent

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// What a screen shows when it has nothing to show.
struct EmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(Theme.textFaint)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PillButtonStyle(filled: true))
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - Toast

/// What finished, said once and then gone.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let title: String
    var detail: String?
    var good = true
}

/// إشعار عائم بأسلوب إشعارات iOS: كبسولة ضبابية أعلى الشاشة.
struct ToastView: View {
    let toast: Toast
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.good ? "checkmark.circle.fill"
                                         : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(toast.good ? Theme.good : Theme.warn)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.shadow, radius: 20, y: 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .gesture(DragGesture(minimumDistance: 10).onEnded { v in
            if v.translation.height < -10 { onClose() }
        })
    }
}

// MARK: - Guest chrome

/// One control over the guest's picture.
struct GuestControl: View {
    let systemImage: String
    var active = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().scaleEffect(0.6).tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(active ? Theme.accent : .white)
                }
            }
            .frame(width: 48, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// رأس صفحة مرسوم يدويًا، تستخدمه الشاشات التي ما زالت لا تملك شريط تنقل.
struct HuskHeader<Trailing: View>: View {
    var mark = false
    var back: (() -> Void)? = nil
    var title: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let back {
                    Button(action: back) {
                        Label("رجوع", systemImage: "chevron.backward")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                } else if mark {
                    HuskMark(size: 30)
                }
                Spacer(minLength: 8)
                trailing
            }
            if let title {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.top, 4)
    }
}

extension HuskHeader where Trailing == EmptyView {
    init(mark: Bool = false, back: (() -> Void)? = nil, title: String? = nil) {
        self.init(mark: mark, back: back, title: title) { EmptyView() }
    }
}
