#!/usr/bin/env bash
#
# details.sh — per-entity detail data files.
#
# For each entity of SEVEN types (account / subscription / login / remote host
# / partner / application / domain) one descriptor is written:
#   data/details/<sub>/<slug>.rpt   ->  docs/details/<sub>/<slug>.html
# EVERY name from data/flow-manager/base/ (all lists except _white.tsv) gets a
# page — seen in the logs or not — plus every logged entity. The page slug
# carries the entity's configured DIRECTION: <name-slug>-IN/-OUT/-BOTH/-UNKNOWN
# (UNKNOWN = unconfigured or unclassified), and _slugmap.tsv maps EVERY name to
# its slug (not just collisions), so every consumer links through the map.
# The page body is tinted by direction + seen-ness (META dirclass -> a body
# class, style.css). On a direction=both page, a TABLE whose rows carry both
# directions splits Error/OK into four columns
# (In Error / In OK / Out Error / Out OK) by each File's own direction
# (_files.tsv col 16; files with no direction stay in Files/Volume only);
# a table whose data is all one-way keeps the plain Error/OK pair.
# Every table on a page — activity, dimension breakdowns, largest — counts
# Files, mirroring the entity list reports: distinct Files per entity
# (account/partner/application/domain via _files.tsv; login/site/host
# via _transfers.tsv JOIN _files.tsv deduped per (entity,CoreId)), delivered
# outcome, volume file-once, drill = CoreId.
# Unit-independent header extras appear on every page: processed-row
# performance and the raw IP(s) behind a resolved hostname (the session count
# and the account server-mention count lost their renderers and are gone).
#
# Each page also opens with a KPI INTRO, Activity per day / week / hour / weekday,
# per-dimension breakdowns of every OTHER dimension, and the 10 largest Files.
#
# PERFORMANCE (2026-07, three rounds):
# 1. every per-entity lookup (xref pairs, base results, MOVMAP, ONE/SITE dims,
#    slugs, 1-to-1 server caches, banner dates) is precomputed by ONE awk
#    ANNOTATION PASS over the sorted agg stream (was ~30k+ lookup forks
#    ≈ 3.5 min);
# 2. the head merged into TWO stream traversals (PASS A dims + PASS B
#    annotation/drop/split) over a temp file — no bash-variable copies;
# 3. the WRITER is bin/transfer/details_writer.awk, one awk per entity type
#    over the per-type slices: the former bash loop forked $(printf …) per
#    dimension row, ran ~11 cat/sort/awk per page for the server-log table
#    and reopened the .rpt for every appended line (~44 s of a 59 s run in
#    the kernel); the awk builds each page in memory and writes it once.
# A full acceptance run: 3.5 min -> ~59 s -> ~30 s. Extend the annotation
# line / the writer awk; never reintroduce per-entity shell work.
#
# Usage:
#   ./details.sh    # reads input/*.csv (via the caches), writes data/details/**
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/uc-cases.sh"   # uc_meta(): the shared UC<n> description
source "$ROOT/bin/logons.sh"     # ensure_logons(): the per-login logon summary
source "$SCRIPT_DIR/../details_lib.sh"   # the rendering machinery (every helper the writer loop calls)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
STAMP="$REPORTS_DIR/details/.stamp"
# the shared scripts details.sh USES (the Subscription Summary's cron schedule +
# UC-case text) are dependencies too — a change to either must re-trigger a rebuild.
# the base result caches are DEPS: the pages bake the entity tints/directions,
# so a recolor (bin/build/seen-in-server-log.sh blue marking, bin/build/result.sh) must retrigger
# the detail build. The WHOLE base/ tree, not a representative: every writer is
# cmp-guarded per file, so a recolor confined to e.g. _logins.tsv or _white.tsv
# leaves the other files' mtimes untouched — a representative would miss it.
# the server per-name caches are DEPS too: the "Last server log messages" table
# + the after-last-transfer banner read them (incl. the <name>_err_warn.tsv
# rings), so a server (re)parse must retrigger the detail build. bin/server/
# parse.sh rewrites the five mention caches with their per-name dirs in ONE pass,
# so one representative suffices.
# _srvsubs-map.tsv is a dep too (2026-08): the SITE pages re-emit the server-
# failing error pages as their "Server log error" section, and failed.sh
# writes the map AFTER details.sh in the report phase — without the dep, the
# SECOND build of a fresh estate skipped details and the section never
# appeared (the map is cmp-guarded and carries the evidence stamp, so its
# mtime moves exactly when the evidence does).
skip_if_fresh "$STAMP" "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../details_lib.sh" "$SCRIPT_DIR/../details_writer.awk" \
    "$ROOT/bin/cron2human.awk" "$ROOT/bin/uc-cases.sh" \
    "$CONFIG_BASE" \
    "$SERVER_CACHE/_accounts.tsv" \
    "$REPORTS_DIR/_srvsubs-map.tsv"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', building per-entity detail files..." >&2

ensure_config   # the base lists drive the direction suffixes + config-only pages

ACC_DIR="$REPORTS_DIR/details/accounts"
SITE_DIR="$REPORTS_DIR/details/subscriptions"
LOGIN_DIR="$REPORTS_DIR/details/logins"
HOST_DIR="$REPORTS_DIR/details/hosts"
PTN_DIR="$REPORTS_DIR/details/partners"
APP_DIR="$REPORTS_DIR/details/applications"
DOM_DIR="$REPORTS_DIR/details/domains"
# Optional CLI argument: narrow the run to ONE type (ACC SITE LOGIN HOST
# PTN APP DOM) — only that type's dir is cleared and rewritten; the shared
# prep still runs in full (it is what the writer consumes).
ONLY_TYPE="${1:-}"
for _spec in "ACC:$ACC_DIR" "SITE:$SITE_DIR" "LOGIN:$LOGIN_DIR" "HOST:$HOST_DIR" \
             "PTN:$PTN_DIR" "APP:$APP_DIR" "DOM:$DOM_DIR"; do
    _d=${_spec#*:}
    mkdir -p "$_d"
    if [ -z "$ONLY_TYPE" ] || [ "${_spec%%:*}" = "$ONLY_TYPE" ]; then
        rm -f "$_d"/*.rpt "$_d"/_slugmap.tsv
        # the slugmap must EXIST even for a type with ZERO entities
        # (production 2026-08: no hosts at all): render_rpt's slug_for
        # treats a mapless dir as "not built yet" and falls back to
        # slugify(), fabricating links to pages that do not exist — an
        # EMPTY map says "comprehensive, nothing has a page" instead
        : > "$_d"/_slugmap.tsv
    fi
done


# ONE scratch dir for every intermediate of this run (2026-07 head merge):
# the side inputs, the sorted stream, the pass-A/B map files and the per-type
# slices all live here, cleaned by a single trap.
_pdir=$(mktemp -d "${TMPDIR:-/tmp}/axdet.XXXXXX")
trap 'rm -rf "$_pdir"' EXIT

# Optional side inputs for the KPI line, fed to the aggregations as extra files
# (each starts with a "#" sentinel so an empty input cannot shift awk file counting):
#  - endpoint -> raw IP map (input/<env>/ip/ip-hosts.tsv, columns swapped)
IPMAP="$_pdir/ipmap"
{
    printf '#\t#\n'
    # keys lowercased to match the cache host values (endpoints are canonically lowercase)
    if [ -f "$IP_HOSTS_FILE" ]; then
        awk -F'\t' '$1 != "" && $2 != "" { print tolower($2) "\t" $1 }' "$IP_HOSTS_FILE"
    fi
} > "$IPMAP"
# (the ACCTSRV account -> server-mention count side input was REMOVED 2026-07:
# its 0/5 stream section fed only x_srv, which lost its renderer when the
# Metrics table went. The server per-name caches still feed the "Last server
# log messages" tables, so the skip_if_fresh dep on the server cache stays.)

# ---------------------------------------------------------------------------
# The aggregation emits this line protocol, sorted once:
#   TYPE  ENTITY  SECTION  SORTKEY  payload...
# SECTION 0 = header data (no table), by SORTKEY:
#   0 totals: recs failed processed humanVol first last pct share rank ntype
#             activedays mediangap idledays fi pi fo po largest avgsz srank
#             erank duravg sshare (share = Files %, sshare = Volume % of type)
#   1 perf (processed rows with a duration): "n|avg|p50|p95|max|thr"  (unit-independent)
#   3 raw IP behind a resolved hostname (HOST)                        (unit-independent)
#   (sortkey 5 — the ACC server-log mention count — was removed 2026-07:
#   nothing rendered it since the Metrics table went)
# SECTION 1 = per-day row; 10 = by weekday; 11 = by hour (the two load tables
#   render SIDE BY SIDE via the sxs modifier, weekday first; the per-ISO-week
#   Activity per week table — section 12 — was removed 2026-07).
# Dimension breakdowns (each page omits its own): 2 subscription (the Login
#   dim table was removed 2026-07 — the Account table Login column covers it) ·
#   4 remote-host · 12.6 store-and-forward dwell
#   (the dwell-time.sh distribution per entity; the Protocol/AV Scan dims
#   were removed 2026-07; the 7 secparams Security table too) · 13 direction ·
#   15 mode · 2.8 account · 2.81 domain · 2.82
#   application · 2.83 partner (the PDA dims — single-value ones fold into
#   Features EXCEPT on PARTNER pages, whose Domain/Application ALWAYS render
#   as own tables listing all config-connected values via insert_config_rows;
#   the Groups fact table is gone; the page order:
#   Subscription comes FIRST after the day table; Account renders right under
#   the Outgoing connections table (sec 2.8, moved from the bottom 2026-07);
#   the PDA dims follow right under the Account table — renumbered 20/21/22
#   -> 2.81/2.82/2.83 in 2026-07). Rows: value count
#   failed processed vol, sortkey=inv(count). The ENTITY sections (2/3/4/2.8/19)
#   are cross-referenced against the FlowManager config (insert_config_rows):
#   the configured-but-never-logged partners are appended as red 5-field rows
#   and every row carries @data:seen, so the seenrows tables tint by
#   data-presence (green logged / red config-only; the former client-side
#   All/Seen/Not seen filter was removed 2026-07 — the tint alone remains).
# SECTION 9 = the latest Files (newest first; 500 on SITE, 100 on the other
#   types — see details_lib.sh addbig), payload pipe-joined
#   (date-time|file|coreid|size|dur|thr|direction|outcome). Sorts after the
#   entity dims so the table renders right above the Load by weekday table
#   (renumbered from 2.5 in 2026-07);
#   Direction = the FILE MOVEMENT (Inbound/Outbound/Relay — which way the FILE
#   travels, from the file subscription's scan_dir/target config via flowd[]),
#   NOT the connection direction.
# SECTION 17 = the whitelisted IPs allowed for the entity (the partner AllowIP
#   whitelist joined via bin/flow-manager.sh's *-white caches) — configuration, not
#   activity, so it is unit-independent and not date-aware. Rows: IP.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Writer: bin/transfer/details_writer.awk streams each per-type slice, one
# .rpt per entity, table per section. The file is created LAZILY so the
# section -1 direction line — which sorts first — can name it. EVERY name is
# recorded in _slugmap.tsv (the map is comprehensive, not just collisions),
# so every consumer resolves links through it. On a direction=both page
# (BOTHMODE) each outcome section is buffered and renders as four columns
# only when its rows carry both directions (TMODE). The whole page is built
# in memory and written with ONE open/write/close.
# ---------------------------------------------------------------------------

# (whitelist_rows — the 2.6/2.7 section producer — now runs INSIDE the
# concurrent producer group below instead of blocking here first)

# The Groups table: each entity's Domain / Application / Partner attribution
# from the xref caches (one combined map, one lookup per page). The PDA pages
# (partner/application/domain) are included too — each gets the OTHER two
# dimensions (the self-dimension xref file, e.g. _apps-apps.tsv, does not exist,
# so the -f guard skips it). "TYPE<TAB>name<TAB>label<TAB>group".
grpmap=$(
    for _gspec in "ACC:accounts" "SITE:subscriptions" "LOGIN:logins" "HOST:hosts" \
                  "PTN:partners" "APP:apps" "DOM:domains"; do
        _gt=${_gspec%%:*}; _git=${_gspec#*:}
        for _gg in domains:Domain apps:Application partners:Partner; do
            _gf="$CONFIG_XREF/_${_git}-${_gg%%:*}.tsv"
            if [ -f "$_gf" ]; then
                LC_ALL=C awk -F'\t' -v t="$_gt" -v lbl="${_gg#*:}" -v OFS='\t' '$1 != "" && $2 != "" { print t, $1, lbl, $2 }' "$_gf"
            fi
        done
    done
)

# (the writer labels — cntlabel "Files", the Latest-100 File column — are
# constants inside details_writer.awk now)
# Per-subscription FILE-MOVEMENT direction (scan_dir=out / target_working_dir=in /
# else relay), keyed by subscription name (upper) — the bin/flow-manager.sh
# cache xref/_subscriptions-flowdir.tsv (the same source parse.sh joins into
# _files.tsv col 17 movement). The Latest-Files table's Direction column means
# the FILE movement — a file's own subscription decides which way the FILE
# travels, NOT the connection direction. aggregate_files reads this in BEGIN
# via getline; a missing cache -> empty (-).
mkdir -p "$REPORTS_DIR/details"
# Movement map for the title prefix (ensure_file's YYY): one row per
# TYPE<TAB>name<TAB>in|out|both — the union of the entity's connected
# subscriptions' file-movement directions (the _<item>-subscriptions xref
# pairs joined on _subscriptions-flowdir; a relay subscription moves files
# BOTH ways). SITE rows carry each configured subscription's own flowdir.
# Emission order is hash order, but the map is a lookup file (one row per
# key), so no output depends on it.
MOVMAP="$_pdir/movmap"
movsrc=()
if [ -f "$CONFIG_XREF/_subscriptions-flowdir.tsv" ]; then
    movsrc=("$CONFIG_XREF/_subscriptions-flowdir.tsv")
    for _mf in accounts logins hosts partners apps domains; do
        [ -f "$CONFIG_XREF/_${_mf}-subscriptions.tsv" ] && movsrc+=("$CONFIG_XREF/_${_mf}-subscriptions.tsv")
    done
fi
if [ ${#movsrc[@]} -gt 0 ]; then
    LC_ALL=C awk -F'\t' '
        function pr(t,   k, d) {
            k = t SUBSEP toupper($1)
            d = fd[toupper($2)]
            if (d == "relay") { mi[k] = 1; mo[k] = 1 }
            else if (d == "in") mi[k] = 1
            else if (d == "out") mo[k] = 1
            if (!(k in nm)) nm[k] = $1
        }
        FILENAME ~ /_subscriptions-flowdir\.tsv$/ { fd[toupper($1)] = $2; sn[toupper($1)] = $1; next }
        FILENAME ~ /_accounts-subscriptions\.tsv$/  { pr("ACC"); next }
        FILENAME ~ /_logins-subscriptions\.tsv$/    { pr("LOGIN"); next }
        FILENAME ~ /_hosts-subscriptions\.tsv$/     { pr("HOST"); next }
        FILENAME ~ /_partners-subscriptions\.tsv$/  { pr("PTN"); next }
        FILENAME ~ /_apps-subscriptions\.tsv$/      { pr("APP"); next }
        FILENAME ~ /_domains-subscriptions\.tsv$/   { pr("DOM"); next }
        END {
            for (k in nm) { split(k, a, SUBSEP)
                v = (mi[k] && mo[k]) ? "both" : (mi[k] ? "in" : (mo[k] ? "out" : ""))
                if (v != "") print a[1] "\t" nm[k] "\t" v }
            for (u in fd) { v = fd[u]; if (v == "relay") v = "both"
                if (v != "") print "SITE\t" sn[u] "\t" v }
        }
    ' "${movsrc[@]}" > "$MOVMAP"
else
    : > "$MOVMAP"
fi
# The files aggregation emits only unit-specific sections; the unit-independent
# header extras (perf/ip/server-mentions) merge in from compute_extras,
# the whitelist section joins the stream, and direction_rows contributes one
# sec -1 line per (logged-or-configured) entity — the config-only names enter
# the stream through those lines and materialize as never-seen pages.
# The four stream producers run CONCURRENTLY (2026-07): aggregate_files is a
# full pass over both caches (166 MB + 35 MB) while compute_extras,
# direction_rows and whitelist_rows read the same data again for their own
# sections — running them one after another left this whole head single-core.
# They write to temp files and the sort consumes all four; the sort key makes
# the result order-independent (each producer owns disjoint sections, and
# within section 0 disjoint sortkeys), so the stream is byte-identical either
# way. The three STREAM-INDEPENDENT side extractions overlap them too
# (2026-07 head merge — they used to run sequentially after the sort): the
# per-subscription cron schedule and locations (jq over subscriptions.json)
# and the File Maintenance "Deleted files" scan (one grep over the server
# parse cache). Each writes a $_pdir file; a missing tool/export/cache leaves
# it empty, exactly like the empty-var fallback these replaced.
S_JSON="$FM_INPUT_DIR/subscriptions.json"
_ppids=()   # every producer's PID — the per-PID wait below collects their rcs
aggregate_files  > "$_pdir/agg0" & _ppids+=($!)
compute_extras   > "$_pdir/xtra" & _ppids+=($!)
direction_rows   > "$_pdir/dirs" & _ppids+=($!)
# the `|| true` is LOAD-BEARING: whitelist_rows used to run inside $(...),
# where bash does NOT inherit errexit, and its internal `[ ... ] && ...`
# tails return 1 on the quiet path — as a plain background job set -e would
# kill it before the first output line. The || list disables errexit inside
# the function body, restoring the old command-substitution semantics.
whitelist_rows   > "$_pdir/wl" || true & _ppids+=($!)
# the polling schedule per subscription (jq + the shared cron translator):
# name -> disp-cron (\x1f-joined lines) -> human. Graceful if jq/export absent.
{
    if command -v jq >/dev/null 2>&1 && [ -f "$S_JSON" ]; then
        jq -r '.[] | . as $s
            | (["sftp","ftp"][] as $p
               | ($s.parameters["hybrid_partner_\($p)_relay0_receive_scheduler_cron_expression"]) as $c
               | select($c != null and $c != "")
               | [ $s.name, $c ] | @tsv)' "$S_JSON" 2>/dev/null \
            | awk -F'\t' -v CF=2 -f "$ROOT/bin/cron2human.awk" || true   # -> name \t disp-cron \t human
    fi
} > "$_pdir/sitecron" & _ppids+=($!)
# each subscription's LOCAL (SecureTransport) + REMOTE (partner) directory and
# their file filter/mask, from subscriptions.json — the Features "Local/Remote
# location" rows. join("\t") keeps the Windows-path backslashes literal (@tsv
# would double them). Fields: name, flowdir (out/in/relay, from scan_dir vs
# target_working_dir), local, localMask, remote, remoteMask; the mask sits on the
# PICKUP side (local for outbound, remote for inbound pull).
# fidsub/psub: resolve the TEMPLATE PLACEHOLDERS the location paths carry —
# {{subscription.parameters.customAttribute_FlowIdentifier}} to the
# subscription's own FlowIdentifier and {{subscription.participant.name}}
# to its non-APPLICATION participant's name (the account — the same rule
# the parse fallback uses); both from the same export object. The
# detail-page From/To rows then show the real path, and every downstream
# consumer of those rows (sources-and-targets, the Search page's
# Source/Target rows) inherits the resolution.
{
    if command -v jq >/dev/null 2>&1 && [ -f "$S_JSON" ]; then
        jq -r '
            def nz(v): if (v|type=="string") and (v|length>0) then v else null end;
            .[] | .parameters as $p
            | (nz($p.customAttribute_FlowIdentifier) // "") as $fid
            | ((([.participants[]? | select((((.context.participantType // "")|ascii_downcase)|contains("application"))|not) | .name] | first)
                // ([.participants[]?.name] | first) // "")) as $pn
            | def fidsub: if $fid == "" then .
                  else gsub("\\{\\{subscription\\.parameters\\.customAttribute_FlowIdentifier\\}\\}"; $fid) end;
              def psub: if $pn == "" then .
                  else gsub("\\{\\{subscription\\.participant\\.name\\}\\}"; $pn) end;
              [ .name,
                (if nz($p.source_folder_monitoring_scan_dir) then "out"
                 elif nz($p.target_working_dir) then "in" else "relay" end),
                ((nz($p.source_folder_monitoring_scan_dir) // nz($p.target_working_dir) // "") | fidsub | psub),
                ((nz($p.source_folder_monitoring_file_include_filter) // "") | fidsub | psub),
                ((nz($p.hybrid_partner_sftp_relay0_send_remote_directory)
                 // nz($p.hybrid_partner_ftp_relay0_send_remote_directory)
                 // nz($p.hybrid_partner_sftp_relay0_receive_remote_directory)
                 // nz($p.hybrid_partner_ftp_relay0_receive_remote_directory)
                 // nz($p.relay0_receive_remote_directory) // "") | fidsub | psub),
                ((nz($p.hybrid_partner_sftp_relay0_receive_file_filter_expression)
                 // nz($p.hybrid_partner_ftp_relay0_receive_filefilter_expression)
                 // nz($p.relay0_receive_file_filter_expression) // "") | fidsub | psub) ]
            | join("\t")' "$S_JSON" 2>/dev/null || true
    fi
} > "$_pdir/siteloc" & _ppids+=($!)
# Files staged for a partner but never collected: the server log's File
# Maintenance "Deleted files [/f1, /f2]" lines, extracted ONCE (one grep over the
# server cache) into "ACCOUNT(upper)<TAB>filename<TAB>expiry-date" rows, looked up
# per Account page by uncollected_files_table. Empty without a server cache.
{
    if [ -s "$SERVER_CACHE/_parse.tsv" ]; then
        LC_ALL=C grep -a 'Deleted files \[/' "$SERVER_CACHE/_parse.tsv" 2>/dev/null | awk -F'\t' '
            { if (!match($5, /[A-Za-z0-9_.-]+@FE[0-9]+/)) next
              a=substr($5,RSTART,RLENGTH); sub(/@.*/,"",a); a=toupper(a)
              if (!match($5, /Deleted files \[[^]]*\]/)) next
              c=substr($5,RSTART+15,RLENGTH-16); n=split(c,z,", ")
              for(i=1;i<=n;i++){ f=z[i]; sub(/^\//,"",f); gsub(/^ +| +$/,"",f); if(f!="") print a "\t" f "\t" $1 } }' || true
    fi
} > "$_pdir/uncollected" & _ppids+=($!)
# Per-PID wait — a bare `wait` swallows child exit codes, so a producer dying
# mid-write would hand the writers truncated prep files WITH success status
# and the truncation would be baked into the detail .rpts as fresh. Collect
# every rc and fail loudly instead (the writer pool below already does this).
_prc=0
for _pp in "${_ppids[@]}"; do wait "$_pp" || _prc=$?; done
if [ "$_prc" -ne 0 ]; then
    echo "details.sh: a prep producer failed (exit $_prc) — aborting before the writers run." >&2
    exit "$_prc"
fi
sort -t$'\t' -k1,1 -k2,2 -k3,3n -k4,4 -k5,5 "$_pdir/agg0" "$_pdir/xtra" "$_pdir/dirs" "$_pdir/wl" \
    | insert_config_rows > "$_pdir/agg"

# ACCOUNT TWINS: two accounts whose names differ only in "-" vs "_" are DIFFERENT
# entities (see CLAUDE.md — separator folding is never an identity rule), but each
# one is worth naming on the other page, so the Features table gets a "Twin" row.
# The account universe is the ACC entities of the stream itself — exactly the set
# that gets a page, so a Twin row always has somewhere to link. One line per
# account: "<name>\t<other spelling>[\x1f<other spelling>…]", sorted so the map
# never depends on awk hash order.
awk -F'\t' '$1 == "ACC" { print $2 }' "$_pdir/agg" | LC_ALL=C sort -u \
  | awk -v OFS='\t' '
        { k = toupper($0); gsub(/_/, "-", k)
          NM[k] = (NM[k] != "" ? NM[k] "\037" : "") $0; N[k]++ }
        END { for (k in N) { if (N[k] < 2) continue
                  n = split(NM[k], V, "\037")
                  for (i = 1; i <= n; i++) { o = ""
                      for (j = 1; j <= n; j++) if (j != i) o = o (o == "" ? "" : "\037") V[j]
                      print V[i], o } } }' \
  | LC_ALL=C sort > "$_pdir/twins"

# SUBSCRIPTION TWINS: one logical flow is commonly configured as TWO subscriptions,
# one per file-movement direction, spelled differently (different UC number, and
# often "-" where the other has "_"). Each is worth naming on the other page for
# the same reason the account twin is. Two rules, UNIONed; same output format as
# the account map above, so the writer treats them identically.
#
#   A: the subscription's connected ACCOUNT has a separator twin, and BOTH accounts
#      have exactly ONE subscription -> those two subscriptions are twins. The
#      account is resolved through the xref, NEVER by name: the subscription name
#      ends with its account name on 523 of 526 configured pairs, and the separator
#      style disagrees on 2 more, so a name join would be wrong on five flows.
#      A subscription with TWO accounts (the UC5/UC8 relays, _SRC + _DEST) is
#      skipped -- "the connected account" is not defined for it.
#   B: strip the leading UC<n>_, fold "-" onto "_", and the names are equal, with
#      one side INCOMING (UC3/UC4) and the other OUTGOING (UC1/UC2). The UC number
#      is the side test because this is a rule about the NAME; it agrees with
#      xref/_subscriptions-flowdir.tsv on 523 of 524 subscriptions, and the one
#      disagreement is a singleton under normalization, so it is in no group either.
#   C: the same ACCOUNT carries both a UC2 (partner collects) and a UC4 (partner
#      delivers) subscription -> the pair are twins regardless of name (2026-08):
#      the one FE connection serves both directions of that partner's mailbox —
#      the very fact the Twin row surfaces. Catches the pairs rule B misses on a
#      naming slip (an FI/FE swap, an abbreviated body); resolved through the
#      xref, never by name, like rule A. The OUTBOUND mirror is included only as
#      an EXACT pair — an account whose two subscriptions are one UC1 and one
#      UC3 and nothing else: outbound accounts can fan out to dozens of flows,
#      where same-account pairing would link every UC1 with every UC3, but the
#      exact pair is as unambiguous as the mailbox case.
#
# No rule can pair two subscriptions on the SAME side, and the relation is
# symmetric by construction. All are verified after a run (see CLAUDE.md).
_twf="$_pdir/twins"
_asf="$CONFIG_XREF/_accounts-subscriptions.tsv"; [ -f "$_asf" ] || _asf=/dev/null
_saf="$CONFIG_XREF/_subscriptions-accounts.tsv"; [ -f "$_saf" ] || _saf=/dev/null
_bsf="$CONFIG_BASE/_subscriptions.tsv";          [ -f "$_bsf" ] || _bsf=/dev/null
awk -F'\t' -v OFS='\t' -v TWF="$_twf" -v ASF="$_asf" -v SAF="$_saf" -v PF="$_pdir/twins-pairs" '
    FILENAME == TWF { i = index($0, "\t")                    # account -> twin account(s)
                      if (i > 1) TWA[substr($0, 1, i - 1)] = substr($0, i + 1); next }
    FILENAME == ASF { NSUB[$1]++; SUB1[$1] = $2                # account -> #subs, and the last one
                      if (ASUB[$1] == "") AORD[++naord] = $1   # (emptiness test — see the SACC note)
                      ASUB[$1] = (ASUB[$1] == "" ? "" : ASUB[$1] "\037") $2; next }
    # NOTE the emptiness test, NOT (k in SACC): mawk instantiates the LEFT
    # subscript before evaluating the right side, so a membership test is true
    # on the FIRST insert and every value would carry a leading separator.
    FILENAME == SAF { SACC[$1] = (SACC[$1] == "" ? "" : SACC[$1] "\037") $2; next }   # sub -> account(s)
    { SUBS[$1] = 1 }                                          # base/_subscriptions.tsv: the universe
    # r = the detecting rule letter (A/B/C), accumulated per ORDERED pair for
    # the persisted pair map (the Twins analysis) — dedup per letter
    function addtwin(a, b, r) { if (a == "" || b == "" || a == b) return
                                if (!((a, b) in SEEN)) { SEEN[a, b] = 1; T[a] = T[a] (T[a] == "" ? "" : "\037") b }
                                if (index(RT[a, b], r) == 0) RT[a, b] = RT[a, b] r }
    function side(n,   u) { if (!match(n, /^UC[0-9]+[-_]/)) return ""
                            # ([-_]: the synthetic monitor spells its prefixes
                            # with a dash — 2026-08, so its pairs earn rule B
                            # like everything else)
                            u = substr(n, 3, RLENGTH - 3) + 0
                            if (u == 1 || u == 2) return "out"
                            if (u == 3 || u == 4) return "in"
                            return "" }
    function body(n) { sub(/^UC[0-9]+[-_]/, "", n); gsub(/-/, "_", n); return toupper(n) }   # [-_]: the monitor names spell the prefix with a dash
    END {
        for (s in SUBS) {
            # --- rule A ---
            if ((s in SACC) && index(SACC[s], "\037") == 0) {
                a = SACC[s]
                if (NSUB[a] == 1 && (a in TWA)) {
                    n = split(TWA[a], V, "\037")
                    # a twin is the same flow configured the OPPOSITE way, so the
                    # two subs must be opposite-side (out vs in) — two same-side
                    # flows on spelling-twin accounts (e.g. UC3+UC4, both incoming)
                    # are NOT twins even though the accounts are spelling twins
                    for (i = 1; i <= n; i++) if (NSUB[V[i]] == 1) {
                        oth = SUB1[V[i]]
                        if (side(s) != "" && side(oth) != "" && side(s) != side(oth)) addtwin(s, oth, "A")
                    }
                }
            }
            # --- rule B ---
            k = body(s); GK[k] = GK[k] (GK[k] == "" ? "" : "\037") s
        }
        for (k in GK) { n = split(GK[k], V, "\037")
            for (i = 1; i <= n; i++) for (j = 1; j <= n; j++) {
                if (i == j) continue
                si = side(V[i]); sj = side(V[j])
                if (si != "" && sj != "" && si != sj) addtwin(V[i], V[j], "B") } }
        # --- rule C --- walked in ASF FILE order (AORD), never hash order, so
        # a multi-account subscription accumulates its twins deterministically
        for (ai = 1; ai <= naord; ai++) {
            n = split(ASUB[AORD[ai]], V, "\037")
            for (i = 1; i <= n; i++) for (j = 1; j <= n; j++) {
                if (i == j) continue
                if (V[i] ~ /^UC2/ && V[j] ~ /^UC4/) { addtwin(V[i], V[j], "C"); addtwin(V[j], V[i], "C") }
                # the outbound mirror: ONLY as the account'\''s exact pair
                if (n == 2 && V[i] ~ /^UC1/ && V[j] ~ /^UC3/) { addtwin(V[i], V[j], "C"); addtwin(V[j], V[i], "C") }
            }
        }
        for (s in T) print s, T[s]
        # every ORDERED pair with its rule letters, for the persisted pair
        # map below (hash order here — the shell sorts)
        for (k in SEEN) { split(k, P2, SUBSEP); print "P", P2[1], P2[2], RT[P2[1], P2[2]] > PF }
        close(PF)
    }' "$_twf" "$_asf" "$_saf" "$_bsf" \
  | LC_ALL=C sort > "$_pdir/twins-site"

# ---- persist the twin PAIR maps (the Twins analysis reads them) --------------
# Unordered pairs, each once, the rule letters of both directions unioned in
# fixed A/B/C order; cmp-guarded so an unchanged map keeps its mtime (the
# details tree is a freshness dep of entity-search and publish-details).
# if/fi, NOT a `[ -f ] &&` guard: with zero twin pairs the pairs file never
# exists, the && list would exit 1 and pipefail would kill the whole script
if [ -f "$_pdir/twins-pairs" ]; then
    awk -F'\t' -v OFS='\t' '
        { a = $2; b = $3; r = $4
          if (b < a) { t = a; a = b; b = t }
          k = a SUBSEP b
          if (RU[k] == "") O[++n] = k                       # emptiness test, not membership (mawk)
          s2 = RU[k] r; nr = ""
          if (index(s2, "A")) nr = "A"
          if (index(s2, "B")) nr = nr "B"
          if (index(s2, "C")) nr = nr "C"
          RU[k] = nr }
        END { for (i = 1; i <= n; i++) { split(O[i], P2, SUBSEP); print P2[1], P2[2], RU[O[i]] } }
    ' "$_pdir/twins-pairs"
fi | LC_ALL=C sort > "$_pdir/_twins-subscriptions.tmp"
awk -F'\t' -v OFS='\t' '
    { n = split($2, V, "\037")
      for (i = 1; i <= n; i++) { a = $1; b = V[i]; if (b < a) { t = a; a = b; b = t }; print a, b } }
' "$_twf" | LC_ALL=C sort -u > "$_pdir/_twins-accounts.tmp"
for _tw in _twins-subscriptions _twins-accounts; do
    if cmp -s "$_pdir/$_tw.tmp" "$REPORTS_DIR/details/$_tw.tsv" 2>/dev/null; then :
    else cp "$_pdir/$_tw.tmp" "$REPORTS_DIR/details/$_tw.tsv"; fi
done
# (the writer reads $_pdir/uncollected directly — no UNCOLLECTED variable)
# --- Subscription (SITE) detail pages only: fold Remote host / Account / Login
# into the Summary and add the polling schedule. Account (2.8) comes
# from the agg stream; the Login (3) and Remote host (4)
# dims are no longer emitted by aggregate_files, so those two are joined from
# the CONFIG xref pairs (_subscriptions-logins/-hosts, the showseen prefix
# rule) instead. Other entity types are untouched.
# PASS A (2026-07 head merge): SITE_DIMS + ONE_DIMS computed in ONE read of
# the sorted stream FILE — they were two separate full-stream awk passes over
# a bash variable holding the whole stream. The two aggregations are
# independent; the ONE_DIMS arrays carry an od prefix so the programs cannot
# collide, and rule ORDER keeps the original semantics (a `next` in the SITE
# rule only skips lines the ONE_DIMS rule could never match — $1=="SITE" is
# excluded there for sections 3/2.8, and no SITE 2.81-2.83 rows exist).
awk -F'\t' \
    -v XL="$CONFIG_XREF/_subscriptions-logins.tsv" -v XH="$CONFIG_XREF/_subscriptions-hosts.tsv" \
    -v SDOUT="$_pdir/sitedims" -v ODOUT="$_pdir/onedims" '
    BEGIN{ US=sprintf("%c",31)
        while ((getline l < XL) > 0) { if (split(l, a, "\t") >= 2 && a[1] != "") { nlg++; lgn[nlg]=toupper(a[1]); lgv[nlg]=a[2] } } close(XL)
        while ((getline l < XH) > 0) { if (split(l, a, "\t") >= 2 && a[1] != "") { nhs++; hsn[nhs]=toupper(a[1]); hsv[nhs]=a[2] } } close(XH)
    }
    $1=="SITE" && ($3==3||$3==4||$3==2.8) && $5!="" {
        e=$2; s=$3; v=$5; k=e SUBSEP s SUBSEP toupper(v)
        if(k in seen) next; seen[k]=1
        if(!(e in eidx)){ eidx[e]=++ne; el[ne]=e }
        lst[e SUBSEP s]=lst[e SUBSEP s] (lst[e SUBSEP s]==""?"":US) v
    }
    $1=="SITE" && !(($2) in eidx) { eidx[$2]=++ne; el[ne]=$2 }   # never-seen pages fold their config rows too
    (($3==2.81 && $1!="PTN" && $1!="APP") || ($3==2.82 && $1!="PTN" && $1!="DOM") || ($3==2.83 && $1!="APP" && $1!="DOM") || (($3==3 || $3==2.8) && $1!="SITE")) && $5!="" {
        odk=$1 SUBSEP $2 SUBSEP $3 SUBSEP toupper($5); if(odk in odseen) next; odseen[odk]=1
        odke=$1 SUBSEP $2 SUBSEP $3; odcnt[odke]++; odval[odke]=$5 }
    END{ for(i=1;i<=ne;i++){ e=el[i]; eu=toupper(e)
        l3=lst[e SUBSEP 3]; l4=lst[e SUBSEP 4]
        for(j=1;j<=nlg;j++) if(index(eu, lgn[j])==1 && !((e SUBSEP 3 SUBSEP toupper(lgv[j])) in seen)){
            seen[e SUBSEP 3 SUBSEP toupper(lgv[j])]=1; l3=l3 (l3==""?"":US) lgv[j] }
        for(j=1;j<=nhs;j++) if(index(eu, hsn[j])==1 && !((e SUBSEP 4 SUBSEP toupper(hsv[j])) in seen)){
            seen[e SUBSEP 4 SUBSEP toupper(hsv[j])]=1; l4=l4 (l4==""?"":US) hsv[j] }
        printf "%s\t%s\t%s\t%s\n", e, l4, lst[e SUBSEP 2.8], l3 > SDOUT }
        for(odke in odcnt) if(odcnt[odke]==1){ split(odke,a,SUBSEP); print a[1] "\t" a[2] "\t" a[3] "\t" odval[odke] > ODOUT } }' \
    "$_pdir/agg"
: >> "$_pdir/sitedims"; : >> "$_pdir/onedims"   # awk creates them lazily; an empty result must still exist
# Single-value fold semantics (the ONE_DIMS half of PASS A above): an Account
# (2.8) or Login (3) breakdown — all non-SITE, a SITE page's own/config
# dimensions are already folded — or a PDA dim with exactly ONE distinct value
# folds into the Features table instead of a one-row table
# ("type<TAB>ent<TAB>section<TAB>value" per such case); the annotation pass
# below drops those section rows, along with the Direction breakdown
# (section 13, its one datum is the Features "Direction" row) and the four
# folded SITE sections (3/4/13/2.8 — now in the Summary). The SUBSCRIPTION
# dimension (section 2) is deliberately NOT folded: the subscription table
# renders on EVERY detail page — seen, not-seen and server-only alike —
# listing the data/flow-manager/xref-configured names.
# (the com-profile Features row and bin/comm-profiles.sh's caches were
# removed 2026-07)
# subscriptions surfaced ONLY by the Server -> Transfer step (result==blue in
# the base cache): their page shows the config-only Summary and a server-log
# intro, no operational tables (they have no real transfer). Because there ARE
# no fake rows any more, a blue entity simply has no content sections — it
# renders as a never-seen page automatically — so no fabricated-data suppression
# is needed; only the four folded SITE sections (now in the Summary) are dropped.
if [ -f "$CONFIG_BASE/_subscriptions.tsv" ]; then
    awk -F'\t' '$3=="blue"{print $1}' "$CONFIG_BASE/_subscriptions.tsv" > "$_pdir/siteblue"
else
    : > "$_pdir/siteblue"
fi
# ===== ANNOTATION PASS (2026-07 fork-elimination) ============================
# ONE awk pass over the sorted agg stream + every per-entity lookup source,
# emitting ONE line per entity IN FIRST-SEEN STREAM ORDER — exactly the order
# the writer loop below switches entities — so the writer reads it
# SEQUENTIALLY (fd 4) instead of forking awk/sort/grep lookups per entity
# (the former ~30k forks that made this script the build's slowest step).
# Field separator \x1e (RS; \x1f stays the intra-field multi-value joiner the
# existing consumers expect). Fields (the fmlink field was DROPPED 2026-07 —
# the 🔗 H1 icon it fed is gone, nothing consumed it):
#  1 type  2 name  3 slug(collision-bumped)  4 mvtok  5 result
#  6 isblue  7 siteblue  8 oneacct  9 onedom 10 oneapp 11 oneptn
# 12 sd_hosts 13 sd_accts 14 sd_logins 15 cron 16 cronh
# 17 flowdir 18 local 19 lmask 20 remote 21 rmask
# 22 cfgacct 23 acct_logins 24 acct_hosts 25 conn1to1-files 26 banner_dt
# 27 grp_rows("Label\tName" \x1f-joined) 28 sub_accts 29 sub_logins 30 sub_hosts
#  31 nosub  32 twin (ACC: the other separator spelling(s) of this name;
#                     SITE: the same flow in the opposite file direction)
# PASS B (2026-07 head merge): the annotation pass ALSO applies the drop
# rules and writes the per-type stream/annotation slices directly — the two
# whole-stream filter passes and the two separate split passes folded in
# here, so the stream is traversed twice in total (PASS A + this) instead of
# six times, and never held in a bash variable. Safe because every entity's
# FIRST stream line is its section -1 direction row (never a dropped
# section), so the first-seen annotation keying is unaffected.
STREAMDIR="$_pdir/streams"
mkdir -p "$STREAMDIR"
printf '%s\n' "$grpmap" > "$_pdir/grpmap"
LC_ALL=C awk -F'\t' \
    -v XREF="$CONFIG_XREF" -v BASE="$CONFIG_BASE" \
    -v ODF="$_pdir/onedims" -v SDF="$_pdir/sitedims" -v CRF="$_pdir/sitecron" \
    -v LCF="$_pdir/siteloc" -v BLF="$_pdir/siteblue" -v GRF="$_pdir/grpmap" \
    -v MOV="$MOVMAP" -v SRV="$SERVER_CACHE" -v FWD="$IP_HOSTS_FILE" -v SDIR="$STREAMDIR" \
    -v TWF="$_pdir/twins" -v TWFS="$_pdir/twins-site" '
    function up(s) { return toupper(s) }
    # endpoint -> its address(es), from input/<env>/ip/ip-hosts.tsv (keyed on its
    # HOST column). Loaded once on first use; replaced a fwd/<name>.txt per endpoint.
    function fwd_ips(h,   l, a, k) {
        if (!FWDL) {
            FWDL = 1
            if (FWD != "") { while ((getline l < FWD) > 0) { split(l, a, "\t")
                    if (a[1] != "" && a[2] != "") FWDM[tolower(a[2])] = FWDM[tolower(a[2])] "\037" a[1] }
                close(FWD) }
        }
        k = tolower(h); return (k in FWDM) ? substr(FWDM[k], 2) : ""
    }

    function slugit(s,   t) { t = tolower(s); gsub(/[^a-z0-9]+/, "-", t); sub(/^-+/, "", t); sub(/-+$/, "", t); if (t == "") t = "_"; return t }
    # sorted-unique join of a \x1f-collected list (byte order, small lists)
    function sortu(s,   a, n, i, j, tv, o) {
        if (s == "") return ""
        n = split(s, a, "\037")
        for (i = 2; i <= n; i++) { tv = a[i]; j = i - 1; while (j >= 1 && a[j] > tv) { a[j+1] = a[j]; j-- } a[j+1] = tv }
        o = ""; for (i = 1; i <= n; i++) if (a[i] != "" && a[i] != a[i-1]) o = o (o == "" ? "" : "\037") a[i]
        return o
    }
    function addu(arr, tag, k, v) { if (!((tag, k, v) in _seenkv)) { _seenkv[tag, k, v] = 1; arr[k] = arr[k] (arr[k] == "" ? "" : "\037") v } }
    function loadmap(f, arr, tag,   l, a2, n) {   # key up($1) -> \x1f values ($2), deduped per map
        while ((getline l < f) > 0) { n = split(l, a2, "\t"); if (n >= 2 && a2[1] != "" && a2[2] != "") addu(arr, tag, up(a2[1]), a2[2]) }
        close(f)
    }
    function firstmap(f, arr, col, pfx,   l, a2, n, k) {   # key pfx+up($1) -> first $col
        while ((getline l < f) > 0) { n = split(l, a2, "\t"); k = pfx up(a2[1]); if (n >= col && a2[1] != "" && !(k in arr)) arr[k] = a2[col] }
        close(f)
    }
    function nonempty(f,   l, r) { r = 0; if ((getline l < f) > 0) r = 1; close(f); return r }
    BEGIN {
        # account name -> its other separator spelling(s), \037-joined (built
        # from the ACC entities of the stream just above); feeds the Features
        # table "Twin" row on the account pages
        if (TWF != "") { while ((getline l < TWF) > 0) { i = index(l, "\t")
                             if (i > 1) TWIN[substr(l, 1, i - 1)] = substr(l, i + 1) }
                         close(TWF) }
        # subscription name -> its twin subscription(s), same format and same
        # Features "Twin" row, built by the two-rule block above
        if (TWFS != "") { while ((getline l < TWFS) > 0) { i = index(l, "\t")
                              if (i > 1) TWINS[substr(l, 1, i - 1)] = substr(l, i + 1) }
                          close(TWFS) }
        # --- lookup preloads (each file read ONCE) --------------------------
        loadmap(XREF "/_logins-accounts.tsv", LA, "LA")
        loadmap(XREF "/_accounts-logins.tsv", AL, "AL")
        loadmap(XREF "/_accounts-hosts.tsv",  AH, "AH")
        loadmap(XREF "/_subscriptions-accounts.tsv", SBA, "SBA")
        loadmap(XREF "/_subscriptions-logins.tsv",   SBL, "SBL")
        loadmap(XREF "/_subscriptions-hosts.tsv",    SBH, "SBH")
        firstmap(BASE "/_accounts.tsv", RES, 3, "ACC|");   firstmap(BASE "/_subscriptions.tsv", RES, 3, "SITE|")
        firstmap(BASE "/_logins.tsv", RES, 3, "LOGIN|");   firstmap(BASE "/_hosts.tsv", RES, 3, "HOST|")
        firstmap(BASE "/_partners.tsv", RES, 3, "PTN|")
        firstmap(BASE "/_apps.tsv", RES, 3, "APP|");       firstmap(BASE "/_domains.tsv", RES, 3, "DOM|")
        # 1-to-1 pair caches: distinct RAW $2 values per up($1), like the old
        # `awk | sort -u` (count in P2N, single value in P2V)
        pt["ACC"] = "accounts"; pt["SITE"] = "subscriptions"; pt["LOGIN"] = "logins"; pt["HOST"] = "hosts"
        nct = split("accounts subscriptions logins hosts", CTL, " ")
        for (p in pt) for (ci = 1; ci <= nct; ci++) {
            if (CTL[ci] == pt[p]) continue
            f = XREF "/_" pt[p] "-" CTL[ci] ".tsv"
            while ((getline l < f) > 0) { n = split(l, a2, "\t")
                if (n >= 2 && a2[1] != "" && a2[2] != "") { k = p "|" CTL[ci] "|" up(a2[1])
                    if (!((k, a2[2]) in p2seen)) { p2seen[k, a2[2]] = 1; P2N[k]++; P2V[k] = a2[2] } } }
            close(f)
        }
        # MOVMAP: exact per (type,upname); SITE rows also kept for the prefix rule
        while ((getline l < MOV) > 0) { n = split(l, a2, "\t"); if (n < 3) continue
            MV[a2[1] "|" up(a2[2])] = up(a2[3])
            if (a2[1] == "SITE") { ns++; MSN[ns] = up(a2[2]); MSV[ns] = up(a2[3]) } }
        close(MOV)
        # the PASS A outputs + the small side maps (files under $_pdir)
        vf = ODF; while ((getline l < vf) > 0)  { n = split(l, a2, "\t"); if (n >= 4) OD[a2[1] "|" a2[2] "|" a2[3]] = a2[4] }
        close(vf)
        vf = SDF; while ((getline l < vf) > 0) { i = index(l, "\t"); if (i > 0) SD[substr(l, 1, i-1)] = substr(l, i+1) }
        close(vf)
        vf = CRF; while ((getline l < vf) > 0) { n = split(l, a2, "\t"); k = up(a2[1]); if (n >= 3 && !(k in CR)) { CR[k] = a2[2]; CRH[k] = a2[3] } }
        close(vf)
        vf = LCF; while ((getline l < vf) > 0)  { i = index(l, "\t"); if (i > 0) { k = up(substr(l, 1, i-1)); if (!(k in LOC)) LOC[k] = substr(l, i+1) } }
        close(vf)
        vf = BLF; while ((getline l < vf) > 0) { if (l != "") SF[up(l)] = 1 }
        close(vf)
        # grpmap -> ordered "Label\tName" rows per (type,upname), _compute_grows order
        vf = GRF; while ((getline l < vf) > 0) { n = split(l, a2, "\t"); if (n < 4) continue
            k = a2[1] "|" up(a2[2]); if ((k, a2[3], a2[4]) in gdup) continue; gdup[k, a2[3], a2[4]] = 1
            o = (a2[3] == "Domain") ? 1 : (a2[3] == "Application") ? 2 : 3
            gc[k, o]++; grows[k, o, gc[k, o]] = a2[3] "\t" a2[4] }
        close(vf)
    }
    # ---- main: first stream line per entity -> one ann line (written to the
    # per-type a.<TYPE> slice); then the drop rules + the per-type s.<TYPE>
    # stream slice for EVERY surviving line ---------------------------------
    {
        key = $1 "|" $2
        if (!(key in done)) {
        done[key] = 1
        t = $1; e = $2; U = up(e); tk = t "|" U
        # slug + collision bump, per type dir (dirs start empty — rm -f above)
        slug = slugit(e); base = slug; bn = 1
        while ((t, base) in sl_seen) { bn++; base = slug "-" bn }
        sl_seen[t, base] = 1
        # mvtok: exact match, else (SITE) the longest configured prefix
        mv = (tk in MV) ? MV[tk] : ""
        if (mv == "" && t == "SITE") { bl = 0; for (i = 1; i <= ns; i++) if (index(U, MSN[i]) == 1 && length(MSN[i]) > bl) { mv = MSV[i]; bl = length(MSN[i]) } }
        resv = (tk in RES) ? RES[tk] : ""
        isblue = (resv == "blue") ? 1 : ""
        sblue = (t == "SITE" && (U in SF)) ? 1 : ""
        # guarded reads — a bare OD[k] would CREATE the key, and the drop
        # rules below test membership in OD (the awk read-creates-key trap)
        k4 = t "|" e "|2.8";  od1 = (k4 in OD) ? OD[k4] : ""
        k4 = t "|" e "|2.81"; od2 = (k4 in OD) ? OD[k4] : ""
        k4 = t "|" e "|2.82"; od3 = (k4 in OD) ? OD[k4] : ""
        k4 = t "|" e "|2.83"; od4 = (k4 in OD) ? OD[k4] : ""
        sdh = ""; sda = ""; sdl = ""; cr = ""; crh = ""
        fdir = ""; lloc = ""; lmask = ""; rloc = ""; rmask = ""
        suba = ""; subl = ""; subh = ""
        if (t == "SITE") {
            if (e in SD) { n = split(SD[e], a2, "\t"); sdh = a2[1]; sda = a2[2]; sdl = a2[3] }
            if (U in CR) { cr = CR[U]; crh = CRH[U] }
            if (U in LOC) { n = split(LOC[U], a2, "\t"); fdir = a2[1]; lloc = a2[2]; lmask = a2[3]; rloc = a2[4]; rmask = a2[5] }
            suba = sortu(SBA[U]); subl = sortu(SBL[U]); subh = sortu(SBH[U])
        }
        cfa = sortu(LA[U] != "" && t == "LOGIN" ? LA[U] : "")
        acl = sortu(t == "ACC" ? AL[U] : ""); ach = sortu(t == "ACC" ? AH[U] : "")
        # 1-to-1 connected server-cache files (connected_1to1_srv port)
        conn = ""
        if (t in pt) for (ci = 1; ci <= nct; ci++) {
            ct = CTL[ci]; if (ct == pt[t]) continue
            k = t "|" ct "|" U
            if (P2N[k] != 1) continue
            v = P2V[k]
            if (ct == "hosts") {
                f = SRV "/hosts/" v ".tsv"; if (nonempty(f)) conn = conn (conn == "" ? "" : "\037") f
                nfw = split(fwd_ips(v), afw, "\037")
                for (fi = 1; fi <= nfw; fi++) if (afw[fi] != "") { f = SRV "/hosts/" afw[fi] ".tsv"; if (nonempty(f)) conn = conn (conn == "" ? "" : "\037") f }
            } else { f = SRV "/" ct "/" v ".tsv"; if (nonempty(f)) conn = conn (conn == "" ? "" : "\037") f }
        }
        # banner: MAX first-line "date time" over own + connected _err_warn files
        bdt = ""
        nb = split(conn, a2, "\037")
        for (i = 0; i <= nb; i++) {
            if (i == 0) { if (t in pt) f = SRV "/" pt[t] "/" e "_err_warn.tsv"; else continue }
            else { f = a2[i]; sub(/\.tsv$/, "_err_warn.tsv", f) }
            if ((getline l < f) > 0) { n = split(l, b2, "\t"); if (n >= 2 && b2[1] " " b2[2] > bdt) bdt = b2[1] " " b2[2] }
            close(f)
        }
        grp = ""
        for (o = 1; o <= 3; o++) for (i = 1; i <= gc[t "|" U, o]; i++) grp = grp (grp == "" ? "" : "\037") grows[t "|" U, o, i]
        # ACCOUNT pages: is this account wired into ANY subscription? P2N counts
        # the distinct _accounts-subscriptions.tsv partners, so 0 means no
        # subscription references it — such an account can never move a file,
        # which is what the config WARN banner in details_writer.awk says. Same
        # condition as the "?" movement side in the title prefix and as the
        # Config hygiene "Account without subscriptions" row.
        # Tested by VALUE (+0), deliberately NOT with `in`: the connected-1to1
        # loop just above does a bare `P2N[k] != 1` read, which INSTANTIATES the
        # key for every (type, list, name) it probes — so by the time we get
        # here a membership test is true for every account and would never fire.
        # A phantom key reads as "" (== 0 numerically), so the value test is
        # correct whether the key was instantiated or not.
        # NOTE this awk program is one SINGLE-QUOTED shell string: no apostrophe
        # may appear here unescaped, or it closes the quote mid-program.
        nosub = (t == "ACC" && P2N[t "|subscriptions|" U] + 0 == 0) ? 1 : ""
        twin = (t == "ACC"  && (e in TWIN))  ? TWIN[e]  : \
               (t == "SITE" && (e in TWINS)) ? TWINS[e] : ""
        af = SDIR "/a." t
        if (af != aprev) { if (aprev != "") close(aprev); aprev = af }
        printf "%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\n", \
            t, e, base, mv, resv, isblue, sblue, od1, od2, od3, od4, sdh, sda, sdl, cr, crh, fdir, lloc, lmask, rloc, rmask, cfa, acl, ach, conn, bdt, grp, suba, subl, subh, nosub, twin > af
        }
        # ---- the drop rules (the two former filter passes) + the s. slice ---
        if ($3 == 13) next
        if ($1 == "SITE" && ($3 == 3 || $3 == 4 || $3 == 2.8)) next
        if (($3 == 3 || $3 == 2.8 || $3 == 2.81 || $3 == 2.82 || $3 == 2.83) && (($1 "|" $2 "|" $3) in OD)) next
        sf = SDIR "/s." $1
        if (sf != sprev) { if (sprev != "") close(sprev); sprev = sf }
        print > sf
    }
' "$_pdir/agg"
NOW_TS=$(date '+%Y-%m-%d %H:%M:%S')

# the shared UC descriptions for the Subscription "Use case" row: dumped from
# bin/uc-cases.sh (the single source of truth) for the awk writer to load
UCMETA="$_pdir/ucmeta"
{ for _u in UC1 UC2 UC3 UC4 UC5 UC6 UC7 UC8; do printf '%s\t%s\n' "$_u" "$(uc_meta "$_u")"; done } > "$UCMETA"
# the DERIVED use case for subscriptions whose NAME carries no UC prefix (the
# production hybrid flows) — derived by bin/flow-manager.sh from the flowdir
# and pattern caches (out+pull = UC2, out+push = UC1, in+push = UC4, in+pull
# = UC3; both/neither partner verb = no row, never a guess)
UCDER="$CONFIG_XREF/_subscriptions-ucderived.tsv"
[ -f "$UCDER" ] || UCDER=/dev/null
# the server-failing subscriptions map (failed.sh: name, errors/ page slug,
# evidence stamp — the REDUCED _srvsubs-map, deliberately without the reason
# column: the reason is what the evidence catch-up rerun changes, and this
# file's stability is what lets the details catch-up skip) — a SITE page in
# it gets the "Server log error" section, re-emitting that errors/<slug>.rpt
# page's server-log table
SRVSUBSF="$REPORTS_DIR/_srvsubs-map.tsv"
[ -f "$SRVSUBSF" ] || SRVSUBSF=/dev/null
# ---- the "Last OK transfer" sidecar (SITE pages) ----------------------------
# Per subscription: the newest PROCESSED File — deliberately NOT the outcome
# policy's OK (2026-08): a UC2 file still Waiting is staged, not transferred,
# and showed 3 staging legs where the reader expects the COMPLETE 4-leg
# transfer with the partner's collect; a flow whose files are all Waiting
# simply has no section — with its transfer LEGS and the server-log lines of its legs
# CONNECTIONS (the session join the errors/ drill pages use: _transfers.tsv
# col 24 and _parse.tsv col 6 carry the same id). details_writer.awk renders
# it as the section directly above "Last server log messages". Rows:
#   F <TAB> site <TAB> file <TAB> date time
#   L <TAB> site <TAB> status..transfer-id   (the errors/ legs columns)
#   S <TAB> site <TAB> date time <TAB> level <TAB> raw line   (newest 40,
#           chronological — sorted desc, capped, re-sorted asc)
#   X <TAB> site <TAB> date time <TAB> level <TAB> raw line   (the newest
#           FAILED File's session lines — NOT rendered: the error page the
#           "Last error" row links shows them, so the writer only SUPPRESSES
#           them, together with the S lines, from "Last server log messages")
OKTF="$_pdir/lastok"
: > "$OKTF"
if [ -s "$FILES" ] && [ -s "$PARSED" ]; then
    _tab9=$(printf '\t')
    awk -F'\t' '$12 == "" { next }
        $2 == "Processed" {
            if (!($12 in SK) || $6 > SK[$12]) { SK[$12] = $6; C[$12] = $1; D[$12] = $4 " " $5; N[$12] = $11 }
            next
        }
        $2 == "Failed" {
            if (!($12 in EK) || $6 > EK[$12]) { EK[$12] = $6; EC[$12] = $1 }
        }
        END { for (s in SK) printf "O\t%s\t%s\t%s\t%s\n", C[s], s, N[s], D[s]
              for (s in EK) printf "E\t%s\t%s\n", EC[s], s }' "$FILES" > "$_pdir/lastok.sel"
    awk -F'\t' -v sel="$_pdir/lastok.sel" -v sesf="$_pdir/lastok.ses" '
        function esc9(s) { gsub(/[\t\r\n]/, " ", s); return s }
        function humanbytes(b) {
            b = b + 0
            if (b < 1024)       return sprintf("%d B", b)
            if (b < 1048576)    return sprintf("%.2f KB", b/1024)
            if (b < 1073741824) return sprintf("%.2f MB", b/1048576)
            return sprintf("%.2f GB", b/1073741824)
        }
        function humandur(ms) {
            ms = ms + 0
            if (ms < 0)       return "-"
            if (ms < 1000)    return sprintf("%d ms", ms)
            if (ms < 60000)   return sprintf("%.2f s", ms/1000)
            if (ms < 3600000) return sprintf("%.1f min", ms/60000)
            return sprintf("%.2f h", ms/3600000)
        }
        BEGIN { while ((getline l < sel) > 0) { n = split(l, a, "\t")
                    if (a[1] == "O" && n >= 5) { SITEOF[a[2]] = a[3]; KOF[a[2]] = "S"; printf "F\t%s\t%s\t%s\n", a[3], esc9(a[4]), a[5] }
                    else if (a[1] == "E" && n >= 3) { SITEOF[a[2]] = a[3]; KOF[a[2]] = "X" } }
                close(sel) }
        ($1 in SITEOF) {
            s = SITEOF[$1]
            if (KOF[$1] == "S")
                printf "L\t%s\t%s\t%s\t%s\t%s\t%s %s\t%s\t%s\t%s\n", s, \
                    esc9($3), esc9($2), esc9($10), humanbytes($9), esc9($11), esc9($12), humandur($15), esc9($16), esc9($23)
            if ($24 != "" && !(($1 SUBSEP $24) in ses)) { ses[$1 SUBSEP $24] = 1; print $24 "\t" s "\t" KOF[$1] > sesf }
        }
    ' "$PARSED" > "$OKTF"
    if [ -s "$_pdir/lastok.ses" ] && [ -s "$SERVER_CACHE/_parse.tsv" ]; then
        awk -F'\t' -v sesf="$_pdir/lastok.ses" '
            function esc9(s) { gsub(/[\t\r\n]/, " ", s); return s }
            # A session is MULTI-VALUED: one PeSIT/SSH connection can carry
            # the last-OK files of SEVERAL subscriptions (production: one CFT
            # push connection, six flows), so its lines go to EVERY site whose
            # legs used it. Per (session, site): S beats X (the rendered kind).
            BEGIN { while ((getline l < sesf) > 0) { split(l, a, "\t")
                        k2 = a[1] SUBSEP a[2]
                        if (!(k2 in KS9)) { NS9[a[1]]++; SS9[a[1], NS9[a[1]]] = a[2]; KS9[k2] = a[3] }
                        else if (a[3] == "S") KS9[k2] = "S"
                    }
                    close(sesf) }
            $6 != "" && ($6 in NS9) {
                for (i9 = 1; i9 <= NS9[$6]; i9++) {
                    s = SS9[$6, i9]; k9 = KS9[$6 SUBSEP s]
                    if (cnt[k9, s] >= 400) continue
                    cnt[k9, s]++
                    printf "%s\t%s\t%s %s\t%s\t%s\n", k9, s, $1, $2, ($3 == "E" ? "Error" : $3 == "W" ? "Warning" : "Info"), esc9($5)
                }
            }
        ' "$SERVER_CACHE/_parse.tsv" \
        | LC_ALL=C sort -t"$_tab9" -k1,1 -k2,2 -k3,3r \
        | awk -F'\t' '{ if ($1 == "S") { if (++n9[$2] <= 40) print } else print }' \
        | LC_ALL=C sort -t"$_tab9" -k1,1 -k2,2 -k3,3 >> "$OKTF"
    fi
    rm -f "$_pdir/lastok.sel" "$_pdir/lastok.ses"
fi
# ---- the "Logons" sidecar (LOGIN pages) -------------------------------------
# bin/logons.sh owns the aggregation (ensure_logons, shared with the server
# Logon report, which joins the same four figures onto its Incoming table as
# columns — the two run CONCURRENTLY in the build, so each ensures the file
# itself): per login the first/last successful authentication, the raw count
# and the cadence label. A login absent from the file never authenticated;
# the writer renders that as em dashes, 0 and "Never".
ensure_logons "$SERVER_CACHE"
LOGONSF="$SERVER_CACHE/_logons.tsv"
# the blue evidence dir (data/<env>/blue) for the writer's blue_box
BLUEDIR="${CONFIG_BASE%/flow-manager/base}/blue"

# ---- per-type PARALLEL writers (2026-07) ------------------------------------
# The stream and annotation slices are written per type by PASS B above (the
# sort leads with TYPE, so both are TYPE-contiguous and slice cleanly), and
# bin/transfer/details_writer.awk streams each slice in its own background
# job — the eight types render concurrently instead of one long sequential
# pass. Slicing preserves per-type order exactly, so the output is
# byte-identical to the former single loop. An optional CLI argument narrows
# the run to ONE type (ACC SITE LOGIN HOST PTN APP DOM) for iterating on
# a single family; the shared prep above still runs — it is what the writers
# consume — and the OTHER types' pages are left untouched by the dir cleanup
# only on such a narrowed run (the full run cleared them up top).
wpids=(); wtypes=()
# the Ranking report's per-type sidecars (bin/transfer/reports/ranking.sh) —
# each writer truncates its OWN file, so a single-type run leaves the others
RANKDIR="$REPORTS_DIR/ranking"
mkdir -p "$RANKDIR"
# a type with ZERO entities writes no sidecar — clear the previous run's
# (respecting the ONLY_TYPE narrowing), or a stale set survives forever and
# the Ranking report folds a dead estate's rows into a fresh page
for _ty9 in ACC SITE LOGIN HOST PTN APP DOM; do
    if [ -z "$ONLY_TYPE" ] || [ "$_ty9" = "$ONLY_TYPE" ]; then rm -f "$RANKDIR/$_ty9.tsv"; fi
done
for _ty in ACC SITE LOGIN HOST PTN APP DOM; do
    if [ -n "$ONLY_TYPE" ] && [ "$_ty" != "$ONLY_TYPE" ]; then continue; fi
    [ -s "$STREAMDIR/s.$_ty" ] || continue
    case $_ty in
        ACC) _od=$ACC_DIR ;; SITE) _od=$SITE_DIR ;; LOGIN) _od=$LOGIN_DIR ;;
        HOST) _od=$HOST_DIR ;; PTN) _od=$PTN_DIR ;; APP) _od=$APP_DIR ;; DOM) _od=$DOM_DIR ;;
    esac
    LC_ALL=C awk -F'\t' -v TYPE="$_ty" -v ANN="$STREAMDIR/a.$_ty" -v OUTDIR="$_od" \
        -v RANKOUT="$RANKDIR/$_ty.tsv" \
        -v SRV="$SERVER_CACHE" -v FWD="$IP_HOSTS_FILE" -v BLUE="$BLUEDIR" \
        -v UCF="$UCMETA" -v UCDF="$UCDER" -v UNCF="$_pdir/uncollected" -v OKF="$OKTF" \
        -v SSF="$SRVSUBSF" -v ERRD="$REPORTS_DIR/errors" -v LGF="$LOGONSF" -v LGHF="$SERVER_CACHE/_logons-hosts.tsv" \
        -v NOW="$NOW_TS" -v NFILES="${#files[@]}" \
        -f "$SCRIPT_DIR/../details_writer.awk" "$STREAMDIR/s.$_ty" > "$STREAMDIR/log.$_ty" 2>&1 &
    wpids+=("$!"); wtypes+=("$_ty")
done
[ "${#wpids[@]}" -gt 0 ] || { echo "details.sh: no writer spawned (unknown type '$ONLY_TYPE'?)" >&2; exit 1; }
_wfail=0
for _i in "${!wpids[@]}"; do
    if ! wait "${wpids[$_i]}"; then
        echo "details.sh: ${wtypes[$_i]} writer FAILED:" >&2
        cat "$STREAMDIR/log.${wtypes[$_i]}" >&2 || true
        _wfail=1
    fi
done
cat "$STREAMDIR"/log.* >&2 2>/dev/null || true
[ "$_wfail" = 0 ] || exit 1
# (every intermediate — side inputs, sorted stream, slices — lives under
# $_pdir, removed by the EXIT trap)

# the skip_if_fresh stamp — FULL runs only (a single-TYPE rerun leaves the
# other types as they were, so it must not mark the whole tree fresh); lost
# in the per-type-parallel refactor, which made every build redo all pages
[ -z "$ONLY_TYPE" ] && touch "$STAMP"

count_files=$(find "$REPORTS_DIR/details" -name '*.rpt' | wc -l | tr -d ' ')
echo "Wrote $count_files detail file(s) across accounts/subscriptions/logins/hosts/partners/applications/domains." >&2
