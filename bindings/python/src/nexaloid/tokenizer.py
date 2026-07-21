from __future__ import annotations

import ctypes
import json
import math
import os
import re
import sys
import threading
import warnings
from enum import IntEnum
from pathlib import Path

from .token import Token


class Mode(IntEnum):
    ACCURATE = 0
    FULL = 1
    SEARCH = 2
    RECALL_SEARCH = 3


class _NxConfig(ctypes.Structure):
    # Keep this layout byte-for-byte compatible with core/include/nexaloid.h.
    _fields_ = [
        ("dict_path", ctypes.c_char_p),
        ("user_dict_path", ctypes.c_char_p),
        ("enable_hmm", ctypes.c_uint32),
        ("enable_normalization", ctypes.c_uint32),
        ("enable_plugins", ctypes.c_uint32),
        ("preserve_whitespace", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32 * 7),
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
_RULE_NAMES = (
    "url",
    "email",
    "timestamp",
    "windows_path",
    "ipv6",
    "number_unit",
    "market_day",
    "ascii_term",
)
_RULE_INDEX = {name: index for index, name in enumerate(_RULE_NAMES)}
_RULE_ALL_MASK = (1 << len(_RULE_NAMES)) - 1
_RULE_DEFAULT_SCORES = [300.0, 300.0, 300.0, 300.0, 300.0, 300.0, 300.0, 3.0]

_PACKAGE_DIR = Path(__file__).resolve().parent
_DICT_DIR = _PACKAGE_DIR / "data" / "dict"
_HMM_DIR = _PACKAGE_DIR / "data" / "hmm"
_ENTITY_DIR = _PACKAGE_DIR / "data" / "entity"
_REPO_DICT_DIR = Path(__file__).resolve().parents[4] / "data" / "dict"
_REPO_HMM_DIR = Path(__file__).resolve().parents[4] / "data" / "hmm"
_REPO_ENTITY_DIR = Path(__file__).resolve().parents[4] / "data" / "entity"
_BUILT_DICT = _DICT_DIR / "nexaloid.nxdict"
_BUILT_TEXT_DICT = _DICT_DIR / "nexaloid.tsv"
_HMM_ARTIFACT = "bmes_hmm_wordhub_lattice.nxhmm"
_HMM_MANIFEST = "bmes_hmm_wordhub_lattice.manifest.json"
_ENTITY_ARTIFACT = "entity_bmes_perceptron.nxbmes"
_ENTITY_MANIFEST = "entity_bmes_perceptron.manifest.json"
_DELETED_WORD_SCORE = -1_000_000.0
_MAX_HMM_SEARCH_CHARS = 256
_MAX_HMM_SEARCH_CACHE = 1024


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


def hmm_artifact_path() -> Path:
    repo_artifact = _REPO_HMM_DIR / _HMM_ARTIFACT
    if repo_artifact.exists():
        return repo_artifact
    return _HMM_DIR / _HMM_ARTIFACT


def hmm_manifest_path() -> Path:
    repo_manifest = _REPO_HMM_DIR / _HMM_MANIFEST
    if repo_manifest.exists():
        return repo_manifest
    return _HMM_DIR / _HMM_MANIFEST


def hmm_manifest() -> dict:
    return json.loads(hmm_manifest_path().read_text(encoding="utf-8"))


def entity_artifact_path() -> Path:
    repo_artifact = _REPO_ENTITY_DIR / _ENTITY_ARTIFACT
    if repo_artifact.exists():
        return repo_artifact
    return _ENTITY_DIR / _ENTITY_ARTIFACT


def entity_manifest_path() -> Path:
    repo_manifest = _REPO_ENTITY_DIR / _ENTITY_MANIFEST
    if repo_manifest.exists():
        return repo_manifest
    return _ENTITY_DIR / _ENTITY_MANIFEST


def entity_manifest() -> dict:
    return json.loads(entity_manifest_path().read_text(encoding="utf-8"))


def _resolve_domain_dict_path(domain: str | None) -> Path | None:
    if domain is None:
        return None
    if re.fullmatch(r"[A-Za-z0-9_-]{1,64}", domain) is None:
        raise ValueError("domain must contain only letters, digits, underscores, and hyphens")
    domain_dir = os.environ.get("NEXALOID_DOMAIN_DICT_DIR")
    if not domain_dir:
        raise ValueError("domain requires NEXALOID_DOMAIN_DICT_DIR")

    root = Path(domain_dir).resolve(strict=True)
    for suffix in (".nxdict", ".tsv", ".txt"):
        candidate = root / f"{domain}{suffix}"
        if candidate.is_file():
            resolved = candidate.resolve(strict=True)
            try:
                resolved.relative_to(root)
            except ValueError as exc:
                raise ValueError("domain dictionary resolves outside NEXALOID_DOMAIN_DICT_DIR") from exc
            return resolved
    raise FileNotFoundError(f"domain dictionary not found: {root / (domain + '.tsv')}")


def _plugin_extension() -> str:
    if sys.platform == "win32":
        return ".dll"
    if sys.platform == "darwin":
        return ".dylib"
    return ".so"


def _hmm_plugin_name() -> str:
    if sys.platform == "win32":
        return "nexaloid_plugin_hmm_lattice.dll"
    if sys.platform == "darwin":
        return "nexaloid_plugin_hmm_lattice.dylib"
    return "nexaloid_plugin_hmm_lattice.so"


def _entity_plugin_name() -> str:
    if sys.platform == "win32":
        return "nexaloid_plugin_entity_bmes.dll"
    if sys.platform == "darwin":
        return "nexaloid_plugin_entity_bmes.dylib"
    return "nexaloid_plugin_entity_bmes.so"


def _resolve_hmm_plugin_path() -> Path:
    explicit = os.environ.get("NEXALOID_HMM_PLUGIN")
    if explicit:
        return Path(explicit)
    name = _hmm_plugin_name()
    root = Path(__file__).resolve().parents[4]
    candidates = [
        _PACKAGE_DIR / "native" / name,
        root / "core" / "zig-out" / "lib" / name,
        root / "core" / "zig-out" / "bin" / name,
    ]
    for path in candidates:
        if path.exists():
            return path
    return candidates[0]


def entity_plugin_path() -> Path:
    explicit = os.environ.get("NEXALOID_ENTITY_BMES_PLUGIN")
    if explicit:
        return Path(explicit)
    name = _entity_plugin_name()
    root = Path(__file__).resolve().parents[4]
    candidates = [
        _PACKAGE_DIR / "native" / name,
        root / "core" / "zig-out" / "lib" / name,
        root / "core" / "zig-out" / "bin" / name,
    ]
    for path in candidates:
        if path.exists():
            return path
    return candidates[0]


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
                flags=0,
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
_LIB.nx_set_rule_config.argtypes = [
    ctypes.c_void_p,
    ctypes.c_uint32,
    ctypes.POINTER(ctypes.c_float),
    ctypes.c_size_t,
]
_LIB.nx_set_rule_config.restype = ctypes.c_int
_LIB.nx_load_rules_json.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
_LIB.nx_load_rules_json.restype = ctypes.c_int
_LIB.nx_clear_rules.argtypes = [ctypes.c_void_p]
_LIB.nx_clear_rules.restype = ctypes.c_int
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


def _normalize_rule_config(rule_config: dict | None) -> tuple[int, list[float]] | None:
    if rule_config is None:
        return None
    enabled_mask = _RULE_ALL_MASK
    scores = list(_RULE_DEFAULT_SCORES)

    def apply_rule(name: str, value) -> None:
        nonlocal enabled_mask
        if name not in _RULE_INDEX:
            raise ValueError(f"unknown rule: {name}")
        bit = 1 << _RULE_INDEX[name]
        if isinstance(value, bool):
            enabled_mask = enabled_mask | bit if value else enabled_mask & ~bit
            return
        if not isinstance(value, dict):
            raise TypeError(f"rule config for {name} must be bool or dict")
        if "enabled" in value:
            enabled_mask = enabled_mask | bit if bool(value["enabled"]) else enabled_mask & ~bit
        if "score" in value:
            score = float(value["score"])
            if not math.isfinite(score):
                raise ValueError(f"rule score for {name} must be finite")
            scores[_RULE_INDEX[name]] = score

    for key, value in rule_config.items():
        if key in ("custom_rules", "version"):
            continue
        if key == "builtin_rules":
            for rule_name, rule_value in value.items():
                apply_rule(rule_name, rule_value)
        elif key == "scores":
            for rule_name, score in value.items():
                apply_rule(rule_name, {"score": score})
        else:
            apply_rule(key, value)
    return enabled_mask, scores


def _custom_rules_json(rule_config: dict | None) -> str | None:
    if not rule_config or "custom_rules" not in rule_config:
        return None
    return json.dumps({"version": rule_config.get("version", 1), "rules": rule_config["custom_rules"]}, ensure_ascii=False)


class Tokenizer:
    def __init__(
        self,
        dict_path: str | os.PathLike[str] | None = None,
        *,
        domain: str | None = None,
        plugin_dir: str | os.PathLike[str] | None = None,
        plugin_config_json: str | None = None,
        rule_config: dict | None = None,
        preserve_whitespace: bool = False,
    ):
        self._lock = threading.RLock()
        self._closed = False
        self._engine = ctypes.c_void_p()
        self._hmm_engine: ctypes.c_void_p | None = None
        self._hmm_plugin_path: Path | None = None
        self._hmm_config_json: str | None = None
        self._hmm_ready = False
        self._plugins_loaded = False
        self._hmm_search_cache: dict[str, tuple[tuple[int, str], ...]] = {}
        self._words: dict[str, float] = {}
        self._deleted: set[str] = set()

        resolved_dict = _resolve_dict_path(dict_path)
        resolved_domain_dict = _resolve_domain_dict_path(domain)
        self._dict_path = resolved_dict if resolved_dict.exists() else None
        self._user_dict_path = resolved_domain_dict
        self._rule_config = _normalize_rule_config(rule_config)
        self._rules_json = _custom_rules_json(rule_config)
        self._preserve_whitespace = bool(preserve_whitespace)
        self._engine = self._open_engine()
        try:
            if plugin_dir is not None:
                self.load_plugins(plugin_dir, plugin_config_json)
        except BaseException:
            self.close()
            raise

    def _open_engine(self) -> ctypes.c_void_p:
        engine = ctypes.c_void_p()
        config = _NxConfig()
        resolved_dict = self._dict_path
        resolved_user_dict = self._user_dict_path
        if resolved_dict is not None and resolved_dict.exists():
            config.dict_path = str(resolved_dict).encode("utf-8")
        if resolved_user_dict is not None:
            config.user_dict_path = str(resolved_user_dict).encode("utf-8")
        config.preserve_whitespace = 1 if self._preserve_whitespace else 0
        self._check(_LIB.nx_engine_new(ctypes.byref(config), ctypes.byref(engine)))
        try:
            self._apply_rule_config(engine)
            self._apply_custom_rules(engine)
        except BaseException:
            _LIB.nx_engine_free(engine)
            raise
        return engine

    def _apply_rule_config(self, engine: ctypes.c_void_p) -> None:
        if self._rule_config is None:
            return
        enabled_mask, scores = self._rule_config
        score_array = (ctypes.c_float * len(scores))(*scores)
        self._check(_LIB.nx_set_rule_config(engine, enabled_mask, score_array, len(scores)))

    def _apply_custom_rules(self, engine: ctypes.c_void_p) -> None:
        if self._rules_json is None:
            return
        data = self._rules_json.encode("utf-8")
        self._check(_LIB.nx_load_rules_json(engine, data, len(data)))

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            if self._hmm_engine is not None:
                _LIB.nx_engine_free(self._hmm_engine)
                self._hmm_engine = None
            if self._engine.value is not None:
                _LIB.nx_engine_free(self._engine)
            self._engine = ctypes.c_void_p()
            self._closed = True

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass

    def add_word(self, word: str, freq: float | None = None, tag: str | None = None) -> None:
        with self._lock:
            self._ensure_open()
            if not word:
                raise ValueError("word must not be empty")
            if tag is not None:
                warnings.warn("tag is ignored because Nexaloid does not provide POS tagging", RuntimeWarning, stacklevel=2)
            score = float(freq if freq is not None else 10.0)
            if not math.isfinite(score):
                raise ValueError("word score must be finite")
            self._add_word_score(word, score)

    def _add_word_score(self, word: str, score: float) -> None:
        data = word.encode("utf-8")
        self._check(_LIB.nx_add_word(self._engine, data, len(data), 0, score, 0))
        if self._hmm_engine is not None:
            self._check(_LIB.nx_add_word(self._hmm_engine, data, len(data), 0, score, 0))
        self._words[word] = score
        self._deleted.discard(word)
        self._hmm_search_cache.clear()

    def del_word(self, word: str) -> None:
        with self._lock:
            self._ensure_open()
            if not word:
                raise ValueError("word must not be empty")
            self._add_word_score(word, _DELETED_WORD_SCORE)
            self._deleted.add(word)

    def load_userdict(self, path: str | os.PathLike[str]) -> None:
        with self._lock:
            self._ensure_open()
            resolved = Path(path)
            data = str(resolved).encode("utf-8")
            self._check(_LIB.nx_reload_user_dict(self._engine, data))
            if self._hmm_engine is not None:
                self._check(_LIB.nx_reload_user_dict(self._hmm_engine, data))
            self._user_dict_path = resolved
            self._hmm_search_cache.clear()

    def load_plugin(self, path: str | os.PathLike[str], config_json: str | None = None) -> None:
        with self._lock:
            self._ensure_open()
            path_data = str(Path(path)).encode("utf-8")
            config_data = None if config_json is None else config_json.encode("utf-8")
            self._check(_LIB.nx_load_plugin(self._engine, path_data, config_data))
            self._plugins_loaded = True

    def load_plugins(self, path: str | os.PathLike[str], config_json: str | None = None) -> None:
        with self._lock:
            self._ensure_open()
            for plugin_path in _iter_plugin_paths(path):
                self.load_plugin(plugin_path, config_json)

    def load_rules_json(self, json_text: str) -> None:
        with self._lock:
            self._ensure_open()
            data = json_text.encode("utf-8")
            self._check(_LIB.nx_load_rules_json(self._engine, data, len(data)))
            if self._hmm_engine is not None:
                self._check(_LIB.nx_load_rules_json(self._hmm_engine, data, len(data)))
            self._rules_json = json_text
            self._hmm_search_cache.clear()

    def load_rules(self, path: str | os.PathLike[str]) -> None:
        with self._lock:
            self.load_rules_json(Path(path).read_text(encoding="utf-8"))

    def clear_rules(self) -> None:
        with self._lock:
            self._ensure_open()
            self._check(_LIB.nx_clear_rules(self._engine))
            if self._hmm_engine is not None:
                self._check(_LIB.nx_clear_rules(self._hmm_engine))
            self._rules_json = None
            self._hmm_search_cache.clear()

    def suggest_freq(self, segment, tune: bool = False):
        with self._lock:
            self._ensure_open()
            word = "".join(segment) if isinstance(segment, tuple) else str(segment)
            if tune:
                self.add_word(word, freq=20.0)
            return self._words.get(word, 0)

    def _tokenize_with_engine(self, engine: ctypes.c_void_p, text: str, mode: Mode = Mode.ACCURATE) -> list[Token]:
        with self._lock:
            self._ensure_open()
            data = text.encode("utf-8")
            out: list[Token] = []
            callback_error: BaseException | None = None

            @_CALLBACK
            def on_token(token_ptr, text_ptr, text_len, user_data):
                nonlocal callback_error
                del text_ptr, text_len, user_data
                if callback_error is not None:
                    return
                try:
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
                            flags=int(token.flags),
                        )
                    )
                except BaseException as exc:
                    callback_error = exc

            status = _LIB.nx_tokenize(engine, data, len(data), int(mode), on_token, None)
            if callback_error is not None:
                raise callback_error
            self._check(status)
            return out

    def tokenize(self, text: str, mode: Mode = Mode.ACCURATE) -> list[Token]:
        with self._lock:
            return self._tokenize_with_engine(self._engine, text, mode)

    def tokenize_batch(
        self,
        texts: list[str] | tuple[str, ...],
        mode: Mode = Mode.ACCURATE,
        thread_count: int = 0,
    ) -> list[list[Token]]:
        with self._lock:
            self._ensure_open()
            encoded = [text.encode("utf-8") for text in texts]
            text_array = (ctypes.c_char_p * len(encoded))(*encoded)
            len_array = (ctypes.c_size_t * len(encoded))(*(len(item) for item in encoded))
            out: list[list[Token]] = [[] for _ in encoded]
            callback_error: BaseException | None = None

            @_BATCH_CALLBACK
            def on_token(index, token_ptr, text_ptr, text_len, user_data):
                nonlocal callback_error
                del text_ptr, text_len, user_data
                if callback_error is not None:
                    return
                try:
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
                            flags=int(token.flags),
                        )
                    )
                except BaseException as exc:
                    callback_error = exc

            status = _LIB.nx_tokenize_batch(
                self._engine,
                text_array,
                len_array,
                len(encoded),
                int(mode),
                max(0, int(thread_count)),
                on_token,
                None,
            )
            if callback_error is not None:
                raise callback_error
            self._check(status)
            return out

    def _token_texts(self, text: str, mode: Mode, HMM: bool = False) -> list[str]:
        with self._lock:
            if HMM and mode == Mode.ACCURATE:
                return self._hmm_overlay_texts(text)
            return [token.text for token in self._tokenize_with_engine(self._engine_for_hmm(HMM), text, mode)]

    def _hmm_overlay_texts(self, text: str) -> list[str]:
        base = self._tokenize_with_engine(self._engine, text, Mode.ACCURATE)
        hmm = self._tokenize_with_engine(self._engine_for_hmm(True), text, Mode.ACCURATE)
        out: list[str] = []
        i = 0
        h = 0
        while i < len(base):
            while h < len(hmm) and hmm[h].end_byte <= base[i].start_byte:
                h += 1
            if h < len(hmm) and hmm[h].start_byte == base[i].start_byte and hmm[h].end_byte > base[i].end_byte:
                j = i
                has_single = False
                while j < len(base) and base[j].end_byte <= hmm[h].end_byte:
                    has_single = has_single or len(base[j].text) == 1
                    j += 1
                if j > i + 1 and base[j - 1].end_byte == hmm[h].end_byte and has_single:
                    out.append(hmm[h].text)
                    i = j
                    h += 1
                    continue
            out.append(base[i].text)
            i += 1
        return out

    def cut(self, text: str, cut_all: bool = False, HMM: bool = False):
        with self._lock:
            words = self._token_texts(text, Mode.FULL if cut_all else Mode.ACCURATE, HMM=HMM)
        yield from words

    def lcut(self, text: str, cut_all: bool = False, HMM: bool = False) -> list[str]:
        with self._lock:
            return self._token_texts(text, Mode.FULL if cut_all else Mode.ACCURATE, HMM=HMM)

    def cut_for_search(self, text: str, HMM: bool = False):
        with self._lock:
            candidates = [
                (token.start_char, token.text)
                for token in self._tokenize_with_engine(self._engine, text, Mode.SEARCH)
                if len(token.text) > 1
            ]
            if HMM:
                candidates.extend(self._cached_hmm_search_terms(text))

            seen: set[str] = set()
            words = []
            for _, word in sorted(candidates, key=lambda item: item[0]):
                if word not in seen:
                    seen.add(word)
                    words.append(word)
        yield from words

    def _cached_hmm_search_terms(self, text: str) -> tuple[tuple[int, str], ...]:
        if len(text) > _MAX_HMM_SEARCH_CHARS:
            return ()
        cached = self._hmm_search_cache.get(text)
        if cached is not None:
            return cached
        terms = tuple(self._hmm_search_terms(text))
        if len(self._hmm_search_cache) >= _MAX_HMM_SEARCH_CACHE:
            self._hmm_search_cache.clear()
        self._hmm_search_cache[text] = terms
        return terms

    def _hmm_search_terms(self, text: str):
        base = self._tokenize_with_engine(self._engine, text, Mode.ACCURATE)
        cache: dict[str, list[str]] = {}
        i = 0
        while i < len(base):
            if len(base[i].text) > 1 and base[i].source != "unknown":
                i += 1
                continue
            start = i
            while i < len(base) and (len(base[i].text) == 1 or base[i].source == "unknown"):
                i += 1
            end = i
            if start > 0 and len(base[start - 1].text) <= 2:
                start -= 1
            snippet = text[base[start].start_char : base[end - 1].end_char]
            if 2 <= len(snippet) <= 8:
                words = cache.get(snippet)
                if words is None:
                    words = self._hmm_overlay_texts(snippet)
                    cache[snippet] = words
                cursor = 0
                for word in words:
                    local_start = snippet.find(word, cursor)
                    if local_start < 0:
                        continue
                    cursor = local_start + len(word)
                    yield base[start].start_char + local_start, word

    def _engine_for_hmm(self, enabled: bool) -> ctypes.c_void_p:
        with self._lock:
            self._ensure_open()
            if not enabled:
                return self._engine
            if self._plugins_loaded:
                return self._engine
            if self._hmm_ready and self._hmm_engine is not None:
                return self._hmm_engine

            plugin_path = _resolve_hmm_plugin_path()
            if not plugin_path.exists():
                raise NexaloidError(f"HMM plugin not found: {plugin_path}")
            config_json = json.dumps({"artifact": str(hmm_artifact_path()), "hmm_score": -14.0})
            candidate = self._open_engine()
            try:
                for word, score in self._words.items():
                    data = word.encode("utf-8")
                    self._check(_LIB.nx_add_word(candidate, data, len(data), 0, score, 0))
                path_data = str(plugin_path).encode("utf-8")
                config_data = config_json.encode("utf-8")
                self._check(_LIB.nx_load_plugin(candidate, path_data, config_data))
            except BaseException:
                _LIB.nx_engine_free(candidate)
                raise
            self._hmm_engine = candidate
            self._hmm_plugin_path = plugin_path
            self._hmm_config_json = config_json
            self._hmm_ready = True
            return candidate

    def _check(self, status: int) -> None:
        if status != 0:
            msg = _LIB.nx_status_message(status).decode("utf-8", "replace")
            raise NexaloidError(msg)

    def _ensure_open(self) -> None:
        if self._closed:
            raise NexaloidError("tokenizer is closed")
