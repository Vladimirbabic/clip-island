import Foundation

enum ClipDateFilter: String, CaseIterable, Equatable, Sendable {
    case any
    case today
    case last7Days
    case last30Days

    var displayName: String {
        switch self {
        case .any: return "Any Time"
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .any:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return true }
            return date >= start
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return true }
            return date >= start
        }
    }
}

struct ClipSearchFilters: Equatable, Sendable {
    var kind: ClipKind?
    var sourceAppName: String?
    var date: ClipDateFilter = .any
    var savedOnly = false
    var pinnedOnly = false
    var withRecognizedTextOnly = false

    static let none = ClipSearchFilters()

    var isActive: Bool {
        kind != nil
            || sourceAppName != nil
            || date != .any
            || savedOnly
            || pinnedOnly
            || withRecognizedTextOnly
    }
}
