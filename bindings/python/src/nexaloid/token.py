from dataclasses import dataclass


@dataclass(frozen=True)
class Token:
    text: str
    start_byte: int
    end_byte: int
    start_char: int
    end_char: int
    pos: str | None
    source: str
    score: float

