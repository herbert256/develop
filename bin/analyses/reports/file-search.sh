#!/usr/bin/env bash
#
# file-search.sh — "File search": the searchable index of the FILES themselves,
# by file NAME, split into SIX single pages (2026-08 — the Errors/OK page pair
# is gone: one page per window, every result row tinted green (OK) or red
# (Error) by the site outcome policy):
#
#   file-search-24-hours   the newest FULL day, plus the partial newest day
#                          when one exists (the topview rule: the newest day is
#                          partial when its last activity is before 22:00)
#   file-search-48-hours   the SECOND full day (one day)
#   file-search-week       the last week, the two windows above excluded
#   file-search-2-weeks    the last 2 weeks, the newest week excluded
#   file-search-3-weeks    the last 3 weeks, the newest 2 weeks excluded
#   file-search-month      the last month, the newest 3 weeks excluded
#
# The windows are DATA days, anchored on the newest day in the transfer cache
# (an old export must not render six empty pages). Files older than 30 data
# days are on NO page (the month intro says so); undated files (invalid
# date_iso) cannot be bucketed and are skipped. Error = Failed or Expired,
# OK = anything else (Waiting counts OK) — the row TINT, not a page split.
#
# Each page is one EMPTY table; THIS script writes the page's data sidecar
# (file-search-<key>-data.js, copied to docs/<env>/ by the analyses publish)
# in a COMPACT DATA format (v5, 2026-08 — one row shape for every page):
#
#   window.AXWAY_FSEARCH_D = `date per line`            (the date dictionary)
#   window.AXWAY_FSEARCH_S = `NAME <TAB> slug per line` (the subscription
#                             dictionary; slug from the subscriptions
#                             slugmap, empty = no detail link)
#   window.AXWAY_FSEARCH_R = one File per line:
#     name TAB di TAB si TAB time TAB bytes TAB coreid TAB flag
#   (di/si = dictionary indices; time = HH:MM:SS, rendered beside the date;
#   bytes raw — the engine humanizes; flag: "" = OK, "e" = Error, "E" =
#   Error with its own errors/<coreid>.html page)
#
# The DEDICATED docs/assets/file-search.js parses these and renders only the
# matches — NOT report.js's esearch: a Search button (no per-keystroke
# filtering), the NAV row's five sibling links carrying the query as ?q=….
#
# THE ROW CAP (2026-08, replacing the old byte budget): a page ships at most
# AXWAY_FILE_SEARCH_ROWCAP rows (default 100,000), newest first — the window
# figures still count everything and the intro states the cut. When ANY page
# drops rows the cut is written to $REPORTS_DIR/file-search-capped.txt, which
# the BUILD REPORT renders as a RED warning banner — a capped page must be
# impossible to miss.
#
# An ANALYSES report (pages in the Analyses family, data from the transfer
# outputs): reads the transfer parse cache _files.tsv directly and the
# failed.sh error-page roster. Safe in reports.sh wave 1 — it touches
# neither the PDA TSVs nor home.rpt.
#
# Usage:
#   ./file-search.sh    # -> data/<env>/analyses/reports/file-search-<key>.rpt (x6)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

FCACHE="$DATA/transfer/cache/_files.tsv"
ERRRPTS="$DATA/transfer/reports/errors"     # failed.sh's per-CoreId drill set
SLUGMAP="$DATA/transfer/reports/details/subscriptions/_slugmap.tsv"   # name -> detail slug
ROWCAP=${AXWAY_FILE_SEARCH_ROWCAP:-100000}   # per-page payload row cap
CAPFILE="$REPORTS_DIR/file-search-capped.txt"

KEYS="24-hours 48-hours week 2-weeks 3-weeks month"
# the 2026-08 Errors/OK page pair — swept so the estate never carries both sets
OLDKEYS="48-hours-errors 48-hours-ok week-errors week-ok 2-weeks-errors 2-weeks-ok 3-weeks-errors 3-weeks-ok month-errors month-ok"
for k in $OLDKEYS; do rm -f "$REPORTS_DIR/file-search-$k.rpt" "$REPORTS_DIR/file-search-$k-data.js"; done

if [ ! -f "$FCACHE" ]; then
    echo "file-search: no $FCACHE (transfer parse has not run) — pages not published." >&2
    for k in $KEYS; do rm -f "$REPORTS_DIR/file-search-$k.rpt" "$REPORTS_DIR/file-search-$k-data.js"; done
    rm -f "$CAPFILE"
    exit 0
fi

# freshness: the EXISTING outputs against the cache + the error-page roster
# (a changed roster moves the CoreId links); the OLDEST existing output
# decides. Only 24-hours is REQUIRED — an empty window deliberately has no
# rpt (2026-08), so requiring all six would recompute on every run. A data
# change that fills a new window makes the inputs newer than the oldest
# existing rpt, so it still recomputes exactly then.
FRESH=1
[ -f "$REPORTS_DIR/file-search-24-hours.rpt" ] || FRESH=0
[ -f "$REPORTS_DIR/file-search-24-hours-data.js" ] || FRESH=0
if [ "$FRESH" = 1 ]; then
    OLDEST="$REPORTS_DIR/file-search-24-hours.rpt"
    for k in $KEYS; do
        [ -f "$REPORTS_DIR/file-search-$k.rpt" ] && [ "$REPORTS_DIR/file-search-$k.rpt" -ot "$OLDEST" ] && OLDEST="$REPORTS_DIR/file-search-$k.rpt"
        [ -f "$REPORTS_DIR/file-search-$k-data.js" ] && [ "$REPORTS_DIR/file-search-$k-data.js" -ot "$OLDEST" ] && OLDEST="$REPORTS_DIR/file-search-$k-data.js"
    done
    skip_if_fresh "$OLDEST" "${BASH_SOURCE[0]}" "$FCACHE" "$ERRRPTS" "$SLUGMAP"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/axfsearch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Which CoreIds have an error page: the errors/*.rpt basenames.
shopt -s nullglob
errfiles=("$ERRRPTS"/*.rpt)
shopt -u nullglob
: > "$TMP/errpages"
if [ ${#errfiles[@]} -gt 0 ]; then
    printf '%s\n' "${errfiles[@]}" \
        | awk '{ sub(/.*\//, ""); sub(/\.rpt$/, ""); print }' > "$TMP/errpages"
fi

# the newest data day (jdn, col 7) anchors the windows; the newest day is
# PARTIAL when its last activity time is before 22:00 (the topview.sh rule
# for "(partial end)"), and then the 24-hours window spans TWO data days
read -r ENDJ PART <<< "$(LC_ALL=C awk -F'\t' '
    $7 != "" && $7 > m { m = $7 + 0 }
    { if ($7 != "" && $7 + 0 == m && $5 > lt[$7]) lt[$7] = $5 }
    END { print m + 0, ((lt[m] != "" && lt[m] < "22:00:00") ? 1 : 0) }' "$FCACHE")"

# The CALENDAR bounds of the six windows (full ISO dates) for the page titles:
# theoretical bounds from the anchor day — never the per-bucket data span.
# f = the partial offset: 24-hours = days 0..f, 48-hours = day f+1 alone.
read -r W24A W24B W48D WKA WKB W2A W2B W3A W3B MOA MOB <<< "$(awk -v j="$ENDJ" -v f="$PART" '
    function fromjdn(x,   a,b,c,dd,e,mm,day,mon,yr) { a=x+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    BEGIN { printf "%s %s %s %s %s %s %s %s %s %s %s", \
        fromjdn(j-f),  fromjdn(j),    fromjdn(j-f-1), \
        fromjdn(j-6),  fromjdn(j-f-2), \
        fromjdn(j-13), fromjdn(j-7),  fromjdn(j-20), fromjdn(j-14), \
        fromjdn(j-29), fromjdn(j-21) }')"

# ---- select, bucket, sort newest-first, format -------------------------------
# One pass tags each dated File with its bucket key; one sort orders
# (bucket, sortkey desc, CoreId) so the per-page payloads come out newest
# first and deterministic; one final pass writes each bucket's three payload
# sections (dates d-<k>, subscriptions s-<k>, rows r-<k>) and the stats.
# Dictionary indices are first-seen order over the sorted stream, so the
# payload is deterministic. The ROW CAP cuts a bucket at exactly ROWCAP rows
# (newest first); the rest of the window is counted but not shipped.
LC_ALL=C awk -F'\t' -v OFS='\t' -v endj="$ENDJ" -v f="$PART" '
    $4 == "" || $7 == "" { next }
    {
        d = endj - $7
        if (d < 0 || d >= 30) next
        if (d <= f)          w = "24-hours"
        else if (d == f + 1) w = "48-hours"
        else if (d < 7)      w = "week"
        else if (d < 14)     w = "2-weeks"
        else if (d < 21)     w = "3-weeks"
        else                 w = "month"
        print w, $6, $1, $2, $4, $8, $11, $12, $5
    }
' "$FCACHE" \
| LC_ALL=C sort -t$'\t' -k1,1 -k2,2r -k3,3 \
| LC_ALL=C awk -F'\t' -v errfile="$TMP/errpages" -v tmp="$TMP" -v slugf="$SLUGMAP" -v rowcap="$ROWCAP" '
    function humanbytes(b) {
        b = b + 0
        if (b < 1024)       return sprintf("%d B", b)
        if (b < 1048576)    return sprintf("%.2f KB", b / 1024)
        if (b < 1073741824) return sprintf("%.2f MB", b / 1048576)
        return sprintf("%.2f GB", b / 1073741824)
    }
    # the three JS template-literal escapes (split_search_rows'\'' rule)
    function esc(x) { gsub(/\\/, "\\\\", x); gsub(/`/, "\\`", x); gsub(/\$\{/, "\\${", x); return x }
    BEGIN {
        while ((getline l < errfile) > 0) if (l != "") EP[l] = 1; close(errfile)
        # name -> detail slug; a missing map just leaves every slug empty
        while ((getline l < slugf) > 0) { n = split(l, a, "\t")
            if (n >= 2 && a[1] != "") SLUG[a[1]] = a[2] }
        close(slugf)
    }
    {
        k = $1; cid = $3; oc = $4; dt = $5; sz = $6 + 0; nm = $7; sub9 = $8
        tm = substr($9, 1, 8)                      # HH:MM:SS — the ms add nothing here
        err = (oc == "Failed" || oc == "Expired") ? 1 : 0
        # the window figures count EVERYTHING, capped or not
        N[k]++; V[k] += sz; if (err) NE[k]++
        if (!(k in MX) || dt > MX[k]) MX[k] = dt
        if (!(k in MN) || dt < MN[k]) MN[k] = dt
        # the hard row cap, newest first
        if (NK[k] >= rowcap) { SK[k]++; next }
        FROM[k] = dt                               # oldest SHIPPED day so far
        # the two dictionaries, first-seen order
        if (!((k, dt) in DI)) { DI[k, dt] = ND[k]++; print dt > (tmp "/d-" k) }
        if (!((k, sub9) in SI)) { SI[k, sub9] = NS[k]++
            print esc(sub9) "\t" esc((sub9 in SLUG) ? SLUG[sub9] : "") > (tmp "/s-" k) }
        flag = err ? ((cid in EP) ? "E" : "e") : ""
        print esc(nm) "\t" DI[k, dt] "\t" SI[k, sub9] "\t" tm "\t" sz "\t" cid "\t" flag > (tmp "/r-" k)
        NK[k]++
    }
    END {
        split("24-hours 48-hours week 2-weeks 3-weeks month", KL, " ")
        for (i = 1; i <= 6; i++) { k = KL[i]
            printf "%s\t%d\t%s\t%s\t%s\t%d\t%s\t%d\t%d\n", k, N[k] + 0, humanbytes(V[k] + 0), \
                ((k in MN) ? MN[k] : "-"), ((k in MX) ? MX[k] : "-"), \
                NK[k] + 0, ((k in FROM) ? FROM[k] : "-"), SK[k] + 0, NE[k] + 0 > (tmp "/stats")
        }
        close(tmp "/stats")
    }
'

# the windows that actually HOLD data (2026-08): an empty window gets no
# page and no NAV button — 24-hours always stays, being the top bar's
# landing. DKEYS drives the NAV row and the writer loop below; the
# publisher removes the pages of keys whose rpt is absent.
DKEYS=""
for _dk in $KEYS; do
    IFS=$'\t' read -r _ _dkn _ _ _ _ _ _ _ <<< "$(command grep "^$_dk"$'\t' "$TMP/stats")"
    if [ "$_dk" = "24-hours" ] || [ "${_dkn:-0}" -gt 0 ]; then DKEYS="$DKEYS $_dk"; fi
done

# the NAV row: one sibling button per DATA-holding window, self marked
# current (state 1); the dedicated file-search.js rewrites the sibling
# links with ?q=<current query> after every search, so switching pages
# searches there automatically.
nav_row() {   # $1 = the current key
    local cur=$1 out="NAV" k lbl
    for k in $DKEYS; do
        case $k in
            24-hours) lbl="24 hours" ;;
            48-hours) lbl="48 hours" ;;
            week)     lbl="Week" ;;
            2-weeks)  lbl="2 weeks" ;;
            3-weeks)  lbl="3 weeks" ;;
            month)    lbl="Month" ;;
        esac
        if [ "$k" = "$cur" ]; then out+=$'\t'"1|$lbl|file-search-$k.html"
        else out+=$'\t'"0|$lbl|file-search-$k.html"; fi
    done
    printf '%s\n' "$out"
}

TOTKEPT=0
: > "$TMP/capped"
for k in $KEYS; do
    # an empty window: no page, no payload — and any stale pair goes
    case " $DKEYS " in *" $k "*) ;; *)
        rm -f "$REPORTS_DIR/file-search-$k.rpt" "$REPORTS_DIR/file-search-$k-data.js"
        continue ;;
    esac
    IFS=$'\t' read -r _ NTOT VH DMIN DMAX NSHIP FROM NSKIP NERR <<< "$(command grep "^$k"$'\t' "$TMP/stats")"
    TOTKEPT=$((TOTKEPT + NTOT))
    case $k in
        24-hours) TL="24 hours"; wdesc="the files of the newest **24 hours** (the newest full day, plus the partial newest day when one exists)"
                  span="$W24A to $W24B"; [ "$W24A" = "$W24B" ] && span="$W24B" ;;
        48-hours) TL="48 hours"; wdesc="the files of the **second full day**"
                  span="$W48D" ;;
        week)     TL="Week";     wdesc="the files of the **last week**, the newest two windows excluded"
                  span="$WKA to $WKB" ;;
        2-weeks)  TL="2 weeks";  wdesc="the files of the **last 2 weeks**, the newest week excluded"
                  span="$W2A to $W2B" ;;
        3-weeks)  TL="3 weeks";  wdesc="the files of the **last 3 weeks**, the newest 2 weeks excluded"
                  span="$W3A to $W3B" ;;
        month)    TL="Month";    wdesc="the files of the **last month**, the newest 3 weeks excluded"
                  span="$MOA to $MOB" ;;
    esac
    older=""
    case $k in month) older="Files older than 30 data days are on no page." ;; esac
    # the row cap: state exactly what is and is not searchable
    capnote=""
    [ "${NSKIP:-0}" -gt 0 ] && capnote=" **CAPPED:** of these, only the newest **$NSHIP** (back to **$FROM**) are searchable here — **$NSKIP** older files in this window are NOT shipped."
    OUT="$REPORTS_DIR/file-search-$k.rpt"
    {
        printf 'TITLE\tFile search — %s — %s\n' "$TL" "$span"
        printf 'DESC\tSearch %s by file name or CoreId — date, subscription, size and CoreId; OK rows green, Error rows red.\n' "$wdesc"
        printf 'INTRO\tSearch %s by file name or CoreId. Rows tint by outcome — **green** = OK (Delivered or Waiting), **red** = Error (Failed or Expired); a red row with an error page opens it, every other row opens its subscription.%s\n' "$wdesc" "$capnote"
        printf 'KEYWORDS\tfile,filename,file name,search,find,lookup,coreid,delivered,errored,waiting,expired,size,%s\n' "$TL"
        nav_row "$k"
        printf 'TABLE\t\twide\trestint\tnosort\tnosearch\tnofilter\n'
        printf 'HEAD\tName\tDate\tSubscription\tSize\tCoreId\n'
        printf 'KIND\tfile\ttext\tsite\tnum\tmono\n'
        printf 'SUMMARY\tFiles in this window: %s (%s Error)  |  Volume: %s  |  Window: %s to %s%s\n' "$NTOT" "${NERR:-0}" "$VH" "$DMIN" "$DMAX" "$([ "${NSKIP:-0}" -gt 0 ] && printf '  |  Searchable: %s (from %s)' "$NSHIP" "$FROM")"
        printf 'NOTE\tA **red** row is a transfer that **failed**, or a Waiting file whose staged copy the File Maintenance sweep deleted before pickup (**expired**); a red row with its own error page (kept for a subscription'\''s newest 10 failures of each day) opens it — the facts, every transfer leg, and the server log of its connections. A **green** row opens its subscription'\''s detail page. Date is the file'\''s first record'\''s date and time; Size counts the file once (its largest record).\n'
        [ -n "$older" ] && printf 'NOTE\t%s\n' "$older"
        printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    # the page's COMPACT data sidecar (the publish copies it beside the page)
    DOUT="$REPORTS_DIR/file-search-$k-data.js"
    {
        printf 'window.AXWAY_FSEARCH_D=`\n'
        [ -f "$TMP/d-$k" ] && cat "$TMP/d-$k"
        printf '`;\nwindow.AXWAY_FSEARCH_S=`\n'
        [ -f "$TMP/s-$k" ] && cat "$TMP/s-$k"
        printf '`;\nwindow.AXWAY_FSEARCH_R=`\n'
        [ -f "$TMP/r-$k" ] && cat "$TMP/r-$k"
        printf '`;\n'
    } > "$DOUT.tmp" && mv "$DOUT.tmp" "$DOUT"
    if [ "${NSKIP:-0}" -gt 0 ]; then
        printf '%s\t%s\t%s\n' "file-search-$k" "$NSHIP" "$NSKIP" >> "$TMP/capped"
        echo "WARNING: file-search-$k CAPPED at $NSHIP rows — $NSKIP file(s) in the window are not searchable." >&2
    fi
done
# the build-report red-banner marker: present (with the figures) exactly when
# a page dropped rows this run, gone otherwise
if [ -s "$TMP/capped" ]; then cp "$TMP/capped" "$CAPFILE"; else rm -f "$CAPFILE"; fi
echo "Data written to $REPORTS_DIR/file-search-*.rpt + -data.js (windows:$DKEYS; $TOTKEPT Files bucketed; newest day jdn $ENDJ, partial=$PART)." >&2
