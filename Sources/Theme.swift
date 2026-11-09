import SwiftUI

enum Theme {
    static let maxScale: Double = 110   // °C at full gauge

    /// Colour for a temperature in °C: ice → green → amber → orange → red.
    static func color(for celsius: Double?) -> Color {
        guard let c = celsius else { return .gray }
        switch c {
        case ..<45: return Color(red: 0.30, green: 0.85, blue: 1.00)
        case ..<60: return Color(red: 0.35, green: 0.95, blue: 0.55)
        case ..<75: return Color(red: 1.00, green: 0.80, blue: 0.25)
        case ..<88: return Color(red: 1.00, green: 0.50, blue: 0.15)
        default:    return Color(red: 1.00, green: 0.22, blue: 0.20)
        }
    }

    static func status(for celsius: Double?) -> String {
        guard let c = celsius else { return "No sensor" }
        switch c {
        case ..<45: return "Cool"
        case ..<60: return "Normal"
        case ..<75: return "Warm"
        case ..<88: return "Hot"
        default:    return "Critical"
        }
    }

    static let gaugeGradient = AngularGradient(
        gradient: Gradient(colors: [
            Color(red: 0.30, green: 0.85, blue: 1.00),
            Color(red: 0.35, green: 0.95, blue: 0.55),
            Color(red: 1.00, green: 0.80, blue: 0.25),
            Color(red: 1.00, green: 0.50, blue: 0.15),
            Color(red: 1.00, green: 0.22, blue: 0.20),
        ]),
        center: .center,
        startAngle: .degrees(135),
        endAngle: .degrees(405))

    static let flameGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.85, blue: 0.3), Color(red: 1.0, green: 0.35, blue: 0.05), Color(red: 0.85, green: 0.1, blue: 0.05)],
        startPoint: .top, endPoint: .bottom)
}

enum TempUnit: String, CaseIterable, Identifiable {
    case celsius = "°C", fahrenheit = "°F"
    var id: String { rawValue }

    func convert(_ c: Double) -> Double { self == .celsius ? c : c * 9 / 5 + 32 }

    func format(_ c: Double?, decimals: Int = 0) -> String {
        guard let c = c else { return "--" }
        return String(format: "%.\(decimals)f°", convert(c))
    }
}
