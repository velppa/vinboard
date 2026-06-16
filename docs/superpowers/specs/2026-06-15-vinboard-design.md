# vinboard — design

Date: 2026-06-15
Status: approved (pending spec review)

## Purpose

Self-hosted, single-user replacement for Pinboard. Pinboard is unreliable
(currently DNS-dead; API rate limits "too harsh" per the consolidate-bookmarks
note). vinboard gives full ownership: one SQLite file, one self-contained Zig
binary, hosted on the existing `hotter.myaddr.dev` homeserver alongside Textpod
and the quickblog site.

The Emacs client `vinboard.el` replaces `pinboard.el` as the day-to-day
interface; a built-in htmx web UI covers browser/iOS access.

## Decisions (locked during brainstorming)

- **Build custom**, not adopt linkding/shiori.
- **Runtime:** Zig — one self-contained binary, embedded SQLite.
- **Interfaces:** fresh clean REST API + server-rendered web UI (htmx + Tailwind, both via CDN, no front-end build step).
- **Auth:** none in the app. Caddy gates `/vinboard` with the same token+cookie scheme already on `/bookmarks`; vinboard trusts localhost.
- **v1 features:** FTS5 search, to-read + private/public flags, import (Pinboard JSON + Safari), page archiving via SingleFile.
- **Archiver:** `single-file-cli` (headless Chrome) → one self-contained HTML per bookmark. (Kage was rejected — it shadows whole sites to ZIM/binary, needs a reader to view, wrong granularity.)
- **Repo:** standalone `~/Developer/src/github.com/velppa/vinboard` (server + `vinboard.el`), deployed onto hotter — not inside the hotter repo.

## Architecture

One Zig binary, run under `dtach` like Textpod, holding one SQLite file.

```
Emacs (vinboard.el) ─┐
Browser / iOS ───────┤→ Caddy (TLS, token+cookie gate on /vinboard)
                     └→ reverse_proxy localhost:PORT → vinboard binary → vinboard.db
                                                            └→ single-file-cli (headless Chrome)
```

Binary flags: `--db <path>`, `--port <n>`, `--base-path /vinboard` (base-path
prefixes htmx/asset URLs so the app works under a Caddy sub-path — same trick as
Textpod's `--base-path notes`).

### Zig modules

| Module      | Responsibility                                                        |
|-------------|-----------------------------------------------------------------------|
| `main.zig`  | Arg parse, `std.http.Server` loop, wire modules together              |
| `db.zig`    | SQLite wrapper (bundled amalgamation): open, migrate, typed queries   |
| `router.zig`| Path/method dispatch to handlers                                      |
| `api.zig`   | JSON REST handlers                                                     |
| `web.zig`   | htmx-fragment / full-page HTML handlers                               |
| `archive.zig`| Background worker: spawn archiver, store HTML + FTS text             |
| `import.zig`| Pinboard-JSON + Safari parsers                                        |

Each module has one clear purpose, talks to others through narrow function
interfaces, and is unit-testable in isolation (db against in-memory SQLite,
parsers against fixture strings, archive worker against a stubbed command).

## Data model (SQLite)

```sql
bookmarks(
  id          INTEGER PRIMARY KEY,
  url         TEXT UNIQUE NOT NULL,
  title       TEXT NOT NULL DEFAULT '',
  notes       TEXT NOT NULL DEFAULT '',     -- Pinboard "extended"
  created_at  INTEGER NOT NULL,             -- unix seconds
  updated_at  INTEGER NOT NULL,
  toread      INTEGER NOT NULL DEFAULT 0,    -- bool
  shared      INTEGER NOT NULL DEFAULT 0     -- bool (public)
)

tags(
  bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
  tag         TEXT NOT NULL,
  PRIMARY KEY (bookmark_id, tag)
)

archive(
  bookmark_id INTEGER PRIMARY KEY REFERENCES bookmarks(id) ON DELETE CASCADE,
  html        BLOB,                          -- self-contained page from SingleFile
  text        TEXT,                          -- tag-stripped, for FTS
  fetched_at  INTEGER,
  status      TEXT NOT NULL DEFAULT 'pending' -- pending|done|failed
)

-- FTS5 external-content over title/notes/url/tags/archive.text,
-- kept in sync by triggers on bookmarks/tags/archive.
bookmarks_fts USING fts5(title, notes, url, tags, body, content='', ...)
```

Tags are a normalized join table (clean REST exposes a JSON array, not
Pinboard's space-separated string).

## REST API (JSON)

| Method | Path                          | Purpose                                              |
|--------|-------------------------------|------------------------------------------------------|
| GET    | `/api/bookmarks`              | List; filters `?tag=&toread=&shared=&limit=&offset=` |
| POST   | `/api/bookmarks`              | Create `{url,title,notes,tags[],toread,shared}`; queues archive |
| GET    | `/api/bookmarks/:id`          | One bookmark                                         |
| PATCH  | `/api/bookmarks/:id`          | Partial update                                       |
| DELETE | `/api/bookmarks/:id`          | Delete (cascades tags + archive)                     |
| GET    | `/api/search?q=`              | FTS5 search                                          |
| GET    | `/api/tags`                   | Tag list with counts                                 |
| POST   | `/api/import`                 | Bulk `{source: pinboard|safari, data: [...]}`        |
| GET    | `/api/bookmarks/:id/archive`  | Serve archived HTML (`text/html`)                    |

Web UI: `GET /` — list + search box + add form, server-rendered, htmx for
inline add/edit/delete and search-as-you-type. Archived page shown in an
`<iframe>`.

## Archiving

1. `POST /api/bookmarks` inserts the bookmark and an `archive` row `status='pending'`, returns immediately.
2. A single background worker thread polls `archive WHERE status='pending'`, spawns the archiver command `single-file <url> -` (path injectable via config for tests), captures stdout (self-contained HTML).
3. Stores HTML in `archive.html`, tag-strips into `archive.text` (feeds FTS), sets `status='done'`, `fetched_at=now`. On failure → `status='failed'` (retryable).
4. Host dependency: Chrome/Chromium + `single-file-cli`.

## Import

- **Pinboard**: JSON export array `[{href, description, extended, tags, time, shared, toread}]` → schema mapping (`shared`/`toread` "yes"/"no" → bool; `tags` space-split → join rows). Requires an export file the user already holds (Pinboard API is down).
- **Safari**: generic `[{url, title, time}]`. A small elisp/script extracts Reading List (`~/Library/Safari/Bookmarks.plist`) + history (`History.db`) and POSTs to `/api/import`. Satisfies the "Send Safari history as bookmarks" task.
- Dedup on `url UNIQUE`: upsert-or-skip (keep earliest `created_at`).

## Build & deploy

- `zig build -Doptimize=ReleaseSafe` → single binary. Bundle the SQLite amalgamation (`sqlite3.c`) so the binary is self-contained (no system libsqlite dependency).
- Run: `dtach -n /tmp/vinboard.sock vinboard --db ~/<path>/vinboard.db --port 4670 --base-path /vinboard`. `Makefile` `start-vinboard` target.
- Caddy (`hotter.myaddr.dev` Caddyfile): add `@vinboard path /vinboard /vinboard/*` block, reuse the `/bookmarks` `@valid_token` + `auth_token` cookie gate, then `reverse_proxy localhost:4670`.
- Host deps: Chrome/Chromium, `single-file-cli`.

## Testing

- **Unit (Zig `test`)**: `db.zig` against in-memory SQLite (migrate, CRUD, FTS query build); `import.zig` parsers against fixture JSON; tag-join logic; html→text strip.
- **Integration**: start server on a random port, drive the API end-to-end (create → get → search → patch → delete); archive worker tested with a stub archiver command (e.g. a script echoing canned HTML) so CI needs no Chrome.
- **`vinboard.el`**: thin REST wrappers; a few `ert` tests against a local instance + manual checks.

## Out of scope (v1)

- HN-legible-frontend Cloudflare sync (rewrite later against the new API).
- Pinboard-compatible API shim.
- Whole-site shadowing (Kage).
- Multi-user / accounts.
- Browser bookmarklet, RSS feeds.

## Open items to confirm at review

- Exact `vinboard.db` path on the host.
- Port number (`4670` placeholder).
- Whether to reuse the existing `/bookmarks` token or mint a separate one for `/vinboard`.
- Do you have a Pinboard JSON export on disk (API is down), or does import wait until Pinboard returns?
