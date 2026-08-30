#!/usr/bin/env bash
#
# file-cleanup.sh — file retention / cleanup activity, from the TM messages that
# delete files and run file maintenance:
#   Local deletes   AR0089 "Deleting local file: {…}" — the staged copy removed
#                   after a leg completes, per account.
#   Remote deletes  "Deleting remote file: <file> under <dir>." — files removed
#                   from a partner folder after pickup, per remote directory.
#   Maintenance     "Start File Maintenance for account […]" vs "File Maintenance
#                   for account […] finished." — the retention sweep per account
#                   (most runs start but only a few actually delete anything).
#
# A capacity/retention view: which accounts and remote folders churn the most
# files, and whether maintenance is actually completing. Names/dirs shown as
# logged (mono); an account matching a known transfer-log account is linked to
# its detail page. Reads data/_parse.tsv. Writes data/file-cleanup.rpt.
#
# Usage:
#   ./file-cleanup.sh    # reads input/*.csv (via the cache), writes data/file-cleanup.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/file-cleanup.rpt"

# Entity cross-links: known account names from the transfer Account report
# (ROW field 2 of its FIRST table). An account that matches a known one —
# exactly, or after stripping its @endpoint suffix — gets an @{link=…} prefix
# on its cell (rendered by bin/publish_lib.sh render_cell as a link to its
# detail page); unresolved accounts stay plain text. Linking is skipped when
# the transfer report is absent.
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# LINK_AWK — slug() matches bin/publish_lib.sh's slugify (the same function as
# entity-search.sh's SLUG_AWK); acctlink() returns the @{link=…} cell prefix
# for a known account (exact, also @endpoint-stripped), or "" when unresolved.
LINK_AWK='
    function slug(x){ x=tolower(x); gsub(/[^a-z0-9]+/,"-",x); sub(/^-+/,"",x); sub(/-+$/,"",x); return x }
    function acctlink(t,   s) {
        if (t in kacct) return "@{alink=accounts/" t "}"
        s = t; sub(/@.*$/, "", s)
        if (s in kacct) return "@{alink=accounts/" s "}"
        return ""
    }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TACCT"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass. acc(ns, name, date) accumulates count + per-date buckets + first/last.
# Maintenance tracks starts and finishes per account separately.
#   L <TAB> account <TAB> deletes <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   R <TAB> directory <TAB> deletes <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   M <TAB> account <TAB> starts <TAB> finishes <TAB> buckets(date:starts:finishes) <TAB> first <TAB> last <TAB> loglines
#   TOT <TAB> local <TAB> remote <TAB> mstart <TAB> mfin <TAB> naccts <TAB> ndirs <TAB> nmaccts
agg=$(awk -F'\t' "$LOGLINES_AWK$LINK_AWK"'
    function acc(ns, nm, d,   k, dk) { k = ns SUBSEP nm; cnt[k]++
        if (d != "") { dk = k SUBSEP d; dd[dk]++
            if (!(dk in dseen)) { dseen[dk]=1; dlist[k] = dlist[k] (dlist[k]?",":"") d }
            if (!(k in fst) || d < fst[k]) fst[k]=d
            if (!(k in lst) || d > lst[k]) lst[k]=d } }
    $1 == "KA" { kacct[$2] = 1; next }                       # known-account list (first input)
    {
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        line = lvlname($3) " " compname($4) "  " substr(m, 1, 200)

        if (m ~ /Deleting local file:/) {
            a = "(unknown)"; if (match(m, /\[[^]]*\]/)) { a = substr(m, RSTART+1, RLENGTH-2); sub(/@.*/, "", a) }
            acc("L", a, d); addline("L" SUBSEP a, $1 " " $2, line); tloc++
        } else if (m ~ /Deleting remote file:.* under /) {
            dir = "(unknown)"; if (match(m, /under [^ ]+/)) { dir = substr(m, RSTART+6, RLENGTH-6); sub(/\.$/, "", dir) }
            acc("R", dir, d); addline("R" SUBSEP dir, $1 " " $2, line); trem++
        } else if (m ~ /Start File Maintenance/) {
            a = "(all)"; if (match(m, /\[[^]]*\]/)) { a = substr(m, RSTART+1, RLENGTH-2); sub(/@.*/, "", a) }
            mst[a]++; tmst++; mseen[a]=1
            if (d != "") { mdstart[a SUBSEP d]++; mk=a SUBSEP d; if(!(mk in mdseen)){mdseen[mk]=1; mdlist[a]=mdlist[a] (mdlist[a]?",":"") d}
                if (!(a in mfst)||d<mfst[a]) mfst[a]=d; if (!(a in mlst)||d>mlst[a]) mlst[a]=d }
            addline("M" SUBSEP a, $1 " " $2, line)
        } else if (m ~ /File Maintenance for account .* finished/) {
            a = "(all)"; if (match(m, /\[[^]]*\]/)) { a = substr(m, RSTART+1, RLENGTH-2); sub(/@.*/, "", a) }
            mfin[a]++; tmfin++; mseen[a]=1
            if (d != "") { mdfin[a SUBSEP d]++; mk=a SUBSEP d; if(!(mk in mdseen)){mdseen[mk]=1; mdlist[a]=mdlist[a] (mdlist[a]?",":"") d}
                if (!(a in mfst)||d<mfst[a]) mfst[a]=d; if (!(a in mlst)||d>mlst[a]) mlst[a]=d }
            addline("M" SUBSEP a, $1 " " $2, line)
        }
    }
    END {
        nl=0; nr=0
        for (k in cnt) {
            split(k, ka, SUBSEP); ns=ka[1]; nm=ka[2]
            m2=split(dlist[k], dz, ","); bk=""
            for (i=1;i<=m2;i++){ dd2=dz[i]; bk=bk (bk?",":"") dd2 ":" dd[k SUBSEP dd2] }
            if (ns=="L") nl++; else if (ns=="R") nr++
            lp = (ns=="L") ? acctlink(nm) : ""               # L is an account; R is a directory (never linked)
            printf "%s\t%s%s\t%d\t%s\t%s\t%s\t%s\n", ns, lp, nm, cnt[k], bk, fst[k], lst[k], lastlines(k)
        }
        nm2=0
        for (a in mseen) { nm2++
            m2=split(mdlist[a], dz, ","); bk=""
            for (i=1;i<=m2;i++){ dd2=dz[i]; bk=bk (bk?",":"") dd2 ":" (mdstart[a SUBSEP dd2]+0) ":" (mdfin[a SUBSEP dd2]+0) }
            printf "M\t%s%s\t%d\t%d\t%s\t%s\t%s\t%s\n", acctlink(a), a, mst[a]+0, mfin[a]+0, bk, mfst[a], mlst[a], lastlines("M" SUBSEP a)
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", tloc+0, trem+0, tmst+0, tmfin+0, nl, nr, nm2
    }
' <(known_names KA "$TACCT") "$PARSED")

IFS=$'\t' read -r _ t_loc t_rem t_mst t_mfin n_acct n_dir n_macct <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ $(( t_loc + t_rem + t_mst )) -eq 0 ]; then
    echo "No file-cleanup messages found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

rows3() {   # $1 = namespace (L|R) — name | count | first | last
    while IFS=$'\t' read -r _ name count bk fst lst lines; do
        [ -z "$name" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$name" "$count" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $"^$1"$'\t' | sort -t$'\t' -k3,3nr)"
}
# Same fork-free assembly as rows3 above (a `$(printf …)` per row is a subshell,
# and this table runs to hundreds of accounts); it accumulates rather than
# printing because its consumer keeps the trailing newline the rows carry.
maint_rows=""
while IFS=$'\t' read -r _ acct starts fins bk fst lst lines; do
    [ -z "$acct" ] && continue
    maint_rows+="ROW"$'\t'"$acct"$'\t'"$starts"$'\t'"$fins"$'\t'"$fst"$'\t'"$lst"$'\t'"@data:buckets=$bk"$'\t'"@data:loglines=$lines"$'\n'
done <<< "$(printf '%s\n' "$agg" | grep $'^M\t' | sort -t$'\t' -k3,3nr)"

{
    printf 'TITLE\tFile Cleanup\n'
    printf 'DESC\tFile retention / cleanup activity — local and remote file deletes and the file-maintenance sweeps, by account and remote directory. A capacity/retention view.\n'
    printf 'INTRO\t**%s** local file delete(s) across **%s** account(s), **%s** remote file delete(s) across **%s** directory(ies), and **%s** file-maintenance run(s) started vs **%s** finished. Local deletes clean up the staged copy after a leg; remote deletes remove picked-up files from partner folders. Click a row for its 10 most recent messages.\n' \
        "$t_loc" "$n_acct" "$t_rem" "$n_dir" "$t_mst" "$t_mfin"

    printf 'TABLE\tLocal file deletes by account\twide\n'
    printf 'HEAD\tAccount\tFiles deleted\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\n'
    printf '%s\n' "$(rows3 L)"   # %s\n: $(rows3) stripped the trailing newline
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t\t\n' "$n_acct" "$t_loc"
    printf 'NOTE\tAR0089 "Deleting local file: {…}" — the staged local copy removed after a leg completes, attributed to the account (endpoint stripped). Shown as logged; an account known from the transfer logs links to its detail page. Additive; re-totals under the date filter.\n'

    printf 'TABLE\tRemote file deletes by directory\twide\n'
    printf 'HEAD\tRemote directory\tFiles deleted\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\n'
    printf '%s\n' "$(rows3 R)"   # %s\n: $(rows3) stripped the trailing newline
    printf 'TOTAL\tTotal (%s directory(ies))\t@{class=num}%s\t\t\n' "$n_dir" "$t_rem"
    printf 'NOTE\t"Deleting remote file: <file> under <dir>." — files removed from a partner folder after they were picked up, grouped by the remote directory.\n'

    printf 'TABLE\tFile maintenance by account\twide\n'
    printf 'HEAD\tAccount\tStarts\tFinishes\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnum\tnumprocessed\ttext\ttext\n'
    printf 'RECALC\t-\ts0\ts1\t-\t-\n'
    printf '%s' "$maint_rows"
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t@{class=num processed}%s\t\t\n' "$n_macct" "$t_mst" "$t_mfin"
    printf 'NOTE\t"Start File Maintenance …" vs "File Maintenance … finished." A finish is only logged when the sweep actually deleted files, so far fewer finishes than starts is normal (most runs find nothing to remove). A big gap for one account, or none finishing, is worth a look.\n'

    printf 'SUMMARY\tLocal deletes: %s  |  Remote deletes: %s  |  Maintenance starts: %s / finishes: %s\n' "$t_loc" "$t_rem" "$t_mst" "$t_mfin"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_loc local, $t_rem remote, $t_mst maint-start, $t_mfin maint-fin)." >&2
