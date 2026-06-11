import Foundation
import SwiftData

@MainActor
extension ClipStore {
    static let syncProbeSourceName = "ClipStory Sync Check"
    private static let syncProbeTitlePrefix = "ClipStory Sync Check"

    @discardableResult
    func createSyncProbe(origin: String) -> ClipItem? {
        let id = UUID().uuidString
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let text = """
        \(Self.syncProbeTitlePrefix)
        Origin: \(origin)
        Created: \(createdAt)
        ID: \(id)
        """
        let content = CapturedContent(
            kind: .text,
            text: text,
            sourceAppName: Self.syncProbeSourceName,
            sourceAppBundleID: Bundle.main.bundleIdentifier
        )
        return insertManual(content)
    }

    func syncProbeItems(limit: Int = 6) -> [ClipItem] {
        do {
            let items = try context.fetch(FetchDescriptor<ClipItem>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
            return Array(items.filter(Self.isSyncProbe).prefix(limit))
        } catch {
            logger.error("Failed to fetch sync probes: \(error)")
            return []
        }
    }

    func deleteSyncProbes() {
        do {
            let items = try context.fetch(FetchDescriptor<ClipItem>())
            for item in items where Self.isSyncProbe(item) {
                context.delete(item)
            }
            try context.save()
        } catch {
            logger.error("Failed to delete sync probes: \(error)")
        }
    }

    func syncProbeSummary(limit: Int = 3) -> String {
        let probes = syncProbeItems(limit: limit)
        guard let latest = probes.first else {
            return "No sync test clips yet."
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let latestAge = formatter.localizedString(for: latest.createdAt, relativeTo: Date())
        if probes.count == 1 {
            return "Latest test clip: \(latestAge)."
        }
        return "\(probes.count) recent test clips. Latest: \(latestAge)."
    }

    private static func isSyncProbe(_ item: ClipItem) -> Bool {
        if item.sourceAppName == syncProbeSourceName {
            return true
        }
        return item.text?.hasPrefix(syncProbeTitlePrefix) == true
    }
}
