# develop

Build stats from Axway SecureTransport Cloud logs — the **DEVELOP** repo.

## The three-repo model (develop / acceptance / production)

This project lives in three sibling repos that share ALL code but never data:

- **develop** (this repo) — where every change is made, including AI-assisted
  work. It carries ONLY the **sample estate**: fully synthetic input data
  written by `bin/sample/generate.sh` (fake orgs, RFC 5737 TEST-NET
  addresses, `.example` hosts). No real company data exists here, in the
  working tree or in git history, so nothing real can ever leak into an AI
  context. Preview: **http://localhost/develop/**.
- **acceptance** and **production** (the local checkouts; GitHub `runtime-acceptance` /
  `runtime-production`) — the operational twins
  holding the REAL exports of one environment each (one repo = one
  environment since 2026-09-11; the old combined `runtime` repo is retired).
  They are operated, never developed: no CLAUDE.md/ARCHITECTURE.md, only
  their own README. **AI must never read or edit a runtime repo.** Previews:
  **http://localhost/acceptance/** and
  **http://localhost/production/**.

Code flows one way, develop → runtime, via **`bin/acc.sh`** and
**`bin/prd.sh`** (no arguments — the runtime checkouts sit beside this repo
as `../acceptance` and `../production`): each syncs `bin/` +
`assets/` (+ `.gitattributes`) into its checkout and then runs that
checkout's `bin/build.sh`, rebuilding the site from its own real data; run
the two one after the other, never at the same time. It never touches `input/`, and
the committed `input/.sample-estate` marker (checked by
`bin/sample/generate.sh`, absent in a runtime checkout by construction) makes
it impossible for the generator to overwrite real exports. The sync EXCLUDES
the develop-only tooling — `bin/acc.sh`, `bin/prd.sh`, their shared
`bin/runtime-lib.sh` and `bin/sample/` — and
removes any copy an earlier refresh left behind, so a runtime `bin/` carries
pipeline code only. Which environment a checkout serves is written in its
hand-maintained `input/environment.txt` (`Acceptance` / `Production`; `Sample`
here) — the top-bar label, the home title, and the prefix of the update
archives its build ingests from the inbox (`acc*.7z` / `prd*.7z` or `prod*.7z`); the log
exports inside land as `logEntry_yyyy-mm-dd.csv` / `fileTransfer_yyyy-mm-dd.csv`
and stay in `input/` (the retention step that moved exports older than the past
month to `archive/` was removed 2026-09-28).

## What it publishes

A static HTML site under `docs/` — one environment per checkout, its home page
(the status tables and the per-day table) at the docs root:

- **Reports** — 12 groups over both logs and the FlowManager configuration.
  Three open from their own top-bar links — Overview (the two Top views),
  Entities and Errors (the server log errors included) — and the ONE
  **Reports ▾** menu holds a start page (`reports/index.html`) plus the other
  nine: Use cases & delivery · Activity & volume · Performance · Flow
  patterns · Protocols & security · Logons & connections · Partners ·
  Configuration · Coverage. The reports of a group link each other through
  the first row of buttons.
- **Entities** — nine types (subscription, logical flow, partner, account,
  login, host, domain, application, BL) × six views (All · Seen · Not seen
  · OK · Warning · Error), plus a detail page per entity of the nine types.
- **Search** — the All files search (every File, by name or CoreId) and the
  Entity Search.
- **Dashboard, Monitor and day pages** — the graphical overview, the CFT
  end-to-end Monitor and one page per calendar day.
- **Tools** — the site map (`tools/sitemap.html`, whose Tools card links
  Home, Search, All files search, Help and the build report) and the build
  report (`tools/build.html`).

## How it works

No build system, test framework or package manager — **bash + awk** pipelines.
Requirements: `bash` (3.2 works; the target machine is macOS with BSD userland
— `bin/build.sh` uses BSD `stat -f`), POSIX `awk` (Homebrew **mawk** is picked
up automatically as a 4–9x accelerator), `sort`, `sed`, `date`, `jq` (config
JSON), `perl` and `cksum` (used by the publish and display-rename steps).

The trees are flat — `input/…` → `data/…` → `docs/…` (one repo = one
environment; there is no environment variable or segment anywhere).
Computation is separated from presentation, in three stages:

- **Parse** — `bin/transfer/parse.sh` and `bin/server/parse.sh` tokenize
  `input/{transfer,server}/*.csv` **once** into gitignored caches
  (`data/transfer/cache/_transfers.tsv` + `_files.tsv`,
  `data/server/cache/_parse.tsv`). `bin/flow-manager.sh` extracts the
  configuration caches from `input/flow-manager/*.json` first.
- **Report** — each area's `reports.sh` runs the report scripts; every report
  writes a small TAB-separated **`.rpt` descriptor** to
  `data/<area>/reports/` — no HTML.
- **Publish** — the publish scripts (sharing `bin/publish_lib.sh`) render the
  `.rpt` files into `docs/…`; `bin/build/publish.sh` writes the index
  pages, the shared home and every report's group row **last** (the
  per-area publishes clear the dirs its pages live in).

The whole chain is one command:

```bash
bin/build.sh              # everything, always from scratch — no arguments, NO git step
bin/sample/generate.sh    # regenerate the sample estate (develop only)
bin/sample/verify.sh      # assert the built site covers every planted scenario
```

Every build is a FRESH build: it wipes `build/`, `data/` and `docs/`,
re-seeds `docs/` from `assets/` and runs every step in full — there are no
incremental builds. Each run writes an HTML **build report** to
`build/index.html` (gitignored; one row per step with duration and
OK/FAILED, plus captured output — written even when a step fails), its site
copy `docs/tools/build.html` (linked from the site map) and its console to
`build/build.log`. Only one build can run at a time
(`build/.buildlock`).

For running individual stages, the full dependency rules, the `.rpt` protocol
and every convention, see **`CLAUDE.md`**; deep subsystem notes live in
**`ARCHITECTURE.md`**.

## Data layout

- `input/` — the SAMPLE exports: transfer/server CSVs, the flow-manager
  JSONs, `input/ip/` (the forward-resolved address↔endpoint map — owned by
  `bin/ip.sh`; no reverse DNS anywhere) and `input/renames/`. All committed
  in this repo (they are synthetic and small); regenerate with
  `bin/sample/generate.sh` (no arguments — one estate, the union of the
  former acceptance and production sample rosters). The hand-maintained
  files at the input root: `input/environment.txt` (the checkout's label),
  `input/blacklist.txt`, `input/skip.txt`, `input/rename.txt` (display
  renames — shown instead of the real names at publish time, the data
  untouched), `input/logical.txt` (fixed FlowID → Logical transforms for the
  Logical entity — the FlowIDs condensed into logical flow groups, a full
  entity with its own pages), `input/logical_{domains,apps,partners}.txt`,
  `input/BL.txt`, `input/logons_old.txt` and `input/coreid-url.txt`.
- `data/` — regenerable caches and `.rpt` files (gitignored).
  `rm -rf data/` is safe and never touches the exports.
- `docs/` — the rendered site, PURE build output: every build clears it
  wholesale and re-seeds the hand-authored assets from the repo-root `assets/`
  (`style.css`, `report.js`, `slotchart.js`, `all-files-search.js`, `sub-files.js`,
  `assets/help/`). **Edit in `assets/`, never in `docs/`** — a build
  overwrites the docs copies.

Preview locally at **http://localhost/develop/** (the local httpd serves this
repo's `docs/`; the runtime twins serve at **http://localhost/acceptance/**
and **http://localhost/production/**).
Hard-reload after an asset edit — the `?v=` cache-buster refreshes on the
next publish.
