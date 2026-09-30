#!/usr/bin/env bash
#
# blast-radius.sh — "Endpoint blast radius": what dies with each remote host.
# Per OUTBOUND endpoint (the hosts we dial — _files col 15 on out-connection
# Files) the report counts everything routed over it: Files, volume, and the
# distinct subscriptions, applications, domains and partner organisations
# behind it — plus which partners would lose their ONLY endpoint. Two
# views:
#
#   If this host dies    one row per outbound endpoint, biggest first; a red
#                        row is the sole endpoint of at least one partner,
#                        named in its "Sole endpoint for" cell
#   Shared endpoints     the endpoints serving MORE than one partner — one
#                        address outage with several organisations behind it
#
# Every seen partner is still CLASSED by its distinct recorded endpoints over
# its OUT-connection Files — single-endpoint, multi-endpoint, or none recorded
# (inbound-only: the partner dials us; a legitimate class, not a gap) — for
# the STAT boxes. (The one-row-per-partner "Partner redundancy" table went
# 2026-09-29: its single-endpoint rows are the Sole endpoint for names, its
# endpoint lists the Entities Partners detail pages.)
#
# PARTNER = UNION attribution (xref/_subscriptions-partners.tsv on _files
# col 12 unioned with col 20); APPLICATION = the same union via the
# SUBSCRIPTION (xref/_subscriptions-apps.tsv on col 12 unioned with col 18 —
# until 2026-08-31 it rode the ACCOUNT, and a hybrid production account
# serving many flows inflated the Applications column of every endpoint it
# uses). Domains are single-valued (col 19). Config/analysis page: every
# table is `nofilter`.
#
# Usage:
#   ./blast-radius.sh   # -> data/analyses/reports/blast-radius.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/pda-union.sh"   # SP_AWK: the File attribution UNION (sp_union / ap_union)
OUT="$REPORTS_DIR/blast-radius.rpt"

TF="$DATA/transfer/cache/_files.tsv"
if [ ! -f "$TF" ]; then
    echo "blast-radius: transfer cache missing; skipping." >&2
    rm -f "$OUT"
    exit 0
fi

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
# pre-create the awk side outputs — an empty estate writes no row, and a
# later sort over a missing file errors (config-only clone)
: > "$TMPD/t1.pre"; : > "$TMPD/t3.pre"; : > "$TMPD/stats.tsv"

# One pass over the union maps + $FILES. Table 1 aggregates the OUT-connection
# Files per endpoint; the redundancy/sharing views count each partner's
# distinct recorded endpoints over ALL its Files (an inbound partner's
# endpoint is its recorded source address; a partner with none recorded is
# the inbound-only class). END emits sortable row files — every list sorted
# with explicit tiebreakers, nothing depends on hash order.
awk -F'\t' -v T1="$TMPD/t1.pre" -v T3="$TMPD/t3.pre" -v STATS="$TMPD/stats.tsv" -v SPMAP="$SP_MAP" -v APMAP="$AP_MAP" "$SP_AWK"'
    # a \037 list sorted ascending (insertion sort: a handful of names)
    function sortl(s,   n, X, i, j, t, r) { if (s == "") return ""
        n = split(s, X, "\037")
        for (i = 2; i <= n; i++) { t = X[i]; for (j = i - 1; j >= 1 && X[j] > t; j--) X[j + 1] = X[j]; X[j + 1] = t }
        r = X[1]; for (i = 2; i <= n; i++) r = r "\037" X[i]; return r }
    {
        pset = sp_union($20, $12)   # the partner / application UNION sets (bin/pda-union.sh)
        aset = ap_union($18, $12)
        np = split(pset, P, "\037")
        # the per-partner endpoint census: every File counts for the partner,
        # but only an OUT-connection File names an endpoint WE DIAL (2026-09-28
        # fix: an in-connection File carries the partner SOURCE address in col
        # 15, which made every inbound partner a single/multi-endpoint one and
        # left the inbound-only class empty)
        oh = ($16 == "out") ? $15 : ""
        for (j = 1; j <= np; j++) if (P[j] != "") { p = P[j]
            if (PANY[p] == "") { PORD[++npo] = p }        # emptiness, not membership (mawk)
            PANY[p] = 1
            if (oh != "" && !((p SUBSEP oh) in PE)) { PE[p SUBSEP oh] = 1; PN[p]++
                PEL[p] = PEL[p] (PEL[p] == "" ? "" : "\037") oh
                if (!((oh SUBSEP p) in HP)) { HP[oh SUBSEP p] = 1; HNP[oh]++
                    HPL[oh] = HPL[oh] (HPL[oh] == "" ? "" : "\037") p }
                if (HREG[oh] == "") { HREG[oh] = 1; HORD[++nho] = oh }   # emptiness, not membership (mawk)
            }
        }
        if (oh != "" && np > 0) HAF[oh]++                  # Files over the endpoint, each ONCE
        # table 1: the out-connection aggregation per endpoint
        if ($16 == "out" && $15 != "") { h = $15
            if (OF[h] == "") OORD[++noo] = h
            OF[h]++; OB[h] += $8
            if ($12 != "" && $12 != "Unknown" && !((h SUBSEP "S" $12) in SEEN)) { SEEN[h SUBSEP "S" $12] = 1; NS[h]++ }
            if ($19 != "" && !((h SUBSEP "D" $19) in SEEN)) { SEEN[h SUBSEP "D" $19] = 1; ND[h]++ }
            na = split(aset, A, "\037")
            for (i = 1; i <= na; i++) if (A[i] != "" && !((h SUBSEP "A" A[i]) in SEEN)) { SEEN[h SUBSEP "A" A[i]] = 1; NA[h]++ }
            for (j = 1; j <= np; j++) if (P[j] != "" && !((h SUBSEP "P" P[j]) in SEEN)) { SEEN[h SUBSEP "P" P[j]] = 1; NP2[h]++
                OPL[h] = OPL[h] (OPL[h] == "" ? "" : "\037") P[j] }
        }
    }
    END {
        # sole-endpoint partners per host: a partner with exactly ONE recorded
        # endpoint pins that endpoint
        # (PORD is first-seen order; the names are sorted per cell below)
        for (z = 1; z <= npo; z++) { p = PORD[z]
            if (PN[p] + 0 == 1) { SOLE[PEL[p]]++
                SOLEL[PEL[p]] = SOLEL[PEL[p]] (SOLEL[PEL[p]] == "" ? "" : "\037") p } }
        single = 0; multi = 0; inonly = 0
        for (z = 1; z <= npo; z++) { p = PORD[z]
            c = PN[p] + 0
            if (c == 1) single++; else if (c > 1) multi++; else inonly++
        }
        for (z = 1; z <= noo; z++) { h = OORD[z]
            printf "%09d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%s\n", \
                999999999 - OF[h], h, OF[h], OB[h], NS[h] + 0, NA[h] + 0, ND[h] + 0, NP2[h] + 0, \
                (OPL[h] == "" ? "-" : OPL[h]), SOLE[h] + 0, sortl(SOLEL[h]) > T1
        }
        close(T1)
        nsh = 0
        for (z = 1; z <= nho; z++) { h = HORD[z]
            if (HNP[h] + 0 > 1) { nsh++
                printf "%03d\t%s\t%d\t%s\t%d\n", 999 - HNP[h], h, HNP[h], HPL[h], HAF[h] + 0 > T3 } }
        close(T3)
        printf "outhosts\t%d\nsingle\t%d\nmulti\t%d\ninonly\t%d\nshared\t%d\nptn\t%d\n", \
            noo, single, multi, inonly, nsh, npo > STATS
        close(STATS)
    }
' "$TF"

sv() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$TMPD/stats.tsv"; }
n_out=$(sv outhosts); n_single=$(sv single); n_multi=$(sv multi); n_inonly=$(sv inonly)
n_shared=$(sv shared); n_ptn=$(sv ptn)

{
    printf 'TITLE\tBlast radius\n'   # = its Reports menu label (2026-09-29)
    printf 'DESC\tWhat dies with each remote host: per outbound endpoint the Files, volume, subscriptions, applications, domains and partners routed over it — plus which partners have no second endpoint and which endpoints serve several partners at once.\n'
    printf 'STAT\twhite\t%s\tOutbound endpoints\n' "$n_out"
    printf 'STAT\twhite\t%s\tPartners seen\n' "$n_ptn"
    printf 'STAT\tred\t%s\tSingle-endpoint partners\n' "$n_single"
    printf 'STAT\tgreen\t%s\tMulti-endpoint partners\n' "$n_multi"
    printf 'STAT\twhite\t%s\tInbound-only partners\n' "$n_inonly"
    printf 'STAT\torange\t%s\tShared endpoints\n' "$n_shared"

    printf 'TABLE\tIf this host dies\twide\tnofilter\n'
    printf 'HEAD\tHost\tFiles\tVolume\tSubscriptions\tApplications\tDomains\tPartners\tPartner(s)\tSole endpoint for\n'
    # (2026-09-30 audit S-04 / S-07: the ROW tints by the HOST result —
    # base/_hosts.tsv, like every entity row — and the sole-endpoint risk
    # colours its own cell; the partner lists link every name, @{alist=})
    printf 'KIND\thost\tnum\tnum\tnum\tnum\tnum\tnum\ttext\ttext\n'
    LC_ALL=C sort -t$'\t' -k1,1 -k2,2f "$TMPD/t1.pre" | awk -F'\t' -v HB="$DATA/flow-manager/base/_hosts.tsv" "$AWKLIB"'
        function plist(l) { gsub("\037", ", ", l); return l }
        BEGIN { while ((getline l < HB) > 0) { split(l, a, "\t"); if (a[1] != "") R[toupper(a[1])] = a[3] } close(HB) }
        {
            n++; f += $3; b += $4
            res = R[toupper($2)]
            printf "ROW\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%s\t%s%s\n", \
                $2, $3, hbytes2($4), $5, $6, $7, $8, ($9 == "-" ? "-" : "@{alist=partners}" plist($9)), \
                ($10 + 0 > 0 ? "@{alist=partners,class=failed}" plist($11) : "-"), (res != "" ? "\t@data:res=" res : "")
        }
        END { printf "TOTAL\tTotal (%d host(s))\t@{class=num}%d\t@{class=num}%s\t\t\t\t\t\t\n", n + 0, f + 0, hbytes2(b) }'

    printf 'TABLE\tShared endpoints\tnofilter\tnosearch\n'
    printf 'HEAD\tHost\tPartners\tPartner(s)\tFiles\n'
    printf 'KIND\thost\tnum\ttext\tnum\n'
    if [ -s "$TMPD/t3.pre" ]; then
        LC_ALL=C sort -t$'\t' -k1,1 -k2,2f "$TMPD/t3.pre" | awk -F'\t' -v HB="$DATA/flow-manager/base/_hosts.tsv" '
            function plist(l) { gsub("\037", ", ", l); return l }
            BEGIN { while ((getline l < HB) > 0) { split(l, a, "\t"); if (a[1] != "") R[toupper(a[1])] = a[3] } close(HB) }
            {
                n++; f += $5
                res = R[toupper($2)]
                printf "ROW\t%s\t%d\t%s\t%d%s\n", $2, $3, "@{alist=partners}" plist($4), $5, (res != "" ? "\t@data:res=" res : "")
            }
            END { printf "TOTAL\tTotal (%d host(s))\t\t\t@{class=num}%d\n", n + 0, f + 0 }'
    else
        printf 'ROW\t@{colspan=4}No endpoint serves more than one partner.\n'
        printf 'TOTAL\tTotal (0 host(s))\t\t\t\n'
    fi

    printf 'SUMMARY\tOutbound endpoints: %s  |  Single-endpoint partners: %s  |  Multi-endpoint: %s  |  Inbound-only: %s  |  Shared endpoints: %s\n' \
        "$n_out" "$n_single" "$n_multi" "$n_inonly" "$n_shared"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_out outbound endpoint(s); $n_single/$n_multi/$n_inonly single/multi/inbound-only partner(s); $n_shared shared)." >&2
