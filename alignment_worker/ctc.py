"""CTC forced alignment with a separate, non-display tokenizer view."""
import unicodedata
import numpy as np


def character(char):
    # Fold vocalization/annotation differences in acoustic tokens only. Original
    # Tanzil bytes, display text and whitespace word indices are never changed.
    if char in "ٱأإآ":
        return "ا"
    if char == "ٰ":
        return "ا"
    if char in "ىۦ":
        return "ي"
    if char == "ۥ":
        return "و"
    if char in "| " or char.isspace():
        return "|"
    if char in "ـ-" or unicodedata.category(char).startswith("M"):
        return ""
    return char if "\u0621" <= char <= "\u064a" else ""


def alphabet(vocab):
    return [""] + sorted({character(c) for c in vocab if len(c) == 1} - {""})


def fold_logits(logits, vocab, labels):
    # Sum probability mass of equivalent acoustic classes, including all
    # non-lexical marks in blank. These are acoustic scores, not confidence.
    logits = logits.astype(np.float64)
    probabilities = np.exp(logits - logits.max(axis=1, keepdims=True))
    probabilities /= probabilities.sum(axis=1, keepdims=True)
    folded = np.zeros((len(logits), len(labels)))
    for char, index in vocab.items():
        label = character(char) if len(char) == 1 else ""
        folded[:, labels.index(label)] += probabilities[:, index]
    return np.log(np.maximum(folded, 1e-30))


def tokenize(verses, labels):
    target, owners, words = [], [], []
    for ayah_index, verse in enumerate(verses):
        for word_index, original in enumerate(verse.split()):
            letters = [character(c) for c in original]
            letters = [c for c in letters if c and c != "|"]
            if not letters:  # stand-alone pause/sajdah mark, not a spoken word
                continue
            if target:
                target.append(labels.index("|"))
                owners.append(None)
            word_id = len(words)
            words.append((ayah_index, word_index))
            for char in letters:
                if char not in labels:
                    raise ValueError(f"Unsupported Quran acoustic token U+{ord(char):04X}; use manual timing.")
                target.append(labels.index(char))
                owners.append(word_id)
    return np.array(target, dtype=np.int32), owners, words


def viterbi(logp, target):
    """Strict monotonic CTC: blanks, dwell, advance, legal two-state skips."""
    frames, _ = logp.shape
    states = np.zeros(2 * len(target) + 1, dtype=np.int32)
    states[1::2] = target
    if not len(target) or frames < len(target) or frames * len(states) > 40_000_000:
        raise ValueError("Audio/text is too short or too large to align. Select fewer ayahs and trim to at most 3 minutes.")
    previous = np.full(len(states), -np.inf)
    previous[0] = logp[0, 0]
    previous[1] = logp[0, target[0]]
    trace = np.zeros((frames, len(states)), dtype=np.uint8)
    skip = np.zeros(len(states), dtype=bool)
    skip[2:] = (states[2:] != 0) & (states[2:] != states[:-2])
    for t in range(1, frames):
        choices = np.stack((previous, np.r_[-np.inf, previous[:-1]], np.r_[-np.inf, -np.inf, previous[:-2]]))
        choices[2, ~skip] = -np.inf
        moves = choices.argmax(axis=0)
        trace[t] = moves
        previous = choices[moves, np.arange(len(states))] + logp[t, states]
    state = len(states) - 1 if previous[-1] >= previous[-2] else len(states) - 2
    if not np.isfinite(previous[state]):
        raise ValueError("No complete alignment path. Check the ayah selection or use manual timing.")
    path = np.empty(frames, dtype=np.int32)
    for t in range(frames - 1, -1, -1):
        path[t] = state
        state -= int(trace[t, state])
    return path


def greedy(logp):
    result, previous = [], -1
    for token in logp.argmax(axis=1):
        if token != previous and token:
            result.append(int(token))
        previous = token
    return result


def edit_distance(left, right):
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left):
        current = [i + 1]
        for j, b in enumerate(right):
            current.append(min(current[-1] + 1, previous[j + 1] + 1, previous[j] + (a != b)))
        previous = current
    return previous[-1]
