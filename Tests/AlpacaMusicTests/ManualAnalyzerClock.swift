import Foundation
import Synchronization
@testable import AlpacaMusic

/// A clock that moves only when a test advances it, so the analyzer's 500 ms
/// expiry is crossed exactly when the test says, never by scheduling delay.
final class ManualAnalyzerClock: Sendable {
    private let seconds = Mutex(1_000.0)

    var read: @Sendable () -> Double {
        { [self] in seconds.withLock { $0 } }
    }

    func advance(by delta: Double) {
        seconds.withLock { $0 += delta }
    }
}

extension AudioAnalyzer {
    /// An analyzer on `clock` that analyzes only when a test calls
    /// `analyzeNow()`; no worker timer runs in the background.
    static func manual(_ clock: ManualAnalyzerClock) -> AudioAnalyzer {
        AudioAnalyzer(clock: clock.read, analyzesOnTimer: false)
    }
}
