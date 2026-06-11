import SwiftUI

/// Compact settings sheet: synced history limit, auto-import toggle, sync
/// status, clear history, and version footer.
struct SettingsSheet: View {
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var syncStatus: CloudSyncStatus
    @Environment(\.dismiss) private var dismiss

    @AppStorage(IOSSettingsKeys.autoImportClipboard) private var autoImportClipboard = false
    @AppStorage(AppConstants.copySoundEnabledKey) private var isCopySoundEnabled = true

    /// Local mirror of the synced limit; writing goes through
    /// `store.setHistoryLimit` so the choice syncs across devices.
    @State private var selectedLimit = AppConstants.defaultHistoryLimit
    @State private var isShowingClearConfirmation = false
    @State private var syncProbeMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                historySection
                captureSection
                syncSection
                achievementsSection
                dangerSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Clear Unsaved History?",
                isPresented: $isShowingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Unsaved History", role: .destructive) {
                    store.clearUnpinned()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pinned clips and clips saved to pages are kept. This cannot be undone.")
            }
        }
        .onAppear {
            selectedLimit = store.historyLimit
        }
    }

    private var historySection: some View {
        Section {
            Picker("History Limit", selection: $selectedLimit) {
                ForEach(AppConstants.historyLimitChoices, id: \.self) { limit in
                    Text("\(limit) items").tag(limit)
                }
            }
            .onChange(of: selectedLimit) { _, newValue in
                // Skip echoes of the already-synced value so merely opening
                // this sheet never stamps a new "explicit choice" timestamp.
                guard store.syncedHistoryLimit() != newValue else { return }
                store.setHistoryLimit(newValue)
            }
        } header: {
            Text("History")
        } footer: {
            historyFooter
        }
    }

    private var historyFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Older unsaved history items beyond this limit are removed automatically. Pinned clips and saved pages are kept.")
            if !store.hasSyncedHistoryLimit {
                Text("Pruning is inactive until a limit is chosen on any of your devices.")
            }
        }
    }

    private var captureSection: some View {
        Section {
            Toggle("Auto-Import on Open", isOn: $autoImportClipboard)
            Toggle("Copy Sound", isOn: $isCopySoundEnabled)
        } header: {
            Text("Capture")
        } footer: {
            Text("Saves the iPhone clipboard when the app opens and its contents changed since the last import. iOS shows a paste notification on each import.")
        }
    }

    private var syncSection: some View {
        Section("iCloud Sync") {
            Label(syncStatus.statusText, systemImage: syncStatus.state.systemImageName)
                .foregroundStyle(syncStatus.state.isSyncing ? Color.primary : Color.secondary)
            LabeledContent("Environment", value: cloudKitEnvironmentText)
            LabeledContent("Freshness", value: syncStatus.freshnessText)
            LabeledContent("Test Clips", value: syncProbeMessage ?? store.syncProbeSummary())
            Button {
                createSyncProbe()
            } label: {
                Label("Create iPhone Sync Test Clip", systemImage: "waveform.path.ecg")
            }
            Button {
                syncStatus.refresh()
                syncProbeMessage = store.syncProbeSummary()
            } label: {
                Label("Refresh Sync Status", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                store.deleteSyncProbes()
                syncProbeMessage = "Removed sync test clips."
            } label: {
                Label("Clean Sync Test Clips", systemImage: "trash")
            }
        }
    }

    private var cloudKitEnvironmentText: String {
        Bundle.main.object(forInfoDictionaryKey: "ClipStoryCloudKitEnvironment") as? String ?? "Unknown"
    }

    private func createSyncProbe() {
        guard store.createSyncProbe(origin: "iPhone") != nil else {
            syncProbeMessage = "Could not create a sync test clip."
            return
        }
        syncProbeMessage = "Created an iPhone sync test clip. Open ClipStory on Mac and refresh."
    }

    private var achievementsSection: some View {
        Section("Progress") {
            NavigationLink {
                AchievementsView()
            } label: {
                Label("Achievements", systemImage: "sparkles")
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Clear Unsaved History…", role: .destructive) {
                isShowingClearConfirmation = true
            }
        } footer: {
            Text(appVersionText)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "ClipStory \(version) (\(build))"
    }
}
