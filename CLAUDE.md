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

## The two-repo model — THIS IS THE DEVELOP REPO

The project lives in two sibling repos sharing all code but never data. **develop** (this one)
is where every change happens and holds ONLY the **SAMPLE ESTATE**: synthetic input data from
`bin/sample/generate.sh` (fake orgs, RFC 5737 addresses, `.example` hosts) — deterministic
(seed `AXWAY_SAMPLE_SEED`), committed, regenerable; `bin/sample/verify.sh` asserts a built site
covers every planted scenario. **runtime** is the operational twin with the REAL exports —
**never read, edit or build it from an AI session**; it has no CLAUDE.md by design. Code flows
one way via `bin/runtime.sh <path-to-runtime>` (syncs `bin/` + `assets/` + `.gitattributes`,
removes CLAUDE/ARCHITECTURE there, runs its `bin/fresh.sh`); the sync EXCLUDES the develop-only
tooling — `bin/runtime.sh` itself and `bin/sample/` — and deletes stale copies of them in the
target, so runtime's `bin/` carries pipeline code only. The committed `input/.sample-estate` marker
gates the generator — absent in runtime, so it can never clobber real exports. Local preview:
develop at `http://localhost/develop/`, runtime at `http://localhost/runtime/`.

## Environments (acceptance + production)

Two environments side by side, selected by **`AXWAY_ENV`** (`acceptance`|`production`, default
`acceptance`) via the sourced **`bin/env.sh`**. **Every input/data/docs path in this document is
per-environment**: `input/<env>/…`, `data/<env>/…`, `docs/<env>/…`. Shared only: `data/.awkshim`
and the docs-root artifacts (`index.html` — the ONE shared home —, `404.html`,
`assets/`, `help/`, `.nojekyll`).

Under `docs/<env>/`: `transfer/` (+ `entities/`, `secparams/`, `seenlog/`), `server/`, `analyses/`
(+ `xref/`), `dashboards/`, `day/`, `errors/`, `details/` (one subdir per entity type),
`first-seen/`, `use-cases/`, `coverage/`, `transfers/duration/`, plus
`404.html search.html sitemap.html report-finder.html whats-new.html`. `input/production/` carries REAL
exports since 2026-08 — logs AND the FlowManager JSONs (the production flows are the HYBRID
pattern generation: no folder parameters, flowdir from `{source,target}_hybrid_participant`).
The manual `bin/flow-manager-synth.sh` stays as the fallback for an env with logs but no config
export: it synthesizes the two JSONs from the transfer logs (one subscription per Transfer
Profile, one partner per account).

- `html_head` derives `envbase` (env root) and `base` (docs root) from the css href callers pass
  env-root-relative.
- **The top bar is RUNTIME**: pages bake only a placeholder div; report.js `buildTopbar` renders
  the full bar from `docs/assets/topbar-data.js` (written by `ensure_assets`; `?v=` stamp
  `TB_VER`). The help/build pages bake full chrome (`render_shared_topbar`).
- **The env switch**: `bin/build/crosslink.sh` stamps each placeholder with `data-twin` — the same
  page in the other env when it exists, else that env's `docs/<env>/404.html` (the shared
  `docs/404.html` is what Pages serves for unmatched URLs); report.js carries a live
  `?query`/`#hash` onto a non-404 twin. On the shared home the label toggles the visible baked
  `.envblock` (sessionStorage `axway-env`). report.js keeps the envs' persistence apart:
  `pageKeyBase()` prefixes the env segment; the `report-area` meta is `<env>-<area>`.

## The pipeline — bin/build.sh

Runs the whole chain. One optional argument picks the SCOPE: none = both envs, `acc`/`prd` = that
env only (drops the other env from every loop and cross-env step). NO git step — committing and
pushing is manual. Writes an HTML run report to `build/index.html` (also on FAILED, EXIT trap) —
LOCAL ONLY since 2026-08-29: no docs/ copy, and no page on the site references a build (the
sitemap link went with it, so `AXWAY_BUILD_SCOPE`/`PUBLISH_STAMP_EXTRA` are gone). An env without the two
flow-manager JSON exports is skipped with a note. **An env with the JSONs but NO log CSVs builds
fully** (2026-08, the config-only estate — what a fresh clone is, the exports being gitignored):
both parses write EMPTY-but-valid cache sets and exit 0, every report either renders its zero-row
tables (the roster/entity/cross/UC-status reports — configured rows still show, all orange
"configured, never seen") or skips into the empty-report placeholder; `render_report` pads a
split report short of its `report_tabs` labels with the merge_rpt no-data stub so the group nav's
same-label carry never links a 404, and linkcheck lists an unreachable `help/` page as
informational (its family has no pages then) instead of failing.

The report carries the timings (start → end · duration) in its title and opens with three fact
blocks (Input / Cached files / Output), gathered BEFORE the end timestamp; `count_stats` caches line counts in `data/.buildstats/<key>` under a signature
of the file list. Trap: glob file lists into an ARRAY, not `read <<<"$(…)"` (word-splits under the
assignment's IFS). Nothing on the site links the report; the published HTML is identical
whichever scope built it. (`PUBLISH_STAMP_EXTRA` still exists in publish_lib for any publish that
needs an extra freshness ingredient — **never put a scope-like value in every stamp**, it would
re-render every page on each switch.)

Order: (1) config, both envs — in PARALLEL when both are present (2026-08; ~9 s per env cold;
the shared awk shim is pre-created first); (2) the two env
chains run CONCURRENTLY — the bigger input in the foreground, the smaller in the background
(pools capped via `AXWAY_NJOBS`), merged into the report at the barrier; (3) per env chain:
*parse* (transfer and server `parse.sh` overlap, transfer with
`AXWAY_SKIP_EXPIRE=1 AXWAY_SKIP_SESSIONS=1`, then `bin/session-sites.sh`, `bin/expire-files.sh`,
`bin/build/seen-in-server-log.sh`, `bin/build/result.sh`), *report*
(`bin/transfer/reports/details.sh` FIRST — transfer phase 2 reads its `.rpt`s and slugmaps — then
transfer, server, analyses, dashboards, day), *publish* (transfer, transfer-details,
partner-groups, server, analyses, then THE CATCH-UPS — re-runs folding the cross-phase evidence
into THIS build, each self-gating via its own freshness check (a warm build skips them in ~0 s):
failed.sh (the boxes reasons now on disk; went-kaput runs EARLY, after result.sh, so the kaput
stamps are final on failed.sh's FIRST pass), failing-reasons.sh, then the detail-pages pair
(.rpt + publish) in the BACKGROUND beside the analyses/transfer publish catch-ups — details
deps on the REDUCED `_srvsubs-map.tsv` (name⇥slug⇥stamp, no reason), so a reason-only rerun
leaves it byte-identical and the pair skips — dashboards, day); (4) after the barrier: `bin/build/publish.sh`
(index pages + shared home, reads BOTH trees), then `bin/analyses/publish-accvsprod.sh` per env in
scope, then `bin/build/crosslink.sh` (always), then the scope's report page.

Dependency rules: transfer reports before server and analyses reports; `seen-in-server-log.sh`
last inside the analyses step (needs a fresh `pda.rpt`); dashboards + day after both areas;
`bin/build/publish.sh` last of the publishes (the area publishes clear the dirs its index pages
live in).

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
bin/build.sh                          # everything, both envs (no git)
bin/fresh.sh                          # FULL fresh build: wipe data/ + docs/, seed assets/, build both envs
bin/build/linkcheck.sh                # verify: 0 broken links, 0 orphan pages
bin/transfer/parse.sh                 # -> _transfers.tsv + _files.tsv
bin/transfer/reports.sh [phase1|phase2]
bin/transfer/reports/details.sh [TYPE]   # TYPE = ACC SITE LOGIN HOST PTN APP DOM
bin/server/parse.sh                   # -> _parse.tsv (+ per-entity mention caches)
bin/server/reports.sh
bin/analyses/reports.sh; bin/dashboards/reports.sh; bin/day/reports.sh
bin/transfer/publish.sh               # …and the other per-area publishes; then:
bin/analyses/publish-partner-groups.sh
bin/build/publish.sh                  # index pages + shared home; run LAST
bin/analyses/publish-accvsprod.sh     # needs both env trees
bin/build/crosslink.sh                # stamp the env-switch twin links
AXWAY_FORCE_PUBLISH=1 bin/…/publish.sh   # re-render even when the stamp says fresh
AXWAY_DEBUG_FRESH=1   bin/…/publish.sh   # name the dep that forced the rebuild
bash -n script.sh                     # syntax check — there is no test suite
```

**Manual re-publish gotcha**: `publish-partner-groups.sh` and `publish-accvsprod.sh` run OUTSIDE
the per-area publishes; skipping them after a publish sweep leaves their pages missing. The
DISPLAY-RENAME sweep (`bin/build/display-rename.sh`, `input/rename.txt` — presentation renames
applied to the RENDERED pages as the build's last page-touching step; caches/.rpt keep the real
values, slugs/links untouched) also runs only in `bin/build.sh`: a manually republished page
shows real values until the next build.
**Iterating on HTML/CSS**: edit `assets/style.css`/`assets/report.js` (NOT the docs copies) and
run `bin/build.sh` — it clears+seeds docs/ and re-renders everything. A MANUAL per-area publish
reads the docs/assets copies, so after an assets/ edit copy the file over (or run the build);
a publish SKIPS when its stamp is fresh — the docs asset copies are deps, anything else needs
`AXWAY_FORCE_PUBLISH=1`. The `.rpt` files stay on disk, so the publishes alone re-render the site.

**Incremental parsing.** `parse.sh` (both areas) keeps a manifest (basename + byte size per
input) and tokenizes only what is new: the transfer side `sort -m`-merges into the CoreId-sorted
cache (byte-identical to a full parse), the server side appends; a changed/removed manifested
file — or **editing `parse.sh` / `input/blacklist.txt`** (cksums in `_*.parser`) — forces a full
reparse. `reports.sh` does not parse; each report calls `ensure_parsed`.

**Incremental publishing.** Each publish writes `data/<env>/.publish/<name>.stamp` and skips when
nothing it reads is newer. `bin/publish_lib.sh` owns `publish_is_fresh STAMP OUTDIR DEP…` /
`publish_stamp` / `publish_area_stamps`; deps = `PUBLISH_CORE_DEPS` + the trees the caller lists.
Four rules the machinery depends on:

- **A generated `docs/` page is NEVER a dep** (crosslink.sh rewrites thousands every build); the
  output DIRECTORY's existence is checked instead.
- **Files only, never a directory's own mtime** (`find -type f -newer`); the stamp also stores the
  dep-tree file COUNT so a deletion is noticed.
- **The three cross-cutting steps** (`bin/build/publish.sh`, `publish-accvsprod.sh`,
  `crosslink.sh`) depend on the seven per-AREA stamps BY NAME (`publish_area_stamps`) — never on
  the `.publish` DIR, which also holds their own stamps.
- **A writer regenerating identical content must keep its mtime** (cmp-guarded: `cov_put`,
  `apply_help_chrome`, `_expired.tsv` — tested with `-f`, not `-s`: an empty extraction is
  valid). A `.rpt` cannot be cmp-guarded — its FOOT carries the run time.

Report scripts use `skip_if_fresh OUT SCRIPT [DEP…]`; a directory dep covers its whole tree.

## Tool sets

**`bin/transfer/`** — reports over the transfer logs (`transferLog_*.csv`). **`bin/server/`** — a
parser + report scripts over the server logs (`logEntry_*.csv`). **`bin/analyses/`** —
configured-vs-seen analyses from the transfer outputs + config caches (no parse of its own).
**`bin/dashboards/`** — the graphical Overview. **`bin/day/`** — the per-day pages.

### bin/flow-manager.sh — the pre-parse config step

Extracts from `input/<env>/flow-manager/{partners,subscriptions}.json`: `data/<env>/flow-manager/base/`
— the 11 entity lists (`name⇥direction⇥result`: `_accounts _logins _hosts _white _subscriptions
_profiles` + the derived `_logicals` (the FlowIDs condensed into logical flow groups,
`input/logical.txt` pins honoured), PDA `_partners _apps _domains` and `_bl` (2026-08-31, user
request: the subscriptions.json `tags` entries starting with `BL`, kept verbatim — a full entity,
LAST in the Logical/Partners/Domains/Applications group everywhere it renders; a File belongs to
a BL through its SUBSCRIPTION); result filled later by the
two build steps) — and `data/<env>/flow-manager/xref/` — the pair caches: every pair of the eleven
items BOTH WAYS (110 files; unconfigured = empty — `_profiles-logicals` doubles as the FlowID →
Logical MAP every report attributes a File’s profile column through, `_subscriptions-bl` as the
subscription → BL tag map), plus `_subscriptions-patterns`, `_subscriptions-flowdir`
(out|in|relay), `_subscriptions-ucderived` (2026-08: the use case DERIVED for a non-UC-named
subscription from flowdir × the pattern's one partner verb — out+pull=UC2, out+push=UC1,
in+push=UC4, in+pull=UC3; both/neither verb = no row; consumers: the detail Features "Use case"
row and the UC2/UC4 status selection), `_{accounts,subscriptions}-fmlink`,
`_partner-group{s,-why,-accounts}` and `_templates.tsv` (optional export). It also forward-resolves the configured hosts into
`input/<env>/ip/`.

Nothing downstream reads the JSONs directly (except `publish-insights.sh`); everything goes via
`ensure_config`. Transfer's `ensure_parsed` watches the **xref** cache mtimes only — deliberately
not base/, whose result column is recolored AFTER the parse. `flow-manager.sh` early-exits when
every cache is newer than the exports and itself; a missing cache degrades to an empty list.
**PDA derivation** is owned here too and is LOGICAL-BASED (2026-08-30, user request): the
three-part Logical name `D_A_P` gives part 1 = domain, part 2 = application, part 3 = partner
token; partner tokens merge (same host / shared whitelist IP / whitelisted host IP / curated
alias — details in ARCHITECTURE.md), and every partner/app/domain pair cache is composed
through the FlowID. The account-name split machinery, the subscription-name fallback and the
prune are RETIRED. So is the **Logical derivation** itself (FlowID families → three-part group
names; a `-` inside a part marks parts the derivation combined, which is why Logical names are
never separator-folded) — it runs FIRST, the PDA pass consumes it. The coverage TSVs
`data/<env>/transfer/reports/coverage/*.tsv` are the materialized product (`ensure_pda_tsvs`).

### bin/dashboards/ and bin/day/

`bin/dashboards/reports.sh` → `overview.rpt` (+ `monitor.rpt`, whose EXISTENCE flags "this env
has a monitor"); `publish.sh` renders the Overview — 5 KPIs + one hero graph with alternate
views, all chart type `slots`, drawn client-side by `docs/assets/slotchart.js`.
`bin/day/reports.sh` writes one `.rpt` per calendar day (both logs); its publish renders KPIs →
hero → problem lists → facts → six Top-5 tables. Both run after the two areas' reports; the
UC-status stacks and cumulative "seen" views carry strict invariants — see ARCHITECTURE.md before
touching them. Consumers reading topview Date cells strip the `@{href=…}` cell attr first.

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
  plain name). `ALERT` → red banner (the
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
it automatically — see below) · `nosort` · `sxs`
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
`anchor=` (id on the `<h2>`, an in-page link target) · `keephead` (keep the heading
even on a page's first table) · `rowlink` (the WHOLE row opens its target — the row's own
`@data:href` if it carries one, else its first link; report.js `setupIndexRows`).
A page with ZERO date-aware tables
renders no From/To and neither restores nor persists the shared per-area range.

**Column KINDs**: `text num failed processed numfailed numprocessed numok numerr numwarn numsep
bar file mono srv acct site login host ptn app dom ip lines clines pre` (`numsep` = a num column
that also STARTS a column group — the th/td get the divider; `srv` = the server-log-only blue
marker cell). Entity KINDs link to the detail page, the
slug resolved through that dir's comprehensive `_slugmap.tsv` — no map entry, no link. `lines` =
`\x1f`-separated stacked lines; `clines` collapsible (3+ lines fold behind `⋯`); `pre` = a raw log
LINE kept verbatim in `<pre>` (the failed-file error pages) — logged spacing preserved, NO wrap
and no width cap, so one logged line is one rendered line and the table scrolls.

**Direction columns show the CONNECTION/MOVEMENT pair (`out/in`) wherever both sides exist**; the
per-LEG aggregates (one row per direction) legitimately show one value. **A column headed exactly
`Direction` renders LOWERCASE site-wide** — `dirfold()` folds ONLY the direction vocabulary
(keeping the server PeSIT `ST → CFT` values intact); the three hand-written Direction tables fold
themselves. Raw DATA is never folded (`_transfers.tsv` col 2 stays `Inbound`/`Outbound`).

A ROW/TOTAL cell may lead with `@{class=…,colspan=N,link=…,alink=…,href=…,nolink=1}`
(`alink=<sub>/<name>` resolves through that sub-dir's slugmap at render time). A ROW may carry
`@data:NAME=VALUE` cells (emitted as `data-NAME` on the `<tr>`). Scripts emit values UNESCAPED
(the renderer escapes); keep TAB/CR/LF out of cells. Tables size to content; a wide table scrolls
inside its `.tablewrap`.

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

**Drill-down**: rows/cells carrying `data-coreids[-failed|-processed]` expand to the outcome's 10
most-recent transfers, built by the shared `COREIDS_AWK` helper; the server reports use
`@data:loglines` (`LOGLINES_AWK`, a bounded insert by "date time" — the exports are newest-first
within a file). Full detail in ARCHITECTURE.md.

### Transfer parse — _transfers.tsv

`bin/transfer/parse.sh` tokenizes `input/<env>/transfer/*.csv` once into
`data/<env>/transfer/cache/_transfers.tsv` (`$PARSED`). The CSV tokenizer is hand-rolled in awk
(quoted commas work on any awk). One 24-column row per record, sorted by CoreId then Direction:

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
IPv4 on a row whose account is OUT-side or unknown is replaced by the configured endpoint it maps
to (`input/<env>/ip/ip-hosts.tsv`); an IN-side row KEEPS the raw source IP. No reverse DNS. The
source CSV field indices (both logs) are in ARCHITECTURE.md ("Parse reference"); timestamps are
`MM/DD/YYYY HH:MM:SS.mmm`. Date arithmetic uses awk Julian-day helpers (`jdn()` etc.), never
`date`; `dur_ms()` sums the compound Duration values into ms, `humandur()` formats back. Exact
duplicate record lines are dropped (tokenizer AND post-merge pass), so overlapping exports cannot
double-count and the incremental cache stays byte-identical to a full reparse.

### The attribution chain (parse time, in this order)

Seven passes (0–6), fully specified in ARCHITECTURE.md; the order is deliberate:

0. **RENAME FOLD** (2026-08) — a logged subscription **and profile** name is folded to the name the CONFIG uses
   NOW, at the one canonicalisation point in `parse.sh` (where the `_SCP_` tail is stripped), via
   `input/<env>/renames/subscriptions.tsv` (`bin/renames.sh`, `rn_canon`). A log line keeps the
   name that was current when it was written, so an export that renames a flow would otherwise
   split its history in two — the configured half joining nothing and going orange, the logged
   half arriving as an unknown entity. The map is derived from the EXPORTS, never from the names
   (the 2026-08 rename dropped a doubled tail and folded `-`→`_`: deriving it by rule got 366 of
   545 right, 37 WRONG, 142 underivable); `fm_snapshot_renames` diffs each export against the
   previous run's `flowId`→name snapshot, so a rename records itself. Both files live under
   `input/` — the previous export's names are irreplaceable once it is overwritten, the
   `ip-hosts.tsv` argument. APPEND-ONLY, and a pair that would merge two flows or reuse a current
   name is REFUSED. `parser_sig` cksums the maps and `ensure_parsed` watches them, so recording a
   rename re-tokenizes. **The PROFILE has its own map** (`profiles.tsv`): the profile is what the
   reverse config fallback attributes a leg by, and an unmatched one cost 7,743 CoreIds their
   subscription (the no-subscription skip then dropped ~4.6% of Files). The SERVER side folds too
   — `parse.sh` when matching message tokens to the configured set, and
   `unknown-entities.sh` via **`rn_canon_pfx`**, since the server log TRUNCATES names: a fold
   there happens only when every completion of the truncated name agrees, never on a guess.
   Without it every renamed flow reads as an unknown subscription and `seen-in-server-log.sh`
   appends a phantom blue twin beside the real entity. `rn_canon_pfx` prefers a completion the
   token stops at a NAME-PART boundary of (`_`, or the whole name) when those agree — the ST short
   form `UC4_ODV-ARE-YARDI` is exactly `UC4_` + the first half of `UC4_ODV-ARE-YARDI_ODV-ARE-YARDI`
   while `UC4_ODV-ARE-YARDI-DWH_…` merely shares the prefix. Still a boundary rule, never a guess
   about content.
- **The estate is PRUNED of withdrawn discoveries** (`result.sh` `prune_withdrawn`): both colour
  steps APPEND entities the logs reveal, and nothing removed one whose evidence went away — the
  row just lost its blue and settled as ORANGE, a phantom "configured but never seen" flow that is
  not configured at all (this is how the caches once grew to 696 rows for 568 flows). A row
  survives when it is in `base/.configured.tsv` (the snapshot `flow-manager.sh` takes BEFORE
  either step appends), still blue this run, or backed by real transfer data.
1. **Blacklist** — `input/blacklist.txt` (COMMITTED; TSV `<field>⇥drop|keep⇥<value>`) BLANKS
   platform-internal values (row kept), read only through the sourced `bin/blacklist.sh`;
   `parser_sig` cksums it so an edit forces a full reparse. **report.js has no client-side
   blacklist net and must not gain one** — a config-side leak is filtered in `bin/flow-manager.sh`.
2. **CoreId-group propagation** — blanks fill from the first row in the group that carries a
   value; the unpropagated stream stays as `_transfers0.tsv`, the incremental merge/dedup base.
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
6. **NO-SUBSCRIPTION / HTTP SKIP** — a CoreId with neither site nor ACCOUNT anywhere, or any
   http leg, is dropped from both caches; its raw CSV lines go to `_skipped.csv`. Distinct from
   the `input/skip.txt` SKIP LIST (same layout as the blacklist, but DROPS THE WHOLE RECORD;
   read only through the sourced `bin/skiplist.sh`; matched cache rows → `_skipped.tsv`).

A changed subscriptions.json re-derives `_transfers.tsv` (export → flow-manager cache mtimes →
`ensure_parsed`). Reports skip blank entity values, or show a parenthesized/`-` pseudo-value where
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
```

- **col 9** = last row's start + its duration − first row's start (includes store-and-forward gaps
  and retry idle). UC2 exception: the partner-wait between staging and collect legs is EXCLUDED
  (it is col 21).
- **col 16** = the CONNECTION side (`in`/`out`/`""`); **col 17** = the FILE-MOVEMENT direction
  (col 12 joined on `xref/_subscriptions-flowdir.tsv` — the ONE place that join is done); they
  diverge on pull flows.
- **col 20** = the file's host via `_hosts-partners.tsv`, else the account's unambiguous org (a
  two-group account abstains).

**Outcome (col 2), the last-leg rules**: **Waiting** = ≥3 legs ending on the staging leg
(Inbound+`routing`) — a UC2 file staged, not collected; a later export with the collect leg
re-flips it. **Processed** = ≥2 legs, last leg Outbound+Processed AND matching the movement (out →
`ssh`/`ftp`/`ftps`, in → `pesit`); deliberately no bytes condition. **Failed** = everything else
(incl. a lone leg). **Expired** = a Waiting file whose staged copy the nightly File Maintenance
sweep (~11 days) deleted before pickup — server-log-only evidence, so **`bin/expire-files.sh`**
joins those lines onto Waiting rows (col 22 = the timestamp; cached in `_expired.tsv`,
cmp-guarded, recomputed each run; transfer `parse.sh` re-runs it last unless
`AXWAY_SKIP_EXPIRE=1`).

**OUTCOME POLICY: Waiting counts as OK, Expired counts as ERROR** on every report: Error =
(`=="Failed" || =="Expired"`), OK = otherwise (never `== "Processed"`). The waiting report and the
detail State column distinguish the states. **The entity RESULT COLOUR parts company with the
policy on EXPIRED** (2026-08): an expired-last flow is ORANGE, not red — a staged UC2 copy the
partner never collected and the sweep deleted is a PICKUP problem, nothing errored — so it leaves
the red worklist while the Expired report, the Expired box and every Error count still carry it.
It is red only when something ELSE says so: `result.sh` keeps it a candidate for the
after-last-transfer rule, so expired PLUS a newer server-log Error/Warn is still red.

`_files.tsv` takes the FIRST row with an account and the LAST row with a site.

### Which cache a report reads

Counting `_transfers.tsv` rows over-counts (~3x) and double-counts volume.
**Count/volume/failure/timing reports read `$FILES`**; **per-row dimension reports read
`$PARSED`** and count rows, their count column labelled **"Transfers"** ("Files" is reserved for
per-CoreId counts). The nine ENTITIES reports share one Summary/Detail layout counting distinct
CoreIds (`login.sh`/`subscription.sh`/`remote-host.sh` join `$PARSED`→`$FILES` deduped per
`(entity,CoreId)` — per-entity counts can sum to more than the distinct total).

**PARTNER = UNION attribution**: a File counts for EVERY partner of its subscription (col 12 on
`xref/_subscriptions-partners.tsv`) unioned with col 20 (alone it misses both-partner files, empty
by abstention). **APPLICATION = the same union via the ACCOUNT** (col 3 on
`xref/_accounts-apps.tsv` ∪ col 18). Applied in EVERY partner/application-counting consumer
(`details_lib.sh` carries the shared `SP_MAP`/`AP_MAP`). Domains stay single-valued (part 1 of
the logical flow name — parse col 19 keeps one).

### Server parse — _parse.tsv

`bin/server/parse.sh` tokenizes `input/<env>/server/*.csv` (handling quoted fields with embedded
newlines) into `data/<env>/server/cache/_parse.tsv` — 6 columns: date, time, level (I/W/E),
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
bookkeeping, the Universal Agent acknowledgements, the JSON Transfer start/end bookends, the
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
is the cost this filter exists to avoid. Editing the list changes `parser_sig`, so the next run
reparses in full. **Four server reports read those lines and were removed with them**:
`concurrency` (a `capacity` component), `event-feed` (a `platform-health` component), and
`transfer-outcomes` + `file-freshness` — both components of the merged `transfers` report, which
therefore went too, leaving `pickups` alone in the srv-transfers group. **`advanced-routing` went
the same way** (2026-08) when `AR0011/76/77` joined the list: its Routes table counted Executions
as the AR0076 total and Fail % as failures ÷ executions, so the report could not survive the
filter — `remote-poll` now leads srv-routing alone. Verified first that nothing else depended on
those lines: 0 of 136 blue entities evidenced by one, 0 of 905 entity mention caches made only of
them, 0 of 732 unknown-* seeds. The failed-file error
pages lost their JSON id join with them and now rest on the SESSION join, plus an ANY-MENTION id join
(2026-08-24: every bare UUID in a message looked up against the page's CoreId + transfer ids —
the `.stfs` segments never matched one; what it reaches is the `Error while resubmitting transfer
with id` line on the ADMIN session and the AR0086 post-processing delete on the route's).

`reports.sh` runs every server report in parallel (rosters come from the TRANSFER reports; a
missing roster is `exit 1`), calling `ensure_config`/`ensure_parsed` once up front. The five
`unknown-*` reports are ONE script, `bin/server/reports/unknown-entities.sh` — a map-reduce whose
known sets read the TRANSFER PARSE CACHE directly (cols 4/5/6/16), never a roster (roster-based
sets oscillate); `bin/build/seen-in-server-log.sh` runs it in build stage 1; its all-outputs
freshness check is inlined. Transfer reads nothing from the server REPORTS.

### Result colours (green / red / orange / blue)

**Entities DISCOVERED in the transfer log** (2026-08, `result.sh` stage 0, `discover_logged`): a
subscription (or remote host) can carry real transfers and still be absent from the FlowManager
export — a flow configured after the export was taken. The entity reports list it, so the Entities
view has a row the base cache knows nothing about and the home figure disagrees with the page
footer. The transfer log therefore DISCOVERS entities as the server log already does
(`seen-in-server-log.sh` appends its unknowns as blue); these are NOT blue — they transferred — so
they are appended with an empty result and coloured normally. The rosters MIRROR the reports that
list them: subscriptions = every `_files.tsv` col 12; hosts = col 15 of an OUT-side file (col 16),
the restriction `remote-host.sh` applies, so raw INCOMING addresses are never invented as
entities. A discovered host has no configured subscriptions, so the rollup would call it orange —
`host_own_unpaired` colours a host absent from the pair cache by its own last file instead
(`white_own`'s rule; every configured host is in the pair cache, so nothing else moves). The
append drops `.rescan-mentions` so the server mention scan picks the new names up.

The third column of every `base/*.tsv`, filled after the parses by two build steps (full detail in
ARCHITECTURE.md): **`bin/build/seen-in-server-log.sh`** marks entities seen only in the server
logs **blue**; **`bin/build/result.sh`** fills the rest, preserving blue — a subscription goes
green/red by its LAST File's outcome (red when Failed or Expired; orange = never seen), other
entities roll up their connected subscriptions (a blue subscription counts like ORANGE in the
rollup — server-log discovery must never change a health verdict; `_white.tsv` goes by the last
real transfer from that address instead). **Blue always means "never transferred".** ONE
deliberate exception, the **UC3 clean-poll rule** (2026-08): a would-be-blue UC3 subscription
whose newest successful poll is no older than its newest E-level mention flips GREEN — working,
just nothing to fetch (sidecar `blue/_greenpoll.tsv`; showseen treats a no-data green as
seen-with-blank-counts like blue; deploy-errors clears a UC3 on a poll after its last message).
**The two colour steps must AGREE** (2026-08): `seen-in-server-log.sh` leaves the clean-poll
greens alone (it reads `blue/_greenpoll.tsv`) and `result.sh`'s rollup counts one like ORANGE, as
it does a blue subscription — server-log discovery never sets a health verdict, and an entity
whose only flows have never moved a file is server-log-only, not green. Before that they
disagreed on ~46 subscriptions and ~16 accounts, so BOTH steps rewrote the base caches every run
and every report depending on the colours rebuilt for nothing: a no-op build was 1:39, now 36 s.
The clean-poll flip therefore fires on ORANGE as well as blue — the blue marking is no longer its
precondition, the poll evidence still is.

**A CONNECTED-RING ERROR REDDENS ONE FLOW, NOT ALL OF THEM** (2026-08): a remote host — and just
as much an account or a login — serves many subscriptions, so taking the newest line of its
`_err_warn` ring reddened EVERY flow configured for it — one bad endpoint, a dozen false reds all
carrying the same evidence stamp. `result.sh` `_build_ringattr` attributes each host/account/login
ring line to the ONE flow it concerns and writes `blue/_ringattr.tsv` (subscription ⇥ newest
attributed E stamp), which the flip reads instead of the rings: first the UC token in the MESSAGE,
else the SESSION (`_parse.tsv` col 6, the connection id) voted from the parse cache's own lines,
else — **the session join** (2026-08) — that session's transfer LEGS: `_transfers.tsv` col 24
carries the same id and col 6 the site the attribution chain gave the leg (canonical since parse
time; message/parse tokens fold through `rn_canon_pfx`). A line that attributes to NOTHING cannot
redden what it cannot identify; a session naming two flows — in the parse cache or in its legs —
resolves to neither. **The ring's own entity then owns what is left over** (`orphan_red`,
`blue/_ringorphan.tsv`, ring kind ⇥ name ⇥ stamp): an authentication failure naming only a
credential, a PeSIT transfer-profile complaint naming only the account, is a real problem at that
ENDPOINT / account / login, so it goes RED — unless it has moved a file OK SINCE (the "recovered
since" test the unresolved server reports apply; hosts count OUT-side files only) and never over a
row that is already red; a forward-address ring's residue lands on its endpoint. **E-level only**:
"Error" is the E level site-wide, and every W-level orphan is the benign "Transfer site ID is not
present in environment" shape. Acceptance: 1,128 ring E-lines, 975 attributed (340 distinct
sessions, 191 parse-voted + 62 more by the session join); the five false-red `UC1_IT_ADF_RABOBANK_*`
sisters all carried the one stamp that belongs to `_NSPP` alone. The detail-page banner still
reads its 1-to-1 connected rings wholesale — it shows the log; the COLOUR rests only on
attributed lines.

The SAME evidence also **keeps a UC3 green** (2026-08): the after-last-transfer red flip is
skipped when a successful poll is NEWER than the E-level stamp that would have flipped it — a
flow that has since polled cleanly is working, whatever it logged before (acceptance: 14 of the
15 candidates). `_greenpoll.cand` carries `name⇥newest poll⇥flag`, the flag driving the blue
rule and the stamp this one.
The after-last-transfer red flip records its evidence in `blue/_redflip.tsv` (name + ring stamp);
the UC status per-hour walkers read it (+ `_greenpoll.tsv`) so their sidecars' last row equals
the STAT figures.
Blue counts
as SEEN with blank counts; the status tables show it as the Server column; in the Transfer scope
it retints orange. `data/<env>/blue/<type>/<name>.txt` holds the evidencing log line per blue
entity (existence = the signal `blue_box` renders).

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
cross-links use `DLINK_BASE`. **All options, every env**: menus, sitemap and group tab bars list
every order-listed report UNCONDITIONALLY, so both envs' menus are identical; a missing `.rpt`
gets an "empty report" placeholder page (`render_missing_reports`). Publishes run concurrently
(production beside acceptance; `publish-details.sh` beside `publish.sh` — disjoint trees).

### The page families (details in ARCHITECTURE.md)

- **The home page** (`bin/build/publish.sh`): the two status tables — every cell opens the
  Entities view whose row count IS that figure, in the active scope; `check_status_consistency`
  verifies each figure; the SEEN figures come from `home.rpt`. The per-day figures are FIVE
  side-by-side tables in one `.sxs` row (2026-08): a shared DATE spine first (its cells link the
  day dashboard, its Total row carries the label), then Files (In · Out · Ok · Error · Error %;
  the In/Out split is the movement direction, `_files.tsv` col 17; the count column is gone —
  In + Out carries it), Duration (p50 · p75 · p90 · p95), Red/Green switch and First seen
  (Logical · Partners · Subscriptions · Accounts), each under its own `<h2>` and NONE carrying a Date
  column. All five list the same days in the same order so the rows align on the spine — which is
  why they are all `data-nosort` and the 14-day cap is lifted by ONE shared "Show all" button
  under the flex row (setupShowAll uncaps every capped table in its adjacent wrapper).
  **Red/Green switch** (2026-08): how many
  subscriptions FLIPPED that day, Red = green→red and Green = red→green, from a
  (subscription, sortkey) walk of `_files.tsv` in `daily_loglines_tsv`. The comparison is
  **END-OF-DAY state against the previous ACTIVE day**, never per File: the last File of a day
  sets that day's state (site-wide outcome policy, Waiting counts as OK), so a flow that broke and
  recovered inside one day ends it green and is NOT a flip; a day the flow carried nothing keeps
  the state, so the flip lands on the day the state actually changed. A flow's first active day
  only establishes its state. Each nonzero cell links `docs/<env>/switches/<date>.html#red|#green`
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
  lines, with their level, of the flow's NEWEST drill page — the page the home row opens)
  classified **FIRST-ERROR-first**, warnings only after. The opening error is the CAUSE and
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
- **The Entities pages**: 9 entities x 10 views under `docs/<env>/transfer/entities/`, one shared
  layout assembled at publish time from the entity `.rpt` + the coverage TSVs; the
  +Server/Transfer SCOPE decides whether a server-log sighting counts as seen; sort is shared
  across the nine entities (localStorage, 1-hour sliding expiry, stored by column label).
- **The detail pages** (`details.sh` → `details_lib.sh`/`details_writer.awk`): one page per entity
  of the nine types, every configured name gets one; slugs via the comprehensive `_slugmap.tsv`;
  no From/To, no search box, no RECALC.
- **The special pages**: Entity Search (rows ship as DATA in `search-data.js`; the Type cell is
  read by INDEX in report.js — adding a column means shifting it), the SIX File search pages
  (`file-search-{24-hours,48-hours,week,2-weeks,3-weeks,month}.html`, 2026-08: ONE page per
  window — result rows tint green/red by outcome via restint + a per-row `data-res` — with
  per-page `-data.js` payloads (v5, capped at 100,000 rows; a capped page turns into a RED
  banner on the build report via `file-search-capped.txt`), searched by the DEDICATED
  `docs/assets/file-search.js` — a Search button, never per-keystroke, the NAV row carrying
  `?q=` between the windows; 24 hours = the newest full day + the partial newest day, 48 hours
  = the second full day), the Report finder, the SIX Failed-transfers
  view pages (+ per-CoreId error pages), Cross References, Seen in server log, Entity coverage
  (assert OK ⊆ Current ⊆ Once), whitelist-audit, config-hygiene, Cronjobs, acc-vs-prod, UC status
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
empty stubs). **The BOXES-ONLY reports** (`BOXES_ONLY_REPORTS`) are in no group and no
menu/index/sitemap card; their pages stay at the area URLs with no group tab row, and only the
Boxes pages link them — their scripts still run in the area orchestrators. Both full lists are in
ARCHITECTURE.md.

`TRANSFER_MENU`/`SERVER_MENU` are built from the orders minus the basenames living in the Analyses
dropdown. `ANALYSES_MENU` is hand-written, one line per group: Start page · **Coverage & seen** ·
**Configuration** · **Partners** · **Boxes** · **Errors** ·
**Acceptance vs production**; `_analyses_groups` is the single
source of truth for the analyses group tab bars — **keep it in sync with `ANALYSES_MENU`, the
analyses index and the sitemap.** The Coverage/Configuration members whose PAGE renders into
`docs/<env>/transfer/` are absent from `group_of` and the transfer menu; `finder_area` labels them
Analyses. `_tag_variants` (group crumbs) skips a globbed page that is itself a listed member — the
`<base>-*.html` glob would otherwise claim a different member sharing the prefix.

## Publishing (GitHub Pages)

Published via GitHub Pages — branch `master`, folder `/docs`. No
CI build (the sources are gitignored): run `bin/build.sh` locally → commit `docs/` → `git push`,
both MANUAL.

- **Local preview: `http://localhost/develop/`** — the local Homebrew httpd serves this repo's
  `docs/` (the runtime twin serves at `http://localhost/runtime/`); preview there, never start a
  throwaway HTTP server, hard-reload after an asset edit. All generated links are RELATIVE, so
  the site works under any base path — the 404 page derives its home link from the URL itself.
- **`docs/` is PURE committed build output** (2026-08-29): every `bin/build.sh` run CLEARS its
  scope's docs tree (both = all of `docs/`, `acc`/`prd` = that env's subtree) and RE-SEEDS the
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
- **To add a transfer report**: a script in `bin/transfer/reports/` sourcing `../lib.sh`, calling
  `ensure_parsed`, aggregating `$PARSED` or `$FILES` into `$REPORTS_DIR/<name>.rpt`. Add it to
  `bin/transfer/reports.sh` and `transfer_order` (+ `group_of`/`member_label`, `report_tabs` if
  multi-table), and write its help page. Phase 1 unless it reads another report's output (phase 2
  = `showseen.sh`); build.sh overlaps the phases with `details.sh` in the background, so **a new
  phase-1 report must be safe to run beside the server reports**.
- **Every `.rpt` write is ATOMIC** (2026-08): `} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"` — never a
  direct `> "$OUT"`. skip_if_fresh trusts a fresh mtime, so a killed direct write would leave a
  truncated report every later run skips. Multi-write reports assemble in the ONE `$OUT.tmp` and
  mv once at the end; `bin/day/reports.sh` stages its whole per-day set in `reports.new/` and
  swap-renames (both its passes append across the file set). The `bin/*/reports.sh` orchestrators
  sweep orphaned `*.rpt.tmp` at start. One build runs at a time: `bin/build.sh` takes
  `data/.buildlock` (owner PID recorded; a dead owner's lock is reclaimed automatically).

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
  source; downstream needs no folding. Readers of `input/<env>/ip/` lowercase the HOST column at
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

Every pipeline script lives under **`bin/`** — `bin/runtime.sh` (the develop→runtime code
sync) included; the committed repo top is `bin/ assets/ docs/`,
the three `.md` docs, `.gitignore`/`.gitattributes` and **`input/`** — in
THIS repo committed IN FULL, sample CSVs included (the whole estate is synthetic and small;
`bin/sample/generate.sh` rewrites it). `input/` holds the flow-manager JSONs, the `ip/` and
`renames/` maps, the `.sample-estate` marker + `.sample/` spec, the two policy files
`input/{blacklist,skip}.txt`, the hand-curated `input/partner-aliases.tsv` (partner tokens
naming one organisation — flow-manager's merge rule 4, `variant⇥CANONICAL`; the right side
also names the merged group via the alias star)
and `input/rename.txt` (DISPLAY renames, applied to the rendered pages by the build's last
step — see the manual re-publish gotcha) and `input/logical.txt` (fixed FlowID → Logical
transforms feeding the Logical entity derivation — owned by `bin/flow-manager.sh` since Logical
became a full entity, and one of its freshness deps; a listed FlowID skips the derivation) and
`input/logical_{domains,apps,partners}.txt` (hand-curated FROM→TO PART replacements for the
Logical-based PDA derivation: part 1/2/3 of a three-part Logical name is replaced before it
becomes the domain / application / partner-merge token — the Logical name itself is untouched;
freshness deps too), plus a
README.txt per directory. Gitignored: the `data/` root and `/build/`. A step script that
only `bin/build.sh` ever invokes lives in **`bin/build/`** — the placement rule; the sample-data
generator lives in **`bin/sample/`** (guarded by the marker, seeds in `bin/sample/seed/`).

```
bin/build.sh            the whole chain, both envs

# SHARED — sourced or called by the area scripts:
bin/env.sh              AXWAY_ENV resolution          bin/fastawk.sh    the mawk PATH shim
bin/ip.sh               address<->endpoint map        bin/blacklist.sh  field blanking
bin/skiplist.sh         record dropping               bin/uc-cases.sh   uc_meta()
bin/renames.sh          subscription rename map (input/<env>/renames/) + fm_snapshot_renames
bin/publish_lib.sh      shared renderer + globals     bin/cron2human.awk cron -> prose
bin/render_rpt.awk      the one-pass page-body renderer
bin/merge_rpt.sh        component .rpt -> merged tabbed report
bin/flow-manager.sh     config exports -> data/<env>/flow-manager/{base,xref}
bin/expire-files.sh     Waiting -> Expired from the File Maintenance sweep lines
bin/session-sites.sh    UCx groups -> real subscription via the server log's session route lines

# BUILD-ONLY — nothing but bin/build.sh invokes these:
bin/build/seen-in-server-log.sh  mark server-log-only entities blue (+ the unknown-* reports)
bin/build/result.sh              fill the base result columns (preserve blue)
bin/build/publish.sh             index pages + the shared home; run LAST
bin/build/crosslink.sh           stamp the env-switch twin links
bin/build/linkcheck.sh           every link resolves + every page is reachable (manual gate)
```

All data lives under two roots at the repo top (`data/` gitignored wholesale; under `input/` only
the `*.csv` exports are gitignored):

- `input/<env>/{transfer,server}/*.csv` + `input/<env>/flow-manager/*.json` — the raw exports
  (irreplaceable); `templates.json` optional. `input/blacklist.txt` (COMMITTED) and
  `input/skip.txt` — see the attribution chain.
- `input/<env>/renames/` — `subscriptions.tsv` (old⇥current) and `flowid-names.tsv` (the previous
  export's `flowId`⇥name snapshot). **Machine-maintained, never hand-written**; under `input/`
  for the same reason as the DNS map — once an export is overwritten its names cannot be
  recovered, and `rm -rf data/` must stay safe. See the attribution chain, step 0.
- `input/<env>/ip/ip-hosts.tsv` — the PER-ENV address ↔ endpoint map (`ip⇥host`), **fully
  automatic, never hand-written**; **`bin/ip.sh`** owns it (`ip_put`, the only writer,
  cmp-guarded; an empty dir is valid). **There is NO reverse DNS anywhere, and none may be
  reintroduced** — the configuration names endpoints. Writers: `flow-manager.sh` forward-resolves
  the configured hosts (with `base/_hosts.tsv` as the KEEP list); `parse.sh` records each new
  OUTGOING IPv4 under the host configured for its account (no row on disagreement; an INCOMING
  address gets no row — it stays raw in col 16). **`ip_put` UNIONS, never replaces.** Under
  `input/` because a DNS answer cannot be regenerated — `rm -rf data/` must stay safe.
- `data/<env>/<area>/cache/` — the tokenized caches + companions; `data/<env>/<area>/reports/` —
  the `.rpt` descriptors (+ `details/`, `coverage/`, `errors/`).
- `data/<env>/unknown/*.tsv` — the unknown-* sidecars + the SSH-logon files; ALL FIVE sidecars
  seed the blue step (accounts/logins/sites/hosts/white — `white.tsv` carries only TM-mentioned
  whitelisted IPs and recolors `base/_white.tsv` via `recolor … onlywhite`; the xref `_white-*`
  pair caches are enrichment inputs, not seeds). Rewritten each run; a type with
  no unknowns keeps an EMPTY sidecar (a deleted one would force a full rescan every build).
- `data/<env>/blue/` — the blue evidence. `data/<env>/flow-manager/{base,xref}/` — the config
  caches. `data/<env>/.publish/*.stamp` — the freshness stamps (`data/.publish/crosslink.stamp` is
  shared).

`input/` is deliberately separate from the wipe-able `data/`: `rm -rf data/` is safe and never
touches the raw CSVs or the DNS map. The built site is the committed repo-root `docs/`.
