#!/usr/bin/env bash
#
# partner-scorecard.sh — "Partner scorecard": one composite 0-100 health score
# per partner organisation with at least 100 Files, built from six visible
# components (each is its own column, the NOTE states the weights):
#
#   error %          the heaviest weight: the score STARTS at 100 minus the
#                    partner's Error share (Failed or Expired Files)
#   14-day trend     error % of the last 14 log days vs the 14 before them —
#                    a WORSENING delta deducts, an improving one never adds
#   pickup wait      UC2 partners only: average partner pickup wait (the
#                    _files col 21 staging-to-collect wait); > 24 h deducts
#   security         share of the partner's transfer legs on a weak security
#                    parameter (ssh-rsa host key or TLSv1.2)
#   host redundancy  everything we send rides ONE outbound endpoint
#   quiet            no File for 14+ days (measured against the newest log day)
#
# PARTNER = UNION attribution (xref/_subscriptions-partners.tsv on _files
# col 12 unioned with col 20), the same rule as every partner-counting page.
# The concentration boxes (top-1/3/10 share, Gini) cover ALL seen partners;
# the scorecard lists only the >=100-Files organisations — a score over a
# handful of Files would be noise. (The side-by-side Top 10 by volume / by
# Files tables went 2026-09-29: the Entities Partners view sorted on Volume
# or Files is the same list, date-aware.)
#
# Sources: the transfer caches (_files.tsv, _transfers.tsv col 19 secparams)
# and the flow-manager xref. Config/analysis page: every table is `nofilter`.
#
# Usage:
#   ./partner-scorecard.sh   # -> data/analyses/reports/partner-scorecard.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/pda-union.sh"   # SP_AWK: the File attribution UNION (sp_union)
OUT="$REPORTS_DIR/partner-scorecard.rpt"

TF="$DATA/transfer/cache/_files.tsv"
TT="$DATA/transfer/cache/_transfers.tsv"
if [ ! -f "$TF" ] || [ ! -f "$TT" ]; then
    echo "partner-scorecard: transfer caches missing; skipping." >&2
    rm -f "$OUT"
    exit 0
fi

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
# pre-create the awk side outputs: with an EMPTY estate (config-only clone)
# the main pass writes no row, and a later sort over a missing file is fatal
: > "$TMPD/score.pre"; : > "$TMPD/stats.tsv"

# One pass: the SP union per CoreId, per-partner counters (Files, errors,
# bytes, per-day counts for the trend, UC2 wait, out-endpoints, direction,
# last seen), then the PARSED legs for the security share. END writes the
# sortable scorecard rows and
# the STAT figures (all explicitly ordered/sorted — no hash-order output).
awk -F'\t' -v ROWS="$TMPD/score.pre" -v STATS="$TMPD/stats.tsv" -v SPMAP="$SP_MAP" "$SP_AWK"'
    function jdn(y, m, d,   a2, y2, m2) { a2 = int((14 - m) / 12); y2 = y + 4800 - a2; m2 = m + 12 * a2 - 3
        return d + int((153 * m2 + 2) / 5) + 365 * y2 + int(y2 / 4) - int(y2 / 100) + int(y2 / 400) - 32045 }
    function djdn(s) { return jdn(substr(s,1,4)+0, substr(s,6,2)+0, substr(s,9,2)+0) }
    function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
    FILENAME ~ /_files\.tsv$/ {
        set = sp_union($20, $12)   # the partner UNION set (bin/pda-union.sh)
        if (set == "") next
        PSET[$1] = set
        err = ($2 == "Failed" || $2 == "Expired") ? 1 : 0
        if ($4 != "" && $4 > maxd) maxd = $4
        n = split(set, Z, "\037")
        for (i = 1; i <= n; i++) { p = Z[i]
            if (F[p] == "") PORD[++np] = p          # emptiness, not membership (mawk)
            F[p]++; E[p] += err; B[p] += $8
            if ($4 != "") { if ($4 > L[p]) L[p] = $4; DF[p SUBSEP $4]++; DE[p SUBSEP $4] += err }
            # the pickup WAIT: col 21 is set by the parse on a File of the UC2
            # SHAPE (staged, then collected) whatever its name — gated on the
            # shape itself (2026-09-29 audit: the UC2-name / derived-UC2 gate
            # dropped the waits of configured flows with neither, e.g. the
            # sample STMT_EXPORT_GLOBEX_nn pickups)
            if ($21 + 0 > 0) { W[p] += $21; WN[p]++ }
            if ($16 == "out" && $15 != "" && !((p SUBSEP $15) in OH)) { OH[p SUBSEP $15] = 1; NH[p]++ }
            if ($16 == "in") DI[p] = 1; else if ($16 == "out") DO[p] = 1
            else if ($17 == "in") DI[p] = 1; else if ($17 == "out") DO[p] = 1
        }
        next }
    {   # _transfers.tsv: security parameters per leg, attributed to the CoreId set
        if (!($1 in PSET)) next
        w = 0
        if ($19 ~ /ssh-rsa/)   { w = 1; nr2 = 1 } else nr2 = 0
        if ($19 ~ /TLSv1\.2/)  { w = 1; nt2 = 1 } else nt2 = 0
        n = split(PSET[$1], Z, "\037")
        for (i = 1; i <= n; i++) { p = Z[i]; SN[p]++
            if (w) { SW[p]++; if (nr2) KR[p] = 1; if (nt2) KT[p] = 1 } }
    }
    END {
        mj = (maxd != "") ? djdn(maxd) : 0
        # trend windows: per-(partner,day) counts summed into last-14 / prior-14
        for (k in DF) { split(k, X, SUBSEP); p = X[1]; dd = djdn(X[2])
            if (mj - dd < 14)      { FL[p] += DF[k]; EL[p] += DE[k] }
            else if (mj - dd < 28) { FP[p] += DF[k]; EP[p] += DE[k] } }
        nsc = 0
        for (z = 1; z <= np; z++) { p = PORD[z]
            errpct = 100 * E[p] / F[p]
            # trend delta in percentage points; needs both windows populated
            delta = 0; hastr = 0
            if (FL[p] + 0 > 0 && FP[p] + 0 > 0) { hastr = 1; delta = 100 * EL[p] / FL[p] - 100 * EP[p] / FP[p] }
            wh = (WN[p] + 0 > 0) ? W[p] / WN[p] / 3600000 : -1    # avg UC2 pickup wait, hours
            wsh = (SN[p] + 0 > 0) ? SW[p] / SN[p] : 0             # weak security leg share
            qd = (L[p] != "") ? mj - djdn(L[p]) : 9999            # days since the last File
            # the six weighted deductions (see the NOTE)
            tp = (hastr && delta > 0) ? 0.5 * delta : 0; if (tp > 15) tp = 15
            wp = (wh > 24) ? 5 : 0
            sp = 5 * wsh
            hp = (NH[p] + 0 == 1) ? 3 : 0
            qp = (qd >= 14) ? 10 : 0
            sc = 100 - errpct - tp - wp - sp - hp - qp
            if (sc < 0) sc = 0; if (sc > 100) sc = 100
            sc = int(sc + 0.5)
            if (hastr && delta > 1)       trend = sprintf("\342\226\262 +%.1f pp", delta)
            else if (hastr && delta < -1) trend = sprintf("\342\226\274 %.1f pp", delta)
            else                          trend = "\342\200\225"
            wait = (wh >= 0) ? sprintf("%.1f h", wh) : "-"
            wpc = (100 * wsh < 1) ? "<1%" : sprintf("%d%%", 100 * wsh + 0.5)
            if (KR[p] && KT[p])   weak = "ssh-rsa + TLSv1.2 (" wpc ")"
            else if (KR[p])       weak = "ssh-rsa (" wpc ")"
            else if (KT[p])       weak = "TLSv1.2 (" wpc ")"
            else                  weak = "-"
            hosts = (NH[p] + 0 > 0) ? NH[p] : ""
            dir = (DI[p] && DO[p]) ? "both" : (DO[p] ? "out" : (DI[p] ? "in" : "-"))   # "both" like the rest of the site (two-way until 2026-09-30)
            if (F[p] >= 100) { nsc++
                printf "%03d\t%s\t%d\t%d\t%.1f%%\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n", \
                    sc, p, sc, F[p], errpct, trend, human(B[p]), wait, weak, hosts, dir, L[p], B[p] > ROWS
            }
        }
        close(ROWS)
        # concentration over ALL seen partners: ranked by Files descending,
        # name ascending on a tie
        for (z = 1; z <= np; z++) IX[z] = PORD[z]
        for (i2 = 2; i2 <= np; i2++) { v = IX[i2]; j2 = i2 - 1
            while (j2 >= 1 && (F[IX[j2]] + 0 < F[v] + 0 || (F[IX[j2]] + 0 == F[v] + 0 && IX[j2] > v))) { IX[j2+1] = IX[j2]; j2-- }
            IX[j2+1] = v }
        for (z = 1; z <= np; z++) { A[z] = F[IX[z]] + 0; RK[IX[z]] = z }
        # the top-N shares are DISTINCT Files touching one of the top N
        # partners over every File with a partner (2026-09-28 fix: the
        # per-partner counts were summed, and the union attribution counts
        # a both-partner File for each of them, so the base and a top-N sum
        # counted such a File twice)
        tot = 0; t1 = 0; t3 = 0; t10 = 0
        for (c in PSET) { tot++; mr = np + 1
            n = split(PSET[c], Z, "\037")
            for (i = 1; i <= n; i++) if ((Z[i] in RK) && RK[Z[i]] < mr) mr = RK[Z[i]]
            if (mr <= 1) t1++; if (mr <= 3) t3++; if (mr <= 10) t10++ }
        # Gini over the ascending sequence
        cum = 0; s2 = 0
        for (z = np; z >= 1; z--) { cum += A[z]; s2 += cum }
        gini = (np > 0 && cum > 0) ? (np + 1 - 2 * s2 / cum) / np : 0
        printf "seen\t%d\nscored\t%d\ntop1\t%.1f\ntop3\t%.1f\ntop10\t%.1f\ngini\t%.3f\ntotfiles\t%d\n", \
            np, nsc, (tot ? 100 * t1 / tot : 0), (tot ? 100 * t3 / tot : 0), (tot ? 100 * t10 / tot : 0), gini, tot > STATS
        close(STATS)
    }
' "$TF" "$TT"

sv() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$TMPD/stats.tsv"; }
n_seen=$(sv seen); n_scored=$(sv scored)
top1=$(sv top1); top3=$(sv top3); top10=$(sv top10); gini=$(sv gini)

{
    printf 'TITLE\tPartner scorecard\n'
    printf 'DESC\tOne composite 0-100 health score per partner with at least 100 Files, built from error rate, 14-day trend, UC2 pickup wait, security posture, endpoint redundancy and recency — every component visible as its own column, worst partner first.\n'
    printf 'STAT\twhite\t%s\tPartners seen\n' "$n_seen"
    printf 'STAT\twhite\t%s\tScored (>= 100 Files)\n' "$n_scored"
    printf 'STAT\torange\t%s%%\tTop-1 share of Files\n' "$top1"
    printf 'STAT\torange\t%s%%\tTop-3 share\n' "$top3"
    printf 'STAT\torange\t%s%%\tTop-10 share\n' "$top10"
    printf 'STAT\tred\t%s\tGini coefficient\n' "$gini"

    printf 'TABLE\tScorecard\twide\tnofilter\n'
    printf 'HEAD\tPartner\tScore\tFiles\tError %%\tTrend (14d)\tVolume\tAvg pickup wait\tWeakest security\tHosts\tDirection\tLast seen\n'
    printf 'KIND\tptn\tnum\tnum\tnum\ttext\tnum\ttext\ttext\tnum\ttext\ttext\n'
    # the ROW tints by the partner RESULT (base/_partners.tsv, like every
    # entity row on the site); the score BAND colours the Score cell only
    # (2026-09-30 audit S-04: the band tinted the whole row, so a red partner
    # read green here)
    LC_ALL=C sort -t$'\t' -k1,1n -k2,2f "$TMPD/score.pre" | awk -F'\t' -v PB="$DATA/flow-manager/base/_partners.tsv" '
        BEGIN { while ((getline l < PB) > 0) { split(l, a, "\t"); if (a[1] != "") R[toupper(a[1])] = a[3] } close(PB) }
        {
        band = ($3 + 0 < 40) ? "failed" : ($3 + 0 < 70) ? "warn" : "processed"
        res = R[toupper($2)]
        printf "ROW\t%s\t@{class=%s}%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n", \
            $2, band, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, (res != "" ? "\t@data:res=" res : "") }'
    awk -F'\t' '{ n++; f += $4; b += $13 }
        END { split("B KB MB GB TB PB", U, " "); i = 1; v = b + 0
            while (v >= 1024 && i < 6) { v /= 1024; i++ }
            h = (i == 1) ? sprintf("%d %s", v, U[i]) : sprintf("%.2f %s", v, U[i])
            printf "TOTAL\tTotal (%d partner(s))\t\t@{class=num}%d\t\t\t@{class=num}%s\t\t\t\t\t\n", n + 0, f + 0, h }' \
        "$TMPD/score.pre"

    printf 'SUMMARY\tPartners seen: %s  |  Scored: %s  |  Top-1 share: %s%%  |  Top-10 share: %s%%  |  Gini: %s\n' \
        "$n_seen" "$n_scored" "$top1" "$top10" "$gini"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_scored scored partner(s) of $n_seen seen)." >&2
