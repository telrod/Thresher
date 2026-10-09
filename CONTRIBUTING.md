# Contributing to Thresher

Thresher is alpha software with one user. Contributions are welcome. Read this
page first, then [`CLAUDE.md`](CLAUDE.md), which holds the conventions the code
is held to. Those conventions apply whether you are a person or an agent.

## Build

You need macOS 14 (Sonoma) or later and Xcode. No Python install is needed:
the app runs its backend on the `/usr/bin/python3` that ships with macOS.

```
scripts/build.sh            # → build/Thresher.app
```

The script refuses a dirty working tree, because the build is stamped with the
commit it came from. Use `--allow-dirty` while iterating.

The app starts and stops its own backend. For working on the backend itself,
with processes you restart by hand, see the development loop in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Run the tests

There are two suites. **Run them one at a time, never together.** The frontend
suite drives a real app with real windows and a real run loop, and several of
its tests are timing sensitive. Running `pytest` while `xcodebuild` is running
makes both compete for the same cores and causes flaky failures.

### Backend

```
cd backend && python3 -m pytest tests/ -q -rs
```

You need `flask` and `pytest` installed for the interpreter you run it with.
The suite expects **0 skipped**: a skip means a guard did not run. CI fails on
any skip.

### Frontend

```
xcodebuild -project frontend/Thresher.xcodeproj \
  -scheme Thresher -destination 'platform=macOS' \
  -only-testing:ThresherTests test
```

Before believing a red result:

- **Look for an `Executed N tests` line.** A wedged `testmanagerd` also prints
  `** TEST FAILED **`, after about 660 seconds, with "Test runner never began
  executing tests". Fix it with `pkill -9 testmanagerd` and run again.
- **Re-run a red result on its own**, with nothing else running.
- `SettingsWindowLayoutTests` needs a reachable backend, a connected account,
  and the onboarding tutorial marked as seen. Without them it fails in a way
  that looks like a layout regression but isn't one.

The frontend suite is not in CI, because it has not been shown to pass on a
hosted runner.

### Writing tests

When you add a guard, also add a test that proves the guard can fail. See
"Writing a check that can actually fail" in [`CLAUDE.md`](CLAUDE.md) for the
reasons, all from real misses in this project.

## What to work on

- [**`docs/STATUS.md`**](docs/STATUS.md) lists what is open, what was just
  finished, and what comes next.
- [**`docs/IDEAS.md`**](docs/IDEAS.md) lists features that were considered and
  deliberately not built, with the tradeoff written down. This is the best
  place to start if you want something substantial.
- [**Open issues**](../../issues) list specific, scoped work.

Before you change a design decision, read the matching entry in
[`DECISIONS.md`](DECISIONS.md). Most decisions record what was tried before.

## Data that must never be committed

- **No real mail, no real addresses, no real names.** Test data uses RFC 2606
  reserved domains (`example.com`, `example.org`, `example.net`). The only
  committed `.eml` files are the synthetic corpus in `backend/tests/corpus/`.
- **No databases**, generated or otherwise.
- **`backend/db/seed.sql`** is local-only. Edit `seed.example.sql` instead.

Some of these rules are also enforced by guard tests: names in tracked files,
reserved domains in the corpus, and nothing tracked under `local/`. The rest
are enforced only by `.gitignore` and by review.
