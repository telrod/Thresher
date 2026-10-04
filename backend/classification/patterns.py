"""
Sender-group pattern normalization and validation (D80–D82).

Every write path for group membership goes through here: `POST /sender-groups`,
`PUT /sender-groups/<id>` and `POST /onboarding/people`. Before this existed the
API accepted any non-empty string, and a bare domain such as `example.com` was
stored and then matched nothing, ever — the matcher compares a pattern with no
`@` and no `*` against the WHOLE address. A pattern that renders as live and
silently never fires is the failure `CLAUDE.md` already bans for rules.

Accepted forms, after normalization:

  - a full address            `name@example.com`
  - a domain                  `@example.com`
  - a bare domain             `example.com`   → stored as `@example.com`
  - a glob                    `*@example.com`, `j*@example.com`
                              `*` only BEFORE the `@`, exactly one `@`, no
                              whitespace — so a glob can never span domains.

Two further rejections, both decided by asking the REAL matcher rather than by
string-matching each form (a second copy of the matching rules would drift):

  - a pattern covering a whole consumer mail domain (`gmail.com`, `@gmail.com`,
    `*@gmail.com`) — it would put a large share of all mail in Tier 1. A full
    address at that domain is fine.

Validation applies on WRITE only. Stored patterns are not re-checked until they
are next saved.
"""

from __future__ import annotations

import re
from typing import Optional

from classification.engine import ClassificationEngine

# The seeded leadership member in seed.example.sql. It matches nobody; onboarding
# drops it when the user supplies real members (D78).
PLACEHOLDER_PATTERN = "boss@example.com"

# Shared consumer mail domains (D82). Short and explicit on purpose: this list is a
# guard against one entry putting most of someone's mail in Tier 1, not a
# directory of every free-mail provider.
CONSUMER_DOMAINS = frozenset({
    "gmail.com", "googlemail.com",
    "outlook.com", "hotmail.com", "live.com",
    "icloud.com", "me.com",
    "yahoo.com", "aol.com",
    "proton.me", "protonmail.com",
})

# Two probe local parts that share no character at all. A glob matching BOTH can
# contain no literal character in its local part — so it covers the whole domain.
# (Probes that shared a prefix would let `p*@gmail.com` through as "whole domain"
# when it is not, or the reverse.)
_PROBE_LOCALS = ("a1", "z9")

_DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)"
    r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$",
    re.IGNORECASE,
)
_LOCAL_RE = re.compile(r"^[^\s@]+$")

FORMAT_HELP = ("Use a full address (name@example.com), a domain (example.com or "
               "@example.com), or a glob with * before the @ (*@example.com).")


def _is_domain(s: str) -> bool:
    return bool(_DOMAIN_RE.match(s))


def normalize_pattern(raw: str) -> str:
    """Trim, and turn a bare domain into the `@domain` form the matcher honours.

    Only a bare DOMAIN is rewritten. Anything else is returned trimmed and left for
    `pattern_error` to accept or reject, so a malformed entry is reported as the
    user typed it rather than as something this function invented.
    """
    s = (raw or "").strip()
    if "@" not in s and "*" not in s and _is_domain(s):
        return "@" + s
    return s


def _format_ok(p: str) -> bool:
    if not p or any(ch.isspace() for ch in p) or p.count("@") != 1:
        return False
    local, domain = p.split("@")
    if not _is_domain(domain):          # rejects any `*` in the domain part
        return False
    if local == "":
        return True                     # `@domain`
    return bool(_LOCAL_RE.match(local))  # full address, or a glob (`*` in local)


def _covers_whole_domain(p: str, domain: str) -> bool:
    return all(ClassificationEngine._pattern_matches(p, f"{local}@{domain}")
               for local in _PROBE_LOCALS)


def pattern_error(p: str) -> Optional[str]:
    """Why the NORMALIZED pattern `p` is unacceptable, or None if it is fine."""
    if not _format_ok(p):
        return f"'{p}' is not a valid pattern. {FORMAT_HELP}"
    for domain in sorted(CONSUMER_DOMAINS):
        if _covers_whole_domain(p, domain):
            return (f"'{p}' would match everyone at {domain}, a shared mail "
                    f"provider. Enter the person's full address instead.")
    return None


def normalize_patterns(raw: list) -> tuple[list[str], list[dict]]:
    """Normalize and validate a list of entries.

    Returns `(patterns, errors)`. `patterns` is trimmed, normalized, de-duplicated
    (case-insensitively, keeping the first spelling) with empties dropped. `errors`
    holds one `{"entry", "error"}` per rejected entry, naming the entry as typed.
    """
    out: list[str] = []
    seen: set[str] = set()
    errors: list[dict] = []
    for item in raw:
        entry = (item or "").strip()
        if not entry:
            continue
        p = normalize_pattern(entry)
        err = pattern_error(p)
        if err:
            errors.append({"entry": entry, "error": err})
            continue
        if p.lower() not in seen:
            seen.add(p.lower())
            out.append(p)
    return out, errors
