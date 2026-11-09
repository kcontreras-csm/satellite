import Foundation

/// Where the apps bar sits: down the left side of the window (the rail), or along the top, under the toolbar.
/// Settings > General > Apps bar changes it; the main window follows live through `changed`.
enum RailPosition: String, CaseIterable, Identifiable {
    case left, top

    static let defaultsKey = "railPosition"
    static let changed = Notification.Name("satellite.railPositionChanged")

    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return "Left"
        case .top: return "Top"
        }
    }

    static var current: RailPosition {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .left
    }
}
