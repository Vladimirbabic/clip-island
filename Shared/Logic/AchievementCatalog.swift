import Foundation

struct ClipStats: Equatable {
    let totalClips: Int
    let savedClips: Int
    let pageCount: Int
    let imageClips: Int
    let linkClips: Int
    let clipsWithRecognizedText: Int
    let sourceCount: Int
    let oldestClipAgeDays: Int?
}

struct ClipAchievement: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImageName: String
    let isUnlocked: Bool
}

enum AchievementCatalog {
    static func stats(items: [ClipItem], pinboards: [Pinboard], now: Date = Date()) -> ClipStats {
        let saved = items.filter { $0.isPinned || $0.pinboard != nil }.count
        let sources = Set(items.compactMap { source in
            let value = source.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        })
        let oldest = items.map(\.createdAt).min()
        let oldestDays = oldest.map {
            max(0, Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0)
        }
        return ClipStats(
            totalClips: items.count,
            savedClips: saved,
            pageCount: pinboards.count,
            imageClips: items.filter { $0.kind == .image || $0.imageData != nil }.count,
            linkClips: items.filter { $0.kind == .url }.count,
            clipsWithRecognizedText: items.filter {
                !($0.recognizedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count,
            sourceCount: sources.count,
            oldestClipAgeDays: oldestDays
        )
    }

    static func achievements(items: [ClipItem], pinboards: [Pinboard]) -> [ClipAchievement] {
        let stats = stats(items: items, pinboards: pinboards)
        let hasMacAndPhone = Set(items.compactMap(\.sourceAppName)).contains { source in
            source.localizedCaseInsensitiveContains("iphone")
        } && stats.sourceCount > 1

        return [
            ClipAchievement(
                id: "first-rescue",
                title: "First Rescue",
                subtitle: "Save your first clip.",
                systemImageName: "lifepreserver",
                isUnlocked: stats.totalClips >= 1
            ),
            ClipAchievement(
                id: "time-traveler",
                title: "Time Traveler",
                subtitle: "Keep history for at least a week.",
                systemImageName: "clock.arrow.circlepath",
                isUnlocked: (stats.oldestClipAgeDays ?? 0) >= 7
            ),
            ClipAchievement(
                id: "page-builder",
                title: "Page Builder",
                subtitle: "Create your first saved Page.",
                systemImageName: "square.grid.2x2",
                isUnlocked: stats.pageCount >= 1
            ),
            ClipAchievement(
                id: "prompt-library",
                title: "Prompt Library",
                subtitle: "Save 10 text clips or notes.",
                systemImageName: "text.book.closed",
                isUnlocked: items.filter { $0.kind == .text && ($0.isPinned || $0.pinboard != nil) }.count >= 10
            ),
            ClipAchievement(
                id: "screenshot-sleuth",
                title: "Screenshot Sleuth",
                subtitle: "Index text from a screenshot or image.",
                systemImageName: "text.viewfinder",
                isUnlocked: stats.clipsWithRecognizedText >= 1
            ),
            ClipAchievement(
                id: "cross-device-relay",
                title: "Cross-Device Relay",
                subtitle: "Sync clips between iPhone and another source.",
                systemImageName: "iphone.gen3.radiowaves.left.and.right",
                isUnlocked: hasMacAndPhone
            ),
            ClipAchievement(
                id: "clean-desk",
                title: "Clean Desk",
                subtitle: "Save at least 25 clips worth keeping.",
                systemImageName: "tray.full",
                isUnlocked: stats.savedClips >= 25
            ),
            ClipAchievement(
                id: "ai-memory",
                title: "AI Memory",
                subtitle: "Build a Page for reusable coding or AI snippets.",
                systemImageName: "sparkles",
                isUnlocked: pinboards.contains { board in
                    let name = board.displayName.lowercased()
                    return name.contains("ai")
                        || name.contains("prompt")
                        || name.contains("coding")
                        || name.contains("snippet")
                }
            ),
        ]
    }
}
