import Foundation
import IOKit.ps

public enum BatteryMonitor {
    public static func snapshot() -> BatterySnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .pluggedIn
        }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else {
            return .pluggedIn
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let state = (description[kIOPSPowerSourceStateKey] as? String) ?? ""
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let max = description[kIOPSMaxCapacityKey] as? Int
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let percent: Double?
            if let current, let max, max > 0 {
                percent = Double(current) / Double(max) * 100
            } else {
                percent = nil
            }
            let onBattery = state == kIOPSBatteryPowerValue
            return BatterySnapshot(onBattery: onBattery, percent: percent, charging: charging || !onBattery)
        }
        return .pluggedIn
    }
}
