#!/usr/bin/env python3
"""model_choices.py: the chat models offered to the Honcho provisioner."""
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "honcho_model_choices", Path(__file__).with_name("model_choices.py"))
choices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(choices)

OLLAMA = "http://192.0.2.90:11434"
INVENTORY = {"models": [
    {"server": OLLAMA, "name": "qwen3:14b", "tools": True, "context_length": 65536,
     "params_b": 14.8, "loaded": False, "is_embedding": False},
    {"server": "http://192.0.2.91:11434", "name": "qwen3:14b", "tools": True, "context_length": 131072,
     "params_b": 14.8, "loaded": True, "is_embedding": False},
    {"server": OLLAMA, "name": "qwen3:32b", "tools": True, "context_length": 65536,
     "params_b": 32.8, "loaded": False, "is_embedding": False},
    {"server": "strata+http://192.0.2.92:8080", "name": "qwen3.8-flash-next", "tools": True,
     "context_length": 32768, "params_b": 125, "loaded": True, "is_embedding": False},
    {"server": OLLAMA, "name": "gemma3:12b", "tools": None, "context_length": 131072,
     "params_b": 12, "loaded": False, "is_embedding": False},
    {"server": "http://192.0.2.93:11434", "name": "airllm-72b", "tools": False, "context_length": 2048,
     "params_b": 72, "loaded": False, "is_embedding": False},
    {"server": OLLAMA, "name": "mystery", "tools": True, "context_length": None, "is_embedding": False},
    {"server": OLLAMA, "name": "nomic-embed-text:latest", "tools": None, "context_length": 2048,
     "loaded": False, "is_embedding": True},
    {"server": OLLAMA, "name": "bge-m3", "tools": None, "context_length": 8192,
     "loaded": True, "is_embedding": True},
    {"name": ""}, "not an entry",
]}


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = choices.main(list(argv))
    return status, out.getvalue(), err.getvalue()


class InventoryTest(unittest.TestCase):
    def setUp(self):
        handle, self.path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(handle, "w") as out:
            json.dump(INVENTORY, out)

    def tearDown(self):
        os.unlink(self.path)

    def test_chat_offers_what_the_proxy_accepts_best_first(self):
        status, out, err = run("chat", self.path, "65536")
        self.assertEqual(0, status)
        lines = [line.split("\t") for line in out.splitlines()]
        self.assertEqual(["qwen3:14b", "qwen3:32b"], [line[0] for line in lines],
                         "a loaded model first, then the larger one")
        self.assertEqual("131072-token context, 14.8B, loaded, on 2 servers", lines[0][1],
                         "a model on two servers is one choice, described by its best entry")
        self.assertEqual("http://192.0.2.91:11434/v1", lines[0][2])
        self.assertIn("qwen3.8-flash-next (32768-token context)", err)
        self.assertIn("gemma3:12b (tool support not reported)", err)
        self.assertIn("airllm-72b (no tool support)", err)
        self.assertIn("mystery (no reported context)", err)
        self.assertNotIn("nomic", out + err, "embedding models are not chat models")

    def test_a_smaller_window_admits_more(self):
        _, out, _ = run("chat", self.path, "32768")
        self.assertEqual("qwen3.8-flash-next", out.splitlines()[0].split("\t")[0], "loaded, 125B")
        self.assertEqual("http://192.0.2.92:8080/v1", out.splitlines()[0].split("\t")[2],
                         "a kind prefix is not part of the URL")

    def test_an_empty_inventory_offers_nothing(self):
        with open(self.path, "w") as out:
            json.dump({"models": []}, out)
        self.assertEqual((0, "", ""), run("chat", self.path, "65536"))

    def test_bad_usage(self):
        self.assertEqual(2, run("chat", self.path)[0])
        self.assertEqual(2, run("embedding", self.path)[0], "embedding models are not chosen any more")


if __name__ == "__main__":
    unittest.main()
