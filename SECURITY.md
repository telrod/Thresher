# Security policy

## Reporting a vulnerability

**Please report vulnerabilities privately, through GitHub's private
vulnerability reporting:** open the repository's **Security** tab and choose
**Report a vulnerability**. Do not open a public issue, pull request or
discussion for a suspected vulnerability.

A useful report includes what you found, how to reproduce it, which commit you
tested, and what an attacker would gain.

## What to expect

Thresher is alpha software with a single maintainer. Responses are
**best-effort, with no guaranteed response or fix time**. A valid report will be
acknowledged and fixed on `main` when it can be.

## Supported versions

**Only the latest commit on `main` is supported.** There are no release
branches and no backported fixes. Before reporting, check that the issue still
happens on the latest `main`.

## What is in scope

Thresher runs entirely on your Mac. Knowing what it holds and where helps you
decide whether something is in scope.

- **Your mail**, fetched from Gmail over IMAP with TLS (`imap.gmail.com:993`)
  and stored unencrypted in a local SQLite file:
  `~/Library/Application Support/thresher/thresher.db`. Logs are in the
  `logs/` folder next to it.
- **A Gmail app password**, stored in the macOS Keychain under the service name
  `thresher`. By design it is not written to the database, the logs or any
  other file, and a report showing otherwise is in scope.
- **A local HTTP API** that the app uses to talk to its backend. It listens on
  `127.0.0.1:8765` only and has **no authentication**, so any process running
  as your user can read your stored mail through it. This is a known property
  of the current design, not a new finding. Reports showing it is reachable
  beyond loopback, or from a web page in a browser, are in scope.

In scope:

- Anything that exposes stored mail, the app password or the local API
  beyond your own user account on your own Mac.
- Anything that sends mail content, addresses or credentials off the machine,
  other than the IMAP connection to Gmail.
- Code execution or crashes caused by crafted incoming mail.
- The app password reaching a file, a log or a crash report.

Out of scope:

- Attacks that need an attacker already running code as your user, or with
  physical access to your unlocked Mac. They can read the same files the app
  does.
- The lack of code signing and notarization. Distribution is source-only and
  this is documented.
- Vulnerabilities in Gmail, macOS, or the Python and SQLite that ship with
  macOS. Report those to their vendors.
