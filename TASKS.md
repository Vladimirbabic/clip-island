# ClipStory Task List

Last updated: 2026-06-10

This file is the source of truth for future work. If the user writes
`/task <idea>`, append the idea to **Inbox** with today's date. Do not build
new `/task` items unless the user explicitly asks to implement them now.

## Inbox

- [x] 2026-06-10: Allow mouse/trackpad scroll wheel gestures to move the macOS clip strip left and right.
- [x] 2026-06-10: Add selectable icons for Pinboards/Pages.
- [x] 2026-06-10: Explore issue where ClipStory is not showing up in the macOS toolbar/menu bar.
  - Hardened the status item: explicit visibility, stable width, image scaling, and text fallback.
  - Fresh Mac build was launched successfully; visually confirm icon placement in the menu bar.
- [x] 2026-06-10: Make iOS cards visually match the macOS cards more closely, including header color, source app icon, metadata/footer, selected state, and media/file previews.
- [x] 2026-06-10: Implement long-press arrow controls to switch the selected card.

## Now

- [ ] Verify pending iOS bottom fade tuning on device.
- [ ] Verify pending iOS image-file preview support after a new image file copy syncs from Mac.
- [ ] Verify iOS tap-to-copy and long-press "View Details" behavior.
- [ ] Improve iCloud sync freshness and visibility.
  - [x] Register for remote notifications on iOS.
  - [x] Add a visible "last updated/sync health" signal.
  - [ ] Test Mac -> iPhone and iPhone -> Mac latency with small text, image, and file-image clips.
- [ ] Keep the macOS island animation smooth.
  - Validate the current easing changes by running the app, not just building it.

## Next

- [x] OCR for images and screenshots.
  - [x] Index recognized text into searchable metadata.
  - [x] Make screenshots findable from search.
  - [x] Unlock Screenshot Sleuth from real OCR search.
- [x] Search filters.
  - [x] Filter by content type.
  - [x] Filter by source app.
  - [x] Filter by Page through the existing Page picker.
  - [x] Filter by date.
  - [x] Filter saved/pinned/OCR-backed clips.
- [x] Rich preview and editing.
  - [x] Preview action on Mac cards for text, links, images, and files.
  - [x] Better iOS detail page with OCR text.
  - [x] Rename clips.
  - [x] Edit text clips.
  - [x] Rotate image previews on iOS.
  - [x] Extract text from image previews after OCR lands.
- [x] Gamification layer.
  - [x] Achievements: First Rescue, Time Traveler, Page Builder, Prompt Library, Screenshot Sleuth, Cross-Device Relay, Clean Desk, AI Memory.
  - [x] Stats: clips, saved clips, Pages, searchable images.
  - [x] UI: iOS achievements screen, Mac Settings achievements section.
  - [x] Keep it productivity-focused; no loud popups during copy/paste.
- [ ] iOS capture integrations.
  - [ ] Share extension.
  - [ ] Action extension.
  - [x] Shortcuts actions for saving clipboard and creating notes.
  - [ ] Optional keyboard extension.

## Later

- [x] Local MCP server for AI tools.
  - [x] Let Claude/Codex search a local ClipStory JSON export.
  - [ ] Let AI organize clips into Pages.
  - [x] Keep local-only by default.
- [ ] Shared Pages.
  - [x] Design data model before implementation.
  - [x] Do not treat current Pages as shared until sync reliability is strong.
  - [ ] Implement CloudKit Sharing or backend-backed sharing.
- [ ] Team/collaboration features.
  - [x] Document privacy and data-model constraints.
  - [ ] Implement roles, invites, audit behavior, and shared storage.
- [ ] Distribution work.
  - [ ] TestFlight setup for iOS.
  - [ ] macOS notarization.
  - [x] Release build workflow.
  - [x] Privacy copy and onboarding notes.

## Parked / Not Now

- [ ] Full Paste-style collaboration. Park until personal sync is reliable.
- [ ] Heavy AI features that require cloud processing. Park until local MCP and privacy story are clear.
- [ ] Complex leaderboards or social gamification. ClipStory should reward personal productivity, not compete with other users.
- [ ] Big visual redesign before interaction reliability is finished.

## Done Recently

- [x] Wider macOS island and smaller macOS clipboard cards.
- [x] iCloud sync status chip on macOS.
- [x] Accessory-app paste target fix for Raycast/Alfred style UIs.
- [x] Faster macOS clipboard polling after Cmd-C.
- [x] Saved Pages are protected from "Clear Unsaved History".
- [x] iOS two-column grid direction inspired by competitor reference.
- [x] iOS tap-to-copy and long-press details behavior added locally.
- [x] macOS wheel/trackpad scroll moves selected cards left and right.
- [x] Page/Pinboard icons added across Mac and iOS.
- [x] iOS cards moved closer to the macOS card style.
- [x] iOS image thumbnails are clipped to fixed card preview bounds.
- [x] Holding arrow keys repeats selected-card navigation on macOS.
- [x] Local OCR makes screenshots and image-file previews searchable.
- [x] Structured filters added on Mac and iOS.
- [x] Clip rename/edit/preview actions added.
- [x] iOS Shortcuts actions added.
- [x] Achievements and stats added to iOS/Mac settings.
- [x] Local MCP JSON export/search groundwork added.
- [x] Distribution and shared-page design docs added.
