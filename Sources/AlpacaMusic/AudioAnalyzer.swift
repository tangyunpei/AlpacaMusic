import AVFoundation
import Foundation
import MediaToolbox
import QuartzCore
import Synchronization

/// The audio callback never creates Tasks or runs an FFT. It takes a try-lock,
/// copies PCM into preallocated storage, and immediately returns the source audio.
/// A utility queue transforms snapshots; all cross-thread state is mutex-protected.
final class AudioAnalyzer: @unchecked Sendable {
    private struct CaptureState {
        var samples = [Float](repeating: 0, count: 8192)
        var writeIndex = 0
        var count = 0
        var serial: UInt64 = 0
        var generation: UInt64 = 0
        var sampleRate: Double = 44100
        var format = AudioStreamBasicDescription()
        var lastInput: Double = 0
        mutating func clear() {
            writeIndex = 0; count = 0; lastInput = 0
            serial &+= 1; generation &+= 1
        }
    }
    private let capture = Mutex(CaptureState())
    private let published = Mutex(AudioLevels())
    private let worker = DispatchQueue(label: "dev.byalpaca.music.spectrum", qos: .utility)
    private let timer: DispatchSourceTimer
    private let bandAnalysis = AudioBandAnalysis()
    // Worker-queue-only state.
    private var workerGeneration: UInt64?
    private var lastSerial: UInt64 = 0
    private var lastAnalysis: Double = 0
    private var fast: Float = 0
    private var slow: Float = 0
    private var history: [(Double, Float)] = []
    private var lastBeat = -Double.infinity

    init() {
        timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.analyze() }
        timer.resume()
    }
    deinit { timer.cancel() }
    func levels() -> AudioLevels { published.withLock { $0 } }
    func reset() {
        capture.withLock { state in
            state.clear()
            published.withLock { $0 = AudioLevels() }
        }
    }
    fileprivate func prepare(_ format: AudioStreamBasicDescription) {
        capture.withLock { state in
            state.clear(); state.format = format; state.sampleRate = format.mSampleRate
            published.withLock { $0 = AudioLevels() }
        }
    }
    fileprivate func consume(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        _ = capture.withLockIfAvailable { state in
            let format = state.format
            guard format.mFormatID == kAudioFormatLinearPCM, Self.validSampleRate(format.mSampleRate),
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return }
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
            let bytes = Int(format.mBitsPerChannel / 8)
            guard (isFloat && (bytes == 4 || bytes == 8)) || (signed && (bytes == 2 || bytes == 4)) else { return }
            let now = CACurrentMediaTime()
            if state.lastInput > 0, now - state.lastInput >= 0.5 {
                state.clear(); published.withLock { $0 = AudioLevels() }
            }
            var copied = false
            for frame in 0..<frames {
                var sample: Float = 0
                var channels = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let channelCount = Int(buffer.mNumberChannels)
                    for channel in 0..<min(channelCount, 2) {
                        let offset = (frame * channelCount + channel) * bytes
                        guard offset + bytes <= Int(buffer.mDataByteSize) else { continue }
                        let value: Float
                        if isFloat && bytes == 4 { value = data.loadUnaligned(fromByteOffset: offset, as: Float.self) }
                        else if isFloat { value = Float(data.loadUnaligned(fromByteOffset: offset, as: Double.self)) }
                        else if bytes == 2 { value = Float(data.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32768 }
                        else { value = Float(data.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2147483648 }
                        // Invalid channel values occupy their original time position as silence.
                        // Clipping to PCM full scale also prevents accumulation from overflowing.
                        sample += Self.finitePCM(value); channels += 1
                    }
                }
                guard channels > 0 else { continue }
                state.samples[state.writeIndex] = sample / Float(channels)
                state.writeIndex = (state.writeIndex + 1) % state.samples.count
                state.count = min(state.samples.count, state.count + 1)
                copied = true
            }
            if copied { state.lastInput = now; state.serial &+= 1 }
        }
    }
    /// Test/import analysis entry point, also useful for decoded PCM from future providers.
    func ingest(samples: [Float], sampleRate: Double) {
        capture.withLock { state in
            guard Self.validSampleRate(sampleRate), !samples.isEmpty else {
                state.clear(); published.withLock { $0 = AudioLevels() }; return
            }
            let now = CACurrentMediaTime()
            if state.sampleRate != sampleRate || (state.lastInput > 0 && now - state.lastInput >= 0.5) {
                state.clear(); published.withLock { $0 = AudioLevels() }
            }
            state.sampleRate = sampleRate
            for value in samples { state.samples[state.writeIndex] = Self.finitePCM(value); state.writeIndex = (state.writeIndex + 1) % state.samples.count; state.count = min(state.samples.count, state.count + 1) }
            state.lastInput = now; state.serial &+= 1
        }
    }
    private static func finitePCM(_ value: Float) -> Float { value.isFinite ? min(1, max(-1, value)) : 0 }
    private static func validSampleRate(_ rate: Double) -> Bool { AudioBandAnalysis.isValidSampleRate(rate) }
    private func clearWorkerHistory() {
        lastSerial = 0; lastAnalysis = 0
        fast = 0; slow = 0; history.removeAll(keepingCapacity: true); lastBeat = -.infinity
    }
    private func analyze() {
        let now = CACurrentMediaTime()
        let snapshot = capture.withLock { state -> ([Float], Double, UInt64, UInt64)? in
            guard state.count >= 2048, now - state.lastInput < 0.5, Self.validSampleRate(state.sampleRate) else {
                if state.lastInput > 0, now - state.lastInput >= 0.5 { state.clear() }
                published.withLock { $0 = AudioLevels() }; return nil
            }
            // Retain up to 8192 samples for the band filters' actual PCM pre-roll.
            // The spectrum and all displayed traces still share the latest 2048-sample trigger.
            let count = min(8192, state.count)
            let start = (state.writeIndex + state.samples.count - count) % state.samples.count
            let samples = (0..<count).map { state.samples[(start + $0) % state.samples.count] }
            return (samples, state.sampleRate, state.serial, state.generation)
        }
        guard let (samples, sampleRate, serial, generation) = snapshot else {
            clearWorkerHistory(); return
        }
        if workerGeneration != generation { clearWorkerHistory(); workerGeneration = generation }
        guard serial != lastSerial else { return }
        lastSerial = serial
        let dt = lastAnalysis == 0 ? 0.033 : min(0.1, max(0, now - lastAnalysis)); lastAnalysis = now
        guard let analyzed = bandAnalysis.analyzeSnapshot(samples: samples, sampleRate: sampleRate) else { return }
        let amplitudes = analyzed.amplitudes
        let start = max(1, Int(ceil(20 * 2048 / sampleRate))), end = min(1023, max(start, Int(160 * 2048 / sampleRate)))
        let bass = start <= end ? min(1, amplitudes[start...end].reduce(0, +) * 1.5) : 0
        fast += (bass - fast) * Float(1 - exp(-dt / 0.05)); slow += (bass - slow) * Float(1 - exp(-dt / 0.3))
        history.removeAll { now - $0.0 > 0.7 }
        let mean = history.isEmpty ? fast : history.reduce(Float(0)) { $0 + $1.1 } / Float(history.count)
        if fast > max(0.035, mean * 1.3), fast > slow * 1.12, now - lastBeat > 0.25 { lastBeat = now }
        history.append((now, fast))
        var levels = analyzed.levels
        levels.energy = min(1, slow * 1.7)
        levels.beat = Float(max(0, 1 - (now - lastBeat) / 0.35))
        // Always acquire capture before published. A reset/prepare that wins this lock
        // invalidates this snapshot, so an in-flight transform cannot revive old PCM.
        capture.withLock { state in
            guard state.generation == generation, state.count >= 2048, CACurrentMediaTime() - state.lastInput < 0.5 else { return }
            published.withLock { $0 = levels }
        }
    }
    @MainActor
    func audioMix(for asset: AVURLAsset) async throws -> AVAudioMix? {
        if try await asset.load(.hasProtectedContent) { return nil }
        let parameters: AVMutableAudioMixInputParameters
        if #available(macOS 27.0, *) {
            // The no-track initializer targets the new mixed-output track (ID 0).
            parameters = AVMutableAudioMixInputParameters()
        } else {
            // HLS has no stable AVAssetTrack for a tap before macOS 27.
            guard asset.url.pathExtension.lowercased() != "m3u8",
                  let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
            parameters = AVMutableAudioMixInputParameters(track: track)
        }
        parameters.audioTapProcessor = try makeTap()
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
        return mix
    }
    private func makeTap() throws -> MTAudioProcessingTap {
        let retained = Unmanaged.passRetained(self).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained,
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<AudioAnalyzer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in Unmanaged<AudioAnalyzer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee) },
            unprepare: { tap in Unmanaged<AudioAnalyzer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().reset() },
            process: { tap, count, _, list, countOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, count, list, flagsOut, nil, countOut)
                guard status == noErr else { countOut.pointee = 0; return }
                Unmanaged<AudioAnalyzer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().consume(list, frames: countOut.pointee)
            })
        var tap: MTAudioProcessingTap?
        let status: OSStatus
        if #available(macOS 27.0, *) {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)
            status = MTAudioProcessingTapCreateWithPreferredFormat(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, format?.formatDescription, &tap)
        } else {
            status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        }
        guard status == noErr, let tap else { Unmanaged<AudioAnalyzer>.fromOpaque(retained).release(); throw MusicError.message(L10n.string("无法建立音频分析通道（\(String(status))）。")) }
        return tap
    }
}
