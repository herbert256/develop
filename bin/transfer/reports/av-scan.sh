#!/usr/bin/env bash
#
# av-scan.sh
# Anti-virus / ICAP scan outcomes, counted on the FIRST INBOUND LEG of every
# CoreId — the scan runs when a file ENTERS the system, so that leg carries
# the File's verdict (one per File). Parsed from the free-text "ICAP Details"
# column: Allowed, Blocked, Not performed, Error or Unknown.
# The "Not first inbound" tab is the CHECK on that model: every real scan
# verdict (Allowed/Blocked/Error) found on any OTHER leg — inbound retries
# and the UC2 staging re-entry show up here; outbound legs never should.
#
# Usage:
#   ./av-scan.sh    # reads input/*.csv, writes data/av-scan.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/av-scan.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ONE chronological walk (coreid, sortkey) feeds the whole report: the group's
# first Inbound leg carries the File's scan verdict; every other leg feeds the
# check tab when it carries a REAL verdict (Allowed/Blocked/Error/Other — not
# Unknown, not the "Scanning was not performed" boilerplate outbound legs
# repeat). The Blocked detail rows are written out to $TMP on the way past, so
# a blocked-heavy window cannot blow up $agg and the sorted cache is read once
# instead of three times.
# Cache cols: 1=coreid 2=direction 8=file 10=protocol 11=date 12=time
# 13=sortkey 17=av_bucket.
TMP=$(mktemp "${TMPDIR:-/tmp}/avscan.XXXXXX")
trap 'rm -f "$TMP"' EXIT

agg=$(LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k13,13 "$PARSED" | awk -F'\t' -v blk="$TMP" "$COREIDS_AWK"'
    # buildlist joins with commas (the @data:coreids row-drill format);
    # per-CELL drills (data-drill-cell-N) expect \x1f-joined entries instead
    function cellist(p,   s) { s = buildlist(top[p]); gsub(/,/, _US, s); return s }
    $1 != cur { cur = $1; seenin = 0 }
    # The moment scanning became ACTIVE in this window: the earliest sortkey
    # with an Allowed verdict, on ANY leg. Everything "Not performed" BEFORE
    # that moment is the pre-activation era (in this dataset: scanning went
    # live 2026-06-25 16:57 — derived from the data each run, never hardcoded).
    # Stays empty when the window has no Allowed at all (scanning off
    # throughout).
    $17 == "Allowed" && $13 != "" && ($13 < avon || avon == "") { avon = $13 }
    {
        fi = 0
        if ($2 == "Inbound" && !seenin) { seenin = 1; fi = 1 }
        b = $17; day = $11; proto = ($10 == "" ? "?" : $10)
        if (fi) {
            # every first-inbound Blocked leg, for the Blocked transfers table
            if (b == "Blocked" && $13 != "") printf "%s|%s|%s|%s|%s|%s|%s\t%s\n", $13, $11, $12, $4, $5, $6, proto, $8 > blk
            if (day == "") next
            oc[b]++; total++
            dtot[day]++; ptot[proto]++; seen_p[proto] = 1
            ocd[b SUBSEP day]++; pdt[proto SUBSEP day]++
            # drill lists: the 10 most recent Files behind EVERY number —
            # per outcome (Breakdown rows), per day x category and per
            # protocol x category (one list per numeric cell)
            cat = (b == "Allowed") ? "A" : (b == "Blocked") ? "B" : (b == "Not performed") ? "N" : "O"
            addtop("OUT" SUBSEP b, $13, $11 " " $12, $1)
            addtop("D" SUBSEP day SUBSEP cat, $13, $11 " " $12, $1)
            addtop("D" SUBSEP day SUBSEP "T", $13, $11 " " $12, $1)
            addtop("P" SUBSEP proto SUBSEP cat, $13, $11 " " $12, $1)
            addtop("P" SUBSEP proto SUBSEP "T", $13, $11 " " $12, $1)
            if (b == "Allowed")            { da[day]++; pa[proto]++; pda[proto SUBSEP day]++ }
            else if (b == "Blocked")       { db[day]++; pb[proto]++; pdb[proto SUBSEP day]++ }
            else if (b == "Not performed") { dn[day]++; pn[proto]++; pdn[proto SUBSEP day]++
                # WHY was the scan skipped? An aborted/empty arrival never gets
                # scanned; a complete file skips when the scanner cannot see
                # inside (encrypted) or it exceeds the scan-size cap; anything
                # else is Other (future cases). The pre-activation era outranks
                # all four, but its boundary (avon) is only known once the whole
                # window has been read — so the row is BUFFERED here and
                # classified in END.
                st = $3; sub(/ Subtransmission$/, "", st)
                fn = tolower($8)
                if (st != "Processed" || $9 + 0 == 0) r = 1
                else if (fn ~ /\.pgp$/ || fn ~ /\.enc$/) r = 2
                else if ($9 + 0 >= 1048576) r = 3
                else r = 4
                nnp++; npq[nnp] = r SUBSEP day SUBSEP $13 SUBSEP ($11 " " $12) SUBSEP $1
            }
            else                           { do_[day]++; po[proto]++; pdo[proto SUBSEP day]++ }
            seen_day[day] = 1
        } else if (b != "Unknown" && b != "Not performed" && b != "") {
            k = $2 SUBSEP proto SUBSEP b
            nf[k]++; nftot++
            if (day != "") nfd[k SUBSEP day]++
            addtop("X" SUBSEP k, $13, $11 " " $12, $1)
        }
    }
    END {
        # the buffered Not-performed rows, now that the pre-activation boundary
        # is known (r = 0 beats the reason the walk computed)
        for (i = 1; i <= nnp; i++) {
            split(npq[i], zf, SUBSEP)
            r = (avon != "" && zf[3] != "" && zf[3] < avon) ? 0 : zf[1]
            np[r]++; npd[r SUBSEP zf[2]]++
            addtop("N" SUBSEP r, zf[3], zf[4], zf[5])
        }
        printf "AVON|%s\n", (avon == "" ? "" : sprintf("%s-%s-%s %s", substr(avon, 1, 4), substr(avon, 5, 2), substr(avon, 7, 2), substr(avon, 9, 8)))
        for (k in ocd) { split(k, a, SUBSEP); obk[a[1]] = obk[a[1]] (obk[a[1]] ? "," : "") a[2] ":" ocd[k] }
        for (k in pdt) { split(k, a, SUBSEP); pbk[a[1]] = pbk[a[1]] (pbk[a[1]] ? "," : "") a[2] ":" (pda[k]+0) ":" (pdb[k]+0) ":" (pdn[k]+0) ":" (pdo[k]+0) ":" pdt[k] }
        for (k in oc) printf "OUT|%s|%d|%s|%s|%s\n", k, oc[k], (total ? sprintf("%.1f", oc[k]*100/total) : "0.0"), obk[k], buildlist(top["OUT" SUBSEP k])
        for (k in seen_day) printf "DAY|%s|%d|%d|%d|%d|%d|%s|%s|%s|%s|%s\n", k, da[k]+0, db[k]+0, dn[k]+0, do_[k]+0, dtot[k], \
            cellist("D" SUBSEP k SUBSEP "A"), cellist("D" SUBSEP k SUBSEP "B"), cellist("D" SUBSEP k SUBSEP "N"), cellist("D" SUBSEP k SUBSEP "O"), cellist("D" SUBSEP k SUBSEP "T")
        for (k in seen_p) printf "PRO|%s|%d|%d|%d|%d|%d|%s|%s|%s|%s|%s|%s\n", k, pa[k]+0, pb[k]+0, pn[k]+0, po[k]+0, ptot[k], pbk[k], \
            cellist("P" SUBSEP k SUBSEP "A"), cellist("P" SUBSEP k SUBSEP "B"), cellist("P" SUBSEP k SUBSEP "N"), cellist("P" SUBSEP k SUBSEP "O"), cellist("P" SUBSEP k SUBSEP "T")
        for (k in nf) {
            split(k, a, SUBSEP)
            bk = ""
            for (k2 in nfd) { split(k2, a2, SUBSEP); if (a2[1] SUBSEP a2[2] SUBSEP a2[3] == k) bk = bk (bk ? "," : "") a2[4] ":" nfd[k2] }
            printf "NFI|%s|%s|%s|%d|%s|%s\n", a[1], a[2], a[3], nf[k], bk, buildlist(top["X" SUBSEP k])
        }
        for (r = 0; r <= 4; r++) {
            bk = ""
            for (k2 in npd) { split(k2, a2, SUBSEP); if (a2[1] == r) bk = bk (bk ? "," : "") a2[2] ":" npd[k2] }
            printf "NPR|%d|%d|%s|%s\n", r, np[r]+0, bk, buildlist(top["N" SUBSEP r])
        }
        printf "TOT|%d|%d|%d|%d|%d|%d\n", oc["Allowed"]+0, oc["Blocked"]+0, oc["Not performed"]+0, (total - (oc["Allowed"]+0) - (oc["Blocked"]+0) - (oc["Not performed"]+0)), total, nftot+0
    }
')

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ tot_allowed tot_blocked tot_notperf tot_other tot_all tot_nfi <<< "$(printf '%s\n' "$agg" | grep '^TOT|')"
# the window's first Allowed verdict, already formatted for display ("" when
# the window has none) — it names the pre-activation era in the reason table
avon_disp=$(printf '%s\n' "$agg" | awk -F'|' '$1 == "AVON" { print $2 }')

# The row blocks are formatted by awk straight into the .rpt below (one fork
# per table, not one per row): grep picks the tag, sort orders it, awk shapes
# the ROW lines.
{
    printf 'TITLE\tAV Scan (ICAP) Outcomes\n'
    printf 'DESC\tAnti-virus scan outcomes on the first Inbound leg of every File — the scan runs when a file enters the system.\n'
    printf 'KEYWORDS\ticap, virus, av, blocked, allowed, scan, first inbound\n'
    # META line (not rendered) feeds the root-index KPI strip in bin/build/publish.sh.
    printf 'META\tblocked\t%s\n' "$tot_blocked"
    printf 'INTRO\tScan outcomes on the **first Inbound leg** of every File — the AV scan runs when a file ENTERS the system, so that leg carries the File'\''s verdict (one per File). **%s** allowed  |  **%s** blocked  |  **%s** not performed. The **Not first inbound** tab is the check: scan verdicts found on any other leg.\n' \
        "$tot_allowed" "$tot_blocked" "$tot_notperf"

    printf 'TABLE\tScan outcome breakdown\n'
    printf 'HEAD\tOutcome\tFiles\tShare\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    # Outcome breakdown rows (largest first). Tint Allowed green, Blocked red.
    printf '%s\n' "$agg" | grep '^OUT|' | sort -t'|' -k3,3nr | awk -F'|' '
        $2 != "" {
            cell = ($2 == "Allowed") ? "@{class=processed}" $2 : ($2 == "Blocked") ? "@{class=failed}" $2 : $2
            printf "ROW\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids=%s\n", cell, $3, $4, $5, $6
        }' || true                       # no first-inbound leg at all: no rows, not a failure
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}100.0%%\n' "$tot_all"

    printf 'TABLE\tScan outcomes per day\n'
    printf 'HEAD\tDate\tAllowed\tBlocked\tNot performed\tOther\tTotal\n'
    printf 'KIND\ttext\tnumprocessed\tnumfailed\tnum\tnum\tnum\n'
    # Per-day rows (chronological); every numeric cell carries its own drill list.
    printf '%s\n' "$agg" | grep '^DAY|' | sort -t'|' -k2,2 | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:drill-cell-1=%s\t@data:drill-cell-2=%s\t@data:drill-cell-3=%s\t@data:drill-cell-4=%s\t@data:drill-cell-5=%s\n", \
                          $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }' || true
    printf 'TOTAL\tTotal\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\n' \
        "$tot_allowed" "$tot_blocked" "$tot_notperf" "$tot_other" "$tot_all"

    printf 'TABLE\tScan outcomes per protocol\n'
    printf 'HEAD\tProtocol\tAllowed\tBlocked\tNot performed\tOther\tTotal\n'
    printf 'KIND\tmono\tnumprocessed\tnumfailed\tnum\tnum\tnum\n'
    printf 'RECALC\t-\ts0\ts1\ts2\ts3\ts4\n'
    # Per-protocol rows — HOW files enter the system, largest first. The sort
    # key is field 7 = Total, the row's magnitude (like the outcome breakdown
    # above, which sorts on its own count column); it was field 6 = Other,
    # which is 0 on every row, so the order fell through to the alphabetical
    # whole-line tie-break and read smallest-first.
    printf '%s\n' "$agg" | grep '^PRO|' | sort -t'|' -k7,7nr | awk -F'|' '
        $2 != "" { printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:drill-cell-1=%s\t@data:drill-cell-2=%s\t@data:drill-cell-3=%s\t@data:drill-cell-4=%s\t@data:drill-cell-5=%s\n", \
                          $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13 }' || true
    printf 'TOTAL\tTotal\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\n' \
        "$tot_allowed" "$tot_blocked" "$tot_notperf" "$tot_other" "$tot_all"
    printf 'NOTE\tThe protocol of the first Inbound leg — HOW the file entered the system (pesit = from CFT, ssh/ftp = a partner delivering in).\n'

    # Blocked detail: every first-inbound Blocked leg individually, newest first.
    printf 'TABLE\tBlocked transfers\twide\n'
    printf 'HEAD\tDate\tTime\tAccount\tLogin\tSubscription\tProtocol\tFile\n'
    printf 'KIND\ttext\ttext\tacct\tlogin\tsite\tmono\tfile\n'
    blocked_rows=$(sort -t'|' -k1,1r "$TMP" | awk -v n=200 'NR<=n')
    if [ -n "$blocked_rows" ]; then
        nblk=0
        while IFS='|' read -r _sk bdate btime bacct blogin bsite brest; do
            [ -z "$bdate" ] && continue
            nblk=$((nblk + 1))
            bproto=${brest%%$'\t'*}; bfile=${brest#*$'\t'}
            printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$bdate" "$btime" "$bacct" "$blogin" "$bsite" "$bproto" "$bfile"
        done <<< "$blocked_rows"
        printf 'TOTAL\tTotal (%s rows)\t\t\t\t\t\t\n' "$nblk"
        if [ "$nblk" -eq 200 ] && [ "$tot_blocked" -gt 200 ]; then
            printf 'NOTE\tShowing the 200 most recent of %s blocked Files.\n' "$tot_blocked"
        fi
    else
        printf 'ROW\t@{colspan=7}No blocked transfers in this data window.\n'
    fi

    # The Not-performed WHY tab: the skip reasons, fixed four-row layout (the
    # Other row stays visible at 0 so a future new skip reason is noticed).
    printf 'TABLE\tNot performed\n'
    printf 'HEAD\tReason\tFiles\tShare\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    printf '%s\n' "$agg" | grep '^NPR|' | sort -t'|' -k2,2n | awk -F'|' -v tot="$tot_notperf" -v avd="$avon_disp" '
        function nplabel(r) {
            if (r == 0) return "Before scanning was active (pre first Allowed verdict" (avd == "" ? "" : ", " avd) ")"
            if (r == 1) return "Failed or empty arrival (nothing to scan)"
            if (r == 2) return "Encrypted file (.pgp / .enc)"
            if (r == 3) return "Oversized (>= 1 MB)"
            return "Other"
        }
        $2 != "" { printf "ROW\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:coreids=%s\n", \
                          nplabel($2 + 0), $3, (tot > 0 ? sprintf("%.1f", $3 * 100 / tot) : "0.0"), $4, $5 }'
    printf 'TOTAL\tTotal\t@{class=num}%s\t@{class=num}100.0%%\n' "$tot_notperf"
    printf 'NOTE\tWhy the scanner skipped these arrivals. **Before scanning was active**: everything ahead of the window'\''s FIRST Allowed verdict — the boundary is derived from the data each run, and in this window scanning went live mid-2026-06-25; before that, every arrival entered unscanned. **Failed or empty**: the receive aborted or brought 0 bytes — nothing whole to scan. **Encrypted**: the scanner cannot see inside a .pgp/.enc file. **Oversized**: above the ICAP scan-size cap. **Other** catches what no known reason explains — it should sit at (or near) 0, and growth there is a new skip reason worth investigating. Click a row for its 10 most recent Files.\n'

    # The CHECK tab: real scan verdicts on legs that are NOT the first Inbound.
    printf 'TABLE\tNot first inbound\n'
    printf 'HEAD\tDirection\tProtocol\tOutcome\tTransfers\n'
    printf 'KIND\ttext\tmono\ttext\tnum\n'
    printf 'RECALC\t-\t-\t-\ts0\n'
    if [ "${tot_nfi:-0}" -gt 0 ]; then
        # the check tab: real verdicts on NON-first-inbound legs (largest first)
        printf '%s\n' "$agg" | grep '^NFI|' | sort -t'|' -k5,5nr | awk -F'|' '
            $2 != "" {
                cell = ($4 == "Allowed") ? "@{class=processed}" $4 : ($4 == "Blocked") ? "@{class=failed}" $4 : $4
                printf "ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids=%s\n", $2, $3, cell, $5, $6, $7
            }'
        printf 'TOTAL\tTotal\t\t\t@{class=num}%s\n' "$tot_nfi"
        printf 'NOTE\tScan verdicts (Allowed/Blocked/Error) on legs OTHER than the File'\''s first Inbound leg — the check on the "scan on entry" model. What legitimately shows up: **Inbound retries** (a re-entry is re-scanned) and the **UC2 staging re-entry** (Inbound routing). An **Outbound** row here would break the model. The plain "Scanning was not performed" boilerplate on outbound legs is excluded.\n'
    else
        printf 'ROW\t@{colspan=4}No scan verdicts outside the first Inbound leg — the scan-on-entry model holds.\n'
        printf 'TOTAL\tTotal\t\t\t@{class=num}0\n'
    fi

    printf 'NOTE\tOne scan verdict per File — its first Inbound leg (a File with no Inbound leg has no scan). Outcomes are parsed from the free-text "ICAP Details" column; "Other" groups Error/Unknown and unrecognized text.\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_blocked blocked, $tot_allowed allowed, $tot_nfi off-model leg(s))." >&2
