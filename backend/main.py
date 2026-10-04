"""
thresher backend entrypoint
Runs the IMAP ingestion → classification → SQLite pipeline as a long-lived
process until interrupted (Ctrl-C / SIGTERM).

⚠️  DO NOT RUN THIS BY HAND AND WALK AWAY (OI32).
    Started from a terminal, this process lives only as long as that terminal
    and NOTHING RESTARTS IT. On 2026-08-13 it crashed on a transient IMAP
    timeout and no mail was fetched for 13 days; 141 messages were waiting on
    the server. D64 fixed that particular crash, but any crash is permanent
    without a supervisor — so the supervisor is the real fix, not the retry.

    For anything other than watching it in a terminal, use:

        scripts/launchagent.sh install

    which hands this process and the API to launchd with KeepAlive (starts at
    login, back within ~40s of a crash). `scripts/launchagent.sh status` shows
    both agents plus live per-account ingestion health.

Usage:
    cd backend
    python3 main.py                         # poll EVERY connected account
    python3 main.py --account you@example.com  # restrict the run to one mailbox
    python3 main.py --poll-interval 60      # override the DB poll interval (seconds)
    python3 main.py --once                  # run a single poll, process it, then exit
    python3 main.py -v                      # debug logging

Auth (CLAUDE.md / D26): the Gmail App Password is read at runtime from the macOS
Keychain. Store it once before first run:
    security add-generic-password -s "thresher" -a "<account>" -w "<app-password>"

The DB is initialized (and seeded on first run) before the pipeline starts, so a
fresh install comes up with the default sender groups and rules from seed.sql.
"""

import argparse
import logging
import signal
import sys
import threading
import time

from db.database import init_db, get_connection, default_db_path
from ingestion.keychain import KeychainError
from ingestion.pipeline import IngestionPipeline
from notifications.service import NotificationService
from notifications.scheduler import DigestScheduler

# Exit codes. 0 success · 1 error · 2 auth/config failure (permanent) ·
# 3 NOT CONFIGURED YET — see the `if not accounts` guard in main() for why this
# is distinct from 0. Mirrored in BackendSupervisor.swift; the two must agree.
EXIT_NOT_CONFIGURED = 3

log = logging.getLogger("thresher")

# No DEFAULT_ACCOUNT any more: the Keychain registry decides which mailboxes are
# connected (D41), so hardcoding one here would silently restrict every run to it —
# which is exactly how multi-account support would become dead code.


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="thresher",
        description="Run the thresher IMAP ingestion + classification pipeline.",
    )
    parser.add_argument(
        "--account", default=None,
        help="Restrict the run to ONE mailbox. Default: poll every connected "
             "account (every App Password stored in the Keychain).",
    )
    parser.add_argument(
        "--poll-interval", type=float, default=None, metavar="SECONDS",
        help="Override the DB-configured poll interval (preferences.poll_interval_minutes).",
    )
    parser.add_argument(
        "--once", action="store_true",
        help="Run a single poll, process the queue, then exit (useful for testing/cron).",
    )
    parser.add_argument(
        "--no-notify", action="store_true",
        help="Disable macOS notifications (ingest + classify only).",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable debug logging.",
    )
    return parser.parse_args(argv)


def configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )


def resolve_accounts(only: "str | None" = None) -> list:
    """Which mailboxes to poll.

    The Keychain is the account registry (D41) — an account is "connected" iff it
    has a stored App Password — so this asks the same source `GET /accounts` does,
    and the two can never disagree.

    `only` restricts the run to one mailbox. It is honored even if that account has
    no stored password, so the resulting failure is the honest one ("no credential
    for X") rather than a confusing empty run.
    """
    if only:
        return [only]
    try:
        from ingestion.keychain import list_accounts
        return list(list_accounts())
    except Exception:                       # noqa: BLE001 — degrade, don't crash
        log.exception("Could not read the Keychain account registry")
        return []


def run_once(pipelines: list) -> int:
    """
    Single-shot mode: poll every account once, drain each queue, exit.

    Accounts are polled SEQUENTIALLY rather than concurrently: a single poll is
    usually a human debugging one mailbox, and interleaved per-account logs make
    that harder, not easier. The long-lived path (run_forever) does run them
    concurrently, where throughput actually matters.

    P1: one account failing must not stop the others. Each failure is logged and
    counted; the exit code is non-zero if ANY account failed, so a scripted caller
    still notices, but every healthy mailbox is still polled.
    """
    failures = []
    for pipeline in pipelines:
        log.info("Running a single poll for %s", pipeline.account)
        # Start only the consumer; we drive the single poll ourselves rather than
        # running the interval-based producer (which would race this manual poll).
        # queue.join() then waits for every enqueued item to be marked task_done.
        pipeline.start_consumer_only()
        try:
            enqueued = pipeline.poll_once(get_connection(default_db_path()))
        except Exception as exc:                # noqa: BLE001 — per-account isolation
            pipeline.stop(drain=False)
            log.exception("Poll FAILED for %s; continuing with other accounts",
                          pipeline.account)
            failures.append((pipeline.account, exc))
            continue
        log.info("Enqueued %d message(s) for %s; waiting for processing to finish",
                 enqueued, pipeline.account)
        pipeline.queue.join()
        pipeline.stop()
        log.info("Single poll complete for %s (stats=%s)",
                 pipeline.account, pipeline.stats)

    if failures:
        log.error("Single poll finished with %d failed account(s): %s",
                  len(failures), ", ".join(a for a, _ in failures))
        return 1
    return 0


# How often the Keychain registry is re-read (seconds). NOT every loop tick:
# `list_accounts()` shells out to `security dump-keychain`, measured at ~100ms,
# so reconciling on the 1s supervision tick would burn ~10% of a core
# continuously in a process that runs from login onward. 30s keeps "connect an
# account and it just starts polling" comfortably within the shortest settable
# poll interval (1 minute) while costing ~0.3%.
ACCOUNT_REFRESH_SECONDS = 30.0


def _supervise_accounts(pipelines: list, retired: list, pipeline_factory,
                        only_account: "str | None") -> None:
    """
    Reconcile the running pipelines against the Keychain registry (OI25).

    Called on each supervision tick. Starts a pipeline for any account that has
    appeared, stops one whose credential has vanished, and leaves everything else
    strictly alone — an unchanged account must not be restarted, since that would
    re-seed its cursor and re-poll.

    Deliberately NOT applied to a `--account` run: `resolve_accounts(only)` returns
    that account unconditionally, so re-resolving would start pipelines for every
    OTHER connected mailbox and silently widen a run the user narrowed on purpose.
    The caller gates on this too; the guard is repeated here because widening a
    debug run into a full mailbox poll is not a failure you want to depend on one
    call site to prevent.

    Never raises: supervision is a background convenience, and a transient
    Keychain read failure must not take down mailboxes that are polling fine.
    `resolve_accounts` already degrades to [] on error — which this treats as
    "don't know", NOT as "every account was disconnected", or a locked Keychain
    would stop all ingestion.
    """
    if only_account or pipeline_factory is None:
        return

    try:
        connected = resolve_accounts()
    except Exception:                       # noqa: BLE001 — never kill the loop
        log.exception("Account supervision could not read the registry; "
                      "keeping the current account set")
        return

    if not connected:
        # Ambiguous: an empty registry and an unreadable one look identical here
        # (resolve_accounts swallows the error and returns []). Stopping every
        # pipeline on that reading would turn a locked Keychain into a total
        # ingestion outage — the exact class of silent failure D65 exists to
        # catch. A genuinely disconnected last account costs one extra poll.
        return

    running = {p.account: p for p in pipelines}

    for account in connected:
        if account in running:
            continue
        log.info("Account %s connected while running; starting its pipeline "
                 "(OI25 — no restart needed)", account)
        try:
            pipeline = pipeline_factory(account)
            pipeline.start()
        except Exception:                   # noqa: BLE001 — isolate, P1
            log.exception("Could not start a pipeline for %s; will retry next tick",
                          account)
            continue
        pipelines.append(pipeline)

    for account, pipeline in list(running.items()):
        if account in connected:
            continue
        log.info("Account %s was disconnected; stopping its pipeline", account)
        try:
            # drain=True: whatever was already fetched is still the user's mail,
            # and P1 says suppression is delay, never deletion — dropping a queue
            # mid-flight would lose messages that were already taken responsibility
            # for. Disconnecting removes the credential, not the history.
            pipeline.stop(drain=True)
        except Exception:                   # noqa: BLE001 — quiet, per the work order
            log.exception("Error while stopping the pipeline for %s", account)
        pipelines.remove(pipeline)
        retired.append(pipeline)


def run_forever(pipelines: list, scheduler=None, *,
                pipeline_factory=None,
                supervise_accounts: bool = False,
                only_account: "str | None" = None) -> int:
    """
    Long-lived mode: start every account's pipeline (and the ONE optional digest
    scheduler) and block until SIGINT/SIGTERM, then shut down gracefully.

    One scheduler for the whole process, never one per account: the user has one
    attention, so N accounts must not mean N digests a day. The caller owns that
    invariant by passing a single scheduler; this function never creates one.

    P1: a fatal error in one account's pipeline does not stop the others. The
    process keeps running the healthy mailboxes and reports the failures at exit.

    OI25 — `supervise_accounts` re-reads the Keychain registry on each tick, so a
    mailbox connected in Settings starts being polled WITHOUT a restart, and one
    that is disconnected stops. Before this the registry was read exactly once at
    startup, so the account set was frozen for the life of the process while
    Settings showed an affirmative green check — a silent failure to poll a
    connected mailbox, which for this tool is close to a worst-case bug. The
    reload-per-poll shape is deliberate: it is the same mental model E11/D37
    already established for rules and sender groups ("changes take effect on the
    next poll"), rather than a second, feature-specific rule for the user to learn.

    `pipeline_factory(account) -> IngestionPipeline` builds a pipeline for a newly
    connected account; supervision is inert without one.
    """
    shutdown = threading.Event()

    def _handle(signum, _frame):
        log.info("Received signal %s; shutting down…", signal.Signals(signum).name)
        shutdown.set()

    signal.signal(signal.SIGINT, _handle)
    signal.signal(signal.SIGTERM, _handle)

    # `pipelines` is mutated in place by supervision, so keep the caller's list
    # object rather than rebinding: the shutdown path in `finally` and the
    # failure report below must both see the CURRENT set, including accounts
    # added after startup.
    for pipeline in pipelines:
        pipeline.start()
    if scheduler is not None:
        scheduler.start()
    log.info("thresher running for %d account(s): %s. Press Ctrl-C to stop.",
             len(pipelines), ", ".join(p.account for p in pipelines) or "none")

    # Accounts retired by supervision (disconnected, or dead on a fatal error).
    # Kept so the exit-code report still names an account that died even if the
    # user removed it afterwards — dropping it would make the failure vanish.
    retired: list = []
    # Reconcile on the FIRST tick, then every ACCOUNT_REFRESH_SECONDS.
    last_account_check = float("-inf")

    try:
        # Wake on either a signal or ALL pipelines having stopped. A single
        # account dying (e.g. a missing Keychain credential) must not end the
        # process — the others keep polling — so this waits for every one of them.
        while not shutdown.is_set():
            now = time.monotonic()
            if supervise_accounts and now - last_account_check >= ACCOUNT_REFRESH_SECONDS:
                last_account_check = now
                _supervise_accounts(pipelines, retired, pipeline_factory,
                                    only_account)
            # With supervision on, an empty set is a WAITING state, not an exit:
            # the user may have disconnected their last account and be about to
            # add another, and exiting would mean the next add is never noticed
            # (the failure OI25 is about). Without supervision the set can never
            # change, so all-stopped is genuinely terminal.
            if pipelines and all(p.wait_until_stopped(timeout=0.0) for p in pipelines):
                log.error("Every account's pipeline has stopped; exiting.")
                break
            if not pipelines and not supervise_accounts:
                break
            time.sleep(1.0)
    finally:
        if scheduler is not None:
            scheduler.stop()
        for pipeline in pipelines:
            pipeline.stop(drain=True)

    # Report every account that died, not just the first — with two mailboxes,
    # "one of them broke" is the interesting case and naming it saves a debug cycle.
    failed = [p for p in list(pipelines) + retired if p.fatal_error is not None]
    if failed:
        for p in failed:
            log.error("Account %s stopped due to a fatal error: %s",
                      p.account, p.fatal_error)
        # A KeychainError is re-raised so main()'s handler prints the actionable
        # guidance — but only when it's the ONLY thing wrong, so a single
        # misconfigured account doesn't mask a different failure elsewhere.
        keychain_errors = [p.fatal_error for p in failed
                           if isinstance(p.fatal_error, KeychainError)]
        if len(keychain_errors) == len(failed) == 1:
            raise keychain_errors[0]
        return 1
    log.info("thresher stopped cleanly.")
    return 0


def main(argv=None) -> int:
    args = parse_args(argv)
    configure_logging(args.verbose)

    # Provenance first (build-provenance workorder): the SHA this process is running
    # is the first line in the log, so a stale runtime is visible without needing to
    # suspect it. Session 27 lost time to exactly that.
    from provenance import log_startup_line
    log_startup_line("poller")

    db_path = default_db_path()
    log.info("Initializing database at %s", db_path)
    # init_db is idempotent and seeds defaults only on a fresh install.
    init_db(db_path, seed=True).close()

    def connection_factory():
        # Each pipeline thread gets its own connection (SQLite is not thread-safe
        # to share). The producer/consumer call this once apiece.
        return get_connection(db_path)

    # Notification hook: runs on the consumer thread with its own connection.
    # Disabled with --no-notify (P5: side effects are opt-out-able).
    on_classified = None
    if not args.no_notify:
        def on_classified(conn, message_id, _result):
            NotificationService(conn).notify_for_message(message_id)

    # Which mailboxes? The Keychain is the account registry (D41): an account is
    # "connected" iff it has a stored App Password. `--account` narrows the run to
    # one mailbox (single-account debugging, and what `backend.sh poll` wants).
    accounts = resolve_accounts(args.account)
    if not accounts:
        log.error("No accounts connected. Add one in Settings → Email accounts, or "
                  "store an App Password directly:\n"
                  '  security add-generic-password -s "thresher" '
                  '-a "<account>" -w "<app-password>"')
        # NOT 0. "Nothing to do" is still not a crash, but it is also not
        # "finished", and a supervisor cannot tell those apart from an exit code
        # alone. That ambiguity abandoned the poller on every first run: the app
        # launches with an empty Keychain, this returns, and the supervisor spends
        # its whole restart budget — three tries, 30s apart — on a condition that
        # resolves the moment the user finishes typing an App Password. It then
        # gives up PERMANENTLY, about 90 seconds too early.
        #
        # EXIT_NOT_CONFIGURED says "there is no work available YET, keep
        # watching, do not spend a restart on this." The supervisor treats it as
        # wait rather than died. See BackendSupervisor.restartAnythingThatDied().
        return EXIT_NOT_CONFIGURED

    log.info("Polling %d account(s): %s", len(accounts), ", ".join(accounts))

    def build_pipeline(account: str) -> IngestionPipeline:
        # ONE construction site, used both at startup and by OI25 supervision, so
        # an account connected mid-run gets a pipeline configured identically to
        # one present at boot. A second construction site is how the two would
        # drift (different notification hook, different interval override) and the
        # drift would only show up on the newly added mailbox.
        return IngestionPipeline(
            account=account,
            connection_factory=connection_factory,
            poll_interval_seconds=args.poll_interval,
            on_classified=on_classified,
        )

    pipelines = [build_pipeline(account) for account in accounts]

    # Daily digest scheduler (long-lived mode only; single-shot --once doesn't
    # run a clock). Disabled with --no-notify (P5).
    # ONE scheduler for the process, never one per account: the user has one
    # attention, so N mailboxes must not produce N digests a day. The digest reads
    # the whole store, which is already account-agnostic.
    scheduler = None
    if not args.no_notify:
        scheduler = DigestScheduler(connection_factory)

    try:
        if args.once:
            return run_once(pipelines)
        # Supervision is long-lived-mode only, and OFF for a --account run: that
        # flag narrows the run on purpose, and re-resolving would widen it back to
        # every connected mailbox (see _supervise_accounts).
        return run_forever(
            pipelines, scheduler,
            pipeline_factory=build_pipeline,
            supervise_accounts=(args.account is None),
            only_account=args.account,
        )
    except KeychainError as exc:
        # A missing/misconfigured App Password is a permanent configuration error,
        # not a transient one — fail fast with the actionable guidance the error
        # already carries, rather than dumping a traceback or retrying forever.
        log.error("Cannot authenticate to Gmail: %s", exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())