// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// The screen Husk opens on when it is starting Android for you.
///
/// Before this, "start on launch" dropped you into a library whose apps could
/// not be opened yet, with a strip at the top explaining why — which is a UI
/// asking you to wait in front of it. A boot is a boot: it gets its own screen,
/// it says how far along it is, and it talks to you while it works. The phrases
/// are there because two minutes of a progress bar is two minutes of wondering
/// whether it has hung.
struct BootScreen: View {
    let onSkip: () -> Void

    @ObservedObject private var runner = QemuRunner.shared
    @ObservedObject private var host = AndroidHost.shared

    @State private var phrase = 0
    @State private var began = Date()
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let rotate = Timer.publish(every: 3.4, on: .main, in: .common).autoconnect()

    /// Said in order, not at random: the first two land while someone is still
    /// looking at the screen, and the jokes should not repeat before the
    /// information does.
    private static let phrases = [
        "يُستعاد الجهاز المحفوظ إن كان متاحًا.",
        "الإقلاع الأول قد يستغرق عدة دقائق.",
        "تقدر تتصفح مكتبتك أثناء التشغيل.",
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                HuskMark(size: 96)

                Text("ios app")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.text)
                    .padding(.top, 18)
                Text("نجهّز مساحتك")
                    .font(.title3.weight(.medium))
                    .padding(.top, 8)

                // The line that talks. Keyed on the index so each one fades
                // into the next rather than snapping.
                Text(Self.phrases[phrase % Self.phrases.count])
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .frame(height: 42)
                    .padding(.horizontal, 30)
                    .id(phrase)
                    .transition(.opacity)
                    .padding(.top, 10)

                progress
                    .padding(.horizontal, 44)
                    .padding(.top, 6)

                Spacer()

                // What Android itself is doing, small, under everything else.
                // The phrases pass the time; this is the part that is true.
                Text(runner.setupMessage ?? host.status)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.opacity(0.75))
                    .lineLimit(1)
                    .padding(.horizontal, 30)

                // An escape hatch, but not an invitation: it turns up only once
                // waiting has stopped being novel.
                if now.timeIntervalSince(began) > 8 {
                    Button("تصفّح المكتبة أثناء التشغيل", action: onSkip)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 26)
        }
        .onReceive(tick) { now = $0 }
        .onReceive(rotate) { _ in
            withAnimation(.easeInOut(duration: 0.45)) { phrase += 1 }
        }
        .animation(.easeInOut(duration: 0.3), value: now.timeIntervalSince(began) > 8)
    }

    private var progress: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceHigh)
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * fraction)
                        .animation(.easeOut(duration: 0.25), value: fraction)
                }
            }
            .frame(height: 5)

            HStack {
                Text(shown > 0 ? "\(shown)%" : "جارٍ البدء")
                    .font(.technical(12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Spacer()
                if let left = remaining {
                    Text(left)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    private var fraction: CGFloat {
        CGFloat(shown) / 100
    }

    /// Only observed boot milestones, never fabricated time-based progress.
    private var shown: Int {
        max(0, min(runner.bootProgress, 100))
    }

    /// Elapsed time, not an unverified promise about how long is left.
    private var remaining: String? {
        let elapsed = max(0, Int(now.timeIntervalSince(began)))
        return elapsed < 60 ? "\(elapsed) ثانية" : "\(elapsed / 60) دقيقة"
    }
}
