#!/usr/bin/env python3
"""The MCP registration preserves existing Open WebUI connections and grants."""
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location(
    "honcho_webui", Path(__file__).with_name("integrate-webui.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def whoami(request, key, body=None):
    """The gateway's answer to /osr/v1/whoami, or None for another URL."""
    if not request.full_url.endswith("/osr/v1/whoami"):
        return None
    if request.get_header("Authorization") != "Bearer " + key:
        raise HTTPError(request.full_url, 401, "Invalid API key", {}, None)
    return Response(json.dumps(body or {"client": "openwebui", "user": None,
                                        "workspace": None, "per_user": True}).encode())


class IntegrationTest(unittest.TestCase):
    def test_add_then_update_without_losing_other_connections_or_grants(self):
        with tempfile.TemporaryDirectory() as directory:
            admin = Path(directory, "admin")
            key = Path(directory, "honcho")
            admin.write_text("webui-secret")
            key.write_text("honcho-secret")
            original = {"url": "http://other/mcp", "type": "mcp",
                        "info": {"id": "other"}, "path": "/mcp"}
            state = [original]
            calls = []

            def fake_urlopen(request, timeout):
                answer = whoami(request, key.read_text())
                if answer is not None:
                    self.assertEqual("http://192.0.2.85:3000/osr/v1/whoami", request.full_url)
                    calls.append("WHOAMI")
                    return answer
                self.assertEqual(request.get_header("Authorization"),
                                 "Bearer webui-secret")
                self.assertEqual(timeout, 20)
                calls.append(request.get_method())
                if request.data is not None:
                    state[:] = json.loads(request.data)["TOOL_SERVER_CONNECTIONS"]
                return Response(json.dumps(
                    {"TOOL_SERVER_CONNECTIONS": state}).encode())

            argv = ["integrate-webui.py", "http://127.0.0.1:8080",
                    str(admin), str(key), "http://192.0.2.85:3000"]
            with patch.object(module, "urlopen", fake_urlopen), \
                 patch.object(sys, "argv", argv):
                with patch.object(sys, "argv", ["integrate-webui.py", "--check",
                                                "http://127.0.0.1:8080", str(admin)]):
                    module.main()
                self.assertEqual(["GET"], calls)
                calls.clear()
                module.main()
                self.assertEqual(["GET", "WHOAMI", "POST"], calls)
                self.assertEqual(original, state[0])
                self.assertEqual("http://192.0.2.85:3000/mcp", state[1]["url"])
                self.assertEqual("honcho-secret", state[1]["key"])
                self.assertEqual("/mcp", state[1]["path"])
                # Open WebUI fills in each user's ID; the gateway gives each a workspace.
                self.assertEqual({"X-User-Id": "{{USER_ID}}"}, state[1]["headers"])
                state[1]["config"]["access_grants"] = [{"principal_id": "group-1"}]
                # An older registration named the shared workspace; an admin added a header.
                state[1]["headers"] = {"X-Honcho-Workspace-ID": "osr", "x-user-id": "fixed",
                                       "X-Trace": "on"}
                state[1]["info"]["name"] = "My Memory"
                key.write_text("rotated-secret")
                calls.clear()
                module.main()
                self.assertEqual(["GET", "WHOAMI", "POST"], calls)
                self.assertEqual("rotated-secret", state[1]["key"])
                self.assertEqual({"X-Trace": "on", "X-User-Id": "{{USER_ID}}"}, state[1]["headers"])
                self.assertEqual("My Memory", state[1]["info"]["name"])
                self.assertEqual([{"principal_id": "group-1"}],
                                 state[1]["config"]["access_grants"])
                calls.clear()
                module.main()
                self.assertEqual(["GET", "WHOAMI"], calls)

    def test_a_key_the_gateway_does_not_accept_for_open_webui_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            admin = Path(directory, "admin")
            key = Path(directory, "honcho")
            admin.write_text("webui-secret")
            key.write_text("agent-key")
            argv = ["integrate-webui.py", "http://127.0.0.1:8080", str(admin), str(key),
                    "http://192.0.2.85:3000"]
            for answer, message in (
                    ({"client": "hermes-201", "workspace": "osr", "per_user": False}, "hermes-201"),
                    (HTTPError("u", 401, "Invalid API key", {}, None), "rejected the key"),
                    (HTTPError("u", 404, "Not Found", {}, None), "no client gateway")):
                writes = []

                def fake_urlopen(request, timeout, answer=answer, writes=writes):
                    if request.full_url.endswith("/osr/v1/whoami"):
                        if isinstance(answer, HTTPError):
                            raise answer
                        return Response(json.dumps(answer).encode())
                    writes.append(request.get_method())
                    return Response(json.dumps({"TOOL_SERVER_CONNECTIONS": []}).encode())
                with patch.object(module, "urlopen", fake_urlopen), patch.object(sys, "argv", argv):
                    with self.assertRaisesRegex(ValueError, message):
                        module.main()
                self.assertNotIn("POST", writes)


class SnapshotRestoreTest(unittest.TestCase):
    """--snapshot/--restore put back the Honcho connection a failed rotation replaced."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.dir = Path(directory.name)
        (self.dir / "admin").write_text("webui-secret")
        (self.dir / "honcho").write_text("new-key")
        self.snapshot = str(self.dir / "snapshot.json")
        self.state = []
        self.posts = 0

    def run_main(self, *args):
        def fake_urlopen(request, timeout):
            answer = whoami(request, (self.dir / "honcho").read_text())
            if answer is not None:
                return answer
            self.assertEqual(request.get_header("Authorization"), "Bearer webui-secret")
            if request.data is not None:
                self.posts += 1
                self.state[:] = json.loads(request.data)["TOOL_SERVER_CONNECTIONS"]
            return Response(json.dumps({"TOOL_SERVER_CONNECTIONS": self.state}).encode())
        with patch.object(module, "urlopen", fake_urlopen), \
             patch.object(sys, "argv", ["integrate-webui.py", *args]):
            module.main()

    def snapshot_args(self, mode):
        return (mode, "http://127.0.0.1:8080", str(self.dir / "admin"), self.snapshot)

    def register(self):
        self.run_main("http://127.0.0.1:8080", str(self.dir / "admin"),
                      str(self.dir / "honcho"), "http://192.0.2.85:3000")

    def test_restore_puts_back_the_old_connection_in_place(self):
        before = {"type": "mcp", "url": "http://other/mcp", "info": {"id": "before"}}
        old = {"type": "mcp", "url": "http://192.0.2.85:3000/mcp", "key": "old-key",
               "config": {"enable": True, "access_grants": [{"principal_id": "group-1"}]},
               "info": {"id": "honcho", "name": "My Memory"}}
        after = {"type": "openapi", "url": "http://tools", "info": {"id": "after"}}
        self.state[:] = [before, old, after]
        self.run_main(*self.snapshot_args("--snapshot"))
        self.assertEqual(0, self.posts, "a snapshot never writes to Open WebUI")
        if os.name == "posix":
            self.assertEqual(0o600, Path(self.snapshot).stat().st_mode & 0o777)
        self.register()
        self.assertEqual("new-key", self.state[-1]["key"])
        self.run_main(*self.snapshot_args("--restore"))
        self.assertEqual([before, old, after], self.state)
        posts = self.posts
        self.run_main(*self.snapshot_args("--restore"))
        self.assertEqual(posts, self.posts, "an unchanged list is not written again")

    def test_restore_removes_a_connection_that_did_not_exist(self):
        other = {"type": "mcp", "url": "http://other/mcp", "info": {"id": "other"}}
        self.state[:] = [other]
        self.run_main(*self.snapshot_args("--snapshot"))
        self.register()
        self.assertEqual(2, len(self.state))
        self.run_main(*self.snapshot_args("--restore"))
        self.assertEqual([other], self.state)

    def test_an_invalid_snapshot_is_refused_without_a_write(self):
        self.state[:] = [{"type": "mcp", "info": {"id": "honcho"}, "key": "k"}]
        for bad in ({"position": -1, "connections": []},
                    {"position": 0, "connections": [{"info": {"id": "other"}}]},
                    {"position": "0", "connections": []},
                    {"position": True, "connections": []},
                    ["not a snapshot"]):
            Path(self.snapshot).write_text(json.dumps(bad))
            with self.assertRaises(ValueError):
                self.run_main(*self.snapshot_args("--restore"))
        self.assertEqual(0, self.posts)

    def test_other_connection_with_non_object_info_is_preserved(self):
        other = {"type": "mcp", "url": "http://other/mcp", "info": "legacy"}
        self.state[:] = [other]
        self.run_main(*self.snapshot_args("--snapshot"))
        self.register()
        self.run_main(*self.snapshot_args("--restore"))
        self.assertEqual([other], self.state)

    def test_check_only_reads(self):
        self.run_main("--check", "http://127.0.0.1:8080", str(self.dir / "admin"))
        self.assertEqual(0, self.posts)
        with self.assertRaises(ValueError):
            self.run_main("--check", "http://127.0.0.1:8080")

    def test_check_rejects_a_response_without_tool_server_connections(self):
        def fake_urlopen(*_args, **_kwargs):
            return Response(b"{}")
        with patch.object(module, "urlopen", fake_urlopen), \
             patch.object(sys, "argv", ["integrate-webui.py", "--check",
                                        "http://127.0.0.1:8080", str(self.dir / "admin")]):
            with self.assertRaises(ValueError):
                module.main()


if __name__ == "__main__":
    unittest.main()
