#!/usr/bin/env python3
"""Submit selected artifacts to FileScan.IO and fail on malicious verdicts."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


API_BASE = "https://www.filescan.io"
DEFAULT_POLL_SECONDS = 15
# A 4.6 MB archive can sit in FileScan's queue for longer than ten minutes, and
# a scan that is still running is not a detection. Bound the wait by wall
# clock, not by a poll count, so a server-supplied pause cannot shorten it.
DEFAULT_MAX_WAIT_SECONDS = 1800
FAIL_VERDICTS = {"suspicious", "likely_malicious", "malicious"}
# FileScan.IO sits behind Cloudflare, which rejects Python's default
# `Python-urllib/x.y` agent with `403 error code: 1010` (banned browser
# signature) before the request ever reaches the API. Identify the client
# explicitly so the scan reaches the API instead of failing on the WAF.
USER_AGENT = (
    "route10-dnscrypt-proxy-filescan/1.0 "
    "(+https://github.com/unflawed-code/route10-dnscrypt-proxy)"
)


class FileScanClient:
    def __init__(self, api_key: str) -> None:
        self.api_key = api_key

    def request(
        self,
        method: str,
        path: str,
        *,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> dict[str, object]:
        req_headers = {
            "X-Api-Key": self.api_key,
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        }
        if headers:
            req_headers.update(headers)
        request = urllib.request.Request(
            f"{API_BASE}{path}",
            data=data,
            headers=req_headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                body = response.read()
                if not body:
                    return {}
                return json.loads(body.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            if exc.code == 429:
                retry_after = int(exc.headers.get("Retry-After", "60"))
                print(f"FileScan rate limit reached; sleeping {retry_after}s.", flush=True)
                time.sleep(retry_after)
                return self.request(method, path, data=data, headers=headers)
            raise RuntimeError(f"FileScan HTTP {exc.code}: {body}") from exc

    def scan_file(self, path: Path) -> str:
        body, content_type = build_multipart_body(path)
        payload = self.request(
            "POST",
            "/api/scan/file",
            data=body,
            headers={"Content-Type": content_type},
        )
        return str(payload["flow_id"])

    def get_report(self, flow_id: str) -> dict[str, object]:
        query = urllib.parse.urlencode(
            [
                ("filter", "general"),
                ("filter", "finalVerdict"),
                ("filter", "taskReference"),
            ]
        )
        return self.request("GET", f"/api/scan/{urllib.parse.quote(flow_id)}/report?{query}")


def build_multipart_body(path: Path) -> tuple[bytes, str]:
    boundary = f"----route10-filescan-{uuid.uuid4().hex}"
    mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
        f"Content-Type: {mime_type}\r\n\r\n"
    ).encode("utf-8")
    tail = f"\r\n--{boundary}--\r\n".encode("utf-8")
    return head + path.read_bytes() + tail, f"multipart/form-data; boundary={boundary}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def poll_report(
    client: FileScanClient,
    flow_id: str,
    *,
    poll_seconds: int,
    max_wait_seconds: int,
) -> dict[str, object]:
    deadline = time.monotonic() + max_wait_seconds
    attempt = 0
    while True:
        attempt += 1
        payload = client.get_report(flow_id)
        state = str(payload.get("state") or "")
        all_finished = bool(payload.get("allFinished"))
        if all_finished or state == "finished":
            return payload

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(
                f"Timed out after {max_wait_seconds}s waiting for FileScan flow "
                f"{flow_id} (last state={state or 'unknown'})"
            )

        pause = payload.get("pollPause")
        wait_seconds = poll_seconds
        if isinstance(pause, int) and pause > 0:
            wait_seconds = max(poll_seconds, pause)
        wait_seconds = min(wait_seconds, remaining)
        print(
            f"FileScan flow {flow_id} is state={state or 'unknown'}; "
            f"poll {attempt}, {int(remaining)}s left.",
            flush=True,
        )
        time.sleep(wait_seconds)


def report_verdicts(payload: dict[str, object]) -> list[dict[str, str]]:
    reports = payload.get("reports", {})
    if not isinstance(reports, dict):
        return []

    verdicts: list[dict[str, str]] = []
    for report_id, report in reports.items():
        if not isinstance(report, dict):
            continue
        final = report.get("finalVerdict", {})
        if not isinstance(final, dict):
            final = {}
        file_info = report.get("file", {})
        if not isinstance(file_info, dict):
            file_info = {}
        verdicts.append(
            {
                "report_id": str(report_id),
                "verdict": str(final.get("verdict") or "unknown").lower(),
                "threat_level": str(final.get("threatLevel") or ""),
                "confidence": str(final.get("confidence") or ""),
                "file_hash": str(file_info.get("hash") or ""),
                "file_type": str(file_info.get("type") or ""),
            }
        )
    return verdicts


def markdown_row(path: Path, sha256: str, flow_id: str, verdict: dict[str, str]) -> str:
    return (
        f"| `{path.as_posix()}` | `{sha256[:12]}` | `{flow_id}` | "
        f"{verdict['verdict']} | {verdict['threat_level']} | {verdict['confidence']} |"
    )


def write_summary(rows: list[str]) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    with Path(summary_path).open("a", encoding="utf-8") as handle:
        handle.write("## FileScan.IO scan\n\n")
        if not rows:
            handle.write("No files were selected for scanning.\n")
            return
        handle.write("| File | SHA-256 | Flow | Verdict | Threat level | Confidence |\n")
        handle.write("| --- | --- | --- | --- | ---: | ---: |\n")
        for row in rows:
            handle.write(row + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--poll-seconds", type=int, default=DEFAULT_POLL_SECONDS)
    parser.add_argument(
        "--max-wait-seconds", type=int, default=DEFAULT_MAX_WAIT_SECONDS
    )
    args = parser.parse_args()

    api_key = os.environ.get("FILESCAN_API_KEY")
    if not api_key:
        print("FILESCAN_API_KEY is not set.", file=sys.stderr)
        return 2

    selected = [path for path in args.files if path.is_file()]
    if not selected:
        print("No existing files were selected for FileScan.IO scanning.", file=sys.stderr)
        return 2

    client = FileScanClient(api_key)
    rows: list[str] = []
    failures: list[str] = []

    # Submit every file before polling any of them: each upload is its own flow
    # and FileScan runs flows concurrently, so polling them in turn costs the
    # slowest scan's wall time instead of the sum of all four.
    submissions: list[tuple[Path, str, str]] = []
    for path in selected:
        sha256 = sha256_file(path)
        print(f"Submitting {path} ({path.stat().st_size} bytes, sha256={sha256})", flush=True)
        submissions.append((path, sha256, client.scan_file(path)))

    for path, sha256, flow_id in submissions:
        try:
            payload = poll_report(
                client,
                flow_id,
                poll_seconds=args.poll_seconds,
                max_wait_seconds=args.max_wait_seconds,
            )
        except RuntimeError as exc:
            # A scan that never finished is a failed check, not a verdict.
            failures.append(f"{path}: {exc}")
            rows.append(
                markdown_row(
                    path,
                    sha256,
                    flow_id,
                    {"verdict": "unknown", "threat_level": "", "confidence": ""},
                )
            )
            continue
        verdicts = report_verdicts(payload)
        if not verdicts:
            failures.append(f"{path}: no report verdict returned for flow {flow_id}")
            rows.append(markdown_row(path, sha256, flow_id, {"verdict": "unknown", "threat_level": "", "confidence": ""}))
            continue

        for verdict in verdicts:
            rows.append(markdown_row(path, sha256, flow_id, verdict))
            if verdict["verdict"] in FAIL_VERDICTS:
                failures.append(f"{path}: verdict={verdict['verdict']}, sha256={sha256}")

    write_summary(rows)
    if failures:
        print("FileScan.IO scan failures:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("FileScan.IO scan completed without suspicious or malicious verdicts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
