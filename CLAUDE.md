# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working with this repository.

**Deep subsystem notes live in `ARCHITECTURE.md`** (repo root, not auto-loaded): the attribution
chain and result colours in full, PDA derivation, dashboards + Monitor, day pages, drill-down,
home, Entities views, detail pages, special pages, Boxes pages, group lists. **Read the relevant
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
covers every planted scenario. **runtime-acceptance** and **runtime-production**
(`~/axway/runtime-acceptance`, `~/axway/runtime-production`; github `herbert256/runtime-acceptance`
/ `runtime-production`, private, no Pages) are the operational twins with the REAL exports of ONE
environment each — **never read, edit or build them from an AI session**; they have no CLAUDE.md
by design. (The old combined `runtime` repo — two environments in one checkout — is RETIRED since
2026-09-11, left in place for Herbert to delete; `bin/acc.sh` / `bin/prd.sh` refuse it.) Code flows one way
via **`bin/acc.sh`** and **`bin/prd.sh`** (no arguments — the runtime checkouts sit BESIDE this repo as `../runtime-acceptance` and `../runtime-production`; each syncs `bin/` + `assets/` + `.gitattributes` into its checkout, removes CLAUDE/ARCHITECTURE
there, then runs that checkout's `bin/build.sh`; run the two one AFTER the other, never at the
same time — every runtime build pulls and pushes the shared inbox/outbox repo, `~/exchange` by
default, which the build report and every message call "the inbox" / "the outbox", never by
name — 2026-09-12, user request; the `~/cloud` drop folder is gone since the same day); the
sync EXCLUDES the develop-only tooling — `bin/acc.sh`, `bin/prd.sh`, their shared `bin/runtime-lib.sh` and `bin/sample/` — and deletes
stale copies of them in the target, so a runtime `bin/` carries pipeline code only. The committed
`input/.sample-estate` marker gates the generator — absent in a runtime checkout, so it can never
clobber real exports. Local preview: develop at `http://localhost/develop/`, the runtimes at
`http://localhost/runtime-acceptance/` and `http://localhost/runtime-production/`.

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
the label is the TEXT of the top bar's brand/home link (report.js `buildTopbar` reads `env:"…"`
from `topbar-data.js`; `render_topbar` bakes the same link on the help/build pages; "Cloud" on a
checkout without the file — 2026-09-12, the separate label span beside a fixed "Cloud" brand is
gone) and the home title (`Cloud Reports — <label>`). **THE ENVIRONMENT SWITCH** (2026-09-12,
user request, later the same day): on a RUNTIME checkout (`ENV_KEY` acceptance|production —
`env_has_switch`) the brand slot holds the pair **Acceptance / Production** instead — the ACTIVE
site bold and YELLOW (`.envcur`), its link the home page; the OTHER one the SAME PAGE on the
other site, whose host differs per viewer, so its href is computed in the browser, never baked:
`window.AXWAY_ENVLINKS()` (publish_lib `ENVSWITCH_JS`, the ONE implementation; the four URLs in
`ENV_SITES_JS` — localhost → `http://localhost/runtime-{acceptance,production}/`, any other host
→ the two GitHub Pages sites) fills every `a[data-envto]` from its `data-root` (the page's
docs-root prefix) + the page's root-relative path + query + hash; the other site answers a
missing page with its own 404 (GitHub Pages serves `docs/404.html`; the local Apache its
default). It ships inside `topbar-data.js` (report.js `buildTopbar` renders the pair from
`envkey:"…"` and calls it) AND inline on the baked bar line (`render_topbar`: the help pages and
the build report load no script; `apply_help_chrome` swaps the whole line, so the script stays on
it). The develop/sample checkout keeps its single "Sample" brand link. `TB_VER` folds the key
and the URLs. KEEP the two markups in step; it derives the runtime
inbox prefixes (Acceptance → `acc*`, Production → `prd*` and `prod*`, case-insensitive; any other
label = the inbox skipped with a note) and names the outbox archives
(`build/st-reports-<key>_<stamp>.7z` and the outbox repo's `st-reports-<key>.7z`; the `~/cloud/`
copy is gone since 2026-09-12); a missing label FAILS the archive step. The docs root holds the site itself: `index.html` (the
home), `404.html` (self-contained; its home link = the path before the FIRST known top-level dir,
a trailing `acceptance/`|`production/` stripped for pre-split bookmarks), `assets/`, `help/`,
`.nojekyll`, `transfer/` (+ `entities/`, `secparams/`, `expired/` — 2026-09-21, user
request: one page per subscription with expired Files, Start · Expired · File name · CoreId, opened
from the Expired cells of the Expired report's subscriptions table; `expired.sh` writes the
`.rpt` set into `data/transfer/reports/expired/`; default sort = Expired descending, baked in that
order, and the CoreId of the FIRST 5 rows links `files/<coreid>.html` — the list
`_expired-files.tsv`, paged by `failed.sh` under list tag `X`; and its twin `waiting/` — the same
day: the Files still staged, Start · Waiting for · File name · CoreId, opened from the Waiting
Files cells of the Waiting report's first table, default sort = Waiting for descending via the
cell's `sortval` (the wait in seconds — the humanized text does not sort), list
`_waiting-files.tsv`, tag `W`), `server/`, `analyses/`
(+ `xref/`), `dashboards/`, `day/`, `details/` (one subdir per entity type), `files/`
(2026-09-21, user request: the ONE directory of the per-File pages — the failed-File error pages
`<coreid>.html`, the subscription-named error pages `<slug>.html` and the File pages of any
outcome; the separate `errors/` directory is GONE. Only the DATA stays split —
`data/transfer/reports/errors/` + `files/`, because failed.sh's reason-evidence pass globs the
first — and `bin/transfer/publish.sh` renders both sets into `docs/files/`, the errors set last),
`latest/` (2026-09-16: one page per subscription — its newest 1000 Files, the table the
subscription detail pages used to carry, linked from their Features "Files" row; since
2026-09-27, user request, the rows ship as DATA in the sibling `<slug>.js` — `split_table_rows`
lifts them, each payload REGISTERS on `window.AXWAY_LATEST` as `{s, n, h, r}` (slug, name, HEAD
labels, rendered rows) and report.js `latestRows()` puts them back into the `data-latest` table
first thing in `init()` — plus `search.html`, the Latest files search: every payload loaded at
once, searched by the dedicated `docs/assets/latest-search.js` — a File name or CoreId field and a
Subscription field (in that order, BELOW the From/To row — class `underdates`), results as you type, at most 500 newest-first, `?s=`/`?f=` in the URL;
it and the six `search/file-search-*.html` pages are ONE group, and the top bar's **Files** link opens THIS page (2026-09-27; both bar renderers) — a FIRST tab row right after the
`<h1>`, **Implementation 1, period** (→ `search/file-search-24-hours.html`) | **Implementation
2, latest 1000** (→ `latest/search.html`) | **Implementation 3, all files** (→
`search/all-files.html`), from publish_lib `file_search_impl_row`),
**the ALL FILES SEARCH** (2026-09-27, user request: every File, balancing the user's wait against
the size of docs/) — `bin/analyses/publish-all-files.sh`, its OWN build step after the transfer
publish catch-up (its rows link the files/ pages the failed.sh catch-ups settle; a manual
re-publish must run it too): ONE SHARD PER DATA DAY `search/all/d-<date>.js` (the day's Files
newest first, ~95 B each — name ⇥ HHMMSS ⇥ LOCAL subscription index ⇥ bytes ⇥ 32-hex CoreId ⇥
flag, UPPERCASE flag = the CoreId has a files/ page; each shard carries its own subscription
dictionary, so an old day's shard is byte-identical build to build) + the manifest
`search/all/index.js` (`window.AXWAY_AFX`: the subscription→slug dictionary and per day its count,
subscriptions, shard cksum and a BLOOM FILTER — the name trigrams that hold a non-[0-9a-f-]
character + "#"+8hex CoreId tokens, 8+ bits per item, three hashes; KEEP THE GENERATOR AND
`assets/all-files-search.js` IN STEP). The engine loads only the days that can hold a match (a
pasted CoreId: ~its own day), newest first, 4 at a time, stops at the newest 500; the table is
a `rangehook` table (From/To narrows the days; the page counts as a TRANSFER-area page in
render_rpt). linkcheck models the shard links (section 3b), display-rename sweeps the shards,
verify.sh checks that the shards hold every dated File),
`first-seen/`, `use-cases/`, `coverage/`, `transfers/duration/`, `switches/`, plus
`search/` (`search.html` + `search-data.js`, the six `file-search-*.html` + their `-data.js` payloads — 2026-09-12, user request; at the root before) and `tools/` (`sitemap.html`, `report-finder.html`, `whats-new.html` and the build report `build.html` — 2026-09-12, user request; at the root before, the build report local-only 2026-08-29..09-12). `input/` carries
the exports — logs AND the FlowManager JSONs (the real production flows are the HYBRID pattern
generation: no folder parameters, flowdir from `{source,target}_hybrid_participant`; the sample
estate carries both shapes). The manual `bin/flow-manager-synth.sh` stays as the fallback for a
checkout with logs but no config export: it synthesizes the two JSONs from the transfer logs
(one subscription per Transfer Profile, one partner per account).

- `html_head` derives ONE prefix — `base`, back to the docs root — from the css href callers pass
  docs-root-relative (`../assets/style.css` from `docs/transfer/`); the placeholder it bakes is
  `<div class="topbar" data-b=… [data-help=…]>`.
- **The top bar is RUNTIME**: pages bake only that placeholder; report.js `buildTopbar` renders
  the full bar from `docs/assets/topbar-data.js` (written by `ensure_assets`: the
  `transfer/server/analyses` menu strings with their `@` placeholder, `monitor:0|1`,
  `coreid:"<url>"`, `env:"<label>"`, `envkey:"<key>"`, `period:"yyyy-mm-dd / yyyy-mm-dd"` (the DATA PERIOD — the transfer day report’s META first/last days, shown second in the bar after the environment, before Entities; 2026-09-13, user request) + the `AXWAY_ENVLINKS` switch function;
  `?v=` stamp `TB_VER` folds the flag, the template, the label, the key and the site URLs). The
  help/build pages bake full chrome (`render_shared_topbar` → `render_topbar BASE HELPSLUG`, the
  switch script inline on the bar line) — KEEP THE TWO IN STEP.
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
the sitemap Tools card (local-only 2026-08-29..09-12; before that, in `docs/`); still
no page on the site references a build. A checkout without the two flow-manager JSON exports
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
assignment's IFS). Nothing on the site links the report.

Order, ONE linear chain (the rationale of every position is in the script's comments):
(runtime only) `bin/build/exchange-in.sh` (the inbox, by prefix; it calls
`bin/build/st-reports-update.sh` per archive, which renames the log exports to
`logEntry_yyyy-mm-dd.csv` / `fileTransfer_yyyy-mm-dd.csv` from their first record's date and tells
the JSON exports apart by content — `subscriptions.json` / `partners.json` from the first object's
`meta.href` or keys, whatever they were called — 2026-09-12) → (runtime only)
`bin/build/archive-old-logs.sh` (RETENTION, 2026-09-12, user request: keep the CURRENT and the
PAST month of exports in `input/`; every server/transfer export dated before the first of the
past month — the day from its `_yyyy-mm-dd.csv` name, else its first record — moves to the
gitignored repo-root `archive/` as `<name>.7z`, tested before the original goes; a failure is a
warning that leaves the file in place; it runs BEFORE the parses so they see the final input
set) → the have-config check → *parse*: server `parse.sh` in the background
(`AXWAY_SKIP_MENTIONS=1`: tokenize + merge only, started BEFORE the config step since 2026-09-27
— it reads no config) beside `bin/flow-manager.sh` and then transfer `parse.sh`, then — beside
the server MENTION caches (`AXWAY_MENTIONS_ONLY=1 parse.sh`, background slot 2, waited for
before result.sh) and the logon summary (`bin/build/logon-summary.sh`, background slot 1, waited for
right before the server reports since 2026-09-28) — `bin/session-sites.sh` (its re-derive is
`AXWAY_DERIVE_ONLY=1` transfer `parse.sh`), `bin/expire-files.sh`, `bin/bookend-ok.sh`,
`bin/build/result.sh`, a server-mention rescan (`AXWAY_MENTIONS_ONLY=1` again) when
`data/server/cache/.rescan-mentions` exists (skipped inside when no cache line holds an appended
name — see BUILD SPEED), `went-kaput.sh` early (its ONLY run: its evidence sidecar makes the
`_srvsubs-map` final on failed.sh's first run, so details.sh runs once) → *report*:
`bin/transfer/reports/details.sh` in
background slot 2 beside transfer phase 1 and the server reports, then transfer phase 2, analyses,
the dashboards MONITOR (`monitor.sh`, foreground: whether `monitor.rpt` exists sets every
page's top bar), then dashboards ∥ day in background slot 2 BESIDE the publishes below, waited
for right before the dashboards publish → *publish*: detail
pages ∥ transfer, then partner-groups, server, analyses, then THE CATCH-UPS — re-runs folding the
cross-phase evidence into THIS build: `bin/build/drill-files.sh` (2026-09-21 — lists the first
File of every red / orange drill cell for failed.sh to page, see "Drill-down"), failed.sh (the
boxes reasons now on disk), failed-files.sh, failing-reasons.sh, the detail-pages RE-RENDER
(`publish-details.sh` only, in the BACKGROUND beside the analyses publish catch-up — the detail
.rpt files need no second run: their one catch-up input, the REDUCED `_srvsubs-map.tsv`,
name⇥slug⇥stamp, is final after failed.sh's first run), the transfer publish catch-up,
dashboards, day → `bin/build/publish.sh` (index pages + the home, reads every area) →
`bin/build/display-rename.sh` → (runtime only) `bin/build/st-reports-archive.sh`.

Dependency rules: transfer reports before server and analyses reports; dashboards + day after both areas;
`bin/build/publish.sh` last of the publishes (the area publishes clear the dirs its index pages
live in). A script that ran twice in one build only to skip the second time runs ONCE now:
`went-kaput.sh` (not in the server-reports pool), `monitor.sh` (not in `bin/dashboards/reports.sh`)
and `details.sh` (not in the catch-up).

**BUILD SPEED (2026-09-27/28, the "prd build" analysis — production 6:34 → 3:44 min in 14 rounds,
then → ~3:18 in rounds 15-27 (2026-09-28); every round byte-identical on a develop fresh build).** What a change must not break:

- **Background slots**: `bg_step_start/bg_step_wait` and `bg2_step_start/bg2_step_wait` — ONE step
  per slot in flight; a background step's `TIME` lines are replayed at its wait. Moving a step
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
  stays on its `FNR % 6` slicing on purpose (its tie rule depends on the slicing).
- **Server-cache subsets** (`bin/server/subsets.sh`, `srv_subset NAME` in `bin/server/lib.sh`):
  the RARE message families of uc1/uc3-status, remote-poll, connection-diagnostics, ssh-key-auth
  and ssh-sessions, copied once per cache; every line a consumer acts on must contain one of its
  fixed-string MARKERS — change a consumer's patterns, change its markers. A missing subset set
  (no `subsets/.done`) falls back to the whole cache.
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
- **pda-entities.sh** computes the per-leg flags ONCE (a temp file) and runs its five dimensions
  as parallel jobs (2026-09-28).
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
`bin/<area>/`; report scripts in `bin/<area>/reports/` — EXCEPT reports whose PAGE sits in the
Analyses menu, which live in `bin/analyses/reports/` and source `../../<area>/lib.sh`. **Where a
script lives says where its PAGE goes; which `lib.sh` it sources says where its DATA goes.** All
paths are centralized in `lib.sh` (derived from `LIB_DIR`, its own location): `INPUT_DIR`,
`CACHE_DIR`, `REPORTS_DIR`, `CONFIG_DIR`, the cross-area cache/report vars, `PARSED`, `FILES` —
don't reintroduce `../../data`-style paths or path arguments.

```bash
bin/build.sh                          # everything, always fresh: wipe build/ data/ docs/, seed assets/, build (no git)
bin/build/linkcheck.sh                # verify: 0 broken links, 0 orphan pages
bin/transfer/parse.sh                 # -> _transfers.tsv + _files.tsv (AXWAY_DERIVE_ONLY=1: re-derive from _transfers0.tsv)
bin/transfer/reports.sh [phase1|phase2]
bin/transfer/reports/details.sh [TYPE]   # TYPE = ACC SITE LOGIN HOST PTN APP DOM
bin/server/parse.sh                   # -> _parse.tsv (+ per-entity mention caches; AXWAY_SKIP_MENTIONS / AXWAY_MENTIONS_ONLY)
bin/server/reports.sh
bin/analyses/reports.sh; bin/dashboards/reports.sh; bin/day/reports.sh
bin/transfer/publish.sh               # …and the other per-area publishes; then:
bin/analyses/publish-partner-groups.sh
bin/build/publish.sh                  # index pages + the home; run LAST
bash -n script.sh                     # syntax check — there is no test suite
```

**Manual re-publish gotcha**: `publish-partner-groups.sh` runs OUTSIDE the per-area publishes;
skipping it after a publish sweep leaves its pages missing. The DISPLAY-RENAME sweep
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
move. Not movable: a grouped header band (GHEAD), `data-heat`, the Boxes pages (`th[data-pf]`),
Entity Search, `dayrows`, spacer columns, any spanned DATA row; a `nocolmove` TABLE modifier can be
added if a report needs to opt out. New column-addressing code must use the built index.

**Five more runtime features (2026-09-05, report.js)**: the column PICKER (`cols` hotspot bottom-RIGHT of the
last visible cell of the TOTAL row, else of the last visible data row — `colHostCell`; that cell is
rewritten by the recalc/totals paths and changes with every sort/filter/page, so `replaceHotspots`
re-attaches `table._colTools` after each of them plus a mouseover safety net — attached LAST in init(),
after the data-orig snapshots; the Reset link at the foot of the picker restores order + columns (the
↺ hotspot is gone, 2026-09-06); csv keeps the last header cell; hidden cells carry the `hidden` ATTRIBUTE, never a class — the recalc paths restore classNames;
stored `colhide:…` beside `colorder:…`; the CSV export skips hidden cells) · MULTI-KEY sort (`sortKeys`
takes `[{ci, dir}]`, shift-click adds a key, arrows carry `<sup>` ranks; `sortTable(table, col, dir)`
is the position-based wrapper, `resort()` re-applies a table's keys; saveSort stores "ci:dir,ci:dir")
· the DARK theme (`data-theme` on `<html>`, localStorage `axway-theme`, unset = LIGHT — never the system preference, user request; the dark CSS
is GENERATED at publish from the light rules by `bin/darken-css.awk` — colour maps per property
class, appended to docs/assets/style.css by build.sh; a new light colour must be added to
its maps; the page head applies the theme before the stylesheet, help pages carry the same inline
line) · RELATIVE dates (`setupRelDates`, mouseover delegation, tooltip only) · the COMMAND palette
(`setupPalette`, Ctrl/Cmd+K; fetches `tools/report-finder.html` and `search/search-data.js` from the docs root once, stripping the `../` their hrefs carry).
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
`AXWAY_DERIVE_ONLY`, went-kaput / monitor run once). Within-build DEPENDENCY guards stay:
`ensure_logons` builds the logon summary only when it is not there yet (the background step
normally has), `srv_subset` falls back to the whole cache without `subsets/.done`, and the
appended-names mention rescan is skipped when it cannot change anything.

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
items BOTH WAYS (110 files; unconfigured = empty — `_profiles-logicals` doubles as the FlowID →
Logical MAP every report attributes a File’s profile column through, `_subscriptions-bl` as the
subscription → BL tag map, and its sidecar `_subscriptions-bl-added.tsv` carries the
`input/BL.txt` rows the `tags` do NOT hold — the Analyses → Configuration “Added BL” page), plus `_subscriptions-patterns`, `_subscriptions-flowdir`
(out|in|relay), `_subscriptions-ucderived` (2026-08: the use case DERIVED for a non-UC-named
subscription from flowdir × the pattern's one partner verb — out+pull=UC2, out+push=UC1,
in+push=UC4, in+pull=UC3; both/neither verb = no row; consumers: the detail Features "Use case"
row and every use-case-gated consumer — the UC1–UC4 status rosters, the UC3 clean-poll keep
and its clears, missing-cronjobs, account-sharing, twins, the twin rules; until 2026-08-31 most
read the name prefix alone and silently dropped the hybrid flows), `_{accounts,subscriptions}-fmlink`,
`_partner-group{s,-why,-accounts}` and `_templates.tsv` (optional export). It also forward-resolves the configured hosts into
`input/ip/`.

Nothing downstream reads the JSONs directly (except `publish-insights.sh`); everything goes via
the caches `flow-manager.sh` writes in the build's config step (no early exit — it rebuilds every
build); a missing cache degrades to an empty list.
**PDA derivation** is owned here too and is LOGICAL-BASED (2026-08-30, user request): the
three-part Logical name `D_A_P` gives part 1 = domain, part 2 = application, part 3 = partner
token; partner tokens merge (same host / shared whitelist IP / whitelisted host IP — every merge
DERIVED since 2026-09-01, the curated alias file having become a part replacement; details in
ARCHITECTURE.md), and every partner/app/domain pair cache is composed
through the FlowID. The account-name split machinery, the subscription-name fallback and the
prune are RETIRED. So is the **Logical derivation** itself (FlowID families → three-part group
names; a `-` inside a part marks parts the derivation combined, which is why Logical names are
never separator-folded) — it runs FIRST, the PDA pass consumes it. The coverage TSVs
`data/transfer/reports/coverage/*.tsv` are the materialized product (`ensure_pda_tsvs`).

### bin/dashboards/ and bin/day/

`bin/dashboards/reports.sh` → `overview.rpt` (+ `monitor.rpt`, whose EXISTENCE flags "this checkout
has a monitor"); `publish.sh` renders the Overview — 5 KPIs + one hero graph with alternate
views, all chart type `slots`, drawn client-side by `docs/assets/slotchart.js`.
`bin/day/reports.sh` writes one `.rpt` per calendar day (both logs); its publish renders KPIs →
hero → problem lists → facts → six Top-5 tables. Both run after the two areas' reports; the
UC-status stacks and cumulative "seen" views carry strict invariants — see ARCHITECTURE.md before
touching them. Consumers reading topview Date cells strip the `@{href=…}` cell attr first; the
transfer `topview.rpt` per-day table has six column groups since 2026-09-12 (Files, Recovered =
Automatic · Manual, Resubmit = Ok · Failed, Transfers, State — ROW fields 5-20 in that order),
see ARCHITECTURE.md.

## Architecture

Compute and presentation are separated. `parse.sh` owns tokenizing; each report script is a small
bash wrapper feeding one `awk -F'\t'` program that emits a **`.rpt` descriptor** — never HTML. The
publish scripts (sharing `bin/publish_lib.sh`) are the generic renderer.

### The .rpt line protocol

TAB-separated, directives `TITLE / DESC / SUBTITLE / INTRO / ALERT / WARN / NAV / STAT / LOGCARD /
TABLE / HEAD / GHEAD / KIND / RECALC / ROW / TOTAL / NOTE / LINK / SUMMARY / FOOT / KEYWORDS /
META`. `GHEAD` = an optional group-banner `<th>` row ABOVE `HEAD` (cells may lead
`@{colspan=N,class=…}`); pairs with the `gsep=` TABLE modifier, which draws the matching dividers.

- Empty `TABLE` heading → no `<h2>`. `INTRO`/`NOTE` support `**bold**` and `[[sub/name]]`
  entity detail links (slugmap-resolved at render time like a cell's `alink`; no entry → the
  plain name). **NEITHER RENDERS ON A REPORT PAGE** (2026-09-13, user request: a report explains
  itself on its HELP page only) — `render_report` sets `RPT_NOPROSE=1` and render_rpt.awk skips
  the two directives; the report's HAND-WRITTEN help page (`assets/help/<slug>.html`, compact
  bullets — see the `docs/help/*.html` bullet under Publishing) carries those facts instead, so a
  changed INTRO/NOTE means an updated help page; the Report finder shows the one-line `DESC` (the
  INTRO words still feed its search). The drill and record
  pages (files/ — the error and File pages, the record and value pages, the detail pages) keep their INTRO — there
  it states facts. `ALERT` → red banner (the
  RUNTIME register); `WARN` → amber (the CONFIGURATION register). `STAT⇥class⇥value⇥label` → info
  box. `LOGCARD⇥date time⇥message` → timestamped monospace card. `LINK⇥url⇥text` → below the
  table. `KEYWORDS` feeds the Report finder. `NAV` is emitted by publish_lib when splitting a
  multi-table report into tabbed pages (entry state: 0 link · 1 current · 2 disabled).

**THE GROUP MEMBER BUTTONS GO BETWEEN THE TITLE AND THE PROSE**: on a page belonging to a group,
the row of buttons for the group's other members renders directly after the `<h1>`, above the
intro; a row with NO group members sits under the intro (writers: `_hdr_with_nav`,
`_inject_after_h1`, `_inject_after_intro`, `render_missing_reports`/`_subs_placeholder`,
`analyses_group_tabs`; the cross pages opt out — their rows are entity selectors).

**TABLE modifiers**: `wide` · `group` · `nosearch` · `nofilter` (full-period semantics) ·
`drill=UNIT` · `totaltop` · `datereset` (always open at the full range) · `seenrows` (green =
logged, red = configured only) · `restint` (`@data:res` paints the whole row; the SERVER pages get
it automatically — see below) · `nosort` · `rangehook` (2026-09-27: the rows are built by a page ENGINE that takes the From/To range through a window hook — report.js counts the table date-aware and calls every function on the `window.AXWAY_RANGEHOOKS` list; paired with `nofilter`, latest/search.html + search/all-files.html) · `sxs`
(side-by-side; `sxs=ID` — a different id starts a new flex row) · `esearch` · `fold=` · `noagg=` ·
`sort=` · `startempty` (first paint empty until searched) · `pfnoun=` (the stat-filter total-row
noun) · `seenmode=all|seen|notseen` · `seenword=` (the Show-Seen intro noun) · `heat` (hour ×
weekday heatmap, re-tinted by quartile on a date change) · `pct=` (per-column % recompute spec) ·
`gsep=` (0-based columns that start a column group — pairs with `GHEAD`) · `pager=N` (client-side
pagination) · `zerohide=M` (on a NARROWED range, hide a data row whose re-aggregated bucket
metric M sums to 0 — a "Recovered 0" row says nothing; the full-range restore brings it back;
the recovered-files tables) · `topsel=N` (top-N re-select: the rows are the full candidate set — per qualifying
date its own top N, value-descending, each row `@data:date` + `@data:val`, rows past the global
top N baked `@data:dhide=1` — and report.js re-picks the visible N for the selected range) ·
`period=` (the date period the table aggregates, appended to the `<h2>` as a muted span;
report.js keeps it on the selected range) ·
`tab=KEY` (consecutive tables sharing KEY stay on ONE tab page of a split report, stacked and
all visible — `switch=` shows one at a time; the UC3 tab of UC status, 2026-09-05) ·
`anchor=` (id on the `<h2>`, an in-page link target) · `keephead` (keep the heading
even on a page's first table) · `rowlink` (the WHOLE row opens its target — the row's own
`@data:href` if it carries one, else its first link; report.js `setupIndexRows`).
A page with ZERO date-aware tables
renders no From/To and neither restores nor persists the shared per-area range.

**Column KINDs**: `text num failed processed numfailed numprocessed numok numerr numwarn numsep
bar file mono acct site login host ptn app dom ip lines clines pre` (`numsep` = a num column
that also STARTS a column group — the th/td get the divider). Entity KINDs link to the detail page, the
slug resolved through that dir's comprehensive `_slugmap.tsv` — no map entry, no link. `lines` =
`\x1f`-separated stacked lines; `clines` collapsible (3+ lines fold behind `⋯`); `pre` = a raw log
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
(the renderer escapes); keep TAB/CR/LF out of cells. Tables size to content; a wide table WIDENS THE
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
most-recent transfers, built by the shared `COREIDS_AWK` helper; the server reports use
`@data:loglines` (`LOGLINES_AWK`, a bounded insert by "date time" — the exports are newest-first
within a file). **The first File of a RED or ORANGE drill cell links its File page** (2026-09-21,
user request): report.js `bindDrill` makes the first entry's CoreId a link to
`files/<coreid>.html` when the cell it opens under is red / orange at click time;
`bin/build/drill-files.sh` collects those CoreIds from the transfer `.rpt` tree into
`_drill-files.tsv` (a superset: every cell that CAN tint), failed.sh pages them (list tag `D`)
and linkcheck fails on a listed File without a page. Full detail in ARCHITECTURE.md.

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
   re-run (`AXWAY_DERIVE_ONLY=1`, session-sites.sh).
3. **Config fallback** — reverse (profile's `FlowIdentifier` → subscription, disambiguated by the
   pesit-leg direction; never guessed) then forward (site → account/profile).
4. **XREF single-value fallback** — unanimous vote of the populated fields' one-value maps; HOST
   is never filled but votes.
5. **FLOWDIR fallback + SESSION JOIN + FAKE SUBSCRIPTION** (2026-08) — a still-siteless group
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
   session-joined groups agree 7-for-7). When even that fails, the group keeps the SYNTHETIC
   site **`UCx_<account>`** — counted like any logged-but-unconfigured subscription (result.sh
   `discover_logged` appends it to the base cache), EXCEPT that first-seen.sh excludes it by the
   `UCx_` prefix; it surfaces on not-in-flow-manager.
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
`_transfers.tsv` into one row per CoreId, 22 columns (`$FILES`, documented in `data/_files.txt`):

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
(Inbound+`routing`) — a UC2 file staged, not collected; a later export with the collect leg
re-flips it. **Processed** = ≥2 legs, last leg Outbound+Processed AND matching the movement (out →
`ssh`/`ftp`/`ftps`, in → `pesit`); deliberately no bytes condition. **Failed** = everything else
(incl. a lone leg). **Expired** = a Waiting file whose staged copy the nightly File Maintenance
sweep (~11 days) deleted before pickup — server-log-only evidence, so **`bin/expire-files.sh`**
joins those lines onto Waiting rows (col 22 = the timestamp; the deletion list in
`_expired.tsv`; a build step after session-sites). **SETTLED BY BOOKEND** (2026-09-09, user
request, **`bin/bookend-ok.sh`** right after expire-files): a **Failed** File whose LAST leg's transfer id a server-log
`"Transfer end logged."` JSON record ends with `"status":"ok"` + `"direction":"Outbound"` (an ok
bookend of an earlier leg of the same File does not count; the JSON's own `coreId` is NOT required
to match — it can differ from the transfer log's CoreId for the same transfer, the transfer id is
the key), and about which NO
Error/Warning line classifies to a reason (`flip-reason.awk` over the legs' sessions and the
CoreId/transfer-id mentions), reads **Processed** — the platform ends one transfer twice when the
client tears the connection down after the bytes went (ok on its fresh connection, error on the
dropped one; the transfer log keeps the error). Col 23 = the ok bookend's stamp; `_bookendok.tsv`
lists the settled rows; extracts cached in `_bookends.tsv` / `_reasonlines.tsv`; settled rows are
re-evaluated every run. The JSON bookends therefore stay in the server cache (out of the noise
list since 2026-09-09) but the mention scanner skips them.

**OUTCOME POLICY: Waiting counts as OK, Expired counts as ERROR** on every report: Error =
(`=="Failed" || =="Expired"`), OK = otherwise (never `== "Processed"`). The waiting report and the
detail State column distinguish the states. **The entity RESULT COLOUR parts company with the
policy on EXPIRED** (2026-08): an expired-last flow is ORANGE, not red — a staged UC2 copy the
partner never collected and the sweep deleted is a PICKUP problem, nothing errored — so it leaves
the red worklist while the Expired report, the Expired box and every Error count still carry it.
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
CoreIds (`login.sh`/`subscription.sh`/`remote-host.sh` join `$PARSED`→`$FILES` deduped per
`(entity,CoreId)` — per-entity counts can sum to more than the distinct total).

**PARTNER = UNION attribution**: a File counts for EVERY partner of its subscription (col 12 on
`xref/_subscriptions-partners.tsv`) unioned with col 20 (alone it misses both-partner files, empty
by abstention). **APPLICATION = the same union via the SUBSCRIPTION** (col 12 on
`xref/_subscriptions-apps.tsv` ∪ col 18 — the FlowID spine, 1:1; until 2026-08-31 it rode the
ACCOUNT, and a hybrid production account serving many flows credited every File of it to every
application the account touches). Applied in EVERY partner/application-counting consumer
(`details_lib.sh` carries the shared `SP_MAP`/`AP_MAP`); the parse fills cols 18/19 from the
subscription first, the account map only when unambiguous. Domains stay single-valued (part 1 of
the logical flow name — parse col 19 keeps one).

### Server parse — _parse.tsv

`bin/server/parse.sh` tokenizes `input/server/*.csv` (handling quoted fields with embedded
newlines) into `data/server/cache/_parse.tsv` — 6 columns: date, time, level (I/W/E),
component (T=TM P=PESITD S=SSHD; ADMIN/AUDIT dropped), message (multi-line buffered into one
row), **session** (CSV field 18 — the SAME connection id `_transfers.tsv` carries in col 24, so a
file's legs and the server lines of their connection join on it; `""` where the export wrote
UNKNOWN — no session at all on PESITD/SSHD records, ~96% of TM records carry one; the parser
walks to field 18 for it, ~15 % of the tokenize). The exports are newest-first within a file, so cache order is NOT chronological. Runs in
parallel (per-file tokenize+sort, then per-date merges — byte-identical to a global merge); also
builds the per-entity mention caches `_{accounts,subscriptions,logins,hosts}.tsv` with per-name
dirs (last 25 rows + last 10 Error/Warn; hosts match case-insensitively).

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
is the cost this filter exists to avoid; every parse applies the list as it stands. **Four server reports read those lines and were removed with them**:
`concurrency` (a `capacity` component), `event-feed` (a `platform-health` component), and
`transfer-outcomes` + `file-freshness` — both components of the merged `transfers` report, which
therefore went too, leaving `pickups` alone in the srv-transfers group. **`advanced-routing` went
the same way** (2026-08) when `AR0011/76/77` joined the list: its Routes table counted Executions
as the AR0076 total and Fail % as failures ÷ executions, so the report could not survive the
filter — `remote-poll` then led srv-routing alone, and since 2026-09-05 it is an unpublished
intermediate whose tables ride the UC status / UC3 tab (`uc3-polling.sh`; the srv-routing group, then only
`transfer-site-missing`, went with that report 2026-09-27, user request). Verified first that nothing else depended on
those lines: 0 of 136 blue entities evidenced by one, 0 of 905 entity mention caches made only of
them, 0 of 732 unknown-* seeds. The failed-file error
pages lost their JSON id join with them and now rest on the SESSION join, plus an ANY-MENTION id join
(2026-08-24: every bare UUID in a message looked up against the page's CoreId + transfer ids —
the `.stfs` segments never matched one; what it reaches is the `Error while resubmitting transfer
with id` line on the ADMIN session and the AR0086 post-processing delete on the route's).

`reports.sh` runs every server report in parallel (rosters come from the TRANSFER reports; a
missing roster is `exit 1`). The five
`unknown-*` reports are ONE script, `bin/server/reports/unknown-entities.sh` — a map-reduce whose
known sets read the TRANSFER PARSE CACHE directly (cols 4/5/6/16), never a roster (roster-based
sets oscillate); `bin/server/reports.sh` runs it in its pool. Its `data/unknown/*.tsv` sidecars are the SERVER-LOG SIGHTING LISTS the colour-free
safety checks read (Entity Search / Cross reference: an unconfigured sighting is red; the
cleanup backlog: a mentioned whitelist IP is not unused). Transfer reads nothing from the server REPORTS.

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
list them: subscriptions = every `_files.tsv` col 12; hosts = col 15 of an OUT-side file (col 16),
the restriction `remote-host.sh` applies, so raw INCOMING addresses are never invented as
entities. A discovered host has no configured subscriptions, so the rollup would call it orange —
`host_own_unpaired` colours a host absent from the pair cache by its own last file instead
(`white_own`'s rule; every configured host is in the pair cache, so nothing else moves). The
append drops `.rescan-mentions` so the server mention scan picks the new names up.

The third column of every `base/*.tsv`, filled after the parses by ONE build step (full detail
in ARCHITECTURE.md), **`bin/build/result.sh`** — a subscription goes green/red by its LAST File's
outcome (red when Failed or Expired; orange = never seen in the transfer log), other entities
roll up their connected subscriptions (`_white.tsv` goes by the last real transfer from that
address instead). **A UC3 WITH NO TRANSFERS IS NEVER GREEN** (2026-09-28, user rule: "A UC3
subscription that has no transfers must be orange and not green"): polling fine with nothing to
fetch leaves it ORANGE (UC3 status "not seen"; the verdict and No remote files name its polls). The
**clean-poll rule** that flipped it GREEN (2026-08, sidecar `colour/_greenpoll.tsv`, its uc3-status
per-hour branch and detail-page "Working, nothing to fetch" verdict) is GONE — never bring it back.
ONE deliberate exception remains, a UC3 poll verdict: the
**cannot-connect rule** (2026-09-10, user rule): a never-transferred UC3 whose own polls fail
with "Connection failure while <flow> tried to connect …" on THREE polls in a row (newer than its
newest successful poll, or none at all) flips RED — a flow that polls and cannot connect is
broken, not idle; the newest failure is its `colour/_redflip.tsv` stamp, so it lands on the home
"Failing subscriptions in Server log" worklist with its own error page and the reason
"Connection failures".

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
`_build_ringattr`, which names the flow. `went-kaput.sh` applies the same rule to its page and
to the `_kaput-evidence.tsv` the home Reason reads. 1:1 owners are unchanged.

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
`orphan_red`'s recovered-since test, went-kaput's `lastokf` (its "Last OK transfer" column shows
that end), and the detail pages (details_lib's totals-row field 30 → `last_transfer_cut()`, the
banner and the connected-lines cutoff); the "Last OK transfer" section picks the newest Processed
File by its end too. Never lower than the old start-based cut, so it only ever spares a flip.

**The SSH logon funnel is SESSION-aware** (2026-09-06, user request — the FE000508 finding):
`_parse.tsv` column 6 is the SSH session id, and `bin/server/reports/logon.sh` + its twin
`bin/logons.sh` (the detail pages' Logons table and the Incoming table's four logon-summary columns —
"a change to either matcher belongs in both") tie every `[Ssh Default]` line to its connection.
A **re-screen** is an "Allowed user" line LATER than the last successful authentication of its
session (an Allowed that an authentication follows is a real screening, whatever the session
logged before — the sample's shared-session flows log several pairs on one id): a partner that keeps a connection open for days re-keys it about hourly and the
server logs "Start login process" + "Allowed user" again with no new authentication (FE000508:
601 Allowed vs 375 Authenticated, no failure, 2 hosts × 24 h/day). Re-screens have their own
column (kind `num`, never a problem, never the row-tint verdict) and are NOT in Allowed — nor
in the host file's Allowed. **Session errors** are the Error/Warning `[Ssh Default]` lines of no
counted family ("Stream read/write error. Exception message is: CMS parsing has failed"),
attributed to the login of their session; a `numfailed` column with drills, a 7th field of the
`_logon-problems.tsv` sidecar (the FE overview's Logon problems sum) and sidecar fields 22-25 of
`_logons.tsv`. Both need the whole cache read first (the exports are newest-first, not
chronological), so every Allowed line is booked in END. The sample estate plants one persistent
connection for the first login (`bin/sample/gen-events.awk` env_ambient, fixed session id, no
rint()). Drill-cell numbering on Incoming: 1 Allowed, 2 Disallowed, 3 Authenticated, 4 No account,
5 Bad key, 6 Key failures, 7 Locked, 9 Session errors, 14 Re-screens — Re-screens is the LAST column
(2026-09-08, user request); `publish-insights.sh` reads the Incoming cells by POSITION for its "login
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
(the restint CSS excludes `.failed`/`.processed`). The four server members whose PAGE lands in
Analyses get the same treatment via `render_subs_group_pages`. Kept in its own array — the detail
pages' `resmaps` tint entity CELLS and must not switch this on for a whole area.

The analyses, dashboards and day publishes hand-render their pages but source publish_lib;
cross-links use `DLINK_BASE`. **All options, every checkout**: menus, sitemap and group tab bars list
every order-listed report UNCONDITIONALLY, so every checkout's menus are identical; a missing `.rpt`
gets an "empty report" placeholder page (`render_missing_reports`). Publishes run concurrently
(`publish-details.sh` beside `publish.sh` — disjoint trees).

### The page families (details in ARCHITECTURE.md)

- **The home page** (`bin/build/publish.sh`): the two status tables — every cell opens the
  Entities view whose row count IS that figure (Entity · Total · Seen · OK · Error · Warning ·
  Ok; no scope switch since 2026-09-27); `check_status_consistency`
  verifies each figure; the SEEN figures come from `home.rpt`. The per-day figures are ONE wide
  "Per day" table (2026-08-31, user request — the 2026-08 five-table flex row with its Date
  spine is retired: it could fall out of row-sync whenever a header's height changed): a `gband`
  banner row (Files · Duration · Red/Green switch · First seen) over a shared Date column (its
  cells link the day dashboard), then the group columns — Files (In · Out · Ok · Cured ·
  Error · Error %; Cured = the transfer topview.rpt's Recovered group, Automatic + Manual; the In/Out split is the movement direction, `_files.tsv` col 17; the count
  column is gone — In + Out carries it), Duration (p50 · p75 · p90 · p95 · p99 — p99 last since 2026-09-13, user request; EVERY cell of the group, banner and headers included, carries `data-href="transfer/duration.html"` and opens the Duration report WITHOUT a date — report.js `setupCellLinks`, which outranks the index row link that would open the day page), Red/Green switch
  (Red · Green) and First seen (Logical · Partners · Subscriptions · Accounts). Group dividers
  are POSITIONAL CSS on `table.dayrows` (columns 2/8/12/14 + the `gbrow` banner cells — adding
  a column means moving them). Still `data-nosort` (the 14-day cap hides the OLDEST rows by
  class, which a sort would interleave); the cap is lifted by the "Show all" button under the
  tablewrap (setupShowAll uncaps every capped table in its adjacent wrapper).
  **Red/Green switch** (2026-08): how many
  subscriptions FLIPPED that day, Red = green→red and Green = red→green, from a
  (subscription, sortkey) walk of `_files.tsv` in `daily_loglines_tsv`. The comparison is
  **END-OF-DAY state against the previous ACTIVE day**, never per File: the last File of a day
  sets that day's state (site-wide outcome policy, Waiting counts as OK), so a flow that broke and
  recovered inside one day ends it green and is NOT a flip; a day the flow carried nothing keeps
  the state, so the flip lands on the day the state actually changed. A flow's first active day
  only establishes its state. Each nonzero cell links `docs/switches/<date>.html#red|#green`
  — one page per day with flips, listing the subscriptions behind the two cells (tinted by their
  CURRENT colour, each row opening the detail page); the pages are written by the same
  `write_env_block` pass from the names side-file `daily_loglines_tsv` fills. Then the RED worklist
  (`write_failing_now`, 2026-08), split in TWO tables because a red flow is red for one of two
  reasons and they want different columns and destinations: **Failing transfers** — it has a
  failed File, so the rows are `failed-sub-all.rpt`'s own, red only and ONE PER SUBSCRIPTION (its
  newest; the .rpt is newest-first) — and **Failing subscriptions in Server log** — everything else,
  red for what the transfer log cannot show. BOTH show Subscription / **Reason** / **Last**; the
  first opens that file's ERROR PAGE from every cell (the CoreId is the row's destination, not a
  column), the second the flow's OWN subscription-named error page for red rows (its DETAIL page
  for the green early warnings). They sit SIDE BY SIDE in the renderer's own
  `.sxs`/`.sxscol` flex row, and both carry `data-sort-init` on Last (descending — the emitted
  order, but `makeSortable` re-sorts on load, so the default must be declared). Membership across the two is the COLOUR, not a report's selection, so
  together they are still every red flow. The Reason is
  `analyses/reports/_subs-boxes.tsv` (the most specific Subscriptions-in-boxes box, written by
  `publish-insights.sh`). **The SERVER LOG ON THE FLOW'S OWN ERROR PAGE COMES FIRST** (2026-08):
  the page a home row opens is the evidence a reader checks, so the Reason must be what that page
  says — `_errpage-evidence.tsv` (written by `failed.sh`: the first 8 Error/Warning
  lines, with their level, of the flow's NEWEST drill page — the page the home row opens —
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
  `<entity>-<view>.html`, no scope pages since 2026-09-27) under `docs/transfer/entities/`,
  assembled at publish time (`render_entity_report`) from
  `data/transfer/reports/entities/<name>.rpt` — ONE writer for the nine,
  `bin/transfer/reports/entities.sh` — plus the coverage TSVs and the base caches (the ghost
  rows: a green with no report row of its own is Seen with blank counts); sort is shared across the nine entities (localStorage, 1-hour sliding expiry,
  stored by "group › column" label). THE GROUPED LAYOUT (2026-09-13, user request — built that day
  as the `transfer/entities2/` twin experiment and adopted the same day; the classic Name ·
  Direction · Files · Volume · OK · Retry · Resubmit · Error · Last seen pages are GONE): Name,
  then seven column groups the Top view way (a `GHEAD` banner + `gsep=` dividers) — Files (In ·
  Out by MOVEMENT, `_files.tsv` col 17 · Error · Error %) · Retry / Resubmit (Auto = an OK File
  with a failed leg and no resubmitted leg; Ok / Error = every resubmitted File by outcome — the
  Top view's Automatic + Resubmit Ok/Failed rule) · Duration (p90 · p95 · p99 · p100 of the OK
  Files' wall-clock span, the Duration report's scope and nearest-rank rule, FOLLOWING the date
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
  thresholds are known). The writer's attribution mirrors the nine classic writers (`account.sh`,
  `subscription.sh`, `login.sh`, `remote-host.sh`, `pda-entities.sh`), which STAY as DATA
  producers — `showseen.sh`, `entity-search.sh` and the server rosters read their `<name>.rpt`
  positionally — but render no page. Links INTO the pages sort by header LABEL
  (`?axway_sort=Error:-1` / `Total:-1` — report.js resolves the first header cell reading it; the
  home day table and the overview/day Top 5 produce them), since the positions shift when a group
  is hidden. The hand-written help pages `entities-<name>.html` describe this layout. Other
  report.js pieces that came with it and are general: the RECALC tokens `vN.M`
  (humanBytes(sumN/sumM)), `SN`, `eN.M`, `HN`/`VN.M`, `PN`; `pct=` accepting `a+b` column lists
  (the searched total honours S/e/H too); the TOTAL row's day count under a narrowed range = the
  DISTINCT in-range dates (was 0).
- **The detail pages** (`details.sh` → `details_lib.sh`/`details_writer.awk`): one page per entity
  of the nine types, every configured name gets one; slugs via the comprehensive `_slugmap.tsv`;
  no From/To, no search box, no RECALC.
- **The special pages**: Entity Search (rows ship as DATA in `search-data.js`; the Type cell is
  read by INDEX in report.js — adding a column means shifting it), the SIX File search pages
  (`search/file-search-{24-hours,48-hours,week,2-weeks,3-weeks,month}.html` — under `docs/search/` since 2026-09-12, beside `search/search.html`; the engine-derived links carry `../` — 2026-08: ONE page per
  window — result rows tint green/red by outcome via restint + a per-row `data-res` — with
  per-page `-data.js` payloads (v5, capped at 100,000 rows; a capped page turns into a RED
  banner on the build report via `file-search-capped.txt`), searched by the DEDICATED
  `docs/assets/file-search.js` — as you type (no Search button, no idle text since 2026-09-27), the NAV row carrying
  `?q=` between the windows; 24 hours = the newest full day + the partial newest day, 48 hours
  = the second full day), the Report finder, the SIX Failed-transfers
  view pages (+ per-CoreId error pages, and since 2026-09-03 the FILE pages `docs/files/<coreid>.html` — the same layout for a File of ANY outcome, written by `failed.sh` for the CoreIds the Transfer patterns page's "Last 5 files" cells link, `_patterns-files.tsv`, and for every File the Longest Files page lists (DELIVERED Files only since 2026-09-13, user request — no Failed / Expired / Waiting and no "All transfers" view; the one-hour threshold went 2026-09-06), `_longest-files.tsv` — its CoreId cell opens the File page), Cross References, Entity coverage
  (assert OK ⊆ Current ⊆ Once), whitelist-audit, config-hygiene, UC status (its UC3
  tab also carrying the polling tables — the former Remote polls report and Cronjobs page, 2026-09-05), Polling (the SAME polling information as ONE flat table, one row per polling subscription — `bin/analyses/reports/polling.sh` → `polling.rpt`, a `SUBS_GROUP_REPORTS` server member rendered into analyses/, sitting at the old Cronjobs slot of the Configuration row, 2026-09-05)
  (a Use-cases view; pages in analyses/).
- **The Boxes pages** (subscriptions-in-boxes + accounts-in-boxes, written by publish-insights):
  both start from the shared `_subs_box_rows` producer; the account join is
  `xref/_subscriptions-accounts.tsv` and ONLY that — **never match subscriptions to accounts by
  name**.

### Report groups and menus

`bin/publish_lib.sh` owns `transfer_order`/`server_order` and
`group_of`/`group_members`/`group_label`/`group_desc`/`member_label` (`group_of` is area-aware —
both areas have a `topview`). Index pages and dropdowns show one line per group, landing on the
group leader (`group_home` → `first_page`); each report page carries a row-1 tab bar of its
group's members. **Entities lands on Subscriptions / All** — the same member its tab bar leads
with and the target of the top bar's own Entities link: KEEP THE THREE IN SYNC.

The full transfer/server group lists are in ARCHITECTURE.md ("Report groups") and authoritative
in `group_members`/`group_label`.

**Merged reports** (`bin/merge_rpt.sh`, run after the report pools) fold component `.rpt`s into
one tabbed report; the components stay on disk as unpublished intermediates (listed in
`MERGED_COMPONENT_REPORTS`; whats-new skips them; `_merge_pad` pads a missing component with
empty stubs — 0 for a component whose tables ride another one's tab via `tab=KEY`). The merge
ends its component run with a `META merged` sentinel so the last component's trailing NOTE
stays on its own tab instead of footering onto every tab (2026-09-05). **The BOXES-ONLY reports** (`BOXES_ONLY_REPORTS`) are in no group and no
menu/index/sitemap card; their pages stay at the area URLs with no group tab row, and only the
Boxes pages link them — their scripts still run in the area orchestrators. Both full lists are in
ARCHITECTURE.md.

`TRANSFER_MENU`/`SERVER_MENU` are built from the orders minus the basenames living in the Analyses
dropdown. `ANALYSES_MENU` is hand-written, one line per group: Start page · **Coverage & seen** ·
**Configuration** · **Partners** · **Boxes** · **Errors** · **Month stats** (2026-09-13, user
request: `bin/transfer/reports/month-stats.sh` → `data/transfer/reports/month-stats/{this,previous}-<entity>.rpt`,
the nine entities counted over the Files that STARTED in the month of the newest File start
(this) and the month before (previous) — Total · In · Out · Errors · Auto Retries · Resubmit
OK / Error · Waiting · Expired, the Entities definitions and attribution; `render_month_stats`
in the transfer publish renders the 18 pages into `docs/transfer/month-stats/` with two tab
rows (month, entity), no date filter, help page `month-stats`; listed in `_analyses_groups`,
the finder's static rows and the sitemap). A FOURTH dropdown, **Goodies**
(`GOODIES_MENU`, 2026-09-13, user request), is a hand-written SHORT CUT to the best reports —
Partners - Incoming (analyses/partners-in.html, `bin/analyses/reports/partners-in.sh` = fe-overview.rpt +
the Incoming logon funnel of logon.rpt, one row per login; the old FE overview page and the Logons
(incoming) page stay in their own groups but left Goodies 2026-09-13) · Partners - Outgoing
(analyses/hosts-overview.html, the hosts twin for UC1/UC3, `bin/analyses/reports/hosts-overview.sh`) ·
Transfer Duration · Error reasons (analyses/failing-reasons.html; replaced Failed Subscriptions 2026-09-15) · Subscriptions (the analyses/subscriptions.html
configuration list) · Polling (analyses/polling.html) — the pages
staying in their own menus and groups; it ships in `topbar-data.js` as `goodies`, both bar
renderers draw it, `TB_VER` folds it, linkcheck reads it like the other menus. `_analyses_groups` is the single
source of truth for the analyses group tab bars — **keep it in sync with `ANALYSES_MENU`, the
analyses index and the sitemap.** The Coverage/Configuration members whose PAGE renders into
`docs/transfer/` are absent from `group_of` and the transfer menu; `finder_area` labels them
Analyses. `_tag_variants` (group crumbs) skips a globbed page that is itself a listed member — the
`<base>-*.html` glob would otherwise claim a different member sharing the prefix.

## Publishing (GitHub Pages)

Published via GitHub Pages — branch `master`, folder `/docs`. No
CI build (the sources are gitignored): run `bin/build.sh` locally → commit `docs/` → `git push`,
both MANUAL.

- **Local preview: `http://localhost/develop/`** — the local Homebrew httpd serves this repo's
  `docs/` (the runtime twins serve at `http://localhost/runtime-acceptance/` and
  `http://localhost/runtime-production/`); preview there, never start a
  throwaway HTTP server, hard-reload after an asset edit. Every page head carries the no-cache
  trio (`http-equiv` Cache-Control / Pragma / Expires — 2026-09-12, user request; baked by
  `html_head`, `write_root_404`, the build report and the hand-authored `assets/help/*.html`,
  KEEP IN STEP); the assets rely on their `?v=` busters. All generated links are RELATIVE, so
  the site works under any base path — the 404 page derives its home link from the URL itself.
- **`docs/` is PURE committed build output** (2026-08-29): every `bin/build.sh` run CLEARS
  `docs/` wholesale and RE-SEEDS the
  hand-authored files from the repo-root **`assets/`** — `style.css`, `report.js`, `slotchart.js`,
  `file-search.js` → `docs/assets/`, `assets/help/` → `docs/help/`. **EDIT IN `assets/`, never in
  `docs/`** — a build overwrites the docs copies. (`.nojekyll` and `topbar-data.js` stay
  generated.)
- **`assets/help/*.html`** — a help page per report (or shared per group/family) plus `general.html`
  and `index.html`; seeded into `docs/help/` each build. `help_slug_for AREA BASENAME` maps
  basename → slug (server basenames get a `server-` prefix; detail pages `details-$sub`). **A
  new/renamed/regrouped report needs its help page created or extended BY HAND** — a slug with no
  file is a silent 404, not a build error.
- **The `.rpt` files and parse caches are NOT committed.** Keep them on disk for HTML/CSS
  iteration; a fresh clone must run parse + reports before the publishes produce a site.
- **All generated links are relative** — the site lives under `/axway/` and Pages is
  case-sensitive; keep paths lowercase and exact. The assets' `cksum` is the `?v=` cache-buster on
  every page (`ASSET_VER`), so an asset edit wants a full re-publish.
- **To add a transfer report**: a script in `bin/transfer/reports/` sourcing `../lib.sh`,
  aggregating `$PARSED` or `$FILES` into `$REPORTS_DIR/<name>.rpt` — no freshness check (every
  build is fresh; see "No incremental machinery"). Add it to
  `bin/transfer/reports.sh` and `transfer_order` (+ `group_of`/`member_label`, `report_tabs` if
  multi-table), and write its help page. Phase 1 unless it reads another report's output (phase 2
  = `showseen.sh`); build.sh overlaps the phases with `details.sh` in the background, so **a new
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
  group — force the string comparison with `($2 "") != cur`.
- **No Python or other interpreters** — bash + awk + `sort`/`sed`/`date` + `jq`.
- **Tolerate CRLF and LF in the input CSVs** — strip a trailing `\r` during awk parsing so it
  never leaks into a field value, filename or sort key.
- **Keep the `.sh` files themselves LF** (`.gitattributes` enforces it); bash 3.2 chokes on CRLF
  scripts — if a script suddenly won't parse, check `file *.sh` first.
- **`set -euo pipefail` is on everywhere.** Compute first/last records in one awk pass rather than
  `sort | head`/`tail`, and cap top-N lists with `awk 'NR<=n'`, never `head` — the early
  pipe-close SIGPIPEs `sort` and silently kills the script.

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
  tokens, CSS classes, `@data:coreids-*`, the coverage TSVs' P|F). Exceptions: raw status values
  shown verbatim, the server "Failed logins" report name, file-freshness's "Processed" column.
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
sync) included; the committed repo top is `bin/ assets/ docs/`,
the three `.md` docs, `.gitignore`/`.gitattributes` and **`input/`** — in
THIS repo committed IN FULL, sample CSVs included (the whole estate is synthetic and small;
`bin/sample/generate.sh` — no argument — rewrites it as ONE estate, the union of the former
acceptance and production sample rosters; its `KEY="acceptance"` constant is only the PRNG
namespace that keeps the generated identities stable). `input/` holds the flow-manager JSONs, the
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
the sample template), `logons_old.txt` (2026-09-02: the FE logins' last logon on the OLD gateway, `<login> <stamp>` per line — the Analyses → Configuration "Partners - Incoming" page's Gateway column; hand-maintained, sample template in develop), `coreid-url.txt` (2026-09-07: the SecureTransport File Tracking URL every CoreId on the site links to — ONE line, `@COREID@` where the id goes; hand-maintained per checkout, the REAL admin hosts live only in the runtime copies, develop's sample carries an `.example` host — read by `publish_lib.sh` into topbar-data.js) and
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
README.txt per directory. Gitignored: the `data/` root, `/build/` and the retention `/archive/`. A step script that
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
bin/flow-manager.sh     config exports -> data/flow-manager/{base,xref}
bin/expire-files.sh     Waiting -> Expired from the File Maintenance sweep lines
bin/bookend-ok.sh       Failed -> Processed on the server log's own ok "Transfer end logged." bookend (no reason line)
bin/session-sites.sh    UCx groups -> real subscription via the server log's session route lines

# BUILD-ONLY — nothing but bin/build.sh invokes these:
bin/build/result.sh              fill the base result columns
bin/build/publish.sh             index pages + the home; run LAST
bin/build/drill-files.sh         the first File of every red / orange drill cell -> _drill-files.tsv (failed.sh pages them)
bin/build/display-rename.sh      the display-rename sweep (input/rename.txt); the last page-touching step
bin/build/linkcheck.sh           every link resolves + every page is reachable (manual gate)

# RUNTIME-ONLY (skipped on the sample estate — the .sample-estate marker):
bin/build/exchange-in.sh         the inbox (a git repo, ~/exchange by default — never named in output): this environment's <prefix>*.7z -> st-reports-update.sh
bin/build/st-reports-update.sh   one archive -> input/ (the log exports renamed logEntry_yyyy-mm-dd.csv / fileTransfer_yyyy-mm-dd.csv)
bin/build/archive-old-logs.sh    retention: exports older than the current + past month -> archive/<name>.7z (gitignored), tested before removal
bin/build/st-reports-archive.sh  docs/ -> st-reports-<env>_<stamp>.7z -> build/ + the outbox (the same repo, st-reports-<env>.7z)
```

All data lives under two roots at the repo top (`data/` gitignored wholesale; a runtime repo
additionally ignores the `*.csv` exports under `input/`, its one bulk item):

- `input/{transfer,server}/*.csv` + `input/flow-manager/*.json` — the raw exports
  (irreplaceable); `templates.json` optional. `input/blacklist.txt` and `input/skip.txt` — see
  the attribution chain. `input/environment.txt` — the checkout's label (see "Environment"),
  never synced, never delivered by an archive.
- `input/renames/` — `subscriptions.tsv` (old⇥current) and `flowid-names.tsv` (the previous
  export's `flowId`⇥name snapshot). **Machine-maintained, never hand-written**; under `input/`
  for the same reason as the DNS map — once an export is overwritten its names cannot be
  recovered, and `rm -rf data/` must stay safe. See the attribution chain, step 0.
- `input/ip/ip-hosts.tsv` — the address ↔ endpoint map (`ip⇥host`), **fully
  automatic, never hand-written**; **`bin/ip.sh`** owns it (`ip_put`, the only writer,
  cmp-guarded — the one kind of guard kept: the file outlives the build; an empty dir is valid). **There is NO reverse DNS anywhere, and none may be
  reintroduced** — the configuration names endpoints. Writers: `flow-manager.sh` forward-resolves
  the configured hosts (with `base/_hosts.tsv` as the KEEP list); `parse.sh` records each new
  OUTGOING IPv4 under the host configured for its account (no row on disagreement; an INCOMING
  address gets no row — it stays raw in col 16). **`ip_put` UNIONS, never replaces.** Under
  `input/` because a DNS answer cannot be regenerated — `rm -rf data/` must stay safe.
- `data/<area>/cache/` — the tokenized caches + companions; `data/<area>/reports/` —
  the `.rpt` descriptors (+ `details/`, `coverage/`, `errors/`).
- `data/unknown/*.tsv` — the unknown-* sidecars, the server-log SIGHTING LISTS
  (accounts/logins/sites/hosts/white — `white.tsv` carries only TM-mentioned whitelisted IPs),
  read colour-free by Entity Search, Cross reference, data-diff and the cleanup backlog.
  Rewritten each run; a type with no unknowns keeps an EMPTY sidecar (its readers expect one). (The SSH-logon files went with the blue result, 2026-09-27.)
- `data/colour/` — `result.sh`'s sidecars (`_redflip`, `_ringattr`,
  `_ringorphan`, `_kaputflip`, …; `data/blue/` until 2026-09-27). `data/flow-manager/{base,xref}/`
  — the config caches. `data/.buildstats/` — the build report's input statistics, the one
  directory the build's wipe carries over.

`input/` is deliberately separate from `data/`, which EVERY build wipes: that never touches the
raw CSVs or the DNS map. The built site is the committed repo-root `docs/`.
