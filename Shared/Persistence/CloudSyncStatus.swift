import CloudKit
import Foundation
import OSLog

/// Live, honest sync status: the store must be CloudKit-backed AND an iCloud
/// account must be available. Only probes CloudKit when the cloud container
/// was actually created (CKContainer(identifier:) raises an Objective-C
/// exception when the entitlement is missing).
@MainActor
final class CloudSyncStatus: ObservableObject {
    enum State: Equatable {
        case syncing
        case noAccount
        case localOnly
        case ephemeral

        var isSyncing: Bool { self == .syncing }
    }

    @Published private(set) var state: State
    @Published private(set) var lastCheckedAt: Date?

    private let mode: PersistenceMode
    private let logger = Logger(subsystem: "com.vladbabic.clipstory", category: "sync-status")
    private var accountObserver: NSObjectProtocol?

    init(mode: PersistenceMode) {
        self.mode = mode
        switch mode {
        case .cloudKit:
            state = .syncing
            refresh()
            accountObserver = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        case .localOnly:
            state = .localOnly
        case .inMemory:
            state = .ephemeral
        }
    }

    deinit {
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
    }

    var statusText: String {
        switch state {
        case .syncing: return "iCloud sync is on"
        case .noAccount: return "Signed out of iCloud — items stay on this device until you sign in"
        case .localOnly: return "iCloud sync unavailable (set your team + container in project.yml)"
        case .ephemeral: return "Storage unavailable — history will NOT survive relaunch"
        }
    }

    var freshnessText: String {
        guard let lastCheckedAt else { return "Not checked yet" }
        return "Checked \(lastCheckedAt.formatted(date: .omitted, time: .shortened))"
    }

    func refresh() {
        guard mode == .cloudKit else { return }
        let containerID = ModelContainerFactory.cloudKitContainerID
        Task { @MainActor [weak self] in
            do {
                let status = try await CKContainer(identifier: containerID).accountStatus()
                self?.lastCheckedAt = Date()
                self?.state = status == .available ? .syncing : .noAccount
            } catch {
                self?.logger.error("Account status check failed: \(error)")
                self?.lastCheckedAt = Date()
                self?.state = .noAccount
            }
        }
    }
}
