// SPDX-License-Identifier: GPL-2.0-or-later
import AVFoundation

/// Plays what the guest produces.
///
/// The division of labour matches the display path: QEMU's audio backend
/// (husk-audio.c) puts PCM into a ring, and this takes it out on Core Audio's
/// own render thread. Neither side ever waits for the other, which is the whole
/// point — QEMU's audio thread holds the BQL and must not block on Core Audio,
/// and a render callback that blocks on the BQL would drop the entire output
/// stream, not just a frame.
///
/// Fixed at 48 kHz interleaved 16-bit stereo, because the backend declares that
/// format and QEMU's mixeng converts whatever the guest actually plays.
///
/// Deep improvements:
/// - Observe audio session interruptions (calls, Siri) and resume cleanly.
/// - Observe media services reset and rebuild the engine.
/// - Prefer speaker output when no headphones are connected.
@MainActor
final class HuskAudio {
    static let shared = HuskAudio()

    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private(set) var running = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers])
            try session.setPreferredSampleRate(Double(HUSK_AUDIO_RATE))
            try? session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
        } catch {
            HuskLog.log("audio", "could not start the audio session: \(error.localizedDescription)")
            return
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: Double(HUSK_AUDIO_RATE),
                                   channels: AVAudioChannelCount(HUSK_AUDIO_CHANNELS),
                                   interleaved: true)
        guard let format else {
            HuskLog.log("audio", "could not describe the guest's audio format")
            return
        }

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let out = buffers.first?.mData else { return noErr }
            husk_audio_pull(out.assumingMemoryBound(to: Int16.self), Int32(frameCount))
            return noErr
        }

        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            HuskLog.log("audio", "could not start the audio engine: \(error.localizedDescription)")
            return
        }

        self.engine = engine
        self.source = node
        running = true
        installSessionObservers()
        HuskLog.log("audio", "playing at \(HUSK_AUDIO_RATE) Hz, "
                           + "\(HUSK_AUDIO_CHANNELS) channels")
    }

    func stop() {
        removeSessionObservers()
        engine?.stop()
        engine = nil
        source = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    nonisolated var summary: String {
        "\(husk_audio_frames_in()) frames in, \(husk_audio_underruns()) silent"
    }

    private func installSessionObservers() {
        removeSessionObservers()
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })

        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                HuskLog.log("audio", "media services reset — rebuilding engine")
                self?.stop()
                self?.start()
            }
        })

        observers.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            HuskLog.log("audio", "route changed")
        })
    }

    private func removeSessionObservers() {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            HuskLog.log("audio", "interruption began — pausing engine")
            engine?.pause()
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume) {
                HuskLog.log("audio", "interruption ended — resuming")
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try engine?.start()
                } catch {
                    HuskLog.log("audio", "resume failed: \(error.localizedDescription)")
                }
            }
        @unknown default:
            break
        }
    }
}
