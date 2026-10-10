import Foundation

enum HardwareSensorCategory: String, CaseIterable, Identifiable, Sendable {
    case motion = "Lid & motion"
    case display = "Display & light"
    case temperature = "Temperature"
    case power = "Power & fans"
    case battery = "Battery"
    case system = "System"
    case diagnostics = "Raw / unclassified"

    var id: String { rawValue }
}

enum HardwareSensorStatus: Equatable, Sendable {
    case available
    case unavailable(String)
    case unclassified(String)
    case present(String)

    var label: String {
        switch self {
        case .available: "Live"
        case .unavailable: "Unavailable"
        case .unclassified: "Unclassified"
        case .present: "Detected"
        }
    }
    var explanation: String? {
        switch self {
        case .available: nil
        case .unavailable(let reason), .unclassified(let reason), .present(let reason): reason
        }
    }
    var isAvailable: Bool { if case .available = self { true } else { false } }
}

struct HardwareSensorReading: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let category: HardwareSensorCategory
    let value: Double?
    let unit: String
    let textValue: String?
    let status: HardwareSensorStatus
    let source: String
    let detail: String
    let timestamp: Date
    let metadata: [String: String]

    init(id: String, name: String, category: HardwareSensorCategory, value: Double? = nil,
         unit: String = "", textValue: String? = nil, status: HardwareSensorStatus = .available,
         source: String, detail: String = "", timestamp: Date = Date(), metadata: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.category = category
        self.value = value
        self.unit = unit
        self.textValue = textValue
        self.status = status
        self.source = source
        self.detail = detail
        self.timestamp = timestamp
        self.metadata = metadata
    }
}
