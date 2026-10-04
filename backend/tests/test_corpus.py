"""Tests for the synthetic corpus and its generator.

Two things are pinned here, and they fail for different reasons:

  1. The committed fixtures under `backend/tests/corpus/` are what they claim to
     be — the edge cases survive, and no real address or non-reserved domain has
     crept in. These fail if someone regenerates the fixtures carelessly.

  2. The generator's own guarantees — determinism, reserved domains, the tier
     distribution, and the two-sided report. These fail if the generator changes.

⚠️ Read `docs/eml-corpus-enumeration.md` before changing any fixture. A fixture
replaced by a prettier one that tests less is a regression that looks like
progress, and that document is the record of what each one pins.
"""

import subprocess
import sys
from email.header import decode_header, make_header
from pathlib import Path

import pytest

from ingestion.parser import parse_message

_BACKEND = Path(__file__).resolve().parents[1]
_REPO = _BACKEND.parent
_CORPUS = _BACKEND / "tests" / "corpus"
_GENERATOR = _REPO / "scripts" / "generate_corpus.py"

# Pinned so the committed fixtures are reproducible. Changing either of these
# means the committed .eml files no longer match what the generator produces,
# which `test_committed_fixtures_match_generator` catches.
SEED = 20260912
REFERENCE = "2026-09-12"

RESERVED_DOMAINS = {"example.com", "example.org", "example.net"}
DEMO_ACCOUNT = "thresher.demo@gmail.com"


def _fixture_paths() -> list[Path]:
    return sorted(_CORPUS.glob("*.eml"))


def _parsed():
    for path in _fixture_paths():
        yield path, parse_message(path.read_bytes(),
                                  message_id=f"{DEMO_ACCOUNT}:{path.name}",
                                  account=DEMO_ACCOUNT)


# ── The fixtures exist and are readable ───────────────────────────────────────

def test_fixture_corpus_is_committed_and_sized():
    paths = _fixture_paths()
    assert paths, (
        "no fixtures found — regenerate with:\n"
        "  ./scripts/generate_corpus.py --profile fixtures "
        f"--seed {SEED} --reference-date {REFERENCE}")
    # ~25 per the spec. A wide band: the exact count is allowed to drift as edge
    # cases are added, but a collapse to a handful means something deleted them.
    assert 20 <= len(paths) <= 40, f"unexpected fixture count: {len(paths)}"


def test_every_fixture_parses_without_raising():
    """P1: the parser degrades to safe defaults, it never fails hard. Several
    fixtures are deliberately malformed, so this is a real assertion."""
    for path, msg in _parsed():
        assert msg is not None, path.name


def test_manifest_lists_every_fixture():
    """The manifest is the 'what does this pin' record. A fixture missing from
    it is a fixture whose reason for existing has been lost."""
    manifest = _CORPUS / "MANIFEST.md"
    assert manifest.exists(), "MANIFEST.md missing — regenerate the fixtures"
    text = manifest.read_text()
    for path in _fixture_paths():
        assert path.name in text, f"{path.name} is not described in MANIFEST.md"


# ── Privacy and domain safety ─────────────────────────────────────────────────

def test_only_reserved_domains_appear():
    """RFC 2606 domains only. A synthetic message from a real company's domain
    is a fake message impersonating that company, and this corpus is destined
    for a public repo and for screenshots."""
    import re
    pattern = re.compile(rb"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
    for path in _fixture_paths():
        for match in pattern.finditer(path.read_bytes()):
            domain = match.group(1).decode().lower().rstrip(">,;")
            assert domain in RESERVED_DOMAINS or domain == "gmail.com", (
                f"{path.name} references non-reserved domain {domain!r}")


def test_the_only_gmail_address_is_the_demo_identity():
    """gmail.com is allowed for exactly one address: the throwaway demo account.
    Anything else there would be a real person's mailbox."""
    import re
    pattern = re.compile(rb"[A-Za-z0-9._%+-]+@gmail\.com")
    for path in _fixture_paths():
        for match in pattern.finditer(path.read_bytes()):
            assert match.group(0).decode().lower() == DEMO_ACCOUNT, (
                f"{path.name} contains a gmail.com address that is not the "
                f"demo identity: {match.group(0)!r}")


# The terms this guard sweeps for are deliberately NOT the public repo's own
# placeholder vocabulary. `example.com` is the RFC 2606 domain every fixture
# uses on purpose, so sweeping for "example" would fail on correct data.
#
# These are the private-tree terms that must never reappear in a generated
# corpus. They are kept verbatim rather than scrubbed: a guard against a term
# cannot work if the term itself has been replaced by a placeholder — the whole
# point is to fail if one of these ever comes back.
@pytest.mark.parametrize("term", [
    "verusen", "tomelrod", "tom.elrod", "gozio",
    "tewksbury", "marcus", "addy robinson",
])
def test_no_term_from_the_real_corpus(term):
    """Nothing derived from the real mailbox — not a name, not a domain.

    The public-repo sweep found addresses a term list missed; this guards the
    other direction, so the synthetic corpus cannot reintroduce them.
    """
    for path in _fixture_paths():
        haystack = path.read_bytes().lower()
        assert term.encode() not in haystack, f"{path.name} contains {term!r}"


# ── The edge cases the fixtures exist to pin ──────────────────────────────────
#
# Each of these would pass vacuously if the corresponding fixture were dropped,
# so each asserts that AT LEAST ONE fixture exhibits the property. That is the
# check that makes "a prettier fixture that tests less" fail loudly.

def test_a_fixture_has_no_subject():
    assert any(m.subject in (None, "") for _, m in _parsed()), \
        "no fixture omits Subject — the missing-header case is unpinned"


def test_a_fixture_has_no_sender():
    assert any(not m.sender_email for _, m in _parsed()), \
        "no fixture omits From — the missing-sender case is unpinned"


def test_a_fixture_has_an_html_only_body():
    assert any(m.body_html and not m.body_plain for _, m in _parsed()), \
        "no fixture is HTML-only — the HTML fallback path is unpinned"


def test_a_fixture_has_an_empty_body():
    assert any(not m.body_plain and not m.body_html for _, m in _parsed()), \
        "no fixture has an empty body"


def test_a_fixture_has_non_ascii_content():
    assert any(
        any(ord(ch) > 127 for ch in ((m.subject or "") + (m.body_plain or "")))
        for _, m in _parsed()
    ), "no fixture carries non-ASCII text"


def test_the_preencoded_fixture_carries_an_rfc2047_subject():
    """The PRE-ENCODED fixture (010) must arrive encoded and decode correctly.

    ⚠️ This test named the fixture only after a sabotage exposed that it did
    not. The first version accepted ANY fixture with an encoded Subject, and
    fixture 009 carries a non-ASCII subject that the email package encodes on
    its own — so blanking 010's header entirely still passed. The test proved
    "some encoded subject exists somewhere", which is not the claim its name
    made, and 010 could have been silently reduced to nothing.

    Naming the fixture is what makes the check able to fail. The distinction
    matters because 009 and 010 pin different directions: 009 is our ENCODER
    (non-ASCII in, valid header out), 010 is the DECODER (a header written
    pre-encoded by hand, exactly as a foreign sender would emit it).
    """
    matches = [p for p in _fixture_paths() if p.name.startswith("010-")]
    assert len(matches) == 1, \
        f"expected exactly one 010- fixture, found {[p.name for p in matches]}"
    path = matches[0]

    subject_line = next(
        (l for l in path.read_bytes().split(b"\r\n")
         if l.lower().startswith(b"subject:")), None)
    assert subject_line is not None, f"{path.name} has no Subject header"
    assert b"=?" in subject_line, (
        f"{path.name} is the pre-encoded fixture but its Subject carries no "
        f"encoded word: {subject_line!r}")

    decoded = str(make_header(decode_header(
        subject_line.split(b":", 1)[1].decode().strip())))
    assert "=?" not in decoded, f"{path.name} did not decode: {decoded!r}"
    assert any(ord(ch) > 127 for ch in decoded), (
        f"{path.name} decoded to pure ASCII ({decoded!r}) — an encoded word "
        "that carries no non-ASCII character pins nothing")


def test_a_fixture_has_an_encoded_display_name():
    assert any(
        m.sender_name and any(ord(ch) > 127 for ch in m.sender_name)
        for _, m in _parsed()
    ), "no fixture has a non-ASCII sender display name"


def test_a_fixture_display_name_contains_a_comma():
    """A comma in a display name must not split into two addresses."""
    hits = [(p, m) for p, m in _parsed() if m.sender_name and "," in m.sender_name]
    assert hits, "no fixture has a comma in the display name"
    for path, msg in hits:
        assert msg.sender_email.count("@") == 1, \
            f"{path.name}: comma in display name split the address"


def test_a_fixture_has_a_very_long_subject():
    assert any((m.subject or "") and len(m.subject) > 120 for _, m in _parsed()), \
        "no fixture has a long subject — row/chip truncation is unpinned"


def test_a_fixture_has_a_very_long_single_line_body():
    assert any(
        m.body_plain and max((len(l) for l in m.body_plain.splitlines()), default=0) > 400
        for _, m in _parsed()
    ), "no fixture has a long single-line body — detail-pane layout is unpinned"


def test_two_fixtures_share_a_message_id():
    """The dedup path needs two distinct files carrying one Message-ID."""
    seen: dict[str, list[str]] = {}
    for path in _fixture_paths():
        for line in path.read_bytes().split(b"\r\n"):
            if line.lower().startswith(b"message-id:"):
                mid = line.split(b":", 1)[1].strip().decode()
                seen.setdefault(mid, []).append(path.name)
    assert any(len(v) > 1 for v in seen.values()), \
        "no duplicate Message-ID — the dedup path is unpinned"


def test_a_thread_has_at_least_three_messages():
    threads: dict[str, int] = {}
    for _, msg in _parsed():
        if msg.thread_id:
            threads[msg.thread_id] = threads.get(msg.thread_id, 0) + 1
    assert max(threads.values(), default=0) >= 3, \
        "no thread of three — the conversation view is unpinned"


def test_bulk_fixtures_carry_list_unsubscribe():
    """OI38: the engine cannot match this header yet. The fixtures carry it so
    the corpus already exercises header matching the day that lands, rather
    than the gap being discovered then."""
    assert any(b"List-Unsubscribe:" in p.read_bytes() for p in _fixture_paths()), \
        "no fixture carries List-Unsubscribe"


def test_fixtures_straddle_both_recency_bands():
    """D57 bands at 14 and 90 days. A fixture on each side of each boundary,
    close enough to catch an off-by-one.

    Ages are computed against the pinned REFERENCE, not against now — otherwise
    this test's meaning would change every day it is not run.
    """
    from datetime import datetime, timezone
    ref = datetime.fromisoformat(REFERENCE).replace(tzinfo=timezone.utc)
    ages = []
    for path, msg in _parsed():
        # The missing-Date fixture falls back to ingestion time by design, so
        # its age is meaningless here — see MANIFEST.md.
        if b"\r\nDate:" not in path.read_bytes():
            continue
        delta = ref - datetime.fromisoformat(msg.received_at)
        ages.append(delta.total_seconds() / 86400.0)

    # ⚠️ This assertion is on EXACT ages, and it took two sabotages to get
    # right. Both earlier versions passed with the dedicated 13-day fixture
    # deleted:
    #
    #   - a ±2-day window was satisfied by fixture 007 (12 days), which exists
    #     to pin a missing From header;
    #   - an exact `a == 13` was satisfied by fixture 008 (13.5 days, which
    #     truncates to 13), which exists to pin a missing Subject.
    #
    # Unrelated fixtures kept wandering into the window, so the test was
    # pinning "something happens to be nearby" rather than "the boundary is
    # deliberately straddled". Ages are therefore measured to the FRACTIONAL
    # day and required to be exact: a deliberate boundary fixture is generated
    # at a whole-number offset, an incidental one essentially never is.
    for boundary in (14, 90):
        assert any(abs(a - (boundary - 1)) < 0.01 for a in ages), (
            f"no fixture at exactly {boundary - 1}.0 days — the day just "
            f"INSIDE the {boundary}-day band is unpinned. "
            f"Ages: {sorted(round(a, 2) for a in ages)}")
        assert any(abs(a - (boundary + 1)) < 0.01 for a in ages), (
            f"no fixture at exactly {boundary + 1}.0 days — the day just "
            f"OUTSIDE the {boundary}-day band is unpinned. "
            f"Ages: {sorted(round(a, 2) for a in ages)}")


# ── Generator guarantees ──────────────────────────────────────────────────────

def _run(tmp_path, *args) -> Path:
    out = tmp_path / "out"
    subprocess.run(
        [sys.executable, str(_GENERATOR), "--out", str(out),
         "--reference-date", REFERENCE, *args],
        check=True, capture_output=True, text=True,
    )
    return out


def _digest(directory: Path) -> list[tuple[str, bytes]]:
    return [(p.name, p.read_bytes()) for p in sorted(directory.glob("*.eml"))]


def test_same_seed_and_reference_produce_identical_output(tmp_path):
    a = _run(tmp_path / "a", "--profile", "demo", "--count", "40",
             "--seed", str(SEED))
    b = _run(tmp_path / "b", "--profile", "demo", "--count", "40",
             "--seed", str(SEED))
    assert _digest(a) == _digest(b), "generator is not deterministic"


def test_a_different_seed_produces_different_output(tmp_path):
    """Determinism is only meaningful if the seed does something.

    Without this, a generator that ignored --seed entirely would pass the
    determinism test above — the check would be pinning a constant.
    """
    a = _run(tmp_path / "a", "--profile", "demo", "--count", "40", "--seed", "1")
    b = _run(tmp_path / "b", "--profile", "demo", "--count", "40", "--seed", "2")
    assert _digest(a) != _digest(b), "--seed has no effect on output"


def test_a_different_reference_date_shifts_the_dates(tmp_path):
    out_a = tmp_path / "a" / "out"
    out_b = tmp_path / "b" / "out"
    for out, ref in ((out_a, "2026-09-12"), (out_b, "2026-03-01")):
        subprocess.run(
            [sys.executable, str(_GENERATOR), "--out", str(out),
             "--profile", "demo", "--count", "40", "--seed", str(SEED),
             "--reference-date", ref],
            check=True, capture_output=True, text=True)
    assert _digest(out_a) != _digest(out_b), "--reference-date has no effect"


def test_generated_corpus_reaches_at_least_four_tiers(tmp_path):
    """Spec §Verification: at least four distinct tiers with groups populated.

    ⚠️ Assert the DISTRIBUTION, not merely that classification ran. A corpus
    where everything lands in one tier passes a 'classification works' check,
    which is precisely how the current seed shipped.
    """
    result = subprocess.run(
        [sys.executable, str(_GENERATOR), "--out", str(tmp_path / "out"),
         "--profile", "demo", "--seed", str(SEED),
         "--reference-date", REFERENCE, "--report"],
        check=True, capture_output=True, text=True)
    populated, empty = _parse_report(result.stdout)
    assert len(populated) >= 4, (
        f"only {len(populated)} distinct tiers with groups populated: "
        f"{populated}\n{result.stdout}")


def test_report_states_both_sides_and_groups_empty_loses_tier_one(tmp_path):
    """The groups-empty number is the honest measure of what a stranger sees.

    Tier 1 must be ZERO there: both seeded Tier 1 rules target sender groups,
    and a fresh install ships those groups memberless. If this ever becomes
    non-zero, either the seed gained a content-based Tier 1 rule or the corpus
    started flattering the rule set — both are worth a human look.
    """
    result = subprocess.run(
        [sys.executable, str(_GENERATOR), "--out", str(tmp_path / "out"),
         "--profile", "demo", "--seed", str(SEED),
         "--reference-date", REFERENCE, "--report"],
        check=True, capture_output=True, text=True)
    assert "sender groups EMPTY" in result.stdout, \
        "the report does not state the groups-empty case at all"
    _populated, empty = _parse_report(result.stdout)
    assert empty.get(1, 0) == 0, (
        "a fresh install produced a Tier 1 message, which the seeded rules "
        f"cannot do — groups-empty distribution was {empty}")


def _parse_report(stdout: str) -> tuple[dict, dict]:
    """Pull the two tier tables out of --report output."""
    populated: dict[int, int] = {}
    empty: dict[int, int] = {}
    target = None
    for line in stdout.splitlines():
        if "groups populated" in line:
            target = populated
        elif "groups EMPTY" in line:
            target = empty
        elif target is not None and line.strip().startswith("T"):
            tier = int(line.strip()[1])
            count = int(line.split(":")[1].split("(")[0].strip())
            if count:
                target[tier] = count
    return populated, empty


def test_committed_fixtures_match_the_generator(tmp_path):
    """The committed fixtures are regenerable.

    If this fails, either someone hand-edited a fixture (don't — edit the
    generator) or the generator changed without the fixtures being regenerated.
    Regenerate with:

        ./scripts/generate_corpus.py --profile fixtures \\
            --seed 20260912 --reference-date 2026-09-12
    """
    regenerated = _run(tmp_path, "--profile", "fixtures", "--seed", str(SEED))
    assert _digest(regenerated) == _digest(_CORPUS), (
        "committed fixtures differ from generator output — regenerate them")
