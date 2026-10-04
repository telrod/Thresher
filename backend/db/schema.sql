-- thresher message store schema
-- Version: 1.0.0
-- Constitution refs: P1 (never drop), P3 (transparent), P4 (configurable)

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- ─────────────────────────────────────────
-- Messages
-- Every email ever retrieved. Never deleted by the tool (P1).
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS messages (
    id              TEXT PRIMARY KEY,       -- Gmail message ID
    account         TEXT NOT NULL,          -- e.g. you@example.com
    thread_id       TEXT,
    sender_name     TEXT,
    sender_email    TEXT NOT NULL,
    subject         TEXT,
    body_plain      TEXT,
    body_html       TEXT,
    received_at     TEXT NOT NULL,          -- ISO-8601
    ingested_at     TEXT NOT NULL,          -- ISO-8601, when we pulled it
    raw_headers     TEXT                    -- JSON blob of all headers
);

-- ─────────────────────────────────────────
-- Classifications
-- The result of running the rules engine on a message (P3: transparent).
-- One row per message; updated if reclassified.
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS classifications (
    message_id      TEXT PRIMARY KEY REFERENCES messages(id),
    urgency_tier    INTEGER NOT NULL CHECK (urgency_tier BETWEEN 1 AND 5),
    category        TEXT NOT NULL CHECK (category IN ('work', 'personal', 'unknown')),
    triage_state    TEXT NOT NULL DEFAULT 'new'
                        CHECK (triage_state IN ('new', 'acknowledged', 'needs_action', 'done')),
    classified_at   TEXT NOT NULL,          -- ISO-8601
    rule_matches    TEXT NOT NULL,          -- JSON array: [{rule_id, rule_name, field, value}]
                                            -- Satisfies P3: user can always see why
    -- D52 invariant 3 ("overwrite with dated audit, never version"): no history
    -- table, no second row — this single column records that the classification was
    -- RE-run and when. NULL = classified once at ingest and never re-run, which is
    -- invariant 4's default lifecycle.
    reclassified_at TEXT
);

-- ─────────────────────────────────────────
-- Sender groups
-- Maps sender email patterns to named groups (P4: configurable).
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sender_groups (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    group_name      TEXT NOT NULL,          -- e.g. "leadership", "recruiters", "family"
    -- DEPRECATED by D53 (two-step): patterns now live in sender_group_patterns.
    -- Retained for one release so a rollback to the previous binary still
    -- classifies; the engine no longer reads it. Drop in a later migration.
    email_pattern   TEXT NOT NULL,
    urgency_floor   INTEGER NOT NULL CHECK (urgency_floor BETWEEN 1 AND 5),
    -- The sender override invariant: a message from this group will never be
    -- classified *below* urgency_floor, regardless of content signals.
    notes           TEXT
);

-- ─────────────────────────────────────────
-- Sender group patterns (D53)
-- A sender group is a named set of address patterns sharing ONE floor tier; a
-- sender matching ANY pattern is in the group. The floor stays per-GROUP, never
-- per-pattern — per-row floors were the reason option C was rejected (the
-- sender-override invariant would have two answers for one group).
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sender_group_patterns (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    group_id        INTEGER NOT NULL REFERENCES sender_groups(id) ON DELETE CASCADE,
    pattern         TEXT NOT NULL,          -- exact email, glob (*@x.com), or @domain
    UNIQUE (group_id, pattern)              -- a duplicate pattern in one group is meaningless
);
CREATE INDEX IF NOT EXISTS idx_sgp_group_id ON sender_group_patterns(group_id);

-- ─────────────────────────────────────────
-- Classification rules
-- Ordered list of rules evaluated top-to-bottom (P4: configurable).
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rules (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_name       TEXT NOT NULL,
    priority        INTEGER NOT NULL DEFAULT 100,   -- lower = evaluated first
    enabled         INTEGER NOT NULL DEFAULT 1,
    field           TEXT NOT NULL,                  -- 'sender_email', 'sender_domain',
                                                    -- 'subject', 'body', 'sender_group'
    operator        TEXT NOT NULL,                  -- 'equals', 'contains', 'starts_with',
                                                    -- 'ends_with', 'matches_group'
    value           TEXT NOT NULL,
    set_tier        INTEGER CHECK (set_tier BETWEEN 1 AND 5),
    set_category    TEXT CHECK (set_category IN ('work', 'personal')),
    notes           TEXT,
    -- D55/D53: `matches_group` rules reference their group by ID, so renaming a
    -- group no longer orphans them. NULL means unresolved — the engine falls back
    -- to comparing `value` against group names (case-insensitively) so the change
    -- is non-breaking. Migration 2 backfills unambiguous matches only; misses and
    -- ambiguities are reported, never guessed.
    sender_group_id INTEGER REFERENCES sender_groups(id) ON DELETE SET NULL,
    -- D52 part D: when this rule last changed, so the explain panel can say how
    -- stale a stored classification is ("N rules have changed since"). NULL means
    -- "not known to have changed" — pre-D52 rows are left NULL deliberately, since
    -- stamping a time would make every stored classification look instantly stale.
    updated_at      TEXT,
    -- At least one of set_tier / set_category must be non-null: a rule that can
    -- match must do something (a no-effect rule pollutes /explain, P3). The API
    -- enforces this post-merge on writes; this table-level CHECK is the
    -- schema backstop for fresh DBs. (Existing DBs predate the constraint — see
    -- Open items; the API check covers them, so no migration is shipped.)
    -- NOTE: a table-level constraint must follow ALL column defs, hence it sits
    -- after `notes` rather than beside the set_* columns.
    CHECK (set_tier IS NOT NULL OR set_category IS NOT NULL)
);

-- ─────────────────────────────────────────
-- Preferences
-- Key-value store for all user-configurable settings (P4).
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS preferences (
    key             TEXT PRIMARY KEY,
    value           TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

-- ─────────────────────────────────────────
-- Notification log
-- Record of every notification sent (for debugging and transparency).
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id      TEXT REFERENCES messages(id),
    notification_type TEXT NOT NULL,        -- 'tier1_alert', 'tier2_alert', 'digest'
    sent_at         TEXT NOT NULL,
    payload         TEXT                    -- JSON
);

-- Executed-bulk audit log (D60).
--
-- APPEND-ONLY, AND IT IS A LOG, NOT STATE. Nothing UPDATEs or DELETEs these
-- rows, and — this is the part that matters — **no code path may read this
-- table to make a decision.** The first person who wants a shortcut will reach
-- for it (it looks like a convenient cache of "what was recently triaged"); a
-- log that something depends on stops being append-only in practice, because
-- then its contents have to be correct rather than merely honest.
--
-- Why it exists: the filter and the frozen `until` bound exist ONLY at execute
-- time and cannot be reconstructed afterwards. Every other part of an undo
-- feature can be added whenever; this part cannot, so it is recorded now even
-- though undo is deliberately not built (see docs/IDEAS.md).
--
-- Written INSIDE the same transaction as the bulk UPDATE, so a recorded
-- operation and an applied operation cannot diverge.
--
-- Retention: none needed, and that is load-bearing rather than an oversight —
-- rows are bounded by how often a human runs a bulk action. This stays true
-- ONLY while the log records OPERATIONS. If per-message prior state is ever
-- added for undo, growth becomes unbounded and retention becomes mandatory.
CREATE TABLE IF NOT EXISTS bulk_operation_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    executed_at     TEXT NOT NULL,          -- ISO-8601 UTC
    triage_state    TEXT NOT NULL,          -- the state applied
    filter_json     TEXT,                   -- the filter AS JSON, not a rendered string;
                                            -- NULL for an explicit-id bulk
    until_bound     TEXT,                   -- the frozen upper bound (filter mode)
    account         TEXT,                   -- set only if the filter was account-scoped
    matched_count   INTEGER NOT NULL,       -- how many the selection resolved to
    updated_count   INTEGER NOT NULL,       -- rows actually affected
    already_count   INTEGER NOT NULL DEFAULT 0  -- of those, already in the target state
);

-- Mailbox write-back log (D63).
--
-- One row per ATTEMPT to modify the real mailbox, recorded whether or not it
-- succeeded. This is the only outward-facing side effect the app has (P5), and
-- until now it left no trace: the `wrote_back` flag went back to the client and
-- was discarded. When a write-back was noticed happening unexpectedly, the
-- honest answer to "how many messages has this touched?" was *unknowable* —
-- the only bound available was the count of triage requests in an access log
-- that does not record the outcome.
--
-- An unbounded, unknowable blast radius on the one feature that reaches outside
-- the app is the part that needed fixing, independently of who enabled it.
--
-- Append-only, and like `bulk_operation_log` it is a LOG, NOT STATE: nothing
-- reads it to make a decision. Failures are recorded too (`ok = 0`) — a log of
-- only the successes would understate what was attempted against the mailbox.
CREATE TABLE IF NOT EXISTS writeback_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    attempted_at    TEXT NOT NULL,          -- ISO-8601 UTC
    account         TEXT NOT NULL,
    message_id      TEXT NOT NULL,          -- the local {account}:{uid}
    rfc822_id       TEXT,                    -- what was actually targeted (D46)
    action          TEXT NOT NULL,          -- 'mark_read'
    triage_state    TEXT,                    -- the state that triggered it
    ok              INTEGER NOT NULL,        -- 1 = the flag was set, 0 = not
    detail          TEXT                     -- failure reason when ok = 0
);

-- ─────────────────────────────────────────
-- Indices
-- ─────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_messages_received_at     ON messages(received_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_sender_email    ON messages(sender_email);
CREATE INDEX IF NOT EXISTS idx_classifications_tier     ON classifications(urgency_tier);
CREATE INDEX IF NOT EXISTS idx_classifications_state    ON classifications(triage_state);
CREATE INDEX IF NOT EXISTS idx_rules_priority           ON rules(priority ASC);
-- The log is read newest-first and only ever by a human asking "what did that
-- operation do?", so one descending index covers its single query shape.
CREATE INDEX IF NOT EXISTS idx_bulk_log_executed_at     ON bulk_operation_log(executed_at DESC);
-- Two query shapes, both human-driven: "what happened recently?" and "was THIS
-- message ever written back?" — the second is what bounds a blast radius.
CREATE INDEX IF NOT EXISTS idx_writeback_log_at         ON writeback_log(attempted_at DESC);
CREATE INDEX IF NOT EXISTS idx_writeback_log_message    ON writeback_log(message_id);
