import SwiftData
import SwiftUI
import UIKit

/// UserDefaults keys that only exist on the iOS app.
enum IOSSettingsKeys {
    static let autoImportClipboard = "autoImportClipboard"
    /// Last `UIPasteboard.general.changeCount` already imported (or produced
    /// by our own copy), so auto-import never re-reads the same pasteboard
    /// generation and never re-imports self-copies.
    static let lastImportedChangeCount = "lastImportedChangeCount"
}

final class ClipStoryIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        application.registerForRemoteNotifications()
    }
}

@main
struct ClipStoryiOSApp: App {
    @UIApplicationDelegateAdaptor(ClipStoryIOSAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(IOSSettingsKeys.autoImportClipboard) private var autoImportClipboard = false
    @AppStorage(IOSSettingsKeys.lastImportedChangeCount) private var lastImportedChangeCount = -1

    private let persistence: PersistenceSetup
    @StateObject private var store: ClipStore
    @StateObject private var syncStatus: CloudSyncStatus

    init() {
        let persistence = ModelContainerFactory.makeShared()
        self.persistence = persistence
        _store = StateObject(wrappedValue: ClipStore(container: persistence.container))
        _syncStatus = StateObject(wrappedValue: CloudSyncStatus(mode: persistence.mode))
    }

    var body: some Scene {
        WindowGroup {
            HistoryListView()
                .environmentObject(store)
                .environmentObject(syncStatus)
        }
        .modelContainer(persistence.container)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            syncStatus.refresh()
            store.dedupeSweep()
            importCurrentClipboardIfNeeded()
        }
    }

    /// Opt-in auto-import (reading the pasteboard shows the iOS paste
    /// banner). `changeCount` is readable without a prompt, so skip both the
    /// read and the banner when the pasteboard has not changed since the last
    /// import — including changes produced by our own copy actions.
    private func importCurrentClipboardIfNeeded() {
        guard autoImportClipboard else { return }
        let changeCount = UIPasteboard.general.changeCount
        guard changeCount != lastImportedChangeCount else { return }
        lastImportedChangeCount = changeCount
        guard let content = ClipboardReader.readCurrentContent() else { return }
        guard let item = store.insert(content), let imageData = item.imageData else { return }
        let contentHash = item.contentHash
        let store = store
        Task.detached(priority: .utility) {
            let text = ImageTextRecognizer.recognizedText(in: imageData)
            await MainActor.run {
                store.updateRecognizedText(contentHash: contentHash, text: text)
            }
        }
    }
}
