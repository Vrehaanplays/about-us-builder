import Foundation
import PersonalAICore

/// Thread-safe snapshot of "may we do background work right now?". The indexer polls it between small batches,
/// so generation, heat, Low Power Mode and the app being in the background all pause indexing within ~one batch.
final class WorkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generating = false, foreground = true, charging = false, onlyCharging = true
    func update(generating: Bool? = nil, foreground: Bool? = nil, charging: Bool? = nil, onlyCharging: Bool? = nil) {
        lock.withLock {
            if let g = generating { self.generating = g }
            if let f = foreground { self.foreground = f }
            if let c = charging { self.charging = c }
            if let o = onlyCharging { self.onlyCharging = o }
        }
    }
    func level() -> WorkLevel {
        let s = lock.withLock { (generating, foreground, charging, onlyCharging) }
        if s.0 { return .none }
        let thermal = DeviceInfo.thermal
        if thermal == .serious || thermal == .critical { return .none }
        if DeviceInfo.lowPowerMode { return .light }
        if thermal == .fair { return .light }
        if s.3 && !s.2 { return .light }              // on battery: bookkeeping only unless the user allowed battery indexing
        return s.1 || s.2 ? .full : .light
    }
}

/// Lets synchronous planner callbacks read the currently loaded model's numbers.
final class ProfileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var profile = ModelProfile(id: "none", maxContext: 4096, weightsBytes: 1_500_000_000, kvBytesPerToken: 150_000)
    func set(_ p: ModelProfile) { lock.withLock { profile = p } }
    func get() -> ModelProfile { lock.withLock { profile } }
}
