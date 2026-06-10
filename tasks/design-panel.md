# Panel redesign spec — match Paste's look (reference: ~/.claude/image-cache/9cb63323-f726-4131-8b3b-eec0a8f41855/1.png)

## Layout

- Full-width bottom panel, dark translucent (existing VisualEffectView, hudWindow material),
  rounded TOP corners only (~16pt), height ~340pt.
- Top bar (~52pt), contents CENTERED as a group:
  - Search: magnifying-glass icon button at left of the tab group. Clicking it (or typing any
    character while the panel is key) expands an inline search field in its place; Esc collapses
    (second Esc hides panel).
  - Tab strip:
    - "Clipboard History" tab: pill with gray fill when selected (white ~12% opacity), SF Symbol
      "clock.arrow.circlepath" + label, white text. Unselected tabs have no pill fill.
    - One tab per Pinboard: 9pt colored dot + name. Selected = same gray pill.
    - "+" button after the last tab → creates pinboard "Untitled", immediately editable (rename).
    - Tab context menu: Rename…, Color submenu (8 named colors), Delete Pinboard.
  - Far right: "…" (ellipsis) button → menu: Pause/Resume Capture, Clear Unpinned History…, Settings…, Quit.

## Cards

- ~200pt wide × 240pt tall, corner radius 14, horizontal scroll, 12pt gaps, 16pt side padding.
- Card background: very dark gray (≈ #1E1E20, NOT pure black).
- Header (~46pt): leading-aligned 2 lines: kind title ("Text" / "Link" / "Image" / "File") 14pt
  semibold white; relative time below ("7 minutes ago") 11pt white 75%.
  - Top-right: source app icon 26pt (lookup via NSWorkspace urlForApplication(withBundleIdentifier:)
    → NSWorkspace.icon(forFile:), cached by bundleID; fallback generic clipboard glyph).
  - Header background = dominant color of the app icon (average color of downsampled icon bitmap,
    cached by bundleID), fallback: stable hash palette (magenta, blue, purple, orange, teal, pink,
    indigo, red — saturated, Paste-like). Subtle vertical gradient (color → color darkened 15%).
- Body:
  - text: white 90% 12.5pt, up to 9 lines, top-leading, 10pt padding.
  - url: if linkTitle/og-image fetched (LinkPresentation at insert time on macOS): thumbnail fills
    upper body + bold title below; else link icon + URL text.
  - image: image fills body (scaledToFill, clipped) + bottom-trailing capsule badge "W × H"
    (ultraThinMaterial dark).
  - file: large file icon + fileName centered.
- Footer (~24pt): left "N characters" (thousands separator, e.g. "1.545 characters" — use
  NumberFormatter localized) 11pt white 60%; right: quick-paste badge "≡ n" (list.dash symbol + index)
  for the first 9 visible cards.
- Selected card: 3pt accent-blue rounded ring (#3478F6) with 2pt inset gap; first card selected by default.

## Behavior

- ⌘1…⌘9 pastes the Nth visible card. Return pastes selection; double-click pastes; single click selects.
- Card context menu: Paste, Copy, Add to Pinboard ▸ (list + "New Pinboard…"), Remove from Pinboard
  (only when assigned), Delete.
- Tabs filter: Clipboard History = items with pinboard == nil (chronological); a pinboard tab shows its
  items. Search filters within the active tab.
- Launch argument "--show-panel" opens the panel at startup (for screenshot-based UI verification).

## Data model (Shared)

- New @Model Pinboard: name (default ""), colorName (default "magenta"), sortOrder Int default 0,
  createdAt default now. items: [ClipItem]? optional inverse. CloudKit rules: all defaulted/optional,
  no unique.
- ClipItem additions: pinboard: Pinboard? (optional relationship, nullify), linkTitle: String?
  (og:title for url items). CloudKit-safe (optional, additive).
- isPinned stays in the model for compatibility but UI/pruning now use pinboard membership:
  HistoryPruner protects items where isPinned OR pinboard != nil. ClipStore.clearUnpinned keeps those.
- ClipStore new ops: createPinboard(named:) -> Pinboard, rename, setColor, deletePinboard (items'
  pinboard → nil), assign(_ item, to pinboard?), pinboards fetch sorted by sortOrder/createdAt.

## iOS (keep native, minimal parity)

- Horizontal chip row under the nav title: "History" + pinboard chips (colored dot + name) switching
  the filtered list; chips scroll horizontally.
- Context menu + detail toolbar: "Add to Pinboard ▸" menu (+ "Remove from Pinboard").
- Swipe leading becomes Add-to-first-pinboard? NO — keep swipe leading as quick "Remove/Add to
  pinboard" is ambiguous; change leading swipe to nothing and keep Delete trailing; pinboard
  assignment via context menu/detail only.
- Empty states updated to mention pinboards.
