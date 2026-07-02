from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Token:
    text: str
    start_byte: int
    end_byte: int
    start_char: int
    end_char: int
    pos: Optional[str]
    source: str
    score: float
