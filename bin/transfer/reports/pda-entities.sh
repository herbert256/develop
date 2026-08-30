#!/usr/bin/env bash
#
# pda-entities.sh — the Logical + three PDA entities as Entities reports, one
# .rpt per dimension from the logical-transfer cache (each File carries its
# partner / application / domain attribution, _files.tsv cols 20 / 18 / 19;
# the Logical resolves the profile column 13 through the FlowID map,
# xref/_profiles-logicals.tsv):
#   logical.rpt  partner.rpt  application.rpt  domain.rpt
# Each is the exact account.sh shape — a summary per name (Files, Failed,
# Processed, Volume, % of Files, First/Last seen) plus a per-day detail — so
# showseen.sh and entity-search.sh can lift counts/buckets/drill from the
# summaries exactly like the classic five. The name column is plain text:
# these entities link to their own detail pages.
#
# Usage:
#   ./pda-entities.sh    # reads input/*.csv (via the caches), writes data/{logical,partner,application,domain}.rpt
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
mkdir -p "$REPORTS_DIR"
ensure_parsed
# one script, FOUR outputs — skip only when ALL are fresh (guarding just
# partner.rpt left application/domain.rpt stale after a mid-loop failure)
_pda_fresh=1
for _o in logical partner application domain; do
    _f="$REPORTS_DIR/$_o.rpt"
    if ! { [ -f "$_f" ] && ! [ "$PARSED" -nt "$_f" ] && ! [ "$FILES" -nt "$_f" ] && ! [ "${BASH_SOURCE[0]}" -nt "$_f" ]; }; then
        _pda_fresh=0; break
    fi
done
if [ "$_pda_fresh" = 1 ]; then
    echo "  logical/partner/application/domain.rpt are up to date; skipping." >&2
    exit 0
fi
unset _pda_fresh _o _f
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

for dim in logical partner application domain; do
    case $dim in
        logical)     col=13; title="Logical";      chead="Logical"; nkind=lgc
                     attr="the file's logical flow group (its FlowID condensed to a 3-part group name — data/flow-manager/base/_logicals.tsv)" ;;
        partner)     col=20; title="Partners";     chead="Partner"; nkind=ptn
                     attr="the file's partner organisation (part 3 of its logical flow name, merged into organisations — data/flow-manager/base/_partners.tsv)" ;;
        application) col=18; title="Applications"; chead="Application"; nkind=app
                     attr="part 2 of the file's logical flow name (data/flow-manager/base/_apps.tsv)" ;;
        domain)      col=19; title="Domains";      chead="Domain"; nkind=dom
                     attr="part 1 of the file's logical flow name (data/flow-manager/base/_domains.tsv)" ;;
    esac
    OUT="$REPORTS_DIR/$dim.rpt"

    # One pass over _files.tsv (1=coreid, 2=outcome, 4=date_iso, 5=time,
    # 6=sortkey, 8=size, C=the dimension value) — account.sh's aggregation
    # with the account column swapped for the PDA attribution. Files without
    # the attribution or a valid date are skipped.
    # UNION attribution: a File counts for EVERY name its config maps to,
    # UNIONED with the parse-time attribution ($C) — deduped per (name,
    # CoreId), so these Files can sum to more than the distinct total.
    #   partner:     col 12 (subscription) joined on _subscriptions-partners
    #                — a UC5 relay / both-partner file belongs to BOTH
    #                organisations, and the both-partner case carries an
    #                EMPTY col 20 (the parse abstains on a two-group account)
    #   application: col 3 (account) joined on _accounts-apps — a UC8 relay
    #                account carries TWO applications (its partner token is
    #                really an application), but parse.sh'\''s col 18 holds
    #                only ONE (last map row wins), silently starving the other
    # Domains stay single-valued (part 1 of the name — never doubles).
    UMAP=""; UKEY=0
    case $dim in
        logical)     [ -f "$CONFIG_XREF/_subscriptions-logicals.tsv" ] && { UMAP="$CONFIG_XREF/_subscriptions-logicals.tsv"; UKEY=12; } ;;
        partner)     [ -f "$CONFIG_XREF/_subscriptions-partners.tsv" ] && { UMAP="$CONFIG_XREF/_subscriptions-partners.tsv"; UKEY=12; } ;;
        application) [ -f "$CONFIG_XREF/_accounts-apps.tsv" ] && { UMAP="$CONFIG_XREF/_accounts-apps.tsv"; UKEY=3; } ;;
    esac
    # the logical dim's DIRECT attribution is the profile column resolved
    # through the FlowID map — an unmapped or blank profile abstains (the
    # union via the subscription may still count the File)
    VMAP=""
    [ "$dim" = logical ] && [ -f "$CONFIG_XREF/_profiles-logicals.tsv" ] && VMAP="$CONFIG_XREF/_profiles-logicals.tsv"
    agg=$(awk -F'\t' -v C="$col" -v UMAP="$UMAP" -v UK="$UKEY" -v VMAP="$VMAP" "$COREIDS_AWK"'
        function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
            while (v >= 1024 && i < 6) { v /= 1024; i++ }
            return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
        BEGIN {
            if (UMAP != "") { while ((getline l < UMAP) > 0) { n2 = split(l, z, "\t")
                if (n2 >= 2 && z[1] != "" && z[2] != "") sp[toupper(z[1])] = sp[toupper(z[1])] (sp[toupper(z[1])] == "" ? "" : "\037") z[2] } close(UMAP) }
            if (VMAP != "") { while ((getline l < VMAP) > 0) { n2 = split(l, z, "\t")
                if (n2 >= 2 && z[1] != "" && z[2] != "") vm[toupper(z[1])] = z[2] } close(VMAP) }
        }
        $4 == "" { next }
        {
            delete P; np2 = 0
            if ($C != "") { v = $C
                if (VMAP != "") v = ((toupper($C) in vm) ? vm[toupper($C)] : "")
                if (v != "") { P[v] = 1; np2++ } }
            if (UMAP != "" && $UK != "" && (toupper($UK) in sp)) {
                n2 = split(sp[toupper($UK)], z, "\037")
                for (i2 = 1; i2 <= n2; i2++) if (!(z[i2] in P)) { P[z[i2]] = 1; np2++ }
            }
            if (np2 == 0) next
            f = ($2 == "Failed" || $2 == "Expired"); date = $4; sk = $6; disp = $4 " " $5; cid = $1; size = $8
            for (a in P) {
                sc[a]++; if (f) sfl[a]++; else spr[a]++; sv[a] += size
                if (!(a in havemin) || sk < mink[a]) { mink[a] = sk; fst[a] = date; havemin[a] = 1 }
                if (!(a in havemax) || sk > maxk[a]) { maxk[a] = sk; lst[a] = date; havemax[a] = 1 }
                addtop("S" SUBSEP a SUBSEP (f ? "F" : "P"), sk, disp, cid)
                dk = a SUBSEP date; ds[dk] = 1; dl[dk]++; if (f) dfl[dk]++; else dpr[dk]++; ddb[dk] += size
                addtop("D" SUBSEP a SUBSEP date SUBSEP (f ? "F" : "P"), sk, disp, cid)
            }
            tc++; if (f) tfl++; else tpr++; tvol += size
        }
        END {
            for (dk in ds) { split(dk, kk, SUBSEP)
                bk[kk[1]] = bk[kk[1]] (bk[kk[1]] ? "," : "") kk[2] ":" dl[dk] ":" (dfl[dk]+0) ":" (dpr[dk]+0) ":" ddb[dk] }
            for (a in sc) { ns++
                sh = tc > 0 ? sprintf("%.1f", sc[a] * 100 / tc) : "0.0"
                printf "S|%s|%d|%d|%d|%s|%s|%s|%s|%s|%s|%s\n", a, sc[a], sfl[a]+0, spr[a]+0, human(sv[a]+0), sh, fst[a], lst[a], \
                    bk[a], buildlist(top["S" SUBSEP a SUBSEP "F"]), buildlist(top["S" SUBSEP a SUBSEP "P"]) }
            for (dk in ds) { split(dk, x, SUBSEP); nd++
                printf "D|%s|%s|%d|%d|%d|%s|%s\n", x[1], x[2], dl[dk], dfl[dk]+0, dpr[dk]+0, \
                    buildlist(top["D" SUBSEP x[1] SUBSEP x[2] SUBSEP "F"]), buildlist(top["D" SUBSEP x[1] SUBSEP x[2] SUBSEP "P"]) }
            printf "T|%d|%d|%d|%s|%d|%d\n", tc+0, tfl+0, tpr+0, human(tvol+0), ns+0, nd+0
        }
    ' "$FILES")

    if [ -z "$agg" ]; then
        echo "No usable records found ($dim)." >&2
        continue
    fi

    IFS='|' read -r _ tot_records tot_failed tot_processed tot_human summary_row_count detail_row_count <<< "$(printf '%s\n' "$agg" | grep '^T|')"

    # Summary rows, busiest first. ONE awk pass formats the sorted stream into
    # finished ROW lines — a bash while-read with a $(printf) per row forked a
    # subshell per name, three dims deep. The last field takes the line's
    # remainder, like read into the final variable did.
    summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
        $2 == "" { next }
        { ccp = $12; for (i = 13; i <= NF; i++) ccp = ccp "|" $i
          printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
              $2, $3, $4, $5, $6, $8, $9, $10, $11, ccp }')

    # Detail rows, sorted by name then date (repeated name blanked in-browser).
    detail_rows=$({ printf '%s\n' "$agg" | grep '^D|' || true; } | sort -t'|' -k2,2 -k3,3 | awk -F'|' '
        $2 == "" { next }
        { ccp = $8; for (i = 9; i <= NF; i++) ccp = ccp "|" $i
          printf "ROW\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
              $2, $3, $4, $5, $6, $7, ccp }')

    {
        printf 'TITLE\t%s\n' "$title"
        printf 'DESC\tFiles per %s: a summary and a per-day detail, both split into Error/OK.\n' "$dim"
        src="derived from the logical flow names (and, for partners, the endpoint/whitelist/alias merge)"
        [ "$dim" = logical ] && src="derived from the FlowIDs, condensed into logical flow groups"
        printf 'INTRO\tEvery %s with its **Files** (one per CoreId), Error/OK split, volume and last sighting — %s. The view tabs switch between logged (**Seen**), configured (**All** / **Not seen**), the status subsets (**OK** / **Warning** / **Error**) and the server-log-only ones (**Server**); the scope tabs decide whether a server-log sighting counts as seen (**+Server**, the default) or not (**Transfer**) — rows tint by each %s'\''s status.\n' "$dim" "$src" "$dim"

        printf 'TABLE\tSummary per %s\twide\n' "$chead"
        printf 'HEAD\t%s\tFiles\tError\tOK\tVolume\tFirst seen\tLast seen\n' "$chead"
        printf "KIND\t$nkind\tnum\tnumfailed\tnumprocessed\tnum\ttext\ttext\n"
        printf 'RECALC\t-\ts0\ts1\ts2\th3\t-\t-\n'
        [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
        printf 'TOTAL\tTotal (%s %s(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t\t\n' \
            "$summary_row_count" "$dim" "$tot_records" "$tot_failed" "$tot_processed" "$tot_human"

        printf 'TABLE\tDetail per %s / Date\tgroup\n' "$chead"
        printf 'HEAD\t%s\tDate\tFiles\tError\tOK\n' "$chead"
        printf "KIND\t$nkind\ttext\tnum\tnumfailed\tnumprocessed\n"
        [ -n "$detail_rows" ] && printf '%s\n' "$detail_rows"
        printf 'TOTAL\t@{colspan=2}Total (%s row(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\n' \
            "$detail_row_count" "$tot_records" "$tot_failed" "$tot_processed"

        printf 'NOTE\tCounts Files — one logical transfer each; the %s is %s. Names link to the logical / partner / application / domain detail pages. Volume is the file counted once; First/Last seen stay full-period under the date filter. **The Total row counts each File once** (the site-wide distinct figure); a narrowed date range re-totals over the per-%s rows, whose union attribution can claim one File for several %ss — so a filtered Total can run slightly higher than the distinct figure it replaces, and snaps back to it at the full range. Click an Error or OK count for that outcome'\''s 10 most recent Files (newest first).\n' "$dim" "$attr" "$dim" "$dim"
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "Data written to $OUT ($summary_row_count $dim(s), $tot_records file(s))." >&2
done
