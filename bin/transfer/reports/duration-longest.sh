#!/usr/bin/env bash
#
# duration-longest.sh — "Longest Files": the TOP_N longest logical transfers
# by WALL-CLOCK duration (data/_files.tsv col 9, dur_ms — first record start
# to last record end, gaps included), split out of duration.sh 2026-09-03
# (user request) into its own Performance-group page.
#
# ONE table: the DELIVERED Files only — outcome Processed; not Failed, not
# Expired and not Waiting either (2026-09-13, user request: the former
# "All transfers" switch view, every outcome with a measured duration, is
# gone — a failed transfer's run time is a timeout, not a duration). Every
# row links its per-transfer RECORD page, docs/<env>/transfers/duration/top/
# <coreid>.html, written here (moved from duration.sh) into
# $REPORTS_DIR/duration/top/ and rendered by bin/transfer/publish.sh.
# Columns: Duration (sorting by the exact milliseconds via @{sortval}), Start
# Time, CoreId, Destination Subscription, Size, File — the former "Duration
# (ms)" and "Account" columns went with the split (user request). EVERY
# listed File (either scope) also gets a File page docs/<env>/files/
# <coreid>.html (the sidecar _longest-files.tsv, paged by failed.sh) — its
# CoreId cell opens that instead of the record page (2026-09-03, user
# request; the one-hour threshold it started with was dropped 2026-09-06,
# user request).
#
# Usage:
#   ./duration-longest.sh    # -> data/<env>/transfer/reports/duration-longest.rpt
#                            #    + duration/top/<coreid>.rpt (the OK list)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/duration-longest.rpt"
TOPDIR="$REPORTS_DIR/duration/top"         # the per-transfer record pages (OK list)
FILESIDE="$REPORTS_DIR/_longest-files.tsv"  # every listed CoreId → File pages (failed.sh)
TOPLINK="../transfers/duration/top"        # their href base from docs/<env>/transfer/
TOP_N=50

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
# the record-page dir is an output too: a missing one forces a rebuild
[ -d "$TOPDIR" ] || rm -f "$OUT"
[ -f "$FILESIDE" ] || rm -f "$OUT"
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# top_list — the TOP_N longest DELIVERED Files (outcome Processed), ms-descending:
#   ms ⇥ coreid ⇥ "date time" ⇥ subscription ⇥ size ⇥ file ⇥ humandur ⇥ humanbytes
top_list() {
    awk -F'\t' '
        function clean(s){ gsub(/[\t\r]/, " ", s); return s }
        function humandur(ms) {
            if (ms < 1000)    return sprintf("%d ms", ms)
            if (ms < 60000)   return sprintf("%.2f s", ms/1000)
            if (ms < 3600000) return sprintf("%.1f min", ms/60000)
            return sprintf("%.2f h", ms/3600000)
        }
        function humanbytes(b,   u, i, v) {
            split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
            while (v >= 1024 && i < 6) { v /= 1024; i++ }
            return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i])
        }
        $2 != "Processed" { next }   # delivered Files only: no Failed, no Expired, no Waiting
        { ms = $9 + 0; if (ms <= 0) next
          s = clean($12); if (s == "") s = "(no subscription)"
          sz = int($8)
          printf "%d\t%s\t%s %s\t%s\t%d\t%s\t%s\t%s\n", ms, $1, $4, $5, s, sz, clean($11), humandur(ms), humanbytes(sz) }
    ' "$FILES" | sort -t$'\t' -k1,1nr | awk -v n="$TOP_N" 'NR<=n'
}
# the scope total (delivered Files with a duration), for the TOTAL row
count_scope() { awk -F'\t' '$2 == "Processed" && ($9 + 0) > 0 { n++ } END { print n + 0 }' "$FILES"; }

slow_ok=$(top_list)
n_ok=$(count_scope)
shown_ok=$(printf '%s\n' "$slow_ok" | awk 'length($0) { n++ } END { print n+0 }')

# the FILE-page list (2026-09-03, user request): EVERY listed File gets a
# File page docs/<env>/files/<coreid>.html, the errors-page layout for a
# File of any outcome; failed.sh writes it from this sidecar (unioned with
# the Transfer patterns list) and the CoreId cell of every row opens it (the
# one-hour threshold went 2026-09-06, user request: at most TOP_N pages).
# cmp-guarded: an unchanged list keeps its mtime (a failed.sh dep); an
# EMPTY list is valid (-f, not -s)
printf '%s\n' "$slow_ok" \
    | awk -F'\t' 'length($0) { print $2 }' \
    | LC_ALL=C sort -u > "$FILESIDE.tmp"
if cmp -s "$FILESIDE.tmp" "$FILESIDE" 2>/dev/null; then rm -f "$FILESIDE.tmp"; else mv "$FILESIDE.tmp" "$FILESIDE"; fi

# the per-transfer RECORD pages of the OK list: every _transfers.tsv record
# of the CoreId, chronological — the page a Duration / Start Time / CoreId
# cell opens (moved here from duration.sh 2026-09-03)
rm -rf "$TOPDIR"; mkdir -p "$TOPDIR"
if [ -n "$slow_ok" ]; then
    printf '%s\n' "$slow_ok" | awk -F'\t' 'length($0) { printf "%d\t%s\t%s\t%s\n", ++k, $2, $4, $1 }' \
    | awk -F'\t' -v OUTDIR="$TOPDIR" -v TOPN="$shown_ok" '
        function humandur(ms){ ms=ms+0; if(ms<0)return "-"; if(ms<1000)return sprintf("%d ms",ms); if(ms<60000)return sprintf("%.2f s",ms/1000); if(ms<3600000)return sprintf("%.1f min",ms/60000); return sprintf("%.2f h",ms/3600000) }
        function human(b,  u,i,v){ b=b+0; if(b<=0)return "0 B"; split("B KB MB GB TB PB",u," "); i=1; v=b; while(v>=1024&&i<6){v/=1024;i++}; return (i==1)?sprintf("%d %s",v,u[i]):sprintf("%.2f %s",v,u[i]) }
        function nz(s){ return (s=="")?"-":s }
        BEGIN { US=sprintf("%c",31) }
        NR==FNR { rank[$2]=$1; msite[$2]=$3; mdur[$2]=$4; order[++nt]=$2; next }
        ($1 in rank) {
            k=$1; c=++cnt[k]
            rows[k US c] = $13 US $2 US $3 US $11 US $12 US $15 US $9 US $10 US $5 US $16 US $20 US $8 US $23
        }
        END {
            for (t=1; t<=nt; t++) {
                c=order[t]; out=OUTDIR "/" c ".rpt"; n=cnt[c]+0
                for (i=1;i<=n;i++) A[i]=rows[c US i]
                for (i=2;i<=n;i++){ v=A[i]; sk=v; sub(US".*","",sk); j=i-1
                    while (j>=1){ p=A[j]; sub(US".*","",p); if(p>sk){A[j+1]=A[j];j--} else break } A[j+1]=v }
                split(A[n],L,US); oc=(L[3]!="Failed" && L[3]!="Expired")?"OK":"Error"
                site=nz(msite[c])
                printf "TITLE\tTransfer %s\n", c > out
                printf "INTRO\t**%d** record(s) for CoreId `%s`. Subscription **%s**, total duration **%s**, final outcome **%s**. Ranked #%s of the %d longest delivered transfers (the Longest Files page).\n", n, c, site, humandur(mdur[c]), oc, rank[c], TOPN > out
                printf "TABLE\tAll records (chronological)\twide\tnosort\n" > out
                printf "HEAD\tDirection\tStatus\tDate\tTime\tDuration\tSize\tProtocol\tLogin\tRemote Host\tMode\tFile\tTransfer ID\n" > out
                printf "KIND\ttext\ttext\ttext\tmono\ttext\tnum\ttext\tmono\tmono\ttext\tfile\tmono\n" > out
                for (i=1;i<=n;i++){ split(A[i],F,US)
                    printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                        nz(F[2]),nz(F[3]),nz(F[4]),nz(F[5]),humandur(F[6]),human(F[7]),nz(F[8]),nz(F[9]),nz(F[10]),nz(F[11]),nz(F[12]),nz(F[13]) > out
                }
                printf "LINK\t../../../transfer/duration-longest.html\tBack to Longest Files\n" > out
                printf "FOOT\tGenerated from _transfers.tsv (all records for this CoreId)\n" > out
                close(out); delete A
            }
        }
    ' - "$PARSED"
fi

# rows: Duration (sortval = the exact ms) ⇥ Start Time ⇥ CoreId ⇥ Subscription ⇥
# Size ⇥ File; the OK rows link their record page from the Duration and Start
# Time cells, and EVERY row's CoreId cell opens its File page
rows_of() {   # $1 the list  $2 link base ("" = plain rows)
    printf '%s\n' "$1" | awk -F'\t' -v L="$2" 'length($0) {
        h = (L != "") ? "href=" L "/" $2 ".html," : ""
        hc = "href=../files/" $2 ".html,"
        printf "ROW\t@{%ssortval=%d}%s\t@{%ssortval=%d}%s\t@{%ssortval=%d}%s\t%s\t%s\t%s\n", h, $1, $7, h, $1, $3, hc, $1, $2, $4, $8, $6 }'
}
GENDATE=$(date '+%Y-%m-%d %H:%M:%S')
{
    printf 'TITLE\tLongest Files\n'
    printf 'DESC\tThe %s longest delivered Files by wall-clock duration, each opening its per-transfer record page.\n' "$TOP_N"
    printf 'INTRO\tThe **%s longest delivered Files** by **wall-clock duration** — from the first record start to the last record end, store-and-forward gaps and retry idle included. Only **OK** Files are listed (outcome Processed): a Failed, Expired or Waiting File is not a completed transfer, and a failure'\''s run time is a timeout, not a duration. Click a Duration or Start Time cell for the transfer'\''s **record page** — every record of that CoreId, chronological. Every listed File has its own **File page** (facts, records and the server log of its connections) — its **CoreId** cell opens that. The columns sort by the exact duration.\n' "$TOP_N"
    printf 'TABLE\tTop %s longest Files by duration\twide\n' "$TOP_N"
    printf 'HEAD\tDuration\tStart Time\tCoreId\tDestination Subscription\tSize\tFile\n'
    printf 'KIND\ttext\ttext\tmono\tsite\tnum\tfile\n'
    rows_of "$slow_ok" "$TOPLINK"
    printf 'TOTAL\tTop %s of %s Files\t\t\t\t\t\n' "$shown_ok" "$n_ok"
    printf 'NOTE\tOne "File" = one logical transfer (all records sharing a CoreId); its duration is the wall-clock span of those records, so it includes the store-and-forward wait inside SecureTransport and any retry idle. Delivered (Processed) Files only — the failed, expired and still-waiting ones are left out (2026-09-13). Every listed File has a record page and a File page.\n'
    printf 'KEYWORDS\tduration,longest,slowest,slow,top,wall-clock,record,coreid,transfer\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$GENDATE" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($shown_ok of $n_ok delivered Files; $shown_ok record page(s) in $TOPDIR)." >&2
