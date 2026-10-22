#!/usr/bin/env python3
"""Exercise the real SDK against synthetic local providers; never use real keys or user files."""
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = (Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".build/debug/shou").resolve()
COUNTS = defaultdict(int)
REQUESTS = []
SLOW = threading.Event()
CHECKS = 0


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = body["model"]
        step = COUNTS[model]
        COUNTS[model] += 1
        REQUESTS.append((self.path, dict(self.headers), body))
        scenario = model.split(":")[-1]
        protocol = model.split(":")[0]
        if "questions" in body:
            if scenario in ("slow", "cross_cancel"):
                SLOW.set()
                time.sleep(4)
            if scenario in ("error", "redirect", "oversized"):
                status=401 if scenario == "error" else 307 if scenario == "redirect" else 200
                data=(b'{"error":"SENSITIVE_PROVIDER_ERROR fixture-key"}' if scenario == "error" else
                      b"x" * 70_000 if scenario == "oversized" else b"")
                self.send_response(status)
                if scenario == "redirect":
                    self.send_header("Location", "/must-not-follow")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            criteria=body["questions"]["cleanup_review"]["criteria"]
            if "generated" in criteria:
                path=body["state"]["directory"]["directory"]["path"]
                verdict=("unknown" if scenario == "unknown" else
                         "mixed" if path == "." else "generated" if path.endswith("cache") else "personal")
            else:
                retention=body["state"].get("user_retention_statements", [])
                verdict=("retain" if scenario == "retain" else "needs_information" if scenario == "uncertain" or
                         (not retention and "retention" not in body["state"]) else "supported")
            probabilities={key: 0.9 if key == verdict else 0.1 / (len(criteria)-1) for key in criteria}
            if scenario == "malformed":
                probabilities[verdict]=1.7
            response={"model": model, "answers": {"cleanup_review": {"type": "choice", "choice": verdict, "confidence": 0.8,
                        "probabilities": probabilities}}, "usage": {"input_tokens": 400, "output_tokens": 10}}
            data=json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if scenario == "oversized":
            data = json.dumps({"error": "x" * 1_100_000}).encode()
            try:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if scenario == "redirect":
            self.send_response(307)
            self.send_header("Location", "/must-not-follow")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if scenario == "error":
            self.send_response(401)
            data = b'{"error":{"message":"SENSITIVE_PROVIDER_ERROR fixture-key"}}'
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if scenario in ("slow", "cross_cancel"):
            SLOW.set()
            time.sleep(4)
        call = None
        if scenario == "probe" and step == 0:
            token = re.search(r"token '([a-fA-F0-9-]+)'", json.dumps(body))[1]
            call = ("verify_connection", {"token": token})
        elif scenario == "investigate":
            calls = [
                ("list_directory", {"path": ".", "offset": 0}),
                ("inspect_directory", {"path": "cache"}),
                ("ask_user", {"question": "Can this generated cache be rebuilt?", "choices": ["Yes; keep source files", "Keep everything"]}),
                ("propose_rule", {"path": "cache", "name": "Fixture cache", "explanation": "Generated fixture cache; user confirmed rebuildability.",
                                  "rebuildNote": "Run the fixture build again; keep source and configuration.", "limitations": ["Synthetic fixture only."], "minimumAgeDays": None}),
            ]
            if step < len(calls):
                call = calls[step]
        elif scenario == "escape" and step < 2:
            call = ("list_directory", {"path": "../private" if step == 0 else "/etc", "offset": 0})
        elif scenario == "wildcard" and step < 2:
            call = ("list_directory", {"path": ".", "offset": 0}) if step == 0 else (
                "propose_rule", {"path": "cache*", "name": "Bad wildcard", "explanation": "Must be refused.", "rebuildNote": "Unknown.", "limitations": [], "minimumAgeDays": None})
        elif scenario in ("budget", "tokens"):
            call = ("list_directory", {"path": ".", "offset": 0})
        text = "Ready" if scenario == "probe" else "Reviewed synthetic evidence. Source files remain protected."
        usage = 40_000 if scenario == "tokens" else 100
        call_id = f"call_{step}"
        if protocol == "chat_completions":
            message = {"role": "assistant", "content": None if call else text}
            if call:
                message["tool_calls"] = [{"id": call_id, "type": "function", "function": {"name": call[0], "arguments": json.dumps(call[1])}}]
            response = {"id": f"chat_{step}", "object": "chat.completion", "created": 1_700_000_000, "model": model,
                        "choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if call else "stop"}],
                        "usage": {"prompt_tokens": usage, "completion_tokens": 10, "total_tokens": usage + 10}}
        elif protocol == "responses":
            output = [{"type": "function_call", "id": f"fc_{step}", "call_id": call_id, "name": call[0], "arguments": json.dumps(call[1]), "status": "completed"}] if call else [
                {"type": "message", "id": f"msg_{step}", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": text, "annotations": []}]}]
            response = {"id": f"resp_{step}", "object": "response", "created_at": 1_700_000_000, "status": "completed", "model": model, "output": output,
                        "usage": {"input_tokens": usage, "output_tokens": 10, "total_tokens": usage + 10}}
        else:
            content = [{"type": "tool_use", "id": call_id, "name": call[0], "input": call[1]}] if call else [{"type": "text", "text": text}]
            response = {"id": f"msg_{step}", "type": "message", "role": "assistant", "model": model, "content": content,
                        "stop_reason": "tool_use" if call else "end_turn", "stop_sequence": None, "usage": {"input_tokens": usage, "output_tokens": 10}}
        data = json.dumps(response).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    global CHECKS
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="shou-ai-evidence-") as temporary:
            base = Path(temporary).resolve()
            folder = base / "files"
            (folder / "build/cache").mkdir(parents=True)
            (folder / "build/cache/output.bin").write_bytes(b"fixture" * 2048)
            if os.name != "nt":
                (folder / "build/cache*").mkdir()
            (folder / "build/.ssh").mkdir()
            (folder / "build/.ssh/private-key").write_text("DO_NOT_SEND_PRIVATE_FIXTURE")
            (folder / "source.swift").write_text("DO_NOT_SEND_FILE_CONTENT")
            env = dict(os.environ, SHOU_DATA_DIR=str(base / "records"), SHOU_AI_FIXTURE_KEY="fixture-key",
                       OPENAI_API_KEY="must-not-use-ambient-key", ANTHROPIC_API_KEY="must-not-use-ambient-key")

            def run(*args, ok=True, timeout=30):
                global CHECKS
                process = subprocess.run([str(BINARY), *args, "--json"], env=env, stdin=subprocess.DEVNULL,
                                         capture_output=True, text=True, timeout=timeout)
                assert process.stdout.strip(), (args, process.stderr)
                result = json.loads(process.stdout)
                assert result["ok"] == ok, (args, process.returncode, result, process.stderr)
                assert "SENSITIVE_PROVIDER_ERROR" not in process.stdout + process.stderr
                CHECKS += 1
                return result

            def profile(protocol, scenario, auth="environment", url=None, decision=None, main_enabled=True, strategy=None):
                connection = {"id": f"connection_{protocol}_{scenario}", "name": "Fixture", "api_protocol": protocol,
                              "base_url": url or f"http://127.0.0.1:{server.server_port}/gateway/v1", "model": f"{protocol}:{scenario}",
                              "authentication": auth, "environment_variable": "SHOU_AI_FIXTURE_KEY"}
                if decision:
                    connection["decision"]={"base_url": f"http://127.0.0.1:{server.server_port}/gateway/v1", "model": f"jev:{decision}",
                                            "authentication": "environment", "environment_variable": "SHOU_AI_FIXTURE_KEY"}
                if not main_enabled:
                    connection["main_model_enabled"]=False
                    connection["model"]=""
                if strategy:
                    connection["routing_strategy"]=strategy
                path = base / "connection.json"
                path.write_text(json.dumps(connection))
                run("ai", "connections", "save", "--file", str(path))
                return connection["id"]

            providers=run("ai", "providers")["data"]
            assert [p["id"] for p in providers] == ["jev"]
            scan = run("analysis", "scan", "--path", str(folder))["data"]["scan_id"]
            discovery = run("capabilities", "--command", "ai")["data"]["commands"]
            assert len(discovery) == 12 and {c["side_effect"] for c in discovery} == {"read", "configuration", "network"}
            for protocol in ("responses", "chat_completions", "anthropic"):
                connection = profile(protocol, "probe")
                assert run("ai", "connections", "test", "--connection-id", connection)["data"]["tool_round_trip"]
                connection = profile(protocol, "investigate")
                state = run("ai", "investigate", "--scan-id", scan, "--path", "build", "--connection-id", connection)["data"]
                assert state["status"] == "waiting" and state["steps"] == 3 and not state["advice"]
                assert run("ai", "show", "--investigation-id", state["id"])["data"]["questions"] == state["questions"]
                answers = base / "answers.json"
                answers.write_text(json.dumps({state["questions"][0]["id"]: "Generated fixture cache is rebuildable; retain source."}))
                complete = run("ai", "resume", "--investigation-id", state["id"], "--file", str(answers))["data"]
                assert complete["status"] == "complete" and complete["steps"] == 5 and len(complete["advice"]) == 1
                advice = complete["advice"][0]
                assert advice["path"] == "build/cache" and advice["rule"]["match"]["relative_patterns"] == ["build/cache"]
                assert advice["rule"]["risk"]["declared_level"] == "high"
                record = run("ai", "advice", "import", "--investigation-id", state["id"], "--advice-id", advice["id"])["data"]
                config = run("rules", "list")["data"]
                assert not any(binding["rule_id"] == advice["id"] and binding["enabled"] for binding in config["bindings"])
                assert record["rule"]["id"] == advice["id"]
                assert record["rule"]["description"] == advice["explanation"]
                assert record["rule"]["risk"]["rebuild_note"] == "Run the fixture build again; keep source and configuration."
                # Imported drafts remain outside enabled workspace bindings.
                workspace = run("workspaces", "list")["data"][0]
                preview = base / "rule.json"
                preview.write_text(json.dumps(record["rule"]))
                run("rules", "preview", "--file", str(preview), "--workspace", workspace["id"])
                run("ai", "resume", "--investigation-id", state["id"], "--file", str(answers), ok=False)
                requests = [item for item in REQUESTS if item[2]["model"] == f"{protocol}:investigate"]
                encoded = json.dumps(requests)
                assert str(folder) not in encoded and ".ssh" not in encoded and "DO_NOT_SEND" not in encoded
                assert len(requests) == 5
                suffix = {"responses": "/responses", "chat_completions": "/chat/completions", "anthropic": "/messages"}[protocol]
                assert all(path == "/gateway/v1" + suffix for path, _, _ in requests)
                headers = {k.lower(): v for k, v in requests[0][1].items()}
                assert headers["x-api-key" if protocol == "anthropic" else "authorization"] == ("fixture-key" if protocol == "anthropic" else "Bearer fixture-key")
                print(f"PASS {protocol}: tool round trip, scoped metadata, question/resume, disabled draft and native preview")

            for decision in ("supported", "uncertain", "retain", "malformed"):
                connection=profile("chat_completions", "unused_" + decision, decision=decision, main_enabled=False)
                if decision == "supported":
                    assert run("ai", "connections", "decision", "test", "--connection-id", connection)["data"]["verdict"] == "supported"
                before_main=sum(count for model,count in COUNTS.items() if not model.startswith("jev:"))
                request_args=("--request", "Retain this content for offline use; keep source and configuration.") if decision == "retain" else ()
                state=run("ai", "investigate", "--scan-id", scan, "--path", "build", "--connection-id", connection, *request_args, ok=decision != "malformed")["data"]
                if decision in ("supported", "uncertain"):
                    assert state["status"] == "waiting" and state["questions"], state
                    answers=base / "answers.json"
                    answers.write_text(json.dumps({state["questions"][0]["id"]: "Cache contains only generated fixture output; retain all source and configuration. Rebuild using fixture-build."}))
                    state=run("ai", "resume", "--investigation-id", state["id"], "--file", str(answers))["data"]
                assert bool(state["advice"]) == (decision == "supported"), state
                assert state["status"] == ("failed" if decision == "malformed" else "complete"), state
                usage={item["service"]: item for item in state["service_usage"]}
                assert usage["main"]["requests"] == 0
                assert sum(count for model,count in COUNTS.items() if not model.startswith("jev:")) == before_main
                assert usage["jev"]["requests"] > 0
                requests=[item for item in REQUESTS if item[2]["model"] == f"jev:{decision}"]
                assert requests and all(item[0] == "/gateway/v1/systemone" for item in requests)
                encoded=json.dumps(requests)
                assert str(folder) not in encoded and ".ssh" not in encoded and "DO_NOT_SEND" not in encoded
                if decision == "supported":
                    assert "Rebuild using fixture-build" in encoded
                    advice=state["advice"][0]
                    assert advice["path"] == "build/cache"
                    imported=run("ai", "advice", "import", "--investigation-id", state["id"], "--advice-id", advice["id"])["data"]
                    assert imported["rule"]["match"]["relative_patterns"] == ["build/cache"]
                print(f"PASS Jev-first {decision}: independent configuration, bounded decisions, guarded drafts and ZERO main-model calls")

            # Open-ended understanding escalates only after bounded metadata and clarification.
            connection=profile("chat_completions", "escalation", auth="none", decision="unknown")
            waiting=run("ai", "investigate", "--scan-id", scan, "--path", "build", "--connection-id", connection)["data"]
            assert waiting["status"] == "waiting" and COUNTS["chat_completions:escalation"] == 0
            answers=base / "answers.json"
            answers.write_text(json.dumps({waiting["questions"][0]["id"]: "An unfamiliar generated tool; its rebuild workflow needs open-ended explanation."}))
            escalated=run("ai", "resume", "--investigation-id", waiting["id"], "--file", str(answers))["data"]
            assert escalated["status"] == "complete" and escalated["escalation_reasons"]
            assert COUNTS["chat_completions:escalation"] == 1
            assert next(item for item in escalated["service_usage"] if item["service"] == "main")["requests"] == 1
            print("PASS necessary escalation: bounded evidence, user clarification, explicit reason, one main-model request")

            # A local measurement question makes no model requests, even with a main-only profile.
            connection=profile("chat_completions", "local_only", auth="none")
            before=len(REQUESTS)
            local=run("ai", "investigate", "--scan-id", scan, "--path", "build", "--connection-id", connection, "--goal", "space")["data"]
            assert local["status"] == "complete" and len(REQUESTS) == before
            assert all(item["requests"] == 0 for item in local["service_usage"])
            # Explicit main-only policy does not call a configured decision provider.
            connection=profile("chat_completions", "main_only", auth="none", decision="supported", strategy="main_only")
            before_jev=COUNTS["jev:supported"]
            main=run("ai", "investigate", "--scan-id", scan, "--path", "build", "--connection-id", connection)["data"]
            assert main["status"] == "complete" and COUNTS["jev:supported"] == before_jev
            assert next(item for item in main["service_usage"] if item["service"] == "main")["requests"] == 1

            for decision in ("error", "redirect", "oversized"):
                connection=profile("chat_completions", "probe", decision=decision)
                run("ai", "connections", "decision", "test", "--connection-id", connection, ok=False)
                before=sum(count for model,count in COUNTS.items() if not model.startswith("jev:"))
                failed=run("ai", "investigate", "--scan-id", scan, "--path", "build", "--connection-id", connection, ok=False)["data"]
                assert failed["status"] in ("failed", "limited")
                assert sum(count for model,count in COUNTS.items() if not model.startswith("jev:")) == before
            assert not any(path == "/must-not-follow" for path, _, _ in REQUESTS)
            print("PASS Jev response limits, redirect refusal and provider-error redaction")

            for scenario in ("escape", "wildcard", "budget", "tokens", "oversized", "error", "redirect"):
                connection = profile("chat_completions", scenario, auth="none")
                limited = scenario in ("budget", "tokens", "oversized", "error", "redirect")
                state = run("ai", "investigate", "--scan-id", scan, "--path", "build", "--connection-id", connection, ok=not limited)["data"]
                assert not state["advice"]
                assert state["status"] == ("limited" if scenario in ("budget", "tokens", "oversized") else "failed" if limited else "complete")
                if scenario == "budget":
                    assert state["steps"] <= 12
                for _, headers, body in REQUESTS:
                    if body["model"] == f"chat_completions:{scenario}":
                        assert not {k.lower() for k in headers}.intersection({"authorization", "x-api-key"})
            assert all(path != "/must-not-follow" for path, _, _ in REQUESTS)
            connection = profile("responses", "probe")
            before = len(REQUESTS)
            for invalid in ("../", "/etc", ".ssh"):
                run("ai", "investigate", "--scan-id", scan, "--path", invalid, "--connection-id", connection, ok=False)
            assert len(REQUESTS) == before
            for invalid_url in ("http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?api_key=secret", "https://example.com/v1/responses"):
                bad = base / "bad.json"
                bad.write_text(json.dumps({"id": "connection_bad", "name": "Bad", "api_protocol": "responses", "base_url": invalid_url,
                                           "model": "fixture", "authentication": "none", "environment_variable": "SHOU_AI_FIXTURE_KEY"}))
                run("ai", "connections", "save", "--file", str(bad), ok=False)

            saved=run("ai", "list")["data"]
            assert saved and len(saved)<=100 and all("connection" in item for item in saved)
            # Cross-process cancellation stops the in-flight transport and preserves evidence.
            connection=profile("chat_completions", "cross_cancel", auth="none")
            SLOW.clear()
            process=subprocess.Popen([str(BINARY),"ai","investigate","--scan-id",scan,"--path","build","--connection-id",connection,"--json"],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            assert SLOW.wait(10), "Cross-process provider request did not start"
            running=next(item for item in run("ai","list")["data"] if item["connection"]["id"]==connection)
            started=time.monotonic()
            run("ai","cancel","--investigation-id",running["id"])
            stdout,stderr=process.communicate(timeout=10)
            assert json.loads(stdout)["data"]["status"]=="cancelled", (stdout,stderr)
            assert time.monotonic()-started<4
            assert run("ai","show","--investigation-id",running["id"],ok=False)["data"]["status"]=="cancelled"
            SLOW.clear()

            def bridge(operation, fields):
                child=subprocess.Popen([str(BINARY),"--desktop-bridge"],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                child.stdin.write(json.dumps({"bridge_version":1,"request_id":"ai_config_fixture","operation":operation,"input":fields})+"\n")
                child.stdin.flush()
                result=json.loads(child.stdout.readline())
                child.stdin.close(); child.wait(timeout=10)
                assert result["kind"]=="result",result
                return result["value"]
            assert bridge("ai.providers",{})["data"][0]["id"]=="jev"
            fixture_profile={"id":"connection_bridge_fixture","name":"Bridge fixture","api_protocol":"responses","base_url":f"http://127.0.0.1:{server.server_port}/gateway/v1","model":"responses:bridge","authentication":"none","environment_variable":""}
            assert bridge("ai.connections.save",{"profile":fixture_profile})["ok"]
            assert not bridge("ai.connections.save",{"profile":dict(fixture_profile,api_key="must-not-store")})["ok"]
            assert "must-not-store" not in json.dumps(run("ai","connections","list"))
            assert bridge("storage.show",{"scan_id":scan})["data"]["root_path"].replace("\\","/")==str(folder).replace("\\","/")
            if os.name=="nt":
                COUNTS["responses:probe"]=0
                import uuid
                fixture_profile.update(id="connection_credential_"+uuid.uuid4().hex,model="responses:probe",authentication="keychain")
                assert bridge("ai.connections.save",{"profile":fixture_profile,"model_key":"fixture-key"})["ok"]
                run("ai","connections","test","--connection-id",fixture_profile["id"])
            # Cancellation travels through the desktop request task into URLSession and a saved checkpoint.
            connection = profile("chat_completions", "slow", auth="none")
            process = subprocess.Popen([str(BINARY), "--desktop-bridge"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            request = {"bridge_version": 1, "request_id": "ai_cancel_fixture", "operation": "ai.investigate", "input": {"scan_id": scan, "path": "build", "connection_id": connection}}
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            assert SLOW.wait(10), "Provider request did not start"
            started = time.monotonic()
            process.stdin.write(json.dumps({"bridge_version": 1, "request_id": "ai_cancel_fixture", "kind": "cancel"}) + "\n")
            process.stdin.flush()
            stdout, stderr = process.communicate(timeout=10)
            assert time.monotonic() - started < 4, (stdout, stderr)
            events = [json.loads(line) for line in stdout.splitlines()]
            assert any(event.get("kind") == "progress" and event.get("value", {}).get("status") == "cancelled" for event in events), events
            assert (folder / "build/cache/output.bin").read_bytes() == b"fixture" * 2048
            assert (folder / "source.swift").read_text() == "DO_NOT_SEND_FILE_CONTENT"
            assert run("history", "list")["data"] == []
            print(f"PASS {CHECKS} AI CLI checks plus desktop cancellation, scope/privacy, budgets, redirect refusal and unchanged fixture files")
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
