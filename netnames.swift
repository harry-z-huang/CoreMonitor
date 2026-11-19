import Foundation
import SystemConfiguration
import CoreWLAN
import CoreLocation

/// Human-readable labels for BSD interface names: "Wi-Fi · MyNetwork (en0)", "USB … LAN (en7)".
/// macOS redacts the Wi-Fi SSID unless the app has Location Services permission, so we ask once.
final class NetNames: NSObject, CLLocationManagerDelegate {
    private let loc = CLLocationManager()
    private var ports: [String: String] = [:]
    private var portsAt = Date.distantPast

    override init() {
        super.init()
        loc.delegate = self
        if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
    }

    /// Labels are cached for 10 s: asking CoreWLAN for the SSID on every 1 s tick cost noticeable main-thread time.
    private var cache: [String: (String, Date)] = [:]
    func label(_ bsd: String) -> String {
        if let c = cache[bsd], Date().timeIntervalSince(c.1) < 10 { return c.0 }
        let l = makeLabel(bsd); cache[bsd] = (l, Date()); return l
    }
    private func makeLabel(_ bsd: String) -> String {
        if Date().timeIntervalSince(portsAt) > 30 { refreshPorts() }
        var name = ports[bsd] ?? (bsd.hasPrefix("utun") ? "Tunnel / VPN" : bsd)
        if let wifi = CWWiFiClient.shared().interface(withName: bsd) {
            if let ssid = wifi.ssid() { name += " · \(ssid)" }
            else if wifi.powerOn() && loc.authorizationStatus != .authorizedAlways { name += " · (SSID needs Location access)" }
        }
        return "\(name) (\(bsd))"
    }

    private func refreshPorts() {
        portsAt = Date(); ports = [:]
        for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let b = SCNetworkInterfaceGetBSDName(i) as String?, let d = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? { ports[b] = d }
        }
    }
}
