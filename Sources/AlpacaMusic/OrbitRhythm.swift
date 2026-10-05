import Foundation

/// Measured motion for particle orbits and silk ribbons, in bass / mid / treble order.
/// Each channel comes from that band's signed PCM; player scalar levels are ignored.
struct OrbitRhythmFrame: Equatable, Sendable {
    var energy: SIMD3<Float>
    var pulse: SIMD3<Float>

    static let zero = OrbitRhythmFrame(energy: .zero, pulse: .zero)
}

/// Runs on the visual clock, never in the realtime audio callback.
/// The adaptive floor detects a level change; it does not normalize loudness or infer tempo.
struct OrbitRhythmClock: Sendable {
    private struct Strike: Sendable {
        var age: Double
        var strength: Double

        var value: Double {
            guard age >= 0, age < 0.60 else { return 0 }
            // A soft 30–40 ms opening, followed by a complete, monotonic release.
            let opening = 1 - exp(-age / 0.015)
            let release = exp(-age / 0.19)
            let progress = min(1, max(0, (age - 0.38) / 0.22))
            let taper = 1 - progress * progress * (3 - 2 * progress)
            return min(1, opening * release * 1.328 * taper) * strength
        }
    }

    private struct Band: Sendable {
        var hasInput = false
        var sampleCount = 0
        var fastRMS = 0.0
        var floor = 0.0
        var lastRMS = 0.0
        var energy = 0.0
        var cooldown = 0.0
        var armed = true
        var strikes: [Strike] = []

        mutating func seed(_ rms: Double, sampleCount: Int, preserveRelease: Bool = false) {
            self.sampleCount = sampleCount
            hasInput = true
            fastRMS = rms
            floor = rms
            lastRMS = rms
            energy = Self.visibleEnergy(rms)
            cooldown = 0
            armed = true
            if !preserveRelease { strikes.removeAll(keepingCapacity: true) }
        }

        mutating func step(dt: Double, rms: Double?, sampleCount: Int) -> (Float, Float) {
            for index in strikes.indices { strikes[index].age += dt }
            strikes.removeAll { $0.age >= 0.60 }
            cooldown = max(0, cooldown - dt)

            if let rms {
                guard hasInput, self.sampleCount == sampleCount else {
                    seed(rms, sampleCount: sampleCount, preserveRelease: !hasInput)
                    return (Float(energy), Float(pulse))
                }

                let previousFast = fastRMS
                let fastTime = rms > fastRMS ? 0.025 : 0.090
                fastRMS += (rms - fastRMS) * (1 - exp(-dt / fastTime))
                let riseRate = max(0, fastRMS - previousFast) / max(dt, 0.000_001)
                let minimumRise = max(0.075, fastRMS * 1.3)

                // An actual fall, quiet interval, or settled level rearms the next strike.
                // A long continuous rise cannot retrigger merely when its cooldown ends.
                if rms < lastRMS - max(0.003, lastRMS * 0.12)
                    || fastRMS <= floor * 1.15 + 0.002
                    || riseRate < minimumRise * 0.15 {
                    armed = true
                }

                if armed, cooldown == 0, fastRMS > 0.006,
                   fastRMS > floor * 1.38 + 0.004, riseRate > minimumRise {
                    let contrast = max(0, min(1, (fastRMS - floor) / (fastRMS + 0.012)))
                    // The PCM block sets strike strength at a fixed gain. Using the
                    // partially integrated detector here would weaken higher frame rates.
                    let strength = min(1, pow(rms * 3.4, 0.62) * (0.55 + contrast * 0.45))
                    // The change arrived within this display interval. Midpoint placement
                    // avoids a one-frame dead period without adding a frame-rate timer.
                    strikes.append(Strike(age: dt * 0.5, strength: strength))
                    cooldown = 0.12
                    armed = false
                }

                let floorTime = fastRMS > floor ? 0.32 : 0.25
                floor += (fastRMS - floor) * (1 - exp(-dt / floorTime))
                lastRMS = rms
                let target = Self.visibleEnergy(fastRMS)
                let energyTime = target > energy ? 0.027 : 0.16
                energy += (target - energy) * (1 - exp(-dt / energyTime))
            } else {
                // A dropped input releases existing measured motion. Reconnection seeds
                // the new sample and never turns its first block into an invented beat.
                hasInput = false
                self.sampleCount = 0
                energy *= exp(-dt / 0.16)
                fastRMS *= exp(-dt / 0.090)
                floor *= exp(-dt / 0.25)
                lastRMS = 0
                armed = true
            }

            // Overlapping hits complete independently. Saturation combines them smoothly
            // instead of replacing a still-visible release with a new zero-age attack.
            return (Float(min(1, max(0, energy))), Float(pulse))
        }

        private var pulse: Double {
            let remaining = strikes.reduce(1.0) { $0 * (1 - $1.value) }
            return min(1, max(0, 1 - remaining))
        }

        private static func visibleEnergy(_ rms: Double) -> Double {
            // Fixed gain, not automatic gain: quieter tracks keep a quieter field.
            min(1, pow(max(0, rms) * 2.5, 0.8))
        }
    }

    private var bands = [Band(), Band(), Band()]
    private var sampleRate: Double?

    mutating func reset() {
        bands = [Band(), Band(), Band()]
        sampleRate = nil
    }

    mutating func step(dt: Double, levels: AudioLevels, resetInput: Bool = false) -> OrbitRhythmFrame {
        let duration = dt.isFinite && dt > 0 ? dt : 0
        let samples = [levels.bassWaveform, levels.midWaveform, levels.trebleWaveform]
        let hasPCM = levels.available && samples.contains { !$0.isEmpty }
        let rate = levels.sampleRate.isFinite && levels.sampleRate > 0 ? levels.sampleRate : 0
        let formatChanged = hasPCM && sampleRate != nil && sampleRate != rate
        let discontinuity = resetInput || (duration == 0 && hasPCM) || duration > 0.25 || formatChanged
        if discontinuity { reset() }
        // Missing input has no new format: retain the previous rate while its measured
        // pulse releases instead of mistaking the empty metadata for a format reset.
        if hasPCM { sampleRate = rate }

        var result = OrbitRhythmFrame.zero
        for band in 0..<3 {
            let rms = levels.available ? Self.rms(samples[band]) : nil
            if discontinuity, let rms {
                bands[band].seed(rms, sampleCount: samples[band].count)
                result.energy[band] = Float(bands[band].energy)
            } else {
                let frame = bands[band].step(dt: duration, rms: rms, sampleCount: samples[band].count)
                result.energy[band] = frame.0
                result.pulse[band] = frame.1
            }
        }
        return result
    }

    private static func rms(_ samples: [Float]) -> Double? {
        guard !samples.isEmpty else { return nil }
        var squareSum = 0.0
        for sample in samples {
            let value = sample.isFinite ? Double(min(1, max(-1, sample))) : 0
            squareSum += value * value
        }
        return sqrt(squareSum / Double(samples.count))
    }
}
