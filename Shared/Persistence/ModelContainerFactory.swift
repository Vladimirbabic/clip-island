import Foundation
import OSLog
import SwiftData

/// How the store was actually created — the UI surfaces this honestly instead
/// of a single misleading boolean.
enum PersistenceMode: Sendable {
    /// CloudKit-backed store created. Whether sync actually runs also depends
    /// on the iCloud account — see `CloudSyncStatus`.
    case cloudKit
    /// On-disk store without CloudKit (missing entitlements/signing).
    case localOnly
    /// Last-resort volatile store; nothing survives relaunch.
    case inMemory
}

/// The persistence stack plus the mode the UI uses to show sync status.
struct PersistenceSetup {
    let container: ModelContainer
    let mode: PersistenceMode
}

enum ModelContainerFactory {
    /// Must match the container in both targets' entitlements.
    static let cloudKitContainerID = "iCloud.com.vladbabic.clipstory"

    static let schema = Schema([ClipItem.self, Pinboard.self, AppSettings.self])

    private static let logger = Logger(subsystem: "com.vladbabic.clipstory", category: "persistence")

    /// Tries CloudKit-synced storage first, falls back to local-only storage
    /// (e.g. when running without signing/entitlements), and finally to
    /// in-memory so the app never fails to launch.
    static func makeShared() -> PersistenceSetup {
        do {
            let cloudConfiguration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .private(cloudKitContainerID)
            )
            let container = try ModelContainer(for: schema, configurations: [cloudConfiguration])
            return PersistenceSetup(container: container, mode: .cloudKit)
        } catch {
            logger.error("CloudKit-backed store unavailable, falling back to local: \(error)")
        }

        do {
            let localConfiguration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [localConfiguration])
            return PersistenceSetup(container: container, mode: .localOnly)
        } catch {
            logger.error("Local store unavailable, falling back to in-memory: \(error)")
        }

        do {
            return PersistenceSetup(container: try makeInMemory(), mode: .inMemory)
        } catch {
            fatalError("Unable to create any SwiftData container: \(error)")
        }
    }

    /// In-memory container for unit tests, previews, and demo mode.
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
