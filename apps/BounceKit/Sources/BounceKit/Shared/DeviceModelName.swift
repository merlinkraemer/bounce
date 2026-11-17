import Foundation

/// Default device name for iOS, where `UIDevice.current.name` is only the
/// generic model word ("iPhone") without the user-assigned-device-name entitlement.
public enum DeviceModelName {
    static let marketingNames: [String: String] = [
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
    ]

    /// Marketing name for a hardware identifier; "iPhone" / "iPad" when unknown.
    public static func marketingName(forMachine machine: String) -> String {
        if let name = marketingNames[machine] { return name }
        return machine.hasPrefix("iPad") ? "iPad" : "iPhone"
    }

    /// True for the generic model words iOS returns without the entitlement.
    static func isGeneric(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n.isEmpty || n == "iphone" || n == "ipad" || n == "ipod touch"
    }

    /// Fallback order: user-set name, a non-generic system name, model marketing name.
    public static func resolve(custom: String?, systemName: String, machine: String) -> String {
        if let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if !isGeneric(systemName) { return systemName }
        return marketingName(forMachine: machine)
    }

    /// Hardware identifier of this device (simulator: the simulated model).
    public static var currentMachine: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty {
            return sim
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Default name for this device, ignoring any user-set name (also the Settings placeholder).
    public static func current(systemName: String) -> String {
        resolve(custom: nil, systemName: systemName, machine: currentMachine)
    }
}
