#!/usr/bin/env python3
"""Render Claude Code's stream-json into a log a person can read.

We ask the CLI for stream-json because /goal prints nothing under the default
text output until its condition is met, which makes a long run and a hung run
look identical. The cost is that every line is a full API envelope - model,
usage, cache counters, uuids, request ids - around the one field that matters.

This reads that stream on stdin and writes the readable form on stdout. The
raw JSON is deliberately not kept: it is mostly envelope, tool results are
routinely megabytes, and nothing downstream reads it.

What survives:
  - the agent's prose, in full: it is the story of the run
  - each tool call as one line, with the command or path it acted on
  - tool results collapsed to a line count, except failures, which print
  - the final status, with duration, turns and cost
  - API errors, which is how an invalid key or a rate limit shows up

What does not: thinking blocks, token accounting, ids, and the init banner's
inventory of every agent and skill installed.

Anything that is not Claude's stream-json - a plain line from codex or agy, a
shell error, a partial line - passes through untouched. This runs inside the
pipeline that produces the log, so it must never be the reason output is lost.
"""

import json
import sys
from datetime import datetime

# A tool result rarely needs to be read in full; when it does, it is because
# the command failed. Successes collapse to a count.
ERROR_RESULT_LINES = 15
COMMAND_WIDTH = 100
INDENT = " " * 22


def stamp(raw: str) -> str:
    """HH:MM:SS in local time, or spaces when the event carries no timestamp."""
    if not raw:
        return "        "
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return parsed.astimezone().strftime("%H:%M:%S")
    except (ValueError, TypeError):
        return "        "


def elide(text: str, width: int = COMMAND_WIDTH) -> str:
    """Shorten from the middle.

    A long command is usually several joined by &&, and both ends carry
    meaning: what it started with and what it ended up doing. Cutting the tail
    would hide the latter.
    """
    text = " ".join(text.split())
    if len(text) <= width:
        return text
    half = (width - 3) // 2
    return f"{text[:half]}…{text[-half:]}"


def describe_tool(name: str, args: dict) -> tuple[str, str]:
    """One line for a tool call: a subject, and the detail worth a second line.

    Bodies are never shown - Write content and Edit replacements are the bulk
    of the stream, and the path is what identifies the action.
    """
    lower = (name or "").lower()
    description = (args.get("description") or "").strip()

    if lower == "bash":
        return description or "command", elide(args.get("command", ""))
    if lower in ("read", "edit", "write", "notebookedit"):
        subject = args.get("file_path") or args.get("notebook_path") or ""
        return subject, description
    if lower in ("grep", "glob"):
        pattern = args.get("pattern", "")
        path = args.get("path", "")
        return f"{pattern} {('in ' + path) if path else ''}".strip(), description
    if lower in ("webfetch", "websearch"):
        return args.get("url") or args.get("query", ""), description
    if lower in ("task", "agent"):
        return description or args.get("subagent_type", ""), ""
    if lower == "todowrite":
        todos = args.get("todos") or []
        active = next(
            (t.get("content", "") for t in todos if t.get("status") == "in_progress"),
            "",
        )
        return f"{len(todos)} items", active

    # An unknown tool still gets a useful line: its description, or the first
    # short scalar argument, rather than a dump of everything it was given.
    if description:
        return description, ""
    for value in args.values():
        if isinstance(value, str) and len(value) < 120:
            return value, ""
    return "", ""


def emit(time_str: str, glyph: str, label: str, detail: str = "") -> None:
    """One event, one line: time, glyph, a short column for the kind, detail.

    Prose carries no label and must not be pushed across the column, or the
    thing worth reading starts further right than everything else.
    """
    if label:
        head = f"{label:<7} " if len(label) <= 7 else f"{label} "
    else:
        head = ""
    print(f"{time_str}  {glyph}  {head}{detail}".rstrip(), flush=True)


def render(event: dict) -> None:
    kind = event.get("type")
    when = stamp(event.get("timestamp", ""))

    if kind == "system":
        # The init banner lists every agent, skill and socket. Three fields
        # from it are worth keeping.
        if event.get("subtype") == "init" or "session_id" in event:
            model = event.get("model") or ""
            session = (event.get("session_id") or "")[:8]
            version = event.get("claude_code_version") or ""
            bits = " · ".join(p for p in (model, version, f"session {session}" if session else "") if p)
            if bits:
                emit(when, "⚙", "start", bits)
        return

    if kind == "assistant":
        message = event.get("message") or {}
        if event.get("is_api_error_message"):
            for block in message.get("content") or []:
                if block.get("type") == "text":
                    emit(when, "✗", "error", block.get("text", "").strip())
            return

        for block in message.get("content") or []:
            block_type = block.get("type")
            if block_type == "text":
                text = (block.get("text") or "").strip()
                if text:
                    # In full, and indented after the first line so a
                    # paragraph stays readable next to the timestamps.
                    first, *rest = text.splitlines()
                    emit(when, "💬", "", first)
                    for extra in rest:
                        print(f"{INDENT}{extra}", flush=True)
            elif block_type == "tool_use":
                name = block.get("name", "tool")
                subject, detail = describe_tool(name, block.get("input") or {})
                emit(when, "▶", name.lower(), subject)
                if detail:
                    print(f"{INDENT}{elide(detail)}", flush=True)
        return

    if kind == "user":
        message = event.get("message") or {}
        content = message.get("content")
        if not isinstance(content, list):
            return
        for block in content:
            if block.get("type") != "tool_result":
                continue
            body = block.get("content")
            if isinstance(body, list):
                body = "".join(
                    part.get("text", "") for part in body if isinstance(part, dict)
                )
            body = body if isinstance(body, str) else ""
            lines = body.splitlines()

            if block.get("is_error"):
                # A failure is the reason someone reads the log at all.
                emit(when, "←", "failed", lines[0] if lines else "")
                for extra in lines[1:ERROR_RESULT_LINES]:
                    print(f"{INDENT}{extra}", flush=True)
                if len(lines) > ERROR_RESULT_LINES:
                    print(f"{INDENT}… {len(lines) - ERROR_RESULT_LINES} more lines", flush=True)
            elif len(lines) <= 1:
                emit(when, "←", "ok", elide(body))
            else:
                emit(when, "←", "ok", f"{len(lines)} lines")
        return

    if kind == "result":
        failed = event.get("is_error") or event.get("api_error_status")
        seconds = (event.get("duration_ms") or 0) / 1000
        duration = f"{int(seconds // 60)}m{int(seconds % 60):02d}s" if seconds >= 60 else f"{seconds:.1f}s"
        parts = [duration]
        if event.get("num_turns"):
            parts.append(f"{event['num_turns']} turns")
        cost = event.get("total_cost_usd")
        if cost:
            parts.append(f"${cost:.2f}")
        emit(when, "✗" if failed else "✓", "done", " · ".join(parts))
        text = (event.get("result") or "").strip()
        if failed and text:
            print(f"{INDENT}{text}", flush=True)
        return


def main() -> int:
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        stripped = line.lstrip()
        if not stripped.startswith("{"):
            # Not our stream: another agent's output, or a shell message.
            print(line, flush=True)
            continue
        try:
            event = json.loads(stripped)
        except json.JSONDecodeError:
            print(line, flush=True)
            continue
        if not isinstance(event, dict):
            print(line, flush=True)
            continue
        try:
            render(event)
        except Exception as exc:  # noqa: BLE001 - never lose a run to a format bug
            print(f"[format error: {exc}] {elide(stripped, 200)}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
