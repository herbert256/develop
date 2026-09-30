#!/usr/bin/env bash
#
# failed.sh — the Failed Subscriptions lists, on TWO pages (2026-08, replacing
# the capped single last-failed list; the Subscription-leg views went 2026-08,
# the two every-failed-File views all-failing / all-all 2026-09-29 — the Failed
# files page lists every File in error): one row per subscription, its newest
# failed File, and one button group picks the FILTER, each its own page
# (analyses/failed*.html; the selector row is injected at publish time by
# bin/analyses/publish.sh, BELOW the From/To date fields):
#
#   failing  hide the subscriptions that are GREEN again
#   all      keep them
#
#   failed.rpt = the still-failing view, THE page (analyses/failed.html);
#   failed-sub-all.rpt -> analyses/failed-sub-all.html keeps the recovered.
#   No caps and no floor: a view is an exact dedup. The (subscription, legs)
#   PAIR rule lives on WITHOUT a page of its own: it still grants the drill
#   pages (each pair's newest file, ~185 pairs over 14,935 acceptance
#   failures) and drives the reason pass's pair borrow.
#
# FILE rows read every File in error — outcome "Failed" or "Expired" (a UC2
# staged copy the partner never collected), the site-wide Error rule
# (2026-09-29); an Expired row's Reason reads "Expired (not collected)".
#
# PLUS THE SERVER-FAILING ROWS (2026-08, with the move to Analyses): every
# RED subscription whose CURRENT failure the transfer log cannot show (a
# server-log error after its last delivery, a deploy mistake, an
# authentication failure attributed to it) — kind R without a failed File in
# the data, kind P with older ones (its server row replaces its file row) —
# gets one row per list: @data:srv=1, Date/time = the NEWEST server evidence
# stamp (colour/_redflip.tsv col 2, else the kaput sidecar, else its last
# File), Last green day = its newest OK File's day ("never"), Days red = from
# the flip's SINCE (_redflip.tsv col 3 — when it went red) to the data
# window's last day, Reason =
# the classified newest server E line (_kaput-evidence.tsv through
# bin/flip-reason.awk) else its Subscriptions-in-boxes box (one build behind,
# like the entities Reason column). Like a file row, the whole row opens the
# flow's OWN error page — files/<slug>.html, NAMED BY THE SUBSCRIPTION,
# holding the facts and the server-log mention ring (the page step below the
# finishing pass writes them). So each view covers ALL failing
# subscriptions, transfer and server alike (the home page's red worklists
# that split them went; this page is THE red list). The consumer of
# failed-sub-all.rpt (the Entities Reason column, publish_lib.sh) skips
# these rows by their @data:srv cell and takes a file row's CoreId page
# from its @data:href — the columns are Subscription,
# Date/time, Reason, CoreId / SessionId and the red-run trio Last green day,
# Days red, Failures in a row (see the list writer below).
#
# DRILL PAGES: every LEG-selection row (which contains every SUB row — a
# subscription's newest file is the newest of its own pair) gets an error
# page, PLUS THE 30-DAY GUARANTEE (2026-08, widened to ALL PERIODS):
# every FAILED file of the newest 30 data days (the File search windows until
# 2026-09-29; the All files search links these pages —
# Failed only, an Expired pickup is not an error page's story) gets a drill
# page even when the leg selection skipped it — capped at 10 pages per
# SUBSCRIPTION PER DAY (leg pages included, newest first). Every list row is
# paged: a row is a subscription's newest File in error (S), and S implies L.
# (The "Expired pickup" page title: an Expired File of the lists — the lists
# carry Failed AND Expired since 2026-09-29.)
#
# Outputs:
#   $REPORTS_DIR/failed.rpt             the two lists (still failing / all)
#   $REPORTS_DIR/failed-sub-all.rpt     — columns: see the header above
#   $REPORTS_DIR/_failed-reasons.tsv    coreid ⇥ Reason of EVERY File in error
#                                       (failed-files.sh shows them per File)
#   $REPORTS_DIR/errors/<slug>.rpt      one per SERVER-FAILING subscription,
#                                       named by the subscription: the facts
#                                       + its server-log mention ring
#   $REPORTS_DIR/errors/<coreid>.rpt    one per paged file: every
#                                       _transfers.tsv leg of that CoreId (with
#                                       the SESSION each leg ran on), plus
#                                       "What the server log said" — EVERY
#                                       server-log line of those sessions and
#                                       every line carrying the CoreId or a
#                                       transfer ID, oldest first, each message
#                                       verbatim in <pre>; and, for a file
#                                       neither join matched, the E-level lines
#                                       naming the subscription inside the
#                                       failure's time window. ONE pass over
#                                       the server cache serves all the pages
#                                       (the cache is ~3 GB — a per-CoreId scan
#                                       is out of the question); a missing
#                                       server cache degrades silently (no
#                                       section).
# bin/transfer/publish.sh renders the second set to docs/files/<coreid>.html
# (one level below the env root, like transfer/ — so "../assets/style.css").
# The WHOLE list row opens that page (the rowlink modifier + the row's
# @data:href, which beats its first link — the Subscription cell, whose own
# link still works when clicked directly).
#
# The REASON column (2026-08, replacing Ended): the fault the file's
# own drill page shows, classified by bin/flip-reason.awk — the SAME function
# behind the Boxes reasons (reason-boxes.sh) and the Entities Reason
# column (publish_lib.sh), whose first-priority source is exactly these pages
# (_errpage-evidence.tsv + pagereason() in reason-boxes.sh). Per file: the page's first 8 Error/Warning lines,
# ERROR lines first in page order, first classification wins — the opening
# error of a failure is the cause, everything after it consequence. A file
# WITHOUT a page (most older Files — the pass reasons EVERY File in error,
# saved to _failed-reasons.tsv for the Failed files report) falls to One-legged, the newest paged file
# of its own (subscription, legs) pair, the flow's evidence sidecar, then its
# last leg's raw status — the same chain, minus the page.
# Blank when nothing classifies: better than a guess. The pass runs AFTER the
# finishing pass (the server-log sections are what it reads) and BEFORE the
# lists are written.
#
# Usage:
#   ./failed.sh    # -> data/transfer/reports/failed*.rpt + errors/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../../ranges.sh"   # rng_feed / rng_off: the byte-range split of the parallel server log pass 1 (2026-09-27)
# PHASE TIMINGS (2026-09-27): one "TIME Ns  failed: <phase>" lap per section
_fl0=$(date +%s)
_flap() { local _t1; _t1=$(date +%s); printf 'TIME %5ds  failed: %s\n' "$((_t1 - _fl0))" "$1" >&2; _fl0=$_t1; }

# THE MODE (2026-09-29, build speed) — an explicit argument, never a
# freshness check:
#   (none) | full   everything below; the build's phase-1 run
#   catchup         bin/build.sh's "report catch-up: failed subscriptions":
#                   ONLY what reads an input that changed since the full run
#                   of THIS build — the Subscriptions-in-boxes sidecar
#                   (_subs-boxes.tsv, the Reason of a server-failing row
#                   without a kaput reason; written after phase 1) and the
#                   red-run sidecar _red-run.tsv (the lists'
#                   red-run columns; written by a phase-1 PEER of the full
#                   run). So: the server-failing set again (its REASON column;
#                   the rest must come out identical, else a full run), their
#                   pages (the reason is in the TITLE), the two lists and the
#                   _srvsubs sidecars. The drill and File pages, both
#                   server-log passes, the evidence sidecar and the File
#                   reasons read nothing that changed and are left as the full
#                   run wrote them; the full run leaves the intermediates this
#                   mode reads in $REPORTS_DIR/.failed-state/ (no state = a
#                   full run).
FAILED_MODE=${1:-full}
case $FAILED_MODE in
    full|catchup) ;;
    *) printf 'usage: failed.sh [full|catchup]\n' >&2; exit 2 ;;
esac

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi

OUT="$REPORTS_DIR/failed.rpt"
# the view variant beside the default still-failing page (see the header;
# the two every-failed-File views, all-failing / all-all, went 2026-09-29 —
# the Failed files page lists every File in error)
VARIANTS="sub-all"
ERRDIR="$REPORTS_DIR/errors"
# The FILE pages (2026-09-03, user request): the same drill-page layout for
# ANY outcome. Pages land in data/transfer/reports/files/, beside errors/ and
# never inside it — the reason-evidence pass globs errors/ and must not read
# an OK File's page. Only the DATA is split: both sets publish into the ONE
# docs/files/ (2026-09-21, user request — the docs/errors/ directory is gone;
# bin/transfer/publish.sh). Since 2026-09-29 (user request: per subscription
# only the newest OK File and the three newest Failed Files are published —
# bin/transfer/filepages.sh, _filepages.tsv) the files/ set is the kind-O
# CoreIds of that list alone: the patterns / Longest Files / drill-cell /
# Expired / Waiting side lists that forced pages here went, their writers
# link a File only when the published set holds it.
FILEDIR="$REPORTS_DIR/files"
FPF="$CACHE_DIR/_filepages.tsv"; [ -f "$FPF" ] || FPF=/dev/null
# The server parse cache (the "What the server log said" sections); an env
# without server logs still works.
SRVLOG="$SERVER_CACHE/_parse.tsv"
# Page guard for the server-log table: a session is normally tens to a few
# hundred lines (acceptance: median 35, p90 144, busiest 477), so this ceiling
# does not bite — it is here so one pathological connection cannot turn a drill
# page into a megabyte. A capped page says so in a NOTE under its table.
SRVCAP=${AXWAY_ERR_LOGCAP:-2000}
# The three server-row evidence sources (see the header); a missing one
# degrades to fewer/reason-less server rows.
RFLIP="$DATA/colour/_redflip.tsv"
KAPUT="$DATA/server/reports/_kaput-evidence.tsv"
BOXES="$DATA/analyses/reports/_subs-boxes.tsv"
# (THE ENVIRONMENT LETTER column of 2026-09-21 — A / P / S first on every
# row — went 2026-09-29, user request: one repo = one environment, and the
# top bar already names it.)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/axlastf.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STATE="$REPORTS_DIR/.failed-state"   # the full run's intermediates the catch-up reads
STATE_FILES="all srvsubs srvsess2 srvsublines reasons"
if [ "$FAILED_MODE" = catchup ]; then
    for _sf in $STATE_FILES; do
        [ -f "$STATE/$_sf" ] || { echo "failed.sh catchup: no full-run state ($_sf) — a full run." >&2; FAILED_MODE=full; break; }
    done
    if [ "$FAILED_MODE" = catchup ]; then
        for _sf in $STATE_FILES; do cp "$STATE/$_sf" "$TMP/$_sf"; done
    fi
fi

if [ "$FAILED_MODE" = full ]; then   # ---- (the catch-up skips down to THE SERVER-FAILING set)

# EVERY failed File, newest first, with the two dedup MARKS the selections
# read: S = the subscription's newest failure (the first row of its site in
# the newest-first stream), L = the newest failure of its (subscription,
# legs) pair — S implies L, a subscription's newest file being the newest of
# its own pair. sortkey (col 6) is YYYYMMDDHH:MM:SS.mmm, so a plain C-locale
# reverse sort is newest-first. Keying on SUBSEP, not a literal \x1f, keeps
# the program POSIX-awk. Fields: sortkey, coreid, site, legs, date, time,
# outcome, marks.
LC_ALL=C awk -F'\t' -v OFS='\t' '$2 == "Failed" || $2 == "Expired" { print $6, $1, $12, $10, $4, $5, $2 }' "$FILES" \
    | LC_ALL=C sort -r \
    | awk -F'\t' -v OFS='\t' '
        { m = ""
          if (!seensub[$3]++)  m = m "S"
          if (!seen[$3, $4]++) m = m "L"
          print $0, m }' > "$TMP/all"
nleg=$(awk -F'\t' '$8 ~ /L/ { n++ } END { print n + 0 }' "$TMP/all")
nallf=$(wc -l < "$TMP/all" | tr -d ' ')

# THE 30-DAY GUARANTEE (2026-08, widened to ALL PERIODS): every FAILED
# file of the newest 30 data days (the span of the File search windows, which
# went 2026-09-29; the All files search links them) gets a drill page, CAPPED at 10
# pages per SUBSCRIPTION PER DAY (leg-selection pages included, each day's
# newest failures winning): one broken flow with thousands of failures must
# not turn errors/ into a landfill, and a day's 10 newest pages tell that
# day's story while every ACTIVE day keeps its evidence. FAILED ONLY, like
# the lists themselves: an EXPIRED file is a pickup problem — its story is
# the subscription's detail page and the Expired report, not an error page.
SUBPAGES=10         # drill pages per (subscription, day) in the window guarantee
ENDJ=$(LC_ALL=C awk -F'\t' '$7 != "" && $7 > m { m = $7 } END { print m + 0 }' "$FILES")
LC_ALL=C awk -F'\t' -v OFS='\t' -v endj="$ENDJ" '
    $4 == "" || $7 == "" { next }
    $2 == "Failed" && (endj - $7) < 30 \
        { print $6, $1, $12, $10, $4, $5, $2 }
' "$FILES" \
| LC_ALL=C sort -r \
| LC_ALL=C awk -F'\t' -v OFS='\t' -v topf="$TMP/all" -v cap="$SUBPAGES" '
    # the leg selection already granted pages: count them per (subscription,
    # day), and never page the same CoreId twice; the stream is newest first,
    # so the cap keeps each subscription the 10 NEWEST window errors OF EACH
    # DAY (field 5 is date_iso in both files)
    BEGIN { while ((getline l < topf) > 0) { split(l, z, "\t")
                if (z[8] !~ /L/) continue
                T[z[2]] = 1; SC[z[3], z[5]]++ } close(topf) }
    ($2 in T) { next }
    SC[$3, $5]++ < cap { print }
' > "$TMP/extra"
nextra=$(wc -l < "$TMP/extra" | tr -d ' ')

rm -rf "$ERRDIR"; mkdir -p "$ERRDIR"
rm -rf "$FILEDIR"; mkdir -p "$FILEDIR"
# The FILE pages (see FILEDIR above): every CoreId patterns.sh listed, in the
# 8-column shape of the lists above (+ the source tag) — a CoreId that already gets a drill
# page as a failed File (the leg selection or the window guarantee) keeps
# that page and is left out here: both sets publish into docs/files/
# (2026-09-21 — until then the finished page was COPIED under files/), so a
# "Last 5 files" link resolves to it and no CoreId is paged twice by the
# pass below.
: > "$TMP/filepages"; : > "$TMP/fileset"; : > "$TMP/overlap"
# THE PUBLISHED SET GETS ITS PAGES (2026-09-29): every CoreId of
# _filepages.tsv (bin/transfer/filepages.sh — per subscription the newest
# DELIVERED File, kind O, and the three newest FAILED Files, kind E) has a
# page under docs/files/. An E File the evidence selection below already
# pages (the leg selection, the window guarantee — errors/, the reasons read
# them) keeps that drill page (the overlap step drops it here); every other
# one gets a File page under files/ — NOT errors/, so the evidence-glob
# passes (the flow and pair verdicts) see exactly what they saw before; the
# reason pass classifies such a File from its own page, like every File page
# (the 2026-09-28 rule). The O pages give the "Latest OK" row of
# a detail page's Features table its target; no back link (the facts table
# links the subscription the File belongs to).
awk -F'\t' '$2 == "O" || $2 == "E" { print $1 "\t" $2 }' "$FPF" | LC_ALL=C sort > "$TMP/fileside"
if [ -s "$TMP/fileside" ]; then
    LC_ALL=C awk -F'\t' -v OFS='\t' -v topf="$TMP/all" -v extraf="$TMP/extra" -v sidef="$TMP/fileside" \
        -v setf="$TMP/fileset" -v ovf="$TMP/overlap" '
        BEGIN { while ((getline l < sidef) > 0) { split(l, y, "\t"); if (y[1] != "") { want[y[1]] = 1; src[y[1]] = y[2] } } close(sidef)
                while ((getline l < topf) > 0) { split(l, z, "\t"); if (z[8] ~ /L/) paged[z[2]] = 1 } close(topf)
                while ((getline l < extraf) > 0) { split(l, z, "\t"); paged[z[2]] = 1 } close(extraf) }
        ($1 in want) { if ($1 in paged) { print $1 > ovf; next }
                       print $1, src[$1] > setf
                       print $6, $1, $12, $10, $4, $5, $2, src[$1] }
    ' "$FILES" | LC_ALL=C sort -r > "$TMP/filepages"
fi
nfilep=$(wc -l < "$TMP/filepages" | tr -d ' ')
# pre-create the sidecars the main awk fills — with no failed files it
# writes none, and the reason/list steps below still read them (the session
# map too: with no leg carrying a session id it was never created, and the
# server-log pass died on the missing file — 2026-09-28 fix)
: > "$TMP/paged"; : > "$TMP/lastst"; : > "$TMP/ids"; : > "$TMP/sess"; : > "$TMP/meta"

# One pass over the parse cache for the legs of exactly the PAGED CoreIds
# (the leg selection + the guarantee extras), writing one drill .rpt per
# file. The cache is CoreId-sorted, so a file's legs arrive together; they
# are held per CoreId and flushed at END so the drill pages come out in a
# defined order whatever the input order. On the side it collects, for EVERY
# failed CoreId, the LAST leg's raw status ($TMP/lastst) — the reason pass
# needs it for the unpaged Files (_failed-reasons.tsv) — and the paged-CoreId set
# ($TMP/paged) the list writer marks its links by.
LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" \
    -v TOPF="$TMP/all" -v EXTRAF="$TMP/extra" -v LASTF="$TMP/lastst" -v PAGEDF="$TMP/paged" \
    -v IDS="$TMP/ids" -v META="$TMP/meta" -v SESS="$TMP/sess" -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" -v ACCRES="$CONFIG_BASE/_accounts.tsv" -v HSTRES="$CONFIG_BASE/_hosts.tsv" \
    -v LGNRES="$CONFIG_BASE/_logins.tsv" -v PTNRES="$CONFIG_BASE/_partners.tsv" -v SPMAP="$CONFIG_XREF/_subscriptions-partners.tsv" \
    -v FILESF="$TMP/filepages" -v FILEDIR="$FILEDIR" '
    # The SUBSCRIPTION result colour (bin/build/result.sh fills the third
    # column of the base cache), so a row carries the state of the flow it
    # belongs to: red = still failing, green = it has delivered OK since,
    # orange = never seen. That is a different fact
    # from the State column, which is about THIS File, and the more useful one
    # to scan for — the same tint the Ranking report and the Entities views
    # give the entity. A name the base cache does not know stays untinted.
    BEGIN { resload(SUBRES, SRES); resload(ACCRES, ARES); resload(HSTRES, HRES)
        resload(LGNRES, LRES); resload(PTNRES, PRES); spload(SPMAP) }
    # the subscription -> partner(s) map (the site-wide UNION attribution: a
    # File belongs to every partner of its subscription), SUBSEP-joined.
    # NOT the shared sp_union (bin/pda-union.sh): the facts row names the
    # SUBSCRIPTION configured partners only (no col 20 — the facts row names
    # the partners of the subscription by design); the key is CASE-FOLDED like
    # sp_union (2026-09-29 audit)
    function spload(f9,   l9, n9, z9) {
        while ((getline l9 < f9) > 0) { n9 = split(l9, z9, "\t")
            if (n9 >= 2 && z9[1] != "" && z9[2] != "" && !((z9[1] SUBSEP z9[2]) in spseen)) {
                spseen[z9[1] SUBSEP z9[2]] = 1; SPM[toupper(z9[1])] = SPM[toupper(z9[1])] SUBSEP z9[2] } }
        close(f9) }
    function resload(f9, A9,   l9, n9, z9) {
        while ((getline l9 < f9) > 0) { n9 = split(l9, z9, "\t")
            if (n9 >= 3 && z9[1] != "") A9[toupper(z9[1])] = z9[3] }
        close(f9) }
    function rescol(A9, nm,   r) { r = (toupper(nm) in A9) ? A9[toupper(nm)] : ""
        return (r == "green" || r == "orange" || r == "red") ? r : "" }
    # A facts-table entity cell: the entity RESULT colour on the cell (the same
    # tint its own page and the Entities views carry) plus the detail-page link,
    # resolved through that sub-dir\047s slugmap at render time. A name the
    # slugmap does not know renders plain, which is the site-wide rule.
    function entcell(A9, sub9, nm,   r, a) {
        if (nm == "") return "-"
        r = rescol(A9, nm); a = "alink=" sub9 "/" nm
        return "@{" (r != "" ? "class=res-" r "," : "") a "}" nm }
    function humandur(ms) {
        ms = ms + 0
        if (ms < 0)       return "-"
        if (ms < 1000)    return sprintf("%d ms", ms)
        if (ms < 60000)   return sprintf("%.2f s", ms/1000)
        if (ms < 3600000) return sprintf("%.1f min", ms/60000)
        return sprintf("%.2f h", ms/3600000)
    }
    function humanbytes(b) {
        b = b + 0
        if (b < 1024)       return sprintf("%d B", b)
        if (b < 1048576)    return sprintf("%.2f KB", b/1024)
        if (b < 1073741824) return sprintf("%.2f MB", b/1048576)
        return sprintf("%.2f GB", b/1073741824)
    }
    # the raw end_time column is MM/DD/YYYY HH:MM:SS.mmm — the one place the
    # cache is not ISO, because parse.sh carries col 18 verbatim
    function iso(e,   p, d, t, m) {
        if (e == "") return ""
        p = index(e, " "); if (p == 0) return e
        d = substr(e, 1, p - 1); t = substr(e, p + 1)
        if (split(d, m, "/") != 3) return e
        return m[3] "-" m[1] "-" m[2] " " t
    }
    function esc(s) { gsub(/[\t\r\n]/, " ", s); return s }
    # a remote host that is a raw IPv4 (a partner SOURCE address — an inbound
    # leg keeps it raw) links its incoming-connection page (2026-09-30, audit
    # D-04 — the detail pages do the same); the renderer resolves the alink
    # through that directory slugmap, so an address without a page stays
    # plain. Any other value is an endpoint name: the hosts entity cell.
    function isip4(v) { return v ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ }
    function hostcell(nm) { return isip4(nm) ? "@{alink=incoming_connections/" nm "}" nm : entcell(HRES, "hosts", nm) }
    # lit(): a raw name starting with @ would read as renderer metadata; the empty block @{} keeps it literal (audit 2026-09-29 F07)
    function lit(s) { return (substr(s, 1, 1) == "@") ? "@{}" s : s }

    # FILENAME dispatch, not an FNR==1 counter: the extras file is legitimately
    # EMPTY when every window error made the list, and an empty file never
    # fires FNR==1 — a counter would then misread the parse cache.
    FILENAME == TOPF {                          # every failed File + marks
        ALLF[$2] = 1                            # the lastst collection set
        if ($8 !~ /L/) next                     # only the leg selection gets a page here
        ord[++nord] = $2                        # CoreId, newest first
        SITE[$2] = $3; LEGS[$2] = $4; SD[$2] = $5; ST[$2] = $6
        OC[$2] = $7                             # Failed | Expired — the title wording (2026-09-29: unset here, an Expired File in the lists got "Failed subscription")
        WANT[$2] = 1
        next
    }
    FILENAME == EXTRAF {                        # drill-only: the 30-day
        ord[++nord] = $2                        # window errors the selection skipped
        SITE[$2] = $3; LEGS[$2] = $4; SD[$2] = $5; ST[$2] = $6
        OC[$2] = $7                             # Failed | Expired (page wording)
        WANT[$2] = 1
        next
    }
    FILENAME == FILESF {                        # the FILE pages (any outcome): the
        ord[++nord] = $2                        # Transfer patterns "Last 5 files" links
        SITE[$2] = $3; LEGS[$2] = $4; SD[$2] = $5; ST[$2] = $6
        OC[$2] = $7                             # Processed | Waiting | Failed | Expired
        SRC[$2] = $8                            # P (patterns) / L (longest) / PL: the back link(s)
        WANT[$2] = 1; FSET[$2] = 1              # -> FILEDIR, neutral wording, no list mark
        next
    }
    # legs_chrono(c): the ROW lines of CoreId c in time order (insertion sort
    # on the per-leg keys — a CoreId has a handful of legs)
    function legs_chrono(c,   n, i, j, k, s, K, R) {
        n = NL[c] + 0
        for (i = 1; i <= n; i++) { K[i] = LEGK[c, i]; R[i] = LEGR[c, i] }
        for (i = 2; i <= n; i++) { k = K[i]; s = R[i]; j = i - 1
            while (j >= 1 && K[j] > k) { K[j+1] = K[j]; R[j+1] = R[j]; j-- }
            K[j+1] = k; R[j+1] = s }
        s = ""; for (i = 1; i <= n; i++) s = s R[i]
        return s
    }
    # the parse cache: the last-leg raw status for every failed CoreId (the
    # cache is CoreId-sorted, legs in cache order — last write wins, the same
    # last row pagereason reads off a drill page)
    ($1 in ALLF) { LASTST[$1] = $3 }
    !($1 in WANT) { next }                      # the drill pages: only these CoreIds
    {
        e = iso($18)
        if (e > ENDT[$1]) ENDT[$1] = e          # ISO sorts lexically
        # the FILE this CoreId carried, for the page title: the first leg that
        # names one (col 8 is the real basename — the same rule _files.tsv col
        # 11 follows). A CoreId with no name anywhere keeps the id as its title.
        if (FNAME[$1] == "" && $8 != "") FNAME[$1] = $8
        # the facts table needs the endpoint and the account: first leg that
        # carries one, the rule _files.tsv cols 15/3 follow
        if (HOSTN[$1] == "" && $16 != "") HOSTN[$1] = $16
        if (ACCTN[$1] == "" && $4  != "") ACCTN[$1] = $4
        if (LOGINN[$1] == "" && $5 != "") LOGINN[$1] = $5   # the login, the rule of _files.tsv col 14 (2026-09-03)
        # each leg with its sort key (col 13, YYYYMMDD + time): the page lists
        # the legs CHRONOLOGICALLY (2026-09-09, user request — cache order is
        # inbound first, so a later outbound attempt used to precede an
        # earlier outbound routing leg); ties keep cache order
        NL[$1]++
        LEGK[$1, NL[$1]] = $13 sprintf("%06d", NL[$1])
        LEGR[$1, NL[$1]] = sprintf("ROW\t%s\t%s\t%s\t%s\t%s %s\t%s\t%s\t%s\n", \
            esc($3), esc($2), esc($10), humanbytes($9), esc($11), esc($12), humandur($15), (isip4($16) ? "@{alink=incoming_connections/" $16 "}" $16 : esc($16)), esc($23))
        # every leg transfer_id -> its CoreId, for the server-log id join
        if ($23 != "" && !tid[$1, $23]++) print $23 "\t" $1 > IDS
        # every leg SESSION -> its CoreId (col 24, the technical connection):
        # the server cache carries the same id per record since 2026-08, so the
        # page can show the whole conversation its legs took part in, not just
        # the lines that happen to name the file. One session can carry files
        # for several of these pages, hence one row per (session, CoreId) pair.
        if ($24 != "" && !ses[$1, $24]++) { print $24 "\t" $1 > SESS; NSES[$1]++ }
    }
    END {
        # the paged-CoreId set (the list writer links these rows) and the
        # last-leg raw status per failed CoreId (the reason pass, unpaged Files)
        for (i = 1; i <= nord; i++) if (!(ord[i] in FSET)) print ord[i] > PAGEDF   # a FILE page is no list link
        for (c in LASTST) print c "\t" LASTST[c] > LASTF
        close(PAGEDF); close(LASTF)

        for (i = 1; i <= nord; i++) {
            c = ord[i]
            f = ((c in FSET) ? FILEDIR : ERRDIR) "/" c ".rpt"
            # The page is named after the FILE, not the CoreId — a name says
            # which feed broke at a glance where an opaque id does not. The id
            # is still on the page (the intro below) since it is the value to
            # quote to Axway support, and it is still the page URL.
            nm = (FNAME[c] != "") ? FNAME[c] : c
            # EVERY CoreId page is titled by its File (2026-09-30, audit
            # D-03): the error pages read "Failed subscription: <subscription>
            # - <reason>" (or "Expired pickup: …") until then, which named a
            # subscription that may be green again by now and read
            # "Failed subscription: Unknown" for the unplaced Files. The
            # subscription and the reason are rows of the facts table below
            # (the reason pass adds the Reason row); only the
            # subscription-named server-failing pages keep that title.
            printf "TITLE\tFile: %s\n", nm > f
            # The FACTS table (2026-08), first thing on the page and in place of
            # the prose line that used to open it: what this File was, where it
            # went and who it belonged to. The last three cells carry the
            # entity RESULT colour and link to its detail page — the same tint
            # and the same destination the rest of the site gives them.
            printf "TABLE\t\tnosearch\n" > f
            printf "HEAD\tItem\tValue\n" > f
            printf "KIND\ttext\ttext\n" > f
            printf "ROW\tFile name\t%s\n", lit(nm) > f
            printf "ROW\tCoreId\t@{class=mono}%s\n", c > f
            printf "ROW\tDate/time\t%s %s\n", SD[c], ST[c] > f
            printf "ROW\tSubscription\t%s\n", entcell(SRES, "subscriptions", SITE[c]) > f
            # Partner, Account, Login, Remote host — each only when the File
            # carries one (2026-09-03, user request): the partner(s) of the
            # subscription (one links like the other entities; several list
            # plainly), the account / login / endpoint from the first leg
            # that carries one
            np9 = split(substr(SPM[toupper(SITE[c])], 2), PP9, SUBSEP)
            if (np9 == 1) printf "ROW\tPartner\t%s\n", entcell(PRES, "partners", PP9[1]) > f
            else if (np9 > 1) { pl9 = PP9[1]; for (q9 = 2; q9 <= np9; q9++) pl9 = pl9 ", " PP9[q9]; printf "ROW\tPartner\t%s\n", pl9 > f }
            if (ACCTN[c] != "")  printf "ROW\tAccount\t%s\n", entcell(ARES, "accounts", ACCTN[c]) > f
            if (LOGINN[c] != "") printf "ROW\tLogin\t%s\n", entcell(LRES, "logins", LOGINN[c]) > f
            if (HOSTN[c] != "")  printf "ROW\tRemote host\t%s\n", hostcell(HOSTN[c]) > f
            # no TOTAL: an Item/Value facts table has nothing to total, and
            # an empty footer row would just draw a grey strip under it (the
            # detail pages\047 Features table omits it for the same reason)
            # No sort= here: the legs are emitted CHRONOLOGICALLY (legs_chrono,
            # 2026-09-09 — until then cache order, inbound first), and the first
            # column is not a date so report.js applies no default of its own.
            # No `nosort`, so the headers stay clickable.
            printf "TABLE\t\twide\tnosearch\n" > f
            printf "HEAD\tStatus\tDirection\tProtocol\tSize\tDate & time\tDuration\tRemote host\tTransfer ID\n" > f
            printf "KIND\ttext\ttext\ttext\tnum\ttext\tnum\thost\tmono\n" > f
            printf "%s", legs_chrono(c) > f
            # NO LINK/FOOT here — the finishing pass below appends the server-log
            # section first, then LINK + FOOT, so those stay the last lines.
            close(f)
            # the id join key set (the CoreId itself; the leg transfer_ids were
            # emitted above) + the window metadata for the name fallback
            print c "\t" c > IDS
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", c, SITE[c], SD[c], ST[c], ENDT[c], NSES[c] + 0 > META
        }
        close(IDS); close(META); close(SESS)
    }
' "$TMP/all" "$TMP/extra" "$TMP/filepages" "$PARSED"
_flap "the failed Files, the drill + File pages"
fi   # (full mode)
# ---- The SERVER-FAILING set (2026-08) ---------------------------------------
# Every RED subscription that is server-reddened (colour/_redflip.tsv) or has NO
# failed File at all — red on the server log's word, not a failed File's. Computed
# BEFORE the server-cache scan below, so the scan can resolve each flow's
# evidence STAMP to the SESSION of the reddening Error line (and the second
# pass after it collect that session's whole conversation for the drill
# page). Output $TMP/srvsubs — name ⇥ slug ⇥ stamp ⇥ reason ⇥ kind:
#   slug   the page basename (lowercased, non-alnum runs folded to "-", the
#          slugify rule; a separator-twin collision takes a numeric suffix; a
#          slug can never collide with a CoreId page, those being UUIDs)
#   stamp  colour/_redflip.tsv col 2 (the NEWEST evidence — its session is
#          the page's reddening session), else the kaput sidecar, else the
#          last File
#   reason the classified kaput E line, else the Subscriptions-in-boxes box
#   kind   R = no failed File (a list server-row + a page)
#          P = redflip WITH failed Files (its server row REPLACES its file
#              row on the lists, and it gets the page)
[ -f "$RFLIP" ] || RFLIP=/dev/null
[ -f "$KAPUT" ] || KAPUT=/dev/null
[ -f "$BOXES" ] || BOXES=/dev/null
# the last-File stamp per subscription (ALL outcomes — a server-reddened
# flow's last File is usually an OK one), the Started fallback
# ... and, for the server rows' red-run columns, the newest OK File's day per
# subscription (outcome policy: not Failed / Expired) and the data window's
# last day (max col 7, the red-run Days red end)
LC_ALL=C awk -F'\t' -v OFS='\t' -v OKF="$TMP/lastok" -v MJF="$TMP/maxjd" '$12 != "" { k = $12
        if ($6 > mx[k]) { mx[k] = $6; d[k] = $4 " " $5 }
        if ($2 != "Failed" && $2 != "Expired" && $6 > ox[k]) { ox[k] = $6; od[k] = $4 } }
    $7 + 0 > mj { mj = $7 + 0 }
    END { for (k in d) print k, d[k]
          printf "" > OKF; for (k in od) print k, od[k] > OKF
          print mj + 0 > MJF }' "$FILES" > "$TMP/lastfile"
: > "$TMP/srvsubs"; : > "$TMP/srvsess2"
LC_ALL=C awk -F'\t' -v OUTS="$TMP/srvsubs" \
    -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" \
    -v RF="$RFLIP" -v KAP="$KAPUT" -v BOX="$BOXES" -v LFF="$TMP/lastfile" -v ALLFF="$TMP/all" \
    "$(cat "$LIB_DIR/../flip-reason.awk")"'
    function slug9(n,   s) { s = tolower(n); gsub(/[^a-z0-9]+/, "-", s)
        sub(/^-+/, "", s); sub(/-+$/, "", s); return s }
    BEGIN {
        # the red names in FILE ORDER (never a hash walk — CLAUDE.md rule)
        while ((getline l < SUBRES) > 0) { n = split(l, a, "\t")
            if (n >= 3 && a[1] != "" && a[3] == "red") RN[++nrn] = a[1] }
        close(SUBRES)
        while ((getline l < RF) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "" && a[2] != "") RFS[toupper(a[1])] = a[2] }
        close(RF)
        while ((getline l < KAP) > 0) { n = split(l, a, "\t")
            if (n < 2 || a[1] == "") continue
            k = toupper(a[1]); KTS[k] = a[2]
            if (n >= 5 && a[5] != "") { r = flip_reason(a[5]); if (r != "") KRE[k] = r } }
        close(KAP)
        while ((getline l < BOX) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "") BXR[toupper(a[1])] = a[2] }
        close(BOX)
        while ((getline l < LFF) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "") LFD[toupper(a[1])] = a[2] }
        close(LFF)
        while ((getline l < ALLFF) > 0) { n = split(l, a, "\t")
            if (n >= 3 && a[3] != "") SEEN[toupper(a[3])] = 1 }
        close(ALLFF)
        for (j = 1; j <= nrn; j++) {
            nm = RN[j]; k = toupper(nm)
            if ((k in SEEN) && !(k in RFS)) continue   # table-1 flow: its story IS its file pages
            kind = (k in SEEN) ? "P" : "R"
            sl = slug9(nm); if (sl == "") sl = "server-failing-" j
            while ((sl in USED)) sl = sl "-2"       # a separator twin took the name
            USED[sl] = 1
            st = (k in RFS) ? RFS[k] : ((k in KTS) ? KTS[k] : ((k in LFD) ? LFD[k] : ""))
            rs = (k in KRE) ? KRE[k] : ((k in BXR) ? BXR[k] : "")
            print nm "\t" sl "\t" st "\t" rs "\t" kind > OUTS
        }
        close(OUTS)
    }
' /dev/null

_flap "the server-failing set"
if [ "$FAILED_MODE" = catchup ]; then
    # only the REASON column may change (the boxes) — a different set, slug,
    # stamp or kind would mean the server-log passes are stale: a full run
    if ! cmp -s <(cut -f1,2,3,5 "$TMP/srvsubs") <(cut -f1,2,3,5 "$STATE/srvsubs"); then
        echo "failed.sh catchup: the server-failing set changed since the full run — a full run." >&2
        rm -rf "$TMP"; trap - EXIT
        exec "$0" full
    fi
    cp "$STATE/srvsess2" "$TMP/srvsess2"   # the set computation above truncated it
fi
if [ "$FAILED_MODE" = full ]; then   # ---- the two server-log passes (the catch-up keeps the full run's)
# ---- "What the server log said" — ONE pass over the server parse cache ------
# The transfer CSVs never carry a failure reason (their detail fields are
# always UNKNOWN); the server log does. Two joins, both resolved in this single
# scan of the 18M-line cache (testing every line against every id would be 100
# CoreIds x ~15 ids):
#
#   SESSION (2026-08, the main one) — the transfer legs carry the technical
#   connection in col 24 and the server cache now carries the same id in col 6,
#   so every line of the conversation a leg took part in is matched, not only
#   the lines that happen to name the file. That is what the error pages show:
#   the whole session, in order, message verbatim.
#
#   ID (2026-08-24: ANY mention) — every 36-char UUID in the message looked up
#   in one map of the page'"'"'s CoreId + its legs'"'"' transfer ids (col 23), whatever
#   words surround it. The join used to recognise three FORMS — "coreId":"…" /
#   "transferId":"…" at a fixed offset, and the segments of an .stfs object
#   path — and matched NOTHING: the JSON bookends are noise-filtered since
#   2026-08 and no .stfs segment is ever a transfer id or CoreId (measured over
#   both caches: 0 hits). The log names a transfer id BARE — `Error while
#   resubmitting transfer with id '…'` (E, on the ADMIN session the resubmit
#   came in on, which no leg carries), the AR0086 `PostProcessingAction$Delete
#   (transferStatusId={…})` bookkeeping on the route'"'"'s session, `Transfer
#   resume logged. TransferStatus.Id: "…"`, the manual-acknowledgment lines —
#   and most of those sit on the file'"'"'s own session anyway. What the session
#   join cannot reach: ~1,900 lines over 1,682 acceptance pages (257 an E
#   line, 15 of them the page'"'"'s ONLY E line), 141 over 83 production pages
#   (81 the resubmit error). The server log never names a CoreId; the id stays
#   in the map because it costs nothing. The regex costs ~9 s on 5.3M lines —
#   not gated on a word, since a gate is a guess about the next message shape.
#
# Fallback per CoreId, only for pages that neither join matched: the E-level
# lines naming the subscription (28-char prefix — the server truncates long
# names) inside the failure'"'"'s minute window (first leg start .. last leg end).
#
# Every matched line is written out (no per-page cap here — the finishing pass
# caps the page); ordering is left to the sort below, since cache order is not
# chronological.
: > "$TMP/srvlines"
if [ -f "$SRVLOG" ] && [ -s "$TMP/meta" ]; then
    # IN PARALLEL (2026-09-27): one job per core over its own byte range of the
    # server cache (the jobs compute the same line offsets, so the ranges
    # partition the lines, in cache order). The line output is sorted below
    # whatever its order; the reddening-session list keeps its FIRST
    # occurrences, so its parts merge in range order with the same dedup.
    # The single pass (a UUID regex over every message) ran ~16 s on
    # production, and again in the build's catch-up.
    FNJ=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
    case $FNJ in ""|*[!0-9]*) FNJ=2 ;; esac
    FSZ=$(wc -c < "$SRVLOG" | tr -d ' ')
    fpass1() {   # $1 = part index: its range of line starts is [lo, hi)
    local lo=$(( ($1 - 1) * FSZ / FNJ )) hi
    if [ "$1" -eq "$FNJ" ]; then hi=$((FSZ + 1)); else hi=$(( $1 * FSZ / FNJ )); fi
    : > "$TMP/srvsess2.p$1"
    rng_feed "$SRVLOG" "$lo" | LC_ALL=C awk -F'\t' -v SSUBF="$TMP/srvsubs" -v SSOUT="$TMP/srvsess2.p$1" -v RANGEF=/dev/stdin -v RLO="$lo" -v RHI="$hi" -v ROFF="$(rng_off "$lo")" '
        function lvlname(x) { if (x == "I") return "Info"; if (x == "W") return "Warning"
                              if (x == "E") return "Error"; return x }
        function compname(x) { if (x == "T") return "TM"; if (x == "P") return "PESITD"
                               if (x == "S") return "SSHD"; return x }
        # THE HOUR INDEX of the name fallback (2026-09-27): page i goes into
        # HB["yyyy-mm-dd HH"] for every hour its window "yyyy-mm-dd HH:MM"
        # w0..w1 touches; a window over two weeks joins HWIDE, tested for
        # every line. Keys and windows compare as text, as before.
        function jdnf(d,   y, mo, dd, a) { y = substr(d, 1, 4) + 0; mo = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
            a = int((14 - mo) / 12); y = y + 4800 - a; mo = mo + 12 * a - 3
            return dd + int((153 * mo + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045 }
        function fromjdnf(j,   a, b, c2, d2, e2, m2) { a = j + 32044; b = int((4 * a + 3) / 146097); c2 = a - int(146097 * b / 4)
            d2 = int((4 * c2 + 3) / 1461); e2 = c2 - int(1461 * d2 / 4); m2 = int((5 * e2 + 2) / 153)
            return sprintf("%04d-%02d-%02d", 100 * b + d2 - 4800 + int(m2 / 10), m2 + 3 - 12 * int(m2 / 10), e2 - int((153 * m2 + 2) / 5) + 1) }
        function hbucket(i, a, b,   h0, h1, h) {
            if (a !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]/ || b !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]/) { HWIDE = HWIDE " " i; return }
            h0 = jdnf(a) * 24 + substr(a, 12, 2); h1 = jdnf(b) * 24 + substr(b, 12, 2)
            if (h1 - h0 > 336) { HWIDE = HWIDE " " i; return }
            for (h = h0; h <= h1; h++) HB[fromjdnf(int(h / 24)) " " sprintf("%02d", h % 24)] = HB[fromjdnf(int(h / 24)) " " sprintf("%02d", h % 24)] " " i
        }
        # one output line per (page, server line): the page CoreId, the section
        # kind (I = this file/connection, N = the window fallback), the cache
        # columns and why it matched. The message is kept whole up to 4000
        # chars — a stack-trace-sized payload is cut with an ellipsis rather
        # than carried into the page.
        function emit(c, kind, why,   msg) {
            msg = $5
            if (length(msg) > 4000) msg = substr(msg, 1, 4000) " …"
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                   c, kind, $1, $2, lvlname($3), compname($4), $6, why, msg
        }
        # the server-failing flows evidence stamps (S1): an E line whose
        # "date time" equals one names, via its SESSION, the connection the
        # red verdict rests on — the second pass collects its whole
        # conversation for the errors/<slug> page
        BEGIN { while ((getline l9 < SSUBF) > 0) { n9 = split(l9, a9, "\t")
                    if (n9 >= 3 && a9[3] ~ /^[0-9][0-9][0-9][0-9]-/)
                        WS[a9[3]] = ((a9[3] in WS) ? WS[a9[3]] SUBSEP a9[1] : a9[1]) }
                close(SSUBF)
                # the id join'"'"'s UUID shape (8-4-4-4-12 hex), spelled out — no
                # interval expressions, they are not portable across awks
                H4 = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
                UUID = H4 H4 "-" H4 "-" H4 "-" H4 "-" H4 H4 H4 }
        # by ARGV POSITION, not an FNR==1 counter: an EMPTY side file (no
        # session ids at all) never fires FNR==1 and shifted every later file
        # onto the wrong branch (2026-09-28 fix)
        FILENAME == ARGV[1] { idmap[$1] = $2; next }  # ids: transfer_id/CoreId -> CoreId
        FILENAME == ARGV[2] {                         # sess: session -> CoreId(s)
            # if/else, never A[k] = (k in A) ? …: mawk creates the key before the
            # test runs, and every first value gained a leading separator
            if ($1 in sesmap) sesmap[$1] = sesmap[$1] " " $2; else sesmap[$1] = $2
            next
        }
        FILENAME == ARGV[3] {                         # meta: coreid, site, date, time, endt, nses
            nc++; C[nc] = $1
            w0[$1] = $3 " " substr($4, 1, 5)
            w1[$1] = ($5 == "") ? w0[$1] : substr($5, 1, 16)
            if (w1[$1] < w0[$1]) w1[$1] = w0[$1]
            pfx[$1] = substr($2, 1, 28)
            if (gmin == "" || w0[$1] < gmin) gmin = w0[$1]
            if (w1[$1] > gmax) gmax = w1[$1]
            hbucket(nc, w0[$1], w1[$1])
            next
        }
        FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
        {                                             # the server parse cache
            m = $5
            # the ID join: every UUID the message carries, in whatever words;
            # idc = the pages this line reached by id (a line can name the ids
            # of several files — one row per page, never two for one)
            split("", idc); s = m
            while (match(s, UUID)) {
                id = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
                if ((id in idmap) && !(idmap[id] in idc)) {
                    mc = idmap[id]; idc[mc] = 1; hit[mc] = 1; emit(mc, "I", "id")
                }
            }
            # the SESSION join: one line can belong to several pages when a
            # connection carried more than one of these files, and the id match
            # above already covered its own page — never emit it twice there
            if ($6 != "" && ($6 in sesmap)) {
                n = split(sesmap[$6], cl, " ")
                for (i = 1; i <= n; i++)
                    if (!(cl[i] in idc)) { hit[cl[i]] = 1; emit(cl[i], "I", "session") }
            }
            if ($3 != "E") next                       # the name fallback is E-level only
            # the reddening-session discovery (see the BEGIN block above)
            if ($6 != "") { k9 = $1 " " $2
                if (k9 in WS) { n9 = split(WS[k9], w9, SUBSEP)
                    for (i9 = 1; i9 <= n9; i9++)
                        if (!ssd[w9[i9], $6]++) print w9[i9] "\t" $6 > SSOUT } }
            k = $1 " " substr($2, 1, 5)
            if (k < gmin || k > gmax) next            # outside every window
            # only the pages whose window covers this HOUR (+ the few wide
            # ones) — the same exact tests as the former walk over EVERY page
            # per E line (E lines x pages: the pass'"'"'s cost on production);
            # the sort below orders the output, so the walk order does not
            # matter
            nb = split(HB[substr(k, 1, 13)] HWIDE, bl, " ")
            for (i = 1; i <= nb; i++) {
                c = C[bl[i]]
                if (c in idc) continue                # already kept by id
                if (k >= w0[c] && k <= w1[c] && index(m, pfx[c]) > 0) emit(c, "N", "window")
            }
        }
    ' "$TMP/ids" "$TMP/sess" "$TMP/meta" /dev/stdin > "$TMP/srvlines.p$1"
    }
    fpids=(); fparts=(); fsess=()
    for ((pi = 1; pi <= FNJ; pi++)); do fpass1 "$pi" & fpids+=("$!"); fparts+=("$TMP/srvlines.p$pi"); fsess+=("$TMP/srvsess2.p$pi"); done
    for p in "${fpids[@]}"; do wait "$p"; done
    LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 -k4,4 "${fparts[@]}" > "$TMP/srvlines"
    awk '!s[$0]++' "${fsess[@]}" > "$TMP/srvsess2"
    rm -f "${fparts[@]}" "${fsess[@]}"
fi

_flap "server log pass 1 (what the server log said)"
# ---- the reddening sessions' conversations (2026-08) ------------------------
# ONE more pass over the server cache: every line of the sessions the scan
# above resolved from the server-failing flows' evidence stamps, so their
# errors/<slug> pages show the WHOLE conversation of the connection that
# logged the reddening error — exactly like a file page's session section,
# and never the flow's unrelated older mentions. Skipped when nothing was
# resolved (no server-failing flows, a stamp outside the exports, or the
# scan above did not run — the pages then fall back to the mention ring).
: > "$TMP/srvsublines"
if [ -f "$SRVLOG" ] && [ -s "$TMP/srvsess2" ]; then
    # IN PARALLEL (2026-09-27, speed round 10): byte ranges of the server
    # cache like pass 1 — it ran single-threaded over the whole cache, twice
    # per build (the catch-up re-run on the critical path). The sort below
    # orders the lines whatever the part order (ties fall to the whole line),
    # so the result is the single pass's.
    FNJ2=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
    case $FNJ2 in ""|*[!0-9]*) FNJ2=2 ;; esac
    FSZ2=$(wc -c < "$SRVLOG" | tr -d ' ')
    fpass2() {   # $1 = part index: its range of line starts is [lo, hi)
    local lo=$(( ($1 - 1) * FSZ2 / FNJ2 )) hi
    if [ "$1" -eq "$FNJ2" ]; then hi=$((FSZ2 + 1)); else hi=$(( $1 * FSZ2 / FNJ2 )); fi
    rng_feed "$SRVLOG" "$lo" | LC_ALL=C awk -F'\t' -v SS="$TMP/srvsess2" -v RANGEF=/dev/stdin -v RLO="$lo" -v RHI="$hi" -v ROFF="$(rng_off "$lo")" '
        function lvlname(x) { if (x == "I") return "Info"; if (x == "W") return "Warning"
                              if (x == "E") return "Error"; return x }
        BEGIN { while ((getline l < SS) > 0) { p = index(l, "\t")
                    if (p > 0) { s = substr(l, p + 1); m = substr(l, 1, p - 1)
                        if (s in SM) SM[s] = SM[s] "\n" m; else SM[s] = m } }   # if/else: see sesmap above
                close(SS) }
        FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
        $6 != "" && ($6 in SM) {
            msg = $5
            if (length(msg) > 4000) msg = substr(msg, 1, 4000) " …"
            n = split(SM[$6], sl9, "\n")
            for (i = 1; i <= n; i++)
                printf "%s\t%s\t%s\t%s\t%s\n", sl9[i], $1, $2, lvlname($3), msg
        }
    ' /dev/stdin > "$TMP/srvsub.p$1"
    }
    fpids2=(); fparts2=()
    for ((pi = 1; pi <= FNJ2; pi++)); do fpass2 "$pi" & fpids2+=("$!"); fparts2+=("$TMP/srvsub.p$pi"); done
    for p in "${fpids2[@]}"; do wait "$p"; done
    LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 "${fparts2[@]}" > "$TMP/srvsublines"
    rm -f "${fparts2[@]}"
fi

# The finishing pass: append the server-log section (where one exists) and the
# LINK + FOOT every drill page ends with — the awk above wrote the pages
# WITHOUT them, so appending here keeps LINK/FOOT the last lines. `>>` is
# deliberate (a fresh awk process'"'"'s `>` would truncate the finished pages).
if [ -s "$TMP/meta" ]; then
    LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" -v CAP="$SRVCAP" -v FILEDIR="$FILEDIR" -v FSETF="$TMP/fileset" '
        # the FILE pages live in FILEDIR (2026-09-03): the same sections, the
        # page path and the back link decided per CoreId
        BEGIN { while ((getline l9 < FSETF) > 0) { split(l9, y9, "\t"); if (y9[1] != "") { FSET[y9[1]] = 1; FSRC[y9[1]] = y9[2] } } close(FSETF) }
        function pdir(c9) { return ((c9 in FSET) ? FILEDIR : ERRDIR) }
        # srvlines: coreid, kind, date, time, level, comp, session, why, message
        # — sorted by coreid, kind, date, time, so each page is contiguous and
        # its lines are already in the order they happened. Read TWICE: the
        # first pass counts (the intro states the totals before the rows), the
        # second writes.
        function close_section(f) {
            if (rows == 0) return
            printf "TOTAL\tTotal (%d line(s))\t\t\n", rows >> f
            if (capped) printf "NOTE\tOnly the first **%d** line(s) are shown — this connection logged **%d**.\n", CAP, tot >> f
            rows = 0; capped = 0
        }
        FNR == 1 { nf++ }
        nf == 1 { nm++; MC[nm] = $1; NSES[$1] = $6 + 0; next }        # meta: the page list
        nf == 2 {                                                     # counting pass
            if ($2 == "I") ni[$1]++; else nw[$1]++   # ni decides the fallback, both give the cap NOTE its total
            next
        }
        {                                                             # writing pass
            c = $1; f = pdir(c) "/" c ".rpt"
            if ($2 == "N" && ni[c] > 0) next          # the fallback is for pages nothing else matched
            if (c != prevc) {
                if (prevc != "") { close_section(prevf); close(prevf) }
                prevc = c; prevf = f
                tot = (ni[c] > 0) ? ni[c] : nw[c]
                # No prose line above this table (2026-08): the columns say what
                # it is. The FALLBACK still gets one — those lines are the weak
                # kind of evidence and saying so is the point.
                if (ni[c] == 0)
                    printf "INTRO\tNo server-log line carries this file'"'"'s session, CoreId or transfer IDs. Shown instead: the **%d** Error line(s) naming this subscription inside the failure'"'"'s time window, oldest first.\n", nw[c] + 0 >> f
                printf "TABLE\t\twide\trestint\tnosort\tnosearch\n" >> f
                printf "HEAD\tDate & time\tLevel\tLine\n" >> f
                printf "KIND\ttext\ttext\tpre\n" >> f
            }
            if (rows >= CAP + 0) { capped = 1; next }
            res = ($5 == "Error") ? "\t@data:res=red" : (($5 == "Warning") ? "\t@data:res=orange" : "")
            printf "ROW\t%s %s\t%s\t%s%s\n", $3, $4, $5, $9, res >> f
            rows++
        }
        END {
            if (prevc != "") { close_section(prevf); close(prevf) }
            for (i = 1; i <= nm; i++) {
                f = pdir(MC[i]) "/" MC[i] ".rpt"
                # a File page (the latest-OK set, O) has no back link — the
                # facts table links its subscription; a drill page links back
                if (!(MC[i] in FSET)) printf "LINK\t../analyses/failed.html\tBack to Failed Subscriptions\n" >> f
                printf "FOOT\n" >> f
                close(f)
            }
        }
    ' "$TMP/meta" "$TMP/srvlines" "$TMP/srvlines"
fi

_flap "server log pass 2 (the reddening sessions)"
fi   # (full mode)
# ---- The SERVER-FAILING drill pages (2026-08) -------------------------------
# One errors/<slug>.rpt per server-failing subscription (the set, slugs,
# stamps and reasons come from the S1 sidecar $TMP/srvsubs above). Written
# BEFORE the evidence-sidecar pass below, so these pages' Error/Warning lines
# join _errpage-evidence.tsv exactly like a file drill page's. Content: the
# facts (subscription + configured account, result colours + detail links,
# the evidence stamp), then THE REDDENING SESSION — every server-log line of
# the connection that logged the evidence-stamp Error (the two cache passes
# above resolved stamp → session → lines), the same conversation a file page
# shows and never the flow's unrelated older mentions. The flow's MENTION
# RING (the last-25 + E/W caches, deduped, oldest first) is only the
# FALLBACK when no session line was found: no stamp, a stamp outside the
# exports, or a session-less component logged the error.
LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" -v CAP="$SRVCAP" \
    -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" -v ACCRES="$CONFIG_BASE/_accounts.tsv" \
    -v SAX="$CONFIG_XREF/_subscriptions-accounts.tsv" \
    -v SPX="$CONFIG_XREF/_subscriptions-partners.tsv" -v SLX="$CONFIG_XREF/_subscriptions-logins.tsv" -v SHX="$CONFIG_XREF/_subscriptions-hosts.tsv" \
    -v PTNRES="$CONFIG_BASE/_partners.tsv" -v LGNRES="$CONFIG_BASE/_logins.tsv" -v HSTRES="$CONFIG_BASE/_hosts.tsv" \
    -v MDIR="$DATA/server/cache/subscriptions" -v SLF="$TMP/srvsublines" '
    function resload(f9, A9,   l9, n9, z9) {
        while ((getline l9 < f9) > 0) { n9 = split(l9, z9, "\t")
            if (n9 >= 3 && z9[1] != "") A9[toupper(z9[1])] = z9[3] }
        close(f9) }
    function rescol(A9, nm,   r) { r = (toupper(nm) in A9) ? A9[toupper(nm)] : ""
        return (r == "green" || r == "orange" || r == "red") ? r : "" }
    function entcell(A9, sub9, nm,   r, a) {
        if (nm == "") return "-"
        r = rescol(A9, nm); a = "alink=" sub9 "/" nm
        return "@{" (r != "" ? "class=res-" r "," : "") a "}" nm }
    function lvlname(x) { if (x == "I") return "Info"; if (x == "W") return "Warning"
                          if (x == "E") return "Error"; return x }
    # read one mention-cache file into the shared ring set (key = the whole
    # line, deduping the err_warn overlap); embedded tabs in a message fold
    # to spaces — a cell may not carry TAB
    function ringload(f9,   l9, n9, z9, i9, m9, k9) {
        while ((getline l9 < f9) > 0) {
            n9 = split(l9, z9, "\t")
            if (n9 < 5 || z9[1] == "") continue
            m9 = z9[5]; for (i9 = 6; i9 <= n9; i9++) m9 = m9 " " z9[i9]
            if (length(m9) > 4000) m9 = substr(m9, 1, 4000) " …"
            k9 = z9[1] " " z9[2] "\t" lvlname(z9[3]) "\t" m9
            if (!(k9 in RSEEN)) { RSEEN[k9] = 1; RL[++nrl] = k9 }
        }
        close(f9) }
    function evrow(dtlvlmsg, f,   z, res) {
        split(dtlvlmsg, z, "\t")
        res = (z[2] == "Error") ? "\t@data:res=red" : ((z[2] == "Warning") ? "\t@data:res=orange" : "")
        printf "ROW\t%s\t%s\t%s%s\n", z[1], z[2], z[3], res > f }
    # a subscription -> values pair cache into M[SUB] as a ", "-joined, deduped
    # list (the facts table: one value links like an entity cell, several
    # render as the plain list)
    function joinload(f9, M,   l9, n9, a9, k9) {
        while ((getline l9 < f9) > 0) { n9 = split(l9, a9, "\t")
            if (n9 >= 2 && a9[1] != "" && a9[2] != "") { k9 = toupper(a9[1])
                if (M[k9] == "") M[k9] = a9[2]
                else if (index(", " M[k9] ", ", ", " a9[2] ", ") == 0) M[k9] = M[k9] ", " a9[2] } }
        close(f9) }
    # the facts row for one joined value set: absent -> no row (2026-09-03,
    # user request); one value -> the tinted, linked entity cell; several ->
    # the plain list
    function factrow(f, label, v, A9, sub9) {
        if (v == "") return
        if (index(v, ", ") == 0) printf "ROW\t%s\t%s\n", label, entcell(A9, sub9, v) > f
        else printf "ROW\t%s\t%s\n", label, v > f }
    BEGIN {
        resload(SUBRES, SRES); resload(ACCRES, ARES)
        resload(PTNRES, PRES); resload(LGNRES, LRES); resload(HSTRES, HRES)
        # (a subscription page, no File: its CONFIGURED values only — not
        # the per-File union of bin/pda-union.sh)
        # ALL of a subscription'\''s accounts, ", "-joined (a relay has two —
        # first-wins named one arbitrary account as fact; a multi-value cell
        # simply renders unlinked) — and likewise its partners, logins and
        # endpoints for the facts table
        joinload(SAX, ACC); joinload(SPX, PTN); joinload(SLX, LGN); joinload(SHX, HST)
        # the reddening-session lines per subscription, already sorted by
        # (sub, date, time) — "date time \t Level \t message" per entry
        while ((getline l < SLF) > 0) { n = split(l, a, "\t")
            if (n >= 5 && a[1] != "") { k = toupper(a[1])
                SL[k, ++SN[k]] = a[2] " " a[3] "\t" a[4] "\t" a[5] } }
        close(SLF)
    }
    {   # $TMP/srvsubs: name ⇥ slug ⇥ stamp ⇥ reason ⇥ kind (R | P)
        nm = $1; sl = $2; st = $3; rs = $4; kind = $5
        k = toupper(nm)
        f = ERRDIR "/" sl ".rpt"
        printf "TITLE\tFailed subscription: %s%s\n", nm, (rs != "" ? " - " rs : "") > f
        printf "TABLE\t\tnosearch\n" > f
        printf "HEAD\tItem\tValue\n" > f
        printf "KIND\ttext\ttext\n" > f
        printf "ROW\tSubscription\t%s\n", entcell(SRES, "subscriptions", nm) > f
        # Partner, Account, Login, Remote host — the subscription'\''s configured
        # ones, each row only when the configuration has a value (2026-09-03)
        factrow(f, "Partner",     (k in PTN) ? PTN[k] : "", PRES, "partners")
        factrow(f, "Account",     (k in ACC) ? ACC[k] : "", ARES, "accounts")
        factrow(f, "Login",       (k in LGN) ? LGN[k] : "", LRES, "logins")
        factrow(f, "Remote host", (k in HST) ? HST[k] : "", HRES, "hosts")
        printf "ROW\tLast server error\t%s\n", (st != "" ? st : "-") > f
        pre = (kind == "P") \
            ? "This subscription is red for what the SERVER log shows — its newest File ended OK and the server log erred AFTER it, so its failed-File pages are older history." \
            : "This subscription is red for what the SERVER log shows — it has no failed File."
        if (SN[k] + 0 > 0) {
            # THE REDDENING SESSION: the whole conversation of the connection
            # that logged the evidence-stamp Error, oldest first
            printf "INTRO\t%s Below: **the server log of the connection that logged the reddening error** (%s) — the whole conversation, oldest first.\n", pre, st > f
            printf "TABLE\t\twide\trestint\tnosort\tnosearch\n" > f
            printf "HEAD\tDate & time\tLevel\tLine\n" > f
            printf "KIND\ttext\ttext\tpre\n" > f
            tot = SN[k]; shown = (tot > CAP + 0) ? CAP + 0 : tot
            for (i = 1; i <= shown; i++) evrow(SL[k, i], f)
            printf "TOTAL\tTotal (%d line(s))\t\t\n", shown > f
            if (tot > shown)
                printf "NOTE\tOnly the first **%d** line(s) are shown — this connection logged **%d**.\n", shown, tot > f
        } else {
            # the FALLBACK: the flow mention ring, oldest first — both caches
            # are small (25 + 10 rows), an insertion sort on "date time" fits
            nrl = 0; split("", RSEEN); split("", RL)
            ringload(MDIR "/" nm ".tsv")
            ringload(MDIR "/" nm "_err_warn.tsv")
            for (i = 2; i <= nrl; i++) { v = RL[i]
                for (p = i - 1; p >= 1 && RL[p] > v; p--) RL[p + 1] = RL[p]
                RL[p + 1] = v }
            if (nrl > 0) {
                printf "INTRO\t%s No server-log line of the reddening connection could be isolated, so below are its newest server-log MENTIONS (the per-entity ring the detail page also shows), oldest first.\n", pre > f
                printf "TABLE\t\twide\trestint\tnosort\tnosearch\n" > f
                printf "HEAD\tDate & time\tLevel\tLine\n" > f
                printf "KIND\ttext\ttext\tpre\n" > f
                for (i = 1; i <= nrl; i++) evrow(RL[i], f)
                printf "TOTAL\tTotal (%d line(s))\t\t\n", nrl > f
            } else
                printf "INTRO\t%s Its server-log mention ring is empty: the evidence is on the subscription'"'"'s detail page and the report its box names.\n", pre > f
        }
        printf "LINK\t../analyses/failed.html\tBack to Failed Subscriptions\n" > f
        printf "FOOT\n" > f
        close(f)
    }
' "$TMP/srvsubs"

if [ "$FAILED_MODE" = full ]; then   # ---- the evidence sidecar + the File reasons (the catch-up keeps the full run's)
# The ERROR-PAGE EVIDENCE sidecar (2026-08): per subscription, the newest
# Error/Warning line any of its drill pages shows. The Boxes reason
# (reason-boxes.sh pagereason) names the fault behind a red flow from the
# server log, and its other source —
# the kaput-evidence sidecar — only covers flows whose LAST TRANSFER WAS OK. A flow
# whose last transfer FAILED and which sits in no specific box therefore had no
# reason at all, though its own error page was showing the very line that
# explains it (an ARRC0029 routing-step warning, in the case that found this).
# The drill .rpt carries the subscription in its facts table (TABLE 1, the
# Subscription row — its TITLE until 2026-09-30) and the log lines as
# "ROW <date time> <Level> <message>".
#
# Per subscription, the FIRST few Error/Warning lines of its NEWEST drill page.
#
# THE FIRST ERROR, not the newest: the opening error of a failure is the cause
# and everything after it is consequence — a rejected host key, then "failed to
# create connection", then the connection failure, then a trailing ARRC0029
# "No files were processed during step execution". Reading from the end names
# the symptom; reading from the start names the fault.
#
# The NEWEST page, because that is the one the Failed Subscriptions row links
# to: a flow with
# several drill pages must be explained by the failure the reader opens, not by
# an older one. Each page is buffered as it is read and replaces the flow
# incumbent when its lines are newer.
#   subscription <TAB> "date time" <TAB> level (Error|Warning) <TAB> message
EVID="$REPORTS_DIR/_errpage-evidence.tsv"
LC_ALL=C awk -F'\t' -v CAND=8 "$(cat "$LIB_DIR/../flip-reason.awk")"'
    function flush(   i) {                      # the buffered page -> its subscription
        if (site == "" || fn == 0) return
        if (fmax > best[site]) { best[site] = fmax; bn[site] = fn
            for (i = 1; i <= fn; i++) { bs[site, i] = fs[i]; bl[site, i] = fl[i]; bm[site, i] = fm[i] } }
    }
    # an error BOOKEND of one of the page own legs is a candidate too
    # (2026-09-10): the Info line {"message":"Transfer end logged.",
    # "status":"error",…} whose transferId is in the legs table (TABLE 2,
    # cell 9) — the only evidence a silently dropped connection leaves; the
    # classifier reads it "Unknown error" and, walking
    # errors first, lets any real error line outrank it
    function ownbookend(m,   t9) {
        if (index(m, "{\"message\":\"Transfer end logged.\"") != 1 || index(m, "\"status\":\"error\"") == 0) return 0
        t9 = m; if (!sub(/.*"transferId" *: *"/, "", t9)) return 0
        sub(/".*/, "", t9); return (t9 in ptid) }
    FNR == 1 { flush(); site = ""; fn = 0; fmax = ""; prev = ""; tno = 0; split("", ptid) }
    $1 == "TABLE" { prev = ""; tno++ }
    # the page subscription = the facts table (TABLE 1) Subscription row,
    # its cell attribute block stripped ("-" = none). Until 2026-09-30 it was
    # parsed from the TITLE, which the CoreId pages no longer carry (they are
    # titled by the File) and which a server-failing page suffixes with
    # " - <reason>" — such a page never joined the sidecar under its name
    $1 == "ROW" && tno == 1 && $2 == "Subscription" { site = $3; sub(/^@\{[^}]*\}/, "", site)
                    if (site == "-") site = ""; next }
    $1 == "ROW" && tno == 2 && NF >= 9 && $9 != "" { ptid[$9] = 1 }   # the legs table: the page own transfer ids
    $1 == "ROW" && site != "" && NF >= 4 && ($3 == "Error" || $3 == "Warning" || ($3 == "Info" && ownbookend($4))) {
        if ($2 > fmax) fmax = $2                # the page own newest line, for picking the page
        if (fn < CAND) { fn++; fs[fn] = $2; fl[fn] = $3; fm[fn] = ctx_enrich(substr($4, 1, 200), prev) }   # a bare "Permission denied" carries the line before it
    }
    $1 == "ROW" && NF >= 4 { prev = $4 }   # the previous line of the page, for ctx_enrich
    END { flush()
          for (k in bn) for (i = 1; i <= bn[k]; i++)
              printf "%s\t%s\t%s\t%s\n", k, bs[k, i], bl[k, i], bm[k, i] }
' "$ERRDIR"/*.rpt 2>/dev/null | LC_ALL=C sort > "$EVID.tmp" || : > "$EVID.tmp"
mv "$EVID.tmp" "$EVID"

# The REASON pass (2026-08): one Reason per FAILED CoreId ($TMP/reasons,
# coreid ⇥ reason, blank kept), now that the finishing pass has appended the
# server-log sections and the EVIDENCE sidecar above is fresh. FIVE sources
# per file, each walked ERROR lines first in page order with the first
# classification winning (the opening error of a failure is the cause,
# everything after it consequence):
#   1. the file's OWN drill page (paged CoreIds only) — its first 8
#      Error/Warning ROW lines, the same candidate rule the sidecar applies.
#      Each file explains ITS OWN failure where it can.
#   2. ONE-LEGGED (2026-08): a file its own page did not classify which
#      took a single leg reads "One-legged" — the Boxes page names that box for
#      exactly these flows (a lone inbound arrival, nothing ever went out),
#      and the two pages should agree. BEFORE the flow borrow below
#      (2026-08-22): a one-legged file whose own session logged only clean
#      lines was inheriting a stale "Connection failures" verdict from a
#      19-day-older page of the same flow — the page's own evidence
#      contradicted its own title. What the file's legs say outranks what a
#      DIFFERENT file's page said. Since 2026-09-21 (user rule) a one-leg file
#      its page classified only as "Unknown error" — the classifier's LAST
#      rule, the bare error bookend — reads "One-legged" too.
#   3. the PAIR borrow (2026-08): an UNPAGED file with nothing of its own
#      takes the reason of the NEWEST PAGED file of its (subscription, legs)
#      pair — the same failure shape, much closer evidence than the flow's
#      newest page, which may be a different failure entirely (the case that
#      found this: a flow whose newest page is a One-legged arrival with only
#      a benign batchSize warning left its old 7- and 12-leg failures blank
#      while their paged pair twins said "PeSIT transfer aborted" and
#      "Connection failures"). The newest paged file ONLY, blank included —
#      an older sibling's page must not outvote the pair's newest evidence,
#      the same staleness rule that narrowed the flow borrow.
#   4. the FLOW's sidecar candidates — the newest page of that subscription BY
#      SERVER-LINE STAMP, which is reason-boxes.sh pagereason()'s exact
#      first-priority source for the Boxes reasons. A MULTI-leg file
#      whose sessions logged no error at all still gets the flow's verdict.
#   5. the LAST LEG's raw Status ("Failed Subtransmission") — from the page
#      for a paged file, from the $TMP/lastst sidecar for an unpaged one.
#      Only when it is more specific than a bare "Failed": a
#      reason must name a fault, never restate the outcome.
# flip_reason() is the SHARED classifier (bin/flip-reason.awk).
#      Still blank when no rule applies: better than a guess.
LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" -v EVID="$EVID" -v PAGEDF="$TMP/paged" -v LASTF="$TMP/lastst" -v CAND=8 \
    -v FILEDIR="$FILEDIR" -v FSETF="$TMP/fileset" \
    "$(cat "$LIB_DIR/../flip-reason.awk")"'
    BEGIN { # the Files with a FILE page (files/, neutral wording, no list
            # link): classified from THAT page too (2026-09-28 fix — they took
            # the pair or flow verdict over the evidence on their own page)
            while ((getline l < FSETF) > 0) { split(l, a, "\t"); if (a[1] != "") FS9[a[1]] = 1 }
            close(FSETF)
            while ((getline l < EVID) > 0) {
                n = split(l, a, "\t")
                if (n >= 4 && a[1] != "") { k = toupper(a[1])
                    en[k]++; el[k, en[k]] = a[3]; em[k, en[k]] = a[4] } }
            close(EVID)
            while ((getline l < PAGEDF) > 0) if (l != "") PG[l] = 1
            close(PAGEDF)
            while ((getline l < LASTF) > 0) { n = split(l, a, "\t")
                if (n >= 2 && a[1] != "") LST[a[1]] = a[2] }
            close(LASTF) }
    function classify(fn, fl, fm,   i, r) {
        for (i = 1; i <= fn; i++) if (fl[i] == "Error") { r = flip_reason(fm[i]); if (r != "") return r }
        for (i = 1; i <= fn; i++) if (fl[i] != "Error") { r = flip_reason(fm[i]); if (r != "") return r }
        return "" }
    # Reads the file page once: the server-section E/W candidates for the
    # classifier AND, as a side effect, LEGST — the LAST leg raw Status from
    # the legs table (TABLE 2; the server section is TABLE 3, so it is
    # complete before the break can fire). The legs table sits between the
    # facts and the server log on every page.
    # an error BOOKEND of one of the file own legs is a candidate too
    # (2026-09-10, see the evidence sidecar above): the Info line whose
    # transferId is in the legs table — the silently dropped connection
    function ownbookend(m, ptid,   t9) {
        if (index(m, "{\"message\":\"Transfer end logged.\"") != 1 || index(m, "\"status\":\"error\"") == 0) return 0
        t9 = m; if (!sub(/.*"transferId" *: *"/, "", t9)) return 0
        sub(/".*/, "", t9); return (t9 in ptid) }
    function pagereason(cid,   f, l, a, n, fn, fl, fm, t, prev, ptid) {
        f = ((cid in FS9) ? FILEDIR : ERRDIR) "/" cid ".rpt"; fn = 0; t = 0; LEGST = ""; prev = ""; split("", ptid)
        while ((getline l < f) > 0) {
            if (fn >= CAND) break
            n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; prev = ""; continue }
            if (a[1] != "ROW") continue
            if (t == 2 && a[2] != "") LEGST = a[2]
            if (t == 2 && n >= 9 && a[9] != "") ptid[a[9]] = 1   # the legs table: the file own transfer ids
            # a bare "Permission denied" takes its meaning from the line before it (ctx_enrich, flip-reason.awk)
            if (n >= 4 && (a[3] == "Error" || a[3] == "Warning" || (a[3] == "Info" && ownbookend(a[4], ptid)))) {
                fn++; fl[fn] = a[3]; fm[fn] = ctx_enrich(substr(a[4], 1, 200), prev) }
            if (n >= 4) prev = a[4]
        }
        close(f)
        return classify(fn, fl, fm) }
    function flowreason(site,   k, i, fn, fl, fm) {
        k = toupper(site); fn = 0
        if (!(k in en)) return ""
        for (i = 1; i <= en[k]; i++) { fn++; fl[fn] = el[k, i]; fm[fn] = em[k, i] }
        return classify(fn, fl, fm) }
    {   # $TMP/all: sortkey, coreid, site, legs, date, time, outcome, marks
        cid = $2; site = $3; legs = $4
        LEGST = ""
        # an EXPIRED File (2026-09-29: the lists carry every File in error,
        # the site-wide Error rule) reads the Failed files wording
        if ($7 == "Expired") { print cid "\tExpired (not collected)"; next }
        if (cid in PG) {
            r6 = pagereason(cid)
            # "Unknown error" on a ONE-LEG file reads One-legged (2026-09-21,
            # user rule): the classifier LAST rule only says an error bookend
            # closed the connection — on a file that took a single leg the
            # missing second leg IS the story, the verdict rule 2 gives every
            # other unclassified one-leg file. Before the PAIR store, so the
            # pair donates the final verdict.
            if (r6 == "Unknown error" && legs + 0 == 1) r6 = "One-legged"
            # the PAIR verdict: the stream is newest first, so the FIRST
            # paged row of a (subscription, legs) pair is that pair NEWEST
            # page — it donates its reason to the unpaged (older, off-window)
            # siblings of the pair below. Stored even when blank: an older
            # sibling page must not outvote the pair newest evidence.
            if (!((site, legs) in PAIRR)) PAIRR[site, legs] = r6
        }
        else if (cid in FS9) {   # its own FILE page (never a pair donor)
            r6 = pagereason(cid)
            if (r6 == "Unknown error" && legs + 0 == 1) r6 = "One-legged"
        }
        else { r6 = ""; if (cid in LST) LEGST = LST[cid] }
        if (r6 == "" && legs + 0 == 1) r6 = "One-legged"
        # rule 3, the PAIR borrow (unpaged files only — a paged file whose
        # own page classified nothing must not take a sibling verdict over
        # its own evidence)
        if (r6 == "" && !(cid in PG) && ((site, legs) in PAIRR)) r6 = PAIRR[site, legs]
        if (r6 == "") r6 = flowreason(site)
        if (r6 == "" && LEGST != "" && LEGST != "Processed" && LEGST != "Failed") r6 = LEGST
        print cid "\t" r6
    }
' "$TMP/all" > "$TMP/reasons"
# the per-CoreId reasons SAVED for the Failed files report (2026-09-14, user
# request: failed-files.sh shows them per File)
LC_ALL=C sort "$TMP/reasons" > "$REPORTS_DIR/_failed-reasons.tsv.tmp" 2>/dev/null || : > "$REPORTS_DIR/_failed-reasons.tsv.tmp"
mv "$REPORTS_DIR/_failed-reasons.tsv.tmp" "$REPORTS_DIR/_failed-reasons.tsv"

# The same Reason lands on each Error File page as a "Reason" row of its
# facts table, right after Date/time — so the page answers WHY at the top
# (2026-08 in the TITLE, "Failed subscription: <name> - <reason>"; a facts
# row since 2026-09-30, audit D-03, when every CoreId page became "File:
# <name>" — and the File pages of Error Files, files/, carry it too: they
# showed no reason at all). Rewrite-in-place: the page is buffered whole,
# then written back with the one row added. Only the pages that RENDER
# (2026-09-29 audit): a CoreId page outside the published set
# (_filepages.tsv) stays an evidence intermediate.
if [ -s "$TMP/reasons" ]; then
    LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" -v FILEDIR="$FILEDIR" -v FPF="$FPF" '
        BEGIN { while ((getline l < FPF) > 0) { split(l, a, "\t"); if (a[1] != "") pub[a[1]] = 1 } close(FPF) }   # (not FNR==NR: FPF may be empty)
        function addreason(f, r,   n, i, l, done) {
            n = 0
            while ((getline l < f) > 0) buf[++n] = l
            close(f)
            if (n == 0) return
            done = 0
            for (i = 1; i <= n; i++) {
                print buf[i] > f
                if (!done && index(buf[i], "ROW\tDate/time\t") == 1) { print "ROW\tReason\t" r > f; done = 1 }
            }
            close(f)
            for (i = 1; i <= n; i++) delete buf[i]
        }
        { cid = $1; r = $2; if (cid == "" || r == "") next
          if (cid ~ /^[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+$/ && !(cid in pub)) next
          addreason(ERRDIR "/" cid ".rpt", r)
          addreason(FILEDIR "/" cid ".rpt", r) }
    ' "$TMP/reasons"
fi
fi   # (full mode)

_flap "server-failing pages + the reasons"
# ---- The TWO lists (see the header) -----------------------------------------
# One pass over $TMP/all writes both bodies to .rpt.tmp files; the mv set
# below publishes them together, AFTER the drill tree and its server-log
# sections are complete — a killed run leaves the OLD complete set rather
# than truncated lists. Rows stream newest first, so every list is newest first (the
# appended server rows land at the end; the page default sort — Date/time,
# descending — interleaves them on load).
LC_ALL=C awk -F'\t' -v RD="$REPORTS_DIR" \
    -v REAS="$TMP/reasons" -v FPF="$FPF" -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" \
    -v SRVS="$TMP/srvsubs" -v SESSF="$TMP/srvsess2" -v RF="$RFLIP" -v LOKF="$TMP/lastok" -v MJF="$TMP/maxjd" \
    -v RRUN="$REPORTS_DIR/_red-run.tsv" '
    function rescol(nm,   r) { r = (toupper(nm) in SRES) ? SRES[toupper(nm)] : ""
        return (r == "green" || r == "orange" || r == "red") ? r : "" }
    function cl(s) { sub(/^@\{[^}]*\}/, "", s); return s }
    # the RED-RUN columns (2026-09-29: the From green to red and Only red
    # pages went — their figures ride here, after the CoreID column so the
    # positional readers keep fields 3-5): Last green day ("never" for a flow
    # that never delivered), Days red, Failures in a row
    function redcols(nm,   k) { k = toupper(nm)
        if (k in RLG) return "\t" RLG[k] "\t" RDR[k] "\t" RCF[k]
        return "\t\t\t" }
    function jdn(y, m, d,   a) { a = int((14 - m) / 12); y = y + 4800 - a; m = m + 12 * a - 3
        return d + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045 }
    # ... and a SERVER row\047s (2026-09-29 audit — they read blank): Last green
    # day = its newest OK File\047s day ("never"), Days red = from the flip\047s
    # SINCE (_redflip.tsv col 3, when it went red — not its newest evidence)
    # to the data window\047s last day, Failures in a row blank (no failed File
    # is the current story)
    function srvcols(nm,   k, s9, dr) { k = toupper(nm); dr = ""
        if (k in RSN) { s9 = RSN[k]
            if (s9 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
                dr = MAXJ - jdn(substr(s9, 1, 4) + 0, substr(s9, 6, 2) + 0, substr(s9, 9, 2) + 0)
                if (dr < 0) dr = 0 } }
        return "\t" ((k in LOKD) ? LOKD[k] : "never") "\t" dr "\t" }
    BEGIN {
        while ((getline l < RF) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "") RSN[toupper(a[1])] = (n >= 3 && a[3] != "") ? a[3] : a[2] }
        close(RF)
        while ((getline l < LOKF) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "") LOKD[toupper(a[1])] = a[2] }
        close(LOKF)
        if ((getline l < MJF) > 0) MAXJ = l + 0
        close(MJF)
        # _red-run.tsv (red-run.sh, 2026-09-30 — the from-green-to-red /
        # only-red .rpt files before): 1 subscription, 2 kind G|N, 3 last green
        # day ("never" for N), 5 days red, 6 run (G: consecutive failures,
        # N: its Files) — written by the report pool, present on the catch-up
        # run (the first run leaves the columns blank, the catch-up fills them)
        while ((getline l < RRUN) > 0) { n = split(l, a, "\t")
            if (n >= 6 && a[1] != "") { k = toupper(a[1]); RLG[k] = a[3]; RDR[k] = a[5]; RCF[k] = a[6] } }
        close(RRUN)
        while ((getline l < SUBRES) > 0) { n = split(l, a, "\t")
            if (n >= 3 && a[1] != "") SRES[toupper(a[1])] = a[3] }
        close(SUBRES)
        while ((getline l < REAS) > 0) { p = index(l, "\t")
            if (p > 0) RE[substr(l, 1, p - 1)] = substr(l, p + 1) }
        close(REAS)
        # PUBLISHED pages only (2026-09-29): a row links its File page when
        # _filepages.tsv lists it (kind E — the three newest Failed Files of
        # its subscription); the evidence pages PAGEDF lists stay unpublished
        while ((getline l < FPF) > 0) { split(l, a9, "\t"); if (a9[2] == "E") PG[a9[1]] = 1 }
        close(FPF)
        # the server-failing set (name ⇥ slug ⇥ stamp ⇥ reason ⇥ kind),
        # written by the page step above together with the errors/<slug>
        # drill pages. EVERY entry gets a server row on both lists (2026-08;
        # it was kind R only): kind R (no failed File anywhere) is the one
        # row of the flow; kind P (server-reddened WITH failed Files)
        # REPLACES the file row of the flow — the CURRENT story is the server
        # verdict, exactly what the flow colour says.
        while ((getline l < SRVS) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "") { nsv++
                SVN[nsv] = a[1]; SVS[nsv] = a[2]
                SVT[nsv] = (n >= 3) ? a[3] : ""; SVR[nsv] = (n >= 4) ? a[4] : ""
                if (n >= 5 && a[5] == "P") PSET[toupper(a[1])] = 1 } }
        close(SRVS)
        # the reddening SESSION of each server-failing flow (name ⇥ session, the
        # scan above: the session of the E line at the flow evidence stamp — the
        # connection its error page shows), the SessionID of its list row; several
        # sessions at one stamp are ", "-joined in file order
        while ((getline l < SESSF) > 0) { p = index(l, "\t")
            if (p > 1) { k = toupper(substr(l, 1, p - 1)); s = substr(l, p + 1)
                # emptiness, not membership: mawk creates SVSES[k] before the RHS runs
                if (s != "") SVSES[k] = ((SVSES[k] != "") ? SVSES[k] ", " : "") s } }
        close(SESSF)
        NP = split("sub-failing sub-all", PK, " ")
        DSC["sub-failing"] = "Every failing subscription — the newest failed File of each, one row per subscription, plus the subscriptions failing in the server log only."
        for (i = 1; i <= NP; i++) {
            k = PK[i]
            f = RD "/" ((k == "sub-failing") ? "failed" : "failed-" k) ".rpt.tmp"
            F[k] = f
            printf "TITLE\tFailed Subscriptions\n" > f
            if (k in DSC) printf "DESC\t%s\n", DSC[k] > f   # the Reports start page reads the DESC of failed.rpt only
            # Newest first is the page DEFAULT (Date/time, desc), not `nosort` —
            # the rows arrive by recency but must still be sortable by any
            # column. `restint` + the per-row @data:res: the row carries its
            # SUBSCRIPTION result colour, red still failing / green recovered
            # since — on the still-failing list effectively all red, the greens
            # being filtered. NOSEARCH and the rows BAKED (2026-08, replacing
            # the search-on-demand payloads): one row per subscription.
            # Subscription · Date/time · Reason · Last green day · Days red ·
            # Failures in a row · CoreId / SessionId (the id LAST since
            # 2026-09-29, user request — a failed File row its CoreId, a
            # server-log row the SESSION of its reddening error line, never a
            # transfer id; the Environment letter column in front went
            # 2026-09-29, user request) — the positional reader of
            # failed-sub-all.rpt (the Entities Reason, publish_lib.sh) reads
            # Subscription = field 2, Date/time = 3, Reason = 4
            printf "TABLE\t\twide\tsort=1:-1\trowlink\trestint\tnosearch\n" > f
            printf "HEAD\tSubscription\tDate/time\tReason\tLast green day\tDays red\tFailures in a row\tCoreId / SessionId\n" > f
            printf "KIND\tsite\ttext\ttext\ttext\tnum\tnum\tmono\n" > f
        }
    }
    {   # $TMP/all: sortkey, coreid, site, legs, date, time, outcome, marks
        cid = $2; site = $3; legs = $4; d = $5; t = $6; m = $8
        # each subscription newest File (mark S) — but the row of a kind-P
        # flow is its SERVER row, appended in END, never a stale newest file
        if (m !~ /S/ || (toupper(site) in PSET)) next
        if (site == "Unknown") next   # no subscription (2026-09-29): no Failed Subscriptions row — Unknown transfers lists it
        col = rescol(site)
        r = (cid in RE) ? RE[cid] : ""
        tint = (col != "") ? "\t@data:res=" col : ""
        # A PAGED row: the Subscription cell opens the error page —
        # @{nolink=1} drops the automatic entity link a `site` cell would
        # otherwise carry, so the row has ONE destination and no cell that
        # quietly goes somewhere else (the error page names the subscription
        # in its facts table, linked) — and @data:href gives the whole row
        # the same target (rowlink). The CoreId is the LAST column again (headed
        # CoreId / SessionId — a server-log row carries its session there) since
        # 2026-09-21 (report.js links it to File Tracking); the failed-sub-all
        # consumer (the entities Reason) still extracts the
        # page from @data:href. PAGED = PUBLISHED (2026-09-29): the row links
        # only when _filepages.tsv lists the File — an Expired newest failure
        # has no page, so its row takes the unpaged branch (the Subscription
        # cell'"'"'s ordinary detail link, nothing else).
        if (cid in PG)
            row = sprintf("ROW\t@{href=../files/%s.html,nolink=1}%s\t%s %s\t%s%s\t%s\t@data:href=../files/%s.html%s", \
                          cid, site, d, t, r, redcols(site), cid, cid, tint)
        else
            row = sprintf("ROW\t%s\t%s %s\t%s%s\t%s%s", site, d, t, r, redcols(site), cid, tint)
        for (i = 1; i <= NP; i++) {
            k = PK[i]
            if (k == "sub-failing" && col == "green") continue   # hide the recovered
            print row > F[k]; CNT[k]++
        }
    }
    END {
        # THE SERVER-FAILING ROWS (see the header): every server-failing
        # subscription (kind R: no failed File in the data; kind P: reddened
        # by the server log after its last delivery), appended to BOTH lists —
        # red passes both filters. @data:srv=1 is the marker consumers skip;
        # like a file row, the row
        # opens the error page of the flow — files/<slug>.html, NAMED BY THE
        # SUBSCRIPTION, written by the page step above. The page default sort
        # (Date/time desc) interleaves the rows on load.
        for (j = 1; j <= nsv; j++) {
            # CoreId / SessionId: a server-log error shows the SESSION of its
            # reddening line (blank when the scan resolved none), never a CoreId
            sk = toupper(SVN[j])
            srow = sprintf("ROW\t@{href=../files/%s.html,nolink=1}%s\t%s\t%s%s\t%s\t@data:href=../files/%s.html\t@data:srv=1\t@data:res=red", \
                           SVS[j], SVN[j], SVT[j], SVR[j], srvcols(SVN[j]), ((sk in SVSES) ? SVSES[sk] : ""), SVS[j])
            for (i = 1; i <= NP; i++) { print srow > F[PK[i]]; CNT[PK[i]]++ }
        }
        for (i = 1; i <= NP; i++) {
            k = PK[i]; f = F[k]
            printf "TOTAL\tTotal (%d rows)\t\t\t\t\t\t\n", CNT[k] + 0 > f
            printf "FOOT\n" > f
            close(f)
        }
    }
' "$TMP/all"
mv "$OUT.tmp" "$OUT"
for v in $VARIANTS; do mv "$REPORTS_DIR/failed-$v.rpt.tmp" "$REPORTS_DIR/failed-$v.rpt"; done
# The PUBLISHED server-failing sidecar (name ⇥ slug ⇥ stamp ⇥ reason ⇥ kind):
# the Entities Subscriptions/Error view links its Reason cells to the
# errors/<slug> pages through it (publish_lib, kind S) — the slug must come
# from here, never re-derived (the twin-collision suffix).
cp "$TMP/srvsubs" "$REPORTS_DIR/_srvsubs.tsv.tmp" && mv "$REPORTS_DIR/_srvsubs.tsv.tmp" "$REPORTS_DIR/_srvsubs.tsv"
# The map beside it (2026-08): name + slug + evidence stamp, WITHOUT the
# reason/kind columns — what details.sh consumes (the "Server log error"
# section needs the membership, the slug and — through the stamp — the
# reddening-session table, never the reason).
cut -f1-3 "$TMP/srvsubs" > "$TMP/srvsubs.map"
cp "$TMP/srvsubs.map" "$REPORTS_DIR/_srvsubs-map.tsv.tmp" && mv "$REPORTS_DIR/_srvsubs-map.tsv.tmp" "$REPORTS_DIR/_srvsubs-map.tsv"

if [ "$FAILED_MODE" = catchup ]; then
    echo "Data written to $OUT + failed-sub-all.rpt, $(wc -l < "$TMP/srvsubs" | tr -d ' ') server-failing page(s) (the catch-up: reasons + lists; the drill and File pages are the full run's)." >&2
    _flap "the two lists (catch-up)"
    exit 0
fi
# the intermediates the catch-up mode reads (see THE MODE above)
rm -rf "$STATE"; mkdir -p "$STATE"
for _sf in $STATE_FILES; do if [ -f "$TMP/$_sf" ]; then cp "$TMP/$_sf" "$STATE/$_sf"; else : > "$STATE/$_sf"; fi; done
# The section stats: pages whose section came from the session/id joins (with
# the line total those pages show) and pages left to the window fallback — the
# fallback rows exist for more pages than that, but the finishing pass drops
# them wherever the joins matched, so they are counted the same way here.
stats=$(awk -F'\t' '$2 == "I" { I[$1]++; nl++ } $2 == "N" { N[$1] = 1 }
                    END { for (c in I) delete N[c]
                          for (c in I) ni++
                          for (c in N) nn++
                          printf "%d %d %d", ni + 0, nl + 0, nn + 0 }' "$TMP/srvlines" 2>/dev/null || echo "0 0 0")
set -- $stats
# the listed CoreIds that are failed Files: their drill page in $ERRDIR IS their
# File page — the two sets share docs/files/, so every "Last 5 files"
# link resolves without a copy
nover=$(wc -l < "$TMP/overlap" | tr -d ' ')
echo "File pages: $nfilep written to $FILEDIR/ + $nover served by their failed-File page (the Transfer patterns links)." >&2
echo "Data written to $OUT + failed-sub-all.rpt ($nallf failed file(s), $nleg subscription/legs combination(s)) and $ERRDIR/ ($((nleg + nextra)) drill page(s), $nextra for the newest 30 days; server-log sections: $1 by session/id carrying $2 line(s), $3 on the time-window fallback)." >&2
_flap "the two lists + the File pages"
