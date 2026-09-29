"""Stand-ins for airllm, transformers and torch so server.py tests run fast.

They are injected into sys.modules before server.py is imported. That only
works because server.py imports them lazily inside functions; if someone
moves those imports to module scope, test_server.py fails loudly on purpose.
"""

from __future__ import annotations

import queue
import sys
import threading
import types
from typing import Any, Dict, List, Optional


class FakeTensor:
    """Just enough of a 2-D torch tensor: shape, [:, a:b] slicing and .to()."""

    def __init__(self, ids: List[int], device: str = "cpu") -> None:
        self.ids = list(ids)
        self.shape = (1, len(self.ids))
        self.device = device

    def __getitem__(self, key) -> "FakeTensor":
        _, cols = key
        return FakeTensor(self.ids[cols], self.device)

    def to(self, device: str) -> "FakeTensor":
        return FakeTensor(self.ids, device)


class FakeTokenizer:
    """One token per whitespace-separated word; token id = word length."""

    def __init__(self, chat_template: Optional[str] = "present") -> None:
        self.chat_template = chat_template
        self.last_call: Dict[str, Any] = {}

    def __call__(self, text: str, **kwargs) -> Dict[str, Any]:
        self.last_call = {"text": text, **kwargs}
        ids = self.encode(text)
        if kwargs.get("add_special_tokens", True):
            ids = [1] + ids  # a BOS, so tests can see whether one was added
        return {"input_ids": FakeTensor(ids)}

    def encode(self, text: str, **_kwargs) -> List[int]:
        return [len(word) for word in text.split()]

    def apply_chat_template(self, messages, tokenize=False, add_generation_prompt=False) -> str:
        parts = [f"<{m['role']}>{m['content']}</{m['role']}>" for m in messages]
        if add_generation_prompt:
            parts.append("<assistant>")
        return "".join(parts)


class FakeConfig:
    model_type = "qwen2"


class FakeModel:
    """Emits a fixed reply one word at a time, honouring the stop criteria."""

    REPLY = ["Hello", " there", " from", " AirLLM", "!"]

    def __init__(self, tokenizer: FakeTokenizer, fail_with: Optional[Exception] = None) -> None:
        self.tokenizer = tokenizer
        self.config = FakeConfig()
        self.fail_with = fail_with
        self.calls: List[Dict[str, Any]] = []
        self.concurrent = 0
        self.max_concurrent = 0
        self.delay = 0.0
        self.started = threading.Event()
        self._lock = threading.Lock()

    def generate(self, **kwargs) -> None:
        with self._lock:
            self.concurrent += 1
            self.max_concurrent = max(self.max_concurrent, self.concurrent)
        try:
            self.calls.append(kwargs)
            self.started.set()
            if self.fail_with is not None:
                raise self.fail_with
            streamer = kwargs["streamer"]
            criteria = kwargs.get("stopping_criteria") or []
            budget = kwargs.get("max_new_tokens", 256)
            for index, token in enumerate(self.REPLY):
                if index >= budget:
                    break
                if any(check(None, None) for check in criteria):
                    break
                if self.delay:
                    threading.Event().wait(self.delay)
                streamer.put_text(token)
        finally:
            with self._lock:
                self.concurrent -= 1


class FakeTextIteratorStreamer:
    def __init__(self, tokenizer, skip_prompt=True, skip_special_tokens=True, timeout=None):
        self.tokenizer = tokenizer
        self.timeout = timeout
        self._queue: "queue.Queue[Any]" = queue.Queue()
        self._stop = object()

    def put_text(self, text: str) -> None:
        self._queue.put(text)

    def end(self) -> None:
        self._queue.put(self._stop)

    def __iter__(self):
        return self

    def __next__(self):
        item = self._queue.get(timeout=self.timeout)
        if item is self._stop:
            raise StopIteration
        return item


class FakeStoppingCriteria:
    def __call__(self, input_ids, scores, **kwargs) -> bool:
        return False


class FakeStoppingCriteriaList(list):
    pass


def install(model: Optional[FakeModel], load_error: Optional[BaseException] = None) -> types.ModuleType:
    """Register fake airllm, transformers and torch modules; return fake torch."""
    airllm = types.ModuleType("airllm")

    class AutoModel:
        last_kwargs: Dict[str, Any] = {}
        last_model_id = ""

        @staticmethod
        def from_pretrained(model_id: str, **kwargs):
            AutoModel.last_kwargs = dict(kwargs)
            AutoModel.last_model_id = model_id
            if load_error is not None:
                raise load_error
            return model

    airllm.AutoModel = AutoModel
    sys.modules["airllm"] = airllm

    transformers = types.ModuleType("transformers")
    transformers.TextIteratorStreamer = FakeTextIteratorStreamer
    transformers.StoppingCriteria = FakeStoppingCriteria
    transformers.StoppingCriteriaList = FakeStoppingCriteriaList
    sys.modules["transformers"] = transformers

    torch = types.ModuleType("torch")
    torch.seeds = []
    torch.manual_seed = lambda seed: torch.seeds.append(seed)
    sys.modules["torch"] = torch
    return torch
