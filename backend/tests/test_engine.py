"""
Engine-level classification tests — the layer OI19 proved was untested.

Why this file exists (Session 28, OI19): a `matches_group` rule targeting a
mixed-case sender group name could never match. `_evaluate_rule` lowercased the
rule's value while `classify()` built the matched-group name set case-preserved,
so `"Me"` lowered to `"me"` and the membership test failed silently. The bug was
invisible for the whole project because **every seeded group name was lowercase**
— "Me" was the first mixed-case group a human ever created — and because the four
E22 tests validate the API's field/operator contract only: **none of them calls
`classify()`**. The batch's "E2E evidence" was evidence of the wrong layer.

So these tests drive the ENGINE, through the real DB repos, the way the pipeline
loads it (`RulesRepo.all_enabled()` + `all_sender_groups()`), and they
deliberately include a group name that violates the seed corpus's implicit
lowercase convention.
"""

from classification.engine import ClassificationEngine, MessageEnvelope
from db.database import RulesRepo


def _engine(conn):
    """Build the engine exactly as ingestion/pipeline.py::_build_engine does."""
    repo = RulesRepo(conn)
    return ClassificationEngine(rules=repo.all_enabled(),
                                sender_groups=repo.all_sender_groups())


def _envelope(sender_email, subject="hello", body="body text"):
    return MessageEnvelope(id=f"acct:{sender_email}", sender_email=sender_email,
                           sender_name="Sender", subject=subject, body_plain=body)


def _group_rule(conn, *, group_name, email_pattern, floor=5, set_tier=2,
                set_category="personal", rule_name=None, rule_value=None):
    """A sender group + a `matches_group` rule pointing at it by name.

    `floor=5` keeps the sender-override invariant out of the way: the assertions
    below must prove the RULE matched, not that the floor rescued the tier. That
    separation is the whole lesson of the Session 27 rule-18 arc — a floor-only
    result is exactly what a non-matching rule looks like.
    """
    repo = RulesRepo(conn)
    repo.create_sender_group({
        "group_name": group_name, "email_pattern": email_pattern,
        "urgency_floor": floor, "notes": None,
    })
    return repo.create_rule({
        "rule_name": rule_name or f"{group_name} → T{set_tier}",
        "priority": 1, "enabled": True,
        "field": "sender_group", "operator": "matches_group",
        "value": rule_value if rule_value is not None else group_name,
        "set_tier": set_tier, "set_category": set_category, "notes": None,
    })


# ── OI19: the mixed-case membership bug ───────────────────────────────────────

def test_matches_group_matches_a_MIXED_CASE_group_name_OI19(conn):
    """OI19 (Session 27 gate, blocking): the exact production shape that failed.

    A `matches_group` rule targeting the mixed-case group "Me" must match a
    message from a member sender, and its effects must APPLY. Red against the
    pre-fix engine: `value` was lowered to "me" and compared against the
    case-preserved set {"Me"}, so the rule never matched and the message fell
    through with only the floor invariant — byte-identical to Test 12 in the
    Session 27 gate run.
    """
    rule = _group_rule(conn, group_name="Me", email_pattern="*@example.org")
    result = _engine(conn).classify(_envelope("you@example.org"))

    matched_ids = [m["rule_id"] for m in result.rule_matches]
    assert rule["id"] in matched_ids, (
        f"the mixed-case matches_group rule did not match; "
        f"rule_matches={result.rule_matches}"
    )
    # The rule's effects applied — not merely the sender-override floor.
    assert result.urgency_tier == 2
    assert result.category == "personal"


def test_mixed_case_group_rule_applies_its_effects_not_just_the_floor_OI19(conn):
    """The discrimination the S27 gate needed and the explain panel supplied.

    With floor=5 and the rule setting T2, a matching rule is the ONLY thing that
    can produce tier 2. If the rule silently fails, the floor yields tier 5 —
    the "matched but misapplied" vs "never matched" distinction, pinned.
    """
    _group_rule(conn, group_name="MiXeDcAsE", email_pattern="*@mixed.example",
                floor=5, set_tier=2)
    result = _engine(conn).classify(_envelope("someone@mixed.example"))

    assert result.urgency_tier == 2, (
        "tier 5 here means the rule never matched and only the floor applied"
    )


def test_rule_value_case_does_not_matter_either_direction_OI19(conn):
    """Casefold BOTH sides: a lowercase rule value must match a mixed-case group.

    The fix normalizes at the set-construction point, so this direction —
    rule stores "me", group is named "Me" — must match too. Without both-side
    normalization one of these two directions silently stays broken.
    """
    rule = _group_rule(conn, group_name="Me", email_pattern="*@bothways.example",
                       rule_value="me")
    result = _engine(conn).classify(_envelope("dana@bothways.example"))

    assert rule["id"] in [m["rule_id"] for m in result.rule_matches]
    assert result.urgency_tier == 2


# ── Regression pair: the seed-corpus behavior must not change ─────────────────

def test_matches_group_still_matches_an_ALL_LOWERCASE_group_name(conn):
    """Regression guard (workorder Part 1 step 3): the lowercase path — every
    group name that existed before "Me" — behaves exactly as before the fix.

    The name is deliberately NOT one of the seeded four: seeded `family` and
    `leadership` carry urgency_floor 1, so reusing those names lets the
    sender-override invariant supply tier 1 and the assertion stops proving the
    rule matched. (Found by this test failing red for the wrong reason.)
    """
    rule = _group_rule(conn, group_name="cousins", email_pattern="*@family.example")
    result = _engine(conn).classify(_envelope("mom@family.example"))

    assert rule["id"] in [m["rule_id"] for m in result.rule_matches]
    assert result.urgency_tier == 2
    assert result.category == "personal"


def test_matches_group_does_NOT_match_a_non_member_sender(conn):
    """The fix must not turn the membership test into a tautology: casefolding
    makes comparison case-insensitive, not universally true."""
    rule = _group_rule(conn, group_name="Me", email_pattern="*@example.org")
    result = _engine(conn).classify(_envelope("stranger@elsewhere.example"))

    assert rule["id"] not in [m["rule_id"] for m in result.rule_matches]


def test_matches_group_does_not_match_a_DIFFERENT_group_name(conn):
    """Two mixed-case groups: a rule naming one must not match a member of the
    other. Guards against normalizing to something lossy (e.g. empty string)."""
    repo = RulesRepo(conn)
    for name, pattern in (("Me", "*@mine.example"), ("Work", "*@work.example")):
        repo.create_sender_group({"group_name": name, "email_pattern": pattern,
                                  "urgency_floor": 5, "notes": None})
    rule = repo.create_rule({
        "rule_name": "Me → T2", "priority": 1, "enabled": True,
        "field": "sender_group", "operator": "matches_group", "value": "Me",
        "set_tier": 2, "set_category": "personal", "notes": None,
    })
    result = _engine(conn).classify(_envelope("colleague@work.example"))

    assert rule["id"] not in [m["rule_id"] for m in result.rule_matches]


# ── The explain-panel payload the gate reads (P3) ─────────────────────────────

def test_mixed_case_group_match_is_visible_in_the_rule_matches_audit_OI19(conn):
    """P3: the gate's instrument is the explain panel, so the match must be
    legible there — the named rule, its field/operator, and the applied tier."""
    rule = _group_rule(conn, group_name="Me", email_pattern="*@example.org",
                       rule_name="Testing - example.org")
    result = _engine(conn).classify(_envelope("you@example.org"))

    records = [m for m in result.rule_matches if m["rule_id"] == rule["id"]]
    assert records, (
        f"the mixed-case rule produced no audit record at all; "
        f"rule_matches={result.rule_matches}"
    )
    record = records[0]
    assert record["rule_name"] == "Testing - example.org"
    assert record["field"] == "sender_group"
    assert record["operator"] == "matches_group"
    assert record["applied_tier"] == 2


# ── D53: multi-pattern groups ─────────────────────────────────────────────────

def _multi_group(conn, *, group_name, patterns, floor=5, set_tier=2,
                 set_category="personal"):
    """A group with several patterns + a rule targeting it BY ID (the D53 shape)."""
    repo = RulesRepo(conn)
    group = repo.create_sender_group({
        "group_name": group_name, "patterns": patterns,
        "urgency_floor": floor, "notes": None,
    })
    rule = repo.create_rule({
        "rule_name": f"{group_name} → T{set_tier}", "priority": 1, "enabled": True,
        "field": "sender_group", "operator": "matches_group", "value": group_name,
        "set_tier": set_tier, "set_category": set_category, "notes": None,
    })
    return group, rule


def test_a_group_matches_via_ANY_of_its_patterns_D53(conn):
    """DG3's plain-language contract: "a sender matching ANY pattern is in the
    group." The second and third patterns must work exactly like the first."""
    group, rule = _multi_group(
        conn, group_name="cousins",
        patterns=["ada@first.example", "*@second.example", "@third.example"])

    for sender in ("ada@first.example", "someone@second.example", "bob@third.example"):
        result = _engine(conn).classify(_envelope(sender))
        assert rule["id"] in [m["rule_id"] for m in result.rule_matches], \
            f"{sender} should be in the group via one of its patterns"
        assert result.urgency_tier == 2


def test_a_sender_matching_TWO_patterns_of_one_group_is_ONE_membership_D53(conn):
    """The floor is per-GROUP, never per-pattern — the reason DG3 rejected option C
    (per-row floors would give the sender-override invariant two answers for one
    group). Two overlapping patterns must still produce ONE override record."""
    _multi_group(conn, group_name="overlap",
                 patterns=["ada@dup.example", "*@dup.example"], floor=3, set_tier=4)
    result = _engine(conn).classify(_envelope("ada@dup.example"))

    overrides = [m for m in result.rule_matches
                 if m["rule_id"] is None and "overlap" in m["rule_name"]]
    assert len(overrides) == 1, f"expected one override record, got {overrides}"
    assert result.urgency_tier == 3


def test_a_single_pattern_group_behaves_exactly_as_before_D53(conn):
    """Regression: the one-pattern case is the whole existing corpus."""
    group, rule = _multi_group(conn, group_name="solo", patterns=["*@solo.example"])
    result = _engine(conn).classify(_envelope("x@solo.example"))
    assert rule["id"] in [m["rule_id"] for m in result.rule_matches]
    assert result.urgency_tier == 2


def test_removing_a_pattern_removes_membership_D53(conn):
    """PUT replaces the set atomically (D44 shape), so a removed pattern really
    stops matching — not merely stops being displayed."""
    repo = RulesRepo(conn)
    group, rule = _multi_group(conn, group_name="shrink",
                              patterns=["keep@x.example", "drop@y.example"])
    assert rule["id"] in [m["rule_id"] for m in
                          _engine(conn).classify(_envelope("drop@y.example")).rule_matches]

    repo.update_sender_group(group["id"], {"patterns": ["keep@x.example"]})

    after = _engine(conn).classify(_envelope("drop@y.example"))
    assert rule["id"] not in [m["rule_id"] for m in after.rule_matches]
    # …and the surviving pattern still matches.
    assert rule["id"] in [m["rule_id"] for m in
                          _engine(conn).classify(_envelope("keep@x.example")).rule_matches]


def test_a_group_with_no_usable_pattern_matches_NOBODY_D53(conn):
    """A group with no pattern has no members. That is emphatically not the same as
    a group that matches everyone — an empty pattern must never become a wildcard."""
    repo = RulesRepo(conn)
    group = repo.create_sender_group({
        "group_name": "empty", "patterns": ["placeholder@x.example"],
        "urgency_floor": 1, "notes": None})
    # Drop straight to a pattern-less state (what a legacy placeholder row looks like).
    conn.execute("DELETE FROM sender_group_patterns WHERE group_id = ?", (group["id"],))
    conn.execute("UPDATE sender_groups SET email_pattern = '' WHERE id = ?", (group["id"],))
    conn.commit()

    result = _engine(conn).classify(_envelope("anyone@anywhere.example"))
    assert not any("empty" in (m["rule_name"] or "") for m in result.rule_matches)


# ── D55/D53: match-by-id survives a rename ───────────────────────────────────

def test_renaming_a_group_does_NOT_orphan_its_rules_D55(conn):
    """The D55 gap, closed by match-by-id. Under match-by-name this test fails:
    the rule's `value` still says the old name, so membership silently stops.

    This is the whole point of the migration's Part 5.
    """
    repo = RulesRepo(conn)
    group, rule = _multi_group(conn, group_name="Me", patterns=["*@example.org"])
    # Resolve the rule to the group id, as the migration does for existing rules.
    conn.execute("UPDATE rules SET sender_group_id = ? WHERE id = ?",
                 (group["id"], rule["id"]))
    conn.commit()

    before = _engine(conn).classify(_envelope("you@example.org"))
    assert rule["id"] in [m["rule_id"] for m in before.rule_matches]

    repo.update_sender_group(group["id"], {"group_name": "Myself"})

    after = _engine(conn).classify(_envelope("you@example.org"))
    assert rule["id"] in [m["rule_id"] for m in after.rule_matches], (
        "renaming the group orphaned its rule — match-by-id is not in effect"
    )
    assert after.urgency_tier == 2


def test_an_unresolved_rule_still_matches_by_name_D55(conn):
    """The fallback is what makes match-by-id non-breaking: a rule with
    sender_group_id NULL must keep matching by name.

    UPDATED for gate-defects Part 3. This test used to create the rule through
    the repo and assert the id came back NULL — true when only the D53
    migration ever set it. Save-time resolution (Part 3) now binds it, so the
    old premise no longer holds and asserting it would be asserting the bug.

    The FALLBACK still matters and still needs cover: rules predating the
    migration, and rules whose group name resolves to nothing, both run with a
    NULL id. So the unresolved state is now constructed explicitly rather than
    obtained by accident.
    """
    group, rule = _multi_group(conn, group_name="fallback", patterns=["*@fb.example"])
    # Force the pre-migration shape: bound by name only.
    conn.execute("UPDATE rules SET sender_group_id = NULL WHERE id = ?", (rule["id"],))
    conn.commit()
    assert conn.execute("SELECT sender_group_id FROM rules WHERE id = ?",
                        (rule["id"],)).fetchone()[0] is None

    result = _engine(conn).classify(_envelope("x@fb.example"))
    assert rule["id"] in [m["rule_id"] for m in result.rule_matches]


# ── Part 3 (gate-defects): the id is resolved AT SAVE TIME ────────────────────
#
# The D53 migration resolved sender_group_id for rules that already existed.
# Nothing resolved it for rules created or edited AFTERWARDS: create_rule never
# inserted the column and update_rule never listed it in _RULE_COLUMNS, so every
# rule saved through the UI/API kept sender_group_id NULL and fell back to
# name-matching — which breaks the moment the group is renamed. The existing
# rename test above passes only because it sets the id by raw SQL, standing in
# for the migration; it proves the ENGINE honours the id, not that anything
# writes it.
#
# Rule 18 ("Testing - example.org") hit this live during the 2026-08-01 gate.


def test_create_rule_resolves_sender_group_id_from_the_name(conn):
    """A newly created matches_group rule must be bound by id, not just name."""
    repo = RulesRepo(conn)
    repo.create_sender_group({
        "group_name": "Me", "email_pattern": "*@example.org",
        "urgency_floor": 5, "notes": None,
    })
    group = next(g for g in repo.all_sender_groups() if g["group_name"] == "Me")

    rule = repo.create_rule({
        "rule_name": "Testing - example.org", "priority": 1, "enabled": True,
        "field": "sender_group", "operator": "matches_group", "value": "Me",
        "set_tier": 2, "set_category": "personal", "notes": None,
    })

    assert rule["sender_group_id"] == group["id"], (
        "create_rule left sender_group_id NULL — the rule is name-bound and a "
        "rename will silently orphan it"
    )


def test_a_rule_created_through_the_repo_survives_a_rename(conn):
    """End to end, without the raw-SQL stand-in: create the rule the way the API
    does, rename the group, and the rule must still match."""
    repo = RulesRepo(conn)
    repo.create_sender_group({
        "group_name": "Me", "email_pattern": "*@example.org",
        "urgency_floor": 5, "notes": None,
    })
    group = next(g for g in repo.all_sender_groups() if g["group_name"] == "Me")
    rule = repo.create_rule({
        "rule_name": "Testing - example.org", "priority": 1, "enabled": True,
        "field": "sender_group", "operator": "matches_group", "value": "Me",
        "set_tier": 2, "set_category": "personal", "notes": None,
    })

    before = _engine(conn).classify(_envelope("you@example.org"))
    assert rule["id"] in [m["rule_id"] for m in before.rule_matches]

    repo.update_sender_group(group["id"], {"group_name": "Me (personal)"})

    after = _engine(conn).classify(_envelope("you@example.org"))
    assert rule["id"] in [m["rule_id"] for m in after.rule_matches], (
        "a rule created through the normal save path was orphaned by a rename"
    )
    assert after.urgency_tier == 2


def test_update_rule_rebinds_the_id_when_the_value_changes(conn):
    """Editing a rule to target a DIFFERENT group must move the id with it —
    otherwise the rule keeps matching its old group by a stale id."""
    repo = RulesRepo(conn)
    # Names chosen NOT to collide with the seed corpus (which already ships
    # "family", "leadership", …) — otherwise the lookup below could pick up a
    # seeded row and the assertion would compare the wrong ids.
    for name, pattern in (("GroupAlpha", "*@alpha.example"),
                          ("GroupBeta", "*@beta.example")):
        repo.create_sender_group({
            "group_name": name, "email_pattern": pattern,
            "urgency_floor": 5, "notes": None,
        })
    groups = {g["group_name"]: g["id"] for g in repo.all_sender_groups()}

    rule = repo.create_rule({
        "rule_name": "retarget me", "priority": 1, "enabled": True,
        "field": "sender_group", "operator": "matches_group",
        "value": "GroupAlpha",
        "set_tier": 2, "set_category": "personal", "notes": None,
    })
    assert rule["sender_group_id"] == groups["GroupAlpha"]

    updated = repo.update_rule(rule["id"], {"value": "GroupBeta"})
    assert updated["sender_group_id"] == groups["GroupBeta"], (
        "the rule still points at the old group's id after being retargeted"
    )


def test_an_unresolvable_group_name_leaves_the_id_null_rather_than_guessing(conn):
    """Rule 10 (`value='unknown'`) is the live case: no group is named "unknown",
    so the rule has always been inert. Saving it must NOT invent a binding — a
    wrong id would turn a visibly-dead rule into a silently-wrong one."""
    repo = RulesRepo(conn)
    repo.create_sender_group({
        "group_name": "leadership", "email_pattern": "*@corp.example",
        "urgency_floor": 5, "notes": None,
    })
    rule = repo.create_rule({
        "rule_name": "Unknown sender → Tier 4", "priority": 10, "enabled": True,
        "field": "sender_group", "operator": "matches_group", "value": "unknown",
        "set_tier": 4, "set_category": None, "notes": None,
    })
    assert rule["sender_group_id"] is None


def test_resolution_is_case_insensitive_like_the_engine_D55(conn):
    """Save-time resolution must use the SAME normalizer as matching, or a rule
    that matches by name would fail to bind by id (and vice versa)."""
    repo = RulesRepo(conn)
    repo.create_sender_group({
        "group_name": "Me", "email_pattern": "*@example.org",
        "urgency_floor": 5, "notes": None,
    })
    group = next(g for g in repo.all_sender_groups() if g["group_name"] == "Me")
    rule = repo.create_rule({
        "rule_name": "lowercase value", "priority": 1, "enabled": True,
        "field": "sender_group", "operator": "matches_group", "value": "  me  ",
        "set_tier": 2, "set_category": "personal", "notes": None,
    })
    assert rule["sender_group_id"] == group["id"]


def test_a_non_group_rule_is_left_alone(conn):
    """Only matches_group rules carry a group binding; a subject rule must not
    acquire one just because its value happens to equal a group name."""
    repo = RulesRepo(conn)
    repo.create_sender_group({
        "group_name": "urgent", "email_pattern": "*@corp.example",
        "urgency_floor": 5, "notes": None,
    })
    rule = repo.create_rule({
        "rule_name": "subject contains urgent", "priority": 1, "enabled": True,
        "field": "subject", "operator": "contains", "value": "urgent",
        "set_tier": 2, "set_category": "work", "notes": None,
    })
    assert rule["sender_group_id"] is None
