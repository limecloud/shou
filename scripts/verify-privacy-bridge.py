#!/usr/bin/env python3
"""Verify privacy transport; optional cleanup touches one exclusively created profile only."""
import argparse
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--native-fixtures", action="store_true")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("privacy_desktop_protocol", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    engine = args.engine.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="shou-privacy-bridge-") as temporary:
        records = Path(temporary).resolve() / "records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))

        def request(operation, values=None, confirmation="cancel", review=None):
            return bridge.request(engine, environment, operation, values, confirmation=confirmation, before_confirmation=review)

        capabilities, _ = request("capabilities")
        platform = capabilities["data"]["platform"]
        assert capabilities["data"]["features"]["privacy"] is (platform in {"windows", "macos"})
        history, confirmed = request("privacy.history")
        assert history["ok"] and history["data"] == {"entries": [], "total_count": 0} and not confirmed
        for operation, values in [
            ("privacy.scan", {"range": "invalid"}), ("privacy.scan", {"range": True}),
            ("privacy.scan", {"path": temporary}), ("privacy.history", {"path": temporary}),
            ("privacy.clean", {"scan_id": "missing", "source_ids": ["missing"], "sign_out": "true"}),
            ("privacy.clean", {"scan_id": "missing", "source_ids": [], "sign_out": False, "yes": True}),
        ]:
            result, confirmed = request(operation, values)
            assert not result["ok"] and result["error"]["code"] == "invalid_argument" and not confirmed
        assert not list(records.rglob("*.json"))
        print("PASS strict privacy scope/range/consent fields and read-only empty history")
        if not args.native_fixtures:
            return
        assert platform in {"windows", "macos"}
        discovery = json.loads(subprocess.check_output([str(engine), "capabilities", "--command", "privacy", "--json"], env=environment, timeout=30))
        assert discovery["ok"] and len(discovery["data"]["commands"]) == 6
        relative_root = "AppData/Local/Chromium/User Data" if platform == "windows" else "Library/Application Support/Chromium"
        home = Path.home().resolve()
        profile_name = "Profile " + str(time.time_ns()) + str(uuid.uuid4().int % 1_000_000)
        profile = home / relative_root / profile_name
        created = []
        profile_identity = None

        def identity(path):
            metadata = path.lstat()
            assert stat.S_ISDIR(metadata.st_mode) and not path.is_symlink() and not getattr(metadata, "st_file_attributes", 0) & 0x400
            assert path.resolve() == path
            if os.name != "nt":
                assert metadata.st_uid == os.getuid() and metadata.st_mode & 0o022 == 0
            return metadata.st_dev, metadata.st_ino

        def directory(path):
            if not path.exists() and not path.is_symlink():
                directory(path.parent)
                path.mkdir(mode=0o700)
                bridge.set_fixture_owner(path)
                created.append((path, identity(path)))
            identity(path)

        secret = "generated-private-" + uuid.uuid4().hex
        try:
            directory(profile.parent)
            profile.mkdir(mode=0o700)
            bridge.set_fixture_owner(profile)
            profile_identity = identity(profile)
            directory(profile / "Network")
            history_path, cookie_path = profile / "History", profile / "Network/Cookies"
            recent = int((time.time() + 11_644_473_600 - 60) * 1_000_000)
            with closing(sqlite3.connect(history_path)) as db:
                db.executescript("CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER); CREATE TABLE downloads(id INTEGER); INSERT INTO downloads VALUES(99);")
                db.execute("INSERT INTO urls VALUES(1,?)", ("https://" + secret + ".invalid",))
                db.executemany("INSERT INTO visits VALUES(?,?,?)", [(1, 1, recent), (2, 1, recent - 7_200_000_000)])
                db.commit()
            with closing(sqlite3.connect(cookie_path)) as db:
                db.executescript("CREATE TABLE cookies(host_key TEXT,value TEXT,last_access_utc INTEGER);")
                db.executemany("INSERT INTO cookies VALUES(?,?,?)", [(secret + ".invalid", secret, recent), ("old.invalid", "retained", recent - 7_200_000_000)])
                db.commit()
            bridge.set_fixture_owner(profile)
            prefix = relative_root + "/" + profile_name + "/"
            scan, confirmed = request("privacy.scan", {"range": "last-hour"})
            assert scan["ok"] and not confirmed, "Generated privacy fixture could not be scanned."
            sources = [row for row in scan["data"]["sources"] if row["definition"]["relative_path"] in {prefix + "History", prefix + "Network/Cookies"}]
            assert len(sources) == 2 and all(row["status"] == "ready" and row["record_count"] == 1 for row in sources), "Generated sources were unavailable; no privacy deletion was attempted. Close Chromium/Chrome and retry the isolated check."
            values = dict(scan_id=scan["data"]["id"], source_ids=[row["id"] for row in sources], sign_out=False)
            result, confirmed = request("privacy.clean", values)
            assert not result["ok"] and result["error"]["code"] == "privacy_sign_out_consent_required" and not confirmed
            values["sign_out"] = True
            duplicate, confirmed = request("privacy.clean", dict(values, source_ids=[sources[0]["id"]] * 2))
            assert not duplicate["ok"] and duplicate["error"]["code"] == "invalid_argument" and not confirmed

            def check_review(challenge):
                review = challenge["review"]
                assert challenge["operation"] == "privacy.delete" and review["requires_sign_out"] is True
                assert review["range"] == "last-hour" and review["range_start"] and review["range_end"]
                assert len(review["items"]) == 2 and all(row["records"] == 1 and profile_name in row["path"] for row in review["items"])
                assert secret not in json.dumps(challenge)

            for decision in ["wrong", "wrong-digest", "cancel"]:
                result, confirmed = request("privacy.clean", values, decision, check_review)
                assert not result["ok"] and confirmed and result["error"]["code"] in {"confirmation_required", "cancelled"}
                for path, table in [(history_path, "visits"), (cookie_path, "cookies")]:
                    with closing(sqlite3.connect(path)) as db:
                        assert db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0] == 2
            print("PASS exact generated source selection, separate Cookie consent, bound confirmation and cancellation")
            result, confirmed = request("privacy.clean", values, "accept", check_review)
            assert result["ok"] and confirmed and result["data"]["state"] == "completed"
            assert len(result["data"]["items"]) == 2 and all(item["removed_records"] == 1 for item in result["data"]["items"])
            with closing(sqlite3.connect(history_path)) as db:
                assert db.execute("SELECT COUNT(*) FROM visits").fetchone()[0] == 1
                assert db.execute("SELECT COUNT(*) FROM downloads").fetchone()[0] == 1
            with closing(sqlite3.connect(cookie_path)) as db:
                assert db.execute("SELECT COUNT(*) FROM cookies").fetchone()[0] == 1
            old, confirmed = request("privacy.clean", values, "accept")
            assert not old["ok"] and old["error"]["code"] == "plan_stale" and not confirmed
            receipts, confirmed = request("privacy.history")
            assert receipts["ok"] and not confirmed and receipts["data"]["total_count"] == 1
            text = json.dumps(receipts)
            assert all(value not in text for value in [secret, profile_name, "AppData", "Library/", "retained"])
            print("PASS confirmed time-range deletion preserves old records/downloads, sanitized durable receipts and stale replay refusal")
            hardlink = profile / "generated-hardlink"
            os.link(history_path, hardlink)
            linked, confirmed = request("privacy.scan", {"range": "all-time"})
            assert linked["ok"] and not confirmed
            linked_source = next(row for row in linked["data"]["sources"] if row["definition"]["relative_path"] == prefix + "History")
            assert linked_source["status"] not in {"ready", "empty"} and linked_source.get("record_count") is None
            hardlink.unlink()
            if os.name == "nt":
                subprocess.run(["icacls", str(cookie_path), "/grant", "*S-1-1-0:(W)", "/Q"], check=True, stdout=subprocess.DEVNULL)
                unsafe, confirmed = request("privacy.scan", {"range": "all-time"})
                assert unsafe["ok"] and not confirmed
                unsafe_source = next(row for row in unsafe["data"]["sources"] if row["definition"]["relative_path"] == prefix + "Network/Cookies")
                assert unsafe_source["status"] == "permission-required" and unsafe_source.get("record_count") is None
                print("PASS native hardlink and untrusted-write ACL refusal on generated browser databases")
            else:
                print("PASS generated database hardlink refusal; Windows ACL branch requires native Windows")
        finally:
            if profile_identity is not None:
                assert identity(profile) == profile_identity, "Generated profile changed; preserved for inspection."
                shutil.rmtree(profile)
            for path, expected in reversed(created):
                if path == profile / "Network":
                    continue
                if path.exists() and identity(path) == expected:
                    try:
                        path.rmdir()
                    except OSError:
                        pass


if __name__ == "__main__":
    main()
