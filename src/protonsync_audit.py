#!/usr/bin/env python3
"""Summarize one protonsync safety-bisync run into a human-readable audit line."""

from __future__ import annotations

import argparse
import re
from datetime import datetime
from pathlib import Path

ACTION_RE = re.compile(
    r"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} INFO  : (.*): "
    r"(Copied(?: \([^)]*\))?|Deleted|Moved|Renamed|Made directory(?: with metadata)?(?: \([^)]*\))?|Removed directory)$"
)
TRANSFER_BYTES_RE = re.compile(r"^Transferred:\s+(.+?)\s+/\s+.+$")
TRANSFER_COUNT_RE = re.compile(r"^Transferred:\s+(\d+)\s+/\s+(\d+),")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-log", required=True)
    parser.add_argument("--audit-log", required=True)
    parser.add_argument("--started", required=True)
    parser.add_argument("--finished", required=True)
    parser.add_argument("--status", type=int, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_log = Path(args.run_log)
    audit_log = Path(args.audit_log)
    text = run_log.read_text(encoding="utf-8", errors="replace") if run_log.exists() else ""
    lines = text.splitlines()

    actions: list[tuple[str, str]] = []
    for line in lines:
        match = ACTION_RE.match(line)
        if match:
            actions.append((match.group(1), match.group(2)))

    transferred_bytes = "unknown"
    transferred_count = "unknown"
    for line in lines:
        stripped = line.strip()
        byte_match = TRANSFER_BYTES_RE.match(stripped)
        if byte_match and not byte_match.group(1).strip().isdigit():
            transferred_bytes = byte_match.group(1).strip()
        count_match = TRANSFER_COUNT_RE.match(stripped)
        if count_match:
            transferred_count = count_match.group(1)

    errors = [line for line in lines if " ERROR " in line or " ERROR:" in line]
    warnings = [line for line in lines if " WARNING" in line]
    rate_limits = sum("429" in line and "Too many" in line for line in lines)
    successful = args.status == 0 and "Bisync successful" in text

    started = datetime.fromisoformat(args.started)
    finished = datetime.fromisoformat(args.finished)
    duration = finished - started
    status_text = "SUCCESS" if successful else f"FAILED (exit {args.status})"
    discrepancy = bool(actions)

    report = [
        "",
        "=" * 72,
        f"Full-sync audit: {started:%Y-%m-%d %H:%M:%S}",
        f"Status: {status_text}",
        f"Duration: {str(duration).split('.')[0]}",
        f"Result: {'DISCREPANCIES FOUND' if discrepancy else 'NO DISCREPANCIES FOUND'}",
        f"Actual file/folder operations: {len(actions)}",
        f"Data transferred: {transferred_bytes}",
        f"Items transferred: {transferred_count}",
        f"Error lines: {len(errors)} | Warnings: {len(warnings)} | API 429: {rate_limits}",
        f"Detailed log: {run_log}",
    ]
    if discrepancy:
        report.append("Items the safety bisync had to reconcile:")
        for path, action in actions[:100]:
            report.append(f"  - {action}: {path}")
        if len(actions) > 100:
            report.append(f"  - ... and {len(actions) - 100} more; see the detailed log")
    elif successful:
        report.append("Conclusion: the fast event sync had already captured every change.")
    else:
        report.append("Conclusion: the audit did not complete; see the detailed log.")

    audit_log.parent.mkdir(parents=True, exist_ok=True)
    with audit_log.open("a", encoding="utf-8") as stream:
        stream.write("\n".join(report) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
