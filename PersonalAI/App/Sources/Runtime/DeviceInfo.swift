import Foundation
import os
import UIKit
import PersonalAICore

/// Real numbers from the device. The planner uses these, the benchmark screen records them, and nothing here is estimated from a model name.
enum DeviceInfo {
    static var physicalMemoryBytes: Int { Int(ProcessInfo.processInfo.physicalMemory) }
    /// Headroom before iOS terminates this process. This, not physical RAM, bounds model + KV cache size.
    static var availableMemoryBytes: Int { Int(os_proc_available_memory()) }
    static var machine: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
    static var thermal: ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
    }
    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    @MainActor static var isCharging: Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }
    @MainActor static var batteryLevel: Float { UIDevice.current.isBatteryMonitoringEnabled = true; return UIDevice.current.batteryLevel }
    static var freeDiskBytes: Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }
    static var osVersion: String { UIDevice.current.systemVersion }
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    static func budget() -> DeviceBudget { DeviceBudget(availableMemoryBytes: availableMemoryBytes, thermal: thermal, lowPowerMode: lowPowerMode) }
}
