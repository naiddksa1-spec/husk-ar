// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import UIKit

/// Cross-cutting performance helpers: smoothed FPS, memory-pressure signals,
/// and a single place to log headroom before large allocations.
///
/// Used by the Metal presenter path and QEMU memory watch so decisions about
/// dropping quality or refusing to start live in one module.
enum HuskPerformance {

    // MARK: - Smoothed FPS (exponential moving average)

    private static let fpsLock = NSLock()
    private static var emaFPS: Double = 0
    private static var lastFrameTime: CFTimeInterval = 0
    private static let alpha = 0.12  // higher = more reactive

    /// Call once per presented frame (from the present path).
    static func noteFrame() {
        let now = CACurrentMediaTime()
        fpsLock.lock()
        defer { fpsLock.unlock() }
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0, dt < 1.0 {
                let instant = 1.0 / dt
                emaFPS = emaFPS == 0 ? instant : (alpha * instant + (1 - alpha) * emaFPS)
            }
        }
        lastFrameTime = now
    }

    static var smoothedFPS: Double {
        fpsLock.lock()
        defer { fpsLock.unlock() }
        return emaFPS
    }

    // MARK: - Memory headroom

    /// MiB the process may still allocate before jetsam.
    static var availableMiB: Int {
        Int(husk_ios_available_memory() / (1024 * 1024))
    }

    /// True when free headroom is dangerously low for a multi-GB guest.
    static var isUnderMemoryPressure: Bool {
        availableMiB < 256
    }

    /// Log a tagged footprint line (phys + available-before-jetsam).
    static func logFootprint(_ tag: String) {
        husk_ios_jit_log_footprint(tag)
    }

    // MARK: - Thermal / low-power awareness

    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// Human-readable one-liner for the settings / debug UI.
    static var summaryLine: String {
        let fps = String(format: "%.1f", smoothedFPS)
        return "FPS \(fps) · \(availableMiB) MiB free · thermal \(thermalLabel) · LPM \(isLowPowerMode ? "on" : "off")"
    }

    private static var thermalLabel: String {
        switch thermalState {
        case .nominal: return "ok"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }
}
