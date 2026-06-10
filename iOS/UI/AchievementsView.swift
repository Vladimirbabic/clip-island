import SwiftData
import SwiftUI

struct AchievementsView: View {
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var items: [ClipItem]
    @Query(sort: [
        SortDescriptor(\Pinboard.sortOrder),
        SortDescriptor(\Pinboard.createdAt),
    ]) private var pinboards: [Pinboard]

    private var achievements: [ClipAchievement] {
        AchievementCatalog.achievements(items: items, pinboards: pinboards)
    }

    private var stats: ClipStats {
        AchievementCatalog.stats(items: items, pinboards: pinboards)
    }

    var body: some View {
        List {
            Section("Stats") {
                LabeledContent("Clips", value: "\(stats.totalClips)")
                LabeledContent("Saved", value: "\(stats.savedClips)")
                LabeledContent("Pages", value: "\(stats.pageCount)")
                LabeledContent("Searchable Images", value: "\(stats.clipsWithRecognizedText)")
            }
            Section("Achievements") {
                ForEach(achievements) { achievement in
                    HStack(spacing: 12) {
                        Image(systemName: achievement.systemImageName)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(achievement.isUnlocked ? Color.accentColor : Color.secondary)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(achievement.title)
                                .font(.body.weight(.semibold))
                            Text(achievement.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: achievement.isUnlocked ? "checkmark.circle.fill" : "lock")
                            .foregroundStyle(achievement.isUnlocked ? Color.green : Color.secondary)
                    }
                }
            }
        }
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
