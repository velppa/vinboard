# vinboard — Claude Code Notes

## Project Overview

A personal bookmarking service in the spirit of Pinboard: bookmarks with
tags, notes, full-text search, and an archived copy of every page. Written
in Zig against SQLite, served by http.zig. The hosted instance runs on the
Mini at `https://uiuo.nl/vinboard`.

## Architecture

| module | what |
|---|---|
| (◊ff 'vinboard "main.zig") | CLI flags, opens the database, starts the server and the archive worker |
| (◊ff 'vinboard "server.zig") | the `App` struct every handler receives, and route registration |
| (◊ff 'vinboard "web.zig") | the HTML UI — by far the largest module |
| (◊ff 'vinboard "api.zig") | the JSON API under `/api` |
| (◊ff 'vinboard "pinboard_compat.zig") | Pinboard's `/v1/posts/*` API, so Pinboard clients work unchanged |
| (◊ff 'vinboard "db.zig") | schema, migrations, and every query |
| (◊ff 'vinboard "sqlite.zig") | thin SQLite binding |
| (◊ff 'vinboard "sqlite3_helpers.c") | the C shims for binds Zig cannot express, `SQLITE_TRANSIENT` ones |
| (◊ff 'vinboard "archive.zig") | background worker that fetches and stores page copies |
| (◊ff 'vinboard "gzip.zig") | compression for those page copies |
| (◊ff 'vinboard "strip.zig") | HTML to plain text, for the search index |
| (◊ff 'vinboard "auth.zig"), (◊ff 'vinboard "oidc.zig") | password hashing; OIDC login against home-auth |
| (◊ff 'vinboard "import.zig") | bookmark import |
| (◊ff 'vinboard "suggest.zig") | tag suggestions from a System One decision model |
| (◊ff 'vinboard "models.zig"), (◊ff 'vinboard "html.zig") | shared types; HTML escaping |

Also: (◊ff 'vinboard "vinboard.el") as an Emacs client, `scripts/` for the
Reddit import (◊ff 'vinboard "reddit-upvoted.js") and the archiver
(◊ff 'vinboard "chromium-archive") with its Emacs half
(◊ff 'vinboard "vinboard-archive.el"), and
`docs/superpowers/` holding the original design spec and plan.

The iOS share-sheet shortcut is built per request from
(◊ff 'vinboard "shortcut-template.xml"), embedded into the binary, and
signed with macOS `shortcuts sign`.

## Build, test, run

```sh
make test     # zig build test --summary all
make build    # ReleaseSafe, then relink ~/.local/bin/vinboard
make run      # vinboard --base-path /vinboard
```

Needs Zig ≥ 0.16. The only package dependency is http.zig, pinned by commit
in (◊ff 'vinboard "build.zig.zon"); SQLite is vendored.

Tests are inline `test` blocks reachable from (◊ff 'vinboard "main.zig")'s
import graph — there is no separate test root. They run with the repo root
as the working directory, so fixtures are addressed as `tests/fixtures/…`.

**`make build` deploys.** `~/.local/bin/vinboard` is a symlink into
`zig-out/bin/`, so a successful build replaces what the running service will
next execute, and a build from a stale checkout ships a regression just as
fast. Note also that its `rm ~/.local/bin/vinboard` step fails if the
symlink is not already there.

On the Mini the service is started from the hotter.myaddr.dev repo (`make
start-vinboard` there), not by this repo's `make start`.

## Conventions

- Handlers take `*App` and hold `db_mutex` around database work — a single
  SQLite connection shared with the archive worker.
- When `--base-path` is set, every route is registered twice: once bare and
  once under the prefix. A reverse proxy strips the prefix, but direct
  access needs the prefixed form too.
- Admin-set configuration lives in the `sysconf` table, not in flags — OIDC
  settings and one-off migration markers both.
- The app authenticates everything itself: web sessions for the UI, and
  `handle:TOKEN` bearer/`auth_token` credentials for `/api` and `/v1`. It
  therefore sits behind **no** `forward_auth` in Caddy.

## Database

SQLite in WAL mode at `~/.local/state/vinboard/vinboard.db` (`--db`
overrides). Tables: `bookmark`, `tag`, `user`, `session`, `sysconf`, plus a
contentless `bookmark_fts` FTS5 index over title, notes, url, tags and page
body. `bookmark.edited` holds bits for the fields a person changed by hand,
which a client re-saving the url leaves alone.

Page copies live in a second file, `vinboard-archive.db` next to it
(`--archive-db` overrides), attached as `arc`; the unqualified `archive`
table resolves there. Moving them out of the main file was one-way: a binary
from before `67a1302` finds no archives in a converted database.

`migrate()` runs on every start and is expected to be idempotent.

## Archived pages

The worker polls for pending urls and shells out to `--archiver`, which must
print html to stdout. On the Mini that is
(◊ff 'vinboard "chromium-archive"): Emacs opens the url in a background tab
of the Chromium connected through browser-gt (with the user's logins),
scrolls it, captures it as MHTML and closes the tab; the script turns that
into one self-contained html file, resources inlined as data urls and
scripts dropped. It needs Emacs running browser-gt and the extension's
`CAPTURE_MHTML` and `OPEN_BACKGROUND_TAB` handlers. A page still showing a
bot check after 45 s fails rather than being saved; pass the check in
Chromium and re-queue it (the "archive" link, or
`POST /api/bookmarks/:id/archive`).

A run is wrapped in `timeout`, because pages that hang the archiver would
otherwise stall the queue forever — the poller keeps picking the same row.
Without a working archiver the server runs fine and archive jobs simply
record `failed`. Archived copies are served under a CSP sandbox: no scripts,
no access to vinboard's origin.

**Page copies are stored gzipped.** `archive.html` is a BLOB; only `html` is
compressed, while `text` stays plain because SQL reads it when building the
FTS body. Reads go through `gzip.decode`, which passes plain bytes through,
so rows written before compression still work. A one-off resumable pass
converts them on startup and marks the database with the sysconf key
`archive_html_compressed`.

That migration is **one-way**: once a database is converted, a binary built
from a pre-compression checkout reads gzip blobs as text and serves binary
garbage, and writes new archives back uncompressed. If you ever bisect or
roll back across `b006223`, point the old binary at a copy of the database,
not the live one.

## Tag suggestions

`--suggest-url` is the full url of a System One endpoint, `--suggest-model`
the model to ask for. The bearer token lives in `sysconf` under
`suggest_api_key`, set once with `--set-suggest-key` so it never shows up in
`ps`. Without a url the feature is off and nothing changes.

    vinboard --set-suggest-key <key>
    vinboard --suggest-url https://openrouter.ai/api/alpha/decisions

A bookmark saved with no tags gets them from the model, on every create
path: `/api/bookmarks`, the `/ui/add` form, and Pinboard's `posts/add`. The
`/add` form is rendered with the same suggestion already in the tags field.
Tags the caller supplied are never touched, and neither is a url that was
saved before.

Two passes: one `choice` question ranks the user's own tags, then a yes/no
question per shortlisted tag gives a probability worth thresholding. Both
cost a round trip, so a create that needs suggestions takes about a second.
A dead server, a malformed answer or an unconvinced model all mean no tags,
never an error — but a server that accepts the connection and then hangs
holds the handler, because `std.http.Client` has no timeout here.

## Gotchas

- `main` is the working branch and deploys straight to the Mini. Before
  leaving changes uncommitted, remember the symlink above: the built binary
  can be ahead of `origin/main` for weeks without anything looking wrong.
- `main.sync-conflict-…` branches are Syncthing artifacts, not work.
- The repo is reachable at two paths, `~/.velppa/vinboard` and
  `~/Developer/src/github.com/velppa/vinboard`, because `~/.velppa` is a
  symlink to the velppa checkout directory. Same checkout either way.
