from __future__ import annotations

from .tokenizer import Tokenizer

# Module-level tokenizer mirrors jieba's global API while still delegating to native core.
dt = Tokenizer()


def cut(sentence, cut_all=False, HMM=False, use_paddle=False):
    if use_paddle:
        raise NotImplementedError("use_paddle=True is not supported")
    return dt.cut(sentence, cut_all=cut_all, HMM=HMM)


def lcut(sentence, cut_all=False, HMM=False, use_paddle=False):
    if use_paddle:
        raise NotImplementedError("use_paddle=True is not supported")
    return dt.lcut(sentence, cut_all=cut_all, HMM=HMM)


def cut_for_search(sentence, HMM=False):
    return dt.cut_for_search(sentence, HMM=HMM)


def lcut_for_search(sentence, HMM=False):
    return list(cut_for_search(sentence, HMM=HMM))


def add_word(word, freq=None, tag=None):
    return dt.add_word(word, freq=freq, tag=tag)


def del_word(word):
    return dt.del_word(word)


def load_userdict(f):
    return dt.load_userdict(f)


def suggest_freq(segment, tune=False):
    return dt.suggest_freq(segment, tune=tune)
