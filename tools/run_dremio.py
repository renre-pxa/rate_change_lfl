"""Run the LFL SQL stack through the Dremio Software REST API (Python 3.10+)."""

import argparse
import getpass
import json
import logging
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler


LOG = logging.getLogger("lfl")
FILES = (
    "01_data_prep.sql", "02_layer_assignment.sql", "03_policy_output.sql",
)
DEFAULT_DREMIO_URL = "https://dremio.renre.com:9047"
MARKER = re.compile(r"^-- @(object|insert) (\w+)\s*$", re.MULTILINE)


def split_sql(text):
    statements = []
    pending = ""
    for character in text:
        pending += character
        if character == ";" and sqlite3.complete_statement(pending):
            statements.append(pending.strip())
            pending = ""
    remainder = re.sub(r"/\*.*?\*/|--[^\n]*", "", pending, flags=re.DOTALL)
    if remainder.strip():
        raise ValueError("SQL statement is missing a terminating semicolon")
    return statements


def load_sections(path):
    text = path.read_text(encoding="utf-8-sig")
    markers = list(MARKER.finditer(text))
    if not markers:
        raise ValueError(f"No @object/@insert markers in {path}")
    sections = []
    for index, marker in enumerate(markers):
        end = markers[index + 1].start() if index + 1 < len(markers) else len(text)
        statements = split_sql(text[marker.end():end])
        if not statements:
            raise ValueError(f"Empty SQL section in {path}: {marker.group(2)}")
        sections.append((marker.group(1), marker.group(2), statements))
    return sections


def layer_queries(sections):
    inserts = [sql for kind, name, statements in sections
               if kind == "insert" and name == "07_lfl_layer_position"
               for sql in statements]
    if len(inserts) != 1:
        raise ValueError("Expected exactly one layer INSERT")
    insert = inserts[0]
    year_query = re.search(r"\by AS \(\s*(SELECT MIN\(policy_year\).*?)\n\),\s*pos AS", insert, re.DOTALL)
    if year_query is None:
        raise ValueError("Cannot locate the layer SQL's y CTE; refusing to run")
    return year_query.group(1), insert


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise RuntimeError("Dremio redirected the API request; configure its direct HTTPS URL")


class Dremio:
    def __init__(self, base_url, token, poll_seconds=5, job_timeout=14400):
        parsed = urlsplit(base_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.query or parsed.fragment:
            raise ValueError("DREMIO_URL must be an HTTPS server URL without credentials, query or fragment")
        self.api = base_url.rstrip("/") + "/api/v3"
        self.token = token
        self.poll_seconds = poll_seconds
        self.job_timeout = job_timeout
        self.opener = build_opener(NoRedirect())

    def request(self, method, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = Request(self.api + path, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
        })
        try:
            with self.opener.open(request, timeout=60) as response:
                return json.load(response)
        except HTTPError as error:
            raise RuntimeError(f"Dremio API {method} {path}: HTTP {error.code}. No automatic resubmission.") from None
        except (URLError, TimeoutError) as error:
            raise RuntimeError(
                f"Dremio API {method} {path}: {type(error).__name__}. "
                "Submission/completion may be uncertain; check Dremio Jobs before restarting."
            ) from None

    def execute(self, sql, results=False):
        job_id = self.request("POST", "/sql", {"sql": sql})["id"]
        LOG.info("Submitted job %s", job_id)
        job_path = "/job/" + quote(job_id, safe="")
        deadline = time.monotonic() + self.job_timeout
        while True:
            job = self.request("GET", job_path)
            state = job["jobState"]
            if state == "COMPLETED":
                LOG.info("Completed job %s", job_id)
                break
            if state in ("FAILED", "CANCELED"):
                raise RuntimeError(f"Job {job_id} {state}: {job.get('errorMessage') or job.get('cancellationReason', '')}")
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Timed out waiting for job {job_id}; it may still be running. Do not resubmit.")
            time.sleep(self.poll_seconds)
        if results:
            return self.request("GET", job_path + "/results?offset=0&limit=500")["rows"]
        return []


def fill_layers(client, year_query, insert, max_years):
    previous_year = None
    completed = 0
    while True:
        rows = client.execute(year_query, results=True)
        if len(rows) != 1 or len(rows[0]) != 1:
            raise RuntimeError("Next-year query must return exactly one scalar")
        year = next(iter(rows[0].values()))
        if year is None:
            LOG.info("No policy years remain; completed %s INSERTs", completed)
            return
        year = int(year)
        if previous_year is not None and year <= previous_year:
            raise RuntimeError(f"Layer INSERT did not advance beyond {previous_year}; stopping")
        if completed >= max_years:
            raise RuntimeError(f"Exceeded --max-years {max_years}; stopping")
        LOG.info("Loading policy year %s", year)
        client.execute(insert)
        previous_year = year
        completed += 1


def run_sections(client, sections):
    for kind, name, statements in sections:
        if kind == "insert":
            continue
        LOG.info("Building %s", name)
        for statement in statements:
            client.execute(statement)


def get_token():
    token = os.environ.get("DREMIO_TOKEN")
    if not token:
        if not sys.stdin.isatty():
            raise ValueError("No terminal to ask for the Dremio token; set DREMIO_TOKEN in the environment")
        token = getpass.getpass("Dremio personal token (input is hidden): ")
    token = token.strip()
    if not token:
        raise ValueError("No Dremio token entered")
    if re.search(r"\s|[\x00-\x1f\x7f]", token):
        raise ValueError("The Dremio token contains spaces or control characters; copy it again")
    return token


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sql-dir", type=Path, default=Path(__file__).resolve().parents[1] / "sql")
    parser.add_argument("--mode", choices=("layers", "full", "outputs"), default="layers")
    parser.add_argument("--confirm-rebuild", action="store_true", help="Allow full mode to DROP and rebuild all tables")
    parser.add_argument("--dry-run", action="store_true", help="Validate SQL files and print plan without API calls")
    parser.add_argument("--max-years", type=int, default=100)
    parser.add_argument("--poll-seconds", type=float, default=5)
    parser.add_argument("--job-timeout", type=float, default=14400)
    parser.add_argument("--log-file", type=Path)
    parser.add_argument("--lock-file", type=Path, default=Path(__file__).resolve().parents[1] / ".dremio-run.lock")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        handlers=[logging.StreamHandler()] + ([logging.FileHandler(args.log_file)] if args.log_file else []))
    if args.max_years <= 0 or args.poll_seconds <= 0 or args.job_timeout <= 0:
        parser.error("Year limit and time intervals must be positive")
    if args.mode == "full" and not args.confirm_rebuild and not args.dry_run:
        parser.error("Full mode drops tables; explicitly pass --confirm-rebuild")
    try:
        required = FILES if args.mode == "full" else (FILES[1:2] if args.mode == "layers" else FILES[2:])
        sections = {filename: load_sections(args.sql_dir / filename) for filename in required}
        layer_sql = layer_queries(sections[FILES[1]]) if args.mode != "outputs" else None
        LOG.info("Mode %s; SQL directory %s", args.mode, args.sql_dir)
        for filename, groups in sections.items():
            LOG.info("%s: %s", filename, ", ".join(name for kind, name, statements in groups))
        if args.dry_run:
            LOG.info("Dry run only. Full mode runs phases 01-03; layers runs phase 02; outputs runs phase 03. Reporting and QA are excluded.")
            return 0
        base_url = os.environ.get("DREMIO_URL") or DEFAULT_DREMIO_URL
        token = get_token()
        client = Dremio(base_url, token, args.poll_seconds, args.job_timeout)
        with args.lock_file.open("x", encoding="utf-8") as lock:
            json.dump({"pid": os.getpid(), "mode": args.mode, "started": time.time()}, lock)
        LOG.info("Acquired lock %s", args.lock_file)
        if args.mode == "full":
            LOG.info("Phase 1/3: Data preparation (objects 01-06)")
            run_sections(client, sections[FILES[0]])
            LOG.info("Phase 2/3: Layer assignment (object 07)")
            run_sections(client, sections[FILES[1]])
            fill_layers(client, *layer_sql, args.max_years)
            LOG.info("Phase 3/3: Consolidated policy output (object 08)")
            run_sections(client, sections[FILES[2]])
        elif args.mode == "layers":
            fill_layers(client, *layer_sql, args.max_years)
        elif args.mode == "outputs":
            LOG.info("Building consolidated policy output (object 08)")
            run_sections(client, sections[FILES[2]])
        args.lock_file.unlink()
        LOG.info("Run succeeded")
        return 0
    except Exception as error:
        LOG.error("%s", error)
        LOG.error("Any existing lock is retained. Check Dremio Jobs before removing it and retrying. Never overlap runners.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
