from __future__ import annotations

import ctypes
import os
import sys
from enum import IntEnum
from pathlib import Path

from .token import Token


class Mode(IntEnum):
    ACCURATE = 0
    FULL = 1
    SEARCH = 2


class _NxConfig(ctypes.Structure):
    # Keep this layout byte-for-byte compatible with core/include/nexaloid.h.
    _fields_ = [
        ("dict_path", ctypes.c_char_p),
        ("user_dict_path", ctypes.c_char_p),
        ("enable_hmm", ctypes.c_uint32),
        ("enable_normalization", ctypes.c_uint32),
        ("enable_plugins", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32 * 8),
    ]


class _NxToken(ctypes.Structure):
    # Token fields mirror NxToken; Python only wraps them into a dataclass.
    _fields_ = [
        ("start_byte", ctypes.c_uint32),
        ("end_byte", ctypes.c_uint32),
        ("start_char", ctypes.c_uint32),
        ("end_char", ctypes.c_uint32),
        ("word_id", ctypes.c_uint32),
        ("pos_id", ctypes.c_uint16),
        ("source", ctypes.c_uint16),
        ("flags", ctypes.c_uint16),
        ("score", ctypes.c_float),
    ]


_CALLBACK = ctypes.CFUNCTYPE(
    None,
    ctypes.POINTER(_NxToken),
    ctypes.POINTER(ctypes.c_char),
    ctypes.c_size_t,
    ctypes.c_void_p,
)

_BATCH_CALLBACK = ctypes.CFUNCTYPE(
    None,
    ctypes.c_uint32,
    ctypes.POINTER(_NxToken),
    ctypes.POINTER(ctypes.c_char),
    ctypes.c_size_t,
    ctypes.c_void_p,
)

_SOURCES = {
    1: "base_dict",
    2: "user_dict",
    3: "domain_dict",
    4: "rule",
    5: "unknown",
    6: "plugin",
}

_PACKAGE_DIR = Path(__file__).resolve().parent
_DICT_DIR = _PACKAGE_DIR / "data" / "dict"
_REPO_DICT_DIR = Path(__file__).resolve().parents[4] / "data" / "dict"
_BUILT_DICT = _DICT_DIR / "nexaloid.nxdict"
_BUILT_TEXT_DICT = _DICT_DIR / "nexaloid.tsv"
_DELETED_WORD_SCORE = -1_000_000.0


def _resolve_dict_path(dict_path: str | os.PathLike[str] | None) -> Path:
    if dict_path is not None:
        return Path(dict_path)
    repo_built = _REPO_DICT_DIR / "nexaloid.nxdict"
    if repo_built.exists():
        return repo_built
    repo_text = _REPO_DICT_DIR / "nexaloid.tsv"
    if repo_text.exists():
        return repo_text
    if _BUILT_DICT.exists():
        return _BUILT_DICT
    if _BUILT_TEXT_DICT.exists():
        return _BUILT_TEXT_DICT
    return repo_text


def _resolve_domain_dict_path(domain: str | None) -> Path | None:
    if domain is None:
        return None
    domain_dir = os.environ.get("NEXALOID_DOMAIN_DICT_DIR")
    if not domain_dir:
        raise ValueError("domain requires NEXALOID_DOMAIN_DICT_DIR")

    root = Path(domain_dir)
    for suffix in (".nxdict", ".tsv", ".txt"):
        candidate = root / f"{domain}{suffix}"
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"domain dictionary not found: {root / (domain + '.tsv')}")


def _plugin_extension() -> str:
    if sys.platform == "win32":
        return ".dll"
    if sys.platform == "darwin":
        return ".dylib"
    return ".so"


def _iter_plugin_paths(path: str | os.PathLike[str]):
    root = Path(path)
    suffix = _plugin_extension()
    for candidate in sorted(root.iterdir()):
        if candidate.is_file() and candidate.name.startswith("nexaloid_plugin") and candidate.name.endswith(suffix):
            yield candidate


def _append_deleted_fallback(out: list[Token], part: str, token: _NxToken) -> None:
    byte_offset = token.start_byte
    for index, ch in enumerate(part):
        data = ch.encode("utf-8")
        out.append(
            Token(
                text=ch,
                start_byte=byte_offset,
                end_byte=byte_offset + len(data),
                start_char=token.start_char + index,
                end_char=token.start_char + index + 1,
                pos=None,
                source="unknown",
                score=-10.0,
            )
        )
        byte_offset += len(data)


def _load_lib() -> ctypes.CDLL:
    # Bindings are thin wrappers; the native shared library does all tokenization.
    explicit = os.environ.get("NEXALOID_LIB")
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    root = Path(__file__).resolve().parents[4]
    candidates += [
        root / "core" / "zig-out" / "bin" / "nexaloid.dll",
        root / "core" / "zig-out" / "lib" / "libnexaloid.so",
        root / "core" / "zig-out" / "lib" / "libnexaloid.dylib",
        _PACKAGE_DIR / "native" / "nexaloid.dll",
        _PACKAGE_DIR / "native" / "libnexaloid.so",
        _PACKAGE_DIR / "native" / "libnexaloid.dylib",
    ]
    for path in candidates:
        if path.exists():
            return ctypes.CDLL(str(path))
    raise RuntimeError("nexaloid shared library not found; run `zig build` in core or set NEXALOID_LIB")


_LIB = _load_lib()
_LIB.nx_engine_new.argtypes = [ctypes.POINTER(_NxConfig), ctypes.POINTER(ctypes.c_void_p)]
_LIB.nx_engine_new.restype = ctypes.c_int
_LIB.nx_engine_free.argtypes = [ctypes.c_void_p]
_LIB.nx_engine_free.restype = None
_LIB.nx_load_plugin.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
_LIB.nx_load_plugin.restype = ctypes.c_int
_LIB.nx_tokenize.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_int,
    _CALLBACK,
    ctypes.c_void_p,
]
_LIB.nx_tokenize.restype = ctypes.c_int
_LIB.nx_tokenize_batch.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_char_p),
    ctypes.POINTER(ctypes.c_size_t),
    ctypes.c_size_t,
    ctypes.c_int,
    ctypes.c_uint32,
    _BATCH_CALLBACK,
    ctypes.c_void_p,
]
_LIB.nx_tokenize_batch.restype = ctypes.c_int
_LIB.nx_add_word.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_uint32,
    ctypes.c_float,
    ctypes.c_uint16,
]
_LIB.nx_add_word.restype = ctypes.c_int
_LIB.nx_reload_user_dict.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_LIB.nx_reload_user_dict.restype = ctypes.c_int
_LIB.nx_status_message.argtypes = [ctypes.c_int]
_LIB.nx_status_message.restype = ctypes.c_char_p


class NexaloidError(RuntimeError):
    pass


class Tokenizer:
    def __init__(
        self,
        dict_path: str | os.PathLike[str] | None = None,
        *,
        domain: str | None = None,
        plugin_dir: str | os.PathLike[str] | None = None,
        plugin_config_json: str | None = None,
    ):
        self._engine = ctypes.c_void_p()
        config = _NxConfig()
        resolved_dict = _resolve_dict_path(dict_path)
        resolved_domain_dict = _resolve_domain_dict_path(domain)
        if resolved_dict.exists():
            config.dict_path = str(resolved_dict).encode("utf-8")
        if resolved_domain_dict is not None:
            config.user_dict_path = str(resolved_domain_dict).encode("utf-8")
        self._check(_LIB.nx_engine_new(ctypes.byref(config), ctypes.byref(self._engine)))
        self._closed = False
        self._words: dict[str, float] = {}
        self._deleted: set[str] = set()
        if plugin_dir is not None:
            self.load_plugins(plugin_dir, plugin_config_json)

    def close(self) -> None:
        if not self._closed:
            _LIB.nx_engine_free(self._engine)
            self._engine = ctypes.c_void_p()
            self._closed = True

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass

    def add_word(self, word: str, freq: float | None = None, tag: str | None = None) -> None:
        self._ensure_open()
        del tag
        score = float(freq if freq is not None else 10.0)
        self._add_word_score(word, score)

    def _add_word_score(self, word: str, score: float) -> None:
        data = word.encode("utf-8")
        self._check(_LIB.nx_add_word(self._engine, data, len(data), 0, score, 0))
        self._words[word] = score
        self._deleted.discard(word)

    def del_word(self, word: str) -> None:
        self._ensure_open()
        self._add_word_score(word, _DELETED_WORD_SCORE)
        self._deleted.add(word)

    def load_userdict(self, path: str | os.PathLike[str]) -> None:
        self._ensure_open()
        data = str(Path(path)).encode("utf-8")
        self._check(_LIB.nx_reload_user_dict(self._engine, data))

    def load_plugin(self, path: str | os.PathLike[str], config_json: str | None = None) -> None:
        self._ensure_open()
        path_data = str(Path(path)).encode("utf-8")
        config_data = None if config_json is None else config_json.encode("utf-8")
        self._check(_LIB.nx_load_plugin(self._engine, path_data, config_data))

    def load_plugins(self, path: str | os.PathLike[str], config_json: str | None = None) -> None:
        self._ensure_open()
        for plugin_path in _iter_plugin_paths(path):
            self.load_plugin(plugin_path, config_json)

    def suggest_freq(self, segment, tune: bool = False):
        word = "".join(segment) if isinstance(segment, tuple) else str(segment)
        if tune:
            self.add_word(word, freq=20.0)
        return self._words.get(word, 0)

    def tokenize(self, text: str, mode: Mode = Mode.ACCURATE) -> list[Token]:
        self._ensure_open()
        data = text.encode("utf-8")
        out: list[Token] = []

        @_CALLBACK
        def on_token(token_ptr, text_ptr, text_len, user_data):
            del text_ptr, text_len, user_data
            token = token_ptr.contents
            part = data[token.start_byte : token.end_byte].decode("utf-8")
            if token.source == 2 and token.score <= _DELETED_WORD_SCORE:
                _append_deleted_fallback(out, part, token)
                return
            out.append(
                Token(
                    text=part,
                    start_byte=token.start_byte,
                    end_byte=token.end_byte,
                    start_char=token.start_char,
                    end_char=token.end_char,
                    pos=None,
                    source=_SOURCES.get(token.source, "unknown"),
                    score=float(token.score),
                )
            )

        self._check(_LIB.nx_tokenize(self._engine, data, len(data), int(mode), on_token, None))
        return out

    def tokenize_batch(
        self,
        texts: list[str] | tuple[str, ...],
        mode: Mode = Mode.ACCURATE,
        thread_count: int = 0,
    ) -> list[list[Token]]:
        self._ensure_open()
        encoded = [text.encode("utf-8") for text in texts]
        text_array = (ctypes.c_char_p * len(encoded))(*encoded)
        len_array = (ctypes.c_size_t * len(encoded))(*(len(item) for item in encoded))
        out: list[list[Token]] = [[] for _ in encoded]

        @_BATCH_CALLBACK
        def on_token(index, token_ptr, text_ptr, text_len, user_data):
            del text_ptr, text_len, user_data
            # Core emits batch callbacks in input order after worker threads finish.
            raw = encoded[index]
            token = token_ptr.contents
            part = raw[token.start_byte : token.end_byte].decode("utf-8")
            if token.source == 2 and token.score <= _DELETED_WORD_SCORE:
                _append_deleted_fallback(out[index], part, token)
                return
            out[index].append(
                Token(
                    text=part,
                    start_byte=token.start_byte,
                    end_byte=token.end_byte,
                    start_char=token.start_char,
                    end_char=token.end_char,
                    pos=None,
                    source=_SOURCES.get(token.source, "unknown"),
                    score=float(token.score),
                )
            )

        self._check(
            _LIB.nx_tokenize_batch(
                self._engine,
                text_array,
                len_array,
                len(encoded),
                int(mode),
                max(0, int(thread_count)),
                on_token,
                None,
            )
        )
        return out

    def cut(self, text: str, cut_all: bool = False, HMM: bool = True):
        del HMM
        mode = Mode.FULL if cut_all else Mode.ACCURATE
        for token in self.tokenize(text, mode):
            yield token.text

    def lcut(self, text: str, cut_all: bool = False, HMM: bool = True) -> list[str]:
        return list(self.cut(text, cut_all=cut_all, HMM=HMM))

    def cut_for_search(self, text: str, HMM: bool = True):
        del HMM
        seen: set[str] = set()
        for token in self.tokenize(text, Mode.SEARCH):
            if len(token.text) <= 1:
                continue
            if token.text not in seen:
                seen.add(token.text)
                yield token.text

    def _check(self, status: int) -> None:
        if status != 0:
            msg = _LIB.nx_status_message(status).decode("utf-8", "replace")
            raise NexaloidError(msg)

    def _ensure_open(self) -> None:
        if self._closed:
            raise NexaloidError("tokenizer is closed")
