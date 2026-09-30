# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working with this repository.

**Deep subsystem notes live in `ARCHITECTURE.md`** (repo root, not auto-loaded): the attribution
chain and result colours in full, PDA derivation, dashboards, day pages, drill-down,
home, Entities views, detail pages, special pages, the Boxes sidecar, group lists. **Read the relevant
section there BEFORE changing one of those subsystems.**

## What this is

Build stats from Axway SecureTransport Cloud logs. No build system, tests, linter or package
manager — **bash + awk** pipelines read CSV log exports into small data files; publish scripts
render those into the static HTML site under `docs/`. Requirements: `bash`, `awk`, `sort`, `sed`,
`date`, `jq` (config JSON only). Homebrew mawk is used automatically; keep the awk POSIX.

## The three-repo model — THIS IS THE DEVELOP REPO

The project lives in three sibling repos sharing all code but never data. **develop** (this one)
is where every change happens and holds ONLY the **SAMPLE ESTATE**: synthetic input data from
`bin/sample/generate.sh` (fake orgs, RFC 5737 addresses, `.example` hosts) — deterministic
(seed `AXWAY_SAMPLE_SEED`), committed, regenerable; `bin/sample/verify.sh` asserts a built site
covers every planted scenario. **acceptance** and **production**
(`~/axway/acceptance`, `~/axway/production` — the local checkouts were `runtime-acceptance` /
`runtime-production` until 2026-09-30, user request; github `herbert256/runtime-acceptance`
/ `runtime-production`, private — the GitHub repo names did not change; each serves its `docs/` through GitHub Pages — the two remote
URLs in publish_lib `ENV_SITES_JS`) are the operational twins with the REAL exports of ONE
environment each — **never read, edit or build them from an AI session**; they have no CLAUDE.md
by design. (The old combined `runtime` repo — two environments in one checkout — is RETIRED since
2026-09-11, left in place for Herbert to delete; `bin/acc.sh` / `bin/prd.sh` refuse it.) Code flows one way
via **`bin/acc.sh`** and **`bin/prd.sh`** (no arguments — the runtime checkouts sit BESIDE this repo as `../acceptance` and `../production`; each syncs `bin/` + `assets/` + `.gitattributes` into its checkout, removes CLAUDE/ARCHITECTURE
there, then runs that checkout's `bin/build.sh`; run the two one AFTER the other, never at the
same time — every runtime build pulls and pushes the shared inbox/outbox repo, `~/exchange` by
default, which the build report and every message call "the inbox" / "the outbox", never by
name — 2026-09-12, user request; the `~/cloud` drop folder is gone since the same day); the
sync EXCLUDES the develop-only tooling — `bin/acc.sh`, `bin/prd.sh`, their shared `bin/runtime-lib.sh` and `bin/sample/` — and deletes
stale copies of them in the target, so a runtime `bin/` carries pipeline code only. The committed
`input/.sample-estate` marker gates the generator — absent in a runtime checkout, so it can never
clobber real exports. Local preview: develop at `http://localhost/develop/`, the runtimes at
`http://localhost/acceptance/` and `http://localhost/production/` (web-root symlinks in
`~/www/docs/` → `../../axway/<env>/docs`; `/runtime-acceptance/` / `/runtime-production/` until
2026-09-30).

## Environment (one repo = one environment)

Since 2026-09-11 a checkout serves ONE SecureTransport environment and the three trees are FLAT:
`input/` → `data/` → `docs/` — no `<env>` level anywhere. Gone with it: `AXWAY_ENV` and
`bin/env.sh`, the build scope argument and the parallel env chains, the top-bar env switch and
`bin/build/crosslink.sh` (`data-twin`), the per-env 404 pages and the `.envblock` home, the
acceptance-vs-production pages (`publish-accvsprod.sh`), `migrate-input.sh` and
`make-monitor-example.sh`. Which environment a checkout IS lives in the hand-maintained,
committed, NEVER-synced **`input/environment.txt`** — one line, the display label: `Acceptance` /
`Production` in the two runtime repos, `Sample` here. **`bin/envlabel.sh`** is its one reader
(sourced; `ENV_LABEL`, `ENV_KEY` = lowercased, `ENV_INBOX`, `env_of_name`, `env_inbox_find`):
the label is the TEXT of the top bar's brand/home link (topbar.js `buildTopbar` reads `env:"…"`
from `topbar-data.js`, on every page; "Cloud" on a
checkout without the file — 2026-09-12, the separate label span beside a fixed "Cloud" brand is
gone; the fallback reads "Axway ST" since 2026-09-29) and the home title (`Axway ST reports — <label>`, "Cloud
Reports" until 2026-09-29, user request). **THE ENVIRONMENT SWITCH** (2026-09-12,
user request, later the same day): on a RUNTIME checkout (`ENV_KEY` acceptance|production —
`ENV_KEY`) the brand slot holds the pair **Acceptance / Production** instead — the ACTIVE
site bold and YELLOW (`.envcur`), its link the home page; the OTHER one the SAME PAGE on the
other site, whose host differs per viewer, so its href is computed in the browser, never baked:
`assets/topbar.js` envLinks (the ONE implementation, 2026-09-30 — `window.AXWAY_ENVLINKS` /
`ENVSWITCH_JS` before) reading the four URLs of topbar-data.js `sites` (publish_lib
`ENV_SITES_JS` — localhost → `http://localhost/{acceptance,production}/`, any other host
→ the two GitHub Pages sites) fills every `a[data-envto]` from its `data-root` (the page's
docs-root prefix) + the page's root-relative path + query + hash; the other site answers a
missing page with its own 404 (GitHub Pages serves `docs/404.html`; the local Apache its
default). topbar.js `buildTopbar` renders the pair from `envkey:"…"` on EVERY page (the help pages
and the build report included — there is no baked bar any more). The develop/sample checkout
keeps its single "Sample" brand link. `TB_VER` folds the key and the URLs. `bin/envlabel.sh` derives the runtime
inbox prefixes (Acceptance → `acc*`, Production → `prd*` and `prod*`, case-insensitive; any other
label = the inbox skipped with a note) and names the outbox archives
(`build/st-reports-<key>_<stamp>.7z` and the outbox repo's `st-reports-<key>.7z`; the `~/cloud/`
copy is gone since 2026-09-12); a missing label FAILS the archive step. The docs root holds the site itself: `index.html` (the
home), `404.html` (self-contained; its home link = the path before the FIRST known top-level dir,
a trailing `acceptance/`|`production/` stripped for pre-split bookmarks), `assets/`, `help/`,
`.nojekyll`, `transfer/` (+ `entities/`, `secparams/`, `expired/` — 2026-09-21, user
request: one page per subscription with expired Files, Start · Expired · File name · CoreId, opened
from the Expired cells of **Waiting & Expired**'s Subscriptions table; `waiting-expired.sh`
(expired.sh until 2026-09-30) writes the `.rpt` set into `data/transfer/reports/expired/`; default sort = Expired descending, baked in that
order (an Expired File never has a File page, so the CoreIds are plain — the first-5 links and
their `_expired-files.tsv` list went 2026-09-29 with the File-page rule below); and its twin `waiting/` — the same
day: the Files still staged, Start · Waiting for · File name · CoreId, opened from the Waiting
cells of Waiting & Expired's Subscriptions table (waiting-expired.sh; waiting.sh until 2026-09-30), default sort = Waiting for descending via the
cell's `sortval` (the wait in seconds — the humanized text does not sort); no File-page links
either since 2026-09-29), `server/`, `analyses/`
(+ `xref/`), `reports/` (the Reports start page, 2026-09-29), `dashboards/`, `day/`, `details/` (one subdir per entity type), `files/`
(2026-09-21, user request: the ONE directory of the per-File pages — the failed-File error pages
`<coreid>.html`, the subscription-named error pages `<slug>.html` and the File pages of any
outcome; the separate `errors/` directory is GONE. Only the DATA stays split —
`data/transfer/reports/errors/` + `files/`, because failed.sh's reason-evidence pass globs the
first — and `bin/transfer/publish.sh` renders both sets into `docs/files/`, the errors set last.
**THE PUBLISHED FILE PAGES** (2026-09-29, user request: "docs/files/ — store only the last OK of a
subscription, store only the last 3 errors of a subscription"): `bin/transfer/filepages.sh` (a
build step right after bookend-ok) writes `data/transfer/cache/_filepages.tsv` — CoreId ⇥ kind ⇥
subscription, kind `O` = the subscription's newest Processed File (by END, col 24), `E` = its three
newest Failed Files (by sortkey); Expired / Waiting Files never get a page. It is THE list of the
CoreIds with a `docs/files/<coreid>.html`: failed.sh still WRITES its evidence pages under data/
for every File it classifies (the reasons read them) and pages every set member (an E File the
leg selection did not page gets a File page under `data/…/files/`), `bin/transfer/publish.sh`
renders only UUID-named pages in the set (`fp_keep`; the subscription-named server-log pages
always), and EVERY File-page link tests membership — failed.sh's lists (only kind E links on
Failed Subscriptions), failed-files, unknown-transfers, io-errors, patterns' Last 5, Longest
Files, the all files search flag, and the drills through render_rpt's `data-fp` row attribute
(`fp_has`: the row's drill CoreIds that are in the set; report.js `bindDrill` links a drill
entry's CoreId only when it is listed there). verify.sh asserts docs/files/ = the set.),
(`latest/` — one "Latest files" page per subscription, 2026-09-16 — is GONE since 2026-09-29,
user request, with its Features row "Files → Latest 1000 files": every subscription detail page
with Files carries the browser-built **Files table** instead — ALL its Files, 25 per page with
Previous / Next, built by `assets/sub-files.js` from the all-files data below: the page bakes an
empty `TABLE … subfiles=<slug>` (details_writer.awk `files_table`, above Load by weekday;
render_rpt.awk stamps `data-subfiles` + `data-v` = the build id `AXWAY_BUILD_ID` + `data-nocolmove`,
render_rpt adds the script), the engine loads `search/all/s/<slug>.js`
(`AXWAY_AFS(slug, day ⇥ Files ⇥ shard cksum ⇥ local indices)`, newest first, written by
publish-all-files.sh) and only the day shards the shown page needs; NO detail page gets a
section-9 list any more — the other types' "Latest 100 Files" table went the same day, user
request, with details_lib.sh `addbig`; never bring `latest/` or section 9 back)
the top bar's **Files** link opens the ALL FILES search (2026-09-28, user request; both bar renderers, `linkcheck` and `verify.sh` model it) — the ONE file search since 2026-09-29 (user
request: "keep only search/all-files.html" — the seven `search/file-search-*.html` window pages,
`file-search.sh`, `assets/file-search.js` and the Implementation 1 | 2 tab row are GONE; never
bring them back),
**the ALL FILES SEARCH** (2026-09-27, user request: every File, balancing the user's wait against
the size of docs/) — `bin/analyses/publish-all-files.sh`, its OWN build step after the transfer
publish catch-up (its rows link the files/ pages the failed.sh catch-ups settle; a manual
re-publish must run it too): ONE SHARD PER DATA DAY `search/all/d-<date>.js` (the day's Files
newest first, ~95 B each — name ⇥ HHMMSS ⇥ LOCAL subscription index ⇥ bytes ⇥ 32-hex CoreId ⇥
flag, UPPERCASE flag = the CoreId has a files/ page; each shard carries its own subscription
dictionary, so an old day's shard is byte-identical build to build) + the manifest
`search/all/index.js` (`window.AXWAY_AFX`: the subscription→slug dictionary and per day its count,
subscriptions, shard cksum and a BLOOM FILTER — the name trigrams that hold a non-[0-9a-f-]
character + "#"+8hex CoreId tokens, 8+ bits per item, three hashes; the engine derives its
filter items from the RAW query words, never the Unicode-lowercased ones — the generator folds in
the C locale, and a lowercase like "İ" → "i" + U+0307 asked for a trigram no shard holds, 2026-09-28; KEEP THE GENERATOR AND
`assets/all-files-search.js` IN STEP). The engine loads only the days that can hold a match (a
pasted CoreId: ~its own day), newest first, 4 at a time, stops at the newest 500; the table is
a `rangehook` table (From/To narrows the days; the page counts as a TRANSFER-area page in
render_rpt). linkcheck models the shard links (section 3b), display-rename sweeps the shards,
verify.sh checks that the shards hold every dated File),
`first-seen/`, `coverage/` (the per-use-case `use-cases/` pages and the
`transfers/duration/` record pages went 2026-09-29: a Subscriptions page search and the files/
pages hold them; `switches/` went 2026-09-06 with the home Red/Green switch group), plus
`search/` (`search.html` + `search-data.js`, `all-files.html` + the `all/` day shards — 2026-09-12, user request; at the root before) and `tools/` (`sitemap.html` and the build report `build.html` — 2026-09-12; `whats-new.html` went 2026-09-29, user request, user request; at the root before, the build report local-only 2026-08-29..09-12). `input/` carries
the exports — logs AND the FlowManager JSONs (the real production flows are the HYBRID pattern
generation: no folder parameters, flowdir from `{source,target}_hybrid_participant`; the sample
estate carries both shapes). The manual `bin/flow-manager-synth.sh` stays as the fallback for a
checkout with logs but no config export: it synthesizes the two JSONs from the transfer logs
(one subscription per Transfer Profile, one partner per account).

- `html_head` derives ONE prefix — `base`, back to the docs root — from the css href callers pass
  docs-root-relative (`../assets/style.css` from `docs/transfer/`); the placeholder it bakes is
  `<div class="topbar" data-b=… [data-help=…]>`.
- **The top bar is RUNTIME — on EVERY page** (2026-09-30: the help pages and the build report too):
  pages bake only that placeholder and load `assets/topbar-data.js` then `assets/topbar.js` (the ONE
  bar: buildTopbar, fitTopbar, envLinks) before `report.js` — publish_lib `topbar_scripts` /
  `topbar_placeholder`; `render_topbar` / `render_shared_topbar` / `FITTOP_JS` / `ENVSWITCH_JS` are
  gone, there is no keep-in-step twin. topbar.js `buildTopbar` renders the full bar from
  `docs/assets/topbar-data.js` (pure data, written by `ensure_assets`: the
  NO menu string since 2026-09-30 — the `reports` key went with the Reports pulldown, user request; the
  `monitor:0|1` flag went 2026-09-30 with the Monitor dashboard —
  `coreid:"<url>"`, `env:"<label>"`, `envkey:"<key>"`, `sites` (the four env URLs) — the DATA PERIOD `period` went 2026-09-30, user request (and
  day.rpt's META first/last with it);
  `?v=` stamp `TB_VER` folds the errors / overview hrefs, the template, the label, the key
  and the site URLs).
- report.js has no `pageEnv`/`setupEnvSwitch`; the sessionStorage keys carry no env prefix; the
  `report-area` meta is the area alone.

## The pipeline — bin/build.sh

Runs the whole chain. NO argument (`-h` only; anything else is exit 2 — the acc/prd scope went
with the env split). NO git step — committing and pushing is manual. **EVERY BUILD IS A FRESH
BUILD** (2026-09-28, user decision — `bin/fresh.sh` folded in, the incremental machinery
removed): after the syntax gate and the build lock (`build/.buildlock`, owner PID, a dead
owner's lock reclaimed), `build/` is emptied around the lock, `data/` and `docs/` are RENAMED
into `build/.trash` and deleted in the background, `docs/` is re-seeded from `assets/`, and every
step runs in full from the raw inputs — nothing checks whether an output is up to date (no
`skip_if_fresh`, publish stamps, parse manifests, parser signatures, `ensure_parsed` /
`ensure_config`, mtime-keeping cmp-guards). The ONE thing carried over is `data/.buildstats` (the
build report's input statistics, keyed by name + size + mtime — it can never go stale). The whole
console also lands in `build/build.log`. A script run on its own assumes a complete build before
it (the config caches and both parse caches exist). **SYNTAX GATE first**
(2026-09-27): `bin/check-syntax.sh` (`bash -n` over every `bin/**/*.sh`, ~1 s) runs before
anything is cleared — and in `bin/runtime-lib.sh` before a sync — because /bin/bash 3.2 exits
**0** on a syntax error in a script that set an EXIT trap (an apostrophe in a comment inside a
single-quoted awk program is the usual cause), so a broken report used to vanish from a green
build. **TIMINGS ON THE CONSOLE** (same day): every stage prints `--- N. <label>: Ns`; the
report runners wrap each report in `timed` (sourced `bin/timing.sh` → `TIME Ns <script>`),
`details.sh` prints `TIME Ns details: <phase>` laps, and a background step's TIME lines are
replayed when it is waited for — a runtime build is profiled from its console alone. Writes an HTML run report to
`build/index.html` (also on FAILED, EXIT trap) AND, since 2026-09-12 (user request), the SITE copy
`docs/tools/build.html` — one render with an `@B@` docs-root placeholder, two copies — linked from
the sitemap Tools card (local-only 2026-08-29..09-12; before that, in `docs/`). A checkout without the two flow-manager JSON exports
exits 1 with a hint. **A checkout with the JSONs but NO log CSVs builds fully** (2026-08, the
config-only estate — what a fresh clone is, the exports being gitignored): both parses write
EMPTY-but-valid cache sets and exit 0, every report either renders its zero-row tables (the
roster/entity/cross/UC-status reports — configured rows still show, all orange "configured,
never seen") or skips into the empty-report placeholder; `render_report` pads a split report
short of its `report_tabs` labels with the merge_rpt no-data stub so the group nav's same-label
carry never links a 404, and linkcheck lists an unreachable `help/` page as informational (its
family has no pages then) instead of failing.

The report carries the timings (start → end · duration) in its title — the environment label
before them — and opens with ONE fact row (Input / Cached files / Output), gathered BEFORE the
end timestamp; `count_stats` caches line counts in `data/.buildstats/<key>` under a signature of
the file list. Then the Inbox block (which prefixes this checkout consumes and what the inbox
step did — `build/inbox.tsv`, 3 columns: status ⇥ archive ⇥ detail; the inbox is never named).
(The Input-changes table went 2026-09-28: the wipe of `build/` had left its manifest empty on
every build.) At the BOTTOM (2026-09-12, user request), two
side-by-side tables — Server log files | Transfer log files — Name · First · Last · Lines per
export in `input/`, sorted on First (`log_inventory`, one awk pass per file cached under
name+size+mtime in `data/.buildstats/loginv/`, gathered before the clock). Trap: glob
file lists into an ARRAY, not `IFS=$'\t' read … <<<"$(f $(ls …))"` (word-splits under the
assignment's IFS).

Order, ONE linear chain (the rationale of every position is in the script's comments):
(runtime only) `bin/build/exchange-in.sh` (the inbox, by prefix; it calls
`bin/build/st-reports-update.sh` per archive, which renames the log exports to
`logEntry_yyyy-mm-dd.csv` / `fileTransfer_yyyy-mm-dd.csv` from their first record's date and tells
the JSON exports apart by content — `subscriptions.json` / `partners.json` from the first object's
`meta.href` or keys, whatever they were called — 2026-09-12) → the have-config check (the
RETENTION step `bin/build/archive-old-logs.sh`, which moved the exports older than the past
month out of `input/` into the gitignored `archive/<name>.7z`, was REMOVED 2026-09-28, user
request: every delivered export stays in `input/`; a runtime checkout may still hold the 7z files
it moved) → *parse*: server `parse.sh` in the background
(`AXWAY_SKIP_MENTIONS=1`: tokenize + merge only, started BEFORE the config step since 2026-09-27
— it reads no config) beside `bin/flow-manager.sh` and then transfer `parse.sh`, then — beside
the server MENTION caches (`AXWAY_MENTIONS_ONLY=1 parse.sh`, background slot 2, waited for
before result.sh) and the logon summary (`bin/build/logon-summary.sh`, background slot 1, waited for
right before the server reports since 2026-09-28) — `bin/session-sites.sh` (its re-derive is
`AXWAY_DERIVE_ONLY=1` transfer `parse.sh`), `bin/expire-files.sh`, `bin/bookend-ok.sh settle`
(its `extract` half runs in background slot 3 beside the two before it, 2026-09-29),
`bin/transfer/filepages.sh` (the published File-page set), `bin/build/newest-caches.sh` (the
newest-first cache copies, background slot 3, waited for before details.sh and phase 1),
`bin/build/result.sh`, a server-mention rescan (`AXWAY_MENTIONS_ONLY=1` again) when
`data/server/cache/.rescan-mentions` exists (skipped inside when no cache line holds an appended
name — see BUILD SPEED; a rescan that RAN leaves `data/server/cache/.rescanned`, and `result.sh`
runs a SECOND time — "re-colour after the mention rescan" — so the colours read the caches the
rescan rewrote, 2026-09-28), `bin/build/kaput-evidence.sh` early (its ONLY run: its evidence sidecar makes the
`_srvsubs-map` final on failed.sh's first run, so details.sh runs once) → *report*:
`bin/transfer/reports/details.sh` in
background slot 2 beside transfer phase 1 and the server reports (with `AXWAY_WAIT_FAILED=1`: it
waits — capped at 30 min — for the phase-1 pool's marker `.phase1-pool-done` in the transfer
reports dir before reading what phase 1 writes, 2026-09-28), then — right after the server
reports since 2026-09-29 — dashboards ∥ day in background slot 2 (the Monitor dashboard's
`monitor.sh`, run in the foreground before them, went 2026-09-30, user request; their
inputs are all final there), then transfer phase 2 and analyses, the dashboards + day reports
waited for right before the dashboards publish. After the server reports: `bin/build/reason-boxes.sh`
(the box-reason sidecar, beside details.sh), then — after details.sh's wait — `failed.sh catchup`,
THE REASON CATCH-UP: the server-failing rows' Reason column and the lists' red-run columns,
which read `_subs-boxes.tsv` and the phase-1 peer `_red-run.tsv`; it keeps the File reasons, the
evidence sidecar, the drill / File pages and the `_srvsubs-map` content, the intermediates in
`data/transfer/reports/.failed-state/` — proven identical to a full run — so failed-files.rpt,
failing-reasons.rpt and unknown-transfers.rpt are final at their first run (2026-09-30, the lean
round: the catch-ups ran after the publishes until then) → *publish*: detail pages ∥ transfer
(EVERY transfer page, docs/files/ included, rendered ONCE — the `firstpass` / `catchup` publish
modes went 2026-09-30; the detail pages' ONLY render), then partner-groups, server, analyses
(every analyses page, once — its `catchup` mode went too), the all-files search
(`bin/analyses/publish-all-files.sh` — its rows link the files/ pages), dashboards, day → `bin/build/publish.sh` (index pages + the home, reads every area) →
`bin/build/display-rename.sh` → (runtime only) `bin/build/st-reports-archive.sh`.

Dependency rules: transfer reports before server and analyses reports; dashboards + day after both areas;
`bin/build/publish.sh` last of the publishes (the area publishes clear the dirs its index pages
live in). A script that ran twice in one build only to skip the second time runs ONCE now:
`bin/build/kaput-evidence.sh` (not in the server-reports pool),
`details.sh`, failed-files.sh, unknown-transfers.sh and failing-reasons.sh (no catch-up re-runs since
2026-09-30); `failed.sh` runs twice on purpose (full in phase 1, `catchup` after reason-boxes — the
evidence ↔ box-reason cycle).

**BUILD SPEED (2026-09-27/28, the "prd build" analysis — production 6:34 → 3:44 min in 14 rounds,
then → ~3:18 in rounds 15-27 (2026-09-28); every round byte-identical on a develop fresh build).** What a change must not break:

- **Background slots**: `bg_step_start/bg_step_wait`, `bg2_step_start/bg2_step_wait` and (since
  2026-09-29) `bg3_step_start/bg3_step_wait` — ONE step per slot in flight; a background step's `TIME` lines are replayed at its wait. Moving a step
  into a slot needs the proof that nothing between start and wait reads its outputs or rewrites
  its inputs (the comments at each call say what was checked).
- **The server parse** (`bin/server/parse.sh`): a file above its fair share (total/NJOBS, ≥ 64 MB;
  `AXWAY_TOK_SPLIT` bytes overrides) is cut at RECORD boundaries (`csv_cuts`: the quote count
  from line 2 is even) into several chunks; chunk parts are per date-HOUR (order-preserving
  names) and merged in ~3 groups per core; the merge's skip filter strips the sort key itself
  (`MERGE_SKIP_PROG` — never `cut(1)`: macOS cut ran ~7× slower than awk on the ~6 GB) and counts
  the kept rows. The tokenizer's `quoted_split` fast path splits an all-quoted record on `","`
  and PROVES the split exact (quotes = 2 ends + 2 per separator + inner ones; inner quotes must
  come in adjacent pairs, which a `","` inside a value never leaves) — anything else walks.
  The tokenize reads no config and no rename map (only the mention scan folds names), which is
  what lets it start beside the config step. Modes: default = tokenize + merge + mentions,
  `AXWAY_SKIP_MENTIONS=1` = tokenize + merge only, `AXWAY_MENTIONS_ONLY=1` = the mention caches
  over the existing cache (the transfer-ended session list is computed once per cache and reused
  by the rescan).
- **Byte-range scans** (`bin/ranges.sh`: `rng_lo/rng_hi/rng_off/rng_feed`; a job owns the lines
  STARTING in its range): subsets, session-sites, expire-files, bookend-ok, failed.sh passes 1
  and 2, result.sh's session vote, the mention rescan. A scan whose result depends on line ORDER
  across parts needs an order-preserving merge (result.sh's vote shows one); `unknown-entities`
  scans line-aligned byte slices (NW = the core count, capped at 6).
- **Server-cache subsets** (`bin/server/subsets.sh`, `srv_subset NAME` in `bin/server/lib.sh`): the
  RARE message families of uc1-status, the POLL families (`poll`: uc3-status, remote-poll,
  no-remote-dir, no-remote-files — one subset since 2026-09-30; the old uc3 / remote-poll pair were
  72 lines apart), connection-diagnostics (+ site-failures), ssh-sessions, deploy-errors (it keeps
  the poll marker: its UC3 poll-recovery clear reads those lines), routing-errors and event-queue,
  copied once per cache. Every line a consumer acts on must contain one of its fixed-string
  MARKERS — change a consumer's patterns, change its markers. Two RULE subsets sit outside the
  marker gate: `noninfo` (every line whose level is not I — top-messages, error-timing,
  error-reasons, failure-flows, pesit, and the Top view / errors-day drill lines) and
  `io-errors`. The same pass writes the COUNTS table `subsets/counts.tsv` (date · hour · level ·
  component → count, plus per-date first / last time over the whole cache; `srv_counts`), which the
  server Top view and errors-day read instead of a full pass. A missing subset set (no
  `subsets/.done`) falls back to the whole cache (`srv_counts` builds the set). **Measured, not
  worth it (2026-09-30):** an `inbound` subset for inbound-connections (+1.0 CPU-s for 0.3 saved)
  and a `day` marker subset for day_srv (+2.6 for 1.1) — only long, rare markers pay; the gate
  regex runs on every character of every line. Each consumer's markers are ONE regex, built in
  BEGIN (the letters of a `~` marker as `[xX]` pairs, the rest escaped with the gate's set), tested
  once per gate-matched line (2026-09-30, lean round 3b: the per-line `index()` loop plus a
  `tolower($0)` copy was two-thirds of the pass; −55 % at scale).
- **The mention scan's MESSAGE MEMO** (2026-09-30, `ENT_PROG` in `bin/server/parse.sh`): a
  record's hits are a function of its message and the config alone, so a repeated message replays
  its recorded `hit()` calls in order instead of being tokenized again (at most `MEMO_MAX` = 150k
  distinct messages per job; the console line `TIME … mentions: memo replay N of M records` shows
  the repetition rate). A change to the matching must keep hits a pure function of `$5` + the
  config, or the memo must go. (The inline 3-char gate of round 3 gave nothing — the memo paid.)
- **The TRANSFER-ENDED sessions** (`_sessions-ended.tsv`) are collected by the full parse's MERGE
  (`MERGE_SKIP_PROG`, per group, first seen, joined in group order, deduped) since 2026-09-30; the
  mention step's full-cache `grep -F` is only the fallback for a cache without the list. The merge
  test is gated (`index($0, TAB literal)` before a field split, the direct `$6` test when a skip
  list split the fields) — testing `$6` ungated cost +0.70 CPU-s at 30×.
- **Newest-first cache copies** (2026-09-30): `bin/build/newest-caches.sh` writes
  `data/transfer/cache/newest/_files.tsv` (col 6 desc, CoreId asc, `sort -s`) and
  `newest/_transfers.tsv` (legs by their File's start desc, CoreId asc, stable), in slot 3 after
  filepages.sh, waited for before details.sh and phase 1. The top-10 ring readers take them through
  `transfer/lib.sh use_newest_caches` (a copy only when newer than its canonical cache, else the
  canonical one): details.sh (legs), entities.sh (both), duration.sh + duplicate-files.sh (Files)
  — the rings fill with their newest Files first, so later Files hit the cheap addtop reject
  (details −21 %, entities −14 %, duration −24 %, duplicate-files −25 % at production scale,
  byte-identical, for 2.3 CPU-s of copying; the old "−5 %, the sort costs as much" predates the
  per-key drill rings). ORDER-SENSITIVE readers (dwell-time, recovered-files, file-type, retry,
  resubmissions, size-dist, failure-heatmap) keep the canonical caches. The copies keep the
  canonical basenames: readers dispatch on `FILENAME ~ /_files\.tsv$/`.
- **Key-aligned and line-aligned slices** (2026-09-28, `bin/ranges.sh`): `grp_cuts FILE N` cuts a
  file SORTED on its first TAB field into byte slices that never split a run of equal keys (blank
  included), `grp_par FILE OUT N CMD…` runs CMD per slice in parallel (slice on stdin, `GRP_PART`
  in its env, `GRP_N` afterwards for per-slice side files) and joins the outputs IN ORDER — so a
  per-key-group filter equals its whole-file run. `line_cuts`/`line_par` = the same over plain
  line boundaries, for per-LINE filters. Users: the transfer derive (propagation; ONE pass for
  the no-subscription drop + skip list + the newest leg start; ONE pipeline per slice for the
  collapse + config join + still-under-way filter — `_files.tsv` is written once; the in-progress
  leg filter) and the server parse's transfer-ended sessions grep.
- **Big writes go through `cat`** (2026-09-28): mawk — and sort — write a regular file in 4 KB
  chunks, and on this Mac's APFS volume ten such writers at once cost several times the work in
  kernel time (10 × 41 MB: 0.92 s wall / 5.5 s sys at 4 KB, 0.06 s at 64 KB). A PARALLEL step
  writing a big file pipes it through `cat` (`grp_par` does it for every slice; the transfer
  tokenize groups and intermediates, the server merge groups, the mention scan's per-type lines
  and the server subsets — an awk writing several files per part uses one `print | "cat > …"`
  per file and `close()`s them in END); the server tokenize part splitter
  is a perl `syswrite` splitter (`PART_SPLIT_PL`; production sort/split 107 → 26 part-s). Reads
  are fine. Many small page writes are not the problem (piping those through `cat` was slower).
- **Never walk a numeric RANGE per key** (2026-09-28): the logon cadence (`bin/logons.sh`) and
  uc2-status walked every MINUTE between a key's first and last minute (~36k per key on 25 days)
  to find the few that are set, and every median walked each gap value up to the largest — the
  minute sets now also keep their distinct minutes per key (count + list, filled where the set is
  filled) handed out sorted (`sortmins`, a numeric quicksort; the minutes are integers, so the
  list is exactly what the walk produced), and a median picks over the sorted DISTINCT values
  (`medpick`). New cadence/percentile code follows that shape.
- **The all-files search** builds its day shards per day-aligned slice (`grp_par`); the global
  subscription dictionary (first appearance, newest day first) is computed by a pre-pass first.
- **`slugify` has a fork-free fast path** for input made only of ASCII letters, digits, space,
  `_` and `-` (the set spelled out — a bracket range would follow the locale collation); anything
  else keeps the `tr | tr | sed` pipeline, the reference. KEEP THE TWO IN STEP.
- **This Mac is an Apple M5: 4 performance + 6 efficiency cores.** A 10-way CPU-bound pass runs
  at well under 10× one core (production tokenize: ~6 µs per record in parallel against 1.7 µs
  alone on a P core) — measure parallel speedups in parallel, not one process on an idle box.
- **details.sh**: `aggregate_files` runs as TWO type groups (`AGG_ONLY` in `details_lib.sh`); state
  shared by every type (gmax, the last failure per subscription) is computed in full by each
  group, per-type state only for its types; the stream sort orders the union.
- **The appended-names mention RESCAN is skipped when it cannot change anything** (2026-09-28,
  `mention_rescan_needed` in `bin/server/parse.sh`): each scan records the name set it matched
  (`data/server/cache/.mention-names`, type ⇥ name); when result.sh's marker is the only reason to
  rescan, no name was removed, every new name is a subscription or host, and no cache line holds
  one of them or a rename alias folding to one (case-insensitive substring, `line_par`), the
  caches on disk ARE the rescan's output (a name only adds hits on a line containing it). A
  change to the mention matching (name_hit, the host test, the rename fold) must keep that
  property or drop the skip. Production: 11 → 1 s.
- **The server-log -> transfer steps run once each** (2026-09-28): the transfer `parse.sh` no
  longer calls session-sites / expire-files / bookend-ok at its tail (nor takes the
  `AXWAY_SKIP_*` flags) — `bin/build.sh` runs the three in order after the parse barrier, and
  session-sites' re-derive (`AXWAY_DERIVE_ONLY=1`) is the parse's only nested call.
- **Publishing**: the files/ pages render in RUNS (four per pool slot); `render_rpt` takes a page
  TITLE from line 1 with a builtin read outside `docs/details/` — every writer puts TITLE on line
  1, and `META dirclass` exists only in the detail-page .rpt files (a writer adding it elsewhere
  must extend that test). `segment_rpt` is a HYBRID (2026-09-28): the bash loop for a .rpt up to
  500 lines, above that `SEGMENT_AWK` (one awk pass printing `$'…'` assignments that are eval'd —
  the bash loop was quadratic, 6.4 s on a 21k-row report); the bash version stays the reference
  and the fallback. KEEP THE TWO IN STEP (identical on all 13.5k production-size .rpt files).
- (**pda-entities.sh** — its five dimensions as parallel jobs, 2026-09-28 — is folded into
  `entities.sh` since 2026-09-30, like the other four classic writers.)
- **2026-09-29 round (prd 197 → ~184 s; six timed prd runs with a 1-s CPU sampler):** the
  appended-names RESCAN is gone from the normal run — `result.sh discover-hosts` appends the
  transfer-log-discovered HOSTS right after the transfer parse (during the server-parse wait;
  nothing before result.sh reads `base/_hosts.tsv`), so the mention scan, still started the
  moment the server parse ends, matches them in its one pass; `result.sh discover` after
  session-sites re-checks the hosts against the pristine roster (`colour/_pristine_hosts.tsv`)
  and appends the discovered SUBSCRIPTIONS (never earlier: the session-sites re-derive reads
  `base/_subscriptions.tsv`) — a change or an append drops the rescan marker, the old path
  stays the safety net. Proven byte-identical on a scratch clone with a planted discovered
  host and one with a discovered subscription. `unknown-entities.sh` scans line-aligned byte
  slices, buckets date-sorted (its latest-mention tie rule `TIEMOD` went with the sidecars'
  stamp columns, the second 2026-09-29 audit — the sidecars carry names only). The tail: the all files search + dashboards + day publishes
  run in slot 2 (beside the two publish catch-ups until those went, 2026-09-30).
  **Tried and reverted — do not retry:** the server reports that read only the server cache
  (topview, errors-day, error-*, event-queue, config-defects, pesit, top-messages,
  ssh-sessions + subsets) in the background beside the server-log -> transfer steps, plain
  and under `nice -n 15`: those steps are CPU-bound parallel scans, not idle time (the ps
  CPU samples overstate the free capacity on the 6 E-cores) — session-sites 8 → 12-14 s,
  the mention scan 20 → 25 s, the build +6..+11 s. The outbox push is network time (5 s,
  once 14 s) — judge a run by its stages, not only its wall.
- **2026-09-29 round 2 (prd 186 → ~165 s; seven timed prd runs):** every stage line carries
  `[cpu Ns]` (`times` of the step's own subshell — `step_cpu`; a background step's from its
  subshell), and a pooled page render of 2 s or more prints `TIME Ns render <area>/<report>`
  (pub_run, `$SECONDS` — no fork per page). The wins: failed.sh's catch-up mode (6 → 0 s); the
  publish catch-ups side by side (gone altogether 2026-09-30: the Reason catch-up moved into the
  report stage, so each publish renders once), the redundant sidecar step and the redundant detail-pages
  re-render dropped; dashboards + day started right after the server reports; overview.sh's
  slot pass in the background beside its seen pass (22 → 15 s) with every series split by ONE
  `read` loop (`series_vars` — the 42 `printf "$ser" | awk` pipes per block went) and the
  seen-curve walk over the entities SIGHTED per slot only; both tokenizers' `sv()` probe with
  `index()` before the regex gsub (~5 % of the server tokenize). THE EINTR FIX: bash 3.2's
  `printf` of a big string into a `$(…)` pipe dies with "write error: Interrupted system call"
  when a SIGCHLD lands on the blocked write — `render_card` / `resolve_ch` (dashboards + day)
  hand their HTML back in variables (`RC_OUT` / `RCH`); keep big strings out of `$(…)` pipes.
  The run's shape: the parse window ~41 s (the build waits ~16 s for the server parse), the
  server-log -> transfer steps ~23 s, phase 1 ~25 s, the server reports ~31 s — all four
  CPU-saturated — then a ~25 s publish tail and the archive (7z 5 s, push 9-16 s, network).
  **Measured, no gain — do not retry:** a copy-free `is_noise` and dropping its SMTP scan
  (the tokenizer is at mawk's floor); `index()` guards and a line-numbered `mseen` in
  unknown-entities (its cost is the per-mention `addline` bookkeeping); overview's durations
  in an ARRAY instead of the growing string (slower); 7z with 32 MB LZMA2 blocks (the 7z
  5 → 4 s, the archive 17 → 19 MB, the push lost more).
- **2026-09-29 round 3 (after the audit; prd ~150 → ~147.5 s over five timed runs, 147-149;
  every change byte-identical on develop and on an 8x SCALED scratch copy):** the build is
  CPU-BOUND nearly throughout (~1,000 CPU-s on ~7 effective cores; a 1-s `top` sampler
  mapped onto epoch-stamped console lines shows 96-100 % busy in every stage but the first
  5 s, result.sh and the archive), so moving work between stages only trades seconds — only
  LESS CPU shortens it. What went in: `unknown-entities.sh` computes its KNOWN sets once up
  front (the merge's rules, moved) and the workers skip known names; its host scan runs only
  on a message holding one of the UNKNOWN configured hosts (an `index()` prefilter — exact:
  a matched token is a substring of the lowercased message) — 71 → 55 CPU-s. `subsets.sh`
  gained marker subsets for deploy-errors and routing-errors, a rule subset for io-errors
  (its regex behind `index($0, "rror")` — case-insensitive gate markers doubled the gate's
  cost) and the level-rule `noninfo` subset (~2 % of the cache) that top-messages,
  error-timing, error-reasons and failure-flows read; it runs BESIDE the pool now
  (`bin/server/reports.sh`: the whole-cache jobs queue first, the 12 subset consumers after
  its wait) — server stage 235 → 196 CPU-s. bookend-ok's extraction is its own mode
  (`bookend-ok.sh extract` / `settle`) in a THIRD background slot (`bg3_step_start/wait`)
  beside session-sites and expire-files (the settle step 10 → 3 CPU-s on the chain).
  result.sh prints sub-second `TIME … result:` laps and builds HOSTLEGS over `grp_par`
  slices; the build report escapes / groups digits with bash builtins (`esc_v`, `hnum_v`)
  instead of ~400 forks per render. **Measured, no gain — do not retry:** the same
  `index()` prefilter for the whitelisted IPs (~100 IPs: slower than the regex walk);
  a parallel offset-write assembly of `_parse.tsv` (`cat` copies ~7 GB/s — the merge's tail
  is its last groups). **Still open:** logon / ssh-crypto / uc2-status / uc4-status /
  auth-activity each scan the whole cache for SSH families (20-45 % of it — per-consumer
  subsets lost, 2026-09-27); ONE shared union subset might pay, but it needs an exact marker
  audit of six consumers and production-like SSH data to prove (the sample's SSH mix is
  thin).
- **Test at production SCALE, not only on the sample**: the develop estate is small per entity and
  light on SSH lines, so a per-entity sort or a per-logon cost can look free there (the detail
  percentiles cut 28-44 % on 8x the sample legs and nothing on the sample). Replicate
  `_files.tsv` / `_transfers.tsv` with prefixed CoreIds, or the SSH lines of `_parse.tsv` with
  suffixed sessions, in a SCRATCH copy of develop — never in develop itself.
- **Archive**: `7zz -mx4 -m0=LZMA2:d=128m:c=128m` (2026-09-28: -mx4 is the hash-chain match
  finder; on a production-size site 16.8 s / 30.0 MB with the former -mx5 64 MB → 6.0 s / 32.4 MB).
  The outbox `git pull` runs in the background beside the 7z; a rejected push pulls and retries
  once.
- **Profiling**: every step prints `TIME Ns <what> [cpu Ns]` laps (bin/timing.sh `timed` + the
  per-script `_…lap` helpers, incl. the tokenize part timings) — a runtime build is profiled from
  its console alone. A BACKGROUND step replays only its `TIME` lines at its wait, so a console
  statistic from one must be a `TIME` line (the tokenizer's "tokenizer paths" counters — records
  and MB per path: production 37M records / 20 GB, 96 % fast split, 71 % noise). EVERY build is
  fresh (2026-09-28, Herbert's decision — no incremental builds at all), so the unchanged exports
  are re-tokenized every time (~33 s, the critical path).

## Running individual stages

Every script takes no arguments and resolves paths from its own location. Three stages — **parse →
report → publish**. Per tool set, `parse.sh`/`lib.sh`/`reports.sh`/`publish.sh` live in
`bin/<area>/`; report scripts in `bin/<area>/reports/`, plus cross-area ones in
`bin/analyses/reports/` that source `../../<area>/lib.sh`. **Which `lib.sh` a script sources says
where its DATA goes, and that area's publish renders its PAGE** — except the `SUBS_GROUP_REPORTS`
members (publish_lib: rendered into `docs/analyses/` whatever their area — Failed Subscriptions,
UC status, Polling, …), the cross-reference pages (transfer data, `docs/analyses/xref/`), Entity
Search (`docs/search/search.html`) and the All files search (its own step → `docs/search/`). All
paths are centralized in `lib.sh` (derived from `LIB_DIR`, its own location): `INPUT_DIR`,
`CACHE_DIR`, `REPORTS_DIR`, `CONFIG_DIR`, the cross-area cache/report vars, `PARSED`, `FILES` —
don't reintroduce `../../data`-style paths or path arguments.

```bash
bin/build.sh                          # everything, always fresh: wipe build/ data/ docs/, seed assets/, build (no git)
bin/build/linkcheck.sh                # verify: 0 broken links, 0 orphan pages (MANUAL gate — build.sh never runs it)
bin/transfer/parse.sh                 # -> _transfers.tsv + _files.tsv (AXWAY_DERIVE_ONLY=1: re-derive from _transfers0.tsv);
                                      #    a manual parse must be followed by bin/session-sites.sh, bin/expire-files.sh,
                                      #    bin/bookend-ok.sh (the build does) — else Expired reads Waiting, settled Files Failed
bin/transfer/reports.sh [phase1|phase2]
bin/transfer/reports/details.sh [TYPE]   # TYPE = ACC SITE LOGIN HOST LGC PTN APP DOM BL
bin/server/parse.sh                   # -> _parse.tsv (+ per-entity mention caches; AXWAY_SKIP_MENTIONS / AXWAY_MENTIONS_ONLY)
bin/server/reports.sh
bin/analyses/reports.sh; bin/dashboards/reports.sh; bin/day/reports.sh
bin/transfer/publish.sh               # …and the other per-area publishes; then:
bin/analyses/publish-partner-groups.sh
bin/analyses/publish-all-files.sh     # the all-files search (day shards + index); after the transfer publish
bin/build/publish.sh                  # index pages + the home + the group rows/tags; run LAST
bash -n script.sh                     # syntax check — there is no test suite
```

**Manual re-publish gotcha**: `publish-partner-groups.sh` and `publish-all-files.sh` run OUTSIDE
the per-area publishes; skipping them after a publish sweep leaves their pages missing or stale.
The group rows and `← Group` tags come ONLY from `bin/build/publish.sh` (`apply_report_groups`), so
run it after any area publish. The DISPLAY-RENAME sweep
(`bin/build/display-rename.sh`, `input/rename.txt` — presentation renames applied to the
RENDERED pages as the build's last page-touching step; caches/.rpt keep the real values,
slugs/links untouched) also runs only in `bin/build.sh`: a manually republished page shows real
values until the next build.
**Column order is a runtime feature** (2026-09-05, report.js `initColOrder`): the columns of a
movable table are reordered by dragging the rows of the `cols` picker (bottom-right of the table;
header dragging was REMOVED 2026-09-06, user request — do not bring it back); the order is stored
in localStorage under the report key + the built header labels
(`colorder:…`), re-applied FIRST in `init()`, restored by the Reset link at the foot of the picker. Every cell of a movable table carries `data-ci`, its BUILT column
index — anything that addresses a column by number (RECALC tokens, `data-noagg`/`data-pct`, the
group column, the total label, the remembered sort, which now stores the built index) goes through
`cellByCi`/`ciOf`/`colByCi`, never through `cells[n]`. A spanned total label is split on the first
move. Not movable: a grouped header band (GHEAD), `data-heat`,
Entity Search, `dayrows`, spacer columns, any spanned DATA row; report.js also honours
`data-nocolmove`, but render_rpt.awk has no `nocolmove` TABLE modifier yet — add one if a report
must opt out. New column-addressing code must use the built index.

**Five more runtime features (2026-09-05, report.js)**: the column PICKER (`cols` hotspot bottom-RIGHT of the
last visible cell of the TOTAL row, else of the last visible data row — `colHostCell`; that cell is
rewritten by the recalc/totals paths and changes with every sort/filter/page, so `replaceHotspots`
re-attaches `table._colTools` after each of them plus a mouseover safety net — attached LAST in init(),
after the data-orig snapshots; the Reset link at the foot of the picker restores order + columns (the
↺ hotspot is gone, 2026-09-06); csv keeps the last header cell; hidden cells carry the `hidden` ATTRIBUTE, never a class — the recalc paths restore classNames;
stored `colhide:…` beside `colorder:…`; the CSV export skips hidden cells) · MULTI-KEY sort (`sortKeys`
takes `[{ci, dir}]`, shift-click adds a key, arrows carry `<sup>` ranks; `sortTable(table, col, dir)`
is the position-based wrapper, `resort()` re-applies a table's keys; saveSort stores "ci:dir,ci:dir")
· RELATIVE dates (`setupRelDates`, mouseover delegation, tooltip only). (The DARK theme — its ◐
toggle, `bin/darken-css.awk` and the head script — and the Ctrl/Cmd+K COMMAND palette went
2026-09-29 with the Report finder, user request; never bring them back.)
COPY icons on ids (`setupCopyIds`, 2026-09-06): a ⧉ after every UUID in td/th/code/.coreid-item/dd/li,
added LAST in init() (after the data-orig snapshots), re-added by a MutationObserver for content the
page builds later and by a mouseover net after a restore; csvCellText skips `.cpid`. **CoreId LINKS to
SecureTransport File Tracking** (`addCoreIdLinks`, 2026-09-07, user request): the same pass, run just
BEFORE the copy icons, makes every UUID a link (new tab) to the URL template of
`input/coreid-url.txt` (`@COREID@` = the id; baked into topbar-data.js as `coreid:"…"` by
`ensure_assets`, folded into `TB_VER`); an id that already IS a link (File / error /
record page) keeps it and gets a `↗` (`.stgo`) after it instead. A checkout without the file
gets no links. Row links and drills ignore anchor
clicks, so the id opens the platform and nothing else.

**Iterating on HTML/CSS**: edit `assets/style.css`/`assets/report.js` (NOT the docs copies) and
run `bin/build.sh` — it clears+seeds docs/ and re-renders everything. A MANUAL per-area publish
reads the docs/assets copies, so after an assets/ edit copy the file over (or run the build); a
publish always renders. The `.rpt` files stay on disk after a build, so the publishes alone
re-render the site.

**No incremental machinery** (2026-09-28, user decision: only fresh builds). Every step runs in
full: `parse.sh` (both areas) tokenizes every export (no manifest, no parser signature, no merge
into an old cache, no parse lock — nothing parses concurrently any more), every report writes its
.rpt (no `skip_if_fresh`), every publish renders (no `data/.publish` stamps), `flow-manager.sh`
rebuilds the config caches (no early exit). There is no `ensure_parsed` / `ensure_config`: a
report reads the caches `bin/build.sh` built before it. A writer never compares content to keep an
mtime (the former cmp-guards) — except the two under `input/` (`bin/ip.sh`'s map, the rename
snapshot), whose files outlive the build. Do not reintroduce a freshness check: a script that
must not repeat work inside one build gets an explicit mode or a single call site instead (the
server parse's `AXWAY_SKIP_MENTIONS` / `AXWAY_MENTIONS_ONLY`, the transfer parse's
`AXWAY_DERIVE_ONLY`, failed.sh's `catchup` mode — the publishes' `firstpass` / `catchup` modes went
2026-09-30 — kaput-evidence runs once). Within-build DEPENDENCY guards stay:
`ensure_logons` builds the logon summary only when it is not there yet (the background step
normally has), `srv_subset` falls back to the whole cache without `subsets/.done`, and the
appended-names mention rescan is skipped when it cannot change anything. (The one tracked
build output outside `docs/`, `bin/build/whats-new-history.tsv`, went 2026-09-29 with What is new
— user request "remove /tools/whats-new.html"; never bring the page or its git-log history back.)

## Tool sets

**`bin/transfer/`** — reports over the transfer logs (`fileTransfer_*.csv` as the inbox names them
since 2026-09-12; the sample estate still writes `transferLog_*.csv` — every reader globs `*.csv`).
**`bin/server/`** — a parser + report scripts over the server logs (`logEntry_*.csv`). **`bin/analyses/`** —
configured-vs-seen analyses from the transfer outputs + config caches (no parse of its own).
**`bin/dashboards/`** — the graphical Overview. **`bin/day/`** — the per-day pages.

### bin/flow-manager.sh — the pre-parse config step

Extracts from `input/flow-manager/{partners,subscriptions}.json`: `data/flow-manager/base/`
— the 11 entity lists (`name⇥direction⇥result`: `_accounts _logins _hosts _white _subscriptions
_profiles` + the derived `_logicals` (the FlowIDs condensed into logical flow groups,
`input/logical.txt` pins honoured), PDA `_partners _apps _domains` and `_bl` (2026-08-31, user
request: the subscriptions.json `tags` entries starting with `BL`, kept verbatim, PLUS (2026-09-18,
user request) every BL NUMBER in a subscription's DESCRIPTION — any key matching `/desc/i` anywhere
in the object, `\bBL[ _-]?[0-9]{3,}` case-insensitively, normalised to `BL<digits>` so the same
number from a description and from `input/BL.txt` is ONE entity; both are export BLs, so neither
lands in the "Added BL" sidecar — a full entity,
LAST in the Logical/Partners/Domains/Applications group everywhere it renders; a File belongs to
a BL through its SUBSCRIPTION); result filled later by the
two build steps) — and `data/flow-manager/xref/` — the pair caches: every pair of the eleven
items BOTH WAYS (95 files since 2026-09-29 — the 17 unread mirrors dropped; unconfigured = empty — `_profiles-logicals` doubles as the FlowID →
Logical MAP every report attributes a File’s profile column through, `_subscriptions-bl` as the
subscription → BL tag map, and its sidecar `_subscriptions-bl-added.tsv` carries the
`input/BL.txt` rows the `tags` do NOT hold — a `+` after the number in the Subscriptions page's BL
column; the separate “Added BL” page went 2026-09-29), plus `_subscriptions-patterns`, `_subscriptions-flowdir`
(out|in|relay), `_subscriptions-ucderived` (2026-08: the use case DERIVED for a non-UC-named
subscription from flowdir × the pattern's one partner verb — out+pull=UC2, out+push=UC1,
in+push=UC4, in+pull=UC3; both/neither verb = no row; consumers: the detail Features "Use case"
row and every use-case-gated consumer — the UC1–UC4 status rosters, the UC3 clean-poll keep
and its clears, missing-cronjobs, the detail pages' twin rules; until 2026-08-31 most
read the name prefix alone and silently dropped the hybrid flows),
`_partner-group{s,-why,-accounts}` and `_templates.tsv` (optional export). It also forward-resolves the configured hosts into
`input/ip/`.

Downstream reads the caches `flow-manager.sh` writes in the build's config step (no early exit —
it rebuilds every build); a missing cache degrades to an empty list. The DIRECT JSON readers, for
what the caches do not carry (cron expressions, Active codes, folders, credentials):
`bin/analyses/publish.sh` (the Subscriptions page), `polling.sh`,
`uc3-polling.sh`, `missing-cronjobs.sh` and `details.sh` (the Active codes
via `bin/subscription-active.jq`) — each on the SKIP-filtered copies in
`data/flow-manager/filtered/` when `flow-manager.sh` wrote them (`FM_CONFIG_DIR` in publish_lib,
`FM_INPUT_DIR` in the area libs; the Subscriptions page's skipped rows read the raw export).
**PDA derivation** is owned here too and is LOGICAL-BASED (2026-08-30, user request): the
three-part Logical name `D_A_P` gives part 1 = domain, part 2 = application, part 3 = partner
token; partner tokens merge (same host / shared whitelist IP / whitelisted host IP — every merge
DERIVED since 2026-09-01, the curated alias file having become a part replacement; details in
ARCHITECTURE.md), and every partner/app/domain pair cache is composed
through the FlowID. The account-name split machinery, the subscription-name fallback and the
prune are RETIRED. The **Logical derivation** (FlowID families → three-part group names; a `-`
inside a part marks parts the derivation combined, which is why Logical names are never
separator-folded) is owned here too — it runs FIRST, the PDA pass consumes it. The coverage TSVs
`data/transfer/reports/coverage/*.tsv` are the materialized product (`ensure_pda_tsvs`).

### bin/dashboards/ and bin/day/

`bin/dashboards/reports.sh` → `overview.rpt` (the Monitor dashboard — `monitor.sh` →
`monitor.rpt` → `dashboards/monitor.html`, the top-bar Monitor link and the `durfit` chart kind —
went 2026-09-30, user request: its page was empty on both runtimes; never restore); `publish.sh` renders the Overview — 5 KPIs + one hero graph with alternate
views, all chart type `slots`, drawn client-side by `docs/assets/slotchart.js`.
`bin/day/reports.sh` writes one `.rpt` per calendar day (both logs); its publish renders KPIs →
hero → problem lists → facts → six Top-5 tables. Both run after the two areas' reports; the
UC-status stacks and cumulative "seen" views carry strict invariants — see ARCHITECTURE.md before
touching them. Consumers reading topview Date cells strip the `@{href=…}` cell attr first; the
transfer `topview.rpt` per-day table: Date, then the groups Files · Recovered (Automatic · Manual) ·
Resubmit (Ok · Error) · Transfers · State as ROW fields 3-18, Volume field 19 (the First / Last
columns and the partial-day marks went 2026-09-30, user request), see ARCHITECTURE.md.

## Architecture

Compute and presentation are separated. `parse.sh` owns tokenizing; each report script is a small
bash wrapper feeding one `awk -F'\t'` program that emits a **`.rpt` descriptor** — never HTML. The
publish scripts (sharing `bin/publish_lib.sh`) are the generic renderer.

### The .rpt line protocol

TAB-separated, directives `TITLE / DESC / INTRO / ALERT / WARN / NAV / STAT / LOGCARD /
TABLE / HEAD / GHEAD / KIND / RECALC / ROW / TOTAL / NOTE / LINK / SUMMARY / FOOT / META`
(`KEYWORDS` went 2026-09-29 with the Report finder, its one reader; merge_rpt ignores a stray one; `SUBTITLE` and ALERT's 3-cell link form went the same day — no writer). `GHEAD` = an optional group-banner `<th>` row ABOVE `HEAD` (cells may lead
`@{colspan=N,class=…}`); pairs with the `gsep=` TABLE modifier, which draws the matching dividers.

- Empty `TABLE` heading → no `<h2>`. `INTRO`/`NOTE` support `**bold**` and `[[sub/name]]`
  entity detail links (slugmap-resolved at render time like a cell's `alink`; no entry → the
  plain name). **NEITHER RENDERS ON A REPORT PAGE** (2026-09-13, user request: a report explains
  itself on its HELP page only) — `render_report` sets `RPT_NOPROSE=1` and render_rpt.awk skips
  the two directives; the report's HAND-WRITTEN help page (`assets/help/<slug>.html`, compact
  bullets — see the `docs/help/*.html` bullet under Publishing) carries those facts instead, so a
  changed INTRO/NOTE means an updated help page; the Reports start page shows the
  one-line `DESC`. The drill and record
  pages (files/ — the error and File pages, the record and value pages, the detail pages) keep their INTRO — there
  it states facts. `ALERT` → red banner (the
  RUNTIME register); `WARN` → amber (the CONFIGURATION register). `STAT⇥class⇥value⇥label` → info
  box. `LOGCARD⇥date time⇥message` → timestamped monospace card. `LINK⇥url⇥text` → below the
  table. `NAV` is emitted by publish_lib when splitting a
  multi-table report into tabbed pages (entry state: 0 link · 1 current · 2 disabled).

**THE GROUP MEMBER BUTTONS GO BETWEEN THE TITLE AND THE PROSE**: on a page belonging to a group,
the row of buttons for the group's members is the FIRST row, directly after the `<h1>`, above the
report's own tab / view rows and the intro; a row with NO group members sits under the intro.
Since 2026-09-29 every group row comes from `apply_report_groups` (see "Report groups and menus")
except the Entities combined row and the cross pair selector, which their renderers write
(`_hdr_with_nav`); `_inject_before_table` places the Failed Subscriptions view row under the From/To.

**TABLE modifiers**: `wide` · `group` · `nosearch` · `nofilter` (full-period semantics) ·
`drill=UNIT` · `totaltop` · `datereset` (always open at the full range) · `seenrows` (green =
logged, red = configured only) · `restint` (`@data:res` paints the whole row; the SERVER pages get
it automatically — see below) · `nosort` · `rangehook` (2026-09-27: the rows are built by a page ENGINE that takes the From/To range through a window hook — report.js counts the table date-aware and calls every function on the `window.AXWAY_RANGEHOOKS` list; paired with `nofilter`; its one user is search/all-files.html) · `sxs`
(side-by-side; `sxs=ID` — a different id starts a new flex row) · `esearch` · `fold=` · `noagg=` ·
`sort=` · `startempty` (first paint empty until searched) · `heat` (hour ×
weekday heatmap, re-tinted by quartile on a date change) · `pct=` (per-column % recompute spec) ·
`gsep=` (0-based columns that start a column group — pairs with `GHEAD`) · `pager=N` (client-side
pagination) · `zerohide=M` (on a NARROWED range, hide a data row whose re-aggregated bucket
metric M sums to 0 — a "Recovered 0" row says nothing; the full-range restore brings it back;
the recovered-files tables) · (`seenmode=`, `seenword=`, `topsel=N`, `period=`, `pfnoun=` and
`anchor=` went 2026-09-29 — no writer emitted them) · `subfiles=<slug>` (the subscription Files table engine) ·
`tab=KEY` (consecutive tables sharing KEY stay on ONE tab page of a split report, stacked and
all visible — `switch=` shows one at a time; the UC3 tab of UC status, 2026-09-05) ·
`keephead` (keep the heading
even on a page's first table) · `rowlink` (the WHOLE row opens its target — the row's own
`@data:href` if it carries one, else its first link; report.js `setupIndexRows`).
A page with ZERO date-aware tables
renders no From/To and neither restores nor persists the shared per-area range.

**Column KINDs**: `text num numfailed numprocessed numok numerr numwarn bar file mono acct site
login host lgc ptn app dom bl clines clinks pre prose` (`failed` / `processed` / `numsep` / `ip` / `lines` went
2026-09-29 — no writer used them; `numok` / `numerr` TINT like numprocessed / numfailed without
counting as the row's OK / Error cell for the drill binding; `prose` = a SERVER-LOG MESSAGE cell — since 2026-09-30 it never wraps, see "Server-log lines never
wrap" below).
Entity KINDs link to the detail page, the
slug resolved through that dir's comprehensive `_slugmap.tsv` — no map entry, no link.
`clines` collapsible (3+ lines fold behind `⋯`), `clinks` the same with every line a link
(`href|label` — patterns' Last 5); `pre` = a raw log
LINE kept verbatim in `<pre>` (the failed-file error pages) — logged spacing preserved, NO wrap
and no width cap, so one logged line is one rendered line and the page scrolls sideways.

**Direction columns show the CONNECTION/MOVEMENT pair (`out/in`) wherever both sides exist**; the
per-LEG aggregates (one row per direction) legitimately show one value. **A column headed exactly
`Direction` renders LOWERCASE site-wide** — `dirfold()` folds ONLY the direction vocabulary
(keeping the server PeSIT `ST → CFT` values intact); the three hand-written Direction tables fold
themselves. Raw DATA is never folded (`_transfers.tsv` col 2 stays `Inbound`/`Outbound`).

A ROW/TOTAL cell may lead with `@{class=…,colspan=N,link=…,alink=…,href=…,nolink=1,title=…}`
(`alink=<sub>/<name>` resolves through that sub-dir's slugmap at render time; `title=` = the
cell's hover title, 2026-09-20 — the Polling page's Active column — its words carry no `,`,
the attr list splits on it). A ROW may carry
`@data:NAME=VALUE` cells (emitted as `data-NAME` on the `<tr>`). Scripts emit values UNESCAPED
(the renderer escapes); keep TAB/CR/LF out of cells. A RAW value that can begin with `@` (a file
name) goes through `lit()` — the empty block `@{}` in front keeps it literal (2026-09-29 audit F07). Tables size to content; a wide table WIDENS THE
PAGE (2026-09-08, user request — `.tablewrap` and `.sxs` are no longer scroll boxes: their bottom
scrollbar was off-screen on a tall table, so the browser's own horizontal bar now does the job; the
fixed top bar keeps its right icons in view).

### Client-side date re-aggregation (RECALC + @data:buckets)

An all-period aggregate table emits `RECALC` (one token per column) and each ROW carries
`@data:buckets=date:m0:m1:…`; report.js `recalcTable` re-aggregates for the From/To range and
restores exact originals at full range. Tokens: `-`/`k` keep · `sN` sum · `hN` humanBytes(sum) · `%N`
share · `pN.M` 100·sumN/sumM · `aN` per-day avg · `c` day count · `dN` days with N>0 · `qN.M`
humanDur(sumN/sumM) · `xN` humanDur(max) · `tN.M` throughput · `bN` bar vs column max · `BN` bar
of per-day average · `rN` POSITION by COLUMN N (not a bucket metric) descending, `rN.a` ascending,
`rN.z` zeros last. Reports without a date dimension per row MUST use this; per-day tables just
use a Date column; capped top-N tables re-aggregate over the shown rows only.
**The shipped encoding is compact** (2026-09-30, the lean round): at render time `data-buckets` /
`data-durdays` name the day by its 0-based index in the page's `report-dates` list (a date not in
the list stays literal), a bucket value `0` ships empty and an originally empty one as `~`
(render_rpt `benc`/`denc`, `-v rdates=$CUR_DATES`); report.js `expandPayload()` decodes them first
in `init()`, so recalc, rank, heat and aggDurDays read the dated form unchanged. The WRITERS keep
emitting the dated form.

`rN` is the one CROSS-ROW token (`rankCols`, a second pass after the cells are rewritten): a
position is a statement about the whole population, so the Ranking report renumbers it over the
rows the range left standing — a filtered value beside a full-period rank would be a lie. It
re-reads the value column's own token numerically (`recalcNum`), never the formatted cell, and
mirrors `details_lib.sh`'s rules exactly (competition ranking; 0 % errors sorts LAST, `.z`), so
the full-range restore lands back on the baked numbers.

**Persistence.** From/To persists per AREA (sessionStorage, `report-area` meta). Search and sort
persist per REPORT (`report-key` meta = the report basename) — EXCEPT the Entities pages, whose
sort is shared across the nine entities (localStorage, 1-hour sliding expiry). Default sort: a
first column holding dates opens DESCENDING (a page default — a stored user sort wins). URL
overrides, each persisting like a user action: `?axway_sort=COL[:DIR]`, `?axway_search=` (kept in
sync via `history.replaceState`; the EMPTY form CLEARS a remembered search — every link out of a
Boxes-page box explanation carries it), `?axway_date=` (one day, or a RANGE `from..to` — each
bound snapped to the page's own date list), `?axway_hero=`, `?axway_row=` (mark + page to +
scroll to that entity's row, and open at the FULL range without touching the stored one — the
detail pages' Ranking rows link this way).

**Drill-down**: rows/cells carrying `data-coreids[-failed|-processed|-retry|-resubmit]` expand to the outcome's 10
most-recent transfers (SHIPPED COMPACT since 2026-09-30: render_rpt ships a drill list that repeats
an earlier one on the same row as `="<key>"` (`coreids-*`) or `="<n>"` (`drill-cell-*`), and a File
drill list with undashed CoreIds and — on a row whose first cell is a date — entries without that
date, marked `#` (`fenc`, which self-checks and keeps the original when the decode is not exact);
report.js `expandPayload()` undoes both first in `init()`; a reader of drill attributes in `bin/`
must allow `=` / `#` — verify.sh's rauto/rmok check does), built by the shared `COREIDS_AWK` helper; the server reports use
`@data:loglines` (`LOGLINES_AWK`, a bounded insert by "date time" — the exports are newest-first
within a file). **A drill entry links its File page only when the File HAS one** (2026-09-29 —
the 2026-09-21 rule "the first File of a red / orange drill cell links its page", with
`bin/build/drill-files.sh` and `_drill-files.tsv`, went with the published File-page set):
render_rpt stamps `data-fp` = every CoreId of the row's SHIPPED File drill lists (a held
coreids-failed / -processed list the splice drops contributes none; `drill=transfer` / `log`
tables none) that is in `_filepages.tsv`, and report.js `bindDrill` links ANY listed entry to
`files/<coreid>.html`, whatever the cell (second 2026-09-29 audit — only the first entry under a
red cell linked before, half the payload was dead), linkcheck models those edges.
Full detail in ARCHITECTURE.md.

### Transfer parse — _transfers.tsv

`bin/transfer/parse.sh` tokenizes `input/transfer/*.csv` once into
`data/transfer/cache/_transfers.tsv` (`$PARSED`). The CSV tokenizer is hand-rolled in awk
(quoted commas work on any awk). One 25-column row per record, sorted by CoreId then Direction
(col 25, 2026-09-08 = the export's own Application field, raw — "none" on the empty outbound ssh
probes the parse-time skip drops; NOT the derived application entity):

```
 1 coreid          the logical-transfer key      13 sortkey (YYYYMMDD+time)
 2 direction                                     14 jdn
 3 status (raw)                                  15 duration (ms integer, -1 if none)
 4 account (@… stripped)                         16 remote_host (LOWERCASED)
 5 login                                         17 av_bucket (ICAP classification)
 6 site (the subscription)                       18 end_time (raw)
 7 action_by                                     19 secparams (raw)
 8 file (Local Filename, CSV field 15)           20 mode (BINARY/ASCII/unknown)
 9 size (validated int)                          21 profile ("UNKNOWN" if none)
10 protocol                                      22 resubmitted (true/false)
11 date_iso (ccyy-mm-dd, "" if invalid)          23 transfer_id (CSV field 29)
12 time                                          24 session_id (CSV field 30, raw) —
                                                    the TECHNICAL connection of the leg;
                                                    the UC2/UC4 same-connection proof
```

Column 8 is the real file basename (CSV field 10 "File" holds the account name on outbound rows —
not used). Raw columns are carried verbatim so each report keeps its own fold/parse. Col 16: an
IPv4 on an OUT-side row is replaced by the configured endpoint it maps to
(`input/ip/ip-hosts.tsv`); an IN-side row KEEPS the raw source IP. Which side a row is on,
and which endpoint an address belongs to, are decided by the row's SUBSCRIPTION first and its
account only as a fallback (2026-08-31): an account may be configured BOTH ways *and* with
SEVERAL hosts, so asked first it mislabelled a hybrid account's inbound rows and — being
ambiguous — poisoned the endpoint vote for every flow of a multi-host account. No reverse DNS. The
source CSV field indices (both logs) are in ARCHITECTURE.md ("Parse reference"); timestamps are
`MM/DD/YYYY HH:MM:SS.mmm`. Date arithmetic uses awk Julian-day helpers (`jdn()` etc.), never
`date`; `dur_ms()` sums the compound Duration values into ms, `humandur()` formats back. Exact
duplicate record lines are dropped (tokenizer AND post-merge pass), so overlapping exports cannot
double-count.

### The attribution chain (parse time, in this order)

Seven passes (0–6), fully specified in ARCHITECTURE.md; the order is deliberate:

0. **RENAME FOLD** (2026-08) — a logged subscription **and profile** name is folded to the name the CONFIG uses
   NOW, at the one canonicalisation point in `parse.sh` (where the `_SCP_` tail is stripped and the
   `<subscription>_<PROTO>_SERVER_<partner>` extension folded — the server reports and the server
   parser's mention tokenizer strip/fold the same two shapes, 2026-09-05), via
   `input/renames/subscriptions.tsv` (`bin/renames.sh`, `rn_canon`). A log line keeps the
   name that was current when it was written, so an export that renames a flow would otherwise
   split its history in two — the configured half joining nothing and going orange, the logged
   half arriving as an unknown entity. The map is derived from the EXPORTS, never from the names
   (the 2026-08 rename dropped a doubled tail and folded `-`→`_`: deriving it by rule got 366 of
   545 right, 37 WRONG, 142 underivable); `fm_snapshot_renames` diffs each export against the
   previous run's `flowId`→name snapshot, so a rename records itself. Both files live under
   `input/` — the previous export's names are irreplaceable once it is overwritten, the
   `ip-hosts.tsv` argument. APPEND-ONLY, and a pair that would merge two flows or reuse a current
   name is REFUSED — and so is a pair whose OLD name the export STILL CONFIGURES (2026-08-31
   audit): a flowId is NOT unique per subscription (one flow, several subscribers — eight on the
   production `STMT_EXPORT_GLOBEX` flow), and join(1) over a shared key emitted the cartesian
   product, whose off-diagonal rows all read as renames (`_01 → _02`, `_03 → _01`, …) and rotated
   every File of the account onto the neighbouring flow. The diff now joins only keys unique on
   both sides, and `_rn_prune` drops such pairs from the existing maps on every config run,
   naming each on stderr. Every build's parses fold the logged names by the maps as they stand.
   A name renamed TWICE folds to its newest name (`rn_canon` follows the chain A → B → C, at most
   16 hops; `_rn_record` accepts the B → C continuation of a recorded A → B and says so), and
   `rn_canon_pfx` never folds a name the config still carries (`RENAMES_CONF` =
   `base/.configured.tsv`) — 2026-09-28.
   **The PROFILE has its own map** (`profiles.tsv`): the profile is what the
   reverse config fallback attributes a leg by, and an unmatched one cost 7,743 CoreIds their
   subscription (the no-subscription skip then dropped ~4.6% of Files). The SERVER side folds too
   — `parse.sh` when matching message tokens to the configured set, and
   `unknown-entities.sh` via **`rn_canon_pfx`**, since the server log TRUNCATES names: a fold
   there happens only when every completion of the truncated name agrees, never on a guess.
   Without it every renamed flow reads as an unknown subscription on the server side (a
   phantom "Missing subscriptions" row beside the real entity). `rn_canon_pfx` prefers a completion the
   token stops at a NAME-PART boundary of (`_`, or the whole name) when those agree — the ST short
   form `UC4_ODV-ARE-YARDI` is exactly `UC4_` + the first half of `UC4_ODV-ARE-YARDI_ODV-ARE-YARDI`
   while `UC4_ODV-ARE-YARDI-DWH_…` merely shares the prefix. Still a boundary rule, never a guess
   about content.
- **The estate is PRUNED of withdrawn discoveries** (`result.sh` `prune_withdrawn`): the colour
  step APPENDS entities the transfer log reveals, and nothing removed one whose evidence went
  away — the row settled as ORANGE, a phantom "configured but never seen" flow that is not
  configured at all (this is how the caches once grew to 696 rows for 568 flows). A row
  survives when it is in `base/.configured.tsv` (the snapshot `flow-manager.sh` takes BEFORE
  the step appends) or backed by real transfer data. (Until 2026-09-27 the server-log BLUE
  step appended too; it is gone with the blue result.)
1. **Blacklist** — `input/blacklist.txt` (a policy file like the others, COMMITTED in develop; TSV
   `<field>⇥drop|keep⇥<value>`) BLANKS
   platform-internal values (row kept), read only through the sourced `bin/blacklist.sh`.
   **The EXTENDED transfer-site fold**
   (2026-09-01, user report): ST logs some flows as `<subscription>_<PROTO>_SERVER_<partner>` —
   not a configured name, so the flow was attributed to NOTHING, its `_files.tsv` movement
   (col 17) stayed empty and the outcome rule (which matches the movement against the last leg's
   protocol) could never say Processed: **every one of those files read Failed** though both legs
   processed cleanly (production: 418 files over 13 flows). `site_extfold` folds the value onto
   the LONGEST configured name it extends at a name-part boundary, and only when the remainder is
   that server/client comm-profile shape — a different flow whose name merely starts with a
   configured one stays a logged-but-unconfigured subscription. The server reports fold the
   same shape. **The configuration outranks the site
   keep rule** (2026-08-31 audit): a clean, rename-folded site value that names a configured
   subscription (`base/.configured.tsv`) is kept whatever its
   shape — the production hybrid flows carry no UC prefix, and the `^UC` shape test blanked their
   correctly logged subscription on every row; the shape test applies only to values the config
   does not know. The literal `UNKNOWN` remote host is blanked in code (a placeholder, not an
   endpoint). **report.js has no client-side
   blacklist net and must not gain one** — a config-side leak is filtered in `bin/flow-manager.sh`.
2. **CoreId-group propagation** — blanks fill from the first row in the group that carries a
   value; the unpropagated stream stays as `_transfers0.tsv`, the input of the derive-only
   re-run (`AXWAY_DERIVE_ONLY=1`, session-sites.sh). **RE-KEYED LEGS go back first**
   (2026-09-29, user report — a production partner's pickups on `UCx_<account>` — now `Unknown` — while their Files
   read Waiting): ST can lose a download's session cycleId mid-transfer (W `No session cycleId
   for file … SENT will not get reported!`) and end the SAME transfer twice — `error` under the
   File's CoreId (the one it STARTED under), `ok` under a FRESH one; the transfer log keeps one
   row per transfer id, the later end wins. Ok last → a lone siteless profile-UNKNOWN leg under
   the fresh CoreId (→ `Unknown`); error last → the leg stays in its File as Failed (bookend-ok
   settles it). `bin/session-sites.sh` learns `cache/_rekeys.tsv` (lone CoreId, transfer id,
   original CoreId) from the JSON bookends: lone legs only, the transfer id's bookends name
   EXACTLY two CoreIds, the start line is under the other one. The derive's `K` records move the
   row back (`K D` drops it, `K G` = the original group rebuilt and pre-sorted by `sort`, so awk
   compares no strings — BSD awk collates by locale); guards: original CoreId in the raw cache,
   holding no row of that transfer id, no chains. The sample plants it on the `STMT_EXPORT_GLOBEX_nn`
   flows (tag `rekey`).
3. **Config fallback** — reverse (profile's `FlowIdentifier` → subscription, disambiguated by the
   pesit-leg direction; never guessed) then forward (site → account/profile).
4. **XREF single-value fallback** — unanimous vote of the populated fields' one-value maps; HOST
   is never filled but votes.
5. **FLOWDIR fallback + SESSION JOIN + `Unknown`** (2026-08; the fake `UCx_` name until 2026-09-29) — a still-siteless group
   takes its account's single subscription on the movement side its legs unanimously imply
   (partner protocols move the file the way the connection points, pesit the opposite; validated
   with zero counter-examples over 181k groups). Failing that, the **SESSION JOIN** asks the
   SERVER log which flow the leg's own connection executed: `_transfers.tsv` col 24 and
   `_parse.tsv` col 6 carry the same session id, and that session's route lines name the
   subscription ST itself ran — **`bin/session-sites.sh`** learns the `session⇥subscription` map
   (`cache/_sessionsites.tsv`; rename-folded, configured names only, a session naming two flows
   maps to neither) and re-derives when it learned something; the derive additionally requires
   the group's mapped sessions unanimous and the flow configured for the group's account when
   that list exists. Failing that too, the **INBOUND-LEG TIE-BREAK** resolves the
   delivered-file-plus-echo shape (Inbound + Outbound partner-protocol legs, no pesit vote —
   the movement conflict FLOWDIR abstains on): the Inbound leg outvotes the echo and the group
   takes the account's single configured movement-in subscription (39-0 validation; the
   session-joined groups agree 7-for-7). When even that fails, the group keeps the site
   **`Unknown`** (2026-09-29, user request: "drop support for UCx on the complete site, give
   those the value Unknown for subscription, do not show Unknown rows in any subscription based
   table, add a new report Unknown transfers in the Errors group" — the synthetic
   `UCx_<account>` names before). `Unknown` is NO subscription: never in the base cache
   (result.sh `discover_logged` skips it), no entity / detail page / slugmap entry / per-
   subscription Files data, no First seen, not on not-in-flow-manager, no observed pairs (it
   colours no account / login / host). See "The Unknown subscription" below.
6. **NO-SUBSCRIPTION / HTTP / PROBE SKIP** — a CoreId with neither site nor ACCOUNT anywhere, or any
   http leg, is dropped from both caches; its raw CSV lines go to `_skipped.csv`. So is (2026-09-08,
   user request) the **EMPTY OUTBOUND SSH PROBE**: a CoreId whose ONE record is Outbound + ssh +
   size 0 + Application "none" (col 25; empty counts the same) — no file moved, so it must not
   become a one-legged Failed File; the Skipped report lists it under its own reason. Distinct from
   the `input/skip.txt` SKIP LIST (same layout as the blacklist — fields TAB- or whitespace-separated since 2026-09-09: a space-typed `any contains X` used to fall to the bare-token form and match nothing, which is how a skipped production subscription stayed on the site; — but DROPS THE WHOLE RECORD — and, on the config side, the account, subscription or comm-profile LOGIN whose name contains the value, 2026-09-03;
   read only through the sourced `bin/skiplist.sh`; matched cache rows → `_skipped.tsv`).

Reports skip blank entity values, or show a parenthesized/`-` pseudo-value where
the transfer must stay countable.

### _files.tsv — the logical-transfer cache

A **logical transfer** = all records sharing one CoreId (commonly 2–7 rows). `parse.sh` collapses
`_transfers.tsv` into one row per CoreId, 27 columns (col 25 = the File colour, col 26 = "1" when a
leg FAILED, col 27 = "1" when a leg was RESUBMITTED — 2026-09-29: the per-File retry / resubmit
facts every report reads instead of re-scanning `_transfers.tsv`; `$FILES`; legend `data/transfer/cache/_files.txt`, written by the parse):

```
 1 coreid                                    12 dest_site (last row)
 2 outcome (see below)                       13 profile ("" if none)
 3 account (first/Inbound row)               14 login   ) each the first row
 4 date_iso                                  15 host    ) that carries one
 5 time                                      16 connection  (config join)
 6 sortkey                                   17 movement    (config join)
 7 jdn                                       18 app         (config join)
 8 size (the file once = max row size)       19 domain      (config join)
 9 dur_ms (wall-clock span)                  20 partner     (config join)
10 rows                                      21 wait_ms (UC2 pickup wait)
11 file (first row's Local Filename)         22 expired (deletion timestamp)
                                             23 settled (the ok bookend's stamp,
                                                bin/bookend-ok.sh; "" otherwise)
                                             24 end (when the transfer ENDED:
                                                the latest leg end, 2026-09-12)
                                             25 colour (green / orange / red)
                                             26 "1" = a leg FAILED
                                             27 "1" = a leg was RESUBMITTED
```

- **col 9** = last row's start + its duration − first row's start (includes store-and-forward gaps
  and retry idle). UC2 exception: the partner-wait between staging and collect legs is EXCLUDED
  (it is col 21).
- **col 16** = the CONNECTION side (`in`/`out`/`""`); **col 17** = the FILE-MOVEMENT direction
  (col 12 joined on `xref/_subscriptions-flowdir.tsv` — the ONE place that join is done); they
  diverge on pull flows.
- **col 20** = the file's SUBSCRIPTION via `_subscriptions-partners.tsv` when it names ONE
  partner (a both-partner subscription abstains), else its host via `_hosts-partners.tsv`, else
  the account's unambiguous org (a two-group account abstains) — every map AMB-guarded
  (2026-08-31). **col 13** is the profile of the row that donated col 12, so one row never names
  two flows (a relay CoreId has legs on two).

**Outcome (col 2), the last-leg rules**: **Waiting** = ≥3 legs ending on the staging leg
(Inbound+`routing`) whose own status is Processed (a FAILED staging leg is Failed — 2026-09-28) —
a UC2 file staged, not collected; a later export with the collect leg
re-flips it. **Processed** = ≥2 legs, last leg Outbound+Processed AND matching the movement (out →
`ssh`/`ftp`/`ftps`, in → `pesit`); deliberately no bytes condition. **Failed** = everything else
(incl. a lone leg). **Expired** = a Waiting file whose staged copy the nightly File Maintenance
sweep (~11 days) deleted before pickup — server-log-only evidence, so **`bin/expire-files.sh`**
joins those lines onto Waiting rows (col 22 = the timestamp; the deletion list in
`_expired.tsv`; a build step after session-sites). **SETTLED BY BOOKEND** (2026-09-09, user
request, **`bin/bookend-ok.sh`** right after expire-files): a **Failed** File whose LAST leg's own status
is a failure (2026-09-28: a File Failed for a STRUCTURAL reason — last leg Processed, wrong
movement or leg count — also carries an ok bookend and must not flip) and whose last leg's transfer id a server-log
`"Transfer end logged."` JSON record ends with `"status":"ok"` + `"direction":"Outbound"` (an ok
bookend of an earlier leg of the same File does not count; the JSON's own `coreId` is NOT required
to match — it can differ from the transfer log's CoreId for the same transfer, the transfer id is
the key), and about which NO
Error/Warning line classifies to a reason (`flip-reason.awk` over the legs' sessions and the
CoreId/transfer-id mentions), reads **Processed** — the platform ends one transfer twice when the
client tears the connection down after the bytes went (ok on its fresh connection, error on the
dropped one; the transfer log keeps the error). Col 23 = the ok bookend's stamp (the separate `_bookendok.tsv` list
went 2026-09-29 — no reader); extracts cached in `_bookends.tsv` / `_reasonlines.tsv`; settled rows are
re-evaluated every run. The JSON bookends therefore stay in the server cache (out of the noise
list since 2026-09-09) but the mention scanner skips them.

**OUTCOME POLICY: Waiting counts as OK, Expired counts as ERROR** on every report: Error =
(`=="Failed" || =="Expired"`), OK = otherwise (never `== "Processed"`). The waiting report and the
detail State column distinguish the states. **The entity RESULT COLOUR parts company with the
policy on EXPIRED** (2026-08): an expired-last flow is ORANGE, not red — a staged UC2 copy the
partner never collected and the sweep deleted is a PICKUP problem, nothing errored — so it leaves
the red lists (Failed Subscriptions, the Error views) while the Expired report, the Expired box and every Error count still carry it.
It is red only when something ELSE says so: `result.sh` keeps it a candidate for the
after-last-transfer rule, so expired PLUS a newer server-log Error/Warn is still red.

`_files.tsv` takes the FIRST row with an account and the LAST row with a site.

**STILL UNDER WAY** (2026-09-15, user rule): right after the collapse, `parse.sh` REMOVES every
File that STARTED less than 10 minutes (`INPROG_MS`) before the newest leg start in
`_transfers.tsv` — from `_files.tsv` AND its legs from `_transfers.tsv` — since its legs may not
all be logged yet (a lone first leg would read Failed). `_transfers0.tsv` keeps the rows, so the
next parse brings them back complete. An undated File stays.

### Which cache a report reads

Counting `_transfers.tsv` rows over-counts (~3x) and double-counts volume.
**Count/volume/failure/timing reports read `$FILES`**; **per-row dimension reports read
`$PARSED`** and count rows, their count column labelled **"Transfers"** ("Files" is reserved for
per-CoreId counts). The nine ENTITIES reports share one Summary/Detail layout counting distinct
CoreIds (login / subscription / remote host join `$PARSED`→`$FILES` deduped per
`(entity,CoreId)` — per-entity counts can sum to more than the distinct total; `entities.sh`).

**PARTNER = UNION attribution**: a File counts for EVERY partner of its subscription (col 12 on
`xref/_subscriptions-partners.tsv`) unioned with col 20 (alone it misses both-partner files, empty
by abstention). **APPLICATION = the same union via the SUBSCRIPTION** (col 12 on
`xref/_subscriptions-apps.tsv` ∪ col 18 — the FlowID spine, 1:1; until 2026-08-31 it rode the
ACCOUNT, and a hybrid production account serving many flows credited every File of it to every
application the account touches). LOGICAL = col 13 through `xref/_profiles-logicals.tsv` ∪ the
subscription's logicals; BL = the subscription's tags. ONE implementation: `bin/pda-union.sh`
(`SP_AWK`: `sp_union`/`ap_union`/`lg_union`/`bl_union` + the `SP_MAP`… maps, 2026-09-29) —
every File-attributing consumer sources it; never hand-copy the join (the few copies left carry a
comment naming why their rule differs); the parse fills cols 18/19 from the
subscription first, the account map only when unambiguous. Domains stay single-valued (part 1 of
the logical flow name — parse col 19 keeps one).

### Server parse — _parse.tsv

`bin/server/parse.sh` tokenizes `input/server/*.csv` (handling quoted fields with embedded
newlines) into `data/server/cache/_parse.tsv` — 6 columns: date, time, level (I/W/E),
component (T=TM P=PESITD S=SSHD; ADMIN/AUDIT dropped), message (multi-line buffered into one
row), **session** (CSV field 18 — the SAME connection id `_transfers.tsv` carries in col 24, so a
file's legs and the server lines of their connection join on it; `""` where the export wrote
UNKNOWN — no session at all on PESITD/SSHD records, ~96% of TM records carry one; the parser
walks to field 18 for it, ~15 % of the tokenize). The exports are newest-first within a file; the cache is CHRONOLOGICAL (the per-date merges sort it). Runs in
parallel (per-file tokenize+sort, then per-date merges — byte-identical to a global merge); also
builds the per-entity mention caches — per-name dirs `{accounts,subscriptions,logins,hosts}/`
(`<name>.tsv` + `<name>_err_warn.tsv`; NO flat mention list since 2026-09-29 — the last one,
`_subscriptions.tsv`, went with its reader, the Cleanup backlog) (last 25 rows + the last 10 Error AND the last 10 Warning lines, merged newest first — one
ring per level since 2026-09-28, so a burst of warnings never pushes the errors out; hosts match
case-insensitively).

**The NOISE filter** (2026-08, the `NOISE`/`is_noise` list at the top of `TOK_PROG`): message
PREFIXES the platform logs for every session and every leg — the session Created/Removed
bookkeeping, the Universal Agent acknowledgements, the
Push/Pull-AS helpers, the SubtransmissionStatus writes, the internal session counter, every
`Reporting event …` (the Sentinel notification-command trace), the `UNKNOWN` placeholders, the
`Stopped ar-`/`Shutdown ar-` worker notices, the `Error during test connection` lines (a
MANUAL admin-UI test, not a flow: an E-level line that landed in the remote host's err/warn ring
and counted as evidence against every subscription configured for that host) and the Advanced
Routing route-execution bookkeeping `AR0011:`/`AR0032:`/`AR0076:`/`AR0077:` (a sandbox created
and purged, a route start and a route finish per run — 1.12M records, 18% of the cache) — dropped at tokenize time. 12.8M of 18.56M acceptance
records, 69% of the export, and the parse got FASTER for it (1:50 → 1:11). **The DAEMON TAG is stripped before
matching**: each daemon stamps `[Ssh Default] ` / `[Pesit Default] ` / `[Ftp Default] ` /
`[Http Default] ` in front of the message (4.4M of the pre-strip 9.4M rows carried one), so an
anchored rule would otherwise match the bare form and miss the tagged twin of the same line. Only
a `<Word> Default` tag is stripped — the odd `[server #173 @…]` lines keep their text — and every
rule then covers both forms, which is why no rule names a tag.
Deliberately NOT `input/skip.txt`: a skip rule archives its records for the Skipped report, which
is the cost this filter exists to avoid; every parse applies the list as it stands. The server
reports that read those lines went with them (2026-08: `concurrency`, `event-feed`,
`transfer-outcomes`, `file-freshness`, `advanced-routing` — none of the colours, mention caches or
unknown-* seeds rested on them). The failed-file error
pages lost their JSON id join with them and now rest on the SESSION join, plus an ANY-MENTION id join
(2026-08-24: every bare UUID in a message looked up against the page's CoreId + transfer ids —
the `.stfs` segments never matched one; what it reaches is the `Error while resubmitting transfer
with id` line on the ADMIN session and the AR0086 post-processing delete on the route's).

`reports.sh` runs every server report in parallel (rosters come from the TRANSFER reports; a
missing roster is `exit 1`). The five
`unknown-*` reports are ONE script, `bin/server/reports/unknown-entities.sh` — a map-reduce whose
known sets read the TRANSFER PARSE CACHE directly (cols 4/5/6/16), never a roster (roster-based
sets oscillate); `bin/server/reports.sh` runs it in its pool. Its `data/unknown/*.tsv` sidecars are the SERVER-LOG SIGHTING LISTS the colour-free
safety checks read (Entity Search / Cross reference: an unconfigured sighting is red). Transfer reads nothing from the server REPORTS — except failed.sh (went-kaput's `_kaput-evidence.tsv`, which is why went-kaput runs early) and publish-details.sh (the UC status .rpt files + `uc2-pickups.tsv`, the verdict and Pickup information).

### Result colours (green / red / orange)

**THE BLUE RESULT IS GONE** (2026-09-27, user request: "remove the /transfer/seen-in-server-log.html report and all use
of it, the 'blue' status must be gone"): the fourth colour — "seen in the server log
only, never transferred" — with its step `bin/build/seen-in-server-log.sh`, its report, the
Entities +Server scope and Server view, the home Transfer/Server columns and "including server
log" switch, the First seen both-logs view, the UC1/UC3/UC4 `server - …` statuses (those flows
are plain **not seen**), the Boxes "Server log only" and "Failing polls" boxes, the Overview's
blue seen curve and the detail pages' server-only evidence card. A server-log mention alone never
makes an entity seen or coloured; the UC3 cannot-connect RED rule below stays (its clean-poll
GREEN twin went 2026-09-28). `data/blue/` is
`data/colour/` (result.sh drops the old directory). Never reintroduce a server-log-only colour.

**Entities DISCOVERED in the transfer log** (2026-08, `result.sh` stage 0, `discover_logged`): a
subscription (or remote host) can carry real transfers and still be absent from the FlowManager
export — a flow configured after the export was taken. The entity reports list it, so the Entities
view has a row the base cache knows nothing about and the home figure disagrees with the page
footer. The transfer log therefore DISCOVERS entities: they are appended with an empty result
and coloured normally. The rosters MIRROR the reports that
list them: subscriptions = every `_files.tsv` col 12; hosts = every LEG host (`_transfers.tsv`
col 16) of an OUT-connection File (`_files.tsv` col 16) — exactly the rows the
Entities writer lists, so raw INCOMING addresses are never invented as entities (2026-09-28: the
File's first host, col 15, alone missed an outbound leg to an unmapped raw address and a production
Entities view listed it untinted, home 105 vs page 106). That population is materialized once as
`colour/_hostlegs.tsv` (host ⇥ File sortkey ⇥ outcome ⇥ subscription ⇥ File end) and read by the
discovery, the prune, `host_own_unpaired`, the observed host pairs and the hosts orphan_red. A discovered host has no configured subscriptions, so the rollup would call it orange —
`host_own_unpaired` colours a host absent from the pair cache by its own last file instead
(`white_own`'s rule; every configured host is in the pair cache, so nothing else moves). The
append drops `.rescan-mentions` so the server mention scan picks the new names up.

The third column of every `base/*.tsv`, filled after the parses by ONE build step (full detail
in ARCHITECTURE.md), **`bin/build/result.sh`** — a subscription goes green/red by its LAST File's
outcome (red when Failed; ORANGE when Expired — a pickup problem, not a failed delivery, since
2026-08; orange = never seen in the transfer log), other entities roll up their connected
subscriptions (`_white.tsv` goes by the last real transfer from that address instead, by the same
rule — its Expired-last was still red until the 2026-09-28 fix, like `host_own_unpaired`'s). **A UC3 WITH NO TRANSFERS IS NEVER GREEN** (2026-09-28, user rule: "A UC3
subscription that has no transfers must be orange and not green"): polling fine with nothing to
fetch leaves it ORANGE (UC3 status "not seen"; the verdict and No remote files name its polls). The
**clean-poll rule** that flipped it GREEN (2026-08, sidecar `colour/_greenpoll.tsv`, its uc3-status
per-hour branch and detail-page "Working, nothing to fetch" verdict) is GONE — never bring it back.
ONE deliberate exception remains, a UC3 poll verdict: the
**cannot-connect rule** (2026-09-10, user rule): a never-transferred UC3 whose own polls fail
with "Connection failure while <flow> tried to connect …" on THREE polls in a row (newer than its
newest successful poll, or none at all) flips RED — a flow that polls and cannot connect is
broken, not idle; the newest failure is its `colour/_redflip.tsv` stamp, so it lands on Failed
Subscriptions with its own error page and the reason "Connection failures" (the home red
worklists went 2026-09-29).

**A CONNECTED-RING ERROR REDDENS ONE FLOW, NOT ALL OF THEM** (2026-08): a remote host — and just
as much an account or a login — serves many subscriptions, so taking the newest line of its
`_err_warn` ring reddened EVERY flow configured for it — one bad endpoint, a dozen false reds all
carrying the same evidence stamp. `result.sh` `_build_ringattr` attributes each host/account/login
ring line to the ONE flow it concerns and writes `colour/_ringattr.tsv` (subscription ⇥ newest
attributed E stamp), which the flip reads instead of the rings: first a CONFIGURED NAME in the
MESSAGE (every name-shaped token, tail-stripped and rename-folded, against the roster — not only
a UC-prefixed one, since 2026-08-31: the production hybrid flows carry no UC prefix, so the
precise channel abstained on them and the wholesale join decided),
else the SESSION (`_parse.tsv` col 6, the connection id) voted from the parse cache's own lines,
else — **the session join** (2026-08) — that session's transfer LEGS: `_transfers.tsv` col 24
carries the same id and col 6 the site the attribution chain gave the leg (canonical since parse
time; message/parse tokens fold through `rn_canon_pfx`). A line that attributes to NOTHING cannot
redden what it cannot identify; a session naming two flows — in the parse cache or in its legs —
resolves to neither. **The ring's own entity then owns what is left over** (`orphan_red`,
`colour/_ringorphan.tsv`, ring kind ⇥ name ⇥ stamp): an authentication failure naming only a
credential, a PeSIT transfer-profile complaint naming only the account, is a real problem at that
ENDPOINT / account / login, so it goes RED — unless it has moved a file OK SINCE (the "recovered
since" test the unresolved server reports apply; hosts count OUT-side files only) and never over a
row that is already red; a forward-address ring's residue lands on its endpoint. **E-level only**:
"Error" is the E level site-wide, and every W-level orphan is the benign "Transfer site ID is not
present in environment" shape. Acceptance: 1,128 ring E-lines, 975 attributed (340 distinct
sessions, 191 parse-voted + 62 more by the session join); the five false-red `UC1_IT_ADF_RABOBANK_*`
sisters all carried the one stamp that belongs to `_NSPP` alone. The detail-page banner still
reads its 1-to-1 connected rings wholesale — 1-to-1 BOTH WAYS since 2026-08-31 (the connected
entity must serve this flow alone) — it shows the log; the COLOUR rests only on attributed
lines. **A ring owner serving SEVERAL flows** (2026-08-31 audit): the loose went-kaput join
(`_build_kaputflip`, promoted to the colour 2026-08-22) counts a shared account's, login's or
host's ring only when its newest line is about the CONNECTION itself (`flip-reason.awk`:
Connection failures, Wrong server fingerprint, Login errors (out) — the credential/endpoint every
flow on it uses is broken); a flow-level line on a shared owner reaches the colour only through
`_build_ringattr`, which names the flow. `bin/build/kaput-evidence.sh` applies the same rule to
`_kaput-evidence.tsv` (read by failed.sh, the Entities Error view's Reason and
`bin/build/reason-boxes.sh`). 1:1 owners are unchanged.

The SAME evidence also **keeps a UC3 green** (2026-08): the after-last-transfer red flip is
skipped when a successful poll is NEWER than the E-level stamp that would have flipped it — a
flow that has since polled cleanly is working, whatever it logged before (acceptance: 14 of the
15 candidates) — a flow that HAS transferred; `_uc3polls.cand` carries `name⇥newest poll`, the
stamp this keep compares.
The after-last-transfer red flip records its evidence in `colour/_redflip.tsv` (name + ring stamp);
the UC status per-hour walkers read it so their sidecars' last row equals
the STAT figures. **"After the last transfer" means after its END** (2026-09-12, user rule: a
production flow logged a "Could not send file" Error at 09:19 while three Files that had STARTED
the day before were delivered by their retries at 15:16 — "there are CoreIds from this
subscription that ended ok after it; in those cases do not mark it as a Server Error"): the cut
the evidence must be newer than is the last File's start raised to the newest OK File's END
(`_files.tsv` col 24, the latest leg end; outcome-policy OK) — in `result.sh`'s flip and
`orphan_red`'s recovered-since test, went-kaput's `lastokf`, and the detail pages (details_lib's totals-row field 30 → `last_transfer_cut()`, the
banner and the connected-lines cutoff); the "Last OK transfer" section picks the newest Processed
File by its end too. Never lower than the old start-based cut, so it only ever spares a flip.

**The SSH logon funnel is SESSION-aware** (2026-09-06, user request — the FE000508 finding):
`_parse.tsv` column 6 is the SSH session id, and `bin/server/reports/logon.sh` + its twin
`bin/logons.sh` (the detail pages' Logons table and the Incoming table's four logon-summary columns —
the family classifier is ONE file since 2026-09-30, `bin/ssh-family.awk`; the session rules
still "belong in both") tie every `[Ssh Default]` line to its connection.
A **re-screen** is an "Allowed user" line LATER than the last successful authentication of its
session (an Allowed that an authentication follows is a real screening, whatever the session
logged before — the sample's shared-session flows log several pairs on one id): a partner that keeps a connection open for days re-keys it about hourly and the
server logs "Start login process" + "Allowed user" again with no new authentication (FE000508:
601 Allowed vs 375 Authenticated, no failure, 2 hosts × 24 h/day). Re-screens have their own
column (kind `num`, never a problem, never the row-tint verdict) and are NOT in Allowed — nor
in the host file's Allowed. **Session errors** are the Error/Warning `[Ssh Default]` lines of no
counted family ("Stream read/write error. Exception message is: CMS parsing has failed"),
attributed to the login of their session; a `numfailed` column with drills and sidecar fields
22-25 of `_logons.tsv` (the `_logon-problems.tsv` sidecar went 2026-09-29 — its one reader, the
retired FE overview Logon problems column, was gone). Both need the whole session seen first (a re-screen is judged against the session's LAST
authentication), so every Allowed line is booked in END. The sample estate plants one persistent
connection for the first login (`bin/sample/gen-events.awk` env_ambient, fixed session id, no
rint()). Drill-cell numbering on Incoming: 1 Allowed, 2 Disallowed, 3 Authenticated, 4 No account,
5 Bad key, 6 Key failures, 7 Locked, 9 Session errors, 14 Re-screens — Re-screens is the LAST column
(2026-09-08, user request); `bin/build/reason-boxes.sh` reads the Incoming cells by POSITION for its "login
in" box (`$4/$7/$8/$9` = Disallowed / Bad key / Key failures / Locked), so a new column goes at the END.

## Rendering

`bin/publish_lib.sh` is **sourced, not run**: it cd's to the repo root, computes the shared
globals and defines `render_report`/`render_rpt`/`ensure_assets` (topbar-data.js is written
ATOMICALLY — tmp + `mv` — because concurrent publishes write it). The page body is rendered by ONE
awk pass per page, **`bin/render_rpt.awk`**; keep cell work in awk (a bash per-cell loop costs ~5
forks per linked cell). No `<style>`, no inline `style=`; the load bar uses `.w0`…`.w100`. Every
table is wrapped in `<div class="tablewrap">` (report.js `tunit()` returns it) and **carries a
TOTAL footer** — "Total (N rows)" + a sum per numeric column, aligned like the column;
non-additive columns blank; humanized cells parsed back and re-summed; report.js re-totals over
visible rows (`recomputeTotals`/`writeRecalc`/`recalcSeen`); top-N tables total the shown rows.
**Every table downloads as CSV** (2026-08-30, report.js `setupCsvBtn`): a faint "csv" hotspot in
the upper-right corner of the LAST header cell exports the table as shown — filtered, sorted,
displayed text, totals excluded — client-side (Blob), no server round-trip.

**SUBSCRIPTION ROW TINTS on the SERVER pages** (2026-08, `RPT_SUBTINT` → render_rpt.awk's
`subtint`): the server publish passes the `base/_subscriptions.tsv` + `_accounts.tsv` caches, and
any table whose HEAD carries a subscription column (`Subscription`, `Subscription (…)`,
deploy-errors' `Account or subscription` — never the plural `Subscriptions`, a COUNT) becomes
`restint` and each row takes that entity's RESULT colour. Decided per TABLE inside
`emit_header`, so it needs no writer change; a row the report tinted itself (`@data:res`) is left
alone, an unconfigured name stays untinted, and the **Error/OK cells keep their own background**
(the restint CSS excludes `.failed`/`.processed`). The two server members whose PAGE lands in
Analyses (uc-status, polling) get the same treatment via `render_subs_group_pages`. Kept in its own array — the detail
pages' `resmaps` tint entity CELLS and must not switch this on for a whole area.

The analyses, dashboards and day publishes hand-render their pages but source publish_lib;
cross-links use `DLINK_BASE`. **All options, every checkout**: menus, sitemap and group tab bars list
every order-listed report UNCONDITIONALLY, so every checkout's menus are identical; a missing `.rpt`
gets an "empty report" placeholder page (`render_missing_reports`). Publishes run concurrently
(`publish-details.sh` beside `publish.sh` — disjoint trees).

### The page families (details in ARCHITECTURE.md)

- **The home page** (`bin/build/publish.sh`): the two status tables — every cell opens the
  Entities view whose row count IS that figure (Entity · Total · Seen % · OK % · Error · Warning ·
  Ok; the percentages tight "71%" since 2026-09-30; no scope switch since 2026-09-27) — EXCEPT
  the Logical / Partners / Domains / Applications / BL rows' Entity LABEL, which opens the
  configured list `coverage/<member>-configured.html` (2026-09-30, user request: Entity and
  Total switched — Total opens `<e>-all` like every row); `check_status_consistency`
  verifies each figure and pairs each label-linked coverage page with its row's Total; the SEEN figures come from `home.rpt`. The per-day figures are ONE
  "Per day" table (`write_home_block`; 2026-08-31, user request — the 2026-08 five-table flex
  row is retired): a `gband` banner over a shared Date column (its cells link the day page), then
  two groups separated by SPACER columns (`th/td.spc`; report.js `syncGroups` keeps the spacers
  and group edges right after a column move or hide): **Files** (Ok · Cured · Error · Error %;
  Cured = the transfer topview.rpt's Recovered group, Automatic + Manual, linking Recovered files
  for that day; Error links Failed files for that day) · **Duration** (p50 · p75 · p90 · p95 ·
  p99 — p99 last since 2026-09-13; banner and headers carry
  `data-href="transfer/duration.html?axway_date=FROM..TO"` — the shown days — each day's cells
  `?axway_row=<date>` — report.js `setupCellLinks`, which outranks the row link).
  **THE NEWEST 14 DAYS ONLY** (`HOME_DAYS`, 2026-09-29, user request: "Remove the Transfers, UC2
  state, First seen subtables, remove the columns In & Out in the Files subtable … have only 14
  days in the Date tables" — every day showed that morning; `data-nosort`, newest first) and NO
  Total row (later that day, user request: "remove the Total row in the date tables" — its
  14-day percentile sentinel went with it). **BESIDE
  it the Errors table** (`write_home_errors`, one `.sxs homeday` row, same request: "Have a
  table Errors side by side to the Date table — the columns Subscription / Date/time / Reason
  from /analyses/failed.html"): every RED row of `failed.rpt`'s table ("show only the Errors
  (red) and not the warnings (orange)"), newest first (Date/time to the minute — "only hh:mm, no
  ss.mmm"), tinted by its
  `@data:res`; the Subscription cell opens the page the row opens on Failed Subscriptions (else the
  detail page), the "Errors" banner the report (`data-href` — a link in a banner th would take
  the header's white). The Red/Green switch group, its `docs/switches/` pages, the Transfers,
  UC2 state and First seen groups and the Files In / Out columns are GONE — never restore
  them. The home's RED worklists ("Failing transfers" / "Failing subscriptions in Server
  log", `write_failing_now`, 2026-08) and "The log exports" facts table (`write_log_facts`) are
  GONE since 2026-09-29 (user request): the red flows are on Failed Subscriptions and the Entities
  Subscriptions Error view, the log facts on the build report. THE REASON CHAIN they used lives on
  in the Entities Subscriptions Error view's Reason column (publish_lib): the Reason is
  `analyses/reports/_subs-boxes.tsv` (the most specific Subscriptions-in-boxes box, written by
  `bin/build/reason-boxes.sh`). **The SERVER LOG ON THE FLOW'S OWN ERROR PAGE COMES FIRST** (2026-08):
  the page a red row opens is the evidence a reader checks, so the Reason must be what that page
  says — `_errpage-evidence.tsv` (written by `failed.sh`: the first 8 Error/Warning
  lines, with their level, of the flow's NEWEST drill page — the page the red row opens —
  PLUS, since 2026-09-10, an Info `"Transfer end logged."` bookend with `"status":"error"` whose
  transferId is one of the page's own legs: the only evidence a silently dropped connection
  leaves, read by the classifier as **"Unknown error"**, its LAST rule)
  classified **FIRST-ERROR-first**, warnings and the bookend only after. The opening error is the CAUSE and
  everything after it consequence: a rejected host key, then "failed to create connection", then
  the connection failure, then a trailing ARRC0029 "No files were processed during step
  execution". Reading from the end names the symptom (it moved 40 acceptance reasons off
  Connection failures onto Routing step failed). A flow with no such page
  takes the NEWEST LINE ACROSS ITS CONNECTED RINGS next (`_kaput-evidence.tsv`; the newest E-level
  line preferred over a merely-newer benign warning — a box is a rank, not a clock, and an old
  route-stop must not outrank this week's connection failure). Only then the BOXES, where box 18
  "Error" and the two mood boxes are deliberately not reasons and a flow in several cause boxes
  takes the one its newest own Error/Warn line classifies to. The REASON is descriptive, not a
  verdict: the colour still never rests on a line attributed to no flow; Last file comes from `_files.tsv`.
- **The Entities pages**: 9 entities x 6 views (All · Seen · Not seen · OK · Warning · Error —
  `<entity>-<view>.html`, no scope pages since 2026-09-27) under `docs/transfer/entities/`. The six
  views' ROW PAYLOAD (buckets, durdays, fp, the `coreids-*` drill lists) ships ONCE per entity in
  `docs/transfer/entities/<entity>-data.js` (`window.AXWAY_EP`, publish_lib `entity_payload_split`,
  run after the views render — 2026-09-30, the lean round: the views repeated it ~3x); page rows
  carry `data-k` and report.js `attachEntityPayload()` puts the payload back FIRST in `init()`;
  TOTAL rows keep their own buckets; linkcheck reads the fp edges from the `.js`. A new reader of
  row attributes needs no change (the DOM is complete after init's first step). Pages
  assembled at publish time (`render_entity_report`) from
  `data/transfer/reports/entities/<name>.rpt` — ONE writer for the nine,
  `bin/transfer/reports/entities.sh` — plus the coverage TSVs and the base caches (the ghost
  rows: a green with no report row of its own is Seen with blank counts); sort is shared across the nine entities (localStorage, 1-hour sliding expiry,
  stored by "group › column" label). THE GROUPED LAYOUT (2026-09-13, user request — built that day
  as the `transfer/entities2/` twin experiment and adopted the same day; the classic Name ·
  Direction · Files · Volume · OK · Retry · Resubmit · Error · Last seen pages are GONE): Name,
  then seven column groups the Top view way (a `GHEAD` banner + `gsep=` dividers) — Files (In ·
  Out by MOVEMENT, `_files.tsv` col 17, a File without one by its connection side col 16 ·
  Error · Error %) · Retry / Resubmit (Auto = an OK File
  with a failed leg and no resubmitted leg; Ok / Error = every resubmitted File by outcome — the
  Top view's Automatic + Resubmit Ok/Error rule) · Duration (p90 · p95 · p99 · p100 of the DELIVERED
  (Processed) Files' wall-clock span — a Waiting File's span is its staging wait, excluded since
  2026-09-29 — the Duration report's scope and nearest-rank rule, FOLLOWING the date
  filter: per-day display-grid histograms `@data:durdays` + the RECALC tokens `P90`…`P100`, rows
  and TOTAL alike, the publish-time subset totals merging the same payload) · Volume (Total · Avg
  per File) · Transfers (Ok · Error · Error % — the LEGS of the entity's Files) · State (Waiting ·
  Expired) · Dates (First · Last · Days with traffic). DISPLAY RULES (user): the TOTAL row LAST
  (`entity_total_last`); an EMPTY Retry / Resubmit or State group HIDDEN per view
  (`entity_hide_groups` drops the columns and the banner cell and remaps every index-naming
  modifier — gsep=, noagg=, pct=, drillcols=) AND, in the browser, hidden whenever a date range or
  a search leaves every visible row's cells of the group empty (the `autohide=Group;Group` TABLE
  modifier → report.js `autoHideGroups`, the auto-hidden set joining the picker's list in
  `applyHidden` without entering the stored one); bytes in WHOLE units (tokens `H`/`V`); a duration
  as a whole number with a one-letter unit s/m/h/d, tinted s green · m amber · h/d red (the `P`
  token retints); an empty Error keeps an EMPTY rate beside it (token `e`); In / Out never show a
  0 (token `S`); every red count cell is KIND `numfailed`, never `numerr` — the views' row tints
  paint over `errc`/`okc` cells (only `.failed`/`.processed`, and a non-empty `.warn`, keep their
  own tint). Every count cell drills to its 10 newest Files (the `drillcols=` TABLE modifier →
  the row's `@data:coreids-<key>`, bound by BUILT column index); the Transfers cells to the Files
  with a leg of that outcome; a Duration cell to the 10 newest OK Files at or above that
  percentile, each entry with its span (the writer reads `_files.tsv` a THIRD time once the
  thresholds are known). Since 2026-09-30 (user decision) the writer ALSO writes the nine
  CLASSIC records `data/transfer/reports/<name>.rpt` (`classic_dim`, from the same S| rows) —
  the five classic writers (`account.sh`, `subscription.sh`, `login.sh`, `remote-host.sh`,
  `pda-entities.sh`) are GONE, folded in with a byte-identical proof; `showseen.sh`,
  `entity-search.sh`, `home.sh` and the server rosters read those records positionally — no page. Links INTO the pages sort by header LABEL
  (`?axway_sort=Error:-1` / `Total:-1` — report.js resolves the first header cell reading it; the
  home day table and the overview/day Top 5 produce them), since the positions shift when a group
  is hidden. The hand-written help pages `entities-<name>.html` describe this layout. Other
  report.js pieces that came with it and are general: the RECALC tokens `SN`, `eN.M`, `HN`/`VN.M`, `PN`; `pct=` accepting `a+b` column lists
  (the searched total honours S/e/H too); the TOTAL row's day count under a narrowed range = the
  DISTINCT in-range dates (was 0).
- **The detail pages** (`details.sh` → `details_lib.sh`/`details_writer.awk`): one page per entity
  of the nine types, every configured name gets one; slugs via the comprehensive `_slugmap.tsv`;
  no From/To, no search box, no RECALC.
- **The special pages**: Entity Search (rows ship as DATA in `search-data.js`; the Type cell is
  read by INDEX in report.js — adding a column means shifting it), the All files search
  (`search/all-files.html`, see above — its data also feeds the subscription pages' Files table; the seven File search window pages went
  2026-09-29), the TWO Failed Subscriptions
  view pages (+ per-CoreId error pages and the FILE pages `docs/files/<coreid>.html` — the same
  layout for a File of ANY outcome, written by `failed.sh`; since 2026-09-29 ONLY the published
  set of `_filepages.tsv` is rendered — see `files/` above; the per-report page lists
  `_patterns-files.tsv` / `_longest-files.tsv` / `_expired-files.tsv` / `_waiting-files.tsv` and
  the Report finder are GONE), Cross References, Entity coverage
  (six pages, the rules as verdict columns; assert OK transfers ⊆ Current ⊆ Once), UC status (its UC3 tab also carrying the polling tables — the
  former Remote polls report and Cronjobs page, 2026-09-05) and Polling (the same polling
  information as ONE flat table, one row per UC3 polling subscription — `bin/analyses/reports/polling.sh`
  → `polling.rpt`, a `SUBS_GROUP_REPORTS` server member, 2026-09-05) — both Use cases & delivery
  members, pages in analyses/.
- **The Boxes PAGE is GONE** (subscriptions-in-boxes, 2026-09-29, user request; its accounts
  twin went the same morning): `bin/build/reason-boxes.sh` — `bin/analyses/publish-insights.sh`,
  called from inside the analyses publish, until 2026-09-30 — still runs the shared
  `_subs_box_rows` producer for `_subs-boxes.tsv` (the Reason chain's LAST fallback, after the
  flow's error page and the kaput evidence; a build step right before the analyses publish); any
  account join is `xref/_subscriptions-accounts.tsv` and ONLY that — **never match
  subscriptions to accounts by name**.

### Report groups and menus — NO pulldown since 2026-09-30

**THE REPORTS PULLDOWN IS GONE** (2026-09-30, late, user request: "Remove the Reports pulldown"):
the top bar links the groups by FIXED paths in assets/topbar.js — Overview · Errors (data) ·
Duration · Partners · Waiting/Expired · Security (`transfer/security-params.html`) · Seen
(`analyses/first-seen.html`) · Configuration (`analyses/subscriptions.html`) · Use cases
(`analyses/use-cases.html`) · Patterns (`transfer/file-journey-patterns.html`) · Activity
(`transfer/activity-per-week.html`) · Entities · Files; Logons & connections has no top-bar link (the
Reports start page and the sitemap reach it). `REPORTS_MENU`, topbar-data.js `reports`, the `.dd`
dropdown CSS and report.js's Escape handler went; linkcheck models the fixed links, verify.sh the
order and the absence. The history below describes the 2026-09-29 pulldown the groups came from.


**Since 2026-09-29 (user request: "Reorganise Transfer Reports and Server Reports and Analyses
and Goodies, just one pulldown named Reports, create logical groups, have all reports in the same
group link to each other with the first selection buttons")** the top bar has ONE report menu,
**Reports ▾**: a Start page (`docs/reports/index.html` — it replaced the transfer/, server/ and
analyses/ `index.html` start pages) and one line per GROUP, landing on the group's first member.
The four dropdowns (Transfer reports · Server reports · Analyses · Goodies) are gone. The groups
MIX areas by question: Overview (the two Top views — a top-bar link, not a menu line, since
2026-09-29: `OVERVIEW_HREF`, `overview` in topbar-data.js; Since yesterday (data-diff), Triage
and Subscriptions in boxes went the same day) · Entities · Errors (Failures until 2026-09-29; + the server log errors: Errors, Per flow, IO
errors, Routing errors — the separate "Server log errors" group was folded in 2026-09-29, user
request; + Unknown transfers) · Use cases & delivery · Activity & volume · Performance
· Flow patterns · Protocols & security (Security Parameters carries the SSH security tables since
2026-09-30) · Logons & connections ·
Partners · Configuration · Coverage — every published report is in exactly one (the
former boxes-only reports included). (The **Cleanup** group — Cleanup backlog, Config hygiene,
Whitelist audit, Account sharing, Twins — went 2026-09-29 with Sources and targets, File journey
Last leg / In and out and Episodes › Episodes, user request: writers, .rpt, help pages and their
sidecars `_inbound-addr.tsv` / the flat server `_subscriptions.tsv` deleted; never restore.)

- **`_report_groups`** (`bin/publish_lib.sh`) is THE single source of truth: one line per group,
  `Label|dir/stem=Label|…` — `dir` the docs directory the page renders into (transfer / server /
  analyses, plus `transfer/entities`, `transfer/month-stats` and `analyses/xref`), `stem` the report basename or the
  hand-written page name. It feeds (the pulldown `REPORTS_MENU` until 2026-09-30) the start page
  (`write_reports_index` + `rg_desc`: a report's DESC, fixed texts for the hand-written pages),
  the sitemap (ONE `.smcols` flow of cards since 2026-09-29, user request — no Reports /
  Dashboards / Tools sections: the Start page card, one card per group, a Dashboards card and
  the Tools card — "Data pages & tools" until then) and the rows + tags below.
- **THE FIRST ROW = the group's members**, on EVERY page of every member, injected by ONE pass
  over the finished site — `apply_report_groups`, run by `bin/build/publish.sh` after every page
  writer (so a MANUAL area re-publish lacks rows until `bin/build/publish.sh` runs): the row lands
  directly under the `</h1>`, above the report's own tab / view rows, the page's own member a
  highlighted span, the others links made relative by `rg_rel` (a transfer page links
  `../server/…`); the h1 gets the tag `← Group`. A member's pages are `<dir>/<stem>.html` +
  `<stem>-*.html`, a LONGER member stem in the same dir winning (duration-longest.html is Longest
  Files, duration-all.html Duration). Idempotent: a page already carrying a `grouptag` is skipped.
- **Two groups keep their native render-time rows**: Entities (`group_of` → account-login-site:
  `render_entity_report`'s combined "members | views" row, the view carried across members — the
  pass only tags them) and the Cross References pair selector (group `cross`, its two entity rows
  under the injected Configuration row). `group_of` returns "" for everything else, so
  `render_report` writes no group row of its own; the old per-area groups (`group_desc`,
  `area_entries`, `build_menu`), `_analyses_groups` and its rows, the three `tag_*_group_h1s`,
  `BOXES_ONLY_REPORTS` and the Use cases / UC status view row (`_ucgroup_tabs`) are GONE —
  (their no-op stubs `analyses_group_tabs*` / `analyses_grouprow_for` went 2026-09-29 too).
- **Entities lands on Subscriptions / All** — the same member its row leads with, the target of
  the top bar's own Entities link (the Reports menu has NO Entities line since 2026-09-29): KEEP
  the link and the group's first member IN SYNC.
- `transfer_order` / `server_order` still drive the renders; `member_label`
  still labels the Entities / cross rows and the placeholders.

**Merged reports** (`bin/merge_rpt.sh`, run after the report pools) fold component `.rpt`s into
one tabbed report (`merge_rpt OUT TITLE DESC COMP...` — no prose argument since the second
2026-09-29 audit); the components stay on disk as unpublished intermediates (pageless: no order
list names them; `_merge_pad` pads a missing component with
empty stubs — 0 for a component whose tables ride another one's tab via `tab=KEY`). The merge
ends its component run with a `META merged` sentinel so the last component's trailing NOTE
stays on its own tab instead of footering onto every tab (2026-09-05). **`append_rpt_tables
[-f] TARGET COMP…`** (same file, 2026-09-29) is the lighter sibling: it inserts the components' TABLE
blocks into an EXISTING report before its first SUMMARY/FOOT (with `-f`, 2026-09-30: before its FOOT,
after its SUMMARY — how Security Parameters takes the ssh-crypto + ssh-sessions tables) — the server Top view carries the
errors-day levels-per-component table that way. **The 2026-09-29 consolidation** ("too many
reports", user request) folded pages into tabs and stacked tables (`tab=KEY`) instead of
separate pages: Sizes (files + top-transfers + size-profile), File in - File out (+ UC4 to UC2),
Retries (+ Recovered files), Recovered flows (`merge-episodes.sh`; its Episodes tab went
2026-09-29), UC status UC2 /
UC3 tabs (+ UC2 pickup visits, Pickups, No remote dir / files), Failed Subscriptions (+ From
green to red / Only red as the Last green day · Days red · Failures in a row columns), Routing
errors (+ Deploy errors), Polling (+ Missing cronjobs as Schedule "no cron"), Entity coverage
(the four rules as verdict COLUMNS, 24 → 6 pages); the retired pages' help pages are deleted and
`bin/sample/verify.sh` asserts their absence. (The BOXES-ONLY reports — pirates, waiting, expired, went-quiet, reached only from the
Boxes pages 2026-07..09-29 — are ordinary group members since the one Reports pulldown; went-kaput is pageless.) The full
merged-component list is in ARCHITECTURE.md.

(**Month stats** — 18 pages, 2026-09-13, `entities.sh` (its `month_stats` part; `month-stats.sh` until 2026-09-30) → `docs/transfer/month-stats/` — and
**Missing entities** — the five unknown-* tables, `missing-entities.sh` — went the morning of
2026-09-29 and CAME BACK the same day, user request: Month stats in Activity & volume (its member
`transfer/month-stats/this` is special-cased in `rg_landing` / `apply_report_groups` —
every page of the directory belongs to it; entities.sh also writes the
Subscriptions page's `_alltime.tsv`), Missing entities in Coverage (a ↗ detail-page icon beside
each name that has a detail page — its value column carries the entity KIND). The **Goodies** short-cut
dropdown of 2026-09-13 went with the one Reports pulldown; Partners in —
`bin/analyses/reports/partners-in.sh` = fe-overview.rpt + the whole Incoming funnel of the pageless
logon.rpt, one row per login — and its sibling Partners Out are the Partners members.)

## Publishing (GitHub Pages)

Published via GitHub Pages — branch `master`, folder `/docs`. No
CI build (the sources are gitignored): run `bin/build.sh` locally → commit `docs/` → `git push`,
both MANUAL.

- **Local preview: `http://localhost/develop/`** — the local Homebrew httpd serves this repo's
  `docs/` (the runtime twins serve at `http://localhost/acceptance/` and
  `http://localhost/production/`); preview there, never start a
  throwaway HTTP server, hard-reload after an asset edit. Every page head carries the no-cache
  trio (`http-equiv` Cache-Control / Pragma / Expires — 2026-09-12, user request; baked by
  `html_head`, `write_root_404`, the build report and the hand-authored `assets/help/*.html`,
  KEEP IN STEP); the assets rely on their `?v=` busters. All generated links are RELATIVE, so
  the site works under any base path — the 404 page derives its home link from the URL itself.
- **`docs/` is PURE committed build output** (2026-08-29): every `bin/build.sh` run CLEARS
  `docs/` wholesale and RE-SEEDS the
  hand-authored files from the repo-root **`assets/`** — `style.css`, `topbar.js`, `report.js`, `slotchart.js`,
  `all-files-search.js`, `sub-files.js` → `docs/assets/` (build.sh `SEED_ASSETS`), `assets/help/` → `docs/help/`. **EDIT IN `assets/`, never in
  `docs/`** — a build overwrites the docs copies. (`.nojekyll` and `topbar-data.js` stay
  generated.)
- **`assets/help/*.html`** — a help page per report (or shared per group/family) plus `general.html`
  and `index.html`. Since 2026-09-30 they are FRAGMENTS (the body from `<h1>`; an optional first
  line `<!-- help: back=page -->`): `bin/build/publish.sh apply_help_chrome` reads `assets/help/`
  and writes the full page to `docs/help/` — head, the no-cache trio, stylesheet + bar scripts with
  `?v=`, placeholder, back / Generic help links, tail; the title `Help: <h1> — Axway ST reports`. `help_slug_for AREA BASENAME` maps
  basename → slug (server basenames get a `server-` prefix; detail pages `details-$sub`). **A
  new/renamed/regrouped report needs its help page created or extended BY HAND** — a slug with no
  file is a silent 404, not a build error.
- **The `.rpt` files and parse caches are NOT committed.** Keep them on disk for HTML/CSS
  iteration; a fresh clone must run parse + reports before the publishes produce a site.
- **Pages is case-sensitive** — keep generated paths lowercase and exact (the links are relative,
  so the site works under any base path). The assets' `cksum` is the `?v=` cache-buster on
  every page (`ASSET_VER`), so an asset edit wants a full re-publish.
- **To add a transfer report**: a script in `bin/transfer/reports/` sourcing `../lib.sh`,
  aggregating `$PARSED` or `$FILES` into `$REPORTS_DIR/<name>.rpt` (TITLE on line 1, a one-line
  DESC) — no freshness check (every build is fresh; see "No incremental machinery"). Add it to
  `bin/transfer/reports.sh` and `transfer_order` (+ `report_tabs` if multi-table), put it in ONE
  group of `_report_groups` (without that: no menu line, no first row, no sitemap card;
  `group_of`/`member_label` matter only for Entities / Cross), and write its help page
  `assets/help/<slug>.html`. Phase 1 unless it reads another report's output (phase 2
  = `showseen.sh` + `ranking.sh`); build.sh overlaps the phases with `details.sh` in the background, so **a new
  phase-1 report must be safe to run beside the server reports**.
- **Every `.rpt` write is ATOMIC** (2026-08): `} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"` — never a
  direct `> "$OUT"`, so a killed run never leaves a truncated report. Multi-write reports assemble in the ONE `$OUT.tmp` and
  mv once at the end; `bin/day/reports.sh` stages its whole per-day set in `reports.new/` and
  swap-renames (both its passes append across the file set). The `bin/*/reports.sh` orchestrators
  sweep orphaned `*.rpt.tmp` at start. One build runs at a time: `bin/build.sh` takes
  `build/.buildlock` (owner PID recorded; a dead owner's lock is reclaimed automatically).

## Target environment (this Mac)

macOS on Apple Silicon (10 cores, 16 GB RAM, BSD userland, `/bin/bash` 3.2, Homebrew).

- **Parallel by default**: core-count job pools, plain `&` + `wait` (bash-3.2-safe, no `wait
  -n`); `sort -S`/`--parallel` feature-detected. Copy the `pool_run`/`pool_wait` pattern.
- **awk runs on Homebrew mawk via `bin/fastawk.sh`** (a PATH shim; no-op without mawk). **Keep the
  programs POSIX-AWK** — no gawk-only extensions (gawk is unsuitable: its UTF-8 locale handling
  tokenizes non-ASCII differently) — and no output may depend on awk HASH-ITERATION order: sort
  with an explicit tiebreaker. Three awk traps: a bare read of a missing key CREATES it (guard
  lookups with `in`), mawk's LHS-first assignment makes `arr[k] = (k in arr ? … : …)` see the
  key as existing — test EMPTINESS, not membership, when assigning to the same key — and a
  numeric-looking FIELD compares NUMERICALLY with an uninitialized variable (`$2 != cur` is FALSE
  for `$2 == "00"` and unset `cur`: 0 == 0), so a group-change tracker silently merges the "00"
  group — force the string comparison with `($2 "") != cur`. And mawk's `index(s, "")` returns 1,
  so an `index("0123456789", c)` test on a possibly empty `substr` checks `c != ""` first.
- **No Python or other interpreters** — bash + awk + `sort`/`sed`/`date` + `jq`.
- **Tolerate CRLF and LF in the input CSVs** — strip a trailing `\r` during awk parsing so it
  never leaks into a field value, filename or sort key.
- **Keep the `.sh` files themselves LF** (`.gitattributes` enforces it); bash 3.2 chokes on CRLF
  scripts — if a script suddenly won't parse, check `file *.sh` first.
- **`set -euo pipefail` is on everywhere.** Compute first/last records in one awk pass rather than
  `sort | head`/`tail`, and cap top-N lists with `awk 'NR<=n'`, never `head` — the early
  pipe-close SIGPIPEs `sort` and silently kills the script.

## Rules from the 2026-09-29 site audit (user request: "a very very deep analyse & audit … fix all")

- **A report page's TITLE is its Reports-menu label** (`_report_groups`): "Transfer top view",
  "Server top view", "One-legged", "Recovered flows", "Per flow", "Routing errors", "Waiting & Expired", "Activity",
  "Sizes & types", "Duration", … — the start page reads the TITLE, the help `<h1>` repeats
  it. The Configuration pair is **Configured subscriptions** / **Configured accounts** (the Entities
  group keeps Subscriptions / Accounts). A new report: label and TITLE the same.
- **Connections split In / Out** (`inbound-connections.sh`, the three volume tabs): a TM
  "had initiated a connection" line that names a login is a partner connecting IN, `login name ""`
  is SecureTransport connecting OUT (bin/logons.sh's reading). (Its sidecar `_inbound-addr.tsv`
  and `bin/server-inbound-addr.awk` went 2026-09-29 with their readers, the Whitelist audit and
  the Cleanup backlog.) The SAMPLE plants both
  kinds: `gen-events.awk` `s_initconn` writes our outbound `login name ""` lines and `s_authok` a
  partner's login-naming line beside every partner authentication (verify.sh fails when the
  Connections TOTAL In cell is empty); `bin/logons.sh` counts only the `login name ""` lines as our
  outbound targets.
- **THE FILE COLOUR** (2026-09-29, user request): `_files.tsv` col 25 = green / orange / red,
  written by the parse collapse — red = Failed, orange = Waiting or an OK (Processed) File with a
  FAILED leg (a retry) or a RESUBMITTED leg (`_transfers.tsv` col 22), green = Processed clean —
  and kept in step by `expire-files.sh` (Expired → red, Waiting → orange) and `bookend-ok.sh`
  (settled → orange, reverted → red). EVERY table of single Files tints its rows by it
  (`restint` + `@data:res`): the All files search and the subscription Files table (shard flag
  `o` = OK-orange beside d/e/w/x), Inbound and Outbound same Protocol's Files, Waiting (orange) /
  Expired (red) lists, Longest Files, Largest Files, Most legs, an incoming connection's Latest 10
  Files, an account's Files not picked up (red), Last error(s) (red). NOT the Failed files /
  Failed Subscriptions lists (their rows tint by the SUBSCRIPTION's current colour on purpose),
  the handover / UC4-to-UC2 pairs (two Files per row), AV Scan's blocked legs, Skipped. The
  COUNTS keep the outcome policy (Waiting = OK, Expired = Error) — only the row tint differs.
- **Engine tables** (`rangehook`, `subfiles=`) get `data-nocolmove` — no cols picker, their rows
  arrive after report.js ordered the columns; report.js `hideEmptyTables` (detail pages) skips a
  `data-subfiles` table, which is empty until sub-files.js fills it.
- **0 in a count cell is blank** in the UC status tables (UC1 / UC3 / UC4, rows + totals), Month
  stats, Expired, Connection efficiency and the UC3 polling tables; the "ok -> error" Status cell is
  red like its row. Activity (weekly / hourly / weekday) Volume = OK File bytes, the Protocol summary
  reads "OK transfers | OK volume"; Waiting & Expired › Collected counts delivered Files only.
- **A TOTAL row may ship its OWN `@data:buckets`** — the DISTINCT per-day totals of a table whose
  rows overlap (a File counts for every BL / partner / application: `entities.sh`; Recovered files
  per protocol): report.js `recalcTable` re-totals a narrowed range from them as long as only the
  date filter hides rows (a search / view filter → the visible-row sum). The OK / Warning / Error
  subset views never inherit them (their totals are row sums).
- **A Volume column follows its table's count scope**: Leg count, Protocol journey and Protocol
  count OK Files / legs, so their Volume is the OK bytes and a row with no OK File is dropped.
- **Durations everywhere = DELIVERED Files, nearest-rank** (`int((n-1)*P/100+0.5)+1`): the Duration
  report, the Entities Duration group, the dashboard / day duration charts. The Transfer errors
  chart counts every non-Processed leg (the per-row Error rule).
- **render_rpt**: an EMPTY `@data:loglines` / `@data:coreids` is no drill (the row stays inert); a
  `LINK` opens in the same tab (an absolute http(s) link in a new one).
- **report.js**: `thLabel(th)` is THE header label (text without the csv / cols / arrow hotspots —
  a regex strip ate "Protocols"); `sort=` and a numeric `?axway_sort=N` are BUILT indexes (a stored
  column order moves positions); the Entities pages remember EVERY sort key (`k` list, labels);
  a sort sends the pager to page 1; a table without a search box still shows the date-range empty
  message; topbar.js `fitTopbar` pads the body to the wrapped top bar on a narrow window; the CSV header of a
  grouped table prefixes each column with its group; a search hides a catalog's group heading row
  with no match under it; `initSeen` only touches seenrows
  tables.
- `td.bar span` has its own navy `#25405c` so load bars stay visible on tinted cells (the dark
  theme went 2026-09-29).
- **Help**: the home page opens `help/home.html`; Failed files its own `failed-files.html`.
- The Reports start page describes a report by its one-line DESC (`rg_desc` for the
  hand-written pages).

## Rules from the second 2026-09-29 audit ("check every .rpt and every field … technical and logical")

- **`_redflip.tsv` col 3 = SINCE** (col 2 stays the NEWEST evidence stamp): the cannot-connect
  rule's oldest failure of the current streak, the after-last-transfer flip's oldest evidence
  line newer than the cut. Failed Subscriptions' server rows (Last green day, Days red), the UC per-hour walkers and the
  dashboard flip slot date by it. `_ringattr.tsv` carries every attributed stamp for it.
- **The rollup (result.sh) uses OBSERVED pairs for UNCONFIGURED subscriptions** (the
  discovered names; never `Unknown`, the no-subscription value): account → subscription, login → subscription, the hosts of their outbound
  Files (`_hostlegs.tsv` has 5 columns); configured pairs keep the xref rule. `orphan_red` host
  recovery reads the leg hosts and the File END. Every "newest OK File after the error" test
  compares the File END (`_files.tsv` col 24) — result.sh is the master rule.
- **Connections In / Out**: a literal `login name ""` = Out, a named login = In, anything else is
  neither (inbound-connections.sh and logons.sh share it); accounts drop their `@login` suffix.
  Server contacts (in) = per address max(inbound lines, authentications) + disallowed.
  Session errors exclude the "No session cycleId … will not get reported" re-key line.
- **UC status drills** list the flow's problem (E) lines first, then its other lines (cap 10), so
  the verdict's Next move fires; Files join `_files.tsv` EXACTLY (prefix matching only for
  server-log tokens); an Expired last File is orange in the per-hour walkers too.
- **Use cases Seen** = the coverage seen flag (a red never-transferred UC3 is not seen) and is not
  a link (no Subscriptions-page search reproduces it).
- **Server parse**: `_parse.tsv` is chronological; its row count is written to `_parse.count`
  (the build report reads it); the flat `_accounts.tsv` mention cache and the `A./L./H.` chunk
  files are gone (no flat mention list stays — `_subscriptions.tsv` went with the Cleanup backlog). Gone as unread: `pesit.rpt` (its
  `pesit-slots.tsv` sidecar stays), event-queue table 2, the first-seen total/seen/notseen cell
  .rpt files, 17 xref mirror files, several dead cache columns.
- **Detail pages**: the Activity per day Duration averages DELIVERED Files; the Duration table is
  titled "Duration per leg" (the OK legs — Ranking's scope); In / Out = movement, else connection
  side; the File END comes from `_files.tsv` col 24; "Files not picked up" = the account's Expired
  Files from `_files.tsv` (col 22 stamp); the Last server log errors table holds the whole ring
  (10 E + 10 W); a GREEN subscription page shows no red ALERT banner; logged Login / Host rows
  carry `@data:seen=1`; a subscription page ships no Error drill list (its Error cell links Failed
  files).
- **Renderer**: empty drill payloads and lists a row could never bind (not in the table's final
  `drillcols`; more than one Error / OK cell) are dropped from the HTML; `data-seen` renders only on seenrows tables; `@data:srv` never renders; a
  suppressed INTRO / NOTE never closes a side-by-side row; a table with no data rows says "No
  rows in this data window." (report.js); engine tables (the Files table) supply their full CSV
  (`table._csvAll`).
- **Recovered / Automatic / Manual**: Recovered = an OK File with a failed leg — Automatic (no
  operator; a platform retry OR a bookend-settled File) + Manual (a resubmitted leg). The orange
  File colour covers MORE: Recovered ∪ resubmitted-OK Files. Recovered files uses the Top view
  words Automatic / Manual. The Top view Resubmit Ok / Error cells are `numok` / `numerr`.
- **Labels follow scope**: Activity / weekday / hour "OK Files" (Processed + Waiting); Duplicate
  filenames "transferred more than once" (any outcome); anomalies / dwell / day-page longest-transfer use DELIVERED Files, dwell
  percentiles nearest-rank and the File's START day.
- **Build**: the wipe (data/ + docs/ moved aside) runs AFTER the inbox step and the config check;
  the EXIT trap runs with `set +e` and always releases the lock; a background slot's PID is
  cleared once reaped; `LC_COLLATE=C` for every step; `bin/check-syntax.sh` also compiles every
  `.awk` (mawk -W dump; sample generators behind prelude.awk, subname.awk behind the renames
  helpers); display-rename applies all rules in ONE pass per line (a chain A→B, B→C never turns A
  into C) over a NUL-separated page list; the build report prunes `data/.buildstats/loginv`.
  verify.sh runs linkcheck and fails on any CONSISTENCY WARNING in build/build.log.
- **The CLASSIC entity .rpt files** (`data/transfer/reports/{account,subscription,login,remote-host,
  domain,application,partner,logical,bl}.rpt`, no page) hold ONE record per name since the same
  day: name · Files · Error · OK · newest Error File start · newest OK File start (1.46 MB →
  40 KB) — what their readers use (the server rosters, entity-search,
  showseen, home). Written by `entities.sh` since 2026-09-30 (the five classic writers folded in). The Recovered / Retry / Resubmit rules read `_files.tsv` cols 26 / 27.
- **Dead .rpt text is GONE** (2026-09-29, the same day's follow-up — Herbert: "why … Left on
  purpose and not fix those?"): every NOTE / INTRO / DESC / SUMMARY / KEYWORDS line no consumer
  reads was removed from the writers and a report FOOT carries no text (each class PROVEN dead by
  a marker build, the removal proven by a byte-identical site; the SECOND audit that day removed
  the ~50 report INTROs the first pass missed, the DESC of every non-member producer and
  merge_rpt's prose chain — the dashboard FOOT lines, overview and monitor, DO render). Write a
  NOTE / INTRO only where it renders (detail / drill pages — no noprose); a report page's
  explanation belongs on its help page.
- The File page's raw log lines stay unwrapped on purpose (one logged line = one rendered line).

## Rules from the third 2026-09-29 audit ("a very very very deep analyse & audit … check if every .rpt file and every field … is really used")

- **Dead output is gone** — every .rpt line, column and sidecar no consumer reads (INTROs, DESCs of
  non-members, drill payloads of pageless producers, the unread boxes of `publish-insights.sh` (now `bin/build/reason-boxes.sh`) —
  specs 2, 4, 7, 8, 9 remain, box 14 reads `data/server/reports/site-failures.tsv`, subscription ⇥
  newest failure stamp), with the dead helpers (`PAGELESS_REPORTS`, `sm_href`, `srv_lines_for`,
  …), the renderer branches (`SUBTITLE`, 3-cell ALERT, `pfnoun=`, `anchor=`, STAT `data-pf`) and
  the front-end code and CSS they served (the Boxes stat filter, the palette, the report finder).
  Pageless producers write only what their readers take: `day.rpt` = the calendar (META first /
  last, Date · Last Time, gap days `-`), `punctuality-src.rpt` = 5 columns (Subscription · Active
  days · Typical arrival · Window · Class), `event-queue` = its slots sidecar only, showseen = the
  coverage TSVs only (home.sh counts their seen flag), coverage TSV col 7 empty. Never restore.
- **File-page links in drills** — see Drill-down: any listed entry links, render_rpt lists only
  the shipped File lists' page-bearing CoreIds.
- **Renamed flows fold everywhere a server-log name meets a roster**: uc1-status / uc3-status
  call `rn_canon_pfx` before `key()` (as remote-poll's `sitecanon`); verify.sh fails when a UC3
  flow's UC status Polls differ from the Polling page's.
- **The UC3 tab = the Polling page's population** (`uc3-polling.sh` `UC3_AWK`: the UC3 status
  roster, exactly or by a unique prefix either way, or UC3-named); its copied tables re-total.
- **Totals add up**: Recovered files › Per protocol has a row for EVERY protocol with a failed leg;
  Unknown transfers totals Legs / Volume / OK / Error; Configured subscriptions reads
  `Total (N): C configured + K skipped` (the annotation after ")" is dropped while filtered).
- **Labels (Files vs transfers, Error vs failure)**: KPIs "Files" / "File error rate", hero
  "OK Files" (`?axway_hero=OK%20Files` — keep the CARDALT keys, the seen cards' and
  anomalies' links and report.js `kmap` in step); Duration views "Delivered Files" / "All Files";
  attempts "% of OK Files"; One-legged per day = one "One-legged Files" column; "Automatic" (not
  "Auto Retries"); resubmission outcomes Error / OK; connection efficiency "User sessions" vs the
  storms' "All sessions"; month stats host pages carry no Waiting / Expired columns; the UC2 tab
  blanks 0 counts like UC1 / UC3 / UC4; Top messages keep a digit run that follows a letter or
  `_` (`UC1_…` stays, not `UCN_…`).
- **Help**: a help page's "?", the build report's "?" and the sitemap's Help open
  `help/general.html` (help/index.html is the Reports start page's help); the help SOURCES carry a
  one-link placeholder bar (`apply_help_chrome` swaps in the real one).
- **No publish catch-up modes** (2026-09-30): `bin/transfer/publish.sh` and `bin/analyses/publish.sh` take no
  argument and render everything once; the only catch-up is `failed.sh catchup`, in the report stage.
- **The sample** plants the server log's resubmit trail and the admin test connections without a
  PRNG draw (gen-events.awk), so Resubmission outcomes and Test connections have rows; verify.sh
  asserts both.
- The home per-day table's thousands DOT (`dotify_v`) is house style, on purpose.

## Rules from the 2026-09-30 audit (user request: "extreme deep analyse & audit … every .rpt file and every field … rows colored the right way … cells linked the right way")

Six read-only auditors (rpt/field usage, transfer, server + analyses, detail/day/home, layout,
front end) then four fix workers with disjoint files. The rules it left:

- **Pageless producers write only what their readers take** (again). Later the same day (user
  decision, the refactoring round) they became plain SIDECARS: `from-green-to-red.sh` +
  `only-red.sh` → ONE `bin/transfer/reports/red-run.sh` writing `_red-run.tsv` (subscription ·
  kind G went red from green / N never delivered · last green day | never · since · days red ·
  run — failed.sh, the day pages and reason-boxes read it); `went-kaput.rpt` is GONE (see
  below); `publish-insights.sh` → `bin/build/reason-boxes.sh`. A reader that takes a
  field by NUMBER names the column in a comment — a column change silently drops a link.
- **Every row tints by the ENTITY's result colour**; a metric colours its own CELL. A Files table keeps
  the File colour.
- **Every entity name links its detail page** wherever it appears — Top-5 cards (day pages +
  Overview; TOP field 7 / TOPDATA field 4 carry the slug, report.js keeps the links on a From/To
  change), server By-account / Remote-host columns (KIND `acct` / `host`, the known set includes
  `base/_accounts.tsv`), Configured accounts (`_acc_links` pass), name lists (`@{alist=SUB}`),
  File-page IPv4 hosts (`incoming_connections/<ip>`), Entity Search Whitelist rows (the address
  page when it exists).
- **Labels**: "OK transfers" where a Transfers count is OK legs only (Protocol, Security
  Parameters); Month stats / Subscriptions page "Files · Error · Resubmit Ok"; KPI labels
  "Files / File error rate / Volume / Server records / Server error rate" on BOTH dashboards
  (report.js `kmap` in step); Direction values lowercase with "→" ("in → out"); "both", never
  "two-way"; percentages "12.3%" with the sign; the Cross References tabs and titles use the
  Entities labels (Accounts, Logins, …); coverage page titles the home Entity labels; File pages
  of a CoreId are titled "File: <name>" with a Reason row (only the subscription-named pages keep
  "Failed subscription: …" — the evidence pass reads the facts-table Subscription row, never the
  TITLE); incoming-connection pages "Incoming connection: <ip>".
- **Durations / counts follow scope**: the dwell Gap per day = Processed Files only; Hour ×
  weekday and the anomaly Files spike / drop count OK Files; Security Parameters value counts skip Unknown legs so a value equals its
  value page's Total; Recovered files / Retries / One-legged per-subscription tables skip Unknown.
- **A per-DAY cell never links a full-period page** (Top view Waiting / Expired day cells are
  plain; the TOTAL keeps the link); a day-page line links a page that can narrow to that day
  (Files in error → failed-files with `axway_date`, One-legged → `pirates-per-day`).
- **No one-tab tab rows** (episodes renders as `transfer/episodes.html`); no report-page prose —
  the Monitor INTRO went (help page); help pages load style.css with `?v=`.
- **Detail pages**: the Waiting/Expired summary is HELD and rendered after the Features block
  (`we_table`), so the section order does not depend on whether an entity has such Files.

## Rules from the fourth 2026-09-30 "few little things" batch (user request)

- **Partners in** (`analyses/partners-in.html`; "Partners - Incoming" until 2026-09-30) = the FE overview + the
  WHOLE former Logons › Incoming funnel, one row per login: Login · Use cases · Cloud · Gateway | Files in ·
  Files out · Error · Retrieved · Waiting · Expired | Oldest waiting | Pickups | Allowed · Disallowed ·
  Authenticated · No account · Bad key · Key failures · Locked · Auth failed · Session errors · Re-screens |
  First logon · Logons · Pattern. Dropped as the same figure twice: the funnel's Last logon (= Cloud) and the
  summed Auth Failed. Drills re-keyed (Incoming cells 1..7 → 12..18, 9 → 20, 14 → 21); full period
  (`nofilter`); tint = the login result colour; logon.rpt's WARN is carried. (The Incoming screening-verdict
  tint and @data:seen went.)
- **Partners Out** (`analyses/partners-out.html`, `bin/analyses/reports/partners-out.sh`, analyses wave 1)
  replaces Logons › Outgoing: one row per host we connect OUT to — base/_hosts.tsv ∪ the Outgoing hosts ∪ the
  logon summary's outbound target addresses (via input/ip/ip-hosts.tsv, else the raw address). Remote host ·
  Use cases (the evening of 2026-09-30, user request: "have a second column Use cases, just like on Partners
  In, remove the subscriptions column" — the Partners in cell's rule, UC1..UC4 by name prefix else
  xref/_subscriptions-ucderived.tsv, over the host's configured xref/_hosts-subscriptions.tsv ∪ the
  Outgoing session join's tried ones) · Connections · Last connection (_logons-hosts.tsv fields 10 / 12 over the name
  + its addresses = the host page's figures) | User · Failures · Password · Key · Certificate · Other · Reason
  (last seen) · First · Last (the Outgoing pairs folded per host, 10 newest lines as the drill). Tint = host
  result colour (raw addresses untinted); 0 blank; full period; baked order Failures, Connections, name.
- **logon.rpt is PAGELESS**: table 1 Incoming, table 2 Outgoing, field positions unchanged, no TABLE modifiers /
  KIND / RECALC (HEAD stays as the legend), no Outgoing buckets. Positional readers: partners-in.sh,
  partners-out.sh, reason-boxes.sh boxes 20 / 21, verify.sh. The Scanners table is its own component
  `logon-scanners.rpt`; **Logons** = Scanners · By account · By source IP (logons.sh merges logon-scanners +
  auth-activity).
- **Partner scorecard, Blast radius and Application dependencies are GONE** (writers, .rpt, pages, help pages) —
  never restore; verify.sh asserts the absence.
- **Top bar**: Overview · Errors · Duration · **Partners** · Waiting/Expired · Entities · Files + the search icon
  ("Partners: In / Out" until the evening, user request: ONE link → `analyses/partners-in.html`, Partners Out
  through the Partners group row; a fixed path in topbar.js like Duration; linkcheck models the edge; verify.sh
  checks the order and that the `.entpair` pair is gone).
- The day pages' "Logon screening failures" / "Outbound logon failures" lines open Partners in / Partners Out
  WITHOUT ?axway_date (full-period pages).
- **The view row Endpoint · Accounts · Partners** (the same evening, user request: "Accounts & Partners must give
  the same reports, but now with the Entities Accounts & Partners"): each writer emits the NAV row in its
  Endpoint .rpt (`partners-in.html` / `partners-out.html`, unchanged URLs) and writes `partners-{in,out}-accounts.rpt`
  + `-partners.rpt` by **`bin/rpt-rollup.awk`** — the Endpoint .rpt read BACK and regrouped per entity through the
  configured pairs (`xref/_logins-{accounts,partners}.tsv`, `xref/_hosts-{accounts,partners}.tsv`), one rule per cell
  (sum / max / min / age / uc / list / stamp / best:N — its header), drills merged (newest DCAP / LCAP kept), tint =
  the entity's result colour. UNION attribution (a login / host paired with two accounts counts for both), so
  the TOTAL counts every mapped endpoint row ONCE (the distinct total); an unmapped endpoint (raw address,
  old-gateway-only login) is in no entity view. `bin/analyses/publish.sh` renders the four view pages after
  `render_subs_group_pages` (the Endpoint help page, their own report key); `apply_report_groups` gives them the
  Partners row by stem. verify.sh checks the rows, the names and the totals. A column change in a writer needs
  its RULES string changed in step (one rule per ROW field from field 3).

## Rules from the seventh 2026-09-30 batch ("a few different things", user request, late)

- **Partners in**: Files Out = Count · Errors · Retrieved · Waiting · Expired (the Pickup group merged in,
  `gsep=2,4,9,13`); verify.sh checks the 5-column banner and that no Pickup banner is left.
- **Protocol, Direction & Mode** has two tabs, Direction × action by · Mode: the Protocol × direction tab
  (`protocol-protocol-direction.html`) is GONE, with protocol.sh's per-protocol / per-direction / per-action-by
  aggregates (unread since 2026-09-29). Never restore; verify.sh asserts the absence.
- **No Reports pulldown; six more top-bar links** — see "Report groups and menus" (the cluster:
  Overview · Errors · Duration · Partners · Waiting/Expired · Security · Seen · Configuration · Use cases ·
  Patterns · Activity · Entities · Files + the search icon).

## Rules from the sixth 2026-09-30 batch ("a few different things", user request)

- **No search-syntax hint**: the "Wildcards: ? = 1 character, * = 0..n characters …" line under the search
  boxes (report.js `SEARCH_HINT`, the `.essearchhint` / `.controlshint` rows) is GONE everywhere; the search
  box tooltip still explains the syntax. Never bring the visible hint back.
- **NEVER SHOW MILLISECONDS** (site rule): a time shows as hh:mm:ss. `bin/build/display-rename.sh` (the build
  stage "display sweep") strips the ".mmm" after every hh:mm:ss in every page and data payload under docs/
  (not docs/assets/) — one perl per batch, writing a file back only when it changed (a parallel `grep -l`
  into one list garbled the names). Presentation only: caches and .rpt keep the milliseconds; the drill
  decoders match by pattern, never by position. A manual per-area publish shows them until the next build.
  verify.sh fails on any hh:mm:ss.mmm left outside docs/assets/.
- **THE VIEW CARRY** (`apply_report_groups`): a page `<stem>-<view>.html` links a sibling group member at
  ITS `<stem>-<view>.html` when that page exists, else at its landing page — Partners in ⇄ Partners Out keep
  Endpoint / Accounts / Partners (the request), and so do the other same-named tabs (Connections ⇄ Logons
  › By account, Entity coverage ⇄ Missing entities › Accounts). Entities, xref and Month stats never carry.
- **Menus** (later that night, user request): the **Partners** group is NOT a Reports pulldown line (like
  Entities / Errors / Overview — the top bar's Partners link, now right AFTER Duration: Overview · Errors ·
  Duration · Partners · Waiting/Expired · Entities · Files); the group stays for the start page, the sitemap and
  the rows. **Coverage** opens on **First seen** (its first member, the pulldown's landing), then Entity
  coverage · Not in Flow Manager · Skipped · Missing entities. verify.sh checks the order and the menu.

## Rules from the fifth 2026-09-30 "few little things" batch (user request, the evening)

- **Waiting & Expired › Subscriptions**: Oldest Waiting / Last Expired are one-unit AGES to the data's last
  record — `bin/fmt.awk hage1` ("5d", "16h", "14m", "40s"; the seconds as `@{sortval=…}`), the Expired
  count KIND `numfailed` (red on a tinted row; `numerr` loses its tint there), default sort Oldest Waiting
  descending (`sort=4:-1`, baked the same way). verify.sh checks the cell shape, the KIND and the sort.
- **Every Errors-group page has the From/To selection**: Error reasons, One-legged › Details, Per flow,
  Unknown transfers › Per account and Errors › Reasons over time carry per-row `@data:buckets` (dated form,
  in date order) + RECALC — their counts (and Per flow's Share) re-count for the range, a row with nothing
  in range hides, First / Last columns and drills stay full-period; Recovered flows only dropped nofilter
  (its episodes are computed over the whole window; a range shows those whose date span overlaps it). A new
  Errors-group table must be date-aware (no nofilter) — verify.sh asserts it per page.
- **Partners in / Partners Out look alike**: both open with Name · Use cases | **Files In** (Count · Errors) |
  **Files Out** (Count · Errors) under a GHEAD banner; then Partners in: Pickup (Retrieved · Waiting ·
  Expired) | Logons (Logons · Cloud · Gateway · Pattern) | Screening (Allowed · Disallowed · Authenticated ·
  Bad key · Locked · Auth failed); Partners Out: Connections (Connections · Last connection) | Failed logons
  (User … Last). Partners in dropped Session errors, Re-screens, First logon, No account, Oldest waiting,
  Pickups, Key failures and the combined Error (user request) — they stay in logon.rpt / fe-overview.rpt for
  their other readers. fe-overview.rpt gained Error in / Error out (fields 14 / 15, the Failed Files by
  movement; @data:res moved to field 16); Partners in Errors = Failed (Expired has its column). Partners Out
  Files = the Entities Remote Hosts rule (every distinct leg host of a dated OUT-connection File, In / Out by
  movement else connection side, Errors = Failed or Expired), computed by a pre-pass over the two caches.
  The funnel drills are re-keyed to 13-17 (Allowed · Disallowed · Authenticated · Bad key · Locked); the
  rollup RULES / ORDER strings changed in step.

## Rules from the third 2026-09-30 "few little things" batch (user request)

- **Logons**: the Near misses and Certificates tabs are GONE (logon.sh no longer writes the FE-namespace
  knocker table — those names stay out of Incoming, listed nowhere; auth-activity.sh no longer scans the
  certificate lines); tabs Scanners · By account · By source IP (Incoming / Outgoing became Partners in /
  Partners Out, fourth batch).
- **logon.rpt's Outgoing Subscription field names the subscription that tried** (a Logons › Outgoing column,
  after User, until the fourth batch; Partners Out showed it until the same evening, now it feeds its Use cases): the sessions of the pair's
  failed attempts joined to the transfer legs of the same connection (`_transfers.tsv` col 24 → col 6,
  the site's session join; a session naming two flows names neither; `Unknown` is no subscription),
  one `@{alist=subscriptions}` cell. reason-boxes reads the Outgoing Last date as field 12 now.

## Rules from the second 2026-09-30 "few little things" batch (user request)

- **Waiting & Expired** (`transfer/waiting-expired.html`, `bin/transfer/reports/waiting-expired.sh`)
  REPLACES Waiting and Expired (never restore those pages, writers or help pages). Summary (Date ·
  Waiting · Expired) = per START day, every dated Waiting / Expired File incl. Unknown, so its totals
  equal `_files.tsv`; its counts drill to the day's 10 newest. Subscriptions (Waiting · Expired ·
  Collected · Oldest Waiting · Last Expired) is `nofilter`, skips Unknown, tints by the subscription
  colour; its Waiting / Expired cells open the `waiting/` / `expired/` File lists. The Entities
  Waiting / Expired cells, the Top view TOTAL cells and the day-page lines link here.
- **Top bar**: Overview · Errors · Duration (`transfer/duration.html`) · Partners · Waiting/Expired
  (`transfer/waiting-expired.html`) · Entities · Files + the search icon (Partners: fourth batch, after Duration since the night); NO data period.
- **Column groups**: the `gsep` gap is 30 px site-wide (= the home table's spacers).
- **Activity › Per weekday**: Weekday · Days · Files · Avg/day · Volume · Load — Files = the OK
  Files, no Error %. The Per week / Per hour tabs keep "OK Files".

## Rules from the 2026-09-30 "few little things" batch (user request)

- **Reports pulldown**: Performance is the FIRST group line (after the Start page); Overview,
  Entities and Errors above it in `_report_groups` are top-bar links.
- **Security Parameters = one report with the SSH security tables** (transfer/security-params.html):
  `bin/server/reports.sh` runs `append_rpt_tables -f "$TRANSFER_REPORTS/security-params.rpt"
  ssh-crypto.rpt ssh-sessions.rpt`; `ssh-security.sh`, `server/ssh-security.html` and
  `help/server-ssh-crypto.html` are GONE (never restore). The Deprecated-parameter warnings rows
  carry their own `@data:res` (the server publish's automatic subscription tint does not reach a
  transfer page). A hand-run security-params.sh drops the SSH tables until the server reports run.
- **Entities Waiting / Expired cells LINK** `transfer/waiting-expired.html` (waiting.html /
  expired.html until the second batch the same day) — on the
  Subscriptions pages with `?axway_row=<subscription>` (the real name, URL-encoded), the other
  entities the page itself; their `coreids-wait` / `coreids-exp` drills went (S| fields 28–29 stay,
  empty). report.js `setCellVal` keeps a recalculated cell's ONE link (a 0 blanks the cell).
- **Duration** = the per-day table Date · Files | Average · Median | p10…p100 (`gsep=2,4`; Min / Max
  went — Max = p100; the home reads p50/p75/p90/p95/p99 by title from ROW fields 8/9/10/11/13) BESIDE
  the Duration distribution of the same scope (duration-distribution.sh folded into duration.sh).
  **Store-and-forward** (`duration-dwell.html`, "Distribution & Store-and-forward" until 2026-09-30)
  is written by dwell-time.sh itself (merge-duration-dwell.sh went). Anomalies' Typical = the baseline
  the ratio used; the "(floor; typical …)" note went.
- **Longest Files**: 250 rows (the L set), columns Duration · Start · End · File · Subscription ·
  CoreId, the WHOLE row opens the File page.
- **Server-log lines never wrap**: ONE class `.logline` (`white-space:pre`) — render_rpt sets it on
  KIND `prose` cells and the Message / Message shape / Example message / Latest message / What goes
  wrong columns and the LOGCARD message; report.js on log-line drill entries. The page scrolls sideways.
- **A CoreId links to its File page, site-wide** (render_rpt): a cell whose value is a CoreId in
  `_filepages.tsv` links `files/<id>.html` (whole-cell `cl`; prefix `FPRE` from the page depth); the
  row's file-name cell (KIND `file`, or a File / File name / Filename column) links the same page when
  the row holds exactly ONE such CoreId (`ROWFP1`); not on TOTAL rows, row-drill rows, cells with an
  explicit link or `Value` columns. report.js still adds the File Tracking ↗ after an id that is a
  link. A writer needs no `@{href=../files/…}` of its own on a CoreId cell any more.
- **File names never wrap or get cut**: `td.file` (KIND file) and `td.fn` (text-KIND File / File
  name / Filename columns) are `nowrap`; the 480 px ellipsis went.

## Rules from the 2026-09-30 lean rounds (user request: "make this site mean and lean")

- **Shared awk helpers**: a date, byte / duration formatter, `lit()`, HTML escape, slug or numeric
  quicksort comes from `bin/date.awk` / `bin/fmt.awk` through `"$AWKLIB"` (`awk … "$OTHER_AWK$AWKLIB"'program'`),
  never a pasted copy. Pick the NAMED variant that gives the output you want; add a new named variant
  rather than changing an existing one. A program that injects `$AWKLIB` must not define those names
  itself (mawk rejects a function defined twice) nor use them as variables (`slug` is a variable in
  many writers — hence `slugof`). The server reports build their `LINK_AWK` from the `SRV_*_AWK`
  strings and `known_names` in `bin/server/lib.sh`. `details_writer.awk` runs as
  `-f bin/fmt.awk -f details_writer.awk`. `hbytes2` / `hbytes0` are the awk twins of report.js
  `humanBytes` / `humanBytesInt` — KEEP IN STEP. render_rpt runs `-f bin/fmt.awk -f bin/render_rpt.awk`
  (html_esc, slugof); entity_res_block takes hbytes0 / qsortn from `$AWKLIB` (its hshort / pr / nz /
  dtint stay: they mirror entities.sh FMT_AWK).
- **Compact payloads** (see RECALC, Drill-down, the Entities pages): what the renderer SHIPS is
  encoded; report.js decodes it first in `init()`. A static round-trip check (decode every shipped
  attribute and compare with the writer's dated form) is the proof for any change there.
- **One pass per publish**: no publish catch-up modes; the Reason catch-up (`failed.sh catchup`)
  runs in the report stage. Keep it that way: a new cross-phase dependency goes BEFORE the publishes.
- **Compact slot-chart series** (2026-09-30): charts_lib `rc_cards` writes a contiguous series as
  `=S<YYYY-MM-DD>T<HHMM>~<o|d|m>|<values>|…`, re-checking every slot's label and date (the original
  is kept on any mismatch); slotchart.js `expandSeries()` rebuilds `label:values:date` before
  `parse()`. A new series writer keeps the contiguous walk and the label shapes `MM-DD HHh` /
  `MM-DD` / `HHhMM`. KEEP IN STEP: overview.sh `slotlab`, the day slot labels, `rc_cards`,
  `expandSeries`. overview.sh `slot_sidecar` sums the PeSIT / EventQueue sidecars; day/reports.sh's
  two passes share `DAY_FN_AWK`.
- **Security**: security-outreach.sh is security-params.sh's WRITER (not pooled): ONE pass over
  `_files` + `_transfers` col 19 feeds both reports. reason-boxes builds its newest-OK-END map once
  (`$TMPD/lok.tsv`) for boxes 14 / 20 / 21 / 15. (A cross-script `_lastok-end.tsv` was NOT made:
  result.sh / kaput-evidence / filepages / details.sh use DIFFERENT rules.)
- **SSH readers** (lean round 3b): `bin/ssh-family.awk` also holds `acctof(m)` — the account of the
  first `ACCOUNT@FE<digits>` token, an exact `index()` twin of
  `match(m, /[A-Za-z0-9_.-]+@FE[0-9]+/)` + `sub(/@.*/, "")` — injected into uc2-status + uc4-status
  (never paste the regex back). `LOGLINES_AWK`'s drill ring keeps its per-key state in
  integer-indexed arrays (`_LLi[p]` = the id): test membership with `(p in _LLi)`, never `_LLn`; a
  line booked under several keys builds the key once and calls `addkey(p, key)`. `date.awk minof`
  and `logons.sh secof` keep a one-entry day-number cache (a set flag + a STRING comparison
  `(d "") != cache` — an empty or numeric-looking date against the unset cache compared equal).
- **Folding logon.sh's per-line pass into the logon summary** (S-04, measured 2026-09-30, user
  request, NOT done): the shared work is only ~25 % of logon.sh (read + split + family
  classification, ~−5 CPU-s on production); the rest would move into the single-threaded
  background summary the build waits for before the server reports — ~+20 s production WALL (its
  "waited 2s" would become ~27 s) plus a details.sh `ensure_logons` duplicate-compute risk. The
  summary's long wall time is harmless: it is hidden behind other work. Do not retry.
- **Measured, not worth it** (do not retry): an `inbound` server subset, a `day` marker subset for
  day_srv, sharing the three `_files.tsv` subscription sorts (<0.5 CPU-s), one shared SSH subset for
  the logon family readers (breaks even), `grep -F` prefilters (slower than mawk).

## Rules from the 2026-09-29 Errors / Unknown change (user request)

- **The Errors group** (Failures until 2026-09-29, "Rename Failures to Errors"): NOT on the
  Reports pulldown — its own top-bar link (`ERRORS_HREF`, the group's first page, Failed
  Subscriptions; `errors` in topbar-data.js). The top bar's Overview · Errors · Duration · Partners · Waiting/Expired · Entities ·
  Files (2026-09-30 order, user request) are ONE cluster (`span.entgroup`, the entity-search icon after them; Overview joined later that
  day — `OVERVIEW_HREF` = transfer/topview.html, `overview` in topbar-data.js) in topbar.js buildTopbar.
- **Sub-rows** (`_report_subrows`, publish_lib.sh): members of a group that collapse into ONE
  entry of the group's first row (its label, landing on the first of them) and get a SECOND row
  of their own on their pages — "Server log" = server errors / failure-flows / io-errors /
  routing-errors ("move the 4 server logs to … a second selection, have Server log as first
  selection"). apply_report_groups emits both rows on one queue line.
- **went-kaput.html is gone** ("Remove server/went-kaput.html"). And since 2026-09-30 (user
  decision, "would we gain much when removing went-kaput.sh?") so is the script as a REPORT:
  `bin/server/reports/went-kaput.sh` became **`bin/build/kaput-evidence.sh`**, a build-only
  step that writes ONLY `data/server/reports/_kaput-evidence.tsv` (the Reason evidence failed.sh,
  the Entities Error view and reason-boxes.sh read); `went-kaput.rpt` and the day pages'
  "Trouble after success" line are gone (the .rpt had 0 rows on both runtimes). The colour never
  read it (result.sh `_build_kaputflip` is its own join). Never restore the .rpt or the line.
- **Trends, Route throughput and Punctuality are GONE** (later the same day, user request "Remove
  the reports trends-*, route-throughput, punctuality-*"): trend.sh, duration-trend.sh,
  trends.sh, expected-arrival.sh, merge-punctuality.sh, route-throughput.sh and their help pages
  deleted; `punctuality.sh` stays as a PAGELESS producer (`punctuality-src.rpt`, one table, no
  drill) — the Polling / UC3 polling file-arrival slot (bin/cron-observed.awk). The dashboard
  Wire throughput card lost its card link (slots still open the day; the Monitor dashboard went 2026-09-30).
  Never restore them.
- **The Unknown subscription**: `_files.tsv` col 12 / `_transfers.tsv` col 6 = `Unknown` for a
  File no attribution pass could place (parse.sh; session-sites.sh rescans those sessions).
  EVERY subscription-keyed table skips it (an explicit `== "Unknown"` test in the writer:
  subscription / entities / month-stats / cross-reference / details (+ details_lib stream) /
  failed / episodes / punctuality / red-run / recovered
  / retry / security-params / same-protocol / size-dist / size-profile /
  went-quiet / waiting-expired / file-in-file-out / entity-search /
  not-in-flow-manager / the boxes sidecar / the day and overview
  Top-5s); FILES tables (failed-files, File pages, incoming-connections, all-files, …) keep it as
  the Subscription value, unlinked. **A new subscription-keyed writer must skip it too** —
  verify.sh fails on any `ROW⇥Unknown⇥` outside the Files tables. `Unknown transfers`
  (transfer/unknown-transfers.sh, Errors group; the transfer serial tail, once — its File-page
  links test `_filepages.tsv`, final before phase 1) lists every such File + a per-account table; verify checks
  its row count against `_files.tsv`. Unknown Files cannot read Processed (no movement), so they
  are Error or Waiting / Expired.


## Rules from the second 2026-09-29 removal batch (user request)

"Remove the next reports (including building the .rpt file for it) … Remove the report finder,
remove the dark theme button (and logic behind it) … docs/files/ store only the last OK and the
last 3 errors of a subscription … Move Overview to the top menu bar, just before Entities":

- **Gone — never restore**: Sources and targets, Data diff ("Since yesterday"), Triage, File
  journey › Last leg and › In and out (arrived-left), Episodes › Episodes (the page is now
  Recovered flows alone, help slug `recovered`), Subscriptions in boxes (the page; the
  `_subs-boxes.tsv` sidecar stays), the whole Cleanup group (Cleanup backlog, Config hygiene,
  Whitelist audit, Account sharing, Twins — config-defects.sh with them), the Report finder
  (`tools/report-finder.html`, FINDER_AWK, `setupReportFinder`, the KEYWORDS directive), the
  Ctrl+K palette, the dark theme (◐ button, `setupTheme`, `bin/darken-css.awk`, the head
  scripts), `bin/build/drill-files.sh`. verify.sh asserts the absence.
- **The sitemap** is ONE flow of cards (`.smcols`); the last card is **Tools** (Home, Search, All
  files search, Help, Build report; What is new went later that day).
- **analyses/accounts.html** has no Breaking naming rules table; **Failed Subscriptions** ends
  with the CoreId / SessionId column.
- **docs/files/** = the `_filepages.tsv` set (see `files/` above): per subscription the newest OK
  (O) and the three newest Error Files (E), plus the Longest Files page's rows (L, 2026-09-30: the
  250 longest delivered Files, at most 10 per subscription — `bin/transfer/filepages.sh` makes the
  selection, `duration-longest.sh` lists exactly those rows, each row opening its File page). A new writer that links a File page tests membership there
  (or, for a drill, lets render_rpt's `data-fp` decide).

## Rules from the external audit of 2026-09-29 (audit.html in develop/, 17 findings)

Herbert: "drop F17, skip the items that need a decision, fix the rest". F03 (the JSON kind
sniffing) and F06 (what "now" is for Waiting ages) are open ON PURPOSE; F17 was about the
removed trend.sh. Fixed:

- **A raw value that can begin with `@` goes out through `lit()`** (F07): `@{}` + the value — the
  EMPTY metadata block — so a partner-chosen file name like `@data:res=green` or
  `@{colspan=7}x.csv` renders as literal text instead of a row attribute or a cell attribute.
  Every file-name cell writer carries `function lit(s)` (bash writers: `case $v in @*)
  v="@{}$v"`). A cell that already leads with a writer block (`@{href=…}name`) needs none — the
  text after a block is always literal. **A new writer of raw names uses lit() too**; the check is
  a scratch build with every sample file name prefixed `@data:pwnd=1` (0 pages may carry `data-pwnd`).
- **The transfer tokenizer frames LOGICAL records** (F08): a line that leaves a quoted field open
  (`csv_open`, set by split_csv) is held and the next physical line joins it; a held record that
  never closes (the next line opens like a record, 64 lines, or end of file) is dropped and
  counted (`WARNING: dropped N CSV record(s) whose quoted field never closed`).
- **Search globs never become a RegExp** (F12): `globMatcher` is the two-pointer walk — ONE copy in
  report.js since 2026-09-30, exported with humanBytes / fileState / fileTint / fileCell as
  `window.AXWAY_UTIL` for sub-files.js and all-files-search.js (the all-files engine defers its
  initial `?f=` / `?s=` search to it). **A "quoted phrase" is ONE search
  term** (F10): parseQuery swaps each phrase for a placeholder before the operator split, so
  and/or/not inside quotes is text — the Failing reasons links search `"<reason>"`.
- **The all-files bloom files the Unicode-lowercase trigrams too** (F11) for a name holding
  U+212A (Kelvin → k) or U+0130 (İ → i + U+0307).
- **A failed full CSV export saves NOTHING** (F13): `_csvAll` answers `cb(null, why)`, the hotspot
  reads `csv ✗` with the reason in its title, a click retries.
- **`?axway_date` follows USER date changes** (F14, `syncDateUrl`): from..to (one day: the day),
  `all` when the URL carried a date, nothing otherwise; data-date-reset pages only rewrite a
  date the URL already had.
- **Fitted duration axes keep two ticks** (F16): the ladder runs to 7 d.
- **punctuality.sh is circular** (F15): minutes unwrap around their circular mean before the
  median / spread / late test (a 23:58 / 00:02 flow is 00:00, not 12:00 ±718).
- **Expiry needs a deletion at/after the STAGING END** (F05): `_files.tsv` col 24, not the start.
- **Intake** (F01, F04): `environment.txt` / `README.txt` are refused in ANY case (APFS is
  case-insensitive); `fm_valid` rejects a FlowManager export whose string-processed fields
  (`.name`, logins, hosts, AllowIP*, tags, parameters/status/participants shapes) have the wrong
  type, or that holds more than one JSON document — the archive stays in the inbox.
- **The build lock** (F09): a stale lock is reclaimed under `build/.buildlock.reclaim` with the
  PID re-read while holding it; `release_lock` removes the lock only for its owner.

## Conventions / gotchas

- **Endpoints are canonically LOWERCASE everywhere, data files included** — lowercased at the
  source; downstream needs no folding. Readers of `input/ip/` lowercase the HOST column at
  read time (the map is an input, kept as written).
- **"Subscription" naming**: the entity is **subscription** in display text and visible internals.
  Still site-named (data model): the KIND token `site`, the parse-cache columns, `sites.tsv`, the
  `Transfer Site` CSV field.
- **Separator folding (`_`→`-`) is a SORT affordance, never an identity rule**: report.js
  `sepFold` is used by `sortTable` only. Matching, counting and linking use the RAW name — the
  exports carry both spellings as SEPARATE entities; folding merges two entities.
- **UI terms "Transfers" / "Files"**: a physical log record (one leg, `_transfers.tsv`) displays
  as **Transfers**; a logical transfer (one CoreId, `_files.tsv`) as **Files** — the site's one
  counting unit. **CoreId** stays the internal term.
- **UI terms "Error" / "OK"**: the outcome split displays as Error/OK in ALL rendered text; every
  INTERNAL name keeps the failed/processed vocabulary (the raw `Status`, the outcome column, KIND
  tokens, CSS classes, `@data:coreids-*`, the coverage TSVs' P|F). Exception: raw status values
  shown verbatim.
- **Status handling**: per-ROW splits treat `Status == "Processed"` as OK, else Error. For FILES,
  the outcome policy (Waiting = OK, Expired = Error).
- **`transfer-profile` is PARSE-INTERNAL ONLY** — no pages, no xref tables, no
  Entities/coverage/search rows, no result colour, no column KIND. What remains is plumbing the
  parse needs (cache columns, the reverse config fallback, the XREF vote) — dropping it would
  silently delete ~4% of Files via the no-subscription skip. **Do not surface a RAW profile in a
  report or page.** ONE layer sits ABOVE the profile and IS surfaced:
  **Logical** (2026-08-31, user request), the `customAttribute_FlowIdentifier` values condensed
  into logical flow groups (the acc-vs-prod **FlowID** pages that showed the raw values were
  REMOVED 2026-08-30, user request — no raw profile value surfaces anywhere), which is
  a FULL first-class entity with Partner parity: `base/_logicals.tsv`, the xref pairs (incl. the
  `_profiles-logicals` FlowID → Logical map), the Entities views (`entities/logical-*.html`),
  detail pages (`details/logicals/`), coverage, search, ranking, first-seen, cross references,
  result colours and the KIND token `lgc`. The profile itself stays parse-internal — Logical
  surfaces the flow GROUP, never a raw profile value.

## Directory layout

Every pipeline script lives under **`bin/`** — `bin/acc.sh` + `bin/prd.sh` (the develop→runtime code
sync) included; the committed repo top is `bin/ assets/ docs/`, `tools/` (two STANDALONE
raw-export helpers, `one-leg.sh` / `uc2-waiting.sh` — Git-for-Windows-safe, no site libs, not
part of the build), the three `.md` docs, `.gitignore`/`.gitattributes` and **`input/`** — in
THIS repo committed IN FULL, sample CSVs included (the whole estate is synthetic and small;
`bin/sample/generate.sh` — no argument — rewrites it as ONE estate, the union of the former
acceptance and production sample rosters; the `KEY = "acceptance"` constant in
`bin/sample/estate.awk` is only the PRNG namespace that keeps the generated identities stable). `input/` holds the flow-manager JSONs, the
`ip/` and `renames/` maps, the `.sample-estate` marker + `.sample/` spec, and the hand-maintained
files at its root: **`environment.txt`** (the checkout's label — see "Environment"),
`blacklist.txt` + `skip.txt` (see the attribution chain),
`rename.txt` (DISPLAY renames, applied to the rendered pages by the build's last step; see the
manual re-publish gotcha), `logical.txt` (fixed FlowID → Logical
transforms feeding the Logical entity derivation — owned by `bin/flow-manager.sh` since Logical
became a full entity; a listed FlowID skips the derivation),
`BL.txt` (BL numbers per subscription, `<subscription> <BL>[,<BL>...]` — several numbers
comma-separated in the second field — a SECOND source of BL entities beside the subscriptions.json tags,
unioned in `bin/flow-manager.sh`; the real files live in the runtime repos' `input/`, develop's are
the sample template), `logons_old.txt` (2026-09-02: the FE logins' last logon on the OLD gateway, `<login> <stamp>` per line — the Partners in page's (Reports › Partners) Gateway column; hand-maintained, sample template in develop), `coreid-url.txt` (2026-09-07: the SecureTransport File Tracking URL every CoreId on the site links to — ONE line, `@COREID@` where the id goes; hand-maintained per checkout, the REAL admin hosts live only in the runtime copies, develop's sample carries an `.example` host — read by `publish_lib.sh` into topbar-data.js) and
`logical_{domains,apps,partners}.txt` (hand-curated FROM→TO PART replacements for the
Logical-based PDA derivation: part 1/2/3 of a three-part Logical name is replaced before it
becomes the domain / application / partner-merge token — and since 2026-09-06 the Logical NAME ITSELF is recreated as Domain_Application_Partner from the replaced parts (the STREAM partner rule included), in the LOGICAL block before the base list / pair caches / PDA read the map, so two Logicals replacing to the same parts become one (the rule trail says "parts replaced").
**`logical_partners.txt` is also where PARTNER ALIASES live** since
2026-09-01, user request: the retired `partner-aliases.tsv` said "these two tokens are one
organisation" and merged them into a group; rewriting the variant to its canonical token here
does the same earlier — the variant never becomes a token, so there is no group to name, and
merge rule 4 plus the alias star went with it. ONE HARD-CODED rule sits beside them in `bin/flow-manager.sh`, 2026-09-03,
user request: a Logical whose name contains `STREAM` takes the partner `ACCEPTEMAIL`, exempt from
the merges), plus a
README.txt per directory. Gitignored: the `data/` root, `/build/`, `/archive/` (the retired retention step's 7z files) and `input/secrets/` (RUNTIME only: the st-reports archive password, generated by `st-reports-archive.sh`). A step script that
only `bin/build.sh` ever invokes lives in **`bin/build/`** — the placement rule; the sample-data
generator lives in **`bin/sample/`** (guarded by the marker, seeds in `bin/sample/seed/`).

```
bin/build.sh            the whole chain (no argument)

# SHARED — sourced or called by the area scripts:
bin/envlabel.sh         input/environment.txt reader (label, inbox prefixes)
bin/fastawk.sh          the mawk PATH shim
bin/ip.sh               address<->endpoint map        bin/blacklist.sh  field blanking
bin/skiplist.sh         record dropping               bin/uc-cases.sh   uc_meta()
bin/renames.sh          subscription rename map (input/renames/) + fm_snapshot_renames
bin/ranges.sh           the byte-range split of the parallel server-cache scans (rng_feed = a dd seek; jobs own the lines STARTING in [lo,hi)) + grp_par / line_par (key- / line-aligned slices, outputs joined in order)
bin/publish_lib.sh      shared renderer + globals     bin/cron2human.awk cron -> prose
bin/render_rpt.awk      the one-pass page-body renderer
bin/merge_rpt.sh        component .rpt -> merged tabbed report
bin/check-syntax.sh     bash -n over every bin/**/*.sh (the build's and the sync's first gate)
bin/timing.sh           `timed` -> the TIME lines
bin/logons.sh           ensure_logons -> the logon summary (_logons.tsv + _logons-hosts.tsv; logon.sh's twin)
bin/ssh-family.awk      the [Ssh Default] logon-family classifier, ONE copy for logon.sh + logons.sh (2026-09-30)
bin/awklib.sh           $AWKLIB (date.awk + fmt.awk) and $CADENCE_AWK — injected in front of an awk program's text
bin/analyses/reports/uc-status-lib.sh  the UC1/UC3/UC4 status skeleton (ucs_setup, UCS_AWK: roster, red flip, Files join, ucs_walk per-hour sidecar; ucs_rows/ucs_stats) — each UC script keeps only its signal block + columns
bin/dashboards/charts_lib.sh  ONE render_card for the dashboards AND the day pages (RC_BASEIV / RC_MORE per publish) + rc_cards (the compact series)
assets/topbar.js        the ONE top bar (buildTopbar, fitTopbar, envLinks) — every page loads it after topbar-data.js
bin/date.awk            jdn / fromjdn / minof            bin/cadence.awk  patron / regspread / label (the pickup-pattern vocabulary)
bin/fmt.awk             hbytes2 / hbytes0 / hbytes1, hdurms, hdsecs, lit, html_esc, slugof, qsortn
bin/pool.sh             pool_run / pool_wait (POOL_TIMED, POOL_WHAT) — the report runners and the server parse
bin/flip-reason.awk     server-log line -> Reason      bin/subname.awk   which configured subscription a line names
bin/cron-observed.awk   schedule vs observed firing    bin/subscription-active.jq  the Active codes
bin/flow-manager.sh     config exports -> data/flow-manager/{base,xref}
bin/flow-manager-synth.sh  MANUAL fallback: the two config JSONs synthesized from the transfer logs
bin/expire-files.sh     Waiting -> Expired from the File Maintenance sweep lines
bin/bookend-ok.sh       Failed -> Processed on the server log's own ok "Transfer end logged." bookend (no reason line)
bin/session-sites.sh    Unknown groups -> real subscription via the server log's session route lines; re-keyed lone legs -> their original CoreId (_rekeys.tsv)

# BUILD-ONLY — nothing but bin/build.sh invokes these:
bin/build/result.sh              fill the base result columns
bin/build/publish.sh             index pages + the home; run LAST
bin/build/logon-summary.sh       the logon summary, once per build (background slot 1)
bin/build/newest-caches.sh       the newest-first copies of _files.tsv / _transfers.tsv (data/transfer/cache/newest/) for the top-10 ring readers
bin/build/display-rename.sh      the display-rename sweep (input/rename.txt); the last page-touching step
bin/build/linkcheck.sh           every link resolves + every page is reachable — a MANUAL gate (verify.sh runs it), build.sh never does

# DEVELOP-ONLY (never synced to a runtime):
bin/acc.sh  bin/prd.sh           sync bin/ + assets/ into ../runtime-<env> and build it (shared code: bin/runtime-lib.sh)
bin/sample/                      the sample-estate generator + verify.sh

# RUNTIME-ONLY (skipped on the sample estate — the .sample-estate marker):
bin/build/exchange-in.sh         the inbox (a git repo, ~/exchange by default — never named in output): this environment's <prefix>*.7z -> st-reports-update.sh
bin/build/st-reports-update.sh   one archive -> input/ (the log exports renamed logEntry_yyyy-mm-dd.csv / fileTransfer_yyyy-mm-dd.csv)
bin/build/st-reports-archive.sh  docs/ -> st-reports-<env>_<stamp>.7z -> build/ + the outbox (the same repo, st-reports-<env>.7z)
```

Environment overrides: `AXWAY_NJOBS` (the pool size of the pools that honour it — publish_lib's
`pub_pool`, the transfer / server report pools, the server parse and subsets; the parse / failed / session-sites / result slices use
the raw core count; default the core count), `AXWAY_EXCHANGE_DIR`
(the inbox/outbox repo, default `~/exchange`), `AXWAY_ERR_LOGCAP` (failed.sh's server-log lines
per error-page connection, default 2000), `AXWAY_TOK_SPLIT` (see BUILD SPEED), `AXWAY_SAMPLE_SEED`;
the stage modes `AXWAY_SKIP_MENTIONS` / `AXWAY_MENTIONS_ONLY` / `AXWAY_DERIVE_ONLY` /
`AXWAY_WAIT_FAILED` are set at their call sites (`bin/build.sh`, `session-sites.sh`).

All data lives under two roots at the repo top (`data/` gitignored wholesale; a runtime repo
additionally ignores the `*.csv` exports under `input/`, its one bulk item):

- `input/{transfer,server}/*.csv` + `input/flow-manager/*.json` — the raw exports
  (irreplaceable); `templates.json` optional. `input/blacklist.txt` and `input/skip.txt` — see
  the attribution chain. `input/environment.txt` — the checkout's label (see "Environment"),
  never synced, never delivered by an archive.
- `input/renames/` — `subscriptions.tsv` (old⇥current), `profiles.tsv` (the same for the
  Transfer Profile) and `flowid-names.tsv` (the previous export's `flowId`⇥name snapshot). **Machine-maintained, never hand-written**; under `input/`
  for the same reason as the DNS map — once an export is overwritten its names cannot be
  recovered, and `rm -rf data/` must stay safe. See the attribution chain, step 0.
- `input/ip/ip-hosts.tsv` — the address ↔ endpoint map (`ip⇥host`), **fully
  automatic, never hand-written**; **`bin/ip.sh`** owns it (`ip_put`, the only writer,
  cmp-guarded — the one kind of guard kept: the file outlives the build; an empty dir is valid). **There is NO reverse DNS anywhere, and none may be
  reintroduced** — the configuration names endpoints. Writers: `flow-manager.sh` forward-resolves
  the configured hosts (with `base/_hosts.tsv` as the KEEP list); `parse.sh` records each new
  OUTGOING IPv4 under the host configured for its SUBSCRIPTION first, its account only as a
  fallback (no row on disagreement; an INCOMING
  address gets no row — it stays raw in col 16). **`ip_put` UNIONS, never replaces.** Under
  `input/` because a DNS answer cannot be regenerated — `rm -rf data/` must stay safe.
- `data/<area>/cache/` — the tokenized caches + companions; `data/<area>/reports/` —
  the `.rpt` descriptors (+ `details/`, `coverage/`, `errors/`).
- `data/unknown/*.tsv` — the unknown-* sidecars, the server-log SIGHTING LISTS, one NAME per line
  (accounts/logins/sites/hosts — the stamp / message columns and `white.tsv` went 2026-09-29, no
  reader), read colour-free by Entity Search and Cross reference.
  Rewritten each run; a type with no unknowns keeps an EMPTY sidecar (its readers expect one). (The SSH-logon files went with the blue result, 2026-09-27.)
- `data/colour/` — `result.sh`'s sidecars (`_redflip`, `_ringattr`,
  `_ringorphan`, `_kaputflip`, …; `data/blue/` until 2026-09-27). `data/flow-manager/{base,xref}/`
  — the config caches. `data/.buildstats/` — the build report's input statistics, the one
  directory the build's wipe carries over.

`input/` is deliberately separate from `data/`, which EVERY build wipes: that never touches the
raw CSVs or the DNS map. The built site is the committed repo-root `docs/`.
