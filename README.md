# develop

Build stats from Axway SecureTransport Cloud logs — the **DEVELOP** repo.

## The three-repo model (develop / runtime-acceptance / runtime-production)

This project lives in three sibling repos that share ALL code but never data:

- **develop** (this repo) — where every change is made, including AI-assisted
  work. It carries ONLY the **sample estate**: fully synthetic input data
  written by `bin/sample/generate.sh` (fake orgs, RFC 5737 TEST-NET
  addresses, `.example` hosts). No real company data exists here, in the
  working tree or in git history, so nothing real can ever leak into an AI
  context. Preview: **http://localhost/develop/**.
- **runtime-acceptance** and **runtime-production** — the operational twins
  holding the REAL exports of one environment each (one repo = one
  environment since 2026-09-11; the old combined `runtime` repo is retired).
  They are operated, never developed: no CLAUDE.md/ARCHITECTURE.md, only
  their own README. **AI must never read or edit a runtime repo.** Previews:
  **http://localhost/runtime-acceptance/** and
  **http://localhost/runtime-production/**.

Code flows one way, develop → runtime, via **`bin/acc.sh`** and
**`bin/prd.sh`** (no arguments — the runtime checkouts sit beside this repo
as `../runtime-acceptance` and `../runtime-production`): each syncs `bin/` +
`assets/` (+ `.gitattributes`) into its checkout and then runs that
checkout's `bin/fresh.sh`, rebuilding the site from its own real data; run
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
archives its build ingests from the inbox (`acc*.7z` / `prd*.7z`); the log
exports inside land as `logEntry_mm-dd.csv` / `fileTransfer_mm-dd.csv`.

## What it publishes

A static HTML site under `docs/` — one environment per checkout, its home page
at the docs root:

- **Transfer reports** — counts, volume, failure rate, protocol, activity,
  performance, notable transfers and AV scan over the FlowManager transfer
  logs, plus a detail page per account, subscription, login, host, partner,
  application and domain, and seven Entities views.
- **Server reports** — records per day, errors and error reasons, logons and
  connections, PeSIT link health, and entities seen in the server logs but
  missing from the transfer logs.
- **Analyses** — configured-vs-seen coverage, first seen, configuration
  hygiene and the Boxes pages.
- **Dashboards and day pages** — the graphical overview, the CFT end-to-end
  Monitor and one page per calendar day.

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
  `data/server/cache/_parse.tsv`); both are incremental — adding an
  export folds in just that file. `bin/flow-manager.sh` extracts the
  configuration caches from `input/flow-manager/*.json` first.
- **Report** — each area's `reports.sh` runs the report scripts; every report
  writes a small TAB-separated **`.rpt` descriptor** to
  `data/<area>/reports/` — no HTML.
- **Publish** — the publish scripts (sharing `bin/publish_lib.sh`) render the
  `.rpt` files into `docs/…`; `bin/build/publish.sh` writes the index
  pages and the shared home **last** (the per-area publishes clear the dirs
  its pages live in).

The whole chain is one command:

```bash
bin/build.sh              # everything — no arguments, NO git step
bin/fresh.sh              # FULL fresh build: wipe data/ + docs/, then build.sh
bin/sample/generate.sh    # regenerate the sample estate (develop only)
bin/sample/verify.sh      # assert the built site covers every planted scenario
```

Each run writes an HTML **build report** to `build/index.html` (local only,
gitignored; one row per step with duration and OK/FAILED, plus captured
output — written even when a step fails). Only one build can run at a time
(`data/.buildlock`).

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
  (`style.css`, `report.js`, `slotchart.js`, `file-search.js`,
  `assets/help/`). **Edit in `assets/`, never in `docs/`** — a build
  overwrites the docs copies.

Preview locally at **http://localhost/develop/** (the local httpd serves this
repo's `docs/`; the runtime twins serve at **http://localhost/runtime-acceptance/**
and **http://localhost/runtime-production/**).
Hard-reload after an asset edit — the `?v=` cache-buster refreshes on the
next publish.
