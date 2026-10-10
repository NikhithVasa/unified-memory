import Darwin
import Foundation
import IOKit
import IOKit.ps
import NativeHardware
import NativeTemperature

// Units come from the API or an exact published key mapping, never the first
// letter of a firmware key or a plausible-looking value.
enum HardwarePowerDecoder {
    struct Mapping: Sendable {
        let name: String
        let unit: String
        let category: HardwareSensorCategory
    }

    struct SMCChannel {
        let key: String
        let type: String
        let size: UInt32
        let mapping: Mapping?
        let name: String
        let detail: String

        init(key: String, type: String, size: UInt32) {
            self.key = key
            self.type = type
            self.size = size
            let mapping = HardwarePowerDecoder.mapping(key: key, type: type)
            self.mapping = mapping
            name = mapping.map { "\($0.name) (\(key))" } ?? "SMC \(key)"
            detail = "Firmware format \(type), \(size) bytes."
        }
    }

    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func fourCCString(_ code: UInt32) -> String {
        String(bytes: [UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16),
                       UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)], encoding: .ascii)
            ?? String(format: "%08X", code)
    }

    static func isSensorKey(_ key: String) -> Bool {
        key.utf8.count == 4 && key.utf8.first.map { [UInt8(84), 80, 86, 73, 70].contains($0) } == true
    }

    static func isNumericFormat(_ type: String, size: UInt32) -> Bool {
        switch type {
        case "flt ": return size == 4
        case "ui8 ", "si8 ", "flag": return size == 1
        case "ui16", "si16": return size == 2
        case "ui32", "si32": return size == 4
        default:
            let bytes = Array(type.utf8)
            guard size == 2, bytes.count == 4, bytes[0] == 102 || bytes[0] == 115, bytes[1] == 112,
                  let integral = Int(String(UnicodeScalar(bytes[2])), radix: 16),
                  let fractional = Int(String(UnicodeScalar(bytes[3])), radix: 16) else { return false }
            return integral + fractional == (bytes[0] == 115 ? 15 : 16)
        }
    }

    // Corroborated exact mappings, including fan Ac/Mn/Mx/Tg, in:
    // https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
    // https://github.com/exelban/stats/blob/master/Modules/Sensors/readers.swift
    static func mapping(key: String, type: String) -> Mapping? {
        guard type == "flt " || type.hasPrefix("fp") || type.hasPrefix("sp") else {
            if key == "FNum", type == "ui8 " { return Mapping(name: "Fan count", unit: "fans", category: .power) }
            return nil
        }
        let bytes = Array(key.utf8)
        if bytes.count == 4, bytes[0] == 70, let index = Int(String(UnicodeScalar(bytes[1])), radix: 16) {
            let suffix = String(bytes: bytes[2...3], encoding: .ascii)
            let label: String?
            switch suffix {
            case "Ac": label = "actual speed"
            case "Mn": label = "minimum speed"
            case "Mx": label = "maximum speed"
            case "Tg": label = "target speed"
            default: label = nil
            }
            if let label { return Mapping(name: "Fan \(index + 1) \(label)", unit: "RPM", category: .power) }
        }
        switch key {
        case "PSTR": return Mapping(name: "System total power", unit: "W", category: .power)
        case "PPBR": return Mapping(name: "Battery power (SMC)", unit: "W", category: .power)
        case "PDTR": return Mapping(name: "DC input power", unit: "W", category: .power)
        case "PMTR": return Mapping(name: "Memory total power", unit: "W", category: .power)
        case "PDBR": return Mapping(name: "Display power delivery", unit: "W", category: .power)
        case "PBwo": return Mapping(name: "Display backlight power", unit: "W", category: .power)
        case "VD0R": return Mapping(name: "DC input voltage", unit: "V", category: .power)
        case "ID0R": return Mapping(name: "DC input current", unit: "A", category: .power)
        case "IBAC": return Mapping(name: "Battery current (SMC)", unit: "A", category: .power)
        default: return nil
        }
    }

    static func smcReading(key: String, type: String, size: UInt32, value: Double?, failure: String? = nil,
                           timestamp: Date = Date(), metadata: [String: String] = [:]) -> HardwareSensorReading {
        smcReading(channel: SMCChannel(key: key, type: type, size: size), value: value, failure: failure,
                   timestamp: timestamp, metadata: metadata)
    }

    static func smcReading(channel: SMCChannel, value: Double?, failure: String? = nil,
                           timestamp: Date = Date(), metadata: [String: String] = [:]) -> HardwareSensorReading {
        let key = channel.key
        let mapping = channel.mapping
        let name = channel.name
        let detail = channel.detail
        if let failure {
            return HardwareSensorReading(id: "smc:\(key)", name: name, category: mapping?.category ?? .diagnostics,
                                         unit: mapping?.unit ?? "raw", status: .unavailable(failure), source: "AppleSMC",
                                         detail: detail, timestamp: timestamp, metadata: metadata)
        }
        guard let value, value.isFinite else {
            return HardwareSensorReading(id: "smc:\(key)", name: name, category: mapping?.category ?? .diagnostics,
                                         unit: "raw", status: .unavailable("Numeric decoder rejected the length, format or nonfinite value."),
                                         source: "AppleSMC", detail: detail, timestamp: timestamp, metadata: metadata)
        }
        if let mapping, value >= 0 || key == "IBAC" {
            return HardwareSensorReading(id: "smc:\(key)", name: name, category: mapping.category, value: value,
                                         unit: mapping.unit, source: "AppleSMC", detail: detail,
                                         timestamp: timestamp, metadata: metadata)
        }
        return HardwareSensorReading(id: "smc:\(key)", name: name, category: .diagnostics, value: value, unit: "raw",
                                     status: .unclassified(mapping == nil
                                        ? "Numeric firmware channel; physical meaning and units are not established."
                                        : "Negative value is not a valid measurement for this mapped channel; retained as raw."),
                                     source: "AppleSMC", detail: detail, timestamp: timestamp, metadata: metadata)
    }

    static func hidReading(id: String, name: String, value: Double?, measurementType: Int64?, subtype: Int64?,
                           timestamp: Date = Date(), metadata: [String: String] = [:]) -> HardwareSensorReading {
        let kind: String
        switch measurementType {
        case 0: kind = "power"
        case 1: kind = "current"
        case 2: kind = "voltage"
        default: kind = "electrical"
        }
        let detail = "IOHID power event 25; type \(measurementType.map(String.init) ?? "unavailable"), subtype \(subtype.map(String.init) ?? "unavailable")."
        guard let value, value.isFinite else {
            return HardwareSensorReading(id: id, name: name, category: .diagnostics, unit: "raw",
                                         status: .unavailable("Power event unavailable, denied, unsupported, or nonfinite; the service remains detected."),
                                         source: "IOHIDEvent / AppleARMPMUPowerSensor", detail: detail,
                                         timestamp: timestamp, metadata: metadata)
        }
        return HardwareSensorReading(id: id, name: name, category: .diagnostics, value: value, unit: "raw",
                                     status: .unclassified("Event identifies \(kind), but the native driver exposes no established unit scale\(subtype == 1 ? "; cumulative subtype is not an instantaneous measurement" : "")."),
                                     source: "IOHIDEvent / AppleARMPMUPowerSensor", detail: detail,
                                     timestamp: timestamp, metadata: metadata)
    }

    static func number(_ object: Any?) -> Double? {
        guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        let type = String(cString: number.objCType)
        return type == "f" || type == "d" || abs(value) <= 9_007_199_254_740_991 ? value : nil
    }

    static func exactIntegerText(_ object: Any?) -> String? {
        guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard type != "f", type != "d", abs(number.doubleValue) > 9_007_199_254_740_991 else { return nil }
        return number.stringValue
    }

    static func boolean(_ object: Any?) -> Bool? {
        guard let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func percentage(current: Double?, maximum: Double?) -> Double? {
        guard let current, let maximum, current.isFinite, maximum.isFinite, current >= 0, maximum > 0 else { return nil }
        let percentage = current / maximum * 100
        return percentage.isFinite ? percentage : nil
    }

    // macOS AppleSmartBattery retains Smart Battery deciKelvin, not centi°C:
    // https://github.com/apple-oss-distributions/PowerManagement/blob/main/AppleSmartBatteryManager/AppleSmartBattery.cpp#L1514
    static func batteryCelsius(deciKelvin: Double?) -> Double? {
        guard let deciKelvin, deciKelvin.isFinite, deciKelvin > 0, deciKelvin < 65_535 else { return nil }
        return deciKelvin / 10 - 273.15
    }

    static func batteryReadings(properties: [String: Any], unavailableReason: String? = nil,
                                timestamp: Date = Date(), id: String = "battery:internal") -> [HardwareSensorReading] {
        var result: [HardwareSensorReading] = []
        result.reserveCapacity(batteryFields.count + batteryBooleans.count + 5)
        let installed = boolean(properties["BatteryInstalled"])
        let absence = unavailableReason ?? (installed == false ? "BatteryInstalled is false; battery measurement is unavailable." : nil)
        for field in batteryFields {
            let raw = number(properties[field.key])
            var value = raw.map { $0 * field.scale }
            var reason = absence
            if field.key == "Temperature" { value = batteryCelsius(deciKelvin: raw) }
            if field.nonnegative, let candidate = value, candidate < 0 { value = nil }
            if field.key == "TimeRemaining", raw == 65_535 { value = nil }
            if value == nil { reason = reason ?? "\(field.key) is absent, invalid, or not a finite numeric property." }
            result.append(HardwareSensorReading(id: "\(id):\(field.key)", name: field.name, category: .battery,
                                                value: reason == nil ? value : nil, unit: field.unit,
                                                status: reason.map(HardwareSensorStatus.unavailable) ?? .available,
                                                source: "AppleSmartBattery", detail: field.detail,
                                                timestamp: timestamp, metadata: ["property": field.key]))
        }
        for field in batteryBooleans {
            let value = boolean(properties[field.key])
            let reason = unavailableReason ?? (value == nil ? "\(field.key) is absent or is not a Boolean property." : nil)
            result.append(HardwareSensorReading(id: "\(id):\(field.key)", name: field.name, category: .battery,
                                                textValue: reason == nil ? value.map { $0 ? "Yes" : "No" } : nil,
                                                status: reason.map(HardwareSensorStatus.unavailable) ?? .available,
                                                source: "AppleSmartBattery", timestamp: timestamp, metadata: ["property": field.key]))
        }
        let charge = percentage(current: number(properties["AppleRawCurrentCapacity"]), maximum: number(properties["AppleRawMaxCapacity"]))
        let health = percentage(current: number(properties["AppleRawMaxCapacity"]), maximum: number(properties["DesignCapacity"]))
        for (suffix, name, value, detail) in [
            ("raw-charge-percent", "Raw battery charge", charge, "AppleRawCurrentCapacity / AppleRawMaxCapacity × 100; separate from the OS normalized charge."),
            ("capacity-health", "Full-charge / design capacity", health, "AppleRawMaxCapacity / DesignCapacity × 100; may legitimately exceed 100%. Not the normalized MaxCapacity.")
        ] {
            let reason = absence ?? (value == nil ? "Required matching mAh capacity properties are absent or invalid." : nil)
            result.append(HardwareSensorReading(id: "\(id):\(suffix)", name: name, category: .battery,
                                                value: reason == nil ? value : nil, unit: "%",
                                                status: reason.map(HardwareSensorStatus.unavailable) ?? .available,
                                                source: "AppleSmartBattery (derived)", detail: detail, timestamp: timestamp))
        }
        for key in rawBatteryKeys {
            let value = number(properties[key])
            result.append(HardwareSensorReading(id: "\(id):\(key)", name: "Battery \(key)", category: .diagnostics,
                                                value: absence == nil ? value : nil, unit: "raw",
                                                status: absence.map(HardwareSensorStatus.unavailable)
                                                    ?? (value == nil ? .unavailable("Property is not a finite scalar.") : .unclassified("Battery status or virtual channel; no physical sensor/unit interpretation applied.")),
                                                source: "AppleSmartBattery", timestamp: timestamp, metadata: ["property": key]))
        }
        let condition = properties["ErrorCondition"] as? String
        result.append(HardwareSensorReading(id: "\(id):ErrorCondition", name: "Battery error condition", category: .battery,
                                            textValue: condition.map { $0.isEmpty ? "None reported" : $0 },
                                            status: unavailableReason.map(HardwareSensorStatus.unavailable)
                                                ?? (condition == nil ? .unavailable("No ErrorCondition property is published.") : .available),
                                            source: "AppleSmartBattery", timestamp: timestamp))
        return result
    }

    private struct BatteryField {
        let key: String
        let name: String
        let unit: String
        var scale: Double = 1
        var nonnegative: Bool = true
        var detail: String = ""
    }

    // IOPMPowerSource documents mA, mV and cycles. The Apple raw/nominal
    // capacities are mAh; normalized CurrentCapacity/MaxCapacity are NOT used
    // as mAh on Apple Silicon. IOPS supplies normalized percentage separately.
    private static let batteryFields: [BatteryField] = [
        .init(key: "Voltage", name: "Battery voltage", unit: "V", scale: 0.001),
        .init(key: "Amperage", name: "Battery average current", unit: "A", scale: 0.001, nonnegative: false, detail: "Signed current; negative indicates discharging."),
        .init(key: "InstantAmperage", name: "Battery instantaneous current", unit: "A", scale: 0.001, nonnegative: false),
        .init(key: "AppleRawCurrentCapacity", name: "Battery remaining charge", unit: "mAh"),
        .init(key: "AppleRawMaxCapacity", name: "Battery full-charge capacity", unit: "mAh"),
        .init(key: "NominalChargeCapacity", name: "Battery nominal charge capacity", unit: "mAh"),
        .init(key: "DesignCapacity", name: "Battery design capacity", unit: "mAh"),
        .init(key: "CycleCount", name: "Battery cycle count", unit: "cycles"),
        .init(key: "DesignCycleCount9C", name: "Battery design cycle count", unit: "cycles"),
        .init(key: "Temperature", name: "Battery temperature", unit: "°C", nonnegative: false, detail: "Smart Battery deciKelvin / 10 − 273.15."),
        .init(key: "TimeRemaining", name: "Battery time remaining estimate", unit: "min", detail: "Driver estimate, not a directly measured runtime.")
    ]
    private static let batteryBooleans: [(key: String, name: String)] = [
        ("BatteryInstalled", "Battery installed"), ("ExternalConnected", "AC power connected"),
        ("ExternalChargeCapable", "External power can charge"), ("IsCharging", "Battery charging"),
        ("FullyCharged", "Battery fully charged"), ("AtWarnLevel", "Battery warning level"),
        ("AtCriticalLevel", "Battery critical level")
    ]
    private static let rawBatteryKeys = ["CurrentCapacity", "MaxCapacity", "VirtualTemperature", "PermanentFailureStatus", "MaxErr", "BatteryCellDisconnectCount", "AppleRawBatteryVoltage"]
    static var batteryPropertyKeys: [String] {
        batteryFields.map(\.key) + batteryBooleans.map(\.key) + rawBatteryKeys + ["ErrorCondition"]
    }

    struct BatteryNestedDescriptor: Sendable {
        let dictionary: String
        let key: String
        let index: Int?

        var id: String { "battery:internal:\(dictionary):\(key)\(index.map { ":\($0)" } ?? "")" }
    }

    // Only telemetry/status allowlists are inspected. Authentication, serial,
    // manufacturer, firmware strings and opaque byte payloads are never used.
    static func nestedBatteryDescriptors(_ dictionaries: [String: [String: Any]]) -> [BatteryNestedDescriptor] {
        var descriptors: [BatteryNestedDescriptor] = []
        for (dictionary, keys) in nestedBatteryKeys {
            guard let properties = dictionaries[dictionary] else { continue }
            for key in keys where properties[key] != nil {
                if let values = properties[key] as? [Any] {
                    for index in values.indices {
                        descriptors.append(.init(dictionary: dictionary, key: key, index: index))
                    }
                } else {
                    descriptors.append(.init(dictionary: dictionary, key: key, index: nil))
                }
            }
        }
        return descriptors
    }

    static func nestedBatteryReading(_ descriptor: BatteryNestedDescriptor, dictionaries: [String: [String: Any]],
                                     unavailableReason: String? = nil, timestamp: Date = Date()) -> HardwareSensorReading {
        var object = dictionaries[descriptor.dictionary]?[descriptor.key]
        if let index = descriptor.index {
            if let array = object as? [Any], array.indices.contains(index) { object = array[index] }
            else { object = nil }
        }
        let raw = number(object)
        let cellVoltage = descriptor.dictionary == "BatteryData" && descriptor.key == "CellVoltage"
        let unit = cellVoltage ? "V" : "raw"
        let exactText = cellVoltage ? nil : exactIntegerText(object)
        let reason = unavailableReason ?? (raw == nil && exactText == nil ? "Previously detected battery telemetry is absent or not a finite numeric scalar." : nil)
        let name = cellVoltage ? "Battery cell \((descriptor.index ?? 0) + 1) voltage"
            : "\(descriptor.dictionary) \(descriptor.key)\(descriptor.index.map { " [\($0)]" } ?? "")"
        return HardwareSensorReading(id: descriptor.id, name: name, category: cellVoltage ? .battery : .diagnostics,
                                     value: reason == nil ? raw.map { cellVoltage ? $0 / 1000 : $0 } : nil, unit: unit,
                                     textValue: reason == nil ? exactText : nil,
                                     status: reason.map(HardwareSensorStatus.unavailable)
                                        ?? (cellVoltage ? .available : .unclassified("Numeric battery/charger telemetry; physical meaning and unit scale are not established.")),
                                     source: "AppleSmartBattery", timestamp: timestamp,
                                     metadata: ["dictionary": descriptor.dictionary, "property": descriptor.key])
    }

    static let nestedBatteryKeys: [(String, [String])] = [
        ("BatteryData", ["AdapterPower", "BatteryHealthMetric", "BatteryRsenseOpenCount", "CellCurrentAccumulatorCount",
                         "ChargeAccum", "CurrentSenseMonitorStatus", "CycleCount", "DailyMaxSoc", "DailyMinSoc",
                         "DataFlashWriteCount", "DesignCapacity", "Dod0AtQualifiedQmax", "FccComp1", "FccComp2",
                         "FilteredCurrent", "Flags", "GaugeFlagRaw", "ISS", "ITMiscStatus", "MaxCapacity", "MiscStatus",
                         "PMUConfigured", "PackCurrentAccumulator", "PackCurrentAccumulatorCount", "PassedCharge",
                         "QmaxDisqualificationReason", "Qstart", "RSS", "ResScale", "SimRate", "Soc1Voltage",
                         "StateOfCharge", "SystemPower", "TrueRemainingCapacity", "Voltage", "CellCurrentAccumulator",
                         "CellVoltage", "CellWom", "DOD0", "PresentDOD", "Qmax", "WeightedRa"]
                         + (0...14).map { String(format: "Ra%02d", $0) }),
        ("ChargerData", ["ChargerID", "ChargerInhibitReason", "ChargerResetCounter", "ChargingCurrent", "ChargingVoltage",
                         "NotChargingReason", "SlowChargingReason", "TimeChargingThermallyLimited", "VacVoltageLimit"]),
        ("AdapterDetails", ["Watts", "Voltage", "Current"])
    ]
}

private struct PowerSMCDescriptor {
    let native: UMSMCValue
    let channel: HardwarePowerDecoder.SMCChannel
    let failure: String?
    let metadata: [String: String]
}

// The actor is the only user of the mutable native connection; destruction
// closes its port. Descriptors and metadata never change after discovery.
private final class PowerSMCConnection: @unchecked Sendable {
    let handle: OpaquePointer?
    let descriptors: [PowerSMCDescriptor]
    let discoveryFailures: [HardwareSensorReading]

    init() {
        var status: Int32 = 0
        handle = UMSMCClientCreate(&status)
        guard let handle else {
            descriptors = []
            discoveryFailures = [Self.failure(id: "smc:inventory", name: "SMC sensor inventory", reason: Self.reason(status, firmware: 0))]
            return
        }
        var count: UInt32 = 0
        let countStatus = UMSMCClientGetKeyCount(handle, &count)
        guard countStatus == 0 else {
            descriptors = []
            discoveryFailures = [Self.failure(id: "smc:inventory", name: "SMC sensor inventory", reason: Self.reason(countStatus, firmware: 0))]
            return
        }
        var found: [PowerSMCDescriptor] = []
        var failures: [HardwareSensorReading] = []
        var seen = Set<UInt32>()
        for index in 0..<count {
            var key: UInt32 = 0
            let indexStatus = UMSMCClientGetKeyAtIndex(handle, index, &key)
            guard indexStatus == 0 else {
                failures.append(Self.failure(id: "smc:inventory:\(index)", name: "SMC inventory slot \(index)", reason: Self.reason(indexStatus, firmware: 0)))
                continue
            }
            let text = HardwarePowerDecoder.fourCCString(key)
            guard HardwarePowerDecoder.isSensorKey(text), seen.insert(key).inserted else { continue }
            var native = UMSMCValue()
            let infoStatus = UMSMCClientGetKeyInfo(handle, key, &native)
            let type = HardwarePowerDecoder.fourCCString(native.dataType)
            let failure = infoStatus != 0 ? Self.reason(infoStatus, firmware: native.firmwareResult)
                : (!HardwarePowerDecoder.isNumericFormat(type, size: native.dataSize)
                    ? "Unsupported/non-scalar firmware format \(type), \(native.dataSize) bytes; payload is not read." : nil)
            found.append(PowerSMCDescriptor(native: native,
                                            channel: HardwarePowerDecoder.SMCChannel(key: text, type: type, size: native.dataSize),
                                            failure: failure,
                                            metadata: ["key": text, "format": type, "bytes": String(native.dataSize), "inventoryIndex": String(index)]))
        }
        descriptors = found
        discoveryFailures = failures
    }

    deinit { if let handle { UMSMCClientDestroy(handle) } }

    static func reason(_ status: Int32, firmware: UInt8) -> String {
        "Read-only SMC access failed (IOReturn \(String(format: "0x%08X", UInt32(bitPattern: status))), firmware result \(firmware)); unavailable or permission-blocked."
    }

    private static func failure(id: String, name: String, reason: String) -> HardwareSensorReading {
        HardwareSensorReading(id: id, name: name, category: .diagnostics, status: .unavailable(reason), source: "AppleSMC")
    }
}

private struct PowerHIDDescriptor {
    let index: Int
    let id: String
    let name: String
    let metadata: [String: String]
}

private final class PowerHIDConnection: @unchecked Sendable {
    let handle: OpaquePointer?
    let descriptors: [PowerHIDDescriptor]
    let failure: String?
    let measurementFields: [UInt32] = [25 << 16]
    let selectorFields: [UInt32] = [(25 << 16) + 1, (25 << 16) + 2]

    init() {
        var status: Int32 = 0
        handle = UMHIDSensorClientCreate(&status)
        guard let handle else {
            descriptors = []
            failure = "Built-in electrical HID sensor discovery unavailable (native status \(status))."
            return
        }
        var found: [PowerHIDDescriptor] = []
        for index in 0..<UMHIDSensorClientGetSensorCount(handle) {
            let page = UMHIDSensorClientGetUsagePage(handle, index)
            let usage = UMHIDSensorClientGetUsage(handle, index)
            guard page == 0xFF08 else { continue }
            let id = UMHIDSensorClientGetSensorID(handle, index).map { String(cString: $0) } ?? "hid:electrical:\(index)"
            let name = UMHIDSensorClientGetSensorName(handle, index).map { String(cString: $0) } ?? "Electrical HID sensor \(index)"
            found.append(PowerHIDDescriptor(index: index, id: id, name: name,
                                           metadata: ["usagePage": String(page), "usage": String(usage), "eventType": "25"]))
        }
        descriptors = found
        failure = found.isEmpty ? "No built-in electrical HID sensor services are exposed." : nil
    }

    deinit { if let handle { UMHIDSensorClientDestroy(handle) } }
}

private struct RegistryFanDescriptor {
    let service: io_registry_entry_t
    let id: String
    let name: String
}

private final class PowerRegistryConnection: @unchecked Sendable {
    let battery: io_service_t
    let batteryKeys: [String]
    let nestedBattery: [HardwarePowerDecoder.BatteryNestedDescriptor]
    let fans: [RegistryFanDescriptor]
    let fanFailure: String?

    init() {
        battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        batteryKeys = HardwarePowerDecoder.batteryPropertyKeys
        var dictionaries: [String: [String: Any]] = [:]
        if battery != 0 {
            for (key, _) in HardwarePowerDecoder.nestedBatteryKeys {
                dictionaries[key] = Self.property(battery, key) as? [String: Any]
            }
        }
        nestedBattery = HardwarePowerDecoder.nestedBatteryDescriptors(dictionaries)
        var iterator: io_iterator_t = 0
        let status = IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
        var found: [RegistryFanDescriptor] = []
        if status == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                // Read one explicitly requested telemetry property, not complete
                // firmware dictionaries or device payloads.
                if Self.property(service, "fanactualRPM") != nil {
                    var id: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(service, &id)
                    found.append(RegistryFanDescriptor(service: service, id: "fan:registry:\(id)", name: "Fan actual speed (registry \(id))"))
                } else { IOObjectRelease(service) }
            }
        }
        fans = found
        fanFailure = status != KERN_SUCCESS ? "IORegistry fan inventory failed (IOReturn \(status))."
            : (found.isEmpty ? "No fanactualRPM property is published in IORegistry. SMC fan keys, if present, are listed separately." : nil)
    }

    deinit {
        if battery != 0 { IOObjectRelease(battery) }
        for fan in fans { IOObjectRelease(fan.service) }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

actor HardwarePowerSensorReader {
    private var smc: PowerSMCConnection?
    private var hid: PowerHIDConnection?
    private var registry: PowerRegistryConnection?
    private var knownPowerSources: [String: String] = [:]

    func read() -> [HardwareSensorReading] {
        if smc == nil { smc = PowerSMCConnection() }
        if hid == nil { hid = PowerHIDConnection() }
        if registry == nil { registry = PowerRegistryConnection() }
        let timestamp = Date()
        var result: [HardwareSensorReading] = []
        result.reserveCapacity((smc?.descriptors.count ?? 0) + (hid?.descriptors.count ?? 0) + 40)
        if let smc {
            result.append(contentsOf: smc.discoveryFailures.map {
                HardwareSensorReading(id: $0.id, name: $0.name, category: $0.category, status: $0.status,
                                      source: $0.source, detail: $0.detail, timestamp: timestamp, metadata: $0.metadata)
            })
            for descriptor in smc.descriptors {
                var failure = descriptor.failure
                var decoded: Double?
                if failure == nil, let handle = smc.handle {
                    var value = descriptor.native
                    let status = UMSMCClientReadValue(handle, &value)
                    if status != 0 { failure = PowerSMCConnection.reason(status, firmware: value.firmwareResult) }
                    else {
                        var number = 0.0
                        let success = withUnsafeBytes(of: &value.bytes) {
                            UMSMCDecodeNumber(value.dataType, $0.bindMemory(to: UInt8.self).baseAddress!, Int(value.dataSize), &number)
                        }
                        if success { decoded = number }
                    }
                }
                result.append(HardwarePowerDecoder.smcReading(channel: descriptor.channel, value: decoded, failure: failure,
                                                             timestamp: timestamp, metadata: descriptor.metadata))
            }
        }
        if let hid {
            if let failure = hid.failure {
                result.append(HardwareSensorReading(id: "hid:electrical:inventory", name: "Electrical HID inventory", category: .diagnostics,
                                                    status: .unavailable(failure), source: "IOHIDEvent", timestamp: timestamp))
            }
            if let handle = hid.handle {
                var selectors = [Int64](repeating: 0, count: 2)
                for descriptor in hid.descriptors {
                    var value = 0.0
                    let hasValue = UMHIDSensorClientReadFloats(handle, descriptor.index, 25, hid.measurementFields, 1, &value)
                    let hasSelectors = UMHIDSensorClientReadIntegers(handle, descriptor.index, 25, hid.selectorFields, 2, &selectors)
                    result.append(HardwarePowerDecoder.hidReading(id: descriptor.id, name: descriptor.name,
                                                                 value: hasValue ? value : nil, measurementType: hasSelectors ? selectors[0] : nil,
                                                                 subtype: hasSelectors ? selectors[1] : nil, timestamp: timestamp,
                                                                 metadata: descriptor.metadata))
                }
            }
        }
        if let registry {
            var properties: [String: Any] = [:]
            if registry.battery != 0 {
                for key in registry.batteryKeys { properties[key] = PowerRegistryConnection.property(registry.battery, key) }
            }
            result.append(contentsOf: HardwarePowerDecoder.batteryReadings(properties: properties,
                unavailableReason: registry.battery == 0 ? "AppleSmartBattery service is not exposed." : nil, timestamp: timestamp))
            var dictionaries: [String: [String: Any]] = [:]
            if registry.battery != 0 {
                for (key, _) in HardwarePowerDecoder.nestedBatteryKeys {
                    dictionaries[key] = PowerRegistryConnection.property(registry.battery, key) as? [String: Any]
                }
            }
            for descriptor in registry.nestedBattery {
                result.append(HardwarePowerDecoder.nestedBatteryReading(descriptor, dictionaries: dictionaries,
                    unavailableReason: HardwarePowerDecoder.boolean(properties["BatteryInstalled"]) == false
                        ? "BatteryInstalled is false; battery telemetry is unavailable." : nil, timestamp: timestamp))
            }
            if let failure = registry.fanFailure {
                result.append(HardwareSensorReading(id: "fan:registry:inventory", name: "Registry fan telemetry", category: .power,
                                                    status: .unavailable(failure), source: "IORegistry", timestamp: timestamp))
            }
            for fan in registry.fans {
                let raw = PowerRegistryConnection.property(fan.service, "fanactualRPM")
                let value = HardwarePowerDecoder.number(raw)
                let valid = value.map { $0 >= 0 } == true
                result.append(HardwareSensorReading(id: fan.id, name: fan.name, category: .power,
                                                    value: valid ? value : nil, unit: "RPM",
                                                    status: valid ? .available : .unavailable("fanactualRPM is absent, nonnumeric, or negative; the fan remains detected."),
                                                    source: "IORegistry", timestamp: timestamp, metadata: ["property": "fanactualRPM"]))
            }
        }
        result.append(contentsOf: readPowerSources(timestamp: timestamp))
        return result
    }

    private func readPowerSources(timestamp: Date) -> [HardwareSensorReading] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return powerSourceFailures(reason: "IOPS could not copy the current power-source descriptions.", timestamp: timestamp)
        }
        var result: [HardwareSensorReading] = []
        var present = Set<String>()
        for (index, source) in sources.enumerated() {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                let id = "iops:slot:\(index)"
                let name = "Power source slot \(index + 1)"
                knownPowerSources[id] = name
                present.insert(id)
                result.append(contentsOf: powerSourceFailure(id: id, name: name,
                    reason: "IOPS exposes this power-source handle but its description is unavailable.", timestamp: timestamp))
                continue
            }
            let sourceID = (description["Power Source ID"] as? NSNumber)?.stringValue ?? String(index)
            let id = "iops:\(sourceID)"
            let name = (description["Name"] as? String) ?? "Power source \(index + 1)"
            knownPowerSources[id] = name
            present.insert(id)
            let charge = HardwarePowerDecoder.percentage(current: HardwarePowerDecoder.number(description["Current Capacity"]),
                                                         maximum: HardwarePowerDecoder.number(description["Max Capacity"]))
            result.append(HardwareSensorReading(id: "\(id):charge", name: "\(name) charge", category: .battery, value: charge, unit: "%",
                                                status: charge == nil ? .unavailable("Current Capacity / Max Capacity are absent or invalid.") : .available,
                                                source: "IOPS", detail: "OS normalized charge percentage; not raw mAh capacity.", timestamp: timestamp))
            for (key, label) in [("Power Source State", "power source"), ("BatteryHealth", "health"), ("BatteryHealthCondition", "health condition")] {
                let text = description[key] as? String
                result.append(HardwareSensorReading(id: "\(id):\(key)", name: "\(name) \(label)", category: .battery,
                                                    textValue: text.map { $0.isEmpty ? "None reported" : $0 },
                                                    status: text == nil ? .unavailable("IOPS \(key) is not reported.") : .available,
                                                    source: "IOPS", timestamp: timestamp))
            }
            for (key, label) in [("Is Charging", "charging"), ("Is Present", "present"), ("LPM Active", "low power mode"),
                                 ("Battery Provides Time Remaining", "runtime estimate supported")] {
                let value = HardwarePowerDecoder.boolean(description[key])
                result.append(HardwareSensorReading(id: "\(id):\(key)", name: "\(name) \(label)", category: .battery,
                                                    textValue: value.map { $0 ? "Yes" : "No" },
                                                    status: value == nil ? .unavailable("IOPS \(key) is not reported.") : .available,
                                                    source: "IOPS", timestamp: timestamp))
            }
            for (key, label, unit, scale) in [("Current", "current", "A", 0.001), ("Voltage", "voltage", "V", 0.001),
                                             ("Time to Empty", "time to empty estimate", "min", 1.0), ("Time to Full Charge", "time to full estimate", "min", 1.0)] {
                let raw = HardwarePowerDecoder.number(description[key])
                let notApplicable = (key == "Time to Empty" && (description["Power Source State"] as? String) != "Battery Power")
                    || (key == "Time to Full Charge" && HardwarePowerDecoder.boolean(description["Is Charging"]) != true)
                let valid = raw.map { key == "Current" || $0 >= 0 } == true && !notApplicable
                result.append(HardwareSensorReading(id: "\(id):\(key)", name: "\(name) \(label)", category: .battery,
                                                    value: valid ? raw.map { $0 * scale } : nil, unit: unit,
                                                    status: valid ? .available : .unavailable(notApplicable ? "Estimate is not applicable in the current charging/power state." : "IOPS \(key) is not reported or is invalid."),
                                                    source: "IOPS", timestamp: timestamp))
            }
        }
        for (id, name) in knownPowerSources where !present.contains(id) {
            result.append(contentsOf: powerSourceFailure(id: id, name: name, reason: "Previously detected power source is no longer exposed by IOPS.", timestamp: timestamp))
        }
        if result.isEmpty { return powerSourceFailures(reason: "No power-source descriptions are exposed by IOPS.", timestamp: timestamp) }
        return result
    }

    private func powerSourceFailures(reason: String, timestamp: Date) -> [HardwareSensorReading] {
        guard !knownPowerSources.isEmpty else {
            return [HardwareSensorReading(id: "iops:inventory", name: "Power-source inventory", category: .battery,
                                          status: .unavailable(reason), source: "IOPS", timestamp: timestamp)]
        }
        return knownPowerSources.flatMap { powerSourceFailure(id: $0.key, name: $0.value, reason: reason, timestamp: timestamp) }
    }

    private func powerSourceFailure(id: String, name: String, reason: String, timestamp: Date) -> [HardwareSensorReading] {
        ["charge", "Power Source State", "BatteryHealth", "BatteryHealthCondition", "Is Charging", "Is Present", "LPM Active", "Battery Provides Time Remaining", "Current", "Voltage", "Time to Empty", "Time to Full Charge"].map {
            HardwareSensorReading(id: "\(id):\($0)", name: "\(name) \($0)", category: .battery,
                                  status: .unavailable(reason), source: "IOPS", timestamp: timestamp)
        }
    }
}
