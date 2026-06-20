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
DEFAULT_MAX_POLLS = 40
FAIL_VERDICTS = {"suspicious", "likely_malicious", "malicious"}


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
        req_headers = {"X-Api-Key": self.api_key}
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
    max_polls: int,
) -> dict[str, object]:
    for attempt in range(1, max_polls + 1):
        payload = client.get_report(flow_id)
        state = str(payload.get("state") or "")
        all_finished = bool(payload.get("allFinished"))
        if all_finished or state == "finished":
            return payload

        pause = payload.get("pollPause")
        wait_seconds = poll_seconds
        if isinstance(pause, int) and pause > 0:
            wait_seconds = max(poll_seconds, pause)
        print(
            f"FileScan flow {flow_id} is state={state or 'unknown'}; "
            f"poll {attempt}/{max_polls}.",
            flush=True,
        )
        time.sleep(wait_seconds)
    raise RuntimeError(f"Timed out waiting for FileScan flow {flow_id}")


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
    parser.add_argument("--max-polls", type=int, default=DEFAULT_MAX_POLLS)
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

    for path in selected:
        sha256 = sha256_file(path)
        print(f"Submitting {path} ({path.stat().st_size} bytes, sha256={sha256})", flush=True)
        flow_id = client.scan_file(path)
        payload = poll_report(
            client,
            flow_id,
            poll_seconds=args.poll_seconds,
            max_polls=args.max_polls,
        )
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
        print("FileScan.IO detections found:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("FileScan.IO scan completed without suspicious or malicious verdicts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
