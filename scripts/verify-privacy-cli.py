#!/usr/bin/env python3
"""Verify privacy CLI contracts with one exclusively created Chromium profile."""
from pathlib import Path
import argparse
from contextlib import closing
import errno
import hashlib
import json
import os
import pty
import select
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import uuid


root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", nargs="?", type=Path, default=root / ".build/release/shou")
parser.add_argument("--evidence-dir", type=Path, default=root / ".build/privacy-cli")
arguments = parser.parse_args()
binary, evidence = arguments.binary.resolve(), arguments.evidence_dir.resolve()
evidence.mkdir(parents=True, exist_ok=True)
base = Path(tempfile.mkdtemp(prefix="shou-privacy-cli-")).resolve()
environment = dict(os.environ, SHOU_DATA_DIR=str(base / "records"))
profile_name = "Profile " + str(time.time_ns()) + str(uuid.uuid4().int % 1_000_000)
browser_root = Path.home().resolve() / "Library/Application Support/Chromium"
profile = browser_root / profile_name
history, cookies = profile / "History", profile / "Network/Cookies"
relative_prefix = "Library/Application Support/Chromium/" + profile_name + "/"
created_parents = []
profile_identity = None
checks = 0
fixture_ids = set()
fixture_sources = []
sentinel = "generated-privacy-" + uuid.uuid4().hex
secret_url = "https://" + sentinel + ".invalid/private-history"
secret_cookie = sentinel + "-cookie-value"
phrase = "DELETE-PRIVACY"


def record(label, value):
    (evidence / label).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def safe_directory(path, create=False):
    """Only create missing known ancestors; never follow links or change permissions."""
    if not path.exists() and not path.is_symlink():
        if not create:
            raise AssertionError(f"Required parent directory is missing: {path}")
        safe_directory(path.parent, create=True)
        path.mkdir(mode=0o700)
        metadata = path.lstat()
        created_parents.append((path, metadata.st_dev, metadata.st_ino))
    metadata = path.lstat()
    assert stat.S_ISDIR(metadata.st_mode) and not path.is_symlink(), path
    assert path.resolve() == path, path
    assert metadata.st_uid == os.getuid() and metadata.st_mode & 0o022 == 0, path


def source_scope(scan):
    return [source for source in scan["sources"]
            if source["definition"]["relative_path"] in
            {relative_prefix + "History", relative_prefix + "Network/Cookies"}]


def sanitized(envelope):
    """Keep evidence limited to generated sources, even when discovery sees real profiles."""
    result = json.loads(json.dumps(envelope))
    value = result.get("data")
    if isinstance(value, dict) and "sources" in value and "scan_id" not in value:
        value["sources"] = source_scope(value)
        value.pop("home_identity", None)
        value["observation_scope"] = "Generated fixture sources only; other discovery rows omitted."
    return result


def run(*args, expected=0):
    global checks
    process = subprocess.run([str(binary), *args, "--json"], env=environment,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             start_new_session=True, timeout=180)
    try:
        result = json.loads(process.stdout)
    except json.JSONDecodeError:
        raise AssertionError((args, process.returncode, process.stderr)) from None
    accepted = [expected] if isinstance(expected, int) else expected
    assert process.returncode in accepted, (args, process.returncode, sanitized(result), process.stderr)
    checks += 1
    record(f"{checks:02d}-{'-'.join(args[:3]).replace('/', '-')}.json", sanitized(result))
    return result


def assert_fixture_plan(plan):
    selected = plan["sources"]
    assert {source["id"] for source in selected} == fixture_ids
    assert {source["definition"]["relative_path"] for source in selected} == {
        relative_prefix + "History", relative_prefix + "Network/Cookies"}
    assert all(source["definition"]["bundle_identifier"] == "org.chromium.Chromium"
               and source["definition"]["profile"] == profile_name for source in selected)
    assert all(source["record_count"] == 1 for source in selected)


def confirm(plan, cancel=False, expected=0):
    global checks
    output_read, output_write = os.pipe()
    pid, terminal = pty.fork()
    if pid == 0:
        os.close(output_read)
        os.dup2(output_write, 1)
        os.close(output_write)
        os.execve(str(binary), [str(binary), "privacy", "execute", "--plan-id", plan["id"], "--json"], environment)
    os.close(output_write)
    readers, transcript, output = {terminal, output_read}, bytearray(), bytearray()
    sent = finished = False
    deadline = time.monotonic() + 180
    try:
        while readers and time.monotonic() < deadline:
            for descriptor in select.select(list(readers), [], [], 0.1)[0]:
                try:
                    data = os.read(descriptor, 65536)
                except OSError as error:
                    if descriptor == terminal and error.errno == errno.EIO:
                        data = b""
                    else:
                        raise
                if not data:
                    readers.remove(descriptor)
                else:
                    (transcript if descriptor == terminal else output).extend(data)
            if not sent and phrase.encode() in transcript:
                scope, _ = json.JSONDecoder().raw_decode(transcript.decode().lstrip())
                assert scope["irreversible"] is True and scope["can_sign_out"] is True
                expected_plan = dict(plan, state="completed") if expected == 4 else plan
                assert scope["restore_supported"] is False and scope["plan"] == expected_plan
                assert_fixture_plan(scope["plan"])
                record(f"tty-scope-{checks + 1:02d}.json", scope)
                os.write(terminal, b"CANCEL\n" if cancel else phrase.encode() + b"\n")
                sent = True
        assert not readers and sent, "Privacy terminal prompt did not complete within its deadline."
        _, status = os.waitpid(pid, 0)
        finished = True
        result = json.loads(output)
        assert os.waitstatus_to_exitcode(status) == (130 if cancel else expected), result
        if cancel:
            assert result["error"]["code"] == "cancelled", result
        elif expected == 0:
            assert result["ok"], result
        else:
            assert result["error"]["code"] == "plan_stale", result
        checks += 1
        record(f"{checks:02d}-tty-result.json", result)
        return result
    finally:
        if not finished:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        os.close(terminal)
        os.close(output_read)


def rows(path, query):
    with closing(sqlite3.connect(f"file:{path}?mode=ro", uri=True)) as database:
        return database.execute(query).fetchall()


def logical_snapshot():
    return {"visits": rows(history, "SELECT * FROM visits ORDER BY id"),
            "urls": rows(history, "SELECT * FROM urls ORDER BY id"),
            "downloads": rows(history, "SELECT * FROM downloads ORDER BY id"),
            "cookies": rows(cookies, "SELECT * FROM cookies ORDER BY id")}


def database_hashes():
    return {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in [history, cookies]}


def assert_sanitized_receipt(receipt):
    text = json.dumps(receipt)
    for forbidden in [sentinel, secret_url, secret_cookie, profile_name, relative_prefix, str(profile)]:
        assert forbidden not in text, "Private fixture data leaked into a privacy receipt."
    assert set(receipt) <= {"id", "plan_id", "created_at", "range", "range_start", "range_end", "state", "items"}
    assert {item["source_id"] for item in receipt["items"]} == fixture_ids
    assert all(set(item) <= {"source_id", "state", "removed_records", "reason"} for item in receipt["items"])


def exercise():
    global profile_identity, fixture_ids, fixture_sources
    assert sys.platform == "darwin", "Native browser activity checking requires macOS."
    assert binary.is_file() and os.access(binary, os.X_OK), binary
    assert not profile.exists() and not profile.is_symlink(), "Refusing an existing browser profile."
    safe_directory(browser_root, create=True)
    profile.mkdir(mode=0o700)
    profile_identity = (profile.stat().st_dev, profile.stat().st_ino)
    (profile / "Network").mkdir(mode=0o700)
    now_microseconds = time.time_ns() // 1000 + 11_644_473_600_000_000
    recent, old = now_microseconds - 60_000_000, now_microseconds - 7_200_000_000
    for path in [history, cookies]:
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
    with closing(sqlite3.connect(history)) as database, database:
        database.executescript("""
            CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,visit_count INTEGER,typed_count INTEGER,last_visit_time INTEGER);
            CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,transition INTEGER,from_visit INTEGER,opener_visit INTEGER,visited_link_id INTEGER);
            CREATE TABLE downloads(id INTEGER PRIMARY KEY,start_time INTEGER,target_path TEXT);
            CREATE TABLE visited_links(id INTEGER); INSERT INTO visited_links VALUES(10),(20),(99);
            CREATE TABLE clusters(cluster_id INTEGER); INSERT INTO clusters VALUES(10),(20),(99);
            CREATE TABLE clusters_and_visits(cluster_id INTEGER,visit_id INTEGER); INSERT INTO clusters_and_visits VALUES(10,1),(20,2);
        """)
        database.execute("INSERT INTO urls VALUES(1,?,2,1,?)", (secret_url, recent))
        database.executemany("INSERT INTO visits VALUES(?,1,?,?,0,0,?)", [(1, old, 1, 10), (2, recent, 0, 20)])
        database.execute("INSERT INTO downloads VALUES(7,?,?)", (recent, sentinel + "-download"))
    with closing(sqlite3.connect(cookies)) as database, database:
        database.execute("PRAGMA journal_mode=WAL")
        database.execute("CREATE TABLE cookies(id INTEGER PRIMARY KEY,host_key TEXT,value TEXT,last_access_utc INTEGER)")
        database.executemany("INSERT INTO cookies VALUES(?,?,?,?)", [(1, sentinel + ".invalid", secret_cookie, old),
                                                                    (2, sentinel + ".invalid", secret_cookie, recent)])
    # Prepare this generated WAL fixture using the same SQLite library as Shou.
    # Newer Python SQLite removes sidecars on close; Apple's read-only VFS cannot
    # open that state until a writable system connection initializes the sidecars.
    subprocess.run(["/usr/bin/sqlite3", str(cookies), "SELECT count(*) FROM cookies;"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    record("fixture.json", {"scope": "Only this exclusively created profile is eligible for selection and cleanup.",
                            "profile": str(profile), "fixture_time_basis": "Chromium integer microseconds since 1601",
                            "initial_counts": {"history": 2, "cookies": 2, "downloads": 1}})
    capabilities = run("capabilities", "--command", "privacy")["data"]["commands"]
    commands = {command["command"]: command for command in capabilities}
    assert commands["privacy execute"]["side_effect"] == "destructive"
    assert commands["privacy history"]["side_effect"] == "read"
    scan = run("privacy", "scan")["data"]
    fixture_sources = source_scope(scan)
    assert len(fixture_sources) == 2, "Generated profile sources were not discovered."
    if any(source["status"] == "browser-running" for source in fixture_sources):
        reason = {"status": "unavailable", "reason": "application_running", "bundle_identifier": "org.chromium.Chromium",
                  "scope": "The generated privacy fixture was not selected or cleaned; close Chromium before rerunning.",
                  "checks_completed": checks}
        record("unavailable.json", reason)
        print(json.dumps(reason, ensure_ascii=False))
        return 8
    assert scan["range"] == "last-hour" and scan.get("range_start") and scan["range_end"]
    assert all(source["status"] == "ready" and source["record_count"] == 1 for source in fixture_sources), fixture_sources
    fixture_ids = {source["id"] for source in fixture_sources}
    original = logical_snapshot()
    original_hashes = database_hashes()
    shown = run("privacy", "scan", "show", "--scan-id", scan["id"])["data"]
    assert shown == scan
    assert run("privacy", "history")["data"] == []
    assert not list((base / "records/privacy-plans").glob("*.json"))
    assert run("privacy", "scan", "--range", "invalid", expected=2)["error"]["code"] == "invalid_argument"
    selection = [value for source_id in sorted(fixture_ids) for value in ["--source", source_id]]
    refusal = run("privacy", "plan", "--scan-id", scan["id"], *selection, expected=5)
    assert refusal["error"]["code"] == "privacy_sign_out_consent_required"
    assert logical_snapshot() == original and database_hashes() == original_hashes
    plan = run("privacy", "plan", "--scan-id", scan["id"], *selection, "--acknowledge-sign-out", "true")["data"]
    assert_fixture_plan(plan)
    assert plan["state"] == "ready" and plan["sign_out_acknowledged"] is True and plan["digest"]
    assert run("privacy", "plan", "show", "--plan-id", plan["id"])["data"] == plan
    refusal = run("privacy", "execute", "--plan-id", plan["id"], expected=7)
    assert refusal["error"]["code"] == "confirmation_required"
    assert logical_snapshot() == original and database_hashes() == original_hashes
    confirm(plan, cancel=True)
    assert logical_snapshot() == original and database_hashes() == original_hashes
    assert run("privacy", "history")["data"] == []
    assert run("privacy", "plan", "show", "--plan-id", plan["id"])["data"]["state"] == "ready"
    receipt = confirm(plan)["data"]
    assert receipt["state"] == "completed"
    assert all(item["state"] == "completed" and item["removed_records"] == 1 for item in receipt["items"])
    assert_sanitized_receipt(receipt)
    assert rows(history, "SELECT id,visit_time FROM visits") == [(1, old)]
    assert rows(cookies, "SELECT id,last_access_utc FROM cookies") == [(1, old)]
    assert rows(history, "SELECT visit_count,typed_count,last_visit_time FROM urls") == [(1, 1, old)]
    assert rows(history, "SELECT id,start_time FROM downloads") == [(7, recent)]
    assert rows(history, "SELECT id FROM visited_links ORDER BY id") == [(10,), (99,)]
    assert rows(history, "SELECT cluster_id FROM clusters ORDER BY cluster_id") == [(10,), (99,)]
    completed = logical_snapshot()
    history_rows = run("privacy", "history")["data"]
    assert history_rows == [receipt]
    for item in history_rows:
        assert_sanitized_receipt(item)
    persisted = list((base / "records/privacy-history").glob("*.json"))
    assert len(persisted) == 1
    durable_receipt = json.loads(persisted[0].read_text())
    assert_sanitized_receipt(durable_receipt)
    assert durable_receipt == receipt
    confirm(plan, expected=4)
    assert logical_snapshot() == completed
    assert run("privacy", "history")["data"] == history_rows
    text = f"{checks} privacy CLI checks passed; only generated source IDs selected; TTY cancellation preserved data; confirmed deletion preserved old records and download history; receipts sanitized; replay rejected."
    (evidence / "summary.txt").write_text(text + "\n")
    print(text)
    print(f"Evidence: {evidence}")
    return 0


try:
    sys.exit(exercise())
finally:
    # The random profile must still be the exact directory this invocation created.
    if profile_identity is not None and profile.exists() and not profile.is_symlink():
        current = profile.lstat()
        if (current.st_dev, current.st_ino) == profile_identity:
            shutil.rmtree(profile)
        else:
            record("cleanup-refused.json", {"reason": "fixture_directory_replaced", "profile": str(profile)})
    for path, device, inode in reversed(created_parents):
        try:
            current = path.lstat()
            if stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == (device, inode):
                path.rmdir()
        except OSError:
            pass
    shutil.rmtree(base)
