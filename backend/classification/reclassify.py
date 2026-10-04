"""
Reclassification on demand (D52).

Classify-once-at-ingest is a real design property, not an accident: a stored audit
trail is stable, and history doesn't rewrite itself under the user (P3-adjacent). But
the rules editor makes rule iteration cheap, and every iteration widens the gap
between "rules as written" and "classifications as stored". D52 closes that gap with
an explicit, user-invoked re-run.

The four pinned invariants from DG4, and where each is enforced here:

1. **Triage state survives reclassification** — a Done message reclassified to T1
   stays Done. Enforced twice: `ClassificationRepo.upsert`'s ON CONFLICT clause does
   not touch `triage_state`, AND `reclassify_one` passes the existing state back
   explicitly rather than defaulting to "new". Belt and braces, because this is the
   invariant a user would actually notice being broken.
2. **Reclassification is SILENT** — no retroactive banners or digest entries. This
   module never touches `NotificationService` or `notification_log`; the ingestion
   pipeline's post-classification hook is deliberately NOT reused here.
3. **Overwrite with a dated audit, never version** — the classification row is
   updated in place, and `reclassified_at` records that it was re-run. No history
   table, no second row.
4. **Classify-once stays the default lifecycle** — nothing in this module runs
   automatically. Both entry points are called only from an explicit user action.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from classification.engine import ClassificationEngine, MessageEnvelope
from db.database import Classification, ClassificationRepo, RulesRepo

log = logging.getLogger("thresher.reclassify")


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def build_engine(conn) -> ClassificationEngine:
    """The engine, loaded exactly as `ingestion.pipeline._build_engine` loads it.

    Built ONCE per reclassify run so the rule set cannot shift mid-run — a bulk pass
    over ~1,600 messages must not straddle a rule edit.
    """
    repo = RulesRepo(conn)
    return ClassificationEngine(rules=repo.all_enabled(),
                                sender_groups=repo.all_sender_groups())


def to_envelope(row) -> MessageEnvelope:
    """A stored message row → the engine's input shape."""
    return MessageEnvelope(
        id=row["id"],
        sender_email=row["sender_email"],
        sender_name=row["sender_name"] if "sender_name" in row.keys() else None,
        subject=row["subject"] if "subject" in row.keys() else None,
        body_plain=row["body_plain"] if "body_plain" in row.keys() else None,
    )


@dataclass
class ReclassifyOutcome:
    """What one message's re-run did. `changed` drives the bulk summary."""
    message_id: str
    urgency_tier: int
    category: str
    triage_state: str
    classified_at: str
    reclassified_at: str
    rule_matches: list
    changed: bool
    previous_tier: Optional[int] = None
    previous_category: Optional[str] = None

    def to_dict(self) -> dict:
        return {
            "message_id":      self.message_id,
            "urgency_tier":    self.urgency_tier,
            "category":        self.category,
            "triage_state":    self.triage_state,
            "classified_at":   self.classified_at,
            "reclassified_at": self.reclassified_at,
            "rule_matches":    self.rule_matches,
            "changed":         self.changed,
            "previous_tier":     self.previous_tier,
            "previous_category": self.previous_category,
        }


def reclassify_one(conn, message_row, *, engine=None,
                   commit: bool = True) -> ReclassifyOutcome:
    """Re-run the current engine over one stored message and overwrite its row.

    `engine` is injectable so a bulk run builds it once (invariant: one rule set for
    the whole pass). `commit=False` lets the bulk path batch commits.
    """
    engine = engine or build_engine(conn)
    cls_repo = ClassificationRepo(conn)

    existing = cls_repo.get(message_row["id"])
    # A message with NO classification row is legitimate — P1 stores the message
    # before classifying, and the D50 amendment surfaces those in Open. Reclassify
    # must be able to fix exactly that case, so "new" is the right state for a row
    # that never had one.
    previous_state = existing["triage_state"] if existing else "new"
    previous_tier = existing["urgency_tier"] if existing else None
    previous_category = existing["category"] if existing else None

    result = engine.classify(to_envelope(message_row))
    stamped = _utcnow()

    cls_repo.upsert(Classification(
        message_id=message_row["id"],
        urgency_tier=result.urgency_tier,
        category=result.category,
        # Invariant 1, stated explicitly rather than relying on the ON CONFLICT
        # clause alone: the user's triage decision is theirs, not the engine's.
        triage_state=previous_state,
        classified_at=result.classified_at,
        rule_matches=result.rule_matches,
    ), commit=commit)
    # Invariant 3: the audit says it was RE-run, without keeping a version.
    conn.execute("UPDATE classifications SET reclassified_at = ? WHERE message_id = ?",
                 (stamped, message_row["id"]))
    if commit:
        conn.commit()

    # NOTE (invariant 2): no notification hook here, deliberately. The ingestion
    # pipeline fires notifications after classification; reusing that path would
    # spray retroactive banners across the user's whole archive.

    return ReclassifyOutcome(
        message_id=message_row["id"],
        urgency_tier=result.urgency_tier,
        category=result.category,
        triage_state=previous_state,
        classified_at=result.classified_at,
        reclassified_at=stamped,
        rule_matches=result.rule_matches,
        changed=(previous_tier != result.urgency_tier
                 or previous_category != result.category),
        previous_tier=previous_tier,
        previous_category=previous_category,
    )


# Commit every N messages during a bulk run: often enough that a crash loses little,
# rarely enough that ~1,600 messages don't pay 1,600 fsyncs. One transaction for the
# whole run was rejected for the D44 reason — the classifier reloads per poll and
# must never read a half-applied state for long.
BULK_COMMIT_EVERY = 100


def reclassify_all(conn, *, commit_every: int = BULK_COMMIT_EVERY) -> dict:
    """Re-run the current engine over every stored message.

    Returns a summary: counted / changed / unchanged / errors (+ the failing ids).

    A per-message failure does NOT abort the run (P1: a message is never lost because
    classification failed). It is counted, logged, and the pass continues.
    """
    engine = build_engine(conn)

    # Select ONLY the columns the engine reads, and ITERATE the cursor instead of
    # fetchall(). The original `SELECT * … .fetchall()` pulled every message —
    # body_plain AND body_html — into memory at once: measured at ~20 MB per run on a
    # 1,592-message store, and because CPython's allocator does not return freed
    # arenas to the OS, RSS grew monotonically (6 MB → 128 → 181 → 202 → 252 MB over
    # six runs) and never came back. A bulk reclassify is explicitly a whole-store
    # operation, so it is exactly the wrong place to materialise the whole store.
    #
    # body_html is never read by the engine (to_envelope only takes body_plain), so
    # it is not selected at all. A total count is fetched separately for the progress
    # log, which is cheap and keeps the streaming read.
    total = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
    cursor = conn.execute(
        "SELECT id, sender_email, sender_name, subject, body_plain "
        "FROM messages ORDER BY received_at DESC"
    )

    counted = changed = errors = 0
    failed_ids: list[str] = []

    for i, row in enumerate(cursor, start=1):
        try:
            outcome = reclassify_one(conn, row, engine=engine, commit=False)
            counted += 1
            if outcome.changed:
                changed += 1
        except Exception:                    # noqa: BLE001 — counted, never fatal
            errors += 1
            failed_ids.append(row["id"])
            log.exception("Reclassify failed for %s; continuing", row["id"])

        if i % commit_every == 0:
            conn.commit()
            log.info("Reclassify progress: %d/%d (%d changed, %d errors)",
                     i, total, changed, errors)

    conn.commit()
    log.info("Reclassify complete: %d counted, %d changed, %d unchanged, %d errors",
             counted, changed, counted - changed, errors)
    return {
        "counted":   counted,
        "changed":   changed,
        "unchanged": counted - changed,
        "errors":    errors,
        "failed_ids": failed_ids,
    }


def rules_changed_since(conn, since: Optional[str]) -> int:
    """How many rules are KNOWN to have changed since `since` (D52 part D).

    NULL `updated_at` contributes zero: pre-D52 rules have no recorded edit time, so
    the honest answer is "not known to have changed", not "might have". The copy this
    feeds must match that meaning.
    """
    if not since:
        return 0
    return conn.execute(
        "SELECT COUNT(*) FROM rules WHERE updated_at IS NOT NULL AND updated_at > ?",
        (since,),
    ).fetchone()[0]
