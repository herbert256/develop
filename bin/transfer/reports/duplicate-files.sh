#!/usr/bin/env bash
#
# duplicate-files.sh — repeated deliveries of the same business filename. Groups
# logical transfers (_files.tsv) by their file (basename) and lists the names
# delivered more than once, worst-first. This catches replay loops, a source
# re-sending, or a stuck flow retrying — but note that a duplicate FILENAME is not
# always a replay: date-stamped names are unique, while a fixed name (a daily
# "export.zip") legitimately recurs. So read this as "filenames seen more than
# once — investigate the unexpected ones", not "these are all replays".
#
# Reads data/_files.tsv (1=coreid, 2=outcome, 3=account, 4=date_iso, 6=sortkey,
# 11=file). Writes data/duplicate-files.rpt.
#
# Usage:
#   ./duplicate-files.sh    # reads input/*.csv (via the cache), writes data/duplicate-files.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/duplicate-files.rpt"
TOP_N=200

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over _files.tsv. Per filename: deliveries, failed, distinct
# accounts, per-date buckets, first/last, and the recent-deliveries drill.
# Emits: G <TAB> file <TAB> deliveries <TAB> failed <TAB> naccts <TAB> first <TAB> last <TAB> buckets(date:deliveries:failed) <TAB> coreids
#        TOT <TAB> groups <TAB> transfers-in-groups
agg=$(awk -F'\t' "$COREIDS_AWK"'
    $11 == "" { next }
    {
        f = $11; oc = $2; a = $3; d = $4; if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        fail = (oc == "Failed" || oc == "Expired")
        cnt[f]++; if (fail) ff[f]++
        if (a != "" && !((f SUBSEP a) in aseen)) { aseen[f SUBSEP a]=1; nacc[f]++ }
        if (d != "") {
            fd[f SUBSEP d]++; ffd[f SUBSEP d] += fail
            if (!((f SUBSEP d) in dseen)) { dseen[f SUBSEP d]=1; dlist[f] = dlist[f] (dlist[f]?",":"") d }
            if (!(f in fst) || d < fst[f]) fst[f]=d
            if (!(f in lst) || d > lst[f]) lst[f]=d
        }
        addtop(f, $6, $4 " " $5, $1)
    }
    END {
        g=0; ntr=0
        for (f in cnt) if (cnt[f] > 1) {
            g++; ntr += cnt[f]
            no=split(dlist[f], dz, ","); bk=""
            for (i=1;i<=no;i++){ dd=dz[i]; bk=bk (bk?",":"") dd ":" fd[f SUBSEP dd] ":" (ffd[f SUBSEP dd]+0) }
            printf "G\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n", f, cnt[f], ff[f]+0, nacc[f]+0, (fst[f]==""?"-":fst[f]), (lst[f]==""?"-":lst[f]), (bk==""?"-":bk), buildlist(top[f])
        }
        printf "TOT\t%d\t%d\n", g, ntr
    }
' "$FILES")

IFS=$'\t' read -r _ n_groups n_intr <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${n_groups:-0}" -eq 0 ]; then
    # No data (e.g. a minimal dataset) is not an error — write an empty-state
    # page and exit 0, so the build's report pool does not abort.
    {
        printf 'TITLE\tDuplicate Files\n'
        printf 'DESC\tBusiness filenames delivered more than once — repeated deliveries of the same file, worst-first. Catches replay loops and re-sends (but a fixed filename legitimately recurs).\n'
        printf 'INTRO\tNo business filename was delivered more than once in this dataset.\n'
        printf 'TABLE\tDuplicate filenames\n'
        printf 'HEAD\tFile\n'
        printf 'KIND\ttext\n'
        printf 'ROW\tNo duplicate filenames in this dataset.\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "No duplicate filenames found — wrote empty-state $OUT." >&2
    exit 0
fi

# Top-N groups by deliveries (then failed)
shown=0
group_rows=$(printf '%s\n' "$agg" | grep $'^G\t' | sort -t"$(printf '\t')" -k3,3nr -k4,4nr | awk -v n="$TOP_N" 'NR<=n' | while IFS=$'\t' read -r _ f del fail nacc fst lst bk cids; do
    [ -z "$f" ] && continue
    [ "$fst" = "-" ] && fst=""; [ "$lst" = "-" ] && lst=""; [ "$bk" = "-" ] && bk=""   # sentinel -> empty (keeps the TAB columns aligned when a filename recurs only on blank-date rows)
    printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids=%s\n' "$f" "$del" "$fail" "$nacc" "$fst" "$lst" "$bk" "$cids"
done)
shown=$(printf '%s\n' "$group_rows" | grep -c '^ROW' || true)
capnote=""
[ "$n_groups" -gt "$TOP_N" ] && capnote=$(printf ' Showing the top %s of %s repeated-filename groups (by deliveries).' "$TOP_N" "$n_groups")

{
    printf 'TITLE\tDuplicate Files\n'
    printf 'DESC\tBusiness filenames delivered more than once — repeated deliveries of the same file, worst-first. Catches replay loops and re-sends (but a fixed filename legitimately recurs).\n'
    printf 'INTRO\t**%s** filename(s) were delivered more than once, covering **%s** logical transfers.%s A duplicate filename is not always a replay — date-stamped names are unique, while a fixed name (e.g. a daily export) recurs by design — so treat this as "filenames seen more than once, investigate the unexpected ones". Click a row for its 10 most recent Files.\n' \
        "$n_groups" "$n_intr" "$capnote"

    printf 'TABLE\tRepeated filenames\twide\n'
    printf 'HEAD\tFilename\tFiles\tError\tAccounts\tFirst\tLast\n'
    printf 'KIND\tfile\tnum\tnumfailed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\ts1\t-\t-\t-\n'
    printf '%s\n' "$group_rows"
    # footer: shown-row count + sums of the summable columns (Accounts is a
    # distinct count, not additive; report.js re-totals on filtering)
    printf '%s\n' "$group_rows" | awk -F'\t' '/^ROW/{n++; c+=$3; f+=$4} END{printf "TOTAL\tTotal (%d rows)\t@{class=num}%d\t@{class=num failed}%d\t\t\t\n", n+0, c+0, f+0}'
    printf 'NOTE\tOne row per filename delivered more than once (grouped from the logical-transfer cache). Files = how many logical transfers carried that exact filename; Error = how many of them failed; Accounts = distinct accounts that sent it (a full-period figure, not date-adjusted). An Error count lower than the group'\''s Files usually means a failed transfer was re-sent successfully. Files and Error re-aggregate over the selected dates. Click a row for its 10 most recent Files.\n'
    printf 'SUMMARY\tRepeated filenames: %s  |  Files in duplicate groups: %s  |  Shown: %s\n' "$n_groups" "$n_intr" "$shown"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_groups group(s), $n_intr transfer(s) in groups)." >&2
