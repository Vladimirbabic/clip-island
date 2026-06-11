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

    /// Every synced model. The CloudKit schema initializer derives the
    /// Development schema from this same list — keep them in lockstep.
    static let modelTypes: [any PersistentModel.Type] = [
        ClipItem.self, Pinboard.self, AppSettings.self, SourceAppBrand.self,
    ]

    static let schema = Schema(modelTypes)

    private static let logger = Logger(subsystem: "com.vladbabic.clipstory", category: "persistence")

    /// iOS app group so the main app and the share extension open the SAME
    /// store file. Without it, the extension wrote into its own sandbox and
    /// shared clips depended on a CloudKit round trip the extension's ~0.65s
    /// lifetime almost never completed — they simply went missing.
    static let iosAppGroupID = "group.com.vladbabic.clipstory"

    /// Tries CloudKit-synced storage first, falls back to local-only storage
    /// (e.g. when running without signing/entitlements), and finally to
    /// in-memory so the app never fails to launch.
    static func makeShared() -> PersistenceSetup {
        let storeURL = sharedStoreURL()
        if hasCloudKitEntitlement() {
            do {
                let cloudConfiguration: ModelConfiguration
                if let storeURL {
                    cloudConfiguration = ModelConfiguration(
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .private(cloudKitContainerID)
                    )
                } else {
                    cloudConfiguration = ModelConfiguration(
                        schema: schema,
                        cloudKitDatabase: .private(cloudKitContainerID)
                    )
                }
                let container = try ModelContainer(for: schema, configurations: [cloudConfiguration])
                return PersistenceSetup(container: container, mode: .cloudKit)
            } catch {
                logger.error("CloudKit-backed store unavailable, falling back to local: \(error)")
            }
        }

        do {
            let localConfiguration: ModelConfiguration
            if let storeURL {
                localConfiguration = ModelConfiguration(
                    schema: schema, url: storeURL, cloudKitDatabase: .none
                )
            } else {
                localConfiguration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            }
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

    /// CKContainer creation hits a fatal trap (not a catchable error) when
    /// the process lacks the iCloud entitlement — so check the entitlement
    /// itself and never touch CloudKit without it. Unsigned or team-less
    /// builds then degrade to local-only instead of crashing.
    private static func hasCloudKitEntitlement() -> Bool {
        let entitled = EntitlementChecker.hasICloudContainerEntitlement()
        if !entitled {
            logger.error("No iCloud entitlement in this build — using local-only storage")
        }
        return entitled
    }

    /// In-memory container for unit tests, previews, and demo mode.
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// On iOS, the store lives in the app group container shared with the
    /// share extension. Nil (→ default per-process location) on macOS, and
    /// on builds whose profile lacks the app group (Debug manual signing).
    private static func sharedStoreURL() -> URL? {
        #if os(iOS)
        let fileManager = FileManager.default
        guard let groupContainer = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: iosAppGroupID
        ) else { return nil }
        let directory = groupContainer.appendingPathComponent(
            "Library/Application Support", isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("Could not create the app-group store directory: \(error)")
            return nil
        }
        let url = directory.appendingPathComponent("default.store")
        migrateLegacySandboxStoreIfNeeded(to: url)
        return url
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// One-time move of the pre-app-group store so existing local data (and
    /// CloudKit mirroring state) survives the location change.
    private static func migrateLegacySandboxStoreIfNeeded(to destination: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let legacy = support.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        for suffix in ["", "-shm", "-wal"] {
            let from = support.appendingPathComponent("default.store" + suffix)
            let into = destination.deletingLastPathComponent()
                .appendingPathComponent("default.store" + suffix)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            do {
                try fileManager.copyItem(at: from, to: into)
            } catch {
                logger.error("Legacy store migration failed for \(from.lastPathComponent): \(error)")
            }
        }
    }
    #endif
}
