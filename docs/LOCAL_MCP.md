# ClipStory Local MCP

ClipStory can export a searchable JSON file from macOS Settings, then a local
MCP server can expose that export to AI tools.

1. Open ClipStory Settings on macOS.
2. Click **Export JSON...** in Data.
3. Save the file as `clipstory-export.json`.
4. Start the MCP server:

```sh
CLIPSTORY_EXPORT_PATH=/path/to/clipstory-export.json ./tools/clipstory_mcp_server.py
```

The server exposes one tool, `search_clips`, which searches clip text, OCR text,
file names, source apps, kinds, titles, and page names.

This is intentionally local/export-based for now. Live SwiftData access should
only be added once there is a stable read-only store bridge that cannot mutate
clipboard history.
