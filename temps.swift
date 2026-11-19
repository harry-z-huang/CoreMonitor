import Foundation
import IOKit
import os

let cmLog = Logger(subsystem: "local.coremonitor", category: "temps")

// Chip die temperature via the IOHID temperature sensors that every Apple Silicon Mac exposes
// ("PMU tdie<n>"). These are spread across the die and aren't tied to specific cores, so we
// report the hottest one. Private API, but stable across M1-M4.
@_silgen_name("IOHIDEventSystemClientCreate") private func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func IOHIDEventSystemClientSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func IOHIDEventSystemClientCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private func IOHIDServiceClientCopyProperty(_ s: AnyObject, _ k: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func IOHIDServiceClientCopyEvent(_ s: AnyObject, _ t: Int64, _ o: Int32, _ f: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") private func IOHIDEventGetFloatValue(_ e: AnyObject, _ f: Int32) -> Double

final class ChipTemp {
    // Must outlive `services`: service clients hold an unretained back-pointer to the event
    // system client. Letting it die at the end of init caused use-after-free crashes in read().
    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var reads = 0
    init() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
            cmLog.error("IOHIDEventSystemClientCreate returned nil; chip temp unavailable"); return
        }
        self.client = client
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let all = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        services = all.filter {
            ((IOHIDServiceClientCopyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String) ?? "").hasPrefix("PMU tdie")
        }
        cmLog.info("ChipTemp init: \(all.count) HID services, \(self.services.count) PMU tdie sensors")
    }
    /// Hottest die sensor in °C, or nil if unavailable.
    func read() -> Double? {
        let vals = services.compactMap { s -> Double? in
            guard let e = IOHIDServiceClientCopyEvent(s, 15, 0, 0)?.takeRetainedValue() else { return nil }
            let v = IOHIDEventGetFloatValue(e, 15 << 16)
            return (v > 0 && v < 150) ? v : nil
        }
        reads += 1
        if vals.isEmpty { cmLog.warning("read #\(self.reads): no valid sensor values") }
        else if reads % 60 == 0 { cmLog.debug("read #\(self.reads): max \(vals.max()!, format: .fixed(precision: 1)) C") }
        return vals.max()
    }
}
