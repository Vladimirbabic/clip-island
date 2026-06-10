# ClipStory

A free, self-hosted rebuild of [Paste](https://pasteapp.io) for macOS and iOS. Your clipboard
history, synced through your own iCloud account via CloudKit — no subscription, no third-party
servers.

## Features

- Menu-bar history panel on macOS, opened with **⇧⌘V**
- Instant search across text, file names, source app, and content type
- Pin items so they survive history pruning and "Clear History"
- Paste directly into the frontmost app (or just copy, without extra permissions)
- Captures text, links, images, and file references — with the source app recorded
- iOS companion app with the same history, search, and pins
- CloudKit **private database** sync: data lives only in your iCloud, never on anyone else's server

## Requirements

- macOS 14+ (Sonoma), iOS 17+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- An **Apple Developer Program membership** ($99/yr) if you want:
  - CloudKit sync — free accounts don't get the iCloud/CloudKit entitlement
  - Apps on a physical iPhone for more than 7 days — free provisioning profiles expire weekly

Without a paid account the macOS app still works fully **local-only** (it detects the missing
entitlement and falls back to on-device storage automatically), and you can run the iOS app in
the Simulator or re-install it on your phone every 7 days.

## Setup

1. Edit `project.yml`: set `DEVELOPMENT_TEAM` to your team ID and change the
   `bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER` values to your own reverse-DNS prefix.
2. **Important:** pick a unique iCloud container ID and replace
   `iCloud.com.vladbabic.clipstory` in **all three** places:
   - `macOS/ClipStory.entitlements`
   - `iOS/ClipStory-iOS.entitlements`
   - `Shared/Persistence/ModelContainerFactory.swift` (`cloudKitContainerID`)
3. Generate the project:
   ```sh
   xcodegen generate
   ```
4. Open `ClipStory.xcodeproj`, select your team for all three targets if Xcode asks, then
   build & run scheme **ClipStory** (Mac) or **ClipStory-iOS** (iPhone/Simulator).

## Permissions (macOS)

- **Accessibility** (System Settings → Privacy & Security → Accessibility) is needed only for
  *auto-paste* — sending the paste keystroke into the frontmost app. Without it, ClipStory
  still copies the selected item to the clipboard; you press ⌘V yourself.
- **No Input Monitoring** permission is required: the global hotkey uses the Carbon hotkey API,
  not an event tap.

## Sync Notes

- Personal builds run against the CloudKit **development** environment, which is fine for your
  own devices. If the app ever ships, deploy the schema to **production** in the
  [CloudKit Console](https://icloud.developer.apple.com).
- The first sync can take a minute or so; subsequent changes propagate quickly via push.
- Both devices must be signed into the **same iCloud account** with iCloud Drive enabled.
- If CloudKit is unavailable (no entitlement, signed out of iCloud), the app falls back to a
  local-only store and keeps working — the UI indicates that sync is off.

## iOS Limitations

Apple does not allow apps to read the clipboard in the background on iOS. The iOS app saves
the current clipboard when you tap **+** (or, optionally, when the app opens) — exactly how
the real Paste app works. Continuous capture only exists on macOS.

## Privacy

- Pasteboard contents marked **concealed** or **transient** (passwords from 1Password,
  Keychain, etc.) are never captured.
- All data is stored on-device and, when sync is enabled, in your iCloud private database.
  Nothing is sent anywhere else.

## Project Structure

```
clipstory/
├── project.yml          # XcodeGen spec — the .xcodeproj is generated, not committed
├── Shared/              # Cross-platform: models, persistence, search, pruning
│   ├── Models/          #   ClipItem (@Model), ClipKind, CapturedContent
│   ├── Persistence/     #   ClipStore, ModelContainerFactory (CloudKit/local fallback)
│   └── Logic/           #   ClipSearch, HistoryPruner, ContentHasher
├── macOS/               # Menu-bar app: capture engine, hotkey, panel UI
├── iOS/                 # Companion app: history list, manual save
└── Tests/               # Unit tests (run via the ClipStory scheme)
```

## Usage

- **⇧⌘V** — open/close the history panel (macOS)
- **Click** an item to copy it; **double-click** to copy *and* paste into the frontmost app
  (auto-paste requires Accessibility permission)
- **Pin** items to keep them forever — pinned items are exempt from pruning and Clear History
- **Search** with space-separated tokens; all must match (item text, file name, source app, or
  kind name — e.g. `link github`), case- and diacritic-insensitive
- **History limit** — unpinned history is pruned to the newest 500 items by default
  (configurable in settings, stored under the `historyLimit` UserDefaults key)
- **Pause capture** — temporarily stop recording the clipboard from the menu (macOS)
