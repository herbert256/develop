# ARCHITECTURE.md — deep subsystem notes

Companion to `CLAUDE.md`, which holds the always-needed rules. This file holds the detailed
mechanics of the individual subsystems and page families. **Read the relevant section here before
changing that subsystem**; it is not auto-loaded, so nothing in it can be assumed known.

## Parse reference

Source CSV field indices (transfer log): `1`=Status, `2`=Account, `3`=Login, `7`=Transfer Site,
`8`=Direction, `9`=Action By, `12`=Transfer Profile, `15`=Local Filename, `17`=ICAP Details,
`19`=Size, `20`=Protocol, `22`=Mode, `23`=Start Time, `24`=End Time, `25`=Duration, `26`=Remote Host,
`29`=Transfer ID, `30`=Session ID (the technical connection — one SSH/PESIT connection = one id),
`34`=CoreId, `35`=Resubmitted, `38`=SecurityParameters. Server logs: `1`=Time,
`2`=Level, `3`=Component, `5`=Message. Timestamps are `MM/DD/YYYY HH:MM:SS.mmm`.

## Merged and boxes-only report lists

**Merged reports** (`bin/merge_rpt.sh`, run after the report pools) fold component `.rpt`s into
one tabbed report; the components stay on disk as unpublished intermediates and every other
consumer keeps reading them. Transfer: `activity` (day+weekly+hourly+weekday), `retries`
(retry+attempts+resubmissions), `file-journey` (patterns+legs-count+protocol-journey+arrived-left),
`files` (size-dist+file-type+duplicate-files), `volume` (volume-src+trend), `went-quiet`
(went-quiet-src+stale-accounts). Server: `errors`, `connections`, `logons`, `ssh-security`,
`platform-health`, `capacity`, `missing-entities`, `transfers`. Analyses: `uc-status`.
`report_tabs` names one tab per component table; `_merge_pad` pads a missing component with empty
stubs so the tab count always matches. Components are listed in `MERGED_COMPONENT_REPORTS`
(whats-new skips them); merged basenames reuse one component's help slug.

**The BOXES-ONLY reports** (`BOXES_ONLY_REPORTS`/`is_boxes_only`): pirates · from-green-to-red ·
only-red · waiting · expired · went-quiet · missing-cronjobs (transfer) and went-kaput ·
site-failures · deploy-errors · no-remote-dir · no-remote-files (server). In NO group and NO area
menu/index/sitemap card; their pages stay at the area URLs with no group tab row; the sitemap
lists them under the Boxes card; the report finder labels them Analyses. Their scripts still run
in the area orchestrators and feed the boxes and day pages.

## The attribution chain (parse time, in this order)

1. **Blacklist — ONE file, `input/blacklist.txt`** (TSV `<field>⇥drop|keep⇥<value>`: `drop`
   blanks on exact match, `keep` = a regex every kept value must match), read through the sourced
   **`bin/blacklist.sh`** (`BLACKLIST_FILE` + `BLACKLIST_AWK`) by its two script consumers —
   transfer `parse.sh` (the authoritative blanking) and server `unknown-entities.sh` — plus the
   generated `docs/assets/blacklist-data.js`.
   COMMITTED (`.gitignore` has `!input/blacklist.txt` — platform policy, not site data);
   `parser_sig` cksums it so an edit forces a full reparse. Blanked (row kept): account
   `SECURETRANSPORT`; any filled site NOT starting with `UC` (catches the `Clone - …` artifacts);
   logins `SECURETRANSPORT`/`P14303_CFT01`/`*nobody`/`UNKNOWN`; the internal cluster hosts
   (`localhost`/`145.219.156.40`/`.20`/`.21`, applied AFTER the endpoint-map fill). Login
   `@`-fallback: a blanked login falls back to the part after `@` in its account
   (`ACME@FE000593` → `FE000593`) — unless that value is itself blacklisted: the blacklist
   outranks the fallback (2026-08-15; an `X@P14303_CFT01`-style account would otherwise
   resurrect the very login just blanked).
2. **CoreId-group propagation**: each still-blank entity value (account, login, site, remote_host;
   profile's blank is `UNKNOWN`) is filled from the first row in the same CoreId group that
   carries one. Only blanks are filled. The unpropagated stream is kept as `_transfers0.tsv` (the
   incremental merge/dedup base); `_transfers.tsv` is derived from it each run.
3. **Config fallback**, both ways. *Reverse*: a group whose every row lost its site but which
   carries a profile takes its subscription from config keyed on that `FlowIdentifier` — NOT
   unique (a flow is commonly two subscriptions, one per direction), so the group's pesit-leg
   direction disambiguates via the subscription's `patternName` (`…_PESIT_PUSH_ST_…` = pesit
   Inbound, `…_ST_CFT_PESIT_PUSH_APP` = pesit Outbound); no unique match → left empty, never
   guessed. *Forward* (after reverse): a row with a site but no account/profile takes them from
   that subscription's config (account = the non-APPLICATION participant, profile =
   `customAttribute_FlowIdentifier`).
4. **XREF single-value fallback** (after reverse, before forward): each still-missing group entity
   — site first, then account, login, profile — takes the unanimous vote of the populated fields
   whose `_<item>-<target>.tsv` maps them to exactly ONE configured value; a conflict leaves it
   empty. HOST is never filled (raw-IP vs configured-DNS spellings conflict) but still votes.
5. **FLOWDIR fallback + FAKE SUBSCRIPTION** (2026-08): a group still siteless after the xref vote
   takes its account's single configured subscription on the MOVEMENT side its legs unanimously
   imply — ssh/sftp/ftp/ftps move the file the way the connection points (Inbound = `in`,
   Outbound = `out`), pesit the opposite; http/routing legs abstain, disagreeing legs kill the
   vote. Sources: `_accounts-subscriptions.tsv` × `_subscriptions-flowdir.tsv` (the `F` records
   of the phase-2 map). Validated with ZERO counter-examples over the 181,297 attributed groups.
   Failing that, the **SESSION JOIN** (2026-08) asks the SERVER log which flow the connection a
   leg ran over executed: `_transfers.tsv` col 24 and `_parse.tsv` col 6 carry the SAME session
   id, and that session's route lines — `Initializing route: {UC4_SI_VPS_VDN}`, the ARRC/AR
   `[account] [route]` brackets — name the subscription ST itself ran, the platform's own
   attribution. `bin/session-sites.sh` (stage 1, after both parses, before expire-files) learns
   the `session⇥subscription` map into `cache/_sessionsites.tsv`: only the sessions of
   currently-UCx rows are (re)scanned, tokens are rename-folded (`rn_canon`) and must be
   configured subscription names, a session naming two flows maps to NEITHER, and unscanned
   entries persist (they keep a rescued group attributed on the next full derive). The file is
   cmp-guarded; when it changed, the script re-runs the transfer parse with
   `AXWAY_SKIP_SESSIONS=1` (a bounded derive-only re-run). The derive's pass (between FLOWDIR and
   the fake name; the `Z` records of the fallback map) adds two more refusals: the group's mapped
   sessions must be UNANIMOUS, and the flow must be one the group's ACCOUNT is configured for
   when that account has a configured list at all. `ensure_parsed` and parse.sh's derive-only
   fast path watch the map's mtime like the xref caches. Acceptance validation: 12 UCx sessions
   scanned, 4 mapped, 7 of 11 UCx Files rescued onto `UC4_SI_VPS_VDN`/`UC4_WA_VDN` (both already
   carrying the flows' properly-attributed history); the 4 `UCx_ODV-MAIA-EBENEFITS` Files stay —
   their routes log as `{ODV-MAIA-EBENEFITS}` with no UC name, and the account has two configured
   flows, so nothing may guess between them.
   Failing that too, the **INBOUND-LEG TIE-BREAK** (2026-08) resolves the delivered-file-plus-echo
   shape: a movement vote conflicted PURELY by partner-protocol legs (no pesit vote) with an
   Inbound leg present — a partner delivered a file and the same connection carried an echo leg
   back. The Inbound leg outvotes the echo (the file moved IN) and the group takes the account's
   single configured movement-in subscription, abstaining when it has two — the rule picks a
   flow, never a UC. Validated on acceptance: every attributed group with both an Inbound and an
   Outbound ssh leg was movement-in (39, all UC4), zero genuinely movement-out (the 3 nominal
   UC2 ones logged no site and resolve earlier via the xref single-value fallback — their account
   has only that one flow — so this pass never sees them); on the 7 session-rescued groups the
   session evidence and this inference agree 7-for-7. The SESSION JOIN outranks it: that is the
   platform naming the flow, this is an inference.
   When even that fails, a group WITH an account keeps the SYNTHETIC site **`UCx_<account>`**
   (the account is already `@…`-stripped; `UCx` = the UC naming shape with an unknowable UC
   number — every UC extractor is digit-anchored, so it classifies to no use case): the
   transfers count everywhere a site is counted, and
   the name behaves like any logged-but-unconfigured subscription — `result.sh discover_logged`
   appends it to `base/_subscriptions.tsv` (empty direction), so the coverage/home/Entities
   figures stay consistent, it gets a detail page + slugmap entry via details.sh, and it lists
   on not-in-flow-manager — EXCEPT that **first-seen.sh drops `UCx_` names** at both its base
   and coverage intake (nothing was configured, so no first sighting can be dated). `uc_meta`
   returns empties for it.
6. **NO-SUBSCRIPTION / HTTP SKIP**: a CoreId with neither site nor ACCOUNT anywhere after all
   passes — or an http leg on any row (web-UI hand traffic) — is dropped from
   `_transfers.tsv`/`_files.tsv`; its raw
   CSV lines go verbatim to `data/<env>/transfer/_skipped.csv`, recomputed each derive (a later
   export adding a subscription leg brings the CoreId back). Distinct from the **`input/skip.txt`
   SKIP LIST**: same layout as the blacklist but a matched rule DROPS THE WHOLE RECORD (field
   `account|login|site|message|any`; rule `contains` default case-insensitive | `exact` | `regex`;
   no TAB = `any contains <line>`; matched formatted cache rows go to `_skipped.tsv`).
   **`bin/skiplist.sh`** is the ONE reader (`SKIPLIST_FILE` + `SKIPLIST_AWK`
   `sl_load`/`sl_match`/`sl_hit`, plus `skip_values FIELD`); its five consumers: transfer
   `parse.sh`, server `parse.sh` (via `message`/`any`), `bin/flow-manager.sh` (jq),
   `bin/analyses/reports/skipped.sh` (`sl_match` names WHICH rule), `publish_lib.sh`'s
   `skipped_tokens`.

## Result colours (green / red / orange / blue) — full detail

1. **`bin/build/seen-in-server-log.sh`** marks entities appearing in the server logs (TM runtime
   lines) but never in the transfer logs **blue** (a real base value the normal tint path renders;
   style.css `#d3e6fb`). The blue set: enrich each `data/<env>/unknown/*` sidecar seed via the
   xref caches (single-value vote, fixpoint; a truncated site seed canonicalizes to its unique
   configured prefix match; a host seed enriching to nothing is dropped; duplicates collapse); per
   entity type, the enriched values on NO real `_files.tsv` row are blue. A NON-subscription
   candidate whose connected subscriptions include one with real transfer data is skipped (its own
   column merely went unattributed — only a subscription's orange means truly never-seen).
   SSH-logon evidence (TM `[Ssh Default]` Allowed/Disallowed/authenticated lines) becomes
   `data/<env>/unknown/logon-{logins,accounts,ips}.tsv` + `logon-evidence.tsv`, extracted by the
   unknown-entities map-reduce workers.
2. **`bin/build/result.sh`** fills the rest, preserving blue: a **subscription** goes green/red by
   its LAST File's outcome (red when Failed or Expired, green otherwise incl. Waiting; orange =
   never seen). **The after-last-transfer rule (2026-08)**: a would-be-green subscription flips
   RED when the server log holds an E-level line NEWER than that last transfer. The evidence is
   its own `_err_warn` ring plus every connected host/account/login ring LINE `_build_ringattr`
   attributes to THIS flow (`blue/_ringattr.tsv`): each of those entities serves other flows too,
   so a connected ring never counts wholesale. A line attributes by the UC token in its MESSAGE,
   else by its SESSION — voted from the parse cache's own lines, then joined against
   `_transfers.tsv` col 24 (the same connection id; col 6 is the leg's site, canonical since
   parse time; legs naming two sites resolve to neither). What attributes to NOTHING goes
   E-level-only to `blue/_ringorphan.tsv` (ring kind ⇥ name ⇥ stamp; a forward-address ring's
   residue lands on its endpoint) and `orphan_red` reds the ring's OWN entity — a credential
   failure, a PeSIT profile complaint naming only the account — unless it moved a file OK since
   (hosts count OUT-side files only) and never over an already-red row. The detail page's
   "ERRORS IN SERVER LOG AFTER LAST TRANSFER" banner still reads its 1-to-1 connected rings
   wholesale — it shows the log. **The trouble-after-success flip (2026-08-22)** adds the LOOSE
   join to the colour after all: `_build_kaputflip` (`blue/_kaputflip.tsv`) takes each flow's
   newest connected account/login/single-host-ring E line WHOLESALE (forward addresses included —
   the went-kaput join), classifies that one newest message with `flip-reason.awk` and drops the
   flow entirely when it reads as a DEPLOY defect (Route stopped / Receive File As not set —
   those stay green, on the Deploy errors report); the surviving stamp merges into the same
   after-last-transfer test, clean-poll keep included. So a Trouble-after-success flow arrives
   on the home "Failing subscriptions in Server log" table RED; the went-kaput page keeps only
   the deploy-classified and poll-cleared remainder. **The UC3 clean-poll
   exception (2026-08)**: a would-be-blue UC3 subscription whose
   newest successful poll line ("Applying the search pattern … for transfer site '…': N file(s) …",
   per-name server mention cache) is no older than its newest E-level mention flips **GREEN** — the
   poll verifiably works, there is simply nothing to fetch. The flipped names land in
   `data/<env>/blue/_greenpoll.tsv` (no-remote-files re-selects on green+blue; the blue evidence
   card is kept), showseen counts a no-data green as seen-with-blank-counts exactly like blue, and
   deploy-errors clears a UC3 subscription on a successful poll after its last route-stop message.
   Every other entity rolls up its connected subscriptions via the xref caches (all
   green → green, any red → red, else orange; a blue subscription counts like ORANGE in the rollup
   — server-log DISCOVERY must never change a health verdict; the clean-poll flip is deliberate —
   a VERIFIED working poll is a verdict, not mere discovery). EXCEPT `_white.tsv`: a whitelisted
   IP goes by the LAST real transfer whose remote host is that address, orange when none. It flips
   the SSH-logon entities orange → blue only when they have no real transfer data
   (`rollup`'s `hd` set), so **blue always means "never transferred"** and no blue row carries a
   Last transfer; `seen-in-server-log.sh` exempts those names (`xf`) from its stale-blue reset.

Blue counts as SEEN with blank counts (`showseen.sh`), so the coverage TSVs mark it seen; the
status tables show it as the **Server** column (Transfer = Seen − Server). On the Entities Summary
views and Entity Search a blue entity is a blank tinted row added at publish time from the base
result — `RESMAP_FILES` alone carries the tint (no separate overlay map). In the Transfer scope a
blue row retints orange and moves to Not seen / Warning. The per-row dimension reports, dashboards
charts and day pages count real `_files.tsv` rows only, so they don't count blue entities.
`data/<env>/blue/<type>/<name>.txt` holds the evidencing server-log line per blue entity
(`result.sh` writes one file per FINAL blue entity from `blue/_evidence.tsv`, each type dir
rebuilt from scratch); `details_lib.sh`'s `blue_box` reads it (existence = the signal) and opens
the detail page with the "Only seen in the server log" INTRO + a LOGCARD.
`data/<env>/seen-in-server-log.tsv` is a standalone audit intermediate, never appended to a cache.

## Report groups (full lists)

Transfer groups: **topview** · **entity-search** · **account-login-site** "Entities"
(subscription · logical · partner · account · login · remote-host · domain · application) · **time**
"Activity over Time" (activity · punctuality) · **volume-files** "Volume, Sizes & Files" (volume ·
files · top-transfers) · **failures** "Failures & Retries" (failure-rate leader ·
episodes · retries · failure-heatmap) · **flow-shape** "Patterns" (file-journey ·
file-in-file-out) · **protocol-security** (protocol · security-params · av-scan) ·
**performance-session** "Performance" (anomalies leader · duration · dwell-time; the
`duration-all` / `duration-minmax` / `duration-all-minmax` siblings share Duration's slot) ·
**cross** "Cross References".

Server groups: **srv-overview** (topview) · **srv-errors** (errors) · **srv-transfers**
"Transfers & Delivery" (pickups — the `transfers` merge went in 2026-08 with the JSON
Transfer-start/end lines its two components read) · **srv-connections** (connections · logons) ·
**srv-security** (ssh-security) · **srv-ops** "Operations & Capacity" (platform-health ·
capacity) · **srv-routing** "Routing & Polling" (remote-poll · transfer-site-missing) ·
**srv-missing** (missing-entities).

## PDA derivation (partners, domains, applications)

`bin/flow-manager.sh` is the SINGLE OWNER; downstream only joins coverage data on.

**BL** (2026-08-31, user request) is the group's FIFTH, LAST member — not PDA-derived: a BL
entity is a `subscriptions.json` `tags` entry starting with `BL`, the tag text kept VERBATIM
(`BL_FIN` stays `BL_FIN`). `xref/_subscriptions-bl.tsv` (subscription ⇥ tag, one row per BL tag
of the subscription) is the map; `base/_bl.tsv` the entity list; the composed pair caches ride
the SUBSCRIPTION spine (`_accounts-bl` … `_bl-white`, via xcompose). Attribution everywhere is
`bl_union(col 12)` — a File counts for every BL tag of its subscription; direction/result roll
up from the subscriptions like every derived member. Everywhere the group renders (Entities,
details section 2.85, coverage, cross references, ranking, search, acc-vs-prod, the home table —
retitled "Logical, Partners, Domains, Applications & BL") BL is added LAST; first-seen and
data-diff deliberately exclude it (their set is the six classic+Logical types).

**THE BASE IS THE LOGICAL ENTITY** (2026-08-30, user request — this replaced the account-NAME
derivation wholesale). The Logical derivation (FlowID families condensed to three-part group
names, `input/logical.txt` pins honoured) runs FIRST; the PDA pass consumes its map
(`xref/_profiles-logicals.tsv`). Before ANY splitting a FlowID is separator-normalized
(2026-08-31, user request): `-` folds to `_`, doubled separators collapse and edge separators
trim — a raw `-_` run or a trailing `-` otherwise split into an empty part and the reshape
joined it into a dangling-dash artifact; a `input/logical.txt` pin matches the raw spelling
first, then the folded one. An unpinned Logical name has exactly three `_`-parts `D_A_P`:

- **part 1 = the DOMAIN**, **part 2 = the APPLICATION**, **part 3 = the PARTNER token** —
  each first passed through its hand-curated FROM→TO replacement map
  (`input/logical_{domains,apps,partners}.txt`; exact match on the UPPERCASE part, the Logical
  name itself untouched; two partner tokens replaced to one value simply fold, no group needed).
- A pinned Logical with any other part count (the monitor's `INFRA-MONITOR-UC`) contributes
  NOTHING — no domain, no application, no partner.
- Directions: a logical is `in` when any of its FlowIDs carries a login, `out` when any carries
  a host; a domain/application/partner's direction is the union of its member logicals' sides
  (`""` when none has either — the schema allows it).

*Partner merge* (union-find over the part-3 tokens; each firing records an evidence edge for the
partner-group "why" pages):

1. **Same host** — two tokens' logical flows connect to the same configured host.
2. **Shared whitelist IP** — their logical flows whitelist the same IP.
3. **Whitelisted host IP** — one token's host resolves (via the forward-DNS map, or a raw-IP
   endpoint verbatim) to an IP another token's logical flows whitelist.
4. **Curated alias** — a pair in `input/partner-aliases.tsv` (`variant⇥CANONICAL`).

No fixpoint loop: no rule reads group state, and union-find keeps every merge transitive. The
group NAME is the sorted member tokens joined with `_` — unless the alias STAR names it: when
every member has a direct alias pair with ONE candidate token, that token wins, and a candidate
appearing on the RIGHT side of a pair outranks the rest (`WONKA` beats its variant `WNK`);
sorted order breaks remaining ties. Multi-member groups are recorded in
`xref/_partner-groups.tsv` (name/members/direction), `_partner-group-why.tsv`
(group/tokenA/tokenB/rule 1-4/evidence sentence) and `_partner-group-accounts.tsv`
(group/token/the accounts behind the token's logical flows) — the partner-groups pages render
them (`bin/analyses/publish-partner-groups.sh`).

*Composition*: every partner/app/domain pair cache is COMPOSED through the FlowID — the pass
emits `_profiles-{partners,apps,domains}` (FlowID → value) and `_logicals-{partners,apps,domains}`
plus the within-logical pairs (`_partners-apps`, `_partners-domains`, `_apps-domains`), and
`xcompose` joins the entity→profile pairs with those maps into
`_{accounts,subscriptions,logins,hosts}-{partners,apps,domains}` and `_{partners,apps,domains}-white`.
A multi-flow account can map to several partners/applications (the relay case) — the parse's
two-group abstain and the site-wide union attribution handle it exactly as before.

*Retired machinery* (2026-08-30): the three `pda_split` copies and every name rule, the
subscription-name fallback (`ptn_resolve`), the transitive `sjoin` pairs (exact by construction
now — everything joins through the FlowID) and the subscription-less-partner prune (vacuous:
every partner descends from a subscription's FlowID by construction). The single-token
"real organisation" lines in `input/partner-aliases.tsv` are tolerated but inert.

Applications and domains share ONE name space with the same machinery: base lists
`_apps.tsv`/`_domains.tsv`, the coverage TSVs `coverage/{partners,applications,domains}.tsv`
(`ensure_pda_tsvs` in `bin/analyses/lib.sh`) and the per-member coverage cell pages.
## bin/dashboards/ — the Overview

`reports.sh` writes the page-spec `overview.rpt` (KPI + CARD/CARDALT + TOP lines); `publish.sh`
(+ the SVG generators `charts_lib.sh`) renders `docs/<env>/dashboards/index.html`. **5 KPIs + ONE
hero graph + the six Top-5 tables** (2026-08: the day pages' "Busiest" block over the FULL period
— same TOP line protocol and rules, partner UNION included, rendered by publish_lib's shared
`top_table` under "Busiest this period"; the "See more" links carry `?axway_sort=` and, ONLY when
the dashboard is narrowed, the period — `daytopSetRange` rewrites them with `?axway_date=<day>` or
the RANGE form `?axway_date=from..to` (2026-08), which the target snaps to its own date list bound
by bound; at the full range the baked hrefs return and the Entities views open at their full-range
default). **The KPIs and the tables
follow the From/To range** like the slot charts: the rpt also carries one TOPDATA line per entity
(`kind⇥name⇥YYYYMMDD:files:vol:errs|…`) and one K line per day
(`K⇥YYYYMMDD⇥files⇥failed⇥vol⇥records⇥errors`), the publish embeds them as a raw-text
`#daytopdata` payload, and report.js `setupDaytop` (driven from the date filter's `apply()` via
`window.daytopSetRange`, beside the slotchart hook) RE-SELECTS the five per metric over the range
— never a re-sum of the baked rows, whose entities a narrowed window may not even rank — re-sums
the five KPI values from the K days (formats mirror `knum_files`/`knum_recs`/`humanbytes` and the
two `%.1f` rates; the KPI cards are matched by their baked LABEL), hides a card that empties (the
grid hole) and restores every baked value exactly at the full range. A dateless File is in the
full-period figures only. **The date controls LEAD the page** — under the centered H1
("Dashboard"; a narrowed range joins it as "Dashboard - <from> to <to>", a single day alone, the
full range plain) — before the KPI row — with the FULL report-page button set (All / Week /
4 weeks / Month / First day / Last day / Previous / Next day, the active preset in the group tab bars' active style; until 2026-08 a reduced
set lived in the hero card's `.chartbtns` row). **A span preset the estate cannot fill is
GRAYED** (2026-08, report.js `mkPresetBtn` cov functions): on a short estate Week / 4 weeks /
Month clamp their From to the first data day, collapsing into what All or First day already
select, so they could never show as the chosen range — they disable with a "data does not reach
back this far" tooltip, the Previous/Next-day affordance, whenever the window reaches past the
oldest data day (an exact fit stays enabled). The card titles carry no "per slot" / "up to each slot" tail — the slot semantics live in
the card subtitles. Twelve hero views, all
chart type `slots` at 6-hour slots: Duration (hero) /
Files processed / Volume / Error % Files / Transfer errors (raw `Failed` + `Failed Subtransmission`
legs from `_transfers.tsv`) / cumulative Subscriptions seen + Partners seen / the four
UC1–UC4 status stacks / PeSIT (LAST and conditional, so its omission never shifts button indices).
First CARD = hero; CARDALT lines render hidden `.althero` siblings; report.js `setupHeroToggle`
swaps positionally (button 0 "Duration" hardcoded in both publishes; rpt directive `HERO0`
overrides).

**The MONITOR dashboard** — `bin/dashboards/reports/monitor.sh` → `monitor.rpt` →
`docs/<env>/dashboards/monitor.html`: the CFT end-to-end monitor page (three `durfit`-axis
`dur` latency views keyed on `monitor_*.txt` files): Monitor CFT pickup, Monitor duration (UC1
inbound start → UC3 outbound start, joined on FILE NAME — the monitor subscriptions share no
CoreId), Monitor staging. A cycle with no end counts as max(1 h, the family's slowest matched
pair), unless younger than 1 h against the newest row (export cut mid-flight — skipped).
**`monitor.rpt`'s EXISTENCE is the "this env has a monitor" flag** (removed when no monitor rows):
it gates the page render (help slug `monitor`), the sitemap entry (keeps it reachable for
linkcheck) and the per-env `monitor:{…}` flags in topbar-data.js that make `buildTopbar` show the
top-bar Monitor link.

**The UC status stacks** are TOTAL-PRESERVING compositions: every slot is a full stack of that use
case's configured subscriptions, bottom-up in ascending severity. UC1/UC3/UC4 share KIND `ucst`
(7 states; UC1 emits a constant 0 for its missing state), UC2 has `ucst2` (5).
`bin/analyses/reports/uc<n>-status.sh` writes a per-hour sidecar
`data/<env>/server/reports/uc<n>-slots.tsv`; `overview.sh` only re-buckets. A status is a STATE: a
coarser slot takes the LAST hour inside it — never a sum/average — and an empty slot carries the
previous state forward. Regression test: the last sidecar row must equal the report's own `STAT`
figures exactly. Server-visibility comes from `res[]=="blue"`. Sidecar guards (same as pesit):
`[ -f "$SLOTS_OUT" ] || rm -f "$OUT"`; the sidecar goes with the `.rpt` on a no-data exit; a run
with data but no timestamped rows creates an EMPTY sidecar; create only when absent, never touch.

**The three cumulative `seen` views** (Subscriptions / Partners / Accounts): per slot, how many
were seen at or
before it — `v0` blue Transfer+server UNION / `v1` orange Transfer / split into `v2` green (latest
File OK) + `v3` red. Invariants at every slot/resolution: blue and orange only RISE; `v2+v3==v1`.
`bar`/`solid` stack red, green (topping out AT orange), then `blue − orange` (`seenTop()`). All
curves count CONFIGURED entities (2026-08; the amended-in synthetic `_UNKNOWN` names stay OUT of
the roster, mirroring First seen). A logged site value credits EVERY configured subscription that
prefixes it (`credits()`, 2026-08-22 — the showseen/first-seen rule, so a configured parent name
is seen through its child flows; the unique-match `canon()` alone missed four such parents and
broke the endpoint identities below), falling back to the unique reverse match for a truncated
value; partner attribution = col 20 ∪ subscription partners ∪ host partners; accounts match
exactly. Orange is transfer
evidence only; blue = orange + the CURATED server-only sets — the base-cache blues (+ the
`_greenpoll.tsv` clean-poll subscriptions), each entering at its first-seen-ledger day.
**Cross-checks after any change**: orange ends at `first-seen.rpt`'s DATED Seen (Seen minus the
no-date bucket; acceptance 2026-08-22: subscriptions 283, partners 97, accounts 221); blue ends
at `first-seen-both.rpt`'s SEEN minus its DATELESS entries (acceptance 2026-08-22: subscriptions
358, partners 106, accounts 260 — no dateless entries that day).
These six overview-only views are not on the day pages; their slot links carry
`?axway_hero=Files%20processed`.

**Slot charts are drawn CLIENT-SIDE** by `docs/assets/slotchart.js`; every other chart type
renders at publish time in `charts_lib.sh`. One placeholder per card (`div.slotchart`, each
`data-iv<m>` one resolution of `label:v1[:v2[:v3]]:date|…`). CARD args: a1 KIND, a2 base series,
a3 the `{}` link pattern, then `"<minutes>:<series>"` extras — a From/To change AUTO-picks the
interval from the span (1 day→1h, ≤3→2h, ≤7→4h, ≤15→6h, ≤30→12h, else 1 day; slotchart.js
`autoIv`, applied by the range hook and the load-time stash; a manual click overrides until the
next change) — overview row 1h/2h/4h/6h/12h/1d (base
360), day row 15/30/60 min (base 30). KIND picks series/colors/format/axis: `dur` (P50/P90/P98) /
`count` / `bytes` / `rate` / `pesit` / `seen` / `ucst` `ucst2` (`stack:1`). The interval +
Line/Bar/Solid rows (sessionStorage `axway-chart-interval[-<base>]` / `axway-chart-style`) are
owned by slotchart.js (the tooltip rebinds on every redraw). Hover targets carry `data-l`+`data-v`
and NO native `<title>`. The slot charts have NO no-JS fallback — without JS the placeholder div
stays empty (the `details.chart-data` tables live only on the publish-time charts_lib charts,
where `setupSearch` skips them). Overview slot columns link `../day/{}.html?axway_hero=<view
label>` — the
same labels as the day pages.

The four transfer series are aggregated from the RAW Files at each resolution — never re-bucketed
from a finer one (a median of medians is not a median). PeSIT sums
`data/<env>/server/reports/pesit-slots.tsv`. Only pages owning a slot chart load the asset
(`html_head`'s 9th arg, folded into `ASSET_VER`). NOTE: the publish reads KPI/CARD lines via `tr
'\t' '\037'` + `IFS=$'\037' read` — a TAB is IFS whitespace and a plain read would collapse empty
middle fields.

## bin/day/ — the per-day pages

One combined page per calendar day (`docs/<env>/day/<date>.html`, both logs). No From/To — the
page IS a date filter. Help slug `daily`. `bin/day/reports.sh` writes ONE `.rpt` per day: the
transfer pass creates the file (header, 3 KPIs, problems, hero + alternates, facts), the server
pass APPENDS (2 KPIs, problems, facts; it writes the header only on a day with no transfer data).
`publish.sh` renders KPI row → hero → the two problem lists → Remarkable facts → six Top-5 tables.

The six Top-5 tables: the day's five biggest partners and subscriptions by Files, Volume and
Errors (`TOP⇥kind⇥title⇥unit⇥href⇥name␟value…`, kind `P`/`S`). A metric with no non-zero entity
emits no table, so each card is PINNED to its grid column (`.dt-p`/`.dt-s`) — a hole, never a
shift. `top5()` is a bounded insert breaking ties on NAME. "See more" opens
`../transfer/entities/<entity>-all.html?axway_date=<d>&axway_sort=<c>:-1` (`?axway_date` beats the
Entities `datereset`). CSS `.daytop`: tracks `minmax(0,1fr)`; `.daytop td` sets
`white-space:normal` against the site-wide nowrap.

The hero = the shared slot views (same labels as the Overview) at 30-minute slots. Slot columns
carry no day link: an empty CARD a3 makes `render_card` fall back to the CARD's own href as
LINKPAT. `Files processed` is the one card that FILLS a3
(`../transfer/entities/subscription-all.html?axway_date=<d>`), so its plot and title point at
different pages — its subtitle says so. The PeSIT view reads `pesit-slots.tsv`, the sidecar
`bin/server/reports/pesit.sh` writes (a missing sidecar forces a pesit.sh rebuild; pesit.sh
removes it with pesit.rpt). `setupHeroToggle` stores the label in sessionStorage `axway-day-hero`,
SHARED with the Overview; `?axway_hero=` overrides and persists.

The problem lists are split per log, rows routed by `PROBLEM⇥transfer|server⇥href⇥headline⇥desc`.
Signals: one-legged/pirates + Waiting/Expired staged files from `_files.tsv`; the three
full-period subscription verdicts bucketed by state-change day (`daycount RPT FIELD`; their
reports are `nofilter` — links carry NO `?axway_date=`); the server No remote dir/files tables
(date-aware — links keep it); per-day `_parse.tsv` line counts for the message-family signals
(logon screening, outbound logon failures, connection failures, deploy route-abandons,
PeSIT ceiling, cluster distress, event-feed errors); UC3 "Failing polls"
= the uc3-status "server - error" rows bucketed by their newest `@data:loglines` failure date
(went-kaput-style; no q). Together the two lists cover every red/orange box of Subscriptions in
boxes that has dated log evidence (Missing cron, Went quiet and Not seen have none). Both Top views link Date cells to day pages via the cell attr
`@{href=URL}`; consumers of topview date cells strip it first (`sub(/^@\{[^}]*\}/,"",d)`:
publish_lib's `area_dates`, `bin/build/publish.sh`, `bin/dashboards/lib.sh`,
`bin/day/reports.sh`).

## Click-to-expand drill-down

`data-coreids` makes a row clickable; `data-coreids-failed`/`-processed` its Error/OK cell.
Clicking inserts a detail row listing that outcome's 10 most-recent transfers; detail rows are
excluded from `dataRows` and torn down before sort/filter/search. Lists are built by the shared
`COREIDS_AWK` helper (`addtop` bounded top-10 + `buildlist`/`orlist`). Every transfer report with
real Error/OK columns emits these (av-scan excepted). The Duration report's per-day table drills
every cell via `@data:drill-cell-<colindex>` (≤5 files nearest each statistic's rank; TAB-read
consumers need `orlist`'s `-` sentinel for empty fields). The server reports use `@data:loglines`
(a row's 10 most recent "date time Level Component message" lines, `LOGLINES_AWK`'s `addline` — a
bounded insert by "date time", NOT arrival order: the exports are newest-first within a file; in
pipe-delimited aggs the loglines field goes LAST so embedded `|` survives).

## The home page

`bin/build/publish.sh` writes the centered shared home (body class `home`): the two status tables
plus the per-day figures — ONE wide "Per day" table (2026-08-31, user request; the 2026-08
five-table `.sxs` flex row with its blanked Date spine is retired — it could fall out of
row-sync whenever a header's height changed, which the csv-hotspot did): a `gband` banner row
(Files · Duration · Red/Green switch · First seen) over a shared Date column whose cells link
the day dashboard; the group dividers are POSITIONAL CSS on `table.dayrows` (columns 2/8/12/14
+ the `gbrow` banner cells), so adding a column means moving them. The days are the transfer
`topview.rpt`'s only — all four data groups are transfer-derived, so a server-only day (the
server export running a day ahead of the transfer export) would render a fully empty row. The
table is `data-nosort` — **capped to the newest 14 days** (2026-08), the older rows and the
Total row carrying class `capx`, hidden while the table carries `cap14` (a sort would
interleave the class-hidden oldest rows), and the "Show all" button under the tablewrap (baked
only when there are more than 14 days) lifts the cap — report.js `setupShowAll` uncaps every
capped table inside the button's adjacent wrapper. The baked Total keeps the full-window figures, since
`recomputeTotals` counts inline display only; the First-seen counts join `first-seen.rpt` by date —
its summary lines stay out of the day rows, and each First-seen Total cell shows the report's
SEEN figure — equal to the status tables' Transfer-scope Seen by construction, the day cells
plus the report's no-date bucket summing to it — linking its `<type>-seen` list), plus the
log-exports facts table (`write_log_facts`:
per log the input-file count from the parse manifests `_parse.files`/`_transfers.files`, total
records, first/last record stamp and the HOLES — span days with no record — from the topviews;
Records = the log's own rows — the server topview's Records column, the transfer topview's
Transfers Count (`$10`, one per physical leg), never a Files or percentage column: until
2026-08-31 the transfer half read `$13`, the Transfers Error %, so a clean 0.0 % day counted as a
hole and an env with no failed transfer showed the Transfer row without Records/First/Last/Days).
Every status cell opens the **Transfer > Entities view whose row
count IS that figure**, in the scope the "including server log" switch is in (ON = the bare
`+Server` pages, OFF = `-transfer`); the Transfer column links `<e>-seen-transfer`, the Server
column `<e>-server`; the percentage columns link too; a 0 renders as an empty cell (inert). The
five Logical/PDA/BL **Total** cells link the coverage cell pages
`docs/<env>/coverage/<member>-configured.html` (written by `bin/analyses/reports/coverage.sh` +
`render_coverage_pages`, help slug `coverage`). `check_status_consistency` verifies every figure
against the tinted (`data-res`) row count of its target view. The "configured names actually SEEN"
figure comes from `bin/analyses/reports/home.sh` → `home.rpt` (nine `SEEN⇥member⇥count` lines;
the derived Logical/PDA members re-run their both-ways merge over `coverage/<member>.tsv`), consumed by
`_status_table` and `seen-in-server-log.sh` — why that report runs last.

## The Entities report pages

Nine entity reports — subscription, logical, partner, account, login, remote-host, domain,
application, bl (group `account-login-site`, label "Entities") — each rendered as TEN pages under
`docs/<env>/transfer/entities/` by `render_entity_report`: `<entity>-{all,ok,error,server}.html` +
`<entity>-{seen,not-seen,warning}[-transfer].html`.

ONE LAYOUT for every view — Name · Direction · Files · Volume · OK · Error · Last seen. ONE
exception (2026-08): the SUBSCRIPTIONS Error view appends a **Reason** column — the same per-flow
diagnosis the home red tables show, resolved by the same chain (newest red `failed-sub-all.rpt` row's
own verdict unless the flow is in `blue/_redflip.tsv`; else the classified `_kaput-evidence.tsv`
newest E line via the shared `bin/flip-reason.awk`; else `_subs-boxes.tsv`) — appended AFTER Last
seen so the baked column indices and every `?axway_sort=` link stay put. `_subs-boxes.tsv` is
written by the LATER analyses publish; the transfer publish stamp watches all three sources + the
classifier, and build.sh re-invokes the transfer publish right after the analyses publish (the
per-env "transfer catch-up (boxes reasons)" step, 2026-08) so a changed — or first-build — boxes
sidecar lands in the SAME build. The sidecar is cmp-guarded, so the catch-up skips in ~0 s when
nothing changed.
`inject_dir_col` adds Direction as the connection/movement pair (a SUBSCRIPTION reads
`_subscriptions-flowdir` alone — **pass that file ONCE**; a second copy makes every subscription
`out/?`). `entity_layout` reorders the figures and drops First seen; `entity_layout 1` keeps only
Name · Direction on Not seen, Server, and Warning-on-subscriptions (figures blank by
construction).

Nav = three tab groups: member · All/Seen/Not seen/OK/Warning/Error[/Server] · **Transfer |
+Server**. The SCOPE: does a server-log sighting count as seen? **+Server** is the default and the
site-wide model (bare filenames); **Transfer** pretends the server log was never read — blue tints
orange and moves into Not seen/Warning (`-transfer` suffix). Only Seen/Not seen/Warning are
scope-dependent; All/OK/Error are one page each (both scope tabs disabled); **Server** is a
seventh view of the blue names only. The `.rpt` keeps its two tables unchanged (rosters and
showseen read it); the variants are assembled at PUBLISH time: All = Summary rows + one zero-blank
row per configured-never-seen name (the DEFAULT page, `first_page`); OK/Warning/Error filter by
site-wide RESULT (`entity_res_block` — one definition, shared with tints and status columns). The
not-seen names come from showseen's `coverage/*.tsv`, so Entities and Show Seen can never
disagree. Every view carries `datereset`.

**SORT is SHARED across the nine entities with a 1-hour sliding expiry** — the one localStorage
in report.js (`entLoad`/`entSave`/`entTouch`/`entResolve`), stored by COLUMN LABEL, never index
(column 0 = the sentinel `#name`); a label the view lacks leaves the entry intact and that page
keeps its own default.

**`showseen.sh` is a DATA producer only** — its four `showseen-*.rpt` are unpublished
intermediates feeding the status figures; its `coverage/*.tsv` feed the entity not-seen rows. It
lifts figures straight from the entity summary `.rpt`s (subscriptions = prefix match, others exact
name match, case aside). Runs after `details.sh` (needs the slugmaps). No Logical/PDA members
(their Seen figures come from the coverage-TSV union path instead).

## Per-entity detail pages

`details.sh` → `data/<env>/transfer/reports/details/<sub>/<slug>.rpt` →
`docs/<env>/details/<sub>/…`, one page per entity of the nine types, counting Files; plus
`details/incoming_connections/` and `details/partner-groups/`. **Every name from `base/` (except
`_white.tsv`) gets a page, seen or not**, plus every logged entity.

The TITLE leads with `XXX/YYY:` (connection/movement, `?` when undecidable). Slug = plain name
slug; collisions bump to `<slug>-N` in stream order; `_slugmap.tsv` is COMPREHENSIVE and every
consumer resolves links through it. The `<body>` carries a tint class (the RESULT wins). **No
From/To, no search box, no RECALC/@data:buckets** (`CUR_DATES` stays empty; `setupSearch` skips
`/details/`).

Page order IS the section number: -1 direction · 0 header data · 0.9 Waiting/Expired summary ·
1 Activity per day · 2 subscription · 2.6/2.7 Incoming/Outgoing connections · 2.8 account ·
2.81–2.83 domain/application/partner · 3 login · 5 protocol · 6 av · 9 latest 100 Files ·
10 weekday · 11 hour · 13 direction · 14 action-by · 15 mode; then `close_file` appends the
Duration/Size perf tables, a Groups fact table (classic types only — a PDA page IS the group) and
"Last server log messages".

- On a direction=both page an outcome section splits into four columns (In/Out x Error/OK) only
  when its rows carry both directions. A never-seen page opens "Configured — never seen" and still
  shows its configured cross-references. **ACCOUNT pages with no referencing subscription carry a
  `WARN` banner** (annotation field 31 `nosub`) — computed BY VALUE (`P2N[…]+0==0`), not `in`: an
  earlier bare read instantiates keys.
- **Subscription pages open with their UCx status verdict** in prose (`subscription-verdict.awk`
  fragments, spliced after DESC by `publish-details.sh`); a UC2 page additionally gets the
  **"Pickup information" table** from `uc2-status.sh`'s `uc2-pickups.tsv` sidecar. The account's
  SSH logons group into VISITS (a gap > 30 min splits); a visit that only DELIVERED files (an
  Inbound ssh row — the UC4 twin flow) is NOT a pickup: its logons show on their own table row
  and are excluded from the pickup figures AND from the UC2 status pickup signal. The table:
  first/last pickup, total pickups, pickups with actual files (visits that collected a File of
  THIS subscription; one stamp per File — its newest Processed collect leg), files picked up
  (= the page's OK figure), the pickup pattern (cadence from the median pickup-logon gap; short
  visits read by their visit-start spacing, sustained pollers by the raw gap) and the
  delivery-only logons. The sidecar's cols 11-15 carry the account's VISIT classification
  (collected / collected+delivered / delivered-only / empty-handed), rendered by the **UC2
  pickup visits** analyses page (`bin/analyses/reports/uc2-visits.sh`, a `SUBS_GROUP_REPORTS`
  member in the Configuration group — it only formats the sidecar, so the three views cannot
  disagree; runs after the server pool, behind `uc2-status.sh`). **The "Connection shared with
  UC4 drop" row (and the UC4 pages' mirror INTRO, and the pickups report's UC4-drop flag) fires
  ONLY on sidecar col 18 — the SHARED-SESSION count**: distinct `_transfers.tsv` Session IDs
  (col 24, one id = one technical connection) in which the account both delivered (Inbound ssh)
  and collected (Outbound ssh, Processed leg of a Processed File). The time-window visit classes
  never fire it (2026-08): an SFTP client commonly opens a fresh connection per operation, so
  "delivered during the same visit" is NOT same-connection proof.
- **The Features "Use case" row on a NON-UC-NAMED subscription is DERIVED** (2026-08): the
  production hybrid flows carry no `UC<n>` prefix, so the use case is computed from the movement
  (`xref/_subscriptions-flowdir.tsv`) and the connecting side (the configured pattern's ONE
  partner verb: `PULL_PARTNER` / `PUSH_PARTNER`) — out+pull = UC2, out+push = UC1, in+push = UC4,
  in+pull = UC3 — labelled "(derived from the configured pattern and direction)". A pattern with
  both or neither partner verb (a relay, an unknown shape) gets no row — never a guess. The map
  is OWNED by `bin/flow-manager.sh` (`xref/_subscriptions-ucderived.tsv`); `details.sh` reads it
  (`uc_desc()` fallback), and **uc2-status.sh / uc4-status.sh count a derived flow like a
  prefix-named one**, which is what puts it in `uc2-pickups.tsv` and gives its detail page the
  "Pickup information" table. The uc2-status TABLE stays account-keyed, so an account owning
  MANY UC2 flows (production: one account, 350) carries one verdict row —
  `subscription-verdict.awk`'s END fallback writes the bare Pickup information table for every
  sidecar flow without a verdict of its own.
- **The "Last OK transfer" section** (2026-08, SITE pages, directly above "Last server log
  messages"): the flow's newest PROCESSED File — deliberately NOT the outcome policy's OK
  (2026-08): a UC2 file still Waiting is staged, not transferred, and showed 3 staging legs where
  the reader expects the complete 4-leg transfer with the partner's collect; an all-Waiting flow
  has no section — shown
  the errors/ drill-page way — the legs table (Status … Transfer ID) and the server-log lines of
  the legs' CONNECTIONS (the `_transfers.tsv` col 24 ↔ `_parse.tsv` col 6 session join; newest
  40 lines, chronological, E/W rows tinted). Computed by `details.sh` into the `$_pdir/lastok`
  sidecar (three passes: newest-Processed per site over `$FILES` → legs + sessions over `$PARSED` →
  the server-cache session scan, sorted/capped per site; the session→site map is MULTI-VALUED —
  one CFT push connection carried six flows' last-OK files, and a single-valued map starved
  five of them); `details_writer.awk`
  `last_ok_section()` renders it. A flow with no OK File emits nothing. The **"Last error"
  section** above it (`last_error_section`, 2026-08) is the newest failed File's error page
  errors/<coreid>.rpt spliced VERBATIM — its legs table and its server-log table, the file name
  in the heading, a LINK to the full page below; never a mere link row (the facts table stays
  out — the page already knows its subscription). The sidecar also carries
  the newest FAILED File's session lines (kind X, never rendered — the spliced error-page
  content shows the failure), and **"Last server log messages" SUPPRESSES every line already
  told on the page** — the S (rendered) and X session lines and both spliced server-log
  tables — keyed on the PRE-fold
  message field, since `emit_srv_table`'s tab-fold appends the trailing session column into the
  displayed text. A SERVER-FAILING subscription (in failed.sh's `_srvsubs-map.tsv` — the REDUCED
  name⇥slug⇥stamp map, cmp-guarded without the reason column so a reason-only rerun leaves it
  byte-identical and the details catch-up self-gates; went-kaput runs EARLY in the build so the
  stamps are final on failed.sh's first pass) additionally
  gets the **"Server log error"** section above Last error (`srv_log_error_section`): its
  `errors/<slug>.rpt` server-log table re-emitted VERBATIM with a LINK to the full error page,
  its lines joining the same suppression set.
- **The "Logons" table** (2026-08, LOGIN pages, `logons_section()`): first/last successful
  authentication, the raw logon count and the cadence label, from **`bin/logons.sh`**
  (`ensure_logons` → `data/<env>/server/cache/_logons.tsv`, atomic + cmp-guarded) — one
  `_parse.tsv` pass over the "User with login name … successfully authenticated" lines (any
  protocol daemon; the same signal uc2-status.sh counts pickups by), the cadence uc2-status's
  pickup-pattern logic verbatim (median gap over distinct logon minutes, bursts collapsed into
  visits) so the two tables speak one vocabulary — PLUS the seven [Ssh Default] screening-funnel
  counts (fields 6-12; logon.sh's matching replicated EXACTLY, qtok and all — a matcher change
  belongs in both) plus field 13, the ANONYMOUS-failure attribution ("Authentication failed
  using local.", no username: credited by timing to the login whose Allowed line it follows
  within one second — an Allowed consumed by its own SSH success does not compete, and two
  distinct candidates attribute to neither), rendered as rows below Pattern with zero rows
  omitted; a funnel-only row
  ("-" stamps, count 0, Never) is a login that was screened but never got in. TWO consumers,
  which the build runs
  CONCURRENTLY, so each ensures the file itself: the detail writer, and the server Logon
  report's Incoming table (the last four columns — full-period `k` tokens under RECALC; a
  count-0 sidecar row renders there like an absent one). The
  table sits in one `.sxs` flex row with Activity per day and Incoming connections
  (`login_sxs_row()` relocates the two blocks after the Activity table and tags all three
  `sxs=9`; a page WITHOUT an Activity table — blue and never-seen logins — anchors the row on
  Features instead; Outgoing connections, where present, stays put). HOST pages get the same
  table over the ADDRESS evidence (`host_logons_section()`, the `_logons-hosts.tsv` second file
  ensure_logons writes), BOTH directions: inbound per client address — the auth lines'
  "Remote address:" and the screening lines' "from address" — first/last/count/pattern +
  Allowed/Disallowed with last stamps; outbound (fields 10-15) per TARGET — the "had initiated
  a connection over …" lines per address and the "Authentication failure connecting to remote
  host" errors per lowercased hostname (one key space; the writer looks pages up by name AND
  forward-resolved addresses) — rendered as First connection / Pattern / Connections, the seven
  CONNECTION-ERROR class rows (sidecar fields 24-37, from the "Connection failure while … tried
  to connect to remote host" lines: Timeouts / SSH errors / Network errors / TLS handshake /
  Too many connections / SSH negotiation / Proxy errors; Network is the catch-all), plus Auth
  failures with the Password/Key/Certificate/Other class rows (red, zeros omitted; no "(out)"
  suffixes). The host blacklist keeps the cluster's addresses out, the login blacklist
  deliberately does NOT apply. A host page sums its addresses; each pattern is the busiest
  address's own. The table sits in one `.sxs` flex row with Features and Activity per day
  (`host_sxs_row()`, sxs=11 — assembled at the EARLIEST of the three blocks in canonical order
  Features | Activity | Logons, since the intro can emit Features after the section tables; a
  missing block just shortens the row). A login absent from the sidecar
  renders em-dash stamps, 0 and "Never" — never-seen pages included (`strip_page` keeps the
  table whole, and `page_srv_log`'s early return emits it first).
- **One-row dim folds** (2026-08, all detail types, `fold_single_dims()`): a Partner /
  Application / Domain breakdown holding exactly ONE row is removed and its name joins Features
  as a row (alink-wrapped, so it keeps the link and result tint; identified by the HEAD's first
  column, up to three folds per page; the sxs pair partner of a folded table renders alone).
  EVERY type titles its breakdown tables (2026-08): Subscriptions (section 2), Accounts (2.8),
  Domains (2.81), Applications (2.82), Partners (2.83) — `dim_table`'s title argument.
- **Twin rows** (Features table, annotation field 32, `twin_features_rows()`): ACCOUNT = the same
  name spelled with the other separator. SUBSCRIPTION = the same flow configured the opposite way
  — the UNION of rule A (the connected account — resolved through
  `xref/_subscriptions-accounts.tsv`, **never by name** — has a separator twin and both accounts
  have exactly ONE subscription; relays skipped), rule B (strip `UC<n>_`, fold `-` onto `_`,
  names equal, one side UC3/UC4 and the other UC1/UC2) and rule C (2026-08-30: the same LOGIN
  serves both a UC2 and a UC4 subscription — the join WAS the shared account; the FE credential
  is the partner's actual connection, so the pair holds across accounts — or the same ACCOUNT
  carries EXACTLY one UC1 and one UC3 and nothing else, the login-less outbound mirror keeping
  the account join — twins regardless of name, resolved through the
  xref (`_logins-subscriptions` / `_accounts-subscriptions`); catches rule B's naming-slip misses). Invariants after any change: the relation is
  SYMMETRIC and every rule B/C pair is in↔out by flowdir (a rule-A spelling pair can join two
  same-movement flows — the EQUENS UC3/UC4 pair does); an env without any qualifying pair must degrade
  to no rows. The cell is `@{alink=…}`, tinted by the TWIN's own result.
- A KPI Summary table (`nosearch`, not date-aware) renders before section 10 on seen pages.
- Section 9, the latest 100 Files: State = Delivered/Errored/Waiting/Expired (row tinted via
  `restint`+`@data:res`); Direction = the FILE MOVEMENT (col 12 via `FLOWMAP`); paged 10 at a
  time.
- Sections 2.6/2.7 (`whitelist_rows()`): 2.7 = configured endpoints ∪ observed outgoing hosts;
  2.6 = the AllowIP whitelist ∪ observed incoming sources (no Name column — an incoming address
  never resolves to a configured endpoint). Green = configured + traffic, red = unconfigured
  traffic, orange = configured unused (folded behind one summary row).
- `insert_config_rows` appends after each section's logged rows one zero-blanked linked row per
  configured-but-never-logged pair (`seenrows`; subscriptions match by prefix). The ONE_DIMS fold
  covers only account/login/mode; the PDA-trio pages' group dims always render as own tables,
  every row tinted by the item's RESULT. Every entity cell is tinted by its own RESULT
  (`RESMAP_FILES`, set around `render_details` only).
- "Last server log messages" (bottom of every page): the entity's 25 recent + 10 recent Error/Warn
  lines, plus on SEEN pages the Error/Warn of its 1-to-1 connected entities after its last
  transfer (ACCOUNT pages fold in their logins'/hosts' lines). Any Error/Warn after the last
  transfer opens a red ALERT banner. Only the five classic types have per-name caches.

report.js `hideEmptyTables()` (detail pages only) hides emptied sections; `setupSectionTabs()`
builds the sticky header (`div.detailhead`). The sticky-header CSS comment must never contain a
literal `*/`.

Structure: four stream producers in **`bin/transfer/details_lib.sh`** run CONCURRENTLY into temp
files one sort consumes (`whitelist_rows`' `|| true` is LOAD-BEARING under `set -e`); the stream
is traversed exactly twice (PASS A dims, PASS B the awk annotation pass); the writer
**`bin/transfer/details_writer.awk`** runs one awk per type in parallel, reproducing `sort -k1,1r
-k2,2r` exactly. Both are `skip_if_fresh` deps; `details.sh <TYPE>` reruns one type.

A resolved IP has no page of its own — links resolve to the hostname page; unresolved IPs keep an
IP-named page.

## The special pages

**File search** (2026-08, SIX pages at the env root): `file-search-<window>-<outcome>.html` for
windows `48-hours` (the newest 2 data days, anchored on the newest day in `_files.tsv`), `week`,
`2-weeks`, `3-weeks` (the 5 days, then a week each, before) and `month` (through data day 30; older files are on no page — the windows PARTITION, a file is on exactly one page), outcomes
`errors` (Failed/Expired) and `ok`. `bin/analyses/reports/file-search.sh` writes one `.rpt` per
page (rows = Name/Date/Subscription/State/Size/CoreId, newest first — the OK pages carry NO State
column, nearly every row would read Delivered; the 48-hours/week ERROR pages carry neither State
— a sub-7-day window cannot hold an Expired file, the sweep runs at ~11 days — nor Size, their
Subscription cell is PLAIN text, and every cell + the row itself (`@data:href`, the shared
rowlink class, a delegated click in file-search.js) opens the file's own error page where one
exists: `failed.sh` grants drill pages for the FAILED files of ALL File search windows (the
newest 30 data days — Failed only, never Expired: a pickup problem is the detail page's story)
since 2026-08, CAPPED at 10 pages per subscription (list pages included, newest failures first —
a busy flow's older rows stay unlinked) — drill-only entries beside its 250-row list); the
analyses publish renders each (an EMPTY table) and copies the per-page COMPACT data sidecar
`file-search-<key>-data.js` the report script writes itself (v2, 2026-08 — it used to lift the
rendered `<tr>` markup at 300-525 B/row; the dictionary-coded data runs ~95 B/row, 2.8-6x
smaller: `AXWAY_FSEARCH_D` the date dictionary, `_S` the subscription dictionary with the detail
slug from the subscriptions `_slugmap.tsv`, `_R` one File per line with dictionary indices — the
engine DOM-renders only the matches). **The BUDGET cap** (`AXWAY_FILE_SEARCH_BUDGET`, default
64 MiB per page — a backstop, not a routine trim): a page's rows stop at the newest WHOLE data
days that fit; the window figures
still count everything and the intro + SUMMARY state the searchable-from day — production-scale
volumes cap instead of shipping tens of MB.
The pages are searched by the DEDICATED hand-authored `docs/assets/file-search.js` (injected with
its own cksum `?v=`), NOT report.js's esearch: search runs only on the Search button (or Enter),
matches on the Name cell (case-insensitive; `*`/`?` globs, space-separated words AND), shows the
newest 500, and carries the query as `?q=` — synced onto the page URL and rewritten onto the NAV
row's five sibling links, so switching windows re-runs the search and a reload repeats it. The
table is `nosort nosearch nofilter` so report.js keeps its hands off. The Analyses menu, index
card, sitemap and finder link the leader (`file-search-48-hours-errors.html`); the other five are
reachable through the NAV row. linkcheck maps each `*-data.js` to its page by name and checks the
row links inside it.

- **Entity Search** — `docs/<env>/search.html`. Columns: Name · Direction · Type · Error · OK ·
  Last seen (Direction = the same `XXX/YYY` pair that titles the detail page; a row with no page
  of its own inherits the pair/counts/tint of the page it links to; Last seen = the newest
  `_files.tsv` entry attributed to the entity as `ccyy-mm-dd hh:mm:ss`, the site's union
  attribution for Partner/Application, the host column for Whitelist/IP rows, the subscription's
  stamp for Source/Target — a multi-subscription path shows the newest and its subrows payload
  carries each member's own). **Rows ship as DATA**:
  `split_search_rows` lifts every rendered `<tr>` into `docs/<env>/search-data.js` (loaded BEFORE
  report.js) and leaves an empty `data-start-empty` table; `esBuild` inserts only matching rows.
  Two rebuild invariants: the header and TOTAL rows keep their ORIGINAL DOM nodes, and
  non-matching rows are counted into `data-es-omitted` so `recomputeTotals` sees the table as
  filtered. `esearch` renders the controls open: entity-type checkbox buttons (all OFF =
  everything; the `TYPES` array is the button order, the filter map is keyed by NAME) + the search
  input. The search matches the NAME column only; no views, no drills, no date filter; rows tinted
  by RESULT. Also lists every whitelisted IP (type "Whitelist", linking the allowing account).
  **Adding a column means shifting report.js** — the Type cell is read by INDEX (`cells[2]`) in
  several places.
- **Report finder** — `docs/<env>/report-finder.html` (`write_report_finder`): the report catalog
  searched client-side; TITLE matches rank above intro-only matches; rows carry KEYWORDS
  (`rpt_keywords`: `KEYWORDS` + every TABLE heading and HEAD column name) via `data-k`.
- **Failed Subscriptions** — `bin/transfer/reports/failed.sh`, leader of the Analyses ERRORS
  group since 2026-08 (`SUBS_GROUP_REPORTS` `transfer:failed` — data in
  `data/<env>/transfer/reports/`, pages in `docs/<env>/analyses/`; the group's second member is
  **Error reasons** — `bin/analyses/reports/failing-reasons.sh`, basename `failing-reasons`
  because `error-reasons` is a SERVER merged component: every possible Reason with the count of
  currently red subscriptions and the newest occurrence, blank rows kept, nonzero rows opening
  `failing-reasons-<slug>.html` drill lists whose rows are the failed.rpt rows minus the Reason
  column; a single-member `_analyses_groups` group renders no member tab row —
  `analyses_group_tabs_ctx` suppresses those): FOUR pages over the Failed `_files.tsv` rows (Expired has its own
  report), two button groups picking the view — the SELECTION (All = every failed File /
  Subscription = each subscription's newest; the Subscription-leg views were REMOVED 2026-08,
  though the (Subscription, Legs) pair rule still grants the drill pages and the pair-borrow
  reason) and the FILTER (All / Still failing = hide the subscriptions green
  again). Default (Subscription × Still failing) = `analyses/failed.html`; the five variants are
  `failed-<sel>-<fil>.html`, rendered by a dedicated block in `bin/analyses/publish.sh` (same
  group row, help slug and persistence key), reachable only through the selector row —
  `p.tabs.undertabs`, injected before the first tablewrap; report.js hoists its From/To anchor
  back over it so the buttons sit BELOW the date fields. PLUS the SERVER-FAILING rows: every red
  subscription with NO failed File (server-log-reddened) gets one row per list — `@data:srv=1` (the
  marker the failed-sub-all.rpt consumers skip; the CoreId/Legs columns are gone since 2026-08,
  the visible columns being Subscription / Date/time / Reason, a file row's CoreId page living
  only in its `@data:href`), Date/time = the redflip/kaput evidence stamp,
  Reason = the classified kaput E line else its box — so the six pages cover ALL failing
  subscriptions, transfer and server alike. Each server-failing subscription ALSO gets its own
  drill page `errors/<slug>.html`, NAMED BY THE SUBSCRIPTION (lowercased, non-alnum → `-`; a
  separator-twin collision suffixes; a slug never collides with a UUID CoreId page): the facts +
  the flow's server-log mention ring, written BEFORE the evidence-sidecar pass so its E/W lines
  join `_errpage-evidence.tsv`; the row opens it like a file row opens its CoreId page. Paged
  file rows link `docs/<env>/errors/<coreid>.html` — a second `.rpt` per paged file under
  `data/<env>/transfer/reports/errors/`, listing every leg of that CoreId.
- **CFT to ST delay** — REMOVED 2026-08-29 on request (the `cft-delay.sh` report, its menu
  entry, single-member group, index/sitemap/finder cards and help page). Three page
  mechanisms it introduced stay available to every report: `topsel=` (per-day top-N
  candidate rows baked, report.js `recalcTopsel` re-picks the visible N for the range),
  `period=` (the aggregated-period span on the `<h2>`, kept on the selected range), and
  **DATE-AWARE STAT cards** — a STAT line's cells 4+ may carry `@data:NAME=VALUE`
  (render_rpt.awk emits them as `data-NAME` on the box; the first PLAIN cell >=4 stays the
  historical `data-pf` filter key) — report.js `recalcStats` recomputes a `data-tok` box
  from its `data-sb` per-day payload on every range change (`sum` · `share` · `maxdur`
  exact; `p50`/`p90` nearest-rank over per-day histograms QUANTIZED TO THE humandur
  DISPLAY GRID, so the shown figure equals the exact one), retints via `data-thr`
  (`le:A:B`/`ge:A:B`), and restores the baked value and class at the full range.
- **Cross References** — `cross-reference.sh` → 72 pages in `docs/<env>/analyses/xref/`: every
  pair of the nine entities both ways, existence only (no counts/drills/date filter); rows =
  seen-together pairs + configured-never-seen (`@data:seen`); table `group`; each cell tinted by
  its own entity's RESULT; two full entity NAV rows (row 1 first entity, row 2 second).
- **Seen in server log** — `transfer/seen-in-server-log.html` (+ `transfer/seenlog/` breakdowns),
  the audit page of the blue-marking step: the two result-status rollups (side by side, `sxs`)
  annotated with the `(+n)`/`(-n)` blue deltas; a "What happened" message-shape table; then each
  blue entity as TWO physical rows — a full-width message row (a `@data:loglines` drill) above its
  data row, kept paired through sorts by `bindPairs`/`repositionPairs`; `nosearch`, no date
  filter.
- **Entity coverage** — `transfer/entity-coverage[-once|-ok|-diff]-{accounts,partners,domains,applications}.html`
  (4 rules x 4 entities): is each configured DIRECTION working? The RULE rides on the BASENAME
  (shared help slug and group slot); its NAV is emitted INSIDE each table block (per-entity —
  switching rule keeps the entity) and hoisted onto the table-tab row (`@sep`) — the only report
  emitting a NAV inside a table block. Rules: **Current** (default, owns the unsuffixed basename)
  = the most recent File that way OK, or a logon/poll proof; **Once** = any File, or a proof;
  **OK transfers** = the most recent File itself OK — no server-log proof; **Difference between
  Current & Once** = the regressions list (worked once, not currently). Proofs (communication
  rules only): In = successful SSH logons (auth-activity.rpt), Out = successful UC3 remote polls
  (remote-poll.rpt). Assert after a change, on all four views: **OK ⊆ Current ⊆ Once**. Accounts
  is the default entity. Two row colours only (green covered / red not); a side with 0 configured
  subscriptions is trivially covered. The STAT boxes sit AFTER each TABLE line (`segment_rpt`
  files them per tab). No date filter.
- **The INSIGHT pages** (`bin/analyses/publish-insights.sh`, each with a same-slug help page):
  `whitelist-audit` (whitelisted IPs vs observed sources; `_white.tsv` is the EXPANDED list) and
  `config-hygiene` (case/separator twins + orphaned config objects; includes the "one name, two
  roles" double sections, `emit_double_sections`; orphans first, twins last). It also writes the
  two Boxes pages. Every page degrades gracefully when a source is missing.
- **Cronjobs** (`cronjobs.html`, hand-written in the analyses publish): configured cron schedules
  vs the OBSERVED firing — Matches/Drifts/Polls-no-files/Never fires. Observation reads the server
  log first via `data/<env>/server/reports/poll-times.tsv` (the sidecar `remote-poll.sh` writes —
  an empty poll leaves no transfer record), marked `· polls`, falling back to punctuality's
  arrival slot `· files`; name matching exact-first then prefix BOTH ways (the server truncates
  long site names); a missing sidecar forces a remote-poll rebuild. `bin/cron2human.awk` renders
  cron expressions as prose.
- **`publish-accvsprod.sh`** writes the per-type acceptance-vs-production pages +
  `acc-vs-prod-summary.html`. Deliberately not in `_analyses_groups` — it keeps its own type/view
  rows directly under the `<h1>`. (The **FlowID** type — the raw
  `customAttribute_FlowIdentifier` value sets — was REMOVED 2026-08-30, user request: Logical,
  its condensed successor, covers the by-flow comparison and no raw profile value surfaces
  anywhere.) ALL types render NAME-ONLY since 2026-08-30 (user choice):
  no Files columns, no result tints — cells still link the detail pages (Whitelist
  has none); the entity-report activity feeds only the Summary's dormancy split. The **Logical**
  type (2026-08-30; a FULL entity since 2026-08-31) condenses the FlowIDs into logical flow
  groups — the derivation lives in `bin/flow-manager.sh` (which writes `base/_logicals.tsv` +
  the `_profiles-logicals` FlowID → Logical map): pass 1 GROUPS (shared 4-part prefixes;
  digit-tailed or numeric-only parts whose removal collides), passes 2–3 NORMALIZE every name to
  three `_`-parts, joining combined parts with `-` — which is why Logical names render UNFOLDED
  site-wide. These pages read the cache like every base and link `details/logicals/`.
- **UC status** — the four `uc<n>-status` reports merged into ONE tabbed report `uc-status`
  (server-area `.rpt`s; its `SUBS_GROUP_REPORTS` entry `server:uc-status` — the full value is
  `" server:uc-status server:uc2-visits transfer:account-sharing transfer:twins "` — routes its PAGES to
  `docs/<env>/analyses/uc-status-uc<n>.html`, rendered by the analyses publish). Presented as a
  **Use-cases VIEW**: the 4th button of the Use Case traffic/definitions/patterns/status row
  (Configuration group).

## The Boxes pages

Two hand-written analyses pages sharing ONE producer — `_subs_box_rows` (publish-insights) emits
the `<box>⇥<subscription>` memberships both start from, so they cannot drift about what a box
means.

**Subscriptions in boxes**: every configured subscription boxed by what is true of it — twenty
boxes over one row each (the first box counts the whole estate). Sources: (a) a report's own
`.rpt` (from-green-to-red, went-kaput, only-red, no-remote-dir/-files, uc3-status "failing polls",
missing-cronjobs, went-quiet, site-failures); (b) derived from `_files.tsv` (One-legged, Waiting,
Expired); (c) no report at all, read from the same sources as the Entities views: not seen
(`coverage/subscriptions.tsv` col 3 = 0), seen (col 3 ≠ 0 minus blue — the TRANSFER-scope reading,
so **Seen + Server + Not seen = Total**, the invariant to re-assert), server (base result blue),
ok (green), error (red). Login errors in/out come from logon.rpt via the `_logins-subscriptions` /
`_hosts-subscriptions` xrefs. **connection** (site-failures) applies the one-legged UNRESOLVED
rule — cleared only by an OK File LATER than the failure instant taken from the row's
`@data:loglines` payload (entry 1 = newest; fallback: end of the Last-seen day). A flagged cell
names its report in red and links it with `?axway_search=<name>`; box links live in the notes
above the table, never in the column headers.

**Accounts in boxes** (the group's FIRST member and default): an account is in a box when one of
its connected subscriptions is. The join is `xref/_subscriptions-accounts.tsv` and ONLY that —
**never match subscriptions to accounts by name** (separator twins are different entities).
Flagged cells open the subscription report searched for the subscriptions behind the flag, joined
with ` or ` (`%20or%20`). One account-only box: **no subs** — the account in no xref row at all.
The table carries `data-pf-noun="account"`.

Shared mechanics: boxes filter via `data-pf` — each ROW carries its box list, each flag column's
`<th>` its own token; that `th[data-pf]` IS the flag→column map `setupStatFilter` needs to hide
columns and re-count the total (it writes the total row itself — the generic `recomputeTotals`
would try to sum box-name cells). A filtered view drops the active box's column and every column
with no hit among visible rows (the same rule runs on load); hiding is one generated
`:nth-child()` rule; `colOf` is 1-based, `cells[]` 0-based. `.pftable` renders at 90% with the
name column fixed `width:31rem` (see the style.css comment); the boxes get `.pfboxes .stat`
(`box-sizing:border-box; width:10.5rem`). **Count the `%s` in the ROW printf when adding a
column** — awk silently drops a surplus argument, costing one column its cell on every row.
