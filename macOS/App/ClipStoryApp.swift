import AppKit
import OSLog
import SwiftData
import SwiftUI

/// App-wide services created once on the main thread and shared between the
/// AppKit world (`AppDelegate`, panel, monitor) and the SwiftUI `Settings`
/// scene. Both sides must see the same store and model container.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let persistence: PersistenceSetup
    let store: ClipStore
    let syncStatus: CloudSyncStatus

    var container: ModelContainer { persistence.container }

    private init() {
        persistence = Self.makePersistence()
        store = ClipStore(container: persistence.container)
        syncStatus = CloudSyncStatus(mode: persistence.mode)
    }

    /// `--demo-data` runs against a volatile in-memory store so screenshots
    /// and UI verification never touch (or sync) real history. `AppDelegate`
    /// double-checks the resulting mode before seeding.
    private static func makePersistence() -> PersistenceSetup {
        if ProcessInfo.processInfo.arguments.contains("--demo-data") {
            do {
                let container = try ModelContainerFactory.makeInMemory()
                return PersistenceSetup(container: container, mode: .inMemory)
            } catch {
                Logger(subsystem: "com.vladbabic.clipstory", category: "app")
                    .error("Demo in-memory container failed, using the regular store: \(error)")
            }
        }
        return ModelContainerFactory.makeShared()
    }
}

/// ClipStory runs as an LSUIElement menu-bar agent. All primary UI (status
/// item, history panel) is owned by `AppDelegate`; the only SwiftUI scene is
/// the Settings window.
@main
struct ClipStoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(syncStatus: AppEnvironment.shared.syncStatus)
                .environmentObject(AppEnvironment.shared.store)
                .modelContainer(AppEnvironment.shared.container)
        }
    }
}

/// Seeds the in-memory demo store (`--demo-data`) with clips matching the
/// design-reference screenshot: ordered, backdated, and pinboard-assigned.
@MainActor
enum DemoDataSeeder {
    static func seed(into store: ClipStore) {
        let slackAlert = store.insert(CapturedContent(
            kind: .text,
            text: opsAlertText,
            sourceAppName: "Slack",
            sourceAppBundleID: "com.tinyspeck.slackmacgap"
        ))

        let pasteLink = store.insert(CapturedContent(
            kind: .url,
            text: "https://pasteapp.io",
            sourceAppName: "Google Chrome",
            sourceAppBundleID: "com.google.Chrome"
        ))
        if let pasteLink {
            store.updateLinkMetadata(
                for: pasteLink,
                title: "The Best Clipboard Manager for Mac & iOS",
                imageData: nil
            )
        }

        let claudeCommand = store.insert(CapturedContent(
            kind: .text,
            text: "claude --dangerously-skip-permissions",
            sourceAppName: "Terminal",
            sourceAppBundleID: "com.apple.Terminal"
        ))

        let codexCommand = store.insert(CapturedContent(
            kind: .text,
            text: "codex --yolo",
            sourceAppName: "Terminal",
            sourceAppBundleID: "com.apple.Terminal"
        ))

        var formImage: ClipItem?
        if let pngData = demoFormImagePNG() {
            formImage = store.insert(CapturedContent(
                kind: .image,
                imageData: pngData,
                sourceAppName: "Safari",
                sourceAppBundleID: "com.apple.Safari"
            ))
        }

        let notesReminder = store.insert(CapturedContent(
            kind: .text,
            text: notesText,
            sourceAppName: "Notes",
            sourceAppBundleID: "com.apple.Notes"
        ))

        // Backdate so the panel ordering matches the reference screenshot.
        let now = Date()
        backdate(slackAlert, minutesAgo: 7, from: now)
        backdate(pasteLink, minutesAgo: 34, from: now)
        backdate(claudeCommand, minutesAgo: 35, from: now)
        backdate(codexCommand, minutesAgo: 60, from: now)
        backdate(formImage, minutesAgo: 60, from: now)
        backdate(notesReminder, minutesAgo: 65, from: now)
        store.save()

        let codingSnippets = store.createPinboard(named: "Coding Snippets", colorName: "magenta")
        store.createPinboard(named: "Builder", colorName: "blue")
        if let claudeCommand, let codingSnippets {
            store.assign(claudeCommand, to: codingSnippets)
        }
    }

    private static func backdate(_ item: ClipItem?, minutesAgo: Int, from reference: Date) {
        item?.createdAt = reference.addingTimeInterval(TimeInterval(-minutesAgo * 60))
    }

    // MARK: - Demo content

    private static let opsAlertText = """
    Chief Ops Alert — Sync Freshness Degraded

    Severity: SEV-2 · Opened 06:42 UTC · Owner: @data-platform-oncall

    14 sync groups have no fresh row-level sync marker in over 10 hours. The \
    affected connectors are google-calendar/calendar_event and \
    hubspot/crm_contact. Watermarks stopped advancing after the 20:31 UTC \
    deploy of ingest-worker v2.41.0; backfill cursors are parked and retry \
    queues are draining into the dead-letter topic at roughly 1.2k events/min.

    User impact: CRM- and calendar-backed content may be stale for affected \
    orgs. Accounts that read calendar_event rows for availability will \
    quietly show yesterday's slots, and lifecycle automations keyed on \
    crm_contact.updated_at will not fire until the markers advance again.

    Mitigation so far: rolled ingest-worker back to v2.40.3 on the canary \
    pool at 07:05 UTC — markers on canary resumed advancing within four \
    minutes. Full-fleet rollback is gated on the change-freeze exception \
    (ticket OPS-4117, awaiting one more approval). Replay of the dead-letter \
    topic is staged but NOT started; do not trigger it before the rollback \
    lands or we will double-apply mutations to downstream rows.

    Watchdog alerts for marker lag are snoozed until 09:00 UTC so the channel \
    is not flooded; re-arm them if the rollback slips past that window.

    Next update at 08:00 UTC or sooner if state changes. Thread in \
    #inc-sync-freshness; page data-platform-oncall for anything \
    customer-visible. Runbook: go/runbook-sync-freshness · Dashboard: \
    go/grafana-sync-markers.
    """

    private static let notesText = """
    Pick up the dry cleaning before 6, book the dentist for Thursday \
    morning, and move the design sync to 2pm. Groceries: oat milk, basil, \
    lemons, parmesan, sourdough. Mia's recital is Friday!
    """

    /// 620x649 two-tone gradient with white rounded rectangles suggesting a
    /// web form, PNG-encoded — stands in for a "copied from Safari" image.
    private static func demoFormImagePNG() -> Data? {
        let size = NSSize(width: 620, height: 649)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let gradient = NSGradient(
                starting: NSColor(srgbRed: 0.15, green: 0.16, blue: 0.21, alpha: 1),
                ending: NSColor(srgbRed: 0.36, green: 0.32, blue: 0.52, alpha: 1)
            ) else { return false }
            gradient.draw(in: rect, angle: -90)

            NSColor(white: 1, alpha: 0.94).setFill()
            let fieldRects = [
                NSRect(x: 60, y: 96, width: 320, height: 30),
                NSRect(x: 60, y: 150, width: 500, height: 54),
                NSRect(x: 60, y: 232, width: 500, height: 54),
                NSRect(x: 60, y: 314, width: 237, height: 54),
                NSRect(x: 323, y: 314, width: 237, height: 54),
                NSRect(x: 60, y: 396, width: 500, height: 110),
                NSRect(x: 60, y: 534, width: 180, height: 48),
            ]
            for fieldRect in fieldRects {
                NSBezierPath(roundedRect: fieldRect, xRadius: 10, yRadius: 10).fill()
            }
            return true
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
