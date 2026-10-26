#!/usr/bin/env python3
"""Check the pre-install Open WebUI probe without a Proxmox host."""

import importlib.util
import json
import pathlib
import unittest
import urllib.error
from unittest import mock


path = pathlib.Path(__file__).with_name("verify-webui.py")
spec = importlib.util.spec_from_file_location("verify_webui", path)
verify_webui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_webui)


class Response:
    status = 200

    def __init__(self, data):
        self.data = json.dumps(data).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def read(self, _limit):
        return self.data


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.responses = {
            "/health": Response({"status": True}),
            "/api/version": Response({"version": "0.12.4"}),
        }

        def open_request(request, timeout):
            self.calls.append((request.full_url, timeout))
            result = self.responses[request.full_url.split(":8000", 1)[1]]
            if isinstance(result, Exception):
                raise result
            return result

        self.patcher = mock.patch.object(verify_webui.urllib.request, "build_opener")
        self.patcher.start().return_value.open.side_effect = open_request
        self.addCleanup(self.patcher.stop)

    def test_healthy_webui(self):
        self.assertEqual(verify_webui.probe(8000), "0.12.4")
        self.assertEqual(
            self.calls,
            [
                ("http://127.0.0.1:8000/health", 5),
                ("http://127.0.0.1:8000/api/version", 5),
            ],
        )

    def test_unhealthy_or_wrong_server_stops_before_version_check(self):
        self.responses["/health"] = Response({"status": "ok"})
        with self.assertRaisesRegex(RuntimeError, "not healthy"):
            verify_webui.probe(8000)
        self.assertEqual(len(self.calls), 1)

    def test_server_without_open_webui_version_is_rejected(self):
        self.responses["/api/version"] = Response({"name": "another app"})
        with self.assertRaisesRegex(RuntimeError, "version is missing"):
            verify_webui.probe(8000)

    def test_unreachable_service_is_rejected(self):
        self.responses["/health"] = urllib.error.URLError("connection refused")
        with self.assertRaisesRegex(RuntimeError, "connection refused"):
            verify_webui.probe(8000)


if __name__ == "__main__":
    unittest.main()
