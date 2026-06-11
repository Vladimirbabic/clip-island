import CoreData
import Foundation
import OSLog
import SwiftData

/// Dev utility behind `--init-cloudkit-schema`: pushes the current SwiftData
/// model to the CloudKit **Development** schema so it can then be deployed to
/// Production in CloudKit Console.
///
/// Run it after ANY `@Model` change, BEFORE shipping Release builds: the
/// Production schema never auto-creates fields, and a record type with a
/// missing field makes every export of that type fail silently — clips and
/// pinboards then simply stop appearing on other devices.
enum CloudKitSchemaInitializer {
    private static let logger = Logger(subsystem: "com.vladbabic.clipstory", category: "schema")

    /// Terminates the process (success or failure) when the flag is present;
    /// returns immediately otherwise.
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--init-cloudkit-schema") else { return }

        let environment = Bundle.main.object(forInfoDictionaryKey: "ClipStoryCloudKitEnvironment") as? String
        guard environment == "Development" else {
            fail("--init-cloudkit-schema needs a Debug build (CloudKit Development environment); this build targets \(environment ?? "unknown").")
        }
        guard EntitlementChecker.hasICloudContainerEntitlement() else {
            fail("This build has no iCloud entitlement; sign it with the CloudKit-capable Debug profile first.")
        }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(
            for: [ClipItem.self, Pinboard.self, AppSettings.self]
        ) else {
            fail("Could not derive a managed object model from the SwiftData schema.")
        }

        // Throwaway store: schema initialization only needs the model, not
        // the app's real data.
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstory-schema-init-\(UUID().uuidString).sqlite")
        let description = NSPersistentStoreDescription(url: storeURL)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: ModelContainerFactory.cloudKitContainerID
        )
        let container = NSPersistentCloudKitContainer(name: "ClipStory", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            fail("Could not load the schema-init store: \(loadError)")
        }

        do {
            try container.initializeCloudKitSchema(options: [])
            let message = """
            CloudKit Development schema initialized for \(ModelContainerFactory.cloudKitContainerID).
            Next: CloudKit Console > \(ModelContainerFactory.cloudKitContainerID) > Deploy Schema Changes (Development -> Production).
            """
            logger.info("\(message)")
            print(message)
            exit(0)
        } catch {
            fail("initializeCloudKitSchema failed: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        logger.error("\(message)")
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        exit(1)
    }
}
