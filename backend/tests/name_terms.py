"""
The private names this public repository must not contain — ENCODED.

One list, read by two guards:

  - `test_name_guard.py` scans every tracked file for NAME_PATTERNS.
  - `test_corpus.py` scans the synthetic corpus for NAME_PATTERNS plus
    CORPUS_ONLY_PATTERNS (names from the real mailbox the corpus replaced).

WHY ENCODED
-----------
A guard against a term has to contain the term, and a file that contains it is
exactly what the repo-wide guard exists to catch. Writing the terms in plain text
would force allowlisting this whole file, which would blind the guard to anything
else added here. So every term is stored ROT13-encoded and decoded at import:

    codecs.decode("gbz", "rot13")  ==  the first name

ROT13 is not secrecy. It is reversible on sight, so a reviewer can still read the
list; it only keeps the literal strings out of the tree. Allowlist tokens in
`test_name_guard.py` are encoded the same way, for the same reason.
"""

import codecs
import re


def decode(s: str) -> str:
    return codecs.decode(s, "rot13")


# Maintainer and employer names. Each is a regex over decoded text, matched
# case-insensitively. The first name is whole-word only: as a bare substring it
# would match ordinary words.
NAME_PATTERNS = [
    r"\b" + decode("gbz") + r"\b",
    decode("gbzryebq"),
    decode("ryebq"),
    decode("gryebq"),
    decode("irehfra"),
    decode("tbmvb"),
]

# Names from the real mailbox the synthetic corpus replaced. Checked against the
# corpus only (they are not this repository's maintainer or employer).
CORPUS_ONLY_PATTERNS = [
    re.escape(decode("grjxfohel")),
    re.escape(decode("znephf")),
    re.escape(decode("nqql ebovafba")),
]

NAME_RE = re.compile("|".join(NAME_PATTERNS), re.IGNORECASE)
