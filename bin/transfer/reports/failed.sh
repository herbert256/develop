#!/usr/bin/env bash
#
# failed.sh — the FAILED files, on FOUR pages (2026-08, replacing the capped
# single last-failed list; the Subscription-leg views were removed 2026-08):
# two button groups pick the view, each combination its own page
# (analyses/failed*.html; the selector row is injected at publish time by
# bin/analyses/publish.sh, BELOW the From/To date fields):
#
#   SELECTION  all  every failed File            FILTER  failing  hide the
#              sub  each subscription's newest           subscriptions that
#                   failed File (one row each)           are GREEN again
#                                                        all      keep them
#
#   failed.rpt = sub x failing, THE page (analyses/failed.html); the other
#   three are failed-<sel>-<fil>.rpt -> analyses/failed-<sel>-<fil>.html.
#   No caps and no floor any more: sub is an exact dedup and the all pages
#   carry every file. The (subscription, legs) PAIR rule lives on WITHOUT a
#   page of its own: it still grants the drill pages (each pair's newest
#   file, ~185 pairs over 14,935 acceptance failures) and drives the reason
#   pass's pair borrow.
#
# FAILED FILE rows read outcome == "Failed" — an EXPIRED file (a UC2 staged
# copy the partner never collected) belongs to its own "Expired" report.
#
# PLUS THE SERVER-FAILING ROWS (2026-08, with the move to Analyses): every
# RED subscription WITHOUT a failed File in the data — red for what the
# transfer log cannot show (a server-log error after its last delivery, a
# deploy mistake, an authentication failure attributed to it) — gets one row
# per list: @data:srv=1, Date/time = the server evidence stamp
# (blue/_redflip.tsv, else the kaput sidecar, else its last File), Reason =
# the classified newest server E line (_kaput-evidence.tsv through
# bin/flip-reason.awk) else its Subscriptions-in-boxes box (one build behind,
# like the entities Reason column). Like a file row, the whole row opens the
# flow's OWN error page — errors/<slug>.html, NAMED BY THE SUBSCRIPTION,
# holding the facts and the server-log mention ring (the page step below the
# finishing pass writes them). So the six pages together cover ALL
# failing subscriptions, transfer and server alike — the same total the home
# page's two red tables split between them. Consumers of failed-sub-all.rpt
# (home table 1, the detail-page splice, the entities Reason) skip these
# rows by their @data:srv cell and take a file row's CoreId page from its
# @data:href — the visible columns are Subscription, Date/time and Reason
# alone (2026-08: the CoreId and Legs columns were dropped).
#
# DRILL PAGES: every LEG-selection row (which contains every SUB row — a
# subscription's newest file is the newest of its own pair) gets an error
# page, PLUS THE FILE SEARCH GUARANTEE (2026-08, widened to ALL PERIODS):
# every FAILED file of the File search windows (the newest 30 data days —
# Failed only, an Expired pickup is not an error page's story) gets a drill
# page even when the leg selection skipped it — capped at 10 pages per
# SUBSCRIPTION PER DAY (leg pages included, newest first). On the all pages
# a row without a page keeps its Subscription cell's ordinary detail link
# and nothing else. (The "Expired pickup" page title branch below is
# unreachable while the guarantee is Failed-only; kept against the day
# expiries return.)
#
# Outputs:
#   $REPORTS_DIR/failed.rpt             the six lists: Subscription,
#   $REPORTS_DIR/failed-<sel>-<fil>.rpt Date/time, Reason
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
# bin/transfer/publish.sh renders the second set to docs/<env>/errors/<coreid>.html
# (one level below the env root, like transfer/ — so "../assets/style.css").
# The WHOLE list row opens that page (the rowlink modifier + the row's
# @data:href, which beats its first link — the Subscription cell, whose own
# link still works when clicked directly).
#
# The REASON column (2026-08, replacing Ended): the fault the file's
# own drill page shows, classified by bin/flip-reason.awk — the SAME function
# behind the home page's red-worklist Reason, whose first-priority source is
# exactly these pages (_errpage-evidence.tsv + pagereason() in
# publish-insights.sh). Per file: the page's first 8 Error/Warning lines,
# ERROR lines first in page order, first classification wins — the opening
# error of a failure is the cause, everything after it consequence. A file
# WITHOUT a page (the all lists) falls to One-legged, the newest paged file
# of its own (subscription, legs) pair, the flow's evidence sidecar, then its
# last leg's raw status — the same chain, minus the page.
# Blank when nothing classifies: better than a guess. The pass runs AFTER the
# finishing pass (the server-log sections are what it reads) and BEFORE the
# lists are written.
#
# Usage:
#   ./failed.sh    # -> data/<env>/transfer/reports/failed*.rpt + errors/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed

OUT="$REPORTS_DIR/failed.rpt"
# the five view variants beside the default sub-x-failing page (see the header)
VARIANTS="sub-all all-failing all-all"
rm -f "$REPORTS_DIR/last-failed.rpt"           # the pre-rename output (2026-08)
rm -f "$REPORTS_DIR"/failed-leg-*.rpt          # the removed Subscription-leg views (2026-08)
ERRDIR="$REPORTS_DIR/errors"
# A missing drill dir — or a missing variant list — forces a rebuild:
# skip_if_fresh only tests the one .rpt, the same guard the pesit/uc-status
# sidecars carry.
[ -d "$ERRDIR" ] || rm -f "$OUT"
for v in $VARIANTS; do [ -f "$REPORTS_DIR/failed-$v.rpt" ] || rm -f "$OUT"; done
# The server parse cache is a dep (the "What the server log said" sections);
# skip_if_fresh skips a missing dep, so an env without server logs still works.
SRVLOG="$SERVER_CACHE/_parse.tsv"
# Page guard for the server-log table: a session is normally tens to a few
# hundred lines (acceptance: median 35, p90 144, busiest 477), so this ceiling
# does not bite — it is here so one pathological connection cannot turn a drill
# page into a megabyte. A capped page says so in a NOTE under its table.
SRVCAP=${AXWAY_ERR_LOGCAP:-2000}
# $CONFIG_BASE is a DEP because the rows and the facts tables carry ENTITY
# RESULT COLOURS (its third column, filled by bin/build/result.sh, which runs
# before the reports): without it a recolour — a subscription going red, or a
# UC3 flipping back to green on a clean poll — left this report and its 191
# error pages showing yesterday's colours until something else forced a
# rebuild. The cache is cmp-guarded, so an unchanged colour set keeps its
# mtime and nothing re-runs (2026-08).
# The three server-row evidence sources (see the header). All cmp-guarded or
# name-keyed sidecars; a missing one degrades to fewer/reason-less server
# rows and skip_if_fresh skips a missing dep.
RFLIP="$DATA/blue/_redflip.tsv"
KAPUT="$DATA/server/reports/_kaput-evidence.tsv"
BOXES="$DATA/analyses/reports/_subs-boxes.tsv"
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SRVLOG" "$CONFIG_BASE" "$LIB_DIR/../flip-reason.awk" \
    "$RFLIP" "$KAPUT" "$BOXES"

GEN=$(date '+%Y-%m-%d %H:%M:%S')
TMP=$(mktemp -d "${TMPDIR:-/tmp}/axlastf.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# EVERY failed File, newest first, with the two dedup MARKS the selections
# read: S = the subscription's newest failure (the first row of its site in
# the newest-first stream), L = the newest failure of its (subscription,
# legs) pair — S implies L, a subscription's newest file being the newest of
# its own pair. sortkey (col 6) is YYYYMMDDHH:MM:SS.mmm, so a plain C-locale
# reverse sort is newest-first. Keying on SUBSEP, not a literal \x1f, keeps
# the program POSIX-awk. Fields: sortkey, coreid, site, legs, date, time,
# outcome, marks.
LC_ALL=C awk -F'\t' -v OFS='\t' '$2 == "Failed" { print $6, $1, $12, $10, $4, $5, $2 }' "$FILES" \
    | LC_ALL=C sort -r \
    | awk -F'\t' -v OFS='\t' '
        { m = ""
          if (!seensub[$3]++)  m = m "S"
          if (!seen[$3, $4]++) m = m "L"
          print $0, m }' > "$TMP/all"
nleg=$(awk -F'\t' '$8 ~ /L/ { n++ } END { print n + 0 }' "$TMP/all")
nallf=$(wc -l < "$TMP/all" | tr -d ' ')

# THE FILE SEARCH GUARANTEE (2026-08, widened to ALL PERIODS): every FAILED
# file of the File search windows — the newest 30 data days, same bucketing
# as bin/analyses/reports/file-search.sh — gets a drill page, CAPPED at 10
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
# pre-create the two sidecars the main awk fills — with no failed files it
# writes neither, and the reason/list steps below still read them
: > "$TMP/paged"; : > "$TMP/lastst"

# One pass over the parse cache for the legs of exactly the PAGED CoreIds
# (the leg selection + the guarantee extras), writing one drill .rpt per
# file. The cache is CoreId-sorted, so a file's legs arrive together; they
# are held per CoreId and flushed at END so the drill pages come out in a
# defined order whatever the input order. On the side it collects, for EVERY
# failed CoreId, the LAST leg's raw status ($TMP/lastst) — the reason pass
# needs it for the unpaged rows of the all lists — and the paged-CoreId set
# ($TMP/paged) the list writer marks its links by.
LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" -v gen="$GEN" \
    -v TOPF="$TMP/all" -v EXTRAF="$TMP/extra" -v LASTF="$TMP/lastst" -v PAGEDF="$TMP/paged" \
    -v IDS="$TMP/ids" -v META="$TMP/meta" -v SESS="$TMP/sess" -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" -v ACCRES="$CONFIG_BASE/_accounts.tsv" -v HSTRES="$CONFIG_BASE/_hosts.tsv" '
    # The SUBSCRIPTION result colour (bin/build/result.sh fills the third
    # column of the base cache), so a row carries the state of the flow it
    # belongs to: red = still failing, green = it has delivered OK since,
    # orange = never seen, blue = server-log only. That is a different fact
    # from the State column, which is about THIS File, and the more useful one
    # to scan for — the same tint the Ranking report and the Entities views
    # give the entity. A name the base cache does not know stays untinted.
    BEGIN { resload(SUBRES, SRES); resload(ACCRES, ARES); resload(HSTRES, HRES) }
    function resload(f9, A9,   l9, n9, z9) {
        while ((getline l9 < f9) > 0) { n9 = split(l9, z9, "\t")
            if (n9 >= 3 && z9[1] != "") A9[toupper(z9[1])] = z9[3] }
        close(f9) }
    function rescol(A9, nm,   r) { r = (toupper(nm) in A9) ? A9[toupper(nm)] : ""
        return (r == "green" || r == "orange" || r == "red" || r == "blue") ? r : "" }
    function subtint(nm,   r) { r = rescol(SRES, nm); return (r != "") ? "\t@data:res=" r : "" }
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

    # FILENAME dispatch, not an FNR==1 counter: the extras file is legitimately
    # EMPTY when every window error made the list, and an empty file never
    # fires FNR==1 — a counter would then misread the parse cache.
    FILENAME == TOPF {                          # every failed File + marks
        ALLF[$2] = 1                            # the lastst collection set
        if ($8 !~ /L/) next                     # only the leg selection gets a page here
        ord[++nord] = $2                        # CoreId, newest first
        SITE[$2] = $3; LEGS[$2] = $4; SD[$2] = $5; ST[$2] = $6
        WANT[$2] = 1
        next
    }
    FILENAME == EXTRAF {                        # drill-only: the File search
        ord[++nord] = $2                        # window errors the selection skipped
        SITE[$2] = $3; LEGS[$2] = $4; SD[$2] = $5; ST[$2] = $6
        OC[$2] = $7                             # Failed | Expired (page wording)
        WANT[$2] = 1
        next
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
        LEG[$1] = LEG[$1] sprintf("ROW\t%s\t%s\t%s\t%s\t%s %s\t%s\t%s\t%s\n", \
            esc($3), esc($2), esc($10), humanbytes($9), esc($11), esc($12), humandur($15), esc($16), esc($23))
        NL[$1]++
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
        # last-leg raw status per failed CoreId (the reason pass, all lists)
        for (i = 1; i <= nord; i++) print ord[i] > PAGEDF
        for (c in LASTST) print c "\t" LASTST[c] > LASTF
        close(PAGEDF); close(LASTF)

        for (i = 1; i <= nord; i++) {
            c = ord[i]
            f = ERRDIR "/" c ".rpt"
            # The page is named after the FILE, not the CoreId — a name says
            # which feed broke at a glance where an opaque id does not. The id
            # is still on the page (the intro below) since it is the value to
            # quote to Axway support, and it is still the page URL.
            nm = (FNAME[c] != "") ? FNAME[c] : c
            if (OC[c] == "Expired") {
                printf "TITLE\tExpired pickup: %s\n", SITE[c] > f
                printf "DESC\tThe expired File %s of subscription %s (CoreId %s): every transfer leg and the server log behind it.\n", nm, SITE[c], c > f
            } else {
                printf "TITLE\tFailed subscription: %s\n", SITE[c] > f
                printf "DESC\tThe failed File %s of subscription %s (CoreId %s): every transfer leg and the server log behind it.\n", nm, SITE[c], c > f
            }
            # The FACTS table (2026-08), first thing on the page and in place of
            # the prose line that used to open it: what this File was, where it
            # went and who it belonged to. The last three cells carry the
            # entity RESULT colour and link to its detail page — the same tint
            # and the same destination the rest of the site gives them.
            printf "TABLE\t\tnosearch\n" > f
            printf "HEAD\tItem\tValue\n" > f
            printf "KIND\ttext\ttext\n" > f
            printf "ROW\tFile name\t%s\n", nm > f
            printf "ROW\tCoreId\t@{class=mono}%s\n", c > f
            printf "ROW\tDate/time\t%s %s\n", SD[c], ST[c] > f
            printf "ROW\tSubscription\t%s\n", entcell(SRES, "subscriptions", SITE[c]) > f
            printf "ROW\tRemote host\t%s\n", entcell(HRES, "hosts", HOSTN[c]) > f
            printf "ROW\tAccount\t%s\n", entcell(ARES, "accounts", ACCTN[c]) > f
            # no TOTAL: an Item/Value facts table has nothing to total, and
            # an empty footer row would just draw a grey strip under it (the
            # detail pages\047 Features table omits it for the same reason)
            # No sort= here: the legs are emitted in cache order (inbound first,
            # then each attempt), which the intro promises, and the first column
            # is not a date so report.js applies no default of its own. Dropping
            # `nosort` leaves that order intact AND makes the headers clickable.
            printf "TABLE\t\twide\tnosearch\n" > f
            printf "HEAD\tStatus\tDirection\tProtocol\tSize\tDate & time\tDuration\tRemote host\tTransfer ID\n" > f
            printf "KIND\ttext\ttext\ttext\tnum\ttext\tnum\thost\tmono\n" > f
            printf "%s", LEG[c] > f
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
' "$TMP/all" "$TMP/extra" "$PARSED"
# ---- The SERVER-FAILING set (2026-08) ---------------------------------------
# Every RED subscription that is server-reddened (blue/_redflip.tsv) or has NO
# failed File at all — exactly the home table-2 red membership. Computed
# BEFORE the server-cache scan below, so the scan can resolve each flow's
# evidence STAMP to the SESSION of the reddening Error line (and the second
# pass after it collect that session's whole conversation for the drill
# page). Output $TMP/srvsubs — name ⇥ slug ⇥ stamp ⇥ reason ⇥ kind:
#   slug   the page basename (lowercased, non-alnum runs folded to "-", the
#          slugify rule; a separator-twin collision takes a numeric suffix; a
#          slug can never collide with a CoreId page, those being UUIDs)
#   stamp  blue/_redflip.tsv, else the kaput sidecar, else the last File
#   reason the classified kaput E line, else the Subscriptions-in-boxes box
#   kind   R = no failed File (a list server-row + a page)
#          P = redflip WITH failed Files (page only — the lists keep its file
#              rows; home table 2 links the page)
[ -f "$RFLIP" ] || RFLIP=/dev/null
[ -f "$KAPUT" ] || KAPUT=/dev/null
[ -f "$BOXES" ] || BOXES=/dev/null
# the last-File stamp per subscription (ALL outcomes — a server-reddened
# flow's last File is usually an OK one), the Started fallback
LC_ALL=C awk -F'\t' -v OFS='\t' '$12 != "" { k = $12
        if ($6 > mx[k]) { mx[k] = $6; d[k] = $4 " " $5 } }
    END { for (k in d) print k, d[k] }' "$FILES" > "$TMP/lastfile"
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
    LC_ALL=C awk -F'\t' -v SSUBF="$TMP/srvsubs" -v SSOUT="$TMP/srvsess2" '
        function lvlname(x) { if (x == "I") return "Info"; if (x == "W") return "Warning"
                              if (x == "E") return "Error"; return x }
        function compname(x) { if (x == "T") return "TM"; if (x == "P") return "PESITD"
                               if (x == "S") return "SSHD"; return x }
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
        FNR == 1 { nf++ }
        nf == 1 { idmap[$1] = $2; next }              # ids: transfer_id/CoreId -> CoreId
        nf == 2 {                                     # sess: session -> CoreId(s)
            sesmap[$1] = ($1 in sesmap) ? sesmap[$1] " " $2 : $2; next
        }
        nf == 3 {                                     # meta: coreid, site, date, time, endt, nses
            nc++; C[nc] = $1
            w0[$1] = $3 " " substr($4, 1, 5)
            w1[$1] = ($5 == "") ? w0[$1] : substr($5, 1, 16)
            if (w1[$1] < w0[$1]) w1[$1] = w0[$1]
            pfx[$1] = substr($2, 1, 28)
            if (gmin == "" || w0[$1] < gmin) gmin = w0[$1]
            if (w1[$1] > gmax) gmax = w1[$1]
            next
        }
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
            for (i = 1; i <= nc; i++) {
                c = C[i]
                if (c in idc) continue                # already kept by id
                if (k >= w0[c] && k <= w1[c] && index(m, pfx[c]) > 0) emit(c, "N", "window")
            }
        }
    ' "$TMP/ids" "$TMP/sess" "$TMP/meta" "$SRVLOG" \
    | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 -k4,4 > "$TMP/srvlines"
fi

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
    LC_ALL=C awk -F'\t' -v SS="$TMP/srvsess2" '
        function lvlname(x) { if (x == "I") return "Info"; if (x == "W") return "Warning"
                              if (x == "E") return "Error"; return x }
        BEGIN { while ((getline l < SS) > 0) { p = index(l, "\t")
                    if (p > 0) { s = substr(l, p + 1); m = substr(l, 1, p - 1)
                        SM[s] = (s in SM) ? SM[s] "\n" m : m } }
                close(SS) }
        $6 != "" && ($6 in SM) {
            msg = $5
            if (length(msg) > 4000) msg = substr(msg, 1, 4000) " …"
            n = split(SM[$6], sl9, "\n")
            for (i = 1; i <= n; i++)
                printf "%s\t%s\t%s\t%s\t%s\n", sl9[i], $1, $2, lvlname($3), msg
        }
    ' "$SRVLOG" | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 > "$TMP/srvsublines"
fi

# The finishing pass: append the server-log section (where one exists) and the
# LINK + FOOT every drill page ends with — the awk above wrote the pages
# WITHOUT them, so appending here keeps LINK/FOOT the last lines. `>>` is
# deliberate (a fresh awk process'"'"'s `>` would truncate the finished pages).
if [ -s "$TMP/meta" ]; then
    LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" -v gen="$GEN" -v CAP="$SRVCAP" '
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
            c = $1; f = ERRDIR "/" c ".rpt"
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
                f = ERRDIR "/" MC[i] ".rpt"
                printf "LINK\t../analyses/failed.html\tBack to Failed Subscriptions\n" >> f
                printf "FOOT\tGenerated on %s\n", gen >> f
                close(f)
            }
        }
    ' "$TMP/meta" "$TMP/srvlines" "$TMP/srvlines"
fi

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
LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" -v gen="$GEN" -v CAP="$SRVCAP" \
    -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" -v ACCRES="$CONFIG_BASE/_accounts.tsv" \
    -v SAX="$CONFIG_XREF/_subscriptions-accounts.tsv" \
    -v MDIR="$DATA/server/cache/subscriptions" -v SLF="$TMP/srvsublines" '
    function resload(f9, A9,   l9, n9, z9) {
        while ((getline l9 < f9) > 0) { n9 = split(l9, z9, "\t")
            if (n9 >= 3 && z9[1] != "") A9[toupper(z9[1])] = z9[3] }
        close(f9) }
    function rescol(A9, nm,   r) { r = (toupper(nm) in A9) ? A9[toupper(nm)] : ""
        return (r == "green" || r == "orange" || r == "red" || r == "blue") ? r : "" }
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
    BEGIN {
        resload(SUBRES, SRES); resload(ACCRES, ARES)
        while ((getline l < SAX) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "" && !(toupper(a[1]) in ACC)) ACC[toupper(a[1])] = a[2] }
        close(SAX)
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
        if (kind == "P")
            printf "DESC\tThe subscription %s is failing in the server log — its last transfer ended OK, the server log erred after it.\n", nm > f
        else
            printf "DESC\tThe subscription %s is failing in the server log — no failed File; the evidence is the server log of the failing connection.\n", nm > f
        printf "TABLE\t\tnosearch\n" > f
        printf "HEAD\tItem\tValue\n" > f
        printf "KIND\ttext\ttext\n" > f
        printf "ROW\tSubscription\t%s\n", entcell(SRES, "subscriptions", nm) > f
        printf "ROW\tAccount\t%s\n", entcell(ARES, "accounts", (k in ACC) ? ACC[k] : "") > f
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
        printf "FOOT\tGenerated on %s\n", gen > f
        close(f)
    }
' "$TMP/srvsubs"

# The ERROR-PAGE EVIDENCE sidecar (2026-08): per subscription, the newest
# Error/Warning line any of its drill pages shows. The home page's Reason column
# names the fault behind a red flow from the server log, and its first source —
# went-kaput's sidecar — only covers flows whose LAST TRANSFER WAS OK. A flow
# whose last transfer FAILED and which sits in no specific box therefore had no
# reason at all, though its own error page was showing the very line that
# explains it (an ARRC0029 routing-step warning, in the case that found this).
# The drill .rpt carries the subscription in its TITLE and the log lines as
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
# The NEWEST page, because that is the one the home row links to: a flow with
# several drill pages must be explained by the failure the reader opens, not by
# an older one. Each page is buffered as it is read and replaces the flow
# incumbent when its lines are newer.
#   subscription <TAB> "date time" <TAB> level (Error|Warning) <TAB> message
# cmp-guarded, so an unchanged run does not drag the analyses publish along.
EVID="$REPORTS_DIR/_errpage-evidence.tsv"
LC_ALL=C awk -F'\t' -v CAND=8 '
    function flush(   i) {                      # the buffered page -> its subscription
        if (site == "" || fn == 0) return
        if (fmax > best[site]) { best[site] = fmax; bn[site] = fn
            for (i = 1; i <= fn; i++) { bs[site, i] = fs[i]; bl[site, i] = fl[i]; bm[site, i] = fm[i] } }
    }
    FNR == 1 { flush(); site = ""; fn = 0; fmax = "" }
    $1 == "TITLE" { site = $2; sub(/^Failed subscription: /, "", site)
                    sub(/^Expired pickup: /, "", site)   # the drill-only Expired pages (File search windows)
                    # a page from a previous run carries the Reason suffix in
                    # its title ("<name> - <reason>"); a name never contains a
                    # space, so stripping from " - " recovers it exactly
                    sub(/ - .*$/, "", site); next }
    $1 == "ROW" && site != "" && NF >= 4 && ($3 == "Error" || $3 == "Warning") {
        if ($2 > fmax) fmax = $2                # the page own newest line, for picking the page
        if (fn < CAND) { fn++; fs[fn] = $2; fl[fn] = $3; fm[fn] = substr($4, 1, 200) }
    }
    END { flush()
          for (k in bn) for (i = 1; i <= bn[k]; i++)
              printf "%s\t%s\t%s\t%s\n", k, bs[k, i], bl[k, i], bm[k, i] }
' "$ERRDIR"/*.rpt 2>/dev/null | LC_ALL=C sort > "$EVID.tmp" || : > "$EVID.tmp"
if cmp -s "$EVID.tmp" "$EVID" 2>/dev/null; then rm -f "$EVID.tmp"; else mv "$EVID.tmp" "$EVID"; fi

# The REASON pass (2026-08): one Reason per FAILED CoreId ($TMP/reasons,
# coreid ⇥ reason, blank kept), now that the finishing pass has appended the
# server-log sections and the EVIDENCE sidecar above is fresh. FOUR sources
# per file, each walked ERROR lines first in page order with the first
# classification winning (the opening error of a failure is the cause,
# everything after it consequence):
#   1. the file's OWN drill page (paged CoreIds only) — its first 8
#      Error/Warning ROW lines, the same candidate rule the sidecar applies.
#      Each file explains ITS OWN failure where it can.
#   2. ONE-LEGGED (2026-08): a file its own page did not classify which
#      took a single leg reads "One-legged" — the home names that box for
#      exactly these flows (a lone inbound arrival, nothing ever went out),
#      and the two pages should agree. BEFORE the flow borrow below
#      (2026-08-22): a one-legged file whose own session logged only clean
#      lines was inheriting a stale "Connection failures" verdict from a
#      19-day-older page of the same flow — the page's own evidence
#      contradicted its own title. What the file's legs say outranks what a
#      DIFFERENT file's page said.
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
#      SERVER-LINE STAMP, which is publish-insights.sh pagereason()'s exact
#      first-priority source for the home page's Reason. A MULTI-leg file
#      whose sessions logged no error at all still gets the flow's verdict.
#   5. the LAST LEG's raw Status ("Failed Subtransmission") — from the page
#      for a paged file, from the $TMP/lastst sidecar for an unpaged one (the
#      all lists). Only when it is more specific than a bare "Failed": a
#      reason must name a fault, never restate the outcome.
# flip_reason() is the SHARED classifier (bin/flip-reason.awk).
#      Still blank when no rule applies: better than a guess.
LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" -v EVID="$EVID" -v PAGEDF="$TMP/paged" -v LASTF="$TMP/lastst" -v CAND=8 \
    "$(cat "$LIB_DIR/../flip-reason.awk")"'
    BEGIN { while ((getline l < EVID) > 0) {
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
    function pagereason(cid,   f, l, a, n, fn, fl, fm, t) {
        f = ERRDIR "/" cid ".rpt"; fn = 0; t = 0; LEGST = ""
        while ((getline l < f) > 0) {
            if (fn >= CAND) break
            n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (a[1] != "ROW") continue
            if (t == 2 && a[2] != "") LEGST = a[2]
            if (n >= 4 && (a[3] == "Error" || a[3] == "Warning")) {
                fn++; fl[fn] = a[3]; fm[fn] = substr(a[4], 1, 200) }
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
        if (cid in PG) {
            r6 = pagereason(cid)
            # the PAIR verdict: the stream is newest first, so the FIRST
            # paged row of a (subscription, legs) pair is that pair NEWEST
            # page — it donates its reason to the unpaged (older, off-window)
            # siblings of the pair below. Stored even when blank: an older
            # sibling page must not outvote the pair newest evidence.
            if (!((site, legs) in PAIRR)) PAIRR[site, legs] = r6
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

# The same Reason lands in each drill page TITLE — "Failed subscription:
# <name> - <reason>" — so the error page answers WHY in its own heading
# (2026-08). Rewrite-in-place: the page is buffered whole, then written back
# with the one line changed. The EVIDENCE parser above strips the suffix when
# it reads a title (a subscription name never contains a space, so the
# " - " separator cannot occur inside one).
if [ -s "$TMP/reasons" ]; then
    LC_ALL=C awk -F'\t' -v ERRDIR="$ERRDIR" '
        { cid = $1; r = $2; if (cid == "" || r == "") next
          f = ERRDIR "/" cid ".rpt"; n = 0
          while ((getline l < f) > 0) buf[++n] = l
          close(f)
          if (n == 0) next
          for (i = 1; i <= n; i++) {
              if (index(buf[i], "TITLE\t") == 1) print buf[i] " - " r > f
              else print buf[i] > f
          }
          close(f)
          for (i = 1; i <= n; i++) delete buf[i] }
    ' "$TMP/reasons"
fi

# ---- The SIX lists (see the header) -----------------------------------------
# One pass over $TMP/all writes all six bodies to .rpt.tmp files; the mv set
# below publishes them together, AFTER the drill tree and its server-log
# sections are complete — a killed run leaves the OLD complete set + a stale
# mtime (rebuild) rather than fresh truncated lists skip_if_fresh would
# trust. Rows stream newest first, so every list is newest first (the
# appended server rows land at the end; the page default sort — Started,
# descending — interleaves them on load). The two all-selection lists carry
# every failed File (acceptance: ~15k rows), so they page client-side
# (pager=500) — sort/search/date filter still work over the full set.
# the two ALL views ship empty (esearch + startempty) — their always-visible
# INTRO must state the searchable row counts, so both are computed up front:
# all-all = every failed File + the kind-R server rows; all-failing = the
# non-green ones + the same server rows (all red by construction)
NSRVR=$(awk -F'\t' '$5 == "R"' "$TMP/srvsubs" | wc -l | tr -d ' ')
NFAILING=$(LC_ALL=C awk -F'\t' -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" '
    BEGIN { while ((getline l < SUBRES) > 0) { n = split(l, a, "\t")
                if (n >= 3 && a[1] != "") C[toupper(a[1])] = a[3] }
            close(SUBRES) }
    { k = toupper($3); if (!(k in C) || C[k] != "green") n++ }
    END { print n + 0 }' "$TMP/all")
LC_ALL=C awk -F'\t' -v RD="$REPORTS_DIR" -v gen="$GEN" -v RCAP=10000 \
    -v NALLALL=$((nallf + NSRVR)) -v NALLFAIL=$((NFAILING + NSRVR)) \
    -v REAS="$TMP/reasons" -v PAGEDF="$TMP/paged" -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" \
    -v SRVS="$TMP/srvsubs" '
    function rescol(nm,   r) { r = (toupper(nm) in SRES) ? SRES[toupper(nm)] : ""
        return (r == "green" || r == "orange" || r == "red" || r == "blue") ? r : "" }
    BEGIN {
        while ((getline l < SUBRES) > 0) { n = split(l, a, "\t")
            if (n >= 3 && a[1] != "") SRES[toupper(a[1])] = a[3] }
        close(SUBRES)
        while ((getline l < REAS) > 0) { p = index(l, "\t")
            if (p > 0) RE[substr(l, 1, p - 1)] = substr(l, p + 1) }
        close(REAS)
        while ((getline l < PAGEDF) > 0) if (l != "") PG[l] = 1
        close(PAGEDF)
        # the server-failing set (name ⇥ slug ⇥ stamp ⇥ reason ⇥ kind),
        # written by the page step above together with the errors/<slug>
        # drill pages. EVERY entry gets a server row on every list (2026-08;
        # it was kind R only): kind R (no failed File anywhere) is the one
        # row of the flow; kind P (server-reddened WITH failed Files)
        # REPLACES the file row of the flow on the sub views — the CURRENT
        # story is the server verdict, exactly what the home page and the
        # Error reasons counts must agree on — and rides BESIDE the file
        # rows on the all views, where it is one more current error.
        while ((getline l < SRVS) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "") { nsv++
                SVN[nsv] = a[1]; SVS[nsv] = a[2]
                SVT[nsv] = (n >= 3) ? a[3] : ""; SVR[nsv] = (n >= 4) ? a[4] : ""
                if (n >= 5 && a[5] == "P") PSET[toupper(a[1])] = 1 } }
        close(SRVS)
        NP = split("sub-failing sub-all all-failing all-all", PK, " ")
        DSC["sub-failing"] = "Every failing subscription — the newest failed File of each, one row per subscription, plus the subscriptions failing in the server log only."
        DSC["sub-all"]     = "The newest failed File of every subscription that ever failed, recovered flows included — one row per subscription — plus the subscriptions failing in the server log only."
        DSC["all-failing"] = "Every failed File of the still-failing subscriptions, newest first, plus the subscriptions failing in the server log only."
        DSC["all-all"]     = "Every failed File in the data, newest first, plus the subscriptions failing in the server log only."
        for (i = 1; i <= NP; i++) {
            k = PK[i]
            f = RD "/" ((k == "sub-failing") ? "failed" : "failed-" k) ".rpt.tmp"
            F[k] = f
            printf "TITLE\tFailed Subscriptions\n" > f
            printf "DESC\t%s\n", DSC[k] > f
            printf "KEYWORDS\tfailed,failure,error,coreid,legs,subscription,still,failing,recent,last\n" > f
            # the ALL views bake their rows but CAP at the newest 10,000
            # (2026-08, replacing the search-on-demand payloads): the intro
            # states the cap whenever it bites
            if (k ~ /^all-/ && ((k == "all-all") ? NALLALL : NALLFAIL) > RCAP)
                printf "INTRO\tThis view holds **%d** rows; the newest **%d** failed Files are shown (the cap keeps the page loadable — every file with its own error page and the server-failing rows always included). Narrow with the From/To dates, or use the **Subscription** view.\n", \
                       (k == "all-all") ? NALLALL : NALLFAIL, RCAP > f
            # Newest first is the page DEFAULT (Started, desc), not `nosort` —
            # the rows arrive by recency but must still be sortable by any
            # column. `restint` + the per-row @data:res: the row carries its
            # SUBSCRIPTION result colour, red still failing / green recovered
            # since — on the -failing lists effectively all red, the greens
            # being filtered. NOSEARCH on every view and the rows BAKED
            # (2026-08, replacing the search-on-demand payloads): the all
            # lists cap at the newest RCAP file rows instead (the intro
            # above says so when it bites), so the page loads whole.
            printf "TABLE\t\twide\tsort=1:-1\trowlink\trestint\tnosearch\n" > f
            printf "HEAD\tSubscription\tDate/time\tReason\n" > f
            printf "KIND\tsite\ttext\ttext\n" > f
        }
    }
    {   # $TMP/all: sortkey, coreid, site, legs, date, time, outcome, marks
        cid = $2; site = $3; legs = $4; d = $5; t = $6; m = $8
        col = rescol(site)
        r = (cid in RE) ? RE[cid] : ""
        tint = (col != "") ? "\t@data:res=" col : ""
        # A PAGED row: the Subscription cell opens the error page —
        # @{nolink=1} drops the automatic entity link a `site` cell would
        # otherwise carry, so the row has ONE destination and no cell that
        # quietly goes somewhere else (the error page names the subscription
        # in its facts table, linked) — and @data:href gives the whole row
        # the same target (rowlink). The CoreId lives ONLY in that href
        # since 2026-08 (no CoreId/Legs columns any more): the failed-sub-all
        # consumers (home table 1, the entities Reason, the detail splice)
        # extract the page from @data:href. An UNPAGED row (the all lists
        # beyond the guarantee) keeps the Subscription cell'"'"'s ordinary
        # detail link and nothing else.
        if (cid in PG)
            row = sprintf("ROW\t@{href=../errors/%s.html,nolink=1}%s\t%s %s\t%s\t@data:href=../errors/%s.html%s", \
                          cid, site, d, t, r, cid, tint)
        else
            row = sprintf("ROW\t%s\t%s %s\t%s%s", site, d, t, r, tint)
        for (i = 1; i <= NP; i++) {
            k = PK[i]
            # each subscription newest — but the sub row of a kind-P flow
            # is its SERVER row (appended in END), never a stale newest file
            if (k ~ /^sub-/ && (m !~ /S/ || (toupper(site) in PSET))) continue
            if (k ~ /-failing$/ && col == "green") continue   # hide the recovered
            # the newest-10k cap — but a row WITH its own error page always
            # rides (they are the drill-page anchors; without them the pages
            # of old pair-newest failures would be linked from nowhere), as
            # do the server rows in END
            if (k ~ /^all-/ && CNT[k] >= RCAP && !(cid in PG)) continue
            print row > F[k]; CNT[k]++
        }
    }
    END {
        # THE SERVER-FAILING ROWS (see the header): every red subscription
        # with NO failed File in the data, appended to ALL SIX lists — red
        # passes both filters, and a subscription-level fact belongs on every
        # selection. @data:srv=1 is the marker consumers skip (the CoreId
        # column that used to show "-" is gone); like a file row, the row
        # opens the error page of the flow — errors/<slug>.html, NAMED BY THE
        # SUBSCRIPTION, written by the page step above. The page default sort
        # (Date/time desc) interleaves the rows on load.
        for (j = 1; j <= nsv; j++) {
            srow = sprintf("ROW\t@{href=../errors/%s.html,nolink=1}%s\t%s\t%s\t@data:href=../errors/%s.html\t@data:srv=1\t@data:res=red", \
                           SVS[j], SVN[j], SVT[j], SVR[j], SVS[j])
            for (i = 1; i <= NP; i++) { print srow > F[PK[i]]; CNT[PK[i]]++ }
        }
        for (i = 1; i <= NP; i++) {
            k = PK[i]; f = F[k]
            printf "TOTAL\tTotal (%d rows)\t\t\n", CNT[k] + 0 > f
            printf "NOTE\tThe two button rows above pick the view, each a page of its own. **All / Subscription** choose the rows: every failed File, or each subscription'"'"'s newest failed File. **All / Still failing** choose the flows: **Still failing** hides the subscriptions that are green again (they have delivered OK since); **All** keeps them.\n" > f
            printf "NOTE\tA File is one logical transfer (all records sharing a CoreId — the id is on the error page the row opens, and in the row'"'"'s link). A row carries the **colour of its subscription**: red = still failing, green = recovered since. **Reason** is the fault the file'"'"'s own error page shows — its first error line that classifies, in the home page'"'"'s red-worklist vocabulary; a single-leg file whose log names nothing recognisable reads **One-legged** (the arrival with no delivery IS the failure); a file without its own error page takes the reason of the **newest paged file of its subscription + leg-count combination** — the same failure shape; a multi-leg file whose sessions logged no error shows its last leg'"'"'s raw status (**Failed Subtransmission**); blank only when no rule applies. Outcome **Failed** only: an **Expired** file (staged for a UC2 pickup that never came) has its own report in this group.\n" > f
            if (k ~ /^all-/)
                printf "NOTE\tA row opens the file'"'"'s own error page where one exists — pages are kept for every subscription + leg-count combination'"'"'s newest failure and for a subscription'"'"'s newest 10 failures of each day in the File search windows. An older row of a busy flow has none; its Subscription cell links the detail page instead.\n" > f
            else
                printf "NOTE\tA file row opens the file'"'"'s own error page: the facts, every transfer leg with its status and timing, and the server-log lines of the connections it ran over.\n" > f
            printf "NOTE\tA row is either a FAILED FILE (its Date/time is the file'"'"'s start, the row opens that file'"'"'s error page) or a subscription whose CURRENT failure is the **server log'"'"'s** — no failed File at all, or its last transfer ended OK and the server log erred after it: a post-delivery error, a deploy mistake, an authentication failure attributed to the flow. For those the Date/time is the server evidence stamp and the row opens the flow'"'"'s own error page — named by the subscription — with the server-log lines behind the verdict; the detail page is linked from its facts table. Together the two kinds are **every failing subscription**, transfer and server alike — the same set the home page'"'"'s two red tables split between them.\n" > f
            printf "FOOT\tGenerated on %s\n", gen > f
            close(f)
        }
    }
' "$TMP/all"
mv "$OUT.tmp" "$OUT"
for v in $VARIANTS; do mv "$REPORTS_DIR/failed-$v.rpt.tmp" "$REPORTS_DIR/failed-$v.rpt"; done
# The PUBLISHED server-failing sidecar (name ⇥ slug ⇥ stamp ⇥ reason ⇥ kind):
# the Entities Subscriptions/Error view links its Reason cells to the
# errors/<slug> pages through it (publish_lib, kind S) — the slug must come
# from here, never re-derived (the twin-collision suffix). cmp-guarded so an
# unchanged set does not re-render the transfer pages.
if cmp -s "$TMP/srvsubs" "$REPORTS_DIR/_srvsubs.tsv" 2>/dev/null; then :
else cp "$TMP/srvsubs" "$REPORTS_DIR/_srvsubs.tsv.tmp" && mv "$REPORTS_DIR/_srvsubs.tsv.tmp" "$REPORTS_DIR/_srvsubs.tsv"; fi
# The STABLE map beside it (2026-08): name + slug + evidence stamp, WITHOUT
# the reason/kind columns. It is what details.sh actually consumes (the
# "Server log error" section needs the membership, the slug and — through
# the stamp — the reddening-session table, never the reason), and the reason
# is the one column the evidence catch-up rerun changes. cmp-guarded on the
# REDUCED content, its mtime holds through that rerun, so the details
# catch-up self-gates to a skip instead of rebuilding every detail page.
cut -f1-3 "$TMP/srvsubs" > "$TMP/srvsubs.map"
if cmp -s "$TMP/srvsubs.map" "$REPORTS_DIR/_srvsubs-map.tsv" 2>/dev/null; then :
else cp "$TMP/srvsubs.map" "$REPORTS_DIR/_srvsubs-map.tsv.tmp" && mv "$REPORTS_DIR/_srvsubs-map.tsv.tmp" "$REPORTS_DIR/_srvsubs-map.tsv"; fi

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
echo "Data written to $OUT + 3 view variants ($nallf failed file(s), $nleg subscription/legs combination(s)) and $ERRDIR/ ($((nleg + nextra)) drill page(s), $nextra for the File search windows; server-log sections: $1 by session/id carrying $2 line(s), $3 on the time-window fallback)." >&2
