import AppKit
import Combine
import ServiceManagement
import SwiftData
import SwiftUI

/// Content of the SwiftUI `Settings` scene. Reads `ClipStore` from the
/// environment; the host applies `.modelContainer` + `.environmentObject`.
@MainActor
struct SettingsView: View {
    @ObservedObject private var syncStatus: CloudSyncStatus

    @EnvironmentObject private var store: ClipStore
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var items: [ClipItem]
    @Query(sort: [SortDescriptor(\Pinboard.sortOrder), SortDescriptor(\Pinboard.createdAt)])
    private var pinboards: [Pinboard]
    @AppStorage(AppConstants.capturePausedKey) private var isCapturePaused = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginItemStatus = LaunchAtLogin.status
    @State private var launchAtLoginError: String?
    @State private var isAccessibilityTrusted = PasteService.isAccessibilityTrusted
    @State private var isShowingClearConfirmation = false
    @State private var selectedPane: SettingsPane = .general
    @State private var syncProbeMessage: String?
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
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(SettingsTheme.divider)
                .frame(width: 1)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    selectedPaneSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }
        }
        .frame(width: 760, height: 600)
        .background(SettingsTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(SettingsTheme.accent)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarHeader

            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    SidebarItemButton(
                        pane: pane,
                        isSelected: selectedPane == pane
                    ) {
                        selectedPane = pane
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                Text("Sync")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.mutedText)
                    .textCase(.uppercase)
                StatusPill(title: syncShortLabel, systemImage: syncSymbolName, color: syncLabelColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .frame(width: 206)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsTheme.sidebarFill)
    }

    private var sidebarHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsTheme.accent.opacity(0.18))
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("ClipStory")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SettingsTheme.primaryText)
                Text("Settings")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var selectedPaneSection: some View {
        switch selectedPane {
        case .general:
            generalSection
        case .permissions:
            permissionsSection
        case .sync:
            syncSection
        case .progress:
            achievementsSection
        case .data:
            dataSection
        case .about:
            aboutSection
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection(title: "General", systemImage: "slider.horizontal.3", tint: .blue) {
            SettingsRow(
                title: "Launch at login",
                subtitle: loginItemStatus == .requiresApproval ? "Waiting for approval in Login Items." : "Start ClipStory when you sign in.",
                systemImage: "power",
                tint: .green
            ) {
                Toggle("", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if let launchAtLoginError {
                SettingsDivider()
                MessageRow(launchAtLoginError, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }

            if loginItemStatus == .requiresApproval {
                SettingsDivider()
                ActionRow(
                    title: "Login Items approval",
                    subtitle: "macOS needs approval before ClipStory can launch automatically.",
                    systemImage: "gear.badge",
                    tint: .orange,
                    buttonTitle: "Open Settings"
                ) {
                    LaunchAtLogin.openLoginItemsSettings()
                }
            }

            SettingsDivider()

            SettingsRow(
                title: "Pause clipboard capture",
                subtitle: "Temporarily stop saving new clipboard items.",
                systemImage: "pause.circle",
                tint: .orange
            ) {
                Toggle("", isOn: $isCapturePaused)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsDivider()

            SettingsRow(
                title: "History limit",
                subtitle: "Pinned clips and saved pages are never removed.",
                systemImage: "clock.arrow.circlepath",
                tint: .purple
            ) {
                Picker("", selection: historyLimitBinding) {
                    ForEach(AppConstants.historyLimitChoices, id: \.self) { limit in
                        Text("\(limit) items").tag(limit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 118)
            }

            if !store.hasSyncedHistoryLimit {
                SettingsDivider()
                MessageRow(
                    "Pruning is inactive until you choose a limit synced across devices.",
                    systemImage: "icloud.and.arrow.up",
                    tint: .orange
                )
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
        SettingsSection(title: "Permissions", systemImage: "hand.raised.fill", tint: .green) {
            SettingsRow(
                title: "Accessibility",
                subtitle: "Required only for automatic paste into other apps.",
                systemImage: "checkmark.shield",
                tint: isAccessibilityTrusted ? .green : .orange
            ) {
                if isAccessibilityTrusted {
                    StatusPill(title: "Granted", systemImage: "checkmark.circle.fill", color: .green)
                } else {
                    Button("Grant...") {
                        PasteService.requestAccessibilityAccess()
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        SettingsSection(title: "Sync", systemImage: "icloud.fill", tint: syncLabelColor) {
            SettingsRow(
                title: "iCloud Sync",
                subtitle: syncStatus.statusText,
                systemImage: syncSymbolName,
                tint: syncLabelColor
            ) {
                StatusPill(title: syncShortLabel, systemImage: syncSymbolName, color: syncLabelColor)
            }

            SettingsDivider()

            SettingsRow(
                title: "Environment",
                subtitle: "CloudKit database used by this build.",
                systemImage: "server.rack",
                tint: .teal
            ) {
                Text(cloudKitEnvironmentText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondaryText)
            }

            SettingsDivider()

            SettingsRow(
                title: "Freshness",
                subtitle: "Last observed CloudKit activity.",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .blue
            ) {
                Text(syncStatus.freshnessText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.secondaryText)
            }

            SettingsDivider()

            ActionRow(
                title: "Sync Test Clip",
                subtitle: syncProbeMessage ?? syncProbeSubtitle,
                systemImage: "waveform.path.ecg",
                tint: .purple,
                buttonTitle: "Create"
            ) {
                createSyncProbe()
            }

            SettingsDivider()

            ActionRow(
                title: "Clean Test Clips",
                subtitle: "Remove ClipStory sync-check markers from history.",
                systemImage: "trash.circle",
                tint: .orange,
                buttonTitle: "Clean"
            ) {
                store.deleteSyncProbes()
                syncProbeMessage = "Removed sync test clips."
                settingsRevision += 1
            }
        }
    }

    private var syncProbeSubtitle: String {
        _ = settingsRevision
        return store.syncProbeSummary()
    }

    private var cloudKitEnvironmentText: String {
        Bundle.main.object(forInfoDictionaryKey: "ClipStoryCloudKitEnvironment") as? String ?? "Unknown"
    }

    private func createSyncProbe() {
        guard store.createSyncProbe(origin: "Mac") != nil else {
            syncProbeMessage = "Could not create a sync test clip."
            return
        }
        syncProbeMessage = "Created a Mac sync test clip. Open ClipStory on iPhone and refresh."
        settingsRevision += 1
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
        case .localOnly: return SettingsTheme.secondaryText
        case .ephemeral: return .red
        }
    }

    // MARK: - Data & About

    private var achievementsSection: some View {
        let achievements = AchievementCatalog.achievements(items: items, pinboards: pinboards)
        let unlocked = achievements.filter(\.isUnlocked).count

        return SettingsSection(title: "Progress", systemImage: "rosette", tint: SettingsTheme.accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "sparkles", tint: SettingsTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Achievements")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(SettingsTheme.primaryText)
                            Spacer()
                            Text("\(unlocked) / \(achievements.count)")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(SettingsTheme.secondaryText)
                        }
                        ProgressView(value: Double(unlocked), total: Double(max(achievements.count, 1)))
                            .progressViewStyle(.linear)
                            .tint(SettingsTheme.accent)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                VStack(spacing: 8) {
                    ForEach(achievements.prefix(4)) { achievement in
                        AchievementRow(achievement: achievement)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private var dataSection: some View {
        SettingsSection(title: "Data", systemImage: "externaldrive.fill", tint: .cyan) {
            ActionRow(
                title: "Export JSON",
                subtitle: "Save clips and pages to a local archive.",
                systemImage: "square.and.arrow.up",
                tint: .cyan,
                buttonTitle: "Export"
            ) {
                ClipExporter.exportJSON(items: items, pinboards: pinboards)
            }

            SettingsDivider()

            ActionRow(
                title: "Clear Unsaved History",
                subtitle: "Pinned clips and saved pages are kept.",
                systemImage: "trash",
                tint: .red,
                buttonTitle: "Clear",
                isDestructive: true
            ) {
                isShowingClearConfirmation = true
            }
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "About", systemImage: "info.circle.fill", tint: .gray) {
            SettingsRow(
                title: "Version",
                subtitle: versionText,
                systemImage: "number",
                tint: SettingsTheme.secondaryText
            ) {
                EmptyView()
            }

            SettingsDivider()

            SettingsRow(
                title: "Hotkey",
                subtitle: "\u{21E7}\u{2318}V opens the history panel.",
                systemImage: "keyboard",
                tint: SettingsTheme.secondaryText
            ) {
                EmptyView()
            }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Settings Components

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case permissions
    case sync
    case progress
    case data
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .permissions: return "Permissions"
        case .sync: return "Sync"
        case .progress: return "Progress"
        case .data: return "Data"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .permissions: return "hand.raised.fill"
        case .sync: return "icloud.fill"
        case .progress: return "rosette"
        case .data: return "externaldrive.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .blue
        case .permissions: return .green
        case .sync: return .green
        case .progress: return SettingsTheme.accent
        case .data: return .cyan
        case .about: return SettingsTheme.secondaryText
        }
    }
}

private enum SettingsTheme {
    static let background = Color.black
    static let sidebarFill = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255)
    static let sectionFill = Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255)
    static let rowFill = Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x1A / 255)
    static let stroke = Color.white.opacity(0.07)
    static let divider = Color.white.opacity(0.06)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.58)
    static let mutedText = Color.white.opacity(0.38)
    static let accent = Color(red: 0.78, green: 0.22, blue: 0.88)
}

private struct SidebarItemButton: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? pane.tint : SettingsTheme.secondaryText)
                    .frame(width: 18)
                Text(pane.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? SettingsTheme.primaryText : SettingsTheme.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SettingsTheme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .background(SettingsTheme.sectionFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsTheme.stroke, lineWidth: 1)
            }
        }
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(systemImage: systemImage, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primaryText)
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(SettingsTheme.rowFill.opacity(0.45))
    }
}

private struct ActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let buttonTitle: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint) {
            Button(buttonTitle, action: action)
                .buttonStyle(SettingsButtonStyle(kind: isDestructive ? .destructive : .normal))
        }
    }
}

private struct MessageRow: View {
    let message: String
    let systemImage: String
    let tint: Color

    init(_ message: String, systemImage: String, tint: Color) {
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SettingsTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsTheme.divider)
            .frame(height: 1)
            .padding(.leading, 62)
    }
}

private struct IconBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.16))
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 32, height: 32)
    }
}

private struct StatusPill: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.24), lineWidth: 1)
            }
    }
}

private struct AchievementRow: View {
    let achievement: ClipAchievement

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: achievement.isUnlocked ? "checkmark.circle.fill" : "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(achievement.isUnlocked ? Color.green : SettingsTheme.mutedText)
                .frame(width: 18)
            Text(achievement.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(achievement.isUnlocked ? SettingsTheme.primaryText : SettingsTheme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case destructive
    }

    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        let color = kind == .destructive ? Color.red : SettingsTheme.primaryText
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(buttonFill(isPressed: configuration.isPressed), in: Capsule())
            .overlay {
                Capsule().stroke(buttonStroke, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private func buttonFill(isPressed: Bool) -> Color {
        switch kind {
        case .normal:
            return Color.white.opacity(isPressed ? 0.16 : 0.10)
        case .destructive:
            return Color.red.opacity(isPressed ? 0.30 : 0.20)
        }
    }

    private var buttonStroke: Color {
        switch kind {
        case .normal:
            return Color.white.opacity(0.12)
        case .destructive:
            return Color.red.opacity(0.32)
        }
    }
}
