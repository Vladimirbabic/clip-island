#!/usr/bin/env python3
"""Tiny local MCP server for searching a ClipStory JSON export.

Set CLIPSTORY_EXPORT_PATH to the JSON file exported from Mac Settings, or put
`clipstory-export.json` in the current directory before starting the server.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


def export_path() -> Path:
    return Path(os.environ.get("CLIPSTORY_EXPORT_PATH", "clipstory-export.json")).expanduser()


def load_clips() -> list[dict[str, Any]]:
    path = export_path()
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return list(payload.get("clips", []))


def search_clips(query: str, limit: int = 10) -> list[dict[str, Any]]:
    tokens = [part.casefold() for part in query.split() if part.strip()]
    matches: list[dict[str, Any]] = []
    for clip in load_clips():
        haystack = "\n".join(
            str(clip.get(key) or "")
            for key in [
                "title",
                "text",
                "recognizedText",
                "fileName",
                "sourceAppName",
                "kind",
                "pageName",
            ]
        ).casefold()
        if all(token in haystack for token in tokens):
            matches.append(clip)
            if len(matches) >= limit:
                break
    return matches


def respond(message_id: Any, result: Any) -> None:
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message_id, "result": result}) + "\n")
    sys.stdout.flush()


def respond_error(message_id: Any, code: int, message: str) -> None:
    sys.stdout.write(
        json.dumps({"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}) + "\n"
    )
    sys.stdout.flush()


def handle(request: dict[str, Any]) -> None:
    method = request.get("method")
    message_id = request.get("id")
    if method == "initialize":
        respond(
            message_id,
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "clipstory-local", "version": "0.1.0"},
            },
        )
    elif method == "tools/list":
        respond(
            message_id,
            {
                "tools": [
                    {
                        "name": "search_clips",
                        "description": "Search a local ClipStory JSON export.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "query": {"type": "string"},
                                "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                            },
                            "required": ["query"],
                        },
                    }
                ]
            },
        )
    elif method == "tools/call":
        params = request.get("params", {})
        if params.get("name") != "search_clips":
            respond_error(message_id, -32601, "Unknown tool")
            return
        args = params.get("arguments", {})
        clips = search_clips(str(args.get("query", "")), int(args.get("limit", 10)))
        respond(message_id, {"content": [{"type": "text", "text": json.dumps(clips, indent=2)}]})
    elif message_id is not None:
        respond_error(message_id, -32601, "Unknown method")


def main() -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            handle(json.loads(line))
        except Exception as exc:
            respond_error(None, -32603, str(exc))


if __name__ == "__main__":
    main()
