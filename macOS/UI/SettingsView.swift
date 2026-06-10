import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Content of the SwiftUI `Settings` scene. Reads `ClipStore` from the
/// environment; the host applies `.modelContainer` + `.environmentObject`.
@MainActor
struct SettingsView: View {
    @ObservedObject private var syncStatus: CloudSyncStatus

    @EnvironmentObject private var store: ClipStore
    @AppStorage(AppConstants.capturePausedKey) private var isCapturePaused = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginItemStatus = LaunchAtLogin.status
    @State private var launchAtLoginError: String?
    @State private var isAccessibilityTrusted = PasteService.isAccessibilityTrusted
    @State private var isShowingClearConfirmation = false
    /// `ClipStore` does not publish changes; bump this after writes so
    /// captions that read store state (synced limit) refresh.
    @State private var settingsRevision = 0

    /// Cheap periodic re-check so the Permissions row updates after the user
    /// grants access in System Settings (there is no notification for it),
    /// and the login-item status row updates after approval.
    private let statusRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(syncStatus: CloudSyncStatus) {
        _syncStatus = ObservedObject(wrappedValue: syncStatus)
    }

    var body: some View {
        Form {
            generalSection
            permissionsSection
            syncSection
            dataSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            loginItemStatus = LaunchAtLogin.status
            isAccessibilityTrusted = PasteService.isAccessibilityTrusted
        }
        .onReceive(statusRefresh) { _ in
            isAccessibilityTrusted = PasteService.isAccessibilityTrusted
            launchAtLogin = LaunchAtLogin.isEnabled
            loginItemStatus = LaunchAtLogin.status
        }
        .alert("Clear unsaved history?", isPresented: $isShowingClearConfirmation) {
            Button("Clear Unsaved History", role: .destructive) { store.clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned clips and clips saved to pages are kept. This cannot be undone.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
            if let launchAtLoginError {
                Label(launchAtLoginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if loginItemStatus == .requiresApproval {
                HStack {
                    Text("Waiting for your approval in Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items Settings") {
                        LaunchAtLogin.openLoginItemsSettings()
                    }
                }
            }

            Toggle("Pause clipboard capture", isOn: $isCapturePaused)

            Picker("History limit", selection: historyLimitBinding) {
                ForEach(AppConstants.historyLimitChoices, id: \.self) { limit in
                    Text("\(limit) items").tag(limit)
                }
            }
            Text("History keeps the newest \(store.historyLimit) unsaved clips. Pinned clips and saved pages are never removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !store.hasSyncedHistoryLimit {
                Text("Pruning is inactive until you choose a limit (synced across devices).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    launchAtLoginError = nil
                } catch {
                    let action = newValue ? "enable" : "disable"
                    launchAtLoginError = "Could not \(action) launch at login: \(error.localizedDescription)"
                }
                // Re-read so the toggle reflects reality (registration can
                // fail or land in .requiresApproval).
                launchAtLogin = LaunchAtLogin.isEnabled
                loginItemStatus = LaunchAtLogin.status
                settingsRevision += 1
            }
        )
    }

    private var historyLimitBinding: Binding<Int> {
        Binding(
            get: { store.historyLimit },
            set: { newValue in
                store.setHistoryLimit(newValue)
                settingsRevision += 1
            }
        )
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            LabeledContent("Accessibility") {
                if isAccessibilityTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 8) {
                        Text("Not granted")
                            .foregroundStyle(.secondary)
                        Button("Grant\u{2026}") {
                            PasteService.requestAccessibilityAccess()
                        }
                    }
                }
            }
            Text("Without Accessibility access, ClipStory still copies the selected clip but cannot paste it into other apps automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section("Sync") {
            LabeledContent("iCloud Sync") {
                Label(syncShortLabel, systemImage: syncSymbolName)
                    .foregroundStyle(syncLabelColor)
            }
            Text(syncStatus.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var syncShortLabel: String {
        switch syncStatus.state {
        case .syncing: return "On"
        case .noAccount: return "No account"
        case .localOnly: return "Off"
        case .ephemeral: return "Not saved"
        }
    }

    private var syncSymbolName: String {
        switch syncStatus.state {
        case .syncing: return "checkmark.icloud"
        case .noAccount: return "icloud.slash"
        case .localOnly: return "xmark.icloud"
        case .ephemeral: return "exclamationmark.icloud"
        }
    }

    private var syncLabelColor: Color {
        switch syncStatus.state {
        case .syncing: return .green
        case .noAccount: return .orange
        case .localOnly: return .secondary
        case .ephemeral: return .red
        }
    }

    // MARK: - Data & About

    private var dataSection: some View {
        Section("Data") {
            Button("Clear Unsaved History\u{2026}", role: .destructive) {
                isShowingClearConfirmation = true
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: versionText)
            LabeledContent("Hotkey", value: "\u{21E7}\u{2318}V opens the history panel")
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
