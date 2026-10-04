# Development

**This document is for working ON the app. It is not how you install or run it.**

If you just want to use it, you need one command and nothing else:

```sh
scripts/build.sh
```

That produces `build/Thresher.app`. Move it to `/Applications`, open it, and
you are done — the app starts and stops its own backend (D67), and there is
nothing to install, configure, or leave running. **Stop reading here.**

Everything below describes a *development* arrangement: running the backend as
separate long-lived processes you manage yourself. It exists because working on
the backend means restarting it constantly, which the app-lifetime model makes
awkward. **It is not the shipped experience and should not be described as
setup.**

> ⚠️ **Why that distinction is stated so bluntly.** This README already made the
> opposite mistake once: it documented the unsupervised arrangement — a poller
> started by hand in a terminal — as though it were normal setup. On 2026-08-13
> that poller crashed on a transient IMAP timeout and **no mail was fetched for
> thirteen days**; 141 messages sat waiting on the server. The crash itself was
> fixed (D64), but *any* crash is permanent without a supervisor. Presenting a
> development arrangement as setup is how a user ends up running an unsupervised
> process and believing it is the intended design.

---

## The two paths, side by side

|  | **Distribution** (`scripts/build.sh`) | **Development** (`scripts/dev-run.sh`) |
| --- | --- | --- |
| Produces | `build/Thresher.app`, then stops | An installed, running app |
| Installs to `/Applications` | No | Yes |
| Backend lifetime | Owned by the app (D67) | launchd agents, or `backend.sh` |
| Touches running processes | Never | Restarts them |
| Who it is for | Anyone who wants the app | Someone changing the code |

They are deliberately different scripts. `build.sh` produces an artifact and
gets out of the way; `dev-run.sh` is a loop that ends with a running app and
asserts the app and backend are the same build.

---

## Building a distributable

```sh
scripts/build.sh                    # → build/Thresher.app (Release)
scripts/build.sh --output /tmp/x    # somewhere else
scripts/build.sh --allow-dirty      # tolerate a dirty tree (stamps read -dirty)
scripts/build.sh --debug            # Debug configuration
```

It checks prerequisites by name before building (macOS version, a usable
Xcode, `/usr/bin/python3`, `rsync`, `pip`), and verifies the artifact after:
backend present, flask vendored, **no real `seed.sql`**, provenance stamped on
both the app and the bundled backend, and the bundled backend importable on the
floor interpreter.

**A broken bundle that builds successfully is the failure this script exists to
prevent**, so every one of those is a hard failure rather than a warning.

### What ships, and what does not

- `backend/` sources, minus tests, caches, and `seed.sql`
- `_vendor/` — flask and its dependencies, ~2.6 MB
- **No Python runtime.** macOS ships `/usr/bin/python3` (3.9.6 on Sonoma) and
  flask is the only third-party dependency (D68). Bundling an interpreter would
  add 24–40 MB plus a relocation and signing problem for no capability we need.

`backend/db/seed.sql` holds **real contacts** and is gitignored; the bundle
ships `seed.example.sql` and `init_db` seeds from it on first run. `build.sh`
fails hard if the real seed ever reaches the bundle.

> **Python floor.** Because the bundle runs on the stock interpreter, **3.9 is a
> hard floor for everything under `backend/`.** `backend/tests/test_python_floor.py`
> guards it by importing every bundled module on `/usr/bin/python3` — importing,
> not compiling, because `str | None` is valid 3.9 *syntax* and fails at import.

---

## The development loop

```sh
scripts/dev-run.sh                 # verify → build → install → restart → launch
scripts/dev-run.sh --skip-build    # fast re-verify of the stamps
scripts/dev-run.sh --no-launch     # everything except opening the app
```

The point of that script is not building — it is asserting that the app's
stamp and `GET /version` **agree**. A human gate was nearly run against an app
binary that predated the whole session's work, which would have produced a
confident PASS about the wrong code.

For finer control, `scripts/backend.sh {start|stop|restart|status}` manages the
two processes directly, and `scripts/launchagent.sh` hands them to launchd with
`KeepAlive`. **The two are mutually exclusive by construction** — `install`
stops anything `backend.sh` is running first, because two supervisors racing for
port 8765 is worse than none.

> ⚠️ **Never run `python3 main.py` and walk away.** It lives only as long as its
> terminal and nothing restarts it. That is the thirteen-day outage above. If you
> want a long-lived backend during development, use `launchagent.sh install`.

### Testing without waiting

`python3 main.py --poll-interval 5` polls every 5 seconds for that run only, and
`--once` does a single poll-process-exit cycle. **Do not lower the stored
`poll_interval_minutes` to achieve this** — it is bounded 1–15 and feeds three
derived values that a sub-minute setting breaks, including the app's refresh
floor and the D45 delivery-claim TTL.

### Tests

```sh
cd backend && python3 -m pytest tests/ -q
xcodebuild -project frontend/Thresher.xcodeproj -scheme Thresher \
    -destination 'platform=macOS' -only-testing:ThresherTests test
```

**Run them one at a time.** The frontend suite drives a real app with real
windows and a RunLoop, and several tests are timing sensitive; running both at
once makes them flaky. A healthy frontend run is ~58s — if it takes ~660s and
fails with `Test runner never began executing tests`, `testmanagerd` has wedged:
`pkill -9 testmanagerd` and remove `<DerivedData>/Logs/Test`. **Check for an
`Executed N tests` line before believing any red result.**

### The icon

`swift design/appicon/RenderIcon.swift design/appicon/png` re-renders every size;
copy the output into `frontend/Thresher/Assets.xcassets/AppIcon.appiconset/`.
A build phase verifies the compiled icon positionally (ramp order, stem
clearance, grain splay) and **fails the build** if it regresses — colour counts
cannot catch a mirrored mark, which is how one shipped. After re-rendering, run
`python3 design/appicon/verify_icon.py design/appicon/png` for the full ladder;
the build phase only sees the four sizes compiled into the `.icns`.
