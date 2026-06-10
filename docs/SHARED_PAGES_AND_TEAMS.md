# Shared Pages And Teams

Shared Pages should not be bolted onto the current private CloudKit model. The
current app stores personal history in the user's private database, which is the
right default for clipboard privacy.

## Recommended Path

1. Keep personal Pages private by default.
2. Add an explicit `SharedPage` model only after sync freshness is reliable.
3. Use CloudKit Sharing for personal-to-person sharing if the product should
   remain self-owned and Apple-only.
4. Use a backend only if teams need roles, audit logs, admin controls, or
   non-Apple accounts.

## Data Model Direction

- `SharedPage`
  - name
  - colorName
  - iconName
  - ownerDisplayName
  - createdAt
  - updatedAt
  - shareState

- `SharedClipReference`
  - sharedPage
  - originalClipID
  - title snapshot
  - text snapshot
  - file metadata snapshot
  - createdAt

Do not share raw clipboard history automatically. A clip should be copied into a
shared page only after explicit user action.

## Safety Rules

- Never auto-share clipboard capture.
- Do not sync concealed/transient data.
- Show shared state clearly on every shared clip.
- Make leaving/unsharing reversible where CloudKit allows it.
- Keep team/collaboration out of MVP distribution until personal sync is solid.
