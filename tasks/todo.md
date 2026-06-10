# ClipStory — Paste (pasteapp.io) rebuild

Goal: free, self-owned clipboard manager for macOS + iOS, synced via iCloud (CloudKit). No subscription.

## Plan

- [x] Skeleton: project.yml (XcodeGen), entitlements, Info.plist keys
- [x] Shared layer (inline): ClipItem @Model, ModelContainerFactory, ClipContent kind, dedup hash, search filter, prune logic
- [x] Workflow fan-out:
  - [x] macOS app: AppDelegate, ClipboardMonitor (NSPasteboard polling), PasteService (CGEvent ⌘V), Carbon HotKey, bottom NSPanel + SwiftUI history cards, Settings, LaunchAtLogin
  - [x] iOS app: history list + search + pin + copy + save-clipboard, detail view
  - [x] Unit tests for shared logic (dedup, search, prune) — 34 tests, all green
  - [x] README (setup: team ID, iCloud container, permissions) + .gitignore
- [x] Build verification: macOS build ✓, iOS sim build ✓, tests ✓ (first try, no fix loop needed)
- [x] Adversarial review workflow (5 lenses → skeptic per finding): 17 confirmed / 4 refuted / 6 low — ALL confirmed + low fixed
- [x] Paste-style redesign (reference screenshot): colored app-color card headers + app icons, pinboard
      tab strip, ⌘1–9 quick-paste badges, link previews (LinkPresentation), dimension badges, selection ring
- [x] Pinboards: synced Pinboard @Model, mac tabs (rename/color/delete), iOS chips, assignment menus
- [x] Rebuild + re-test after fixes: mac ✓, iOS ✓, 6/6 test suites ✓
- [x] Visual verification: --demo-data --show-panel + screencapture vs reference ✓
- [x] Commit

## Review

- Critical fix shipped: history limit is now a *synced* AppSettings record; pruning is disabled until one
  syncs in (prevents a fresh device's 500 default from deleting another device's 2000-limit history).
- Cross-device dedupe sweep (deterministic keeper: newest createdAt, tie → smallest dedupID) runs on
  panel-show (mac) and foreground (iOS).
- Paste race fixed (synchronous orderOut before CGEvent ⌘V); multi-file capture; text+image dual flavors;
  concealed-type guard on BOTH platforms (shared constant); async image encode off main; thumbnails via
  ImageIO downsampling; honest 4-state sync status incl. iCloud sign-out detection.

## Known debt (non-blocking)

- PasteService duplicates PasteboardWriter's flavor-writing logic; should adopt PasteboardWriter.write
  and subscribe to "clipstory.ownPasteboardWrite" so context-menu Copy is also self-write-suppressed
  (today a re-capture just dedup-bumps — harmless).
- Chrome's dominant-icon-color header renders muddy olive (icon averages); could special-case browsers.
- Text+image capture drops the whole clip if PNG encode fails (could fall back to text-only).
- LinkMetadataService fetches og-data only on macOS; iOS displays what synced.

## Key constraints

- SwiftData + CloudKit: all properties optional or defaulted, relationships optional, no `.unique`
- Ignore transient/concealed pasteboard types (password managers)
- Hotkey via Carbon RegisterEventHotKey (no Input Monitoring permission)
- Paste-into-app needs Accessibility permission; degrade to copy-only
- iOS cannot monitor clipboard in background (platform restriction)

## Review

(filled after verification)
