import Foundation
import CoreWLAN

// ─────────────────────────────────────────────────────────────────
// Connection facts for the network hover panel: Wi-Fi network name,
// local IPv4/IPv6 addresses, and the public IP.
//
// Wi-Fi name: CoreWLAN first; on modern macOS the SSID there is
// location-gated (returns nil without location permission), so fall
// back to `ipconfig getsummary`, which still reports it.
//
// Public IP: one HTTPS request to api.ipify.org, cached for 10
// minutes, and only ever made while the panel is open. This is the
// app's only network request — and the "Fetch public IP" switch in
// Settings turns it off entirely.
// ─────────────────────────────────────────────────────────────────

final class NetworkInfoReader {

    private var cachedPublicIP: String?
    private var publicIPFetchedAt = Date.distantPast

    func readInfo() -> NetworkInfo {
        var info = NetworkInfo()

        let wifiInterface = CWWiFiClient.shared().interface()
        info.wifiName = wifiInterface?.ssid()
        if info.wifiName == nil, let interfaceName = wifiInterface?.interfaceName {
            info.wifiName = Self.ssidFromIpconfig(interface: interfaceName)
        }

        (info.localIPv4, info.localIPv6) = Self.localAddresses()
        if UserDefaults.standard.object(forKey: "fetchPublicIP") as? Bool ?? true {
            info.publicIP = publicIP()
        } else {
            // Privacy switch is off: never fetch, and drop what was
            // cached so re-enabling starts fresh.
            cachedPublicIP = nil
            publicIPFetchedAt = .distantPast
        }
        return info
    }

    // MARK: Wi-Fi name

    private static func ssidFromIpconfig(interface: String) -> String? {
        let output = Subprocess.run("/usr/sbin/ipconfig", ["getsummary", interface])
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SSID : ") {
                return String(trimmed.dropFirst("SSID : ".count))
            }
        }
        return nil
    }

    // MARK: Local addresses

    private static func localAddresses() -> (v4: [String], v6: [String]) {
        var v4: [String] = []
        var v6: [String] = []
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0 else { return ([], []) }
        defer { freeifaddrs(addressList) }

        var pointer = addressList
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let entry = current.pointee
            guard let address = entry.ifa_addr else { continue }
            // "en*" = real network hardware (Wi-Fi, Ethernet, ...).
            guard String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }

            var text = String(cString: host)
            if family == UInt8(AF_INET) {
                v4.append(text)
            } else {
                // Strip the "%en0" scope suffix from link-local addresses.
                if let percent = text.firstIndex(of: "%") {
                    text = String(text[..<percent])
                }
                v6.append(text)
            }
        }
        return (v4, v6)
    }

    // MARK: Public IP

    private func publicIP() -> String? {
        if Date().timeIntervalSince(publicIPFetchedAt) < 600 { return cachedPublicIP }
        publicIPFetchedAt = Date()

        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 5

        // Blocking is fine here: readInfo() always runs on a utility task.
        let semaphore = DispatchSemaphore(value: 0)
        var fetched: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count < 64 {
                    fetched = trimmed
                }
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)

        if let fetched { cachedPublicIP = fetched }
        return cachedPublicIP
    }
}
