# API-Contract → Screen Map

**Frontend Phase 0 deliverable.** Maps every endpoint the SwiftUI app consumes to
(a) the screen(s) that use it and (b) the **ground-truth** serializer shape returned by
the code as written — not the prose in `CLAUDE.md`/`spec.md`.

Traced from `backend/api/app.py` (routes + serializers), `backend/db/database.py` (the
queries that feed those serializers — column sets are decided here, not in the route),
`backend/db/schema.sql` (column types/nullability), `backend/classification/engine.py`
(`ClassificationResult.explain()`), and `backend/ingestion/imap_client.py`
(`verify_login()`).

Base URL: `http://localhost:8765`. All responses are JSON. Errors are
`{"error": "<message>"}` with a non-200 status (codes noted per endpoint).

---

## ⚠️ E10 guard — serializer divergences (read this first)

The single most important output of this exercise: **`_message_json()` is shared by four
endpoints whose underlying SQL queries select *different column sets*.** It is NOT one
fixed shape. The function (`app.py:372`) defends every non-universal column with a
`row.keys()` membership check (`col()` helper) and returns `None` for any column the
feeding query didn't select — so the *same function* emits *different JSON* depending on
the caller.

| Consumer | Query (`database.py`) | Body columns? | `preview`? | `rule_matches` in JSON? | `explanation`? |
|---|---|---|---|---|---|
| `GET /messages` | `list_with_classification` | ❌ no | ✅ yes (`substr(body_plain,1,200)`) | ❌ no¹ | ❌ no |
| `GET /messages/search` | `search` | ❌ no | ✅ yes (`substr(body_plain,1,200)`) | ❌ no¹ | ❌ no |
| `GET /threads/<id>` | `list_with_classification` (thread_id filter) | ❌ no | ✅ yes | ❌ no¹ | ❌ no |
| `GET /messages/<id>` | inline `SELECT m.*` (route, `app.py:102`) | ✅ `body_plain`, `body_html` | ❌ **no**² | ✅ yes (when present + non-empty) | ✅ yes (folded in) |

¹ `rule_matches` is only added to the JSON when `include_body=True` **and** the column is
present and truthy (`app.py:406`). List/search/thread all call with the default
`include_body=False`, so even though their query selects `rule_matches`, it is **never
serialized** on those endpoints. It only appears on the detail endpoint.

² **Divergence trap:** the detail query is `SELECT m.*` — `messages` has **no `preview`
column** (`preview` is a query-computed alias, not a table column). So `col("preview")`
returns `None` on the detail endpoint. **List/search rows carry `preview` but no body;
the detail fetch carries body but `preview: null`.** The SwiftUI model must treat both as
optional and not assume one implies the other.

Other bespoke shapes (do NOT route these through `_message_json`):
- `GET /messages/<id>/explain` — its own hand-built dict (`app.py:145`).
- `GET /rules` — `dict(row)` straight off `SELECT *` for both rules and sender_groups.
- Rules / sender-group CRUD responses — `dict(row)` off `SELECT *`.
- `GET /preferences` — a flat `{key: value}` map, not a list.
- `POST /accounts/verify` — `{ok, reason}`.

---

## Field-type legend

Types are the JSON types after SQLite→`sqlite3.Row`→`jsonify`. Nullability is sourced
from `schema.sql` (`NOT NULL` / CHECK) and from the `LEFT JOIN` semantics noted below.

> **Universal nullability caveat (applies to every `_message_json` consumer):** the
> classification columns (`urgency_tier`, `category`, `triage_state`) come via
> `LEFT JOIN classifications`. A message persisted **before** classification (P1) has no
> classification row, so **all three are `null`** even though the columns are `NOT NULL`
> *within* the `classifications` table. The UI must render an unclassified message.

---

## Message List — §4.1.1

### `GET /messages`
- **Screen:** Message List.
- **Route:** `list_messages` (`app.py:79`). **Serializer:** `_message_json(r)` (`include_body=False`).
- **Query:** `MessageRepo.list_with_classification` (`database.py:167`).
- **Request — query params (all optional):**
  | param | type | notes |
  |---|---|---|
  | `tier` | int | filter `c.urgency_tier =` |
  | `category` | string | filter `c.category =` |
  | `triage_state` | string | filter `c.triage_state =` |
  | `states` | string | **D50:** comma-separated multi-state filter (`states=new,needs_action`) → `c.triage_state IN (…)` in ONE query so tier-first ordering holds across the union. Unknown/empty names → **400 naming them** (unlike the older single filters, never a silent empty view). `unclassified` is a valid token (no classification row) |
  | `account` | string | **D56:** scope to one mailbox. A **filter, not an assertion** — an unknown account returns `[]`, never a 400, so a just-disconnected account can't 500 the list |
  | `since` | string (ISO-8601) | **Session 31:** inclusive lower bound on `received_at` |
  | `until` | string (ISO-8601) | **Session 31:** exclusive upper bound. **`until` alone is the "older than X days" case** — the one that makes triaging a backlog possible |
  | `limit` | int | default 100, **server-capped at 500** (`min(limit,500)`) |
  | `offset` | int | default 0 |
  - No request-side validation of `tier`/`category`/`triage_state` values — bad values just match nothing.
  - **`since`/`until` ARE validated → 400 on a malformed bound.** Deliberate asymmetry: the query compares with `julianday()`, which returns NULL for junk, and a NULL comparison is false — so an unvalidated typo would silently return an **empty list** rather than an error. Validating is what keeps "no results" meaning no results.
  - **E24 — the `+` trap.** `+` is the URL encoding of a space, so a correctly-formed `+00:00` offset arrives as ` 00:00` unless percent-encoded. Both the validator and the value passed to SQL run through `_normalize_iso_bound`, which restores it. Parsing lives in **one** helper, `parse_bound()`, shared with `POST /messages/triage-bulk` — a second parser is how this recurs.
  - **Ordering (D57):** recency **band** → tier → `received_at DESC`, bands `≤FRESH_DAYS` / `≤RECENT_DAYS` / older, **Tier 1 exempt at any age (band 0)**. NOT tier-first — that put zero messages from the last 14 days on page one of Open. Band edges compare with `julianday()`, never as TEXT.
- **Response headers (OI21):**

  | header | meaning |
  |---|---|
  | `X-Total-Count` | total matching **THIS filter set**, ignoring limit/offset — powers "Showing N of M". Computed by `count_matching`, which shares the list's WHERE clause so rows and total cannot disagree |
  | `X-Offset` | the offset these rows started at |

  The body stays a bare array so every existing client keeps working.
- **Response:** `200` → **JSON array** of:

  | field | type | nullable? | source |
  |---|---|---|---|
  | `id` | string | no | `messages.id` (PK, Gmail msg ID) |
  | `account` | string | no | `messages.account` |
  | `thread_id` | string | **yes** | `messages.thread_id` |
  | `sender_name` | string | **yes** | `messages.sender_name` |
  | `sender_email` | string | no | `messages.sender_email` |
  | `subject` | string | **yes** | `messages.subject` |
  | `received_at` | string (ISO-8601) | no | `messages.received_at` |
  | `ingested_at` | string (ISO-8601) | no | `messages.ingested_at` |
  | `preview` | string | **yes** | `substr(body_plain,1,200)` — null if body_plain null |
  | `urgency_tier` | int (1–5) | **yes** | `classifications` (null if unclassified — see caveat) |
  | `category` | string (`work`\|`personal`\|`unknown`) | **yes** | `classifications` |
  | `triage_state` | string (`new`\|`acknowledged`\|`needs_action`\|`done`) | **yes** | `classifications` |

  - **Not present:** `body_plain`, `body_html`, `rule_matches`, `explanation`. (Per E10 table.)

### `GET /messages/counts` (D50/D51)
- **Screen:** Message List — the chip counts and the dock badge.
- **Route:** `message_counts`. **Query:** `MessageRepo.triage_counts` (LEFT JOIN + GROUP BY, plus the urgent companion count).
- **Why it exists:** the list endpoint paginates (cap 500) and the alpha store is 1,400+ messages — counting rendered rows would lie. These totals are **store-wide**.
- **Response:** `200` → object, all fields non-null ints:

  | field | meaning |
  |---|---|
  | `new` / `acknowledged` / `needs_action` / `done` | messages per triage state |
  | `unclassified` | messages with **no classification row** (P1: counted, never vanished) |
  | `urgent_new` | **D51 badge:** triage-state-New AND tier ≤ 2 |

- Route-order note: a static `/messages/counts` outranks `/messages/<path:message_id>` in Werkzeug (same reason `/messages/search` works); pinned by test.

### `POST /messages/triage-bulk` (Session 31 + **D59**)
- **Screen:** Message List — the bulk action bar.
- **Route:** `set_triage_bulk` / `_triage_bulk_by_filter`. **Query:** `ClassificationRepo.update_triage_state_bulk` (ids) / `update_triage_state_by_filter` (D59).
- **Two modes, exactly one per request** — 400 if both, 400 if neither:

  | mode | body | when |
  |---|---|---|
  | **ids** (S31) | `{state, message_ids:[…], write_back?}` | act on exactly what the user saw; small sets |
  | **filter** (D59) | `{state, filter:{…}, write_back?}` | "everything matching this filter" — the only way to clear a backlog larger than one page |

- **`filter` keys** — same vocabulary as `GET /messages`: `tier`, `category`, `state`, `states`, `account`, `since`, `until`. **An unknown key is a 400**, not ignored: a silently-dropped `tierr=4` *widens* the update set.
- **`filter.until` is REQUIRED → 400 without it, and is never defaulted server-side.** This is the race guard. A poll can land between the user reading "this will mark 1,594 messages Done" and the execute; with no upper bound, mail that arrived in that window is marked Done **having never been seen** — not a P1 violation (nothing is deleted) but a close cousin, and silent. The client captures `until = now` at preview and replays **that same value**. A server-side `now` would be evaluated at execute time and defeat the whole mechanism.
- **One statement, not a loop and not resolve-then-update-by-id:** the matching set is computed inside the same `UPDATE … WHERE message_id IN (SELECT …)` that writes it, so no window exists in which it could shift, and atomicity is free. D44's lesson (intermediate states are observable by the reload-per-poll classifier, E11/D37) applies with far more force here.
- **Response:** `200` →

  | field | mode | meaning |
  |---|---|---|
  | `updated` | both | rows actually affected |
  | `triage_state` | both | the state applied |
  | `matching` | filter | how many the filter matched |
  | `already_in_state` | filter | of those, how many already held the target state. **Needed because SQLite counts a no-op UPDATE as a changed row** — `updated` alone cannot tell "1,594 moved" from "1,594 matched, 900 already Done" |
  | `wrote_back` | both | mailbox messages marked `\Seen` |
  | `write_back_skipped` | both | true when write-back was not requested (the default) |

  Id mode returns `409` naming the missing ids if any id has no classification, changing nothing.
- **Capped at 5,000 (D60), both modes → `400`** with `{error, matching, limit}`, naming the count and the limit. Not a performance bound — one UPDATE handles far more. It bounds the cost of a filter that matched more than intended, for when the count-naming confirmation is clicked through. The count comes from `count_matching_for_triage`, which resolves the **same set** through the shared predicate the UPDATE uses, so the cap guards the set it counts rather than a near-miss.
- **Every executed bulk writes one `bulk_operation_log` row (D60)**, inside this endpoint's transaction. See `GET /bulk-operations`.
- **Write-back is OFF by default and stays that way (P5).** A realistic bulk Done covers thousands of messages at ~3 IMAP round-trips each — a long-running mailbox rewrite hiding inside a list action. Opt in per request with `write_back: true`; the response always reports what happened.
- **Triage state ONLY** — never reclassifies, never notifies (D52's silence invariant applies to bulk as much as to single).

### `GET /bulk-operations` (D60 — executed-bulk audit log)
- **Screen:** none yet. Command-line answer to "what did that operation do?"; no UI in this work order.
- **Route:** `list_bulk_operations`. **Query:** `ClassificationRepo.recent_bulk_operations`.
- **Request:** `?limit=` (default 50, clamped to 1–500).
- **Response:** `200` → array, newest first:

  | field | type | notes |
  |---|---|---|
  | `id` | int | autoincrement; ordering key |
  | `executed_at` | string (ISO-8601 UTC) | |
  | `triage_state` | string | the state applied |
  | `filter` | object \| **null** | the filter **parsed back to an object** — the caller wants the filter, not a string containing one. **null in id mode** (there was no filter; a synthesised one would misrepresent the operation) |
  | `until` | string \| null | the frozen bound (filter mode) |
  | `account` | string \| null | set only if the filter was account-scoped |
  | `matched` / `updated` / `already_in_state` | int | resolved set, rows affected, rows that already held the state |

- **Append-only, and a LOG rather than STATE.** Nothing updates or deletes rows, and **no code path may read this table to make a decision** — pinned by a test that greps the source. The row is written *inside* the bulk update's transaction, so a recorded operation and an applied one cannot diverge.
- **Retention: none, deliberately.** Rows are bounded by how often a human runs a bulk action. That holds only while the log records *operations*; per-message prior state (for undo) would make growth unbounded and retention mandatory.

### `POST /messages/<id>/reclassify` and `POST /messages/reclassify-all` (D52)
- **Screens:** Message Detail's explain panel (per-message) and Settings → Classification Rules (bulk).
- **Why:** rule edits are not retroactive (E11/D37), so stored classifications fossilize. These are the explicit way to close that gap; **classify-once-at-ingest stays the default lifecycle** (invariant 4) and neither endpoint runs automatically.
- **`POST /messages/<id>/reclassify`** → `200` with the fresh classification, so the caller patches in place (E20 seam, no refetch):

  | field | notes |
  |---|---|
  | `message_id`, `urgency_tier`, `category` | the new classification |
  | `triage_state` | **PRESERVED** (invariant 1) — the server echoes it back so the client asserts rather than assumes |
  | `classified_at`, `reclassified_at` | the dated audit (invariant 3: overwrite, never version) |
  | `changed`, `previous_tier`, `previous_category` | so "no change" reads as a real outcome, not a failure |

  `404` for an unknown message id. An **unclassified** message is a VALID target (P1 stores before classifying; the D50 amendment surfaces those in Open) — that is the case this fixes.
- **`POST /messages/reclassify-all`** → `200` `{counted, changed, unchanged, errors, failed_ids}`. Synchronous **by measurement**: 1,592 real messages in ~0.4s. A per-message failure is counted and the run continues (P1).
- **Neither endpoint notifies** (invariant 2) — no banners, no digest rows, for one message or 1,592.

### `GET /version` (build provenance)
- **Screen:** Settings (passive footer), plus `scripts/backend.sh status`.
- **Why it exists:** Session 27 opened with BOTH runtime artifacts stale, detectable only by inference ("do I see chips?"). A gate pass against the wrong binary is a false PASS recorded with full confidence.
- **Response:** `200`, always (an endpoint whose job is answering "what are you?" must never fail to answer):

  | field | notes |
  |---|---|
  | `git_sha` | `<short-sha>`, `<short-sha>-dirty`, or `unknown`. **Dirty when the tree has uncommitted changes OR when cleanliness can't be verified** — over-claiming clean is the misleading failure. |
  | `started_at` | ISO-8601 UTC process start time |

### `GET /messages/search?q=<term>`
- **Screen:** Message List (search; P1 reachability).
- **Route:** `search_messages` (`app.py:92`). **Serializer:** `_message_json(r)` (`include_body=False`).
- **Query:** `MessageRepo.search` (`database.py:217`) — `LIKE %q%` over `sender_email`, `sender_name`, `subject`, `body_plain`.
- **Request:** `q` (string, required, trimmed). Missing/empty → `400 {"error":"missing query parameter 'q'"}`.
- **Response:** `200` → **JSON array**, **identical field set to `GET /messages`** (same serializer, parallel query — deliberately kept in lockstep per the E10 note in code).
  - **Ordering differs:** `m.received_at DESC` only (no tier grouping).
  - **Limit:** hard-coded 200 (not client-controllable).

---

## Message Detail — §4.1.2

### `GET /messages/<id>`
- **Screen:** Message Detail.
- **Route:** `get_message` (`app.py:100`). **Serializer:** `_message_json(row, include_body=True)` **+ folded-in `explanation`**.
- **Query:** inline in the route — `SELECT m.*, c.urgency_tier, c.category, c.triage_state, c.classified_at, c.rule_matches FROM messages m LEFT JOIN classifications c …`.
- **Request:** path `id` (string; `<path:message_id>` so slashes allowed).
- **Response:** `200` → **single JSON object** (not an array):

  | field | type | nullable? | notes |
  |---|---|---|---|
  | `id` | string | no | |
  | `account` | string | no | |
  | `thread_id` | string | **yes** | |
  | `sender_name` | string | **yes** | |
  | `sender_email` | string | no | |
  | `subject` | string | **yes** | |
  | `received_at` | string (ISO-8601) | no | |
  | `ingested_at` | string (ISO-8601) | no | |
  | `preview` | **always `null`** | yes | ⚠️ `messages` has no `preview` column; `SELECT m.*` doesn't compute it. See E10 §² above. |
  | `urgency_tier` | int (1–5) | **yes** | null if unclassified |
  | `category` | string | **yes** | null if unclassified |
  | `triage_state` | string | **yes** | null if unclassified |
  | `body_plain` | string | **yes** | only here (and per `include_body`) |
  | `body_html` | string | **yes** | only here |
  | `rule_matches` | array of objects | **conditional** | present **only when** the classification row exists *and* `rule_matches` is non-empty (`app.py:406`); each element carries **five always-present keys** — `{rule_id, rule_name, field, operator, value}` — plus **conditional** ones the engine adds only when they apply: `applied_tier`, `applied_category`, `skipped_tier`, `overrode_tier`. See the element-shape note below. **Key absent** otherwise — not `null`. |
  | `explanation` | string | **yes** | `ClassificationResult.explain()` — a multi-line human string (P3). **`null`** when unclassified (`app.py:129`). |
  | `rfc822_message_id` | string | **yes** | **D48:** the RFC822 Message-ID, read from the `raw_headers` JSON blob. **Detail only** (E10 — the list/search shape never grows this key, pinned by test). `null` when the header is absent → the client's Gmail controls stay disabled. |

  - `404 {"error":"message not found"}` if id unknown.
  - **Note on `rule_matches`:** the *key may be absent entirely* (vs. `null`) — Swift decoding must treat it as optional-missing, and the elements are the audit-trail dicts, not strings.

  - **Element shape (OI7 — corrected 2026-09-02 against `classification/engine.py`
    and a live response).** The map previously listed four fields and omitted
    `operator`; checking the running API found the real shape is wider still.
    Elements come in **two variants**:

    | key | always? | notes |
    |---|---|---|
    | `rule_id` | ✅ | `null` on the sender-override variant — it is an invariant, not a stored rule |
    | `rule_name` | ✅ | on the override variant, a sentence: `Sender override invariant — group 'x'` |
    | `field` | ✅ | |
    | `operator` | ✅ | **was missing from this map**; the engine has always emitted it (`engine.py:159`) |
    | `value` | ✅ | |
    | `applied_tier` | conditional | only when this rule actually *lowered* the tier |
    | `skipped_tier` | conditional | a **string**, not an int: `"3 (less urgent than current 2)"` — present when a rule matched but did NOT win |
    | `applied_category` | conditional | only when the rule set a category |
    | `overrode_tier` | conditional | sender-override variant only; the tier before the floor was applied (may be `null`) |

    A decoder must treat every conditional key as optional, and must not assume
    `rule_id` is non-null. `skipped_tier` being a string while `applied_tier` is
    an int is the trap worth naming: they are not two spellings of one field.
    Verified against a live detail response, whose element keys were
    `['applied_category', 'applied_tier', 'field', 'operator', 'rule_id', 'rule_name', 'value']`.

### `GET /messages/<id>/explain`
- **Screen:** Message Detail (P3 — but redundant for detail, which already folds `explanation` in; useful as a standalone/refresh call).
- **Route:** `explain_message` (`app.py:132`). **Serializer:** bespoke inline dict (NOT `_message_json`).
- **Query:** `ClassificationRepo.get` (`database.py:279`) — `SELECT * FROM classifications WHERE message_id = ?`.
- **Request:** path `id`.
- **Response:** `200` → single object:

  | field | type | nullable? | source |
  |---|---|---|---|
  | `message_id` | string | no | echoed from path |
  | `urgency_tier` | int (1–5) | no | `classifications.urgency_tier` (NOT NULL in table) |
  | `category` | string (`work`\|`personal`\|`unknown`) | no | `classifications.category` |
  | `rule_matches` | array of objects | no (may be `[]`) | parsed JSON; same element shape as the detail endpoint — five always-present keys `{rule_id, rule_name, field, operator, value}` plus the conditional ones. See the element-shape note under `GET /messages/<id>`. |
  | `explanation` | string | no | `explain()` multi-line text |

  - `404 {"error":"classification not found"}` if the message has no classification row (e.g. persisted-but-not-yet-classified, P1). **Contrast:** the detail endpoint returns `200` with `explanation: null` for the same case — this one 404s. The UI should prefer the detail payload's folded `explanation` and not depend on this endpoint for unclassified mail.

### `GET /threads/<id>`
- **Screen:** Message Detail ("view full conversation").
- **Route:** `get_thread` (`app.py:296`). **Serializer:** `_message_json(r)` (`include_body=False`).
- **Query:** `MessageRepo.list_with_classification(thread_id=…, limit=500)`.
- **Request:** path `thread_id` (`<path:thread_id>`).
- **Response:** `200` → **JSON array**, **same field set as `GET /messages`** (list shape — **no bodies**, carries `preview`, no `rule_matches`, no `explanation`).
  - **Ordering:** `m.received_at ASC` (oldest→newest, reads top-to-bottom).
  - Unknown/empty thread → `200 []` (empty array, not 404).
  - ⚠️ **Consequence for the UI:** the conversation view gets `preview` per message but **no full body** from this endpoint. Rendering a full message in the thread requires a per-message `GET /messages/<id>` fetch. Flag for screen design.

---

## Settings — §4.1.3

### `GET /preferences`
- **Screen:** Settings (notification prefs, modes, digest time, ceiling — P4).
- **Route:** `get_preferences` (`app.py:169`). **Query:** `PreferencesRepo.all` (`database.py:308`).
- **Response:** `200` → **flat JSON object `{key: value}`** — **NOT** a list, **NOT** wrapped. Both keys and values are **strings** (`value` is `TEXT NOT NULL`; everything is stringly-typed). `updated_at` is **not** returned.
  - Seeded keys (from `seed.example.sql`) the UI can expect: `operating_mode` (`focus`/`catch-up`), `daily_ceiling` (int-as-string), `digest_time`, `poll_interval_minutes` (int-as-string — D34 background timer reads this), `writeback_enabled` (`"true"`/`"false"`).
  - ⚠️ Values are strings even when semantically int/bool — the Swift layer must coerce.
  - **`fresh_days` (D59/§B4) is DERIVED, not stored.** It serves D57's `FRESH_DAYS` constant so the list's "Older than 2 weeks" preset and the recency band are the same number rather than two literals that can drift. Read-only in practice: a `PUT /preferences/fresh_days` writes an ordinary row that this key then shadows. When OI29 promotes the band edges to real preferences, this becomes the stored key and the constant reads from it — no client change.

### `PUT /preferences/<key>`
- **Route:** `set_preference` (`app.py:173`).
- **Request body:** `{"value": <any>}` — required; coerced to string server-side (`str(body["value"])`). Missing `value` → `400 {"error":"body must include 'value'"}`.
- **Response:** `200` → `{"key": <string>, "value": <string>}`. (Upsert: creates the key if absent.)

### `GET /preferences/notifications` — typed notification prefs (Wave 1, gap #5 closed)
- **Screen:** Settings §4.1.3 "Notification Preferences."
- **Route:** `get_notification_preferences` (`app.py`). A **typed view** over specific keys in the same `preferences` table — the generic `GET /preferences` map still exists and still shows these keys as raw strings.
- **Response:** `200` → object with **coerced types** (not raw strings):

  | field | type | nullable? | notes |
  |---|---|---|---|
  | `quiet_hours_start` | string `"HH:MM"` | **yes** | `null` when unset; zero-padded 24-hour |
  | `quiet_hours_end` | string `"HH:MM"` | **yes** | `null` when unset |
  | `audio_alerts` | **bool** | no | defaults `false` when unset (a real JSON bool, not `"true"`) |

  - Underlying storage keys in `preferences`: `quiet_hours_start`, `quiet_hours_end` (stored `"HH:MM"` or `""`), `audio_alerts` (stored `"true"`/`"false"`). The UI should bind to this typed endpoint, not the raw keys.

### `PUT /preferences/notifications` — validated write (Wave 1, gap #5 closed)
- **Route:** `set_notification_preferences` (`app.py`). **Patch semantics** — only provided keys are written.
- **Request body** (any subset):
  | field | type | constraint |
  |---|---|---|
  | `quiet_hours_start` | string | `"HH:MM"` 00:00–23:59 (normalized/zero-padded); `""` **unsets** (→ `null`) |
  | `quiet_hours_end` | string | same |
  | `audio_alerts` | **bool** | must be a real JSON boolean — `"true"`/`1` are **rejected** |
- **Response:** `200` → the **same typed shape** as `GET /preferences/notifications` (full merged state).
  - `400` on: malformed time, non-bool `audio_alerts`, or any **unknown key** (typos don't silently no-op).
  - Writes land in the `preferences` table, so the generic `GET /preferences` reflects them as strings (one source of truth, P4).

### `GET /rules`
- **Screen:** Settings (Classification Rules + sender groups, P4).
- **Route:** `get_rules` (`app.py`). **Serializer:** `dict(row)` off `SELECT *` for both lists.
- **Request — query param (Wave 1, gap #4 closed):** `?include_disabled=true` (also `1`/`yes`, case-insensitive). **Default = false** → enabled rules only (the engine-visible set). The Settings rules editor MUST pass `include_disabled=true` so a toggled-off rule stays visible and re-enableable.
- **Response:** `200` → object with **two arrays**:

  ```json
  { "rules": [ … ], "sender_groups": [ … ] }
  ```

  - `rules` ← `RulesRepo.all_enabled` (default) **or** `RulesRepo.all_rules` (when `include_disabled=true`). Default is **`WHERE enabled = 1` only**; with the flag, **all rules incl. disabled**. Ordered `priority ASC`. Each element (full `rules` row):

    | field | type | nullable? | notes |
    |---|---|---|---|
    | `id` | int | no | PK |
    | `rule_name` | string | no | |
    | `priority` | int | no | ordinal rank, lower = evaluated first. **Dense (1..N) after any reorder (D44)**; new rules append at `MAX+1`. Create-default was 100 pre-D44. |
    | `enabled` | int (0/1) | no | **int, not bool**; `0` for disabled rows (only seen with `include_disabled=true`) |
    | `field` | string | no | `sender_email`\|`sender_domain`\|`subject`\|`body`\|`sender_group` |
    | `operator` | string | no | `equals`\|`contains`\|`starts_with`\|`ends_with`\|`matches_group` |
    | `value` | string | no | |
    | `set_tier` | int (1–5) | **yes** | at least one of set_tier/set_category non-null (CHECK) |
    | `set_category` | string (`work`\|`personal`) | **yes** | |
    | `notes` | string | **yes** | |

  - `sender_groups` ← `RulesRepo.all_sender_groups` — **all groups** (no enabled filter). Ordered `urgency_floor ASC`. Each element (full `sender_groups` row):

    | field | type | nullable? | notes |
    |---|---|---|---|
    | `id` | int | no | PK |
    | `group_name` | string | no | |
    | `email_pattern` | string | no | exact email or glob (`*@example.com`) |
    | `urgency_floor` | int (1–5) | no | sender-override floor |
    | `notes` | string | **yes** | |

  - ⚠️ **`enabled` is 0/1 int, not JSON bool.** And `GET /rules` hides disabled rules — a Settings screen that wants to show *and toggle* disabled rules has **no read endpoint** that returns them (see Gaps).

### `POST /rules`
- **Route:** `create_rule` (`app.py:226`). Validation: `_validate_rule(require_all=True)`.
- **Request body:**
  | field | required? | type | constraint |
  |---|---|---|---|
  | `rule_name` | **yes** | string | |
  | `field` | **yes** | string | ∈ `{sender_email, sender_domain, subject, body, sender_group}` |
  | `operator` | **yes** | string | ∈ `{equals, contains, starts_with, ends_with, matches_group}` |
  | `value` | **yes** | string | |
  | `set_tier` | conditional | int | ∈ 1–5; **at least one of set_tier/set_category must be present & non-null** |
  | `set_category` | conditional | string | ∈ `{work, personal}` |
  | `priority` | no | int | **appends: defaults to `MAX(priority)+1`** (D44 — dense numbering; was fixed 100). Explicit value still honored. |
  | `enabled` | no | bool | defaults true → stored as 1 |
  | `notes` | no | string | |
- **Response:** `201` → the created rule as `dict(row)` (same full-row shape as `GET /rules` elements, incl. new `id`). Invalid → `400 {"error": …}`.

### `PUT /rules/<int:rule_id>`
- **Route:** `update_rule` (`app.py:235`). Validation: `_validate_rule(require_all=False)` + **post-merge both-null guard**.
- **Request body:** any subset of the create fields (patch semantics — only provided columns updated).
- **Guard:** the **merged** result (patch over existing row) must still have ≥1 of `set_tier`/`set_category` non-null, else `400` (a no-effect rule pollutes `/explain`, P3). Omitting both leaves existing effects intact and passes.
- **Response:** `200` → updated rule `dict(row)`. `404 {"error":"rule not found"}` if unknown. `400` on validation/guard failure.
- ⚠️ `<int:rule_id>` — non-integer path segment → Flask **404** (route doesn't match), not a 400.

### `PUT /rules/reorder` (D44 — batch reorder, Amendment 1)
- **Route:** `reorder_rules` (`app.py`). Powers Settings §4.2 Phase 2 rule drag-to-reorder.
- **Request body:** `{"ordered_ids": [7, 14, 3, …]}` — **position is priority**. The client
  sends the *complete* new order; it never computes a priority number, so the wire format
  cannot express a gap or a tie.
- **Invariant:** `ordered_ids` must be an **exact permutation of ALL rule ids** — enabled
  **and disabled** (disabled rules hold their place; the editor fetches with
  `include_disabled=true`). The permutation is checked **inside the transaction against the
  live table** (E12 state invariant), so it spans what the client fetched *then* and what the
  DB holds *now*.
- **Behavior:** assigns `priority = index + 1` to every rule — **dense 1..N, in one
  transaction** (all-or-nothing; the reload-per-poll classifier D37/E11 never sees a
  half-applied order).
- **Responses:**
  - `200` → `{"rules": [ … ]}` — the full reordered set, **same element shape as
    `GET /rules?include_disabled=true`**, so the client re-renders from the response without
    a second fetch.
  - `400` → malformed: missing/duplicate/non-integer `ordered_ids`. Duplicate body names the
    ids: `{"error": …, "duplicate": [<id>]}`.
  - `409` → **stale set**: shape valid but membership drifted from the live table (a rule was
    created or deleted since the client fetched). Body names the mismatch:
    `{"error": …, "unexpected": [<sent-but-gone>], "missing": [<live-but-omitted>]}`
    (P3-adjacent: errors are legible too). Client remedy: refetch and re-present.
- ⚠️ **Route isolation:** `PUT /rules/reorder` must not be captured by
  `PUT /rules/<int:rule_id>`. The `<int:…>` converter won't match `"reorder"`, so it's safe
  regardless of declaration order — an explicit test asserts reorder never reaches `update_rule`.

### `DELETE /rules/<int:rule_id>`
- **Route:** `delete_rule` (`app.py:260`). Hard-delete (config management is allowed; P1's never-delete applies to *messages*, not rules).
- **Response:** `200` → `{"deleted": <rule_id:int>}`. `404 {"error":"rule not found"}` if unknown.

### `POST /sender-groups`
- **Route:** `create_sender_group` (`app.py:268`). Validation: `_validate_sender_group(require_all=True)`.
- **Request body:**
  | field | required? | type | constraint |
  |---|---|---|---|
  | `group_name` | **yes** | string | |
  | `email_pattern` | **yes** | string | must be non-empty after strip |
  | `urgency_floor` | **yes** | int | ∈ 1–5 |
  | `notes` | no | string | |
- **Response:** `201` → created group `dict(row)` (same shape as `GET /rules` `sender_groups` elements). `400` on validation failure.

### `PUT /sender-groups/<int:group_id>`
- **Route:** `update_sender_group` (`app.py:277`). Validation: `_validate_sender_group(require_all=False)`. Patch semantics.
- **Response:** `200` → updated group `dict(row)`. `404 {"error":"sender group not found"}`. `400` on validation failure.

### `DELETE /sender-groups/<int:group_id>`
- **Route:** `delete_sender_group` (`app.py:288`).
- **Response:** `200` → `{"deleted": <group_id:int>}`. `404` if unknown.

> **Settings note — triage update is also a Settings/Detail action.** `POST /messages/<id>/triage` lives logically with Detail but is the only triage write:
> - **Route:** `set_triage` (`app.py:153`). **Body:** `{"state": <one of new|acknowledged|needs_action|done>}`. Invalid/missing → `400`. Unknown message → `404 {"error":"classification not found"}` (keys off the *classification* row, so unclassified messages can't be triaged).
> - **Response:** `200` → `{"message_id": <string>, "triage_state": <string>}`.

---

## Onboarding — §4.1.4

### `POST /accounts/verify`
- **Screen:** Onboarding (connectivity check; read-only, P5 — login then immediate logout, no poll, no mailbox writes).
- **Route:** `verify_account` (`app.py:306`). Backed by `GmailImapClient(account).verify_login()` (`imap_client.py:200`).
- **Request body:** `{"account": <string>}` — required, trimmed. Missing/empty → `400 {"error":"body must include 'account'"}`.
- **Response:** `200` → `{"ok": <bool>, "reason": <string>}`:

  | `ok` | `reason` | meaning |
  |---|---|---|
  | `true` | `"ok"` | login succeeded |
  | `false` | `"missing_credential"` | no App Password in Keychain for this account |
  | `false` | `"auth_failed"` | credential rejected by server |
  | `false` | `"network_error"` | could not reach server (DNS/refused/timeout) |

  - `reason` is a **stable enum** of exactly those four strings — safe to switch on in the UI.

### `POST /accounts` — store App Password (Wave 1, gap #2 closed)
- **Screen:** Onboarding §4.1.4 "connect a Gmail account by supplying an App Password."
- **Route:** `store_account` (`app.py`). Backed by `ingestion.keychain.store_secret`.
- **D40 — store and verify are SEPARATE calls.** `/accounts/verify` stays read-only (IMAP-login class); this endpoint's only side effect is the **Keychain write** (P5) — no IMAP connection, no mailbox access, no DB write. The UI is expected to call `/accounts/verify` first and POST here on success, but verification is **not** coupled in. **D41 — the Keychain is the account registry** (no accounts table).
- **Request body:**
  | field | required? | type | notes |
  |---|---|---|---|
  | `account` | **yes** | string | email; trimmed; empty → 400 |
  | `app_password` | **yes** | string | the secret; empty → 400; **never logged or echoed** |
  | `retrieval_window` | no | string | **D61.** One of `1w` · `1m` · `3m` · `everything`; anything else → **400 naming the valid set**. Absent ⇒ no cutoff ⇒ retrieve everything (the pre-feature behaviour, so an existing account never starts skipping mail). **"2 days" is deliberately not offered** — widening is unsupported, so the narrowest option is the one most likely to be permanently regretted |
- **Response:** `201` → `{"account": <string>, "stored": true, "retrieval_cutoff": <ISO-8601|null>}`. **The password is never returned.**
  - **D61:** the window is resolved to an **absolute cutoff here, at connect time**, and stored as pref `retrieval_cutoff:<account>` — never stored as "N days", which would be re-evaluated each poll and let the boundary slide forward. Written only **after** the credential lands, so a failed connect cannot silently narrow a later successful one.
  - The cutoff bounds the **initial backfill only**. Once anything is stored for the account, it is never consulted again — see `docs/BEHAVIOR.md`, "The retrieval window applies to setup only".
  - `400 {"error":"body must include 'account'"}` / `…non-empty 'app_password'`.
  - `502 {"error": <keychain msg>}` if the Keychain write fails (the error string never contains the secret).
  - Idempotent on re-POST for the same account (uses `security … -U`, updates in place).

### `GET /accounts` — list connected accounts (Wave 1, gap #3 closed)
- **Screen:** Settings §4.1.3 "Email Accounts."
- **Route:** `list_accounts_route` (`app.py`). Backed by `ingestion.keychain.list_accounts` (parses `security dump-keychain`, filtered to service `thresher`).
- **Request:** none.
- **Response:** `200` → `{"accounts": [<email>, …]}` — a **sorted array of unique account strings**; may be `[]`. **No secret values are returned.** An account is "connected" iff it has a stored App Password (D41).
  - `503 {"error": <msg>}` if the `security` tool is unavailable (e.g. non-macOS host).

### `DELETE /accounts/<account>` — disconnect (Wave 1, gap #3 closed)
- **Screen:** Settings §4.1.3 "disconnect Gmail accounts."
- **Route:** `disconnect_account` (`app.py`). Backed by `ingestion.keychain.delete_secret`.
- **Side-effect scope:** Keychain only (P5) — removes the credential. **Does NOT touch the message store** (P1: stored messages stay retrievable, incl. via search).
- **Request:** path `account` (`<path:account>` — `@`/dots fine).
- **Response:** `200` → `{"disconnected": <string>}`. `404 {"error":"account not found"}` if no credential existed. `502` on a Keychain failure other than not-found. `400` if the path segment trims to empty.

---

## Gaps — fields/actions a screen needs (§4.1) that NO current endpoint provides

**Flag-only.** Originally surfaced in Phase 0. **Gaps #2–#5 are now CLOSED by Wave 1
(Work Order A)** — see their endpoint entries above; kept here with strike-through for the
audit trail. Gaps #1, #6, #7 remain open / are by-design.

1. ~~**Open in Gmail identifier (OI4).**~~ ✅ **CLOSED (Session 25, D48 — polish Part E).**
   No schema column was needed after all: `GET /messages/<id>` now folds
   `rfc822_message_id` in from the `raw_headers` blob (detail only — the list/search
   shape does NOT grow the key, pinned by test; **null** when the header is absent, and
   the client keeps its control disabled rather than fabricate a link). The client
   builds `https://mail.google.com/mail/u/0/#search/rfc822msgid:<encoded>`.

2. ~~**Supplying / storing the App Password during onboarding.**~~ ✅ **CLOSED (Wave 1).**
   `POST /accounts` writes the App Password to the Keychain (Keychain-only side effect, P5;
   D40 keeps it split from read-only `/accounts/verify`). See the endpoint entry.

3. ~~**Account list / disconnect.**~~ ✅ **CLOSED (Wave 1).** `GET /accounts` lists connected
   accounts (Keychain-backed, D41) and `DELETE /accounts/<account>` disconnects (removes the
   Keychain entry; touches no mailbox/message store). See the endpoint entries.

4. ~~**Reading disabled rules.**~~ ✅ **CLOSED (Wave 1).** `GET /rules?include_disabled=true`
   returns all rules incl. disabled, with `enabled` as the 0/1 int. See the `GET /rules` entry.

5. ~~**Quiet hours / audio-alert preferences as typed fields.**~~ ✅ **CLOSED (Wave 1).**
   `GET`/`PUT /preferences/notifications` give a validated, type-coerced surface
   (bounds-checked `HH:MM` quiet hours, boolean `audio_alerts`) over the same `preferences`
   table. See the endpoint entries. (Note: "notification *modes*" remain generic string
   prefs — only quiet-hours + audio were in scope for the typed surface.)

6. **Attachments.** §4.1.2 / §2 explicitly exclude attachments from retrieval; Detail has
   no attachment data. **Expected, not a defect** — noted so it isn't mistaken for a gap to fill.

7. **`preview` on the Detail endpoint.** Not a missing-feature gap but a shape trap worth
   repeating: Detail returns `preview: null` (no table column). If a screen reuses a list
   row-model for the detail header, `preview` will be empty there — use `body_plain` instead.

---

## One-line summary for the Swift model layer

- **Two message shapes, one serializer.** List/search/thread = *summary* (has `preview`,
  no body, no `rule_matches`/`explanation`). Detail = *full* (has `body_plain`/`body_html`,
  `explanation`, conditional `rule_matches`, but `preview: null`). Model both as optionals;
  don't assume one implies the other.
- **All classification fields are nullable** (LEFT JOIN; unclassified mail is real).
- **Generic preferences are stringly-typed** `{key:value}`; coerce. **But notification
  prefs have a typed surface** (`/preferences/notifications`) — bind to that, not raw keys.
- **`enabled` is 0/1 int**, not bool; `GET /rules` hides disabled rules **unless
  `?include_disabled=true`** (the Settings editor must pass it).
- **`accounts/verify` `reason` is a 4-value enum**; safe to switch on. **Store is a separate
  call** (`POST /accounts`); `GET /accounts` lists, `DELETE /accounts/<acct>` disconnects.
  No secret values are ever returned by any account endpoint.
- **Wave 1 closed gaps #2–#5** (store App Password, account list/disconnect, read disabled
  rules, typed notification prefs). **Open: #1 open-in-Gmail (OI4)** — needs a schema column;
  out of scope here. #6 attachments and #7 detail-`preview` are by-design notes.