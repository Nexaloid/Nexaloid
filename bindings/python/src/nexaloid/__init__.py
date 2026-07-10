from .token import Token
from .tokenizer import (
    Mode,
    Tokenizer,
    entity_artifact_path,
    entity_manifest,
    entity_manifest_path,
    entity_plugin_path,
    hmm_artifact_path,
    hmm_manifest,
    hmm_manifest_path,
)

try:
    from importlib.metadata import PackageNotFoundError, version

    __version__ = version("nexaloid")
except PackageNotFoundError:
    __version__ = "0.0.0.dev0"

__all__ = [
    "Mode",
    "Token",
    "Tokenizer",
    "entity_artifact_path",
    "entity_manifest",
    "entity_manifest_path",
    "entity_plugin_path",
    "hmm_artifact_path",
    "hmm_manifest",
    "hmm_manifest_path",
    "__version__",
]
