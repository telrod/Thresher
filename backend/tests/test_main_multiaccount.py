"""
Multi-account orchestration tests for main.py — the layer that had NO tests.

`main.py` decides which mailboxes get polled, how many digest schedulers exist, and
what happens when one account fails. All three are invariants, and none of them was
covered before this file — the same "the untested layer is where the bug lives"
shape that let OI19 ship.

These tests drive the real `resolve_accounts` / `run_once` / `run_forever`, faking
only the Keychain and the pipelines themselves.
"""

import sys
from unittest.mock import MagicMock, patch

import pytest

import main
from ingestion.keychain import KeychainError


# ── resolve_accounts: which mailboxes get polled ─────────────────────────────

def test_resolve_accounts_returns_every_connected_account():
    """The Keychain is the registry (D41), so an added account is polled with no
    other configuration — the same source GET /accounts reads."""
    with patch("ingestion.keychain.list_accounts",
               return_value=["you@example.com", "you@example.org"]):
        assert main.resolve_accounts() == ["you@example.com", "you@example.org"]


def test_resolve_accounts_honors_an_explicit_single_account():
    """`--account` narrows the run to one mailbox — what backend.sh poll wants,
    and what single-account debugging needs."""
    with patch("ingestion.keychain.list_accounts",
               return_value=["a@x.example", "b@y.example"]):
        assert main.resolve_accounts("b@y.example") == ["b@y.example"]


def test_an_explicit_account_is_honored_even_with_no_stored_credential():
    """So the failure is the honest one ("no credential for X") rather than a
    silently empty run that looks like success."""
    with patch("ingestion.keychain.list_accounts", return_value=[]):
        assert main.resolve_accounts("ghost@nowhere.example") == ["ghost@nowhere.example"]


def test_resolve_accounts_degrades_to_empty_when_the_keychain_errors():
    """A Keychain read failure must not crash startup — it yields no accounts, and
    main() turns that into an actionable message rather than a traceback."""
    with patch("ingestion.keychain.list_accounts",
               side_effect=KeychainError("locked")):
        assert main.resolve_accounts() == []


def test_no_connected_accounts_exits_NOT_CONFIGURED_not_zero(capsys, tmp_path):
    """Zero accounts is a fresh install, not a crash — but it is not "finished"
    either, and the difference is load-bearing.

    THIS TEST PREVIOUSLY ASSERTED `== 0`, which is the defect it now guards
    against. Exit 0 made "no work available yet" indistinguishable from "the work
    completed", so `BackendSupervisor.restartAnythingThatDied()` counted each
    zero-account exit as a death and spent its whole restart budget (3 tries,
    30s apart) before the user could finish typing an App Password — then gave up
    on the poller PERMANENTLY. Every first run shipped with no ingestion at all.

    VERIFIED RED against the pre-fix main.py: `assert 0 == 3` — the old code
    returned 0 from the same guard, which is exactly the ambiguity.

    The exit code is a CONTRACT with the Swift supervisor: the value here must
    match `BackendSupervisor.exitNotConfigured`. A test on the Swift side pins
    the other half.
    """
    with patch.object(main, "resolve_accounts", return_value=[]), \
         patch.object(main, "init_db"), \
         patch.object(main, "default_db_path", return_value=tmp_path / "t.db"):
        assert main.main(["--once"]) == main.EXIT_NOT_CONFIGURED
    assert main.EXIT_NOT_CONFIGURED == 3, \
        "the supervisor hardcodes 3; changing this breaks first-run ingestion"


def test_not_configured_exit_code_is_distinct_from_every_other_outcome(tmp_path):
    """The whole point is distinguishability, so assert the codes cannot collide.

    0 = success/finished · 1 = error · 2 = auth failure (permanent) ·
    3 = not configured yet (transient, keep watching).

    VERIFIED RED by setting EXIT_NOT_CONFIGURED = 0, which is the pre-fix value:
    the assertion below fails naming the collision.
    """
    assert main.EXIT_NOT_CONFIGURED not in (0, 1, 2), (
        f"EXIT_NOT_CONFIGURED={main.EXIT_NOT_CONFIGURED} collides with an "
        "existing exit code, so the supervisor cannot tell them apart")


# ── run_once: every account polled, failures isolated ────────────────────────

def _fake_pipeline(account, *, poll_raises=None):
    p = MagicMock()
    p.account = account
    p.stats = f"stats({account})"
    p.fatal_error = None
    if poll_raises is not None:
        p.poll_once.side_effect = poll_raises
    else:
        p.poll_once.return_value = 3
    return p


def test_run_once_polls_every_account():
    a = _fake_pipeline("a@x.example")
    b = _fake_pipeline("b@y.example")

    with patch.object(main, "get_connection"), patch.object(main, "default_db_path"):
        assert main.run_once([a, b]) == 0

    a.poll_once.assert_called_once()
    b.poll_once.assert_called_once()


def test_run_once_ONE_FAILING_ACCOUNT_DOES_NOT_STOP_THE_OTHERS(caplog):
    """P1, at the orchestration layer: a dead mailbox must not cost you the mail in
    a healthy one. The exit code still reports failure so a script notices."""
    bad = _fake_pipeline("bad@x.example", poll_raises=RuntimeError("imap exploded"))
    good = _fake_pipeline("good@y.example")

    with patch.object(main, "get_connection"), patch.object(main, "default_db_path"):
        rc = main.run_once([bad, good])

    assert good.poll_once.called, "a failing account stopped a healthy one"
    good.queue.join.assert_called_once()
    assert rc == 1, "the run should still report failure"
    assert "bad@x.example" in caplog.text


def test_run_once_tears_down_the_consumer_of_a_failed_account():
    """No leaked worker threads when a poll throws."""
    bad = _fake_pipeline("bad@x.example", poll_raises=RuntimeError("boom"))
    with patch.object(main, "get_connection"), patch.object(main, "default_db_path"):
        main.run_once([bad])
    bad.stop.assert_called_with(drain=False)


# ── run_forever: ONE scheduler, and failure isolation ────────────────────────

def test_run_forever_starts_every_pipeline_but_only_ONE_scheduler():
    """The invariant most at risk from a careless loop: the user has one attention,
    so N mailboxes must not mean N digests a day."""
    a, b = _fake_pipeline("a@x.example"), _fake_pipeline("b@y.example")
    for p in (a, b):
        p.wait_until_stopped.return_value = True    # stop immediately
    scheduler = MagicMock()

    main.run_forever([a, b], scheduler)

    a.start.assert_called_once()
    b.start.assert_called_once()
    scheduler.start.assert_called_once()
    scheduler.stop.assert_called_once()


def test_run_forever_keeps_running_while_ANY_account_is_alive():
    """One account dying must not end the process — the healthy mailbox keeps
    polling. Here `a` is stopped from the start and `b` stops on the 3rd check;
    the loop must not exit until BOTH are down."""
    a = _fake_pipeline("dead@x.example")
    a.wait_until_stopped.return_value = True
    b = _fake_pipeline("alive@y.example")
    b.wait_until_stopped.side_effect = [False, False, True, True, True]

    with patch.object(main.time, "sleep"):
        main.run_forever([a, b], None)

    assert b.wait_until_stopped.call_count >= 3, \
        "the loop exited while an account was still alive"


def test_run_forever_reports_every_failed_account_not_just_the_first(caplog):
    a = _fake_pipeline("a@x.example")
    b = _fake_pipeline("b@y.example")
    for p in (a, b):
        p.wait_until_stopped.return_value = True
    a.fatal_error = RuntimeError("a died")
    b.fatal_error = RuntimeError("b died")

    assert main.run_forever([a, b], None) == 1
    assert "a@x.example" in caplog.text and "b@y.example" in caplog.text


def test_a_lone_keychain_error_is_reraised_for_the_actionable_message():
    """main()'s handler prints setup guidance for a KeychainError, so a single
    misconfigured account should still reach it."""
    p = _fake_pipeline("nocreds@x.example")
    p.wait_until_stopped.return_value = True
    p.fatal_error = KeychainError("no password for nocreds@x.example")

    with pytest.raises(KeychainError):
        main.run_forever([p], None)


def test_a_keychain_error_ALONGSIDE_another_failure_does_not_mask_it(caplog):
    """With two accounts down for different reasons, re-raising the Keychain one
    would hide the other. Report both and return non-zero instead."""
    a = _fake_pipeline("nocreds@x.example")
    b = _fake_pipeline("broken@y.example")
    for p in (a, b):
        p.wait_until_stopped.return_value = True
    a.fatal_error = KeychainError("no password")
    b.fatal_error = RuntimeError("something else entirely")

    assert main.run_forever([a, b], None) == 1
    assert "something else entirely" in caplog.text


def test_run_forever_drains_every_pipeline_on_shutdown():
    a, b = _fake_pipeline("a@x.example"), _fake_pipeline("b@y.example")
    for p in (a, b):
        p.wait_until_stopped.return_value = True

    main.run_forever([a, b], None)

    a.stop.assert_called_with(drain=True)
    b.stop.assert_called_with(drain=True)


# ── OI25: the account registry is re-read while running ──────────────────────
#
# Before this, `resolve_accounts()` was called exactly once and one pipeline was
# built per account at that moment, so the account set was FROZEN for the life of
# the process. Connecting a mailbox in Settings showed an affirmative green check
# and then silently never polled it — for a tool whose promise is "nothing
# important gets missed", quietly not polling a connected mailbox is close to a
# worst-case failure.
#
# The fix follows the E11/D37 reload-per-poll precedent already established for
# rules and sender groups: the registry is re-read on a supervision tick, so
# "changes take effect on the next poll" is one mental model for the whole system
# rather than a special case per feature.

def _supervising_run(pipelines_by_account, accounts_over_time, *,
                     only=None, initial=()):
    """
    Drive run_forever through N supervision ticks with a changing registry.

    `accounts_over_time` is the sequence resolve_accounts() returns on successive
    ticks; the run ends when it is exhausted. `initial` is the account set main()
    already built pipelines for before calling run_forever (startup behaviour is
    unchanged by OI25 — supervision only reconciles from there). Returns the list
    of accounts for which a pipeline was CONSTRUCTED, in order.
    """
    built = []

    def _factory(account, **_kwargs):
        built.append(account)
        p = pipelines_by_account.setdefault(account, _fake_pipeline(account))
        p.wait_until_stopped.return_value = False       # alive unless told otherwise
        return p

    ticks = list(accounts_over_time)

    def _resolve(only_arg=None):
        if only_arg:
            return [only_arg]
        return ticks.pop(0) if ticks else []

    stop_after = len(ticks)
    calls = {"n": 0}
    # A fake clock: supervision is throttled to ACCOUNT_REFRESH_SECONDS (the
    # Keychain read shells out and costs ~100ms), so the loop's own 1s tick must
    # not be assumed to reconcile. Advancing past the throttle per tick keeps
    # these tests about the RECONCILIATION, with the throttle itself pinned
    # separately by test_the_registry_read_is_THROTTLED_not_run_every_tick.
    clock = {"t": 0.0}

    def _sleep(_seconds):
        calls["n"] += 1
        clock["t"] += main.ACCOUNT_REFRESH_SECONDS
        if calls["n"] >= stop_after:
            raise KeyboardInterrupt          # end the loop deterministically

    starting = [_factory(a) for a in initial]

    with patch.object(main, "resolve_accounts", side_effect=_resolve), \
         patch.object(main.time, "monotonic", side_effect=lambda: clock["t"]), \
         patch.object(main.time, "sleep", side_effect=_sleep):
        try:
            main.run_forever(
                starting, None,
                pipeline_factory=_factory,
                supervise_accounts=(only is None),
                only_account=only,
            )
        except KeyboardInterrupt:
            pass
    return built


def test_an_account_ADDED_while_running_is_polled_without_a_restart():
    """OI25, the headline case. the author connected you@example.org in Settings, the
    indicator went green, and the poller kept reading `running for 1 account(s)`
    until the process was restarted."""
    pipes = {}
    built = _supervising_run(
        pipes,
        [["a@x.example"],
         ["a@x.example", "new@y.example"],      # added mid-run
         ["a@x.example", "new@y.example"]],
    )

    assert "new@y.example" in built, \
        "an account added mid-run was never polled — OI25 has regressed"
    pipes["new@y.example"].start.assert_called_once()


def test_an_account_added_mid_run_does_not_restart_the_existing_ones():
    """The healthy mailbox must not be disturbed to pick up a new sibling — a
    restart would re-seed cursors and re-poll."""
    pipes = {}
    _supervising_run(
        pipes,
        [["a@x.example"],
         ["a@x.example", "new@y.example"],
         ["a@x.example", "new@y.example"]],
    )

    pipes["a@x.example"].start.assert_called_once()
    assert not pipes["a@x.example"].stop.called or \
        pipes["a@x.example"].stop.call_args.kwargs.get("drain") is True


def test_an_account_DISCONNECTED_while_running_stops_being_polled():
    """OI25 cuts both ways: removing an account deletes the Keychain item but
    left its pipeline running, polling a mailbox the user disconnected."""
    pipes = {}
    _supervising_run(
        pipes,
        [["a@x.example", "gone@y.example"],
         ["a@x.example"],                        # disconnected
         ["a@x.example"]],
    )

    pipes["gone@y.example"].stop.assert_called_once()
    assert pipes["gone@y.example"].stop.call_args.kwargs.get("drain") is True, \
        "a disconnected account must still finish processing what it already fetched (P1)"


def test_a_disconnected_account_does_not_raise():
    """Explicit in the work order: stopping a removed account must be quiet, not
    an error spew that looks like a failure."""
    pipes = {}
    built = _supervising_run(
        pipes,
        [["a@x.example", "gone@y.example"],
         ["a@x.example"],
         ["a@x.example"]],
    )
    assert built == ["a@x.example", "gone@y.example"]


def test_a_re_added_account_gets_a_FRESH_pipeline():
    """`stop()` is one-way — the _stop Event is never cleared — so a pipeline that
    was stopped can never poll again. Re-adding must construct a new one, or the
    account comes back green and dead."""
    pipes = {}
    built = _supervising_run(
        {},                                      # fresh dict: factory rebuilds
        [["a@x.example", "flip@y.example"],
         ["a@x.example"],                        # removed
         ["a@x.example", "flip@y.example"],      # re-added
         ["a@x.example", "flip@y.example"]],
    )

    assert built.count("flip@y.example") == 2, \
        "a re-added account reused a stopped pipeline and would never poll"


def test_supervision_is_OFF_for_an_explicit_single_account_run():
    """`--account` deliberately narrows a run to one mailbox (debugging, and what
    backend.sh poll wants). Re-resolving the registry would silently widen it back
    to every connected account — turning a narrowed run into a full one.

    This drives `_supervise_accounts` DIRECTLY rather than going through
    run_forever. Routed through the caller, `supervise_accounts=False` means the
    helper is never reached, so the test passed even with the inner guard deleted
    — it asserted an absence that the call shape guaranteed anyway. Two guards
    exist (caller and helper); each needs its own test or one of them is decorative.
    """
    only = _fake_pipeline("just@me.example")
    pipelines = [only]
    built = []

    def _factory(account):
        built.append(account)
        return _fake_pipeline(account)

    with patch.object(main, "resolve_accounts",
                      return_value=["a@x.example", "b@y.example"]):
        main._supervise_accounts(pipelines, [], _factory,
                                 only_account="just@me.example")

    assert built == [], "--account was widened by supervision: " + repr(built)
    assert [p.account for p in pipelines] == ["just@me.example"]
    assert not only.stop.called, "the --account pipeline was stopped by supervision"


def test_supervision_without_a_factory_is_inert():
    """The factory is what makes supervision able to act; without one the helper
    must do nothing rather than stop every pipeline as "not reconcilable"."""
    p = _fake_pipeline("a@x.example")
    pipelines = [p]

    with patch.object(main, "resolve_accounts", return_value=["b@y.example"]):
        main._supervise_accounts(pipelines, [], None, only_account=None)

    assert [q.account for q in pipelines] == ["a@x.example"]
    assert not p.stop.called


def test_an_UNREADABLE_registry_does_not_stop_every_pipeline():
    """`resolve_accounts` swallows a Keychain error and returns [], so an empty
    registry and an unreadable one are indistinguishable here. Reading that as
    "every account was disconnected" would turn a locked Keychain into a total
    ingestion outage — the silent-stop class of failure D65 exists to catch."""
    p = _fake_pipeline("a@x.example")
    pipelines = [p]

    with patch.object(main, "resolve_accounts", return_value=[]):
        main._supervise_accounts(pipelines, [], lambda a: _fake_pipeline(a),
                                 only_account=None)

    assert [q.account for q in pipelines] == ["a@x.example"], \
        "an empty/unreadable registry stopped a healthy pipeline"
    assert not p.stop.called


def test_supervision_survives_a_registry_read_that_raises():
    """Supervision is a background convenience; it must never take down mailboxes
    that are polling fine."""
    p = _fake_pipeline("a@x.example")
    pipelines = [p]

    with patch.object(main, "resolve_accounts", side_effect=RuntimeError("boom")):
        main._supervise_accounts(pipelines, [], lambda a: _fake_pipeline(a),
                                 only_account=None)

    assert [q.account for q in pipelines] == ["a@x.example"]


def test_a_pipeline_that_fails_to_start_is_retried_not_half_added(caplog):
    """A construction failure must not leave a dead pipeline in the set — that
    would make the account look supervised while never polling (OI25's shape)."""
    pipelines = []

    def _explode(_account):
        raise RuntimeError("could not build")

    with patch.object(main, "resolve_accounts", return_value=["new@y.example"]):
        main._supervise_accounts(pipelines, [], _explode, only_account=None)

    assert pipelines == [], "a pipeline that failed to start was added anyway"
    assert "new@y.example" in caplog.text


def test_supervision_does_not_disturb_a_steady_account_set():
    """The common case: nothing changed, so nothing is started or stopped."""
    pipes = {}
    _supervising_run(
        pipes,
        [["a@x.example"], ["a@x.example"], ["a@x.example"], ["a@x.example"]],
    )

    pipes["a@x.example"].start.assert_called_once()
    assert not pipes["a@x.example"].stop.called or \
        pipes["a@x.example"].stop.call_args.kwargs.get("drain") is True


def test_the_registry_read_is_THROTTLED_not_run_every_tick():
    """`list_accounts()` shells out to `security dump-keychain` — measured at
    ~100ms. At the loop's 1s tick that is ~10% of a core burned continuously in a
    process that runs from login onward (D66). Reconciliation is paced instead,
    which still beats the shortest settable poll interval (1 min) by 2x."""
    resolves = {"n": 0}
    clock = {"t": 0.0}

    def _resolve(only_arg=None):
        resolves["n"] += 1
        return ["a@x.example"]

    def _sleep(_seconds):
        clock["t"] += 1.0                       # the real loop tick
        if clock["t"] >= 10.0:
            raise KeyboardInterrupt

    p = _fake_pipeline("a@x.example")
    p.wait_until_stopped.return_value = False

    with patch.object(main, "resolve_accounts", side_effect=_resolve), \
         patch.object(main.time, "monotonic", side_effect=lambda: clock["t"]), \
         patch.object(main.time, "sleep", side_effect=_sleep):
        try:
            main.run_forever([p], None, pipeline_factory=_fake_pipeline,
                             supervise_accounts=True, only_account=None)
        except KeyboardInterrupt:
            pass

    assert resolves["n"] == 1, (
        f"the Keychain was read {resolves['n']} times in 10 simulated seconds; "
        "the registry read is not throttled")


def test_the_registry_is_read_on_the_FIRST_tick():
    """Throttling must not delay the first reconciliation — an account added
    while the poller was down should be picked up immediately, not 30s in."""
    clock = {"t": 0.0}
    built = []

    def _sleep(_seconds):
        clock["t"] += 1.0
        raise KeyboardInterrupt

    def _factory(account):
        built.append(account)
        q = _fake_pipeline(account)
        q.wait_until_stopped.return_value = False
        return q

    with patch.object(main, "resolve_accounts", return_value=["new@y.example"]), \
         patch.object(main.time, "monotonic", side_effect=lambda: clock["t"]), \
         patch.object(main.time, "sleep", side_effect=_sleep):
        try:
            main.run_forever([], None, pipeline_factory=_factory,
                             supervise_accounts=True, only_account=None)
        except KeyboardInterrupt:
            pass

    assert built == ["new@y.example"], "the first tick did not reconcile"
