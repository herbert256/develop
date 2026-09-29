#!/usr/bin/env bash
#
# app-partners.sh — "Application dependencies": which EXTERNAL partner
# organisations each internal application exchanges Files with, and how well
# each of those (application, partner) pairs works. Two views:
#
#   Applications by external exposure   one row per application: how many
#                                       partners it depends on, its Files,
#                                       the worst pair Error % and how many
#                                       of its pairs run at 100% Error
#   The dependency pairs                one row per (application, partner)
#                                       pair with Files, Error % and last
#                                       seen — the full dependency matrix
#
# APPLICATION = the union attribution via the SUBSCRIPTION (xref/
# _subscriptions-apps.tsv on _files col 12 unioned with col 18); PARTNER =
# the same via xref/_subscriptions-partners.tsv on col 12 unioned with
# col 20 — the site-wide rules (CLAUDE.md). Both ride the FlowID spine:
# subscription -> FlowID -> Logical D_A_P. Until 2026-08-31 the application
# side rode the ACCOUNT (_accounts-apps on col 3): a hybrid production account
# serving many flows credited every File of it to every application the
# account touches and invented dependency pairs.
# Config/analysis page: every table is `nofilter`.
#
# Usage:
#   ./app-partners.sh   # -> data/analyses/reports/app-partners.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/pda-union.sh"   # SP_AWK: the File attribution UNION (sp_union / ap_union)
OUT="$REPORTS_DIR/app-partners.rpt"

TF="$DATA/transfer/cache/_files.tsv"
if [ ! -f "$TF" ]; then
    echo "app-partners: transfer cache missing; skipping." >&2
    rm -f "$OUT"
    exit 0
fi

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
# pre-create the awk side outputs — an empty estate writes no row, and a
# later sort over a missing file errors (config-only clone)
: > "$TMPD/t1.pre"; : > "$TMPD/t2.pre"; : > "$TMPD/stats.tsv"

# One pass: both unions per File, then every (application, partner) pair gets
# Files / Error / last-seen counters. END emits sortable rows for the two
# tables (explicit sort keys — no hash-order output).
awk -F'\t' -v T1="$TMPD/t1.pre" -v T2="$TMPD/t2.pre" -v STATS="$TMPD/stats.tsv" -v SPMAP="$SP_MAP" -v APMAP="$AP_MAP" "$SP_AWK"'
    {
        pset = sp_union($20, $12)   # the partner / application UNION sets (bin/pda-union.sh)
        aset = ap_union($18, $12)
        err = ($2 == "Failed" || $2 == "Expired") ? 1 : 0
        na = split(aset, A, "\037"); np = split(pset, P, "\037")
        for (i = 1; i <= na; i++) if (A[i] != "") for (j = 1; j <= np; j++) if (P[j] != "") {
            k = A[i] SUBSEP P[j]
            if (F[k] == "") { KORD[++nk] = k }            # emptiness, not membership (mawk)
            F[k]++; E[k] += err
            if ($4 != "" && $4 > L[k]) L[k] = $4
        }
    }
    END {
        for (z = 1; z <= nk; z++) { k = KORD[z]; split(k, X, SUBSEP); a = X[1]
            if (AN[a] == "") AORD[++nap] = a
            AN[a]++; AF[a] += F[k]
            ep = 100 * E[k] / F[k]
            if (ep > AW[a] + 0) AW[a] = ep
            if (E[k] == F[k]) AB[a]++
            printf "%s\t%09d\t%s\t%d\t%.1f\t%s\n", a, 999999999 - F[k], X[2], F[k], ep, L[k] > T2
        }
        close(T2)
        tot100 = 0
        for (z = 1; z <= nap; z++) { a = AORD[z]; tot100 += AB[a] + 0
            printf "%03d\t%s\t%d\t%d\t%.1f\t%d\n", 999 - AN[a], a, AN[a], AF[a], AW[a] + 0, AB[a] + 0 > T1 }
        close(T1)
        printf "apps\t%d\npairs\t%d\nfull\t%d\n", nap, nk, tot100 > STATS
        close(STATS)
    }
' "$TF"

sv() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$TMPD/stats.tsv"; }
n_apps=$(sv apps); n_pairs=$(sv pairs); n_full=$(sv full)

# the most exposed application, for the intro
IFS=$'\t' read -r x_app x_ptn x_full <<EOF
$(LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2f "$TMPD/t1.pre" | awk -F'\t' -v OFS='\t' 'NR == 1 { print $2, $3, $6 }')
EOF

{
    printf 'TITLE\tApplication dependencies\n'
    printf 'DESC\tWhich external partner organisations each internal application exchanges Files with: partner count, Files and worst-pair Error %% per application, plus the full (application, partner) dependency matrix.\n'
    printf 'STAT\twhite\t%s\tApplications seen\n' "$n_apps"
    printf 'STAT\twhite\t%s\tDependency pairs\n' "$n_pairs"
    printf 'STAT\tred\t%s\tPairs at 100%% Error\n' "$n_full"

    printf 'TABLE\tApplications by external exposure\tnofilter\n'
    printf 'HEAD\tApplication\tPartners\tFiles\tWorst pair Error %%\tPairs at 100%% Error\n'
    printf 'KIND\tapp\tnum\tnum\tnum\tnum\n'
    LC_ALL=C sort -t$'\t' -k1,1 -k2,2f "$TMPD/t1.pre" | awk -F'\t' '{
            n++; p += $3; f += $4; b += $6
            res = ($6 + 0 > 0) ? "\t@data:res=red" : ""
            printf "ROW\t%s\t%d\t%d\t%s\t%s%s\n", $2, $3, $4, $5, ($6 + 0 > 0 ? $6 : ""), res
        }
        END { printf "TOTAL\tTotal (%d application(s))\t@{class=num}%d\t@{class=num}%d\t\t@{class=num}%d\n", n + 0, p + 0, f + 0, b + 0 }'

    printf 'TABLE\tThe dependency pairs\tnofilter\tpager=50\n'
    printf 'HEAD\tApplication\tPartner\tFiles\tError %%\tLast seen\n'
    printf 'KIND\tapp\tptn\tnum\tnum\ttext\n'
    LC_ALL=C sort -t$'\t' -k1,1f -k2,2 -k3,3f "$TMPD/t2.pre" | awk -F'\t' '{
            n++; f += $4
            res = ($5 + 0 >= 100) ? "\t@data:res=red" : ""
            printf "ROW\t%s\t%s\t%d\t%s\t%s%s\n", $1, $3, $4, $5, ($6 != "" ? $6 : "-"), res
        }
        END { printf "TOTAL\tTotal (%d pair(s))\t\t@{class=num}%d\t\t\n", n + 0, f + 0 }'

    printf 'SUMMARY\tApplications: %s  |  Dependency pairs: %s  |  Pairs at 100%% Error: %s\n' \
        "$n_apps" "$n_pairs" "$n_full"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_apps application(s), $n_pairs pair(s), $n_full at 100% error)." >&2
