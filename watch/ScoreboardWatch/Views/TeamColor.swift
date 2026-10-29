import SwiftUI

/// Turns the overlay's inline colour style ("background: rgb(0, 0, 255);") into a SwiftUI colour.
enum TeamColor {
    struct RGB: Equatable {
        var red: Int, green: Int, blue: Int
    }

    static func rgb(from style: String?) -> RGB? {
        guard let style,
              let match = style.firstMatch(of: /rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)/),
              let red = Int(match.1), let green = Int(match.2), let blue = Int(match.3),
              [red, green, blue].allSatisfy({ (0...255).contains($0) }) else { return nil }
        return RGB(red: red, green: green, blue: blue)
    }

    static func color(from style: String?) -> Color? {
        rgb(from: style).map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255) }
    }
}
