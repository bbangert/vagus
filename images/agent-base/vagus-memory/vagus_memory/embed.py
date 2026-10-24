"""Embedder that runs inside each MCP server process.

Measured on a dragon_q6a with bge-small-en-v1.5: model load 0.64 s, a 336-word note
0.49 s, a short query 16 ms, process RSS 196 MB. That is cheap enough to give every
worker its own embedder instead of running a shared embedding service.
"""

from __future__ import annotations

import os
from collections.abc import Sequence
from typing import Any, Protocol

DEFAULT_MODEL = "BAAI/bge-small-en-v1.5"
DEFAULT_CACHE = "/opt/fastembed"


class Embedder(Protocol):
    model: str

    def embed(self, texts: Sequence[str]) -> list[list[float]]: ...

    def embed_query(self, text: str) -> list[float]: ...


class FastEmbedder:
    def __init__(self, model: str | None = None, cache_dir: str | None = None) -> None:
        self.model = model or os.environ.get("VAGUS_MEMORY_MODEL") or DEFAULT_MODEL
        self.cache_dir = cache_dir or os.environ.get("FASTEMBED_CACHE_PATH") or DEFAULT_CACHE
        self._impl: Any = None

    def _load(self) -> Any:
        # Lazy so a server whose tools never embed (status, journal) skips the model load.
        if self._impl is None:
            from fastembed import TextEmbedding

            # The model is baked into the image and nothing may be downloaded on the
            # board. FASTEMBED_CACHE_PATH alone is not enough offline: fastembed then
            # still tries the hub and fails with "Could not load model ... from any
            # source", so the cache dir and local_files_only are passed explicitly.
            self._impl = TextEmbedding(
                model_name=self.model, cache_dir=self.cache_dir, local_files_only=True
            )
        return self._impl

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        return [v.tolist() for v in self._load().embed(list(texts))]

    def embed_query(self, text: str) -> list[float]:
        # query_embed applies the model's query-side prefix where it has one.
        return next(iter(self._load().query_embed(text))).tolist()
