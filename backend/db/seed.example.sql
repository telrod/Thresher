-- thresher seed data — EXAMPLE / placeholder version
-- This is the committed template. The real seed.sql (with actual contacts) is
-- local-only and gitignored. Copy this to seed.sql and replace the example
-- patterns with your own senders before first run.
--
-- Sender groups and default rules derived from constitution.md §"People in Scope".
-- All of this is user-editable; these are starting points, not constants (P4).

-- ─────────────────────────────────────────
-- Sender groups (constitution §People in Scope)
-- email_pattern accepts an exact address, a glob (*@example.com), or the
-- domain shorthand (@example.com). Leave blank to add members later via Settings.
-- ─────────────────────────────────────────
INSERT INTO sender_groups (group_name, email_pattern, urgency_floor, notes) VALUES
    ('leadership',      'boss@example.com',     1, 'Your manager / leadership — always Tier 1'),
    ('family',          '',                     1, 'Placeholder: add family emails via Settings'),
    ('close_colleagues','colleague@example.com',2, 'A trusted colleague'),
    ('recruiters',      '',                     2, 'Add recruiter emails via Settings if relevant');

-- Group membership lives HERE (D53). One row per pattern; a group may have many.
--
-- OI36: this table used to be EMPTY in both seeds, and classification worked only
-- because `all_sender_groups` falls back per-group to the deprecated
-- `email_pattern` column above. D53 says that column is retained one release and
-- dropped in a later migration — and doing that drop against an unconverted seed
-- leaves every seeded group with ZERO patterns: `matches_group` matches nothing,
-- every group rule goes inert, and mail from leadership and family silently stops
-- being Tier 1. Measured 2026-09-02, not predicted: blanking the column takes
-- boss@example.com from T1 to T4, with no error anywhere.
--
-- The `email_pattern` values above are kept in sync deliberately — this order
-- finishes the conversion, it does not begin the deprecation, and the fallback
-- must keep working for databases seeded the old way.
INSERT INTO sender_group_patterns (group_id, pattern)
SELECT id, 'boss@example.com'      FROM sender_groups WHERE group_name = 'leadership';
INSERT INTO sender_group_patterns (group_id, pattern)
SELECT id, 'colleague@example.com' FROM sender_groups WHERE group_name = 'close_colleagues';
-- 'family' and 'recruiters' ship with no members on purpose (add via Settings),
-- so they get no pattern rows — the same membership they have today, expressed
-- in the new table rather than as an empty string in the old column.

-- ─────────────────────────────────────────
-- Default preferences
-- ─────────────────────────────────────────
INSERT INTO preferences (key, value, updated_at) VALUES
    -- catch-up, not focus (decided 2026-09-07 from the cold-start run).
    -- Focus alerts on Tier 1 ONLY, and a fresh install has no Tier 1 rule that
    -- can fire: both T1 rules target sender groups that ship memberless. So a
    -- new user got GUARANTEED SILENCE regardless of what arrived — the app
    -- promising urgency triage and delivering none of it.
    -- Catch-up alerts on T1+T2, which the seeded T2 rules (verification codes,
    -- security alerts, password resets, calendar invitations) actually reach,
    -- so a first-run user gets real alerts on day one. Focus becomes the right
    -- default once ask/propose populate the groups and T1 means something.
    -- Backfill stays silent regardless (D62), so this is steady-state volume.
    ('operating_mode',          'catch-up',     datetime('now')),
    ('daily_ceiling',           '50',           datetime('now')),
    ('digest_time',             '09:00',        datetime('now')),
    ('poll_interval_minutes',   '5',            datetime('now')),
    ('writeback_enabled',       'false',        datetime('now')),
    ('tier1_sound_enabled',     'false',        datetime('now'));

-- ─────────────────────────────────────────
-- Starter classification rules
-- priority: lower number = evaluated first
-- These implement the sender override invariant and basic content signals.
-- ─────────────────────────────────────────
INSERT INTO rules (rule_name, priority, field, operator, value, set_tier, set_category, notes) VALUES
    -- Sender group overrides (highest priority — the sender override invariant)
    ('Leadership senders → Tier 1',       10, 'sender_group', 'matches_group', 'leadership',       1, NULL,       'Constitution invariant: floor tier for leadership group'),
    ('Family senders → Tier 1',           11, 'sender_group', 'matches_group', 'family',           1, NULL,       'Constitution invariant: floor tier for family group'),
    ('Recruiter senders → Tier 2',        20, 'sender_group', 'matches_group', 'recruiters',       2, NULL,       'Recruiters surface within 1-4h'),
    ('Close colleagues → Tier 2',         21, 'sender_group', 'matches_group', 'close_colleagues', 2, NULL,       'Known colleagues always surface within 1-4h'),

    -- Work domain signals (replace example.com with your work domain)
    ('Work domain → Work',                30, 'sender_domain', 'equals',       'example.com',      NULL, 'work',  'All @example.com senders tagged Work'),

    -- Content urgency signals
    ('Subject: urgent keyword → Tier 2',  50, 'subject',       'contains',     'urgent',           2, NULL,       'Explicit urgency marker in subject'),
    ('Subject: action required → Tier 2', 51, 'subject',       'contains',     'action required',  2, NULL,       NULL),

    -- Time-sensitive machine mail → Tier 2.
    -- Automated, but you usually need it within minutes: a code that expires, a
    -- reset you just asked for, a security alert you did not. These fire on
    -- SUBJECT text, so they work regardless of who sent them.
    ('Subject: verification code → Tier 2',   52, 'subject', 'contains', 'verification code', 2, NULL, 'Expires in minutes — surfacing it late is the same as not surfacing it'),
    ('Subject: security alert → Tier 2',      53, 'subject', 'contains', 'security alert',    2, NULL, NULL),
    ('Subject: password reset → Tier 2',      54, 'subject', 'contains', 'password reset',    2, NULL, 'You almost certainly just asked for this'),
    ('Subject: sign-in attempt → Tier 2',     55, 'subject', 'contains', 'sign-in attempt',   2, NULL, NULL),
    ('Subject: one-time passcode → Tier 2',   56, 'subject', 'contains', 'one-time',          2, NULL, NULL),
    ('Subject: invitation → Tier 2',          57, 'subject', 'contains', 'invitation:',       2, NULL, 'Calendar invitations — the trailing colon is the calendar convention'),

    ('Subject: JIRA/ticket → Tier 3',     60, 'subject',       'contains',     'JIRA',             3, 'work',     'JIRA notifications: Tier 3 unless sender overrides'),
    ('Subject: GitHub → Tier 3',          61, 'subject',       'contains',     'GitHub',           3, 'work',     NULL),

    -- ── Automated-looking senders → Tier 5 ───────────────────────────────────
    --
    -- ⚠️ THE NAME OF THIS RULE IS DELIBERATE, AND SO IS WHAT IT DOES NOT CLAIM.
    -- It matches senders whose ADDRESS looks automated. It is NOT a bulk-mail or
    -- newsletter rule, and naming it one would overpromise.
    --
    -- The reliable signal for bulk mail is the List-Unsubscribe header, and the
    -- rule engine cannot see headers at all — it matches only sender_email,
    -- sender_domain, subject, body and sender_group. Measured on a real
    -- 15-message sample: List-Unsubscribe caught 4, an address pattern caught 3,
    -- and the overlap was ZERO. These are two disjoint halves, so this rule is
    -- structurally about half-blind to list mail and will miss newsletters from
    -- senders like service@ or support@ that read as human.
    --
    -- That is why it says 'automated-looking senders' rather than 'bulk mail':
    -- a user reading the rules list can then understand why some newsletters
    -- still arrive at Tier 3, instead of concluding the tier is unreliable.
    -- See the header-matching open item.
    ('Automated-looking senders → Tier 5', 80, 'sender_email', 'starts_with', 'no-reply',  5, NULL, 'Address begins no-reply@ — see the rule notes on what this does NOT catch'),
    ('Automated-looking senders (noreply) → Tier 5', 81, 'sender_email', 'starts_with', 'noreply', 5, NULL, NULL),
    ('Automated-looking senders (donotreply) → Tier 5', 82, 'sender_email', 'starts_with', 'donotreply', 5, NULL, NULL),
    ('Sender contains no-reply → Tier 5',  83, 'sender_email', 'contains',    'no-reply',  5, NULL, 'Catches digital-no-reply@ and similar, which starts_with misses'),
    ('Sender contains noreply → Tier 5',   84, 'sender_email', 'contains',    'noreply',   5, NULL, NULL),
    ('Marketing senders → Tier 5',         85, 'sender_email', 'starts_with', 'marketing', 5, NULL, NULL),
    ('Newsletter senders → Tier 5',        86, 'sender_email', 'starts_with', 'newsletter', 5, NULL, NULL);

-- REMOVED (2026-09-02, migration-prep batch 1 Part B): 'Unknown sender → Tier 4',
-- priority 90, matches_group 'unknown'. It never matched a single message —
-- `matches_group` compares against the names of groups the sender belongs to,
-- and no sender group has ever been named "unknown". the author did not recognize it.
-- Unmatched mail already lands at Tier 4 through the engine's default, so the
-- rule was not doing this job by another route; it was doing nothing.
-- No migration ships with this: the current store is being abandoned at the
-- public-repo cutover, so cleaning a database about to be discarded is wasted
-- work. Seed edit only.