"""
thresher classification engine
Evaluates the ordered rule set against a message and returns an urgency tier,
category tag, and a human-readable audit trail of which rules matched.

Constitution refs:
  P3 — Transparent by default: every classification includes rule_matches so the
        user can always see *why* an email was classified a given way.
  P4 — Preferences are first-class: all rules live in the DB, not in code.

The sender override invariant is enforced here:
  A message from a known sender group is NEVER classified below that group's
  urgency_floor, regardless of what content rules say.
"""

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Optional
from datetime import datetime, timezone

log = logging.getLogger(__name__)


# ── Result type ────────────────────────────────────────────────────────────────

@dataclass
class ClassificationResult:
    urgency_tier: int           # 1–5
    category: str               # 'work' | 'personal' | 'unknown'
    rule_matches: list          # audit trail — list of dicts
    classified_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def explain(self) -> str:
        """Return a human-readable explanation of the classification (P3)."""
        lines = [
            f"Urgency tier: {self.urgency_tier}",
            f"Category: {self.category}",
            f"Rules matched ({len(self.rule_matches)}):",
        ]
        for m in self.rule_matches:
            lines.append(f"  • [{m['rule_name']}] — {m['field']} {m['operator']} '{m['value']}'")
        if not self.rule_matches:
            lines.append("  • (no rules matched — defaults applied)")
        return "\n".join(lines)


# ── Group-name normalization (OI19) ───────────────────────────────────────────

def _norm_group(name) -> str:
    """Normalize a sender-group name for membership comparison (OI19).

    Group names are matched by name, case-insensitively: the membership set and
    the rule's stored value are both put through this one function so the two
    sides can never drift apart again. `casefold()` rather than `lower()` because
    it is the correct caseless-comparison primitive; `strip()` because a stray
    space in a hand-typed group name shouldn't silently break every rule that
    targets it.

    Since D53 this is the FALLBACK path: rules normally match by
    `sender_group_id`, which survives a rename. Name matching still runs for rules
    the migration left unresolved (a value naming no group, or an ambiguous one),
    which is what makes match-by-id non-breaking.
    """
    return (name or "").strip().casefold()


def _rule_group_id(rule):
    """A rule's `sender_group_id`, or None if unset or the column doesn't exist.

    The column arrives with the D53 migration, so a rule row from an unmigrated
    database simply has no such key — that must read as "fall back to name
    matching", not as an error.
    """
    try:
        return rule["sender_group_id"]
    except (IndexError, KeyError):
        return None


# ── Message envelope (what the engine needs to classify) ──────────────────────

@dataclass
class MessageEnvelope:
    """Lightweight view of a message used during classification."""
    id: str
    sender_email: str
    sender_name: Optional[str]
    subject: Optional[str]
    body_plain: Optional[str]

    @property
    def sender_domain(self) -> str:
        if "@" in self.sender_email:
            return self.sender_email.split("@", 1)[1].lower()
        return ""


# ── Engine ────────────────────────────────────────────────────────────────────

class ClassificationEngine:
    """
    Stateless rule evaluator. Instantiate once with the loaded rule set and
    sender groups; call classify() per message.

    Rules are evaluated in priority order (lowest number first).
    - set_tier rules update the tier floor (never raise it above an already-matched
      lower tier from a higher-priority rule unless the new rule has higher priority).
    - set_category rules set the category (last match wins, but sender group rules
      run first by convention of having low priority numbers).

    The sender override invariant: after all rules, the tier is floored to the
    minimum urgency_floor of any matching sender group.
    """

    def __init__(self, rules: list, sender_groups: list):
        """
        Args:
            rules: list of sqlite3.Row or dict-like objects from the rules table,
                   ordered by priority ASC.
            sender_groups: list of sqlite3.Row or dict-like objects from sender_groups.
        """
        self._rules = rules
        self._sender_groups = sender_groups

    def classify(self, msg: MessageEnvelope) -> ClassificationResult:
        tier: Optional[int] = None
        category: Optional[str] = None
        matches = []

        # ── Step 1: determine which sender groups this sender belongs to ───────
        sender_groups_matched = self._match_sender_groups(msg)
        # OI19 (Session 27 gate): casefold the membership set. `_evaluate_rule`
        # lowercases the rule's value, so a case-preserved set here means any
        # rule targeting a mixed-case group name ("Me") can never match — the
        # bug was unreachable while every seed group name was lowercase. One
        # normalization point, both sides folded; see tests/test_engine.py.
        sender_group_names = {_norm_group(g["group_name"]) for g in sender_groups_matched}
        # D53/D55: membership by group ID is the primary path — renaming a group no
        # longer orphans the rules that target it. The name set above stays as the
        # fallback for rules whose id the migration couldn't resolve unambiguously.
        sender_group_ids = {g["id"] for g in sender_groups_matched}

        # ── Step 2: evaluate rules in priority order ───────────────────────────
        for rule in self._rules:
            if not rule["enabled"]:
                continue

            matched = self._evaluate_rule(rule, msg, sender_group_names,
                                         sender_group_ids)
            if not matched:
                continue

            match_record = {
                "rule_id":   rule["id"],
                "rule_name": rule["rule_name"],
                "field":     rule["field"],
                "operator":  rule["operator"],
                "value":     rule["value"],
            }

            if rule["set_tier"] is not None:
                new_tier = rule["set_tier"]
                if tier is None or new_tier < tier:
                    # Only lower the tier (increase urgency) — a more urgent rule
                    # always wins over a less urgent one.
                    tier = new_tier
                    match_record["applied_tier"] = tier
                else:
                    match_record["skipped_tier"] = f"{new_tier} (less urgent than current {tier})"

            if rule["set_category"] is not None:
                category = rule["set_category"]
                match_record["applied_category"] = category

            matches.append(match_record)

        # ── Step 3: apply sender override invariant ────────────────────────────
        # A message from a known sender group must NEVER land below that group's floor.
        for group in sender_groups_matched:
            floor = group["urgency_floor"]
            if tier is None or tier > floor:
                old_tier = tier
                tier = floor
                matches.append({
                    "rule_id":   None,
                    "rule_name": f"Sender override invariant — group '{group['group_name']}'",
                    "field":     "sender_group",
                    "operator":  "matches_group",
                    "value":     group["group_name"],
                    "applied_tier": tier,
                    "overrode_tier": old_tier,
                })

        # ── Step 4: apply defaults if nothing matched ──────────────────────────
        if tier is None:
            tier = 4  # Unknown senders default to Tier 4
        if category is None:
            category = "unknown"

        result = ClassificationResult(
            urgency_tier=tier,
            category=category,
            rule_matches=matches,
        )

        log.debug("Classified %s → tier=%d category=%s (%d rules matched)",
                  msg.id, tier, category, len(matches))
        return result

    # ── Private helpers ────────────────────────────────────────────────────────

    def _match_sender_groups(self, msg: MessageEnvelope) -> list:
        """Return every sender group this message's sender belongs to.

        D53: a group is a named set of address patterns sharing ONE floor tier, and
        a sender matching **any** pattern is in the group. Matching two patterns of
        the same group is still ONE membership — the floor is per-group, never
        per-pattern. (Per-pattern floors were exactly why DG3's option C was
        rejected: the sender-override invariant would have two answers for one
        group.) So this appends each group at most once.
        """
        sender = msg.sender_email.lower()
        matched = []
        for group in self._sender_groups:
            for pattern in self._group_patterns(group):
                if self._pattern_matches(pattern, sender):
                    matched.append(group)
                    break          # one membership per group, not one per pattern
        return matched

    @staticmethod
    def _group_patterns(group) -> list:
        """A group's patterns, from the D53 child table with a legacy fallback.

        Prefers the `patterns` list the repo now supplies; falls back to the
        deprecated single `email_pattern` column so the engine keeps working
        against a database that hasn't been migrated yet (and so the two-step
        deprecation is real rather than nominal). Empty/whitespace patterns are
        dropped: they matched nothing before and must match nothing now — a group
        with no usable pattern has no members, which is not the same as a group that
        matches everyone.
        """
        raw = None
        try:
            raw = group["patterns"]
        except (IndexError, KeyError):
            raw = None
        if raw is None:
            try:
                legacy = group["email_pattern"]
            except (IndexError, KeyError):
                legacy = None
            raw = [legacy] if legacy else []
        return [p.strip() for p in raw if p and p.strip()]

    @staticmethod
    def _pattern_matches(pattern: str, value: str) -> bool:
        """
        Match a sender pattern against a value.
        Supports:
          - exact match:   'boss@example.com'
          - glob (*):      '*@example.com'
          - domain-only:   '@example.com' (shorthand for *@example.com)
        """
        pattern = pattern.lower().strip()
        value   = value.lower().strip()

        if pattern.startswith("@"):
            # domain shorthand
            return value.endswith(pattern)
        if "*" in pattern:
            # Simple glob: convert to regex
            regex = re.escape(pattern).replace(r"\*", ".*")
            return bool(re.fullmatch(regex, value))
        return pattern == value

    def _evaluate_rule(self, rule, msg: MessageEnvelope, sender_group_names: set,
                       sender_group_ids: set = frozenset()) -> bool:
        """Return True if this rule matches the message."""
        field_name = rule["field"]
        operator   = rule["operator"]
        value      = (rule["value"] or "").lower()

        # Resolve the field value from the message
        if field_name == "sender_email":
            field_val = msg.sender_email.lower()
        elif field_name == "sender_domain":
            field_val = msg.sender_domain.lower()
        elif field_name == "subject":
            field_val = (msg.subject or "").lower()
        elif field_name == "body":
            field_val = (msg.body_plain or "").lower()
        elif field_name == "sender_group":
            if operator == "matches_group":
                # D53/D55: prefer the group ID. A rule carrying `sender_group_id`
                # survives a group rename, which match-by-name never did.
                group_id = _rule_group_id(rule)
                if group_id is not None:
                    return group_id in sender_group_ids
                # Fallback for rules the migration left unresolved (no match, or an
                # ambiguous name): compare by name, which keeps this change
                # non-breaking. OI19: normalize the rule's value through the SAME
                # function that built the membership set — `value`'s plain .lower()
                # above is not enough on its own (that mismatch was the bug).
                return _norm_group(rule["value"]) in sender_group_names
            field_val = ""
        else:
            log.warning("Unknown rule field: %s", field_name)
            return False

        # Apply operator
        if operator == "equals":
            return field_val == value
        elif operator == "contains":
            return value in field_val
        elif operator == "starts_with":
            return field_val.startswith(value)
        elif operator == "ends_with":
            return field_val.endswith(value)
        elif operator == "matches_group":
            return False  # handled above for sender_group field
        else:
            log.warning("Unknown rule operator: %s", operator)
            return False
