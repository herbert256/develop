#!/usr/bin/env bash
#
# resubmissions.sh — "Resubmissions": the legs carrying the transfer log's
# Resubmitted=true flag (_transfers.tsv col 24) — a MANUAL resubmit is human
# intervention, so this is a direct marker of flows that did not recover on
# their own. Per day and per subscription, with drills.
#
# Usage:
#   ./resubmissions.sh   # reads input/*.csv (via the caches), writes data/resubmissions.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/resubmissions.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
# The server-log resubmission trail (third table) reads the SERVER parse cache
# — a cross-area CACHE read (the rule forbids reading server REPORTS). Both
# parses are complete before any report stage runs, so the read is safe; the
# dep makes fresh server data regenerate this report too.
SRV_PARSE="$DATA/server/cache/_parse.tsv"
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SRV_PARSE"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# _transfers.tsv: 1=coreid 3=status 4=account 6=site 9=size 11=date 12=time
# 13=sortkey 24=resubmitted. Counts LEGS (the flag is per physical row);
# Files = distinct CoreIds with >=1 resubmitted leg.
agg=$(awk -F'\t' "$COREIDS_AWK"'
    $22 != "true" { next }
    {
        st = $3; sub(/ Subtransmission$/, "", st); pf = (st != "Processed")
        d = $11
        tl++; if (pf) tf++; else tp++
        if (!($1 in seenc)) { seenc[$1] = 1; tcid++ }
        if (d != "") { dl[d]++; df[d] += pf; dp[d] += (!pf); if (!((d SUBSEP $1) in dc)) { dc[d SUBSEP $1] = 1; dcid[d]++ } }
        s = ($6 == "") ? "(no subscription)" : $6
        sl[s]++; if (!((s SUBSEP $1) in sc)) { sc[s SUBSEP $1] = 1; scid[s]++ }
        if (d != "") { sdl[s SUBSEP d]++
            if (!(s in sfirst) || d < sfirst[s]) sfirst[s] = d
            if (!(s in slast)  || d > slast[s])  slast[s] = d }
        addtop("S" SUBSEP s, $13, $11 " " $12, $1)
    }
    END {
        for (d in dl) printf "DAY|%s|%d|%d|%d|%d\n", d, dl[d], df[d]+0, dp[d]+0, dcid[d]+0
        for (s in sl) {
            bk = ""; for (k in sdl) { split(k, a2, SUBSEP); if (a2[1] == s) bk = bk (bk ? "," : "") a2[2] ":" sdl[k] }
            printf "SUB|%08d|%s|%d|%d|%s|%s|%s|%s\n", sl[s], s, sl[s], scid[s], sfirst[s], slast[s], bk, buildlist(top["S" SUBSEP s])
        }
        printf "TOT|%d|%d|%d|%d\n", tl+0, tf+0, tp+0, tcid+0
    }
' "$PARSED")

IFS='|' read -r _ tot_legs tot_failed tot_processed tot_files <<< "$(printf '%s\n' "$agg" | grep '^TOT|' || printf 'TOT|0|0|0|0\n')"

emptym=""
if [ "$tot_legs" = 0 ]; then emptym=1; fi

# ---- the server log's own resubmission trail (2026-08): per-day "Error ----
# while resubmitting transfer" (E) vs "Resubmission successfully executed"
# (I) lines from the SERVER cache. The table is emitted UNCONDITIONALLY (a
# missing/empty cache renders the placeholder row): resubmissions is a
# merged-component of Retries, whose tab bar enumerates tables, so the TABLE
# count must not vary per env.
sagg=""
if [ -f "$SRV_PARSE" ]; then
    sagg=$(awk -F'\t' '
        $3 == "E" && $5 ~ /Error while resubmitting transfer with id/ {
            d = substr($1, 1, 10); if (d ~ /^[0-9][0-9][0-9][0-9]-/) { e[d]++; te++; days[d] = 1 }
        }
        $5 ~ /^Resubmission successfully executed for file: / {
            d = substr($1, 1, 10); if (d ~ /^[0-9][0-9][0-9][0-9]-/) { s[d]++; ts++; days[d] = 1
                if (sfirst == "" || d < sfirst) sfirst = d }
        }
        END {
            for (d in days) printf "SRV|%s|%d|%d\n", d, e[d]+0, s[d]+0
            pd = ""; pn = -1
            for (d in e) if (e[d] > pn || (e[d] == pn && d < pd)) { pn = e[d]; pd = d }
            printf "STOT|%d|%d|%s|%d|%s\n", te+0, ts+0, pd, (pn < 0 ? 0 : pn), sfirst
        }
    ' "$SRV_PARSE")
fi
IFS='|' read -r _ srv_err srv_ok srv_peakd srv_peakn srv_okfirst <<< "$(printf '%s\n' "$sagg" | grep '^STOT|' || printf 'STOT|0|0||0|\n')"

{
    printf 'TITLE\tResubmissions\n'
    printf 'DESC\tThe manually resubmitted transfer legs (Resubmitted=true) — human intervention on flows that did not recover on their own.\n'
    printf 'KEYWORDS\tresubmit, resubmitted, manual, intervention, operator, rerun\n'
    printf 'INTRO\tLegs carrying the transfer log'\''s **Resubmitted** flag — someone (or an automation) explicitly resubmitted the transfer, so every row here is a flow that needed a push. **%s** resubmitted leg(s) on **%s** File(s): **%s** still Error, **%s** OK after the resubmit.\n' "$tot_legs" "$tot_files" "$tot_failed" "$tot_processed"

    if [ -n "$emptym" ]; then
        printf 'TABLE\tResubmitted legs per day\tnofilter\tnosort\n'
    else
        # noagg=4: the Files column counts DISTINCT CoreIds (a File resubmitted
        # on several days appears once in the total but once per day in the
        # rows), so a filtered re-total must show "–", not the inflated row sum
        printf 'TABLE\tResubmitted legs per day\tnoagg=4\n'
    fi
    printf 'HEAD\tDate\tResubmitted legs\tError\tOK\tFiles\n'
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\n'
    # The placeholder row keeps its trailing newline, or the TOTAL line below
    # would glue onto it.
    if [ -n "$emptym" ]; then
        printf 'ROW\t@{colspan=5}No resubmitted legs in this data window.\n'
    else
        while IFS='|' read -r _ d legs fa pr cid; do
            [ -z "$d" ] && continue
            printf 'ROW\t%s\t%s\t%s\t%s\t%s\n' "$d" "$legs" "$fa" "$pr" "$cid"
        done <<< "$(printf '%s\n' "$agg" | grep '^DAY|' | sort -t'|' -k2,2r)"
    fi
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\n' \
        "$tot_legs" "$tot_failed" "$tot_processed" "$tot_files"

    if [ -n "$emptym" ]; then
        printf 'TABLE\tPer subscription\tnofilter\tnosort\n'
    else
        printf 'TABLE\tPer subscription\tdrill=File\n'
    fi
    printf 'HEAD\tSubscription\tResubmitted legs\tFiles\tFirst\tLast\n'
    printf 'KIND\tsite\tnum\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    if [ -n "$emptym" ]; then
        printf 'ROW\t@{colspan=5}No resubmitted legs in this data window.\n'
    else
        while IFS='|' read -r _ _pad s legs cid first last bk dr; do
            [ -z "$s" ] && continue
            printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids=%s\n' "$s" "$legs" "$cid" "$first" "$last" "$bk" "$dr"
        done <<< "$(printf '%s\n' "$agg" | grep '^SUB|' | sort -t'|' -k2,2r)"
    fi
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}%s\t\t\n' "$tot_legs" "$tot_files"
    printf 'NOTE\tClick a row for that subscription'\''s 10 most recent resubmitted Files. Error/OK is the LEG'\''s own status — an OK resubmitted leg is the retry that finally worked. Files and First/Last stay full-period under a narrowed date range.\n'

    # ---- table 3: the server log's own resubmission trail (2026-08) ----
    if [ "${srv_err:-0}" -gt 0 ] || [ "${srv_ok:-0}" -gt 0 ]; then
        printf 'TABLE\tResubmission outcomes (server log)\n'
    else
        printf 'TABLE\tResubmission outcomes (server log)\tnofilter\tnosort\n'
    fi
    printf 'HEAD\tDate\tErrors\tSuccesses\n'
    printf 'KIND\ttext\tnumfailed\tnumprocessed\n'
    if [ "${srv_err:-0}" -gt 0 ] || [ "${srv_ok:-0}" -gt 0 ]; then
        while IFS='|' read -r _ d se ss; do
            [ -z "$d" ] && continue
            printf 'ROW\t%s\t%s\t%s\n' "$d" "$se" "$ss"
        done <<< "$(printf '%s\n' "$sagg" | grep '^SRV|' | sort -t'|' -k2,2r)"
    else
        printf 'ROW\t@{colspan=3}No server-log resubmission lines in this data window.\n'
    fi
    printf 'TOTAL\tTotal\t@{class=num failed}%s\t@{class=num processed}%s\n' "${srv_err:-0}" "${srv_ok:-0}"
    if [ "${srv_err:-0}" -gt 0 ] || [ "${srv_ok:-0}" -gt 0 ]; then
        printf 'NOTE\tThe SERVER log'\''s own resubmission trail, per day: "Error while resubmitting transfer with id …" (Error) vs "Resubmission successfully executed for file: …" (Info). This complements the leg view above — the server lines also catch resubmit attempts that never produced a transfer-log leg. The worst error day was **%s** (**%s** errors); the error spike rides the PeSIT abort storm (the server report'\''s PeSIT diagCode 310 wave) — resubmitting into a broken ST → CFT link fails again until the link recovers.%s\n' \
            "${srv_peakd:--}" "${srv_peakn:-0}" "$( [ -n "${srv_okfirst:-}" ] && printf ' The first success line is dated %s.' "$srv_okfirst" )"
    else
        printf 'NOTE\tThe SERVER log'\''s own resubmission trail — "Error while resubmitting transfer" vs "Resubmission successfully executed" lines, per day. None in this data window.\n'
    fi

    printf 'SUMMARY\tResubmitted legs: %s | Files: %s | Server-log resubmissions: %s errors / %s successes\n' "$tot_legs" "$tot_files" "${srv_err:-0}" "${srv_ok:-0}"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_legs resubmitted leg(s))." >&2
