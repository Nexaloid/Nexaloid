from .token import Token
from .tokenizer import Mode, Tokenizer

try:
    from importlib.metadata import PackageNotFoundError, version

    __version__ = version("nexaloid")
except PackageNotFoundError:
    __version__ = "0.0.0.dev0"

__all__ = ["Mode", "Token", "Tokenizer", "__version__"]
