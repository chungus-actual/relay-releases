import Foundation

// Local wall-clock time, independent of animation time and the app's color scheme.
struct PetDaylight: Equatable {
    let phase: String
    init(hour: Int) {
        switch (hour % 24 + 24) % 24 {
        case 6..<8: phase = "dawn"
        case 8..<18: phase = "day"
        case 18..<20: phase = "dusk"
        default: phase = "night"
        }
    }
    static func at(_ date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Self {
        Self(hour: calendar.component(.hour, from: date))
    }
    var windowArtwork: String { phase == "night" ? "nookWindow" : "nookWindow" + phase.capitalized }
    var glowHex: String {
        switch phase {
        case "dawn": "F2B388"
        case "day": "FFE4A8"
        case "dusk": "ED936F"
        default: "92ACE8"
        }
    }
    var wallOpacity: Double { phase == "night" ? 0.08 : phase == "day" ? 0.06 : 0.10 }
    var floorOpacity: Double { phase == "night" ? 0.08 : phase == "day" ? 0.15 : 0.18 }
    var beamOpacity: Double { phase == "night" ? 0.035 : phase == "day" ? 0.12 : 0.10 }
}
