import DiskStewardCore
import SwiftUI

extension VisualColorSpec {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }
}

enum UsageTint {
    static func color(forFraction usedFraction: Double) -> Color {
        if usedFraction >= 0.90 { return .red }
        if usedFraction >= 0.78 { return .orange }
        return .accentColor
    }
}
