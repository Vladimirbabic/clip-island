# Agent Notes

Before implementing product work, read `TASKS.md`.

## `/task` Convention

When the user writes `/task <idea>`:

1. Append the idea to the `Inbox` section of `TASKS.md`.
2. Include the current date.
3. Confirm that it was added.
4. Do not implement it unless the user explicitly says to build it now.

If the user writes `/task now <idea>` or otherwise clearly asks for immediate
implementation, add it to `TASKS.md` and then proceed with the work.

## Prioritization

Respect the task sections:

- `Now`: reliability and active polish work.
- `Next`: high-value product features after reliability is stable.
- `Later`: large strategic features.
- `Parked / Not Now`: ideas that should stay out of implementation unless the
  user explicitly reactivates them.

Avoid starting parked items just because they are interesting. ClipStory's
current priority is reliable capture, reliable sync, fast search, and a clean
Mac/iOS workflow.

