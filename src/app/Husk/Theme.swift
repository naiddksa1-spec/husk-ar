// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// Husk's visual vocabulary, in one place so every screen agrees.
///
/// Madar's iPhone-inspired host interface: native typography, grouped system
/// pages and restrained frosted chrome. Not an official future iPhone design.
///
/// Which appearance is shown is the user's choice (`Theme.Appearance`), and it
/// defaults to dark, so nobody who already has the app sees it change.
enum Theme {
    /// Graphite, porcelain and restrained iOS blue.
    /// System Arabic/SF typography keeps RTL, shaping and Dynamic Type native.
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }

    static let bgUI = adaptive(0xF2F2F7, 0x0C0D12)
    static let bg = Color(uiColor: bgUI)
    /// Cards, rows, anything holding content.
    static let surfaceUI = adaptive(0xFFFFFF, 0x1C1D24)
    static let surface = Color(uiColor: surfaceUI)
    /// One step further up: chips, icon wells, the things that sit on a card.
    static let surfaceHighUI = adaptive(0xE9E9F0, 0x2B2C35)
    static let surfaceHigh = Color(uiColor: surfaceHighUI)
    /// The edge that separates a surface from the page.
    static let hairlineUI = adaptive(0xDADAE1, 0x3A3B45)
    static let hairline = Color(uiColor: hairlineUI)

    static let textUI = adaptive(0x17181D, 0xF5F5FA)
    static let text = Color(uiColor: textUI)
    static let textDimUI = adaptive(0x61616E, 0xC7C7D2)
    static let textDim = Color(uiColor: textDimUI)

    static let accentUI = adaptive(0x075CCC, 0xB5D4FF)
    static let accent = Color(uiColor: accentUI)
    /// White-on-blue controls retain contrast in both appearances.
    static let action = Color(red: 0.03, green: 0.34, blue: 0.78)
    static let accentSoft = accent.opacity(0.13)
    static let champagne = Color(uiColor: adaptive(0x646176, 0xD2CDDF))
    static let onAction = Color.white
    static let actionGradient = LinearGradient(
        colors: [Color(red: 0.22, green: 0.40, blue: 0.88), action],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Darker on a light page: the dark-mode green all but vanishes on white.
    static let good = Color(uiColor: .systemGreen)
    /// What a floating thing casts. A light page wants far less of it.
    static let shadow = Color(uiColor: UIColor { $0.userInterfaceStyle == .light
        ? UIColor.black.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.4) })

    /// The appearance the app is drawn in.
    ///
    /// Dark is the default and the design the app was drawn for; System follows
    /// the phone; Light pins the light arrangement.
    enum Appearance: String, CaseIterable, Identifiable {
        case dark, light, system

        static let key = "husk.appearance"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dark: return "داكن"
            case .light: return "فاتح"
            case .system: return "النظام"
            }
        }

        var style: UIUserInterfaceStyle {
            switch self {
            case .dark: return .dark
            case .light: return .light
            case .system: return .unspecified
            }
        }

        static var current: Appearance {
            Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark
        }
    }

    /// Applies an appearance to every window the app has.
    ///
    /// Through UIKit rather than `.preferredColorScheme`: going back to "follow
    /// the system" means handing the window `nil`, and SwiftUI does not reliably
    /// let go of a scheme it has once forced. The window's own override does,
    /// and sheets and covers presented from it inherit it.
    static func apply(_ appearance: Appearance) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = appearance.style
            }
        }
    }

    static let cardCorner: CGFloat = 22
    static let rowCorner: CGFloat = 16

    static var backdrop: some View {
        LinearGradient(colors: [surface, bg, bg],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    /// Fixed, vector wallpaper: ambient depth without per-frame effects.
    /// This lives behind the launcher only, never over a running Android surface.
    static var homeWallpaper: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.13),
                                         Color(red: 0.18, green: 0.15, blue: 0.29),
                                         Color(red: 0.10, green: 0.13, blue: 0.24)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: geometry.size.width * 0.60, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.83, green: 0.72, blue: 0.79),
                                                  Color(red: 0.32, green: 0.29, blue: 0.47),
                                                  Color(red: 0.12, green: 0.14, blue: 0.24)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: geometry.size.width * 1.4, height: geometry.size.height * 0.85)
                    .rotationEffect(.degrees(-36))
                    .offset(x: geometry.size.width * 0.43, y: geometry.size.height * 0.12)
                RoundedRectangle(cornerRadius: geometry.size.width * 0.55, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.49, green: 0.59, blue: 0.75),
                                                  Color(red: 0.21, green: 0.28, blue: 0.44),
                                                  Color(red: 0.09, green: 0.10, blue: 0.18)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: geometry.size.width * 1.30, height: geometry.size.height * 0.90)
                    .rotationEffect(.degrees(34))
                    .offset(x: -geometry.size.width * 0.36, y: geometry.size.height * 0.44)
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.28)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Style UIKit-backed navigation, tabs and form rows without replacing
    /// navigation stacks or touching the mounted guest rendering surface.
    @MainActor static func configureChrome() {
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = bgUI
        bar.shadowColor = hairlineUI
        for item in [bar.stackedLayoutAppearance, bar.inlineLayoutAppearance,
                     bar.compactInlineLayoutAppearance] {
            item.normal.iconColor = textDimUI
            item.normal.titleTextAttributes = [.foregroundColor: textDimUI]
            item.selected.iconColor = accentUI
            item.selected.titleTextAttributes = [.foregroundColor: accentUI]
        }
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = bgUI
        navigation.shadowColor = .clear
        navigation.titleTextAttributes = [.foregroundColor: textUI]
        navigation.largeTitleTextAttributes = [.foregroundColor: textUI]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UITableView.appearance().backgroundColor = bgUI
        UITableViewCell.appearance().backgroundColor = surfaceUI
    }

}

/// Use platform Material, with a solid fallback for Reduce Transparency.
/// Limited to small controls, not repeated app tiles or Android's renderer.
struct MadarGlass: ViewModifier {
    var radius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surface)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.regularMaterial)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Theme.hairline.opacity(0.45), lineWidth: 0.6))
    }
}


extension View {
    func madarGlass(radius: CGFloat = 24) -> some View {
        modifier(MadarGlass(radius: radius))
    }
    /// The app's one container: a lifted surface with a hairline edge.
    @ViewBuilder
    func huskCard<S: Shape>(_ shape: S, high: Bool = false) -> some View {
        self.background(high ? Theme.surfaceHigh : Theme.surface, in: shape)
            .overlay(shape.stroke(Theme.hairline.opacity(0.7), lineWidth: 0.7))
    }

    func huskCard(high: Bool = false) -> some View {
        huskCard(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous),
                 high: high)
    }

    /// Chrome that sits over the guest's own picture.
    ///
    /// Solid, not glass. iOS 26 will happily render this as Liquid Glass and it
    /// looks wrong here: a floating, refracting pill over a game is the phone's
    /// design language arguing with the app's, and over a dark guest screen it
    /// mostly reads as smeared. A flat panel with a hairline is what the design
    /// asks for, and it looks the same on every iOS.
    ///
    /// Always the dark one, whatever the app's appearance: it floats over a
    /// guest that is mostly black, and the controls on it are drawn in white.
    func huskPanel<S: Shape>(_ shape: S) -> some View {
        self.background(Color(red: 0.13, green: 0.12, blue: 0.14).opacity(0.97), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
    }
}


/// Technical values — sizes, counts, frame rates, commit hashes — are set in a
/// monospaced face so digits line up between rows and do not reflow as they
/// change.
extension Font {
    static func technical(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The one action a screen is for.
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(enabled ? Theme.onAction : Theme.textDim)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18).padding(.vertical, 17)
            .background {
                RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                    .fill(enabled ? Theme.action : Theme.surfaceHigh)
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .stroke(Color.white.opacity(enabled ? 0.12 : 0), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A card that is also a button: it moves a little under the finger.
struct CardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// The round glyph buttons in a screen's top corner.
struct CircleButton: View {
    let systemImage: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? .white : Theme.text)
                .frame(width: 44, height: 44)
                .background(active ? Theme.action : Theme.surfaceHigh,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.champagne.opacity(0.18), lineWidth: 0.8))
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityLabel(accessibilityTitle)
    }

    private var accessibilityTitle: String {
        switch systemImage {
        case "plus": return "إضافة"
        case "rectangle.inset.filled": return "عرض أندرويد"
        case "arrow.clockwise": return "تحديث"
        case "chevron.left": return "رجوع"
        case "magnifyingglass": return "بحث"
        default: return systemImage
        }
    }
}

/// Husk's mark, as drawn by whichever app icon is in use.
struct HuskMark: View {
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let art = HuskAppIcon.current.preview(dark: scheme == .dark) {
                Image(uiImage: art).resizable().scaledToFit()
            } else {
                Image(systemName: "cube.fill").font(.system(size: size * 0.6))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// A filter pill.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Theme.onAction : Theme.textDim)
                .padding(.horizontal, 17).padding(.vertical, 11)
                .background(selected ? Theme.action : Theme.surfaceHigh, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small tag under a title — a category, an ABI, a state.
struct Tag: View {
    let text: String
    var tint: Color = Theme.textDim

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.surfaceHigh, in: Capsule())
    }
}

/// A label and a value on one line, for anything worth reading off.
struct DetailRow: View {
    let label: String
    let value: String
    var mono: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textDim)
            Spacer(minLength: 16)
            Text(value)
                .font(mono ? .technical() : .system(size: 15))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 15))
    }
}

/// One row of a grouped card: an icon, a title, an optional subtitle, and the
/// chevron that says it goes somewhere.
struct HuskRow: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = Theme.text
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            HuskGlyph(systemImage: systemImage, tint: glyphTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textDim.opacity(0.7))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .contentShape(Rectangle())
    }

    private var glyphTint: Color {
        if systemImage.contains("folder") || systemImage.contains("externaldrive") { return Theme.champagne }
        if systemImage.contains("globe") || systemImage.contains("network") { return Theme.good }
        return Theme.accent
    }
}

/// Soft enamel wells give navigation symbols character while keeping familiar
/// SF silhouettes. Third-party app artwork is never replaced.
struct HuskGlyph: View {
    let systemImage: String
    var tint: Color = Theme.accent

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 0.7))
            .accessibilityHidden(true)
    }
}

/// Rows stacked into one card, hairlines between them.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .huskCard()
    }
}

/// The hairline between two rows in a group.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 62)
    }
}

/// A section label above a group.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 13)).foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// A small status pill. The tint carries the meaning, the text the detail.
struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = Theme.accent

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.16), in: Capsule())
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
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.champagne)
                .frame(width: 88, height: 88)
                .background(Theme.surfaceHigh,
                            in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 44)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// What finished, said once and then gone.
///
/// Progress belongs in a strip that stays while the work does; this is for the
/// moment after — an APK installed, a machine saved. It says the thing and
/// leaves, because an outcome that needs dismissing is a dialog.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let title: String
    var detail: String?
    var good = true
}

struct ToastView: View {
    let toast: Toast
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.good ? "checkmark.circle.fill"
                                         : "exclamationmark.triangle.fill")
                .font(.system(size: 19))
                .foregroundStyle(toast.good ? Theme.good : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.surfaceHigh,
                    in: RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5))
        .shadow(color: Theme.shadow, radius: 18, y: 8)
    }
}

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
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(active ? Theme.accent : .white)
                }
            }
            .frame(width: 46, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// A screen's own header: the mark or a back arrow, whatever buttons belong in
/// the corner, and the big title under them.
///
/// Drawn rather than left to the navigation bar. On iOS 26 the system bar and
/// every button in it is Liquid Glass — a floating, refracting capsule that
/// belongs to a different design than this one, and cannot be told not to be.
/// Pushed screens keep the real bar, where the back gesture and the title
/// behaviour matter more than the finish; the roots draw their own.
struct HuskHeader<Trailing: View>: View {
    var mark = false
    var back: (() -> Void)? = nil
    var title: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 46, height: 46)
                            .background(Theme.surfaceHigh, in: Circle())
                    }
                    .buttonStyle(.plain)
                } else if mark {
                    HStack(spacing: 10) {
                        HuskMark(size: 40)
                        Text("MADAR")
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(3)
                            .foregroundStyle(Theme.champagne)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            if let title {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.top, 4)
    }
}

/// Optional brand motif for legacy surfaces. The launcher uses its wallpaper
/// and clock rather than repeated decorative portal framing.
struct PortalMotif: View {
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 42 - CGFloat(index) * 6, style: .continuous)
                    .stroke(Theme.champagne.opacity(0.30 - Double(index) * 0.06), lineWidth: 1)
                    .padding(CGFloat(index) * 12)
            }
            HuskMark(size: 80)
        }
        .frame(width: 116, height: 142)
        .rotationEffect(.degrees(-9))
        .accessibilityHidden(true)
    }
}

struct HuskSpotlight: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Text(eyebrow)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.champagne)
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HuskMark(size: 64).accessibilityHidden(true)
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [Theme.surfaceHigh, Theme.surface],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .stroke(Theme.hairline.opacity(0.35), lineWidth: 0.8))
    }
}

extension HuskHeader where Trailing == EmptyView {
    init(mark: Bool = false, back: (() -> Void)? = nil, title: String? = nil) {
        self.init(mark: mark, back: back, title: title) { EmptyView() }
    }
}
