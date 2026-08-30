# develop

Build stats from Axway SecureTransport Cloud logs — the **DEVELOP** repo.

## The two-repo model (develop / runtime)

This project lives in two sibling repos that share ALL code but never data:

- **develop** (this repo) — where every change is made, including AI-assisted
  work. It carries ONLY the **sample estate**: fully synthetic input data
  written by `bin/sample/generate.sh` (fake orgs, RFC 5737 TEST-NET
  addresses, `.example` hosts). No real company data exists here, in the
  working tree or in git history, so nothing real can ever leak into an AI
  context. Preview: **http://localhost/develop/**.
- **runtime** — the operational twin holding the REAL exports. It is
  operated, never developed: no CLAUDE.md/ARCHITECTURE.md, only its own
  README. **AI must never read or edit the runtime repo.** Preview:
  **http://localhost/runtime/**.

Code flows one way, develop → runtime, via **`bin/runtime.sh
<path-to-runtime>`**: it syncs `bin/` + `assets/` (+ `.gitattributes`) into
the runtime checkout and then runs that checkout's `bin/fresh.sh`, rebuilding
the runtime site from its own real data. It never touches `input/`, and the
committed `input/.sample-estate` marker (checked by `bin/sample/generate.sh`,
absent in runtime by construction) makes it impossible for the generator to
overwrite real exports. The sync EXCLUDES the develop-only tooling —
`bin/runtime.sh` itself and `bin/sample/` — and removes any copy an earlier
refresh left behind, so runtime's `bin/` carries pipeline code only.

## What it publishes

A static HTML site under `docs/`, serving **two environments side by side**
(`docs/acceptance/`, `docs/production/`) behind one shared home page:

- **Transfer reports** — counts, volume, failure rate, protocol, activity,
  performance, notable transfers and AV scan over the FlowManager transfer
  logs, plus a detail page per account, subscription, login, host, partner,
  application and domain, and seven Entities views.
- **Server reports** — records per day, errors and error reasons, logons and
  connections, PeSIT link health, and entities seen in the server logs but
  missing from the transfer logs.
- **Analyses** — configured-vs-seen coverage, first seen, configuration
  hygiene, the Boxes pages, and acceptance-vs-production comparisons.
- **Dashboards and day pages** — the graphical overview, the CFT end-to-end
  Monitor and one page per calendar day.

## How it works

No build system, test framework or package manager — **bash + awk** pipelines.
Requirements: `bash` (3.2 works; the target machine is macOS with BSD userland
— `bin/build.sh` uses BSD `stat -f`), POSIX `awk` (Homebrew **mawk** is picked
up automatically as a 4–9x accelerator), `sort`, `sed`, `date`, `jq` (config
JSON), `perl` and `cksum` (used by the publish/crosslink steps).

Everything is **per environment**, selected by `AXWAY_ENV`
(`acceptance`|`production`, default `acceptance`): `input/<env>/…` →
`data/<env>/…` → `docs/<env>/…`. Computation is separated from presentation,
in three stages:

- **Parse** — `bin/transfer/parse.sh` and `bin/server/parse.sh` tokenize
  `input/<env>/{transfer,server}/*.csv` **once** into gitignored caches
  (`data/<env>/transfer/cache/_transfers.tsv` + `_files.tsv`,
  `data/<env>/server/cache/_parse.tsv`); both are incremental — adding an
  export folds in just that file. `bin/flow-manager.sh` extracts the
  configuration caches from `input/<env>/flow-manager/*.json` first.
- **Report** — each area's `reports.sh` runs the report scripts; every report
  writes a small TAB-separated **`.rpt` descriptor** to
  `data/<env>/<area>/reports/` — no HTML.
- **Publish** — the publish scripts (sharing `bin/publish_lib.sh`) render the
  `.rpt` files into `docs/<env>/…`; `bin/build/publish.sh` writes the index
  pages and the shared home **last** (the per-area publishes clear the dirs
  its pages live in).

The whole chain, both environments, is one command:

```bash
bin/build.sh              # both envs (acc | prd for one env only) — NO git step
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

- `input/<env>/` — the SAMPLE exports: transfer/server CSVs, the
  flow-manager JSONs, `input/<env>/ip/` (the forward-resolved
  address↔endpoint map — owned by `bin/ip.sh`; no reverse DNS anywhere) and
  `input/<env>/renames/`. All committed in this repo (they are synthetic and
  small); regenerate with `bin/sample/generate.sh`. Root policy files:
  `input/blacklist.txt`, `input/skip.txt`, `input/partner-aliases.tsv` and
  `input/rename.txt` (display renames — shown instead of the real names at
  publish time, the data untouched) and `input/logical.txt` (fixed FlowID →
  Logical transforms for the Logical pages).
- `data/<env>/` — regenerable caches and `.rpt` files (gitignored).
  `rm -rf data/` is safe and never touches the exports.
- `docs/` — the rendered site, PURE build output: every build clears its
  scope and re-seeds the hand-authored assets from the repo-root `assets/`
  (`style.css`, `report.js`, `slotchart.js`, `file-search.js`,
  `assets/help/`). **Edit in `assets/`, never in `docs/`** — a build
  overwrites the docs copies.

Preview locally at **http://localhost/develop/** (the local httpd serves this
repo's `docs/`; the runtime twin serves at **http://localhost/runtime/**).
Hard-reload after an asset edit — the `?v=` cache-buster refreshes on the
next publish.
