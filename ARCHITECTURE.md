# ARCHITECTURE.md — deep subsystem notes

Companion to `CLAUDE.md`, which holds the always-needed rules. This file holds the detailed
mechanics of the individual subsystems and page families. **Read the relevant section here before
changing that subsystem**; it is not auto-loaded, so nothing in it can be assumed known.

## Parse reference

Source CSV field indices (transfer log): `1`=Status, `2`=Account, `3`=Login, `6`=Application (raw, cache col 25), `7`=Transfer Site,
`8`=Direction, `9`=Action By, `12`=Transfer Profile, `15`=Local Filename, `17`=ICAP Details,
`19`=Size, `20`=Protocol, `22`=Mode, `23`=Start Time, `24`=End Time, `25`=Duration, `26`=Remote Host,
`29`=Transfer ID, `30`=Session ID (the technical connection — one SSH/PESIT connection = one id),
`34`=CoreId, `35`=Resubmitted, `38`=SecurityParameters. Server logs: `1`=Time,
`2`=Level, `3`=Component, `5`=Message, `18`=Session ID (`_parse.tsv` col 6). Timestamps are `MM/DD/YYYY HH:MM:SS.mmm`.

## Merged report lists

**Merged reports** (`bin/merge_rpt.sh`, run after the report pools) fold component `.rpt`s into
one tabbed report; the components stay on disk as unpublished intermediates and every other
consumer keeps reading them. Transfer: `activity` (weekly+hourly+weekday — `day` left
2026-09-29, the Top view carries the per-day table with a Volume group), `retries`
(retry+attempts+resubmissions+recovered-files), `file-journey` (patterns+legs-count+protocol-journey — arrived-left, the In and out tab, and
protocol-journey's Last leg table went 2026-09-29, user request),
`file-in-file-out` (file-in-file-out-src+uc4-to-uc2), `files` (size-dist+file-type+duplicate-files+top-transfers+size-profile),
`episodes` (recovered alone — "Recovered flows"; the Episodes tab, episodes-src, went 2026-09-29),
`went-quiet` (went-quiet-src+stale-accounts), `duration-dwell` (the `trends` and `punctuality`
merges went 2026-09-29 with their pages — user request; punctuality-src stays, pageless, for
the Polling file-arrival slot). Server: `errors`
(error-reasons+error-timing+top-messages), `connections`, `logons`, `ssh-security`; the server
Top view takes errors-day's levels-per-component table through `append_rpt_tables` (2026-09-29).
Analyses: `uc-status` (uc1-status · uc2-status+uc2-visits+pickups on the UC2 tab · uc3-status+uc3-polling+no-remote-dir+no-remote-files
on the UC3 tab · uc4-status). (`platform-health` and `capacity` went with the Operations & Capacity
group, 2026-09-27; `transfers` 2026-09-29. `missing-entities` — the five unknown-* tables, one tab each — went the
morning of 2026-09-29 and came back the same day, user request, in the Coverage group; its
value column carries the ENTITY kind, so each drill row shows a ↗ detail-page icon beside a name
that has a detail page.) Pageless producers read by
another page: from-green-to-red + only-red (Failed Subscriptions' Last green day / Days red /
Failures in a row columns and the Boxes), missing-cronjobs (the Boxes; Polling shows Schedule
"no cron"), deploy-errors (the Boxes Deploy column; Routing errors lists the lines), fe-overview
(Partners - Incoming). month-stats.sh also writes `_alltime.tsv` (the Subscriptions page).
`report_tabs` names one tab per component table (tables sharing a `tab=KEY` modifier are ONE tab);
`_merge_pad` pads a missing component with empty stubs so the tab count always matches. **The
2026-09-28 fewer-server-reports round** (user request: "there are too many, are there
duplicates?") cut the server tabs that repeated another page number for number: Errors lost Per day
(= the Top view) and By hour / By weekday (the heatmap marginals — the heatmap now carries per-hour
Errors / Warnings / Total columns, re-summed by report.js `recalcHeat` from the row's
`data-buckets`, and a row click expands the hour's lines); Reasons leads and carries Per flow's
former "Reasons over time" table (`tab=reasons`); Logons lost the whole ssh-key-auth component
(Key mismatches = Incoming Bad key, Lockouts folded into Incoming Locked — which had missed the
"locked due to too many failed login" line — Outbound key failures = a subset of Outgoing);
Connections lost Whitelist usage (= Incoming Allowed + Re-screens per policy) and Test outcomes
(empty by construction: the NOISE filter drops "Error during test connection"). Components are listed with the other pageless producers in `PAGELESS_REPORTS`
(`is_pageless_report`; whats-new skips them); merged basenames reuse one component's help slug.

**The former BOXES-ONLY reports** (2026-07..09-29, `BOXES_ONLY_REPORTS`, reached only from the
Boxes pages — gone themselves since 2026-09-29): pirates · waiting · expired · went-quiet (transfer) and went-kaput (server) are
ordinary members of their report groups since the one Reports pulldown (Failures — Errors since
2026-09-29 — and Use cases & delivery; went-kaput lost its page 2026-09-29, user request, a
pageless producer now); from-green-to-red, only-red, missing-cronjobs, deploy-errors and
no-remote-dir/-files lost their pages 2026-09-29 (pageless producers, see above). (site-failures
left 2026-09-28: its page was the Per flow "Connection failure" rows, row for row — the script
stays as a pageless data producer in `PAGELESS_REPORTS`, the Boxes connection column reads
its .rpt, and every link to it points at `server/failure-flows.html` now.)

## The attribution chain (parse time, in this order)

0. **Rename fold** — the logged subscription and profile names folded to the names the config
   uses NOW (`input/renames/`, `bin/renames.sh`); fully specified in CLAUDE.md, step 0.
1. **Blacklist — `input/blacklist.txt`** (TSV `<field>⇥drop|keep⇥<value>`: `drop`
   blanks on exact match, `keep` = a regex every kept value must match), read through the sourced
   **`bin/blacklist.sh`** (`BLACKLIST_FILE` + `BLACKLIST_AWK`) by transfer `parse.sh` (the
   authoritative blanking), server `unknown-entities.sh`, and the logon matchers `logon.sh` +
   `bin/logons.sh` (the pseudo-logins stay out of Incoming and the logon summary); the manual
   `flow-manager-synth.sh` reads the drop values itself.
   COMMITTED in develop (the whole `input/` tree is, CSVs included; a runtime repo keeps its own).
   Blanked (row kept): account
   `SECURETRANSPORT`; any filled site NOT starting with `UC` (catches the `Clone - …` artifacts) —
   unless it names a configured subscription (`base/.configured.tsv`: the configuration outranks
   the keep rule, 2026-08-31 — the hybrid production flows carry no UC prefix);
   logins `SECURETRANSPORT`/`P14303_CFT01`/`*nobody`/`UNKNOWN`; the internal cluster hosts
   (`localhost`/`145.219.156.40`/`.20`/`.21`, applied AFTER the endpoint-map fill). Login
   `@`-fallback: a blanked login falls back to the part after `@` in its account
   (`ACME@FE000593` → `FE000593`) — unless that value is itself blacklisted: the blacklist
   outranks the fallback (2026-08-15; an `X@P14303_CFT01`-style account would otherwise
   resurrect the very login just blanked).
2. **CoreId-group propagation**: each still-blank entity value (account, login, site, remote_host;
   profile's blank is `UNKNOWN`) is filled from the first row in the same CoreId group that
   carries one. Only blanks are filled. The unpropagated stream is kept as `_transfers0.tsv` (the
   input of the derive-only re-run); `_transfers.tsv` is derived from it each run.
   **Re-keyed legs** (2026-09-29) are moved back BEFORE this pass: a download whose session lost
   its cycleId is ended twice by ST (error under the File's CoreId, ok under a fresh one, same
   `transferId`), and when the ok end wins the transfer log books the pickup as a lone siteless
   leg under the fresh CoreId. `bin/session-sites.sh` writes `cache/_rekeys.tsv` from the JSON
   bookends (lone legs only; exactly two CoreIds per transfer id; the start line under the
   original) and the prop pass applies it through `K D` (drop the row) / `K G` (the original
   group rebuilt, pre-sorted outside awk) records of the fallback map, recomputing that group's
   aggregates (`agg()`/`regroup()`). Guards: the original CoreId is in the raw cache and holds
   no row of that transfer id; no CoreId is both source and target.
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
   currently-Unknown rows (UCx until 2026-09-29) are (re)scanned, tokens are rename-folded (`rn_canon`) and must be
   configured subscription names, and a session naming two flows maps to NEITHER. When the map
   holds a verdict, the script re-runs the transfer parse DERIVE-ONLY (`AXWAY_DERIVE_ONLY=1`,
   the raw cache reused). The derive's pass (between FLOWDIR and
   the fake name; the `Z` records of the fallback map) adds two more refusals: the group's mapped
   sessions must be UNANIMOUS, and the flow must be one the group's ACCOUNT is configured for
   when that account has a configured list at all. Acceptance validation: 12 UCx sessions
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
   When even that fails, a group WITH an account keeps the site **`Unknown`** (since 2026-09-29,
   user request — no subscription at all: kept out of every subscription table and listed by
   the Unknown transfers report; CLAUDE.md "The Unknown subscription"). UNTIL 2026-09-29 it was
   the SYNTHETIC site **`UCx_<account>`**
   (the account is already `@…`-stripped; `UCx` = the UC naming shape with an unknowable UC
   number — every UC extractor is digit-anchored, so it classifies to no use case): the
   transfers count everywhere a site is counted, and
   the name behaves like any logged-but-unconfigured subscription — `result.sh discover_logged`
   appends it to `base/_subscriptions.tsv` (empty direction), so the coverage/home/Entities
   figures stay consistent, it gets a detail page + slugmap entry via details.sh, and it lists
   on not-in-flow-manager — EXCEPT that **first-seen.sh drops `UCx_` names** at both its base
   and coverage intake (nothing was configured, so no first sighting can be dated). `uc_meta`
   returns empties for it.
6. **NO-SUBSCRIPTION / HTTP / PROBE SKIP**: a CoreId with neither site nor ACCOUNT anywhere after
   all passes — or an http leg on any row (web-UI hand traffic), or (2026-09-08) the EMPTY
   OUTBOUND SSH PROBE, one record Outbound + ssh + size 0 + Application "none"/empty (col 25) — is
   dropped from `_transfers.tsv`/`_files.tsv` (the Skipped report names each reason); its raw
   CSV lines go verbatim to `data/transfer/_skipped.csv`, recomputed each derive (a later
   export adding a subscription leg brings the CoreId back). Distinct from the **`input/skip.txt`
   SKIP LIST**: same layout as the blacklist but a matched rule DROPS THE WHOLE RECORD (field
   `account|login|site|message|any`; rule `contains` default case-insensitive | `exact` | `regex`;
   no TAB = `any contains <line>`; matched formatted cache rows go to `_skipped.tsv`).
   **`bin/skiplist.sh`** is the ONE reader (`SKIPLIST_FILE` + `SKIPLIST_AWK`
   `sl_load`/`sl_match`/`sl_hit`, plus `skip_values FIELD`); its five consumers: transfer
   `parse.sh`, server `parse.sh` (via `message`/`any`), `bin/flow-manager.sh` (jq),
   `bin/analyses/reports/skipped.sh` (`sl_match` names WHICH rule), `publish_lib.sh`'s
   `skipped_tokens`.

## Result colours (green / red / orange) — full detail

**No blue** (2026-09-27, user request): the fourth colour — "seen in the server log only, never
transferred" — and its step `bin/build/seen-in-server-log.sh` are gone, with every consumer. A
server-log mention alone never makes an entity seen or coloured; the server-log SIGHTING LISTS
(`data/unknown/*.tsv`, the unknown-entities map-reduce) are read colour-free (Entity Search /
Cross reference: an unconfigured sighting is red). `data/blue/`
is `data/colour/`; `result.sh` drops the old directory.

**`bin/build/result.sh`** fills the base result column: a **subscription** goes green/red by
   its LAST File's outcome (red when Failed; ORANGE when Expired — a pickup problem, still a
   candidate for the after-last-transfer rule below; green otherwise incl. Waiting; orange =
   never seen in the transfer log). **The after-last-transfer rule (2026-08)**: a would-be-green subscription flips
   RED when the server log holds an E-level line NEWER than that last transfer — newer than its
   END since 2026-09-12 (user rule): the cut is the last File's start raised to the newest OK
   File's END (`_files.tsv` col 24, the latest leg end), because a File that started before the
   error but FINISHED OK after it — a retry burst whose late leg delivered — is a transfer that
   ended OK after the error (production `UC1_CD_IDM_ROTAFORM`: an Error at 09:19, three Files
   started the day before delivered at 15:16); the same cut in went-kaput, `orphan_red`'s
   recovered-since test and the detail pages' banner — never a line on
   a TRANSFER-ENDED session (2026-09-12, user rule): a session that also logged the platform's own
   `{"message":"Transfer end logged."` bookend, any status, is not a server-log error, applied ONCE
   in `bin/server/parse.sh` by keeping such lines out of every `_err_warn` ring
   (`data/server/cache/_sessions-ended.tsv`, the shared PERSISTENT-SESSION pseudo-session never
   listed), so the banner, the red flip, went-kaput and the server-failing set agree. The evidence is
   its own `_err_warn` ring plus every connected host/account/login ring LINE `_build_ringattr`
   attributes to THIS flow (`colour/_ringattr.tsv`): each of those entities serves other flows too,
   so a connected ring never counts wholesale. A line attributes by a CONFIGURED NAME in its
   MESSAGE (every name-shaped token, tail-stripped and rename-folded, roster-checked — not only
   a UC-prefixed token, since 2026-08-31: the hybrid production flows carry no UC prefix),
   else by its SESSION — voted from the parse cache's own lines, then joined against
   `_transfers.tsv` col 24 (the same connection id; col 6 is the leg's site, canonical since
   parse time; legs naming two sites resolve to neither). What attributes to NOTHING goes
   E-level-only to `colour/_ringorphan.tsv` (ring kind ⇥ name ⇥ stamp; a forward-address ring's
   residue lands on its endpoint) and `orphan_red` reds the ring's OWN entity — a credential
   failure, a PeSIT profile complaint naming only the account — unless it moved a file OK since
   (hosts count OUT-side files only) and never over an already-red row. The detail page's
   "ERRORS IN SERVER LOG AFTER LAST TRANSFER" banner still reads its 1-to-1 connected rings
   wholesale — 1-to-1 BOTH WAYS since 2026-08-31: the connected entity must serve this flow alone
   (`details.sh` checks the reverse `P2N` count), or one line in a hybrid account's ring landed
   on all eight of its subscription pages with a red ALERT each — it shows the log. **The
   trouble-after-success flip (2026-08-22)** adds the LOOSE
   join to the colour after all: `_build_kaputflip` (`colour/_kaputflip.tsv`) takes each flow's
   newest connected account/login/single-host-ring E line WHOLESALE (forward addresses included —
   the went-kaput join), classifies that one newest message with `flip-reason.awk` and drops the
   flow entirely when it reads as a DEPLOY defect (Route stopped / Receive File As not set —
   those stay green, on the Deploy errors report); the surviving stamp merges into the same
   after-last-transfer test, clean-poll keep included. **A line whose SESSION names one flow
   is that flow's alone** (2026-09-12, user rule: for a server error with a host, read all the
   log lines with the same session id to find the right subscription): `_build_ringattr`'s
   session vote is persisted as `colour/_sessvote.tsv` (session → the one flow its lines name /
   its transfer legs carried, `\001` when two) and both wholesale joins — `_build_kaputflip`
   and went-kaput.sh — skip such a line for the siblings (a production host shared by two
   flows reddened the wrong one on an "Authentication failure connecting to remote host …"
   whose session's poll lines named the other flow's transfer site). **A ring owner serving
   SEVERAL flows counts only for a CONNECTION-level line** (2026-08-31 audit — Connection failures, Wrong
   server fingerprint, Login errors (out): the credential/endpoint every flow on it uses is
   broken); a flow-level line on a shared account/login/host concerns one of its flows and
   reaches the colour only through `_build_ringattr`. Before, eight production flows on one
   hybrid account all went red on one sibling's route error with one shared evidence stamp —
   the failure `_build_ringattr` was written to kill, reintroduced by the loose join.
   `went-kaput.sh` applies the identical rule (page + evidence sidecar), so the two stay in
   step; 1:1 owners are unchanged. So a Trouble-after-success flow arrives
   RED on Failed Subscriptions (the home red tables went 2026-09-29); the went-kaput rows (no
   page since 2026-09-29 — the Trouble after success box) keep only the deploy-classified and
   poll-cleared remainder. **The UC3 connection-failure streak (2026-09-05, user rule)**: a "Connection failure while
   <UC3 flow> tried to connect …" line reds a UC3 flow only after THREE failed polls in a row.
   When the newest evidence is a connection failure — the flow's own line (its stamp is in
   `_uc3polls.cand`'s sibling `_connfail.cand`, from the per-name mention cache + Error/Warn
   ring), or a sibling's on the shared host/account ring (`_kaputflip.tsv` col 3 flags it) — the
   flow's OWN failures newer than its newest successful poll and than the last transfer are the
   streak; below three the connection failures are DISCOUNTED and the newest of the remaining
   evidence decides by the usual test. Nothing left = the flow stays green, listed in
   `colour/_connhold.tsv` (name, stamp, streak); went-kaput still lists it as trouble after
   success (the box). Evidence of any other kind flips as before. **No UC3 clean-poll green (2026-09-28,
   user rule "A UC3 subscription that has no transfers must be orange and not green")**: a
   never-transferred UC3 whose polls work ("Applying the search pattern … for transfer site '…':
   N file(s) …") stays ORANGE — the 2026-08 exception that flipped it GREEN (sidecar
   `data/colour/_greenpoll.tsv`) is gone; no-remote-files lists such flows, and deploy-errors still
   clears a UC3 subscription on a successful poll after its last route-stop message.
   Every other entity rolls up its connected subscriptions via the xref caches (all
   green → green, any red → red, else orange — server-log evidence never sets the verdict of the
   entities above a flow). EXCEPT
   `_white.tsv`: a whitelisted IP goes by the LAST real transfer whose remote host is that
   address, orange when none.

The coverage TSVs (`showseen.sh`) mark a subscription seen when it has transfer data (a name green without a report row
of its own — seen through its subscriptions — gets blank counts); the Entities views and Entity
Search add such a green as a blank tinted "ghost" row at publish time from the base result — `RESMAP_FILES` alone carries the tint.
The per-row dimension reports, dashboards charts and day pages count real `_files.tsv` rows only.

## Report groups (full lists)

Since 2026-09-29 (user request) ONE Reports pulldown; its groups — authoritative in
`bin/publish_lib.sh` `_report_groups`, members in first-row order (`dir/stem`; T = transfer/,
S = server/, A = analyses/):

- **Overview** — Transfer top view (T topview) · Server top view (S topview). NOT on the Reports
  menu (2026-09-29, user request — the top bar's Overview link, just before Entities, opens it);
  Since yesterday (A data-diff), Triage (A) and Subscriptions in boxes (A) went the same day
- **Entities** — Subscriptions · Logical · Partners · Accounts · Logins · Hosts · Domains ·
  Applications · BL (transfer/entities; native members | views row). NOT on the Reports menu
  (2026-09-29, user request — the top bar's Entities link opens it); the group stays for the
  start page and the h1 tags.
- **Errors** (Failures until 2026-09-29, user request — out of the pulldown, its own top-bar
  link between Entities and Files) — Failed Subscriptions (A failed) · Error reasons (A
  failing-reasons) · Failed files (T) · Unknown transfers (T unknown-transfers, 2026-09-29) ·
  One-legged (T pirates) · Recovered flows (T episodes) · Retries & resubmissions (T retries) · Failure heatmap
  (T) · **Server log** — ONE first-row entry (`_report_subrows`) whose pages carry a second row:
  Errors (S errors: Log reasons / Heatmap / Top messages) · Per flow (S failure-flows) · IO
  errors (S) · Routing errors (S) — the "Server log errors" group until 2026-09-29 (user
  request); Trouble after success (S went-kaput) lost its page the same day
- **Use cases & delivery** — Use cases (A use-cases) · UC status (A uc-status) · Polling (A) ·
  Waiting (T) · Expired (T) · Went quiet (T) (Punctuality went 2026-09-29, user request)
- **Activity & volume** — Activity (T) · Ranking (T) · Sizes & types (T files) · Month stats
  (transfer/month-stats/this — every page of that directory) (Trends and Route throughput went
  2026-09-29, user request)
- **Performance** — Duration (T; + duration-all) · Longest Files (T duration-longest) ·
  Distribution & Store-and-forward (T duration-dwell) · Anomalies (T)
- **Flow patterns** — File journey (T) · File in - File out (T) · Inbound and Outbound same
  Protocol (T same-protocol)
- **Protocols & security** — Protocol, Direction & Mode (T protocol) · Security Parameters (T) ·
  Security outreach (T) · AV Scan (T) · Connection efficiency (T) · SSH security (S)
- **Logons & connections** — Logons (S) · Connections (S)
- **Partners** — Partners - Incoming (A partners-in) · Partner scorecard (A) · Blast radius (A) ·
  Application dependencies (A app-partners)
- **Configuration** — Configured subscriptions (A subscriptions) · Configured accounts (A
  accounts) · Logical detection (A) · Cross References (analyses/xref, its pair selector under the group row)
- **Coverage** — Entity coverage (T) · First seen (A) · Not in Flow Manager (T) · Skipped (T) ·
  Missing entities (S)
- (**Cleanup** — Cleanup backlog · Config hygiene · Whitelist audit · Account sharing · Twins —
  went 2026-09-29, user request, with Sources and targets; never restore.)

Entity Search (search/search.html) sits behind the top bar's search icon, the Files search behind
its Files link, the Dashboard and Monitor behind their own links — none of them in a group.

(Until 2026-09-29 the groups were per AREA, each area with its own dropdown and start page, plus
the Goodies short cuts.)

## PDA derivation (partners, domains, applications)

`bin/flow-manager.sh` is the SINGLE OWNER; downstream only joins coverage data on.

**BL** (2026-08-31, user request) is the group's FIFTH, LAST member — not PDA-derived: a BL
entity is a `subscriptions.json` `tags` entry starting with `BL`, the tag text kept VERBATIM
(`BL_FIN` stays `BL_FIN`) — UNIONED with `input/BL.txt` rows (`<subscription> <BL>[,<BL>...]`,
the numbers comma-separated in the second field; names matched case-insensitively against the checkout's configured
subscriptions, unknown ones reported and skipped). `xref/_subscriptions-bl.tsv` (subscription ⇥
BL, one row per BL of the subscription) is the map; `base/_bl.tsv` the entity list; the composed pair caches ride
the SUBSCRIPTION spine (`_accounts-bl` … `_bl-white`, via xcompose). Attribution everywhere is
`bl_union(col 12)` — a File counts for every BL tag of its subscription; direction/result roll
up from the subscriptions like every derived member. Everywhere the group renders (Entities,
details section 2.85, coverage, cross references, ranking, search, the home table —
retitled "Logical, Partners, Domains, Applications & BL") BL is added LAST; first-seen
deliberately excludes it (its set is the six classic+Logical types).

**THE BASE IS THE LOGICAL ENTITY** (2026-08-30, user request — this replaced the account-NAME
derivation wholesale). The Logical derivation (FlowID families condensed to three-part group
names, `input/logical.txt` pins honoured) runs FIRST; the PDA pass consumes its map
(`xref/_profiles-logicals.tsv`). Before ANY splitting a FlowID is separator-normalized
(2026-08-31, user request): `-` folds to `_`, doubled separators collapse and edge separators
trim — a raw `-_` run or a trailing `-` otherwise split into an empty part and the reshape
joined it into a dangling-dash artifact; an `input/logical.txt` pin matches the raw spelling
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
(A fourth rule, a **curated alias** pair in `input/partner-aliases.tsv`, was RETIRED
2026-09-01 (user request): a curated variant is now rewritten to its canonical token by
`input/logical_partners.txt` BEFORE the token enters the merge, so the two never form a
group at all.) ONE HARD-CODED rule
sits beside the replacements in `bin/flow-manager.sh` (2026-09-03, user request): a Logical whose name
contains `STREAM` takes the partner `ACCEPTEMAIL`, a token the merges leave alone (`FIXED`).

No fixpoint loop: no rule reads group state, and union-find keeps every merge transitive. The
group NAME is the sorted member tokens joined with `_`. (The **alias STAR** that could override
that with one canonical token went with the alias file, 2026-09-01: a group whose members all
pointed at one canonical token is now simply that one token — the part replacement fires before
the merge — so what reaches the naming step is a genuinely DERIVED group of several real
organisations, and the joined member list is its honest name.) Multi-member groups are recorded in
`xref/_partner-groups.tsv` (name/members/direction), `_partner-group-why.tsv`
(group/tokenA/tokenB/rule 1-3/evidence sentence) and `_partner-group-accounts.tsv`
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
every partner descends from a subscription's FlowID by construction). Retired 2026-09-01: the
whole `input/partner-aliases.tsv` file — merge rule 4, the alias star and its inert
single-token lines — folded into `input/logical_partners.txt` as part replacements.

Applications and domains share ONE name space with the same machinery: base lists
`_apps.tsv`/`_domains.tsv`, the coverage TSVs `coverage/{partners,applications,domains}.tsv`
(`ensure_pda_tsvs` in `bin/analyses/lib.sh`) and the per-member coverage cell pages.
## bin/dashboards/ — the Overview

`reports.sh` writes the page-spec `overview.rpt` (KPI + CARD/CARDALT + TOP lines); `publish.sh`
(+ the SVG generators `charts_lib.sh`) renders `docs/dashboards/index.html`. **5 KPIs + ONE
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
4 weeks / Month / Current month / Previous month / First day / Last day / Previous / Next day, the active preset in the group tab bars' active style; until 2026-08 a reduced
set lived in the hero card's `.chartbtns` row). **A span preset the estate cannot fill is
GRAYED** (2026-08, report.js `mkPresetBtn` cov functions): on a short estate Week / 4 weeks
clamp their From to the first data day, collapsing into what All or First day already
select, so they could never show as the chosen range — they are HIDDEN whenever the window
reaches past the oldest data day (an exact fit stays). **Month is the exception** (2026-09-29,
user request): always shown, one calendar month back from the NEWEST data day (ending 09-17 it
selects 08-18 .. 09-17; a partial newest day counts, unlike Week / 4 weeks), From clamped to the
first data day on a shorter estate. "This month" is **Current month** since the same day. **The
Linear/Log row of a card** sits in its `.chartbtns` wrapper, beside the chart, not above it:
slotchart.js finds the card's chart from the enclosing `.chartbox` (2026-09-29 fix — the
`parentNode` lookup found none and stored every click under kind `count`). The card titles carry no "per slot" / "up to each slot" tail — the slot semantics live in
the card subtitles. Sixteen hero views on the sample, all chart type `slots` at 6-hour slots
(`overview.sh`), the first button row: Duration (hero) · Files processed · Volume · Throughput ·
Error % Files · Transfer errors (raw `Failed` + `Failed Subtransmission` legs from
`_transfers.tsv`) · Connections (sessions opened, by who dialled) · PeSIT · EventQueue — PeSIT and
EventQueue LAST of the flat views and conditional on their sidecars, so their omission never
shifts a button index — then two GROUP buttons (a `<group>|<member>` CARDALT label) whose second
row appears while picked: **Seen** (Partners · Accounts · Subscriptions, cumulative) and **Use
cases** (the UC1–UC4 status stacks). Throughput, Connections and every Seen / UC view are
conditional too. Each card carries its own Linear/Log row (not `dur`); the choice is stored per
chart KIND (sessionStorage `axway-chart-scale:<kind>` — seen opens Linear, the rest Log).
First CARD = hero; CARDALT lines render hidden `.althero` siblings; report.js `setupHeroToggle`
swaps positionally (button 0 "Duration" hardcoded in both publishes; rpt directive `HERO0`
overrides).

**The MONITOR dashboard** — `bin/dashboards/reports/monitor.sh` → `monitor.rpt` →
`docs/dashboards/monitor.html`: the CFT end-to-end monitor page (three `durfit`-axis
`dur` latency views keyed on `monitor_*.txt` files): Monitor CFT pickup, Monitor duration (UC1
inbound start → UC3 outbound start, joined on FILE NAME — the monitor subscriptions share no
CoreId), Monitor staging. A cycle with no end counts as max(1 h, the family's slowest matched
pair), unless younger than 1 h against the newest row (export cut mid-flight — skipped).
**`monitor.rpt`'s EXISTENCE is the "this checkout has a monitor" flag** (removed when no monitor rows):
it gates the page render (help slug `monitor`), the sitemap entry (keeps it reachable for
linkcheck) and the `monitor:0|1` flag in topbar-data.js that makes `buildTopbar` show the
top-bar Monitor link.

**The UC status stacks** are TOTAL-PRESERVING compositions: every slot is a full stack of that use
case's configured subscriptions, bottom-up in ascending severity. UC1/UC3/UC4 share KIND `ucst`
(4 states: ok · ok -> error · error · not seen — the three `server - …` states went with the
blue result, 2026-09-27), UC2 has `ucst2` (5).
`bin/analyses/reports/uc<n>-status.sh` writes a per-hour sidecar
`data/server/reports/uc<n>-slots.tsv`; `overview.sh` only re-buckets. A status is a STATE: a
coarser slot takes the LAST hour inside it — never a sum/average — and an empty slot carries the
previous state forward. Regression test: the last sidecar row must equal the report's own `STAT`
figures exactly. Sidecar rules (same as pesit): the sidecar goes with the `.rpt` on a no-data exit;
a run with data but no timestamped rows creates an EMPTY sidecar.

**The three cumulative `seen` views** (Subscriptions / Partners / Accounts): per slot, how many
were seen at or
before it — `v0` orange (seen in the transfer log) / split into `v1` green (latest File OK) +
`v2` red (the blue Transfer+server union curve went 2026-09-27). Invariants at every
slot/resolution: orange only RISES; `v1+v2==v0`. `bar`/`solid` stack red, then green topping
out AT orange (`seenTop()`). All
curves count CONFIGURED entities (2026-08; the amended-in synthetic `_UNKNOWN` names stay OUT of
the roster, mirroring First seen). A logged site value credits EVERY configured subscription that
prefixes it (`credits()`, 2026-08-22 — the showseen/first-seen rule, so a configured parent name
is seen through its child flows; the unique-match `canon()` alone missed four such parents and
broke the endpoint identities below), falling back to the unique reverse match for a truncated
value; partner attribution = col 20 ∪ subscription partners ∪ host partners; accounts match
exactly. Orange is transfer evidence only.
**Cross-check after any change**: orange ends at `first-seen.rpt`'s DATED Seen (Seen minus the
no-date bucket; acceptance 2026-08-22: subscriptions 283, partners 97, accounts 221).
The overview-only views (Throughput, Connections, Seen, Use cases) are not on the day pages:
Throughput's slots open the day's Duration, Connections' and the Seen curves' its Files processed,
a UC stack's the UC's status page.

**Slot charts are drawn CLIENT-SIDE** by `docs/assets/slotchart.js`; every other chart type
renders at publish time in `charts_lib.sh`. One placeholder per card (`div.slotchart`, each
`data-iv<m>` one resolution of `label:v1[:v2[:v3]]:date|…`). CARD args: a1 KIND, a2 base series,
a3 the `{}` link pattern, then `"<minutes>:<series>"` extras — a From/To change AUTO-picks the
interval from the span (1 day→1h, ≤3→2h, ≤7→4h, ≤15→6h, ≤30→12h, else 1 day; slotchart.js
`autoIv`, applied by the range hook and the load-time stash; a manual click overrides until the
next change) — overview row 1h/2h/4h/6h/12h/1d (base
360), day row 15/30/60 min (base 30). KIND picks series/colors/format/axis: `dur` (P50/P90/P98 on
the FIXED 19-tick duration axis — 1 s · 2 s · 3 s · 5 s · 7 s · 10 s · 15 s · 20 s · 25 s · 30 s ·
45 s · 1 m · 5 m · 30 m · 1 h · 5 h · 10 h · 24 h · ≥ 48 h, the user's list verbatim, 2026-09-12;
equal spacing, linear between ticks, the last tick the clamp ceiling; drawn in a taller 760x380
frame so the labels keep apart — `durfit`, the Monitor's fitted axis, stays in the 230 frame) /
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
`data/server/reports/pesit-slots.tsv`. Only pages owning a slot chart load the asset
(`html_head`'s 9th arg, folded into `ASSET_VER`). NOTE: the publish reads KPI/CARD lines via `tr
'\t' '\037'` + `IFS=$'\037' read` — a TAB is IFS whitespace and a plain read would collapse empty
middle fields.

## bin/day/ — the per-day pages

One combined page per calendar day (`docs/day/<date>.html`, both logs). No From/To — the
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
`bin/server/reports/pesit.sh` writes (a missing sidecar leaves the day view an all-zero series —
the Overview omits the view; pesit.sh removes it with pesit.rpt), the EventQueue view
`event-queue-slots.tsv` (event-queue.sh); both
scripts have no page since 2026-09-27, so those two views' titles link nowhere. `setupHeroToggle` stores the label in sessionStorage `axway-day-hero`,
SHARED with the Overview; `?axway_hero=` overrides and persists.

The problem lists are split per log, rows routed by `PROBLEM⇥transfer|server⇥href⇥headline⇥desc`.
Signals: one-legged/pirates + Waiting/Expired staged files from `_files.tsv`; the three
full-period subscription verdicts bucketed by state-change day (`daycount RPT FIELD`; their
reports are `nofilter` — links carry NO `?axway_date=`); the server No remote dir/files tables
(date-aware — links keep it); per-day `_parse.tsv` line counts for the message-family signals
(logon screening, outbound logon failures, connection failures, deploy route-abandons,
event-feed errors; the PeSIT-ceiling and cluster-distress problems went with the Operations &
Capacity pages, 2026-09-27 — the ceiling stays a FACT). (The UC3 "Failing polls" problem went with
the uc3-status "server - error" state, 2026-09-27.) Together the two lists cover every red/orange box of Subscriptions in
boxes that has dated log evidence (Missing cron, Went quiet and Not seen have none). Both Top views link Date cells to day pages via the cell attr
`@{href=URL}`; consumers of topview date cells strip it first (`sub(/^@\{[^}]*\}/,"",d)`:
publish_lib's `area_dates`, `bin/build/publish.sh`, `bin/dashboards/lib.sh`,
`bin/day/reports.sh`). The transfer `topview.rpt` per-day table has SIX column groups since
2026-09-12 — Date · First · Last | Files (Count · Ok · Error · Error %) | **Recovered**
(Automatic · Manual: the OK Files that carried a failed leg, Manual when a leg carries
`Resubmitted=true`, `_transfers.tsv` col 22) | **Resubmit** (Ok · Failed: every File with a
resubmitted leg, by outcome) | Transfers (Count · Ok · Error · Error %) | State (Processed ·
Failed · Waiting · Expired) | Volume (since 2026-09-29, when Activity's per-day tab went) — ROW
fields 2-21 in that order; the home page's Cured cell is Automatic + Manual (fields 9-10).

## Click-to-expand drill-down

`data-coreids` makes a row clickable; `data-coreids-failed`/`-processed` its Error/OK cell (bound by cell class — only on a row with exactly ONE Error / OK cell; render_rpt.awk drops the lists a row could never bind, 2026-09-29); the Entities pages bind their lists per cell through `drillcols=` (the retry / resubmit binding went 2026-09-29 — no page shipped those lists).
Clicking inserts a detail row listing that outcome's 10 most-recent transfers; detail rows are
excluded from `dataRows` and torn down before sort/filter/search. Lists are built by the shared
`COREIDS_AWK` helper (`addtop` bounded top-10 + `buildlist`/`orlist`). Every transfer report with
real Error/OK columns emits these (av-scan excepted). The Duration report's per-day table drills
every cell via `@data:drill-cell-<colindex>` (≤5 files nearest each statistic's rank; TAB-read
consumers need `orlist`'s `-` sentinel for empty fields). The server reports use `@data:loglines`
(a row's 10 most recent "date time Level Component message" lines, `LOGLINES_AWK`'s `addline` — a
bounded insert by "date time", NOT arrival order: the exports are newest-first within a file; in
pipe-delimited aggs the loglines field goes LAST so embedded `|` survives).

**A drill entry links its File page when the File HAS one** (2026-09-29, user request "docs/files/
— store only the last OK and the last 3 errors of a subscription"; replaces the 2026-09-21 "first File
of a red / orange cell" rule and its `bin/build/drill-files.sh` / `_drill-files.tsv` list):
`bin/transfer/filepages.sh` writes the published set `data/transfer/cache/_filepages.tsv` (CoreId ⇥
O|E ⇥ subscription — per subscription the newest Processed File by END and the three newest Failed
Files by sortkey). render_rpt.awk (`fp_has`, `fp_first` — the first 36-character UUID of each
value) collects the row's CoreIds from its `coreids` / `coreids-*` / `drill-cell-*` attributes and
stamps the ones in the set on the row as `data-fp="id id …"` (never on a total row). report.js
`bindDrill` links an entry's CoreId (`data-b` + `files/<coreid>.html`; `addCoreIdLinks` adds the
File Tracking `↗`) only when it is listed in its row's `data-fp`, whatever the cell's colour.
`linkcheck.sh` (2b) models every data-fp CoreId as a strict edge. failed.sh pages every set member
(an E File the leg selection did not page gets a File page); bin/transfer/publish.sh renders only
the set (`fp_keep`).

## The home page

`bin/build/publish.sh` writes the centered shared home (body class `home`): the two status tables
plus the per-day figures — ONE wide "Per day" table (`write_home_block`; 2026-08-31, user
request; the 2026-08 five-table `.sxs` flex row with its blanked Date spine is retired — it could
fall out of row-sync whenever a header's height changed): a `gband` banner row over a shared Date
column whose cells link the day page, then five groups, each behind a SPACER column
(`th/td.spc` — no borders, page background, so every group keeps its own edges; report.js
`syncGroups` re-hides a spacer with its group and sets the edge classes after a move or hide):
**Transfers** (Ok · Error · Error % — the legs) · **Files** (In · Out · Ok · Cured · Error ·
Error %) · **UC2 state** (Waiting · Expired) · **Duration** (p50 · p75 · p90 · p95 · p99; the
banner, headers and Total open `transfer/duration.html?axway_date=all`, each day's cells
`?axway_row=<date>` via `data-href` / `setupCellLinks`) · **First seen** (Partners ·
Subscriptions). (The Red/Green switch group, its `docs/switches/` pages and the Logical /
Accounts First-seen columns went 2026-09-06, user request.) The days are the transfer
`topview.rpt`'s only — every data group is transfer-derived, so a server-only day (the
server export running a day ahead of the transfer export) would render a fully empty row. The
table is `data-nosort` and shows EVERY day (the 14-day cap and its "Show all" button went
2026-09-29, user request); the Total row exists only from 10 days up. The baked Total keeps the full-window figures, since
`recomputeTotals` counts inline display only; the First-seen counts join `first-seen.rpt` by date —
its summary lines stay out of the day rows, and each First-seen Total cell shows the report's
SEEN figure — equal to the status tables' Seen by construction, the day cells
plus the report's no-date bucket summing to it — linking its `<type>-seen` list), plus the
log-exports facts table (`write_log_facts`:
per log the input-file count (the `*.csv` under `input/server/` and `input/transfer/`), total
records, first/last record stamp and the HOLES — span days with no record — from the topviews;
Records = the log's own rows — the server topview's Records column, the transfer topview's
Transfers Count (`$13` since 2026-09-12 — the Recovered and Resubmit groups sit before it — one per physical leg), never a Files or percentage column: until
2026-08-31 the transfer half read `$13`, the Transfers Error %, so a clean 0.0 % day counted as a
hole and an estate with no failed transfer showed the Transfer row without Records/First/Last/Days).
Every status cell opens the **Entities view whose row
count IS that figure** (columns Entity · Total · Seen · OK · Error · Warning · Ok — the
Transfer/Server columns and the "including server log" switch went with the blue result,
2026-09-27): Total links `<e>-all`, Seen `<e>-seen`, the counts their result views; the
percentage columns link too; a 0 renders as an empty cell (inert). The
five Logical/PDA/BL **Total** cells link the coverage cell pages
`docs/coverage/<member>-configured.html` (written by `bin/analyses/reports/coverage.sh` +
`render_coverage_pages`, help slug `coverage`). `check_status_consistency` verifies every figure
against the tinted (`data-res`) row count of its target view. The "configured names actually SEEN"
figure comes from `bin/analyses/reports/home.sh` → `home.rpt` (nine `SEEN⇥member⇥count` lines;
the derived Logical/PDA members re-run their both-ways merge over `coverage/<member>.tsv`), consumed by
`_status_table`.

## The Entities report pages

Nine entity reports — subscription, logical, partner, account, login, remote-host, domain,
application, bl (group `account-login-site`, label "Entities") — each rendered as SIX pages under
`docs/transfer/entities/` by `render_entity_report`:
`<entity>-{all,seen,not-seen,ok,warning,error}.html`. The page data is
`data/transfer/reports/entities/<name>.rpt`, written by ONE writer for the nine,
`bin/transfer/reports/entities.sh` (2026-09-13, user request — built that day as the
`transfer/entities2/` twin experiment and adopted the same day; the classic Name · Direction · Files ·
Volume · OK · Retry · Resubmit · Error · Last seen pages are gone). The nine classic `<name>.rpt`
(`account.sh`, `subscription.sh`, `login.sh`, `remote-host.sh`, `pda-entities.sh`) stay DATA
producers — `showseen.sh`, `entity-search.sh` and the server rosters read them positionally — and
render no page.

THE GROUPED LAYOUT — Name, then seven column groups (a `GHEAD` banner row + `gsep=` dividers like
the Top view), ONE table per view:

| Name | Files | Retry / Resubmit | Duration | Volume | Transfers | State | Dates |
|---|---|---|---|---|---|---|---|
| | In · Out · Error · Error % | Auto · Ok · Error | p90 · p95 · p99 · p100 | Total · Avg | Ok · Error · Error % | Waiting · Expired | First · Last · Days |
| KIND | num num numfailed num | numwarn numwarn numfailed | num num num num (+ unit tint) | num num | numok numfailed num | numwarn numfailed | text text num |
| RECALC | S1 S2 s3 e3.0 | s7 s8 s9 | P90 P95 P99 P100 | H4 V4.0 | s5 s6 e6.12 | s10 s11 | - - c |

Bucket metrics per date: `files in out ferr bytes tok terr rauto rmok rmerr waiting expired legs`
(0–12). Definitions: Transfers = every LEG of the entity's Files (Processed / not), credited to the
File's start day; In/Out = the MOVEMENT direction (`_files.tsv` col 17 — a File with no movement
counts in the total and the Error % only); Retry / Resubmit = the Top view rule (Auto = an OK File
with a failed leg and no resubmitted leg — the former Retry column; Ok / Error = EVERY File with a
resubmitted leg, by outcome); Days = days with ≥1 File; Avg = bytes ÷ Files; Duration = the p90 /
p95 / p99 / p100 of the OK Files' wall-clock span (`_files.tsv` col 9 > 0 — `duration.sh`'s default
scope and nearest-rank rule `T[int((N-1)·P/100+0.5)+1]`), FOLLOWING the date filter (user rule):
each span is quantized to the humandur DISPLAY grid (rounded like the format, so a grid histogram
picks the same displayed value as the exact list), the per-DAY histograms ride the ROW as
`@data:durdays=date:q.count;q.count,…`, and the RECALC tokens `P90`…`P100` (report.js
`aggDurDays`/`pctlHist`) re-pick the percentile over the in-range days — per row, and for the TOTAL
over every visible row's merged histogram; the publish-time subset totals merge the same payload.
Display rules (2026-09-13, user): the TOTAL row LAST (`entity_total_last`); an EMPTY Retry /
Resubmit or State group HIDDEN per view (`entity_hide_groups` — a publish-time decision, an empty
full range being empty for every narrower range: it drops the fields, the banner cell and remaps
gsep=/noagg=/pct=/drillcols= past the dropped columns) and, in the BROWSER, whenever a date range
or a search leaves every visible row's cells of the group empty (the `autohide=Retry /
Resubmit;State` TABLE modifier → `data-autohide` → report.js `autoHideGroups` after every
recalc / search: the group's columns take the hidden attribute through `applyHidden`, whose
`_autoHidden` set joins the picker's `_colHidden` for the cells and the banner spans but never
enters the stored list; the columns return when a visible row carries a value); whole-unit bytes (tokens `H`/`V`); the
s/m/h/d durations tinted green/amber/red by unit (the `P` token retints); an empty rate beside an
empty Error (token `e`); no In/Out 0 (token `S`); every red count as KIND `numfailed` — `errc`/`okc`
cells lose their tint inside the views' tinted rows, only `.failed`/`.processed` and a non-empty
`.warn` keep it. Drills: every count cell → its 10 newest Files (`drillcols=` → the row's
`@data:coreids-<key>`, bound by BUILT column index, the noun in the spec); the Transfers cells → the
Files that carried a leg of that outcome; a Duration cell → the 10 newest OK Files whose (grid) span
is at or above that percentile, each entry carrying its span — a THIRD pass over `_files.tsv` once
the thresholds are known (`calc_pcts` at the pass's first line; END computes them itself on an empty
cache). The writer's attribution mirrors the classic writers exactly (Files / Error / Auto / Volume /
First / Last agree row for row with their `.rpt`); totals per (name, File) pair for
subscription / login / remote-host, once per File for the rest — the classic `T|` rule; rows baked
busiest-first with no `sort=`.

Render (`render_entity_report`): the six views (below), over the grouped `.rpt`
which is already in display order — no Direction injection and no reorder; the seen rows keep their
baked order and the never-seen / ghost rows follow by name; `entity_res_block` re-sums the OK /
Warning / Error subset totals into the writer's own TOTAL template (the count cells, Files and bytes
from the buckets, Days = the distinct bucket dates, the Duration cells rebuilt whole from the merged
`@data:durdays`); the subscriptions Error view's Reason column lands after Days (`nreal` 23);
`entities_name_only` also drops the `GHEAD` line and the `gsep=`/`drillcols=`/`pct=`/`noagg=`
modifiers for the name-only views. Links INTO the pages sort by header LABEL
(`?axway_sort=Error:-1` / `Total:-1`; report.js resolves the first header cell reading it) because
the positions shift when a group is hidden. The hand-written help pages `entities-<name>.html`
describe this layout.

The Reason column (2026-08): the SUBSCRIPTIONS Error view appends it — the same per-flow diagnosis
the removed home red tables showed, resolved by the same chain (newest red `failed-sub-all.rpt` row's own
verdict unless the flow is in `colour/_redflip.tsv`; else the classified `_kaput-evidence.tsv` newest
E line via the shared `bin/flip-reason.awk`; else `_subs-boxes.tsv`). `_subs-boxes.tsv` is written
by the LATER analyses publish, so build.sh re-invokes the transfer publish right after the
analyses publish (the "transfer catch-up (boxes reasons)" step) and the boxes sidecar lands in the
SAME build.

Nav = two tab groups: member · All/Seen/Not seen/OK/Warning/Error — six pages per entity,
`<entity>-<view>.html` (the Transfer | +Server SCOPE row, its `-transfer` pages and the
seventh Server view went with the blue result, 2026-09-27; a server-log sighting never counts as
seen). The views are assembled at PUBLISH time: All = Summary
rows + one zero-blank row per configured-never-seen name (the DEFAULT page, `first_page`);
OK/Warning/Error filter by site-wide RESULT (`entity_res_block` — one definition, shared with tints
and status columns). The not-seen names come from showseen's `coverage/*.tsv`, so Entities and Show
Seen can never disagree. Every view carries `datereset`.

**SORT is SHARED across the nine entities with a 1-hour sliding expiry** — the one localStorage
in report.js (`entLoad`/`entSave`/`entTouch`/`entResolve`), stored by "group › column" LABEL, never
index (column 0 = the sentinel `#name`; the group prefix because Ok / Error / Error % repeat across
the groups); a label the view lacks leaves the entry intact and that page keeps its own default.

**`showseen.sh` is a DATA producer only** — its four `showseen-*.rpt` are unpublished
intermediates feeding the status figures; its `coverage/*.tsv` feed the entity not-seen rows. It
lifts figures straight from the entity summary `.rpt`s (subscriptions = prefix match, others exact
name match, case aside). Runs after `details.sh` (needs the slugmaps). No Logical/PDA members
(their Seen figures come from the coverage-TSV union path instead).

### Month stats (2026-09-13; retired and brought back 2026-09-29 — Activity & volume group)

`bin/transfer/reports/month-stats.sh` reuses the Entities attribution (same rules, same nine
entities, same total-row pair/once rule) but counts only the Files whose START date (`_files.tsv`
col 4) falls in ONE calendar month: "this" = the month of the newest File start, "previous" = the
month before. 18 `.rpt` under `data/transfer/reports/month-stats/{this,previous}-<entity>.rpt`
(`META month` / `META which`), columns Total files · In · Out · Errors · Auto Retries · Resubmit
OK · Resubmit Error · Waiting · Expired, busiest first. `render_month_stats` (publish_lib, from the
transfer publish) renders them into `docs/transfer/month-stats/` with two NAV tab rows (the month
with its yyyy-mm, then the entity) and no From/To filter; help slug `month-stats`. Its Reports
group member is `transfer/month-stats/this` — `rg_landing`, `apply_report_groups` and
`rg_group_for` special-case that directory (every page of it belongs to the member). The same
script writes the all-time sidecar `$REPORTS_DIR/_alltime.tsv` (every File, the nine counts per
entity name) the analyses Subscriptions page reads. (The morning of 2026-09-29 the pages went and
the script was cut down to `alltime-counts.sh`; Herbert asked for them back the same day.)

## Per-entity detail pages

`details.sh` → `data/transfer/reports/details/<sub>/<slug>.rpt` →
`docs/details/<sub>/…`, one page per entity of the nine types, counting Files; plus
`details/incoming_connections/` and `details/partner-groups/`. **Every name from `base/` (except
`_white.tsv`) gets a page, seen or not**, plus every logged entity.

The TITLE leads with `XXX/YYY:` (connection/movement, `?` when undecidable). Slug = plain name
slug; collisions bump to `<slug>-N` in stream order; `_slugmap.tsv` is COMPREHENSIVE and every
consumer resolves links through it. The `<body>` carries a tint class (the RESULT wins). **No
From/To, no search box, no RECALC/@data:buckets** (`CUR_DATES` stays empty; `setupSearch` skips
`/details/`).

Page order IS the section number: -1 direction · 0 header data · 0.9 Waiting/Expired summary ·
1 Activity per day · 2 subscription · 2.6/2.7 Incoming/Outgoing connections · 2.8 account ·
2.81–2.83 domain/application/partner · 3 login · 5 protocol · 6 av · (9, the latest Files,
went 2026-09-29) ·
10 weekday · 11 hour · 13 direction · 14 action-by · 15 mode; then `close_file` appends the
Duration/Size perf tables, a Groups fact table (classic types only — a PDA page IS the group) and
"Last server log messages" + "Last server log errors" (two tables since 2026-09-16, see below).
**SITE pages pair the first two tables**: when the page opens "Activity per day" then "Features"
— the seen-page order — `site_sxs_row()` gives both the same `sxs=af` id, so they render on ONE
flex row (they are already adjacent, so nothing is relocated; a never-seen page, Features first,
is left alone). On a UC2 page `publish-details.sh` splices the Pickup information table into that
SAME row (it reuses the id it finds on the Features line instead of its own `sxs=feat`).

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
  pickup visits** table (`bin/analyses/reports/uc2-visits.sh`, stacked on the UC status UC2 tab
  since 2026-09-29 — its own page went — it only formats the sidecar, so the three views cannot
  disagree; runs after the server pool, behind `uc2-status.sh`; the **Partners - Incoming** page, `bin/analyses/reports/fe-overview.sh`, joins the same sidecar onto LOGIN rows, once per login and account — 2026-09-02; the FE overview page went 2026-09-29, `partners-in.sh` renders it). **The "Connection shared with
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
  "Pickup information" table. The uc2-status TABLE is one row per (account, UC2 subscription)
  PAIR since 2026-08-31 (it was one row per ACCOUNT labelled with its alphabetically-first UC2
  flow: production showed 7 of 14 flows, and a broken flow hid behind a healthy sibling's
  "Both"): staged / collected / expired are the flow's own from `_files.tsv` (expiries
  attributed per flow when any flow of the account has them, the account's server-side deletion
  evidence — shared — otherwise), the pickup-attempt logons are the account's (the partner logs
  on to the account), and the per-hour sidecar walks the same pairs. **MULTI-FE ACCOUNTS**
  (2026-08-31, user report — new in production: one account carries SEVERAL FE logins, each a
  different partner credential serving its own flows): on such an account every LOGON-derived
  figure (attempts, visits, cadence, first/last pickup, the sidecar's Pickup information) is
  scoped to the subscription's OWN login(s) — the same visit rules run per (account, login)
  group — because a logon by login A used to make login B's quiet flows read "No files / the
  partner connects, but nothing is ever staged" though THEIR partner never connected; they read
  "Nothing" now. Single-login accounts are output-identical. uc4-status credits an
  account-level server line to EVERY UC4 flow of the account (union attribution; the STAT totals
  count each line once) instead of one arbitrary flow — except that a logon/refusal NAMING a
  login is, on a multi-FE account, credited only to the flows configured for that login. `subscription-verdict.awk`'s END fallback
  still writes the bare Pickup information table for every sidecar flow without a verdict.
- **"Latest OK" and "Latest Error" — two Features ROWS, not sections** (2026-09-16, user
  request; the "Last OK transfer" and "Last error" SECTIONS, the publish-time last-error splice
  and their log-line suppression are all GONE). Each row reads `<date time>  <file name>` and
  links that File's OWN page: **`files/<coreid>.html`** for the newest PROCESSED File — newest by
  its END (`_files.tsv` col 24, the same "last OK transfer" the after-last-transfer cut uses),
  deliberately NOT the outcome policy's OK, since a UC2 file still Waiting is staged, not
  transferred — and **`files/<coreid>.html`** for the newest FAILED one. `details.sh` writes the
  `$_pdir/lastok` sidecar in ONE pass over `$FILES` (`F⇥site⇥file⇥date time⇥coreid`; the former
  legs/session/server-cache passes went with the sections) and `details_writer.awk`
  `lastfiles_features_rows()` appends the rows to the Features block, after the "Files" row.
  **Both pages are GUARANTEED by `failed.sh`**: the newest failure through the `S` mark (S implies
  L, so the leg selection pages it) and the newest OK through the LATEST-OK list it now folds into
  the `files/` page set (source tag `O`, no back link of its own — the page's facts table links
  its subscription). A flow with no such File gets no row. Because nothing is repeated on the page
  any more, **"Last server log messages" no longer suppresses those lines** and shows the page's
  own log in full — the SUPPRESSION SET has no writers left. A SERVER-FAILING subscription (in
  failed.sh's `_srvsubs-map.tsv` — the REDUCED name⇥slug⇥stamp map, without the reason column;
  went-kaput runs EARLY in the build so the stamps are final on failed.sh's first pass and
  details.sh needs one run) gets a
  THIRD Features row, **"Server log error"** — the map's stamp, linking the flow's OWN
  `files/<slug>.html`, which failed.sh already writes. The section that re-emitted that page's
  server-log table here (`srv_log_error_section`) went with the other two on 2026-09-16.
- **The "Logons" table** (2026-08, LOGIN pages, `logons_section()`): first/last successful
  authentication, the raw logon count and the cadence label, from **`bin/logons.sh`**
  (`ensure_logons` → `data/server/cache/_logons.tsv`, atomic; built once per build by
  `bin/build/logon-summary.sh`) — one
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
  `sxs=9`; a page WITHOUT an Activity table — a never-seen login — anchors the row on
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
  same-movement flows — the EQUENS UC3/UC4 pair does); an estate without any qualifying pair must degrade
  to no rows. The cell is `@{alink=…}`, tinted by the TWIN's own result.
- A KPI Summary table (`nosearch`, not date-aware) renders before section 10 on seen pages.
- Section 9, the latest Files per entity (Latest 100; Latest 1000 on subscription pages) is GONE
  (2026-09-29, user request — no detail page lists Files from the stream any more; the SITE list's
  `docs/latest/` page, since 2026-09-16, and the Features row "Files → Latest 1000 files" went
  with it): `details_writer.awk` `files_table()`
  puts an EMPTY **Files** table (`subfiles=<slug>`) right above Load by weekday on every page with
  Files, and `assets/sub-files.js` fills it in the browser — every File of the subscription, 25 per
  page, Previous / Next — from the all-files data: the per-subscription day list
  `docs/search/all/s/<slug>.js` (publish-all-files.sh: day ⇥ Files ⇥ shard cksum ⇥ the shard's
  local subscription index(es), newest first; `?v=` = the build id `AXWAY_BUILD_ID`, render_rpt.awk
  `data-v`, since the list is written after the pages render) and only the day shards the shown page
  covers (`?v=` their cksum). Columns Start · State · Size · File · CoreId; a File with a page links
  it; a total row counts them all.
- Sections 2.6/2.7 (`whitelist_rows()`): 2.7 = configured endpoints ∪ observed outgoing hosts;
  2.6 = the AllowIP whitelist ∪ observed incoming sources (no Name column — an incoming address
  never resolves to a configured endpoint). Green = configured + traffic, red = unconfigured
  traffic, orange = configured unused (folded behind one summary row).
- `insert_config_rows` appends after each section's logged rows one zero-blanked linked row per
  configured-but-never-logged pair (`seenrows`; subscriptions match by prefix). The ONE_DIMS fold
  covers only account/login/mode; the PDA-trio pages' group dims always render as own tables,
  every row tinted by the item's RESULT. Every entity cell is tinted by its own RESULT
  (`RESMAP_FILES`, set around `render_details` only).
- "Last server log messages" + "Last server log errors" (bottom of every page): TWO TABLES since
  2026-09-16 (user request) and **NO DEDUPLICATION** — the entity's 25 recent lines in the first,
  its 10 recent Error/Warn lines in the second, plus on SEEN pages the Error/Warn of its 1-to-1
  connected entities — 1-to-1 BOTH WAYS (2026-08-31): a connected account/login/host serving other
  flows too is not merged — after its last transfer (ACCOUNT pages fold in their logins'/hosts'
  lines). A line that is both recent and an error now appears in BOTH tables, and a line the log
  holds twice is shown twice (`sort_cap`, which replaced `dedup_cap`; `emit_srv_rows` renders one
  table, `emit_srv_table`'s third argument picks one or two). The per-entity lists a
  never-seen page prints (`srv_lines_for`) stay ONE table each. Any Error/Warn after the last
  transfer opens a red ALERT banner. Only the five classic types have per-name caches.
- **Partners - Incoming** (2026-09-13, user request), `bin/analyses/reports/partners-in.sh` → `analyses/partners-in.html`: a MERGED report — fe-overview.rpt (the FE overview, renamed back from "Partners - Incoming" the same day) joined with the Incoming table of the server pool's `logon.rpt`, one row per login (the union; funnel-only logins untinted with empty transfer cells), the funnel cell drills re-keyed to their new columns; trimmed the same day (user request) to Login … Pickups + Allowed · Disallowed · Authenticated · Auth Failed (= Bad key + Key failures + Auth failed, its drill the 5 newest lines of the three) · Locked · Pattern. Runs after analyses wave 1. The FE overview page went 2026-09-29 (`fe-overview.sh` stays its pageless producer); the Logons report keeps its Incoming tab. (**Partners - Outgoing**, `hosts-overview.sh`, went 2026-09-29: the Entities Hosts view carries the same per-host figures.)

report.js `hideEmptyTables()` (detail pages only) hides emptied sections; `setupSectionTabs()`
builds the sticky header (`div.detailhead`). The sticky-header CSS comment must never contain a
literal `*/`.

Structure: four stream producers in **`bin/transfer/details_lib.sh`** run CONCURRENTLY into temp
files one sort consumes (`whitelist_rows`' `|| true` is LOAD-BEARING under `set -e`); the stream
is traversed exactly twice (PASS A dims, PASS B the awk annotation pass); the writer
**`bin/transfer/details_writer.awk`** runs one awk per type in parallel, reproducing `sort -k1,1r
-k2,2r` exactly. `details.sh <TYPE>` reruns one type.

A resolved IP has no page of its own — links resolve to the hostname page; unresolved IPs keep an
IP-named page.

## The special pages

**File search** — the SEVEN window pages `docs/search/file-search-<window>.html` (2026-08 ..
2026-09-29: `bin/analyses/reports/file-search.sh`, their `-data.js` payloads and the dedicated
`assets/file-search.js`) are GONE (user request: "keep only search/all-files.html"), with the
publish_lib `file_search_impl_row` Implementation 1 | 2 row that joined them to the all-files
search. The ONE file search is `search/all-files.html` — the top bar's **Files** link (CLAUDE.md,
the all-files search). What outlived them: `failed.sh`'s 30-DAY GUARANTEE — every FAILED File of
the newest 30 data days gets its `files/<coreid>.html` page (never Expired — a pickup problem is
the detail page's story), at most 10 per subscription per DAY (its leg-selection pages included,
newest first); the all-files shards flag those CoreIds and link them.

- **Entity Search** — `docs/search/search.html` (+ `search/search-data.js`; at the root until 2026-09-12). Columns: Name · Direction · Type · Error · OK ·
  Last seen (Direction = the same `XXX/YYY` pair that titles the detail page; a row with no page
  of its own inherits the pair/counts/tint of the page it links to; Last seen = the newest
  `_files.tsv` entry attributed to the entity as `ccyy-mm-dd hh:mm:ss`, the site's union
  attribution for Partner/Application, the host column for Whitelist/IP rows, the subscription's
  stamp for Source/Target — a multi-subscription path shows the newest and its subrows payload
  carries each member's own). **Rows ship as DATA**:
  `split_search_rows` lifts every rendered `<tr>` into `docs/search/search-data.js` (loaded BEFORE
  report.js) and leaves an empty `data-start-empty` table; `esBuild` inserts only matching rows.
  Two rebuild invariants: the header and TOTAL rows keep their ORIGINAL DOM nodes, and
  non-matching rows are counted into `data-es-omitted` so `recomputeTotals` sees the table as
  filtered. `esearch` renders the controls open: entity-type checkbox buttons (all OFF =
  everything; the `TYPES` array is the button order, the filter map is keyed by NAME) + the search
  input. The search matches the NAME column only; no views, no drills, no date filter; rows tinted
  by RESULT. Also lists every whitelisted IP (type "Whitelist", linking the allowing account).
  **Adding a column means shifting report.js** — the Type cell is read by INDEX (`cells[2]`) in
  several places.
- **Failed Subscriptions** — `bin/transfer/reports/failed.sh`, the first member of the Failures
  group (`SUBS_GROUP_REPORTS` `transfer:failed` — data in
  `data/transfer/reports/`, pages in `docs/analyses/`; the group's second member is
  **Error reasons** — `bin/analyses/reports/failing-reasons.sh`, basename `failing-reasons`
  because `error-reasons` is a SERVER merged component: every Reason that occurs with the count of
  Files in error (Failed or Expired) and the newest occurrence; a row opens Failed files searched
  on that reason as a whole cell — the per-reason `failing-reasons-<slug>.html` drill pages went
  2026-09-29): since 2026-09-29 TWO pages over the Files in error
  (Failed AND Expired — the site-wide Error rule; Expired reads "Expired (not collected)"), one row
  per subscription (its newest): **Still failing** (default, `analyses/failed.html`) and **All**
  (`failed-sub-all.html`, green-again subscriptions kept) — the "All files" views went (Failed
  files lists every File). Columns Subscription · Date/time · Reason · CoreID /
  SessionID · Last green day · Days red · Failures in a row — the last three from the pageless
  from-green-to-red / only-red producers (the Only red / From green to red pages and Episodes'
  Open incidents table went the same day). The selector row is rendered by a dedicated block in
  `bin/analyses/publish.sh` (same group row, help slug and persistence key) —
  `p.tabs.undertabs`, injected before the first tablewrap; report.js hoists its From/To anchor
  back over it so the buttons sit BELOW the date fields. PLUS the SERVER-FAILING rows: every red
  subscription with NO failed File (server-log-reddened) gets one row per list — `@data:srv=1` (the
  marker the failed-sub-all.rpt consumers skip), Date/time = the redflip/kaput evidence stamp,
  Reason = the classified kaput E line else its box — so the pages cover ALL failing
  subscriptions, transfer and server alike. Each server-failing subscription ALSO gets its own
  drill page `files/<slug>.html`, NAMED BY THE SUBSCRIPTION (lowercased, non-alnum → `-`; a
  separator-twin collision suffixes; a slug never collides with a UUID CoreId page): the facts +
  the flow's server-log mention ring, written BEFORE the evidence-sidecar pass so its E/W lines
  join `_errpage-evidence.tsv`; the row opens it like a file row opens its CoreId page. Paged
  file rows link `docs/files/<coreid>.html` — a second `.rpt` per paged file under
  `data/transfer/reports/errors/`, listing every leg of that CoreId.
- **Cross References** — `cross-reference.sh` → 72 pages in `docs/analyses/xref/`: every
  pair of the nine entities both ways, existence only (no counts/drills/date filter); rows =
  seen-together pairs + configured-never-seen (`@data:seen`); table `group`; each cell tinted by
  its own entity's RESULT; two full entity NAV rows (row 1 first entity, row 2 second).
- **Entity coverage** — `bin/analyses/reports/entity-coverage.sh` → six pages
  `transfer/entity-coverage-{accounts,logical,partners,domains,applications,bl}.html` (one per
  entity, `report_tabs`; 24 pages — 4 rules × the entities — until 2026-09-29): is each
  configured DIRECTION working? Columns Name · Direction | In (Subs · Files · Logons) | Out (Subs ·
  Files · Polls) | Covered — the verdict COLUMNS **Current** (the row colour: the most recent File
  that way OK, or a logon/poll proof) · **Once** (any File, or a proof) · **OK transfers** (the
  most recent File itself OK — no server-log proof) · **Regressed** (covered Once but not
  Current). Proofs: In = successful SSH logons (auth-activity.rpt), Out = successful UC3 remote
  polls (remote-poll.rpt — an unpublished intermediate since 2026-09-05). Assert after a change:
  **OK transfers ⊆ Current ⊆ Once**. Accounts is the default entity. Two row colours only (green
  covered / red not); a side with 0 configured subscriptions is trivially covered. The STAT boxes
  sit AFTER each TABLE line (`segment_rpt` files them per tab). No date filter.
- (The INSIGHT pages `whitelist-audit` and `config-hygiene` of `publish-insights.sh` went
  2026-09-29 with the Cleanup group, user request, and with them `bin/server-inbound-addr.awk`
  and the Connections `_inbound-addr.tsv` sidecar; publish-insights.sh only writes the boxes
  sidecar now — see the last section.)
- **UC3 polling tables** (`bin/analyses/reports/uc3-polling.sh` → `uc3-polling.rpt`, merged behind
  `uc3-status.rpt` with `tab=uc3` so they stack on `uc-status-uc3.html`, 2026-09-05 — the one
  report about us polling partners; the Remote polls page and the hand-written Cronjobs page are
  gone): the Polls by subscription and Remote directory listing failures tables copied from
  `remote-poll.rpt`, then **Configured cronjobs** — the configured cron schedules (`bin/cron2human.awk`)
  against the OBSERVED firing: the server log first via `data/server/reports/poll-times.tsv`
  (the sidecar `remote-poll.sh` writes — an empty poll leaves no transfer record), falling back to
  punctuality's arrival slot `· files`; name matching exact-first then prefix BOTH ways (the server
  truncates long site names); a dark-red `obsbad` Observed cell contradicts its cron — and
  **Schedules that never complete a poll** from `poll-failures.tsv` (S/C/L rows by site, A rows by
  host via the subscription→host xref). A missing input drops the tables it feeds; with neither
  `remote-poll.rpt` nor a config export there is no `.rpt` at all.
- **Polling** (`bin/analyses/reports/polling.sh` → `polling.rpt` → `analyses/polling.html`, 2026-09-05,
  the flat twin of the UC3 polling tables; a Use cases & delivery member): ONE table, one row per
  UC3 polling subscription (UC3 ONLY since 2026-09-13 — the UC3 status roster, name-prefixed or
  derived, plus UC3-named flows the server log shows polling) joined with `remote-poll.rpt`'s polls
  and listing-failure rows and the configured cron schedules (exact name join, else the unique
  prefix either way); columns Subscription · Active (2026-09-20, `bin/subscription-active.jq`) ·
  Cron expression · Schedule (a UC3 without one reads "no cron" — the former Missing cronjobs page)
  · Observed (`obsbad` when contradicting) · Polls · Empty polls · Files matched · Empty % ·
  Listing errors · Poll starts · Failure lines · What goes wrong, the poll counts date-aware
  (RECALC over the merged buckets) with the copied `@data:loglines` drill. The schedule-vs-observed
  classifier is the shared `bin/cron-observed.awk` (also used by uc3-polling.sh). Runs in
  `bin/server/reports.sh` right after uc3-polling.sh.
- **The Logical derivation** (`bin/flow-manager.sh`, which writes `base/_logicals.tsv` + the
  `_profiles-logicals` FlowID → Logical map; 2026-08-30, a FULL entity since 2026-08-31 — it
  outlived the acceptance-vs-production comparison pages it was first built for, retired with
  the environment split 2026-09-11): intake folds the separators and, ABOVE THREE
  PARTS, drops every purely NUMERIC part (2026-09-01, user request — `AB_EUROPORT_EQUENS-1` is
  the EQUENS flow, not a fourth-part variant); pass 1 GROUPS (shared 4-part prefixes,
  digit-tailed parts whose removal collides), passes 2–3 NORMALIZE every name to
  three `_`-parts, joining combined parts with `-` (a TWO-part name takes `UNKNOWN` as its
  middle part — `WA_VDN` → `WA_UNKNOWN_VDN` — since two parts name a domain and a partner,
  never an application) — which is why Logical names render UNFOLDED
  site-wide. Every Logical page reads the cache like every base and links `details/logicals/`.
- **UC status** — the four `uc<n>-status` reports merged into ONE tabbed report `uc-status`
  (server-area `.rpt`s; its `SUBS_GROUP_REPORTS` entry `server:uc-status` — the full value is
  `SUBS_GROUP_REPORTS` in publish_lib — routes its PAGES to
  `docs/analyses/uc-status-uc<n>.html`, rendered by the analyses publish); a Use cases & delivery
  member, beside Use cases and Polling.

### Page mechanisms (available to every report)

Introduced by the CFT to ST delay report (removed 2026-08-29 on request): `topsel=` and
`period=` (both REMOVED 2026-09-29 — no writer emitted them any more), and
**DATE-AWARE STAT cards** — a STAT line's cells 4+ may carry `@data:NAME=VALUE` (render_rpt.awk
emits them as `data-NAME` on the box; the first PLAIN cell >=4 stays the historical `data-pf`
filter key) — report.js `recalcStats` recomputes a `data-tok` box from its `data-sb` per-day
payload on every range change (`sum` · `share` · `maxdur` exact; `p50`/`p90` nearest-rank over
per-day histograms QUANTIZED TO THE humandur DISPLAY GRID, so the shown figure equals the exact
one), retints via `data-thr` (`le:A:B`/`ge:A:B`), and restores the baked value and class at the
full range.

## The boxes sidecar (the Boxes PAGE is gone)

**Subscriptions in boxes** — the page, with Triage beside it — went 2026-09-29 (user request;
the Accounts in boxes twin went the same morning). What stays is its producer:
`bin/analyses/publish-insights.sh` (no argument, sidecar-only) runs `_subs_box_rows` — the
`<box>⇥<subscription>` memberships over the same sources the page used (a report's own `.rpt`:
from-green-to-red, went-kaput, only-red, no-remote-dir/-files, missing-cronjobs, deploy-errors,
went-quiet, site-failures; derived from `_files.tsv`: One-legged, Waiting, Expired; the coverage
seen flag and the result colours) — and `_write_box_reason_sidecar` turns them into
`data/analyses/reports/_subs-boxes.tsv`, the most specific box per red subscription: the
Entities Subscriptions Error view's Reason (after the flow's own error page and its connected
rings, see CLAUDE.md "The home page"). The **connection** box (site-failures) keeps the
one-legged UNRESOLVED rule — cleared only by an OK File LATER than the failure instant. Any
account join is `xref/_subscriptions-accounts.tsv` and ONLY that. report.js's `setupStatFilter`
/ `data-pf` machinery stays for the other STAT-filter tables.
