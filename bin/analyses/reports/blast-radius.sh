#!/usr/bin/env bash
#
# blast-radius.sh — "Endpoint blast radius": what dies with each remote host.
# Per OUTBOUND endpoint (the hosts we dial — _files col 15 on out-connection
# Files) the report counts everything routed over it: Files, volume, and the
# distinct subscriptions, applications, domains and partner organisations
# behind it — plus how many partners would lose their ONLY endpoint. Three
# views:
#
#   If this host dies    one row per outbound endpoint, biggest first; a red
#                        row is the sole endpoint of at least one partner
#   Partner redundancy   every seen partner classed by its distinct recorded
#                        endpoints across ALL its Files: single-endpoint,
#                        multi-endpoint, or none recorded (inbound-only —
#                        the partner dials us; a legitimate class, not a gap)
#   Shared endpoints     the endpoints serving MORE than one partner — one
#                        address outage with several organisations behind it
#
# PARTNER = UNION attribution (xref/_subscriptions-partners.tsv on _files
# col 12 unioned with col 20); APPLICATION = the same union via the account
# (xref/_accounts-apps.tsv on col 3 unioned with col 18). Domains are
# single-valued (col 19). Config/analysis page: every table is `nofilter`.
#
# Usage:
#   ./blast-radius.sh   # -> data/<env>/analyses/reports/blast-radius.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/blast-radius.rpt"

TF="$DATA/transfer/cache/_files.tsv"
SPMAP="$DATA/flow-manager/xref/_subscriptions-partners.tsv"
APMAP="$DATA/flow-manager/xref/_accounts-apps.tsv"
if [ ! -f "$TF" ]; then
    echo "blast-radius: transfer cache missing; skipping." >&2
    rm -f "$OUT"
    exit 0
fi
[ -f "$SPMAP" ] || SPMAP=/dev/null
[ -f "$APMAP" ] || APMAP=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TF" "$SPMAP" "$APMAP"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
# pre-create the awk side outputs — an empty estate writes no row, and a
# later sort over a missing file errors (config-only clone)
: > "$TMPD/t1.pre"; : > "$TMPD/t2.pre"; : > "$TMPD/t3.pre"; : > "$TMPD/stats.tsv"
GENDATE=$(date '+%Y-%m-%d %H:%M:%S')

# One pass over the union maps + $FILES. Table 1 aggregates the OUT-connection
# Files per endpoint; the redundancy/sharing views count each partner's
# distinct recorded endpoints over ALL its Files (an inbound partner's
# endpoint is its recorded source address; a partner with none recorded is
# the inbound-only class). END emits sortable row files — every list sorted
# with explicit tiebreakers, nothing depends on hash order.
awk -F'\t' -v T1="$TMPD/t1.pre" -v T2="$TMPD/t2.pre" -v T3="$TMPD/t3.pre" -v STATS="$TMPD/stats.tsv" '
    FILENAME ~ /_subscriptions-partners\.tsv$/ {
        if ($1 != "" && $2 != "") SP[toupper($1)] = SP[toupper($1)] (SP[toupper($1)] == "" ? "" : "\037") $2
        next }
    FILENAME ~ /_accounts-apps\.tsv$/ {
        if ($1 != "" && $2 != "") AP[toupper($1)] = AP[toupper($1)] (AP[toupper($1)] == "" ? "" : "\037") $2
        next }
    {
        pset = $20
        if ($12 != "" && (toupper($12) in SP)) { n = split(SP[toupper($12)], Z, "\037")
            for (i = 1; i <= n; i++) if (index("\037" pset "\037", "\037" Z[i] "\037") == 0)
                pset = pset (pset == "" ? "" : "\037") Z[i] }
        aset = $18
        if ($3 != "" && (toupper($3) in AP)) { n = split(AP[toupper($3)], Z, "\037")
            for (i = 1; i <= n; i++) if (index("\037" aset "\037", "\037" Z[i] "\037") == 0)
                aset = aset (aset == "" ? "" : "\037") Z[i] }
        np = split(pset, P, "\037")
        # the per-partner endpoint census, ANY connection side
        for (j = 1; j <= np; j++) if (P[j] != "") { p = P[j]
            if (PANY[p] == "") { PORD[++npo] = p }        # emptiness, not membership (mawk)
            PANY[p] = 1; PF[p]++
            if ($15 != "" && !((p SUBSEP $15) in PE)) { PE[p SUBSEP $15] = 1; PN[p]++
                PEL[p] = PEL[p] (PEL[p] == "" ? "" : "\037") $15
                if (!(($15 SUBSEP p) in HP)) { HP[$15 SUBSEP p] = 1; HNP[$15]++
                    HPL[$15] = HPL[$15] (HPL[$15] == "" ? "" : "\037") p }
                if (HREG[$15] == "") { HREG[$15] = 1; HORD[++nho] = $15 }   # emptiness, not membership (mawk)
            }
            if ($15 != "") HAF[$15]++                      # Files touching the endpoint, any side
        }
        # table 1: the out-connection aggregation per endpoint
        if ($16 == "out" && $15 != "") { h = $15
            if (OF[h] == "") OORD[++noo] = h
            OF[h]++; OB[h] += $8
            if ($12 != "" && !((h SUBSEP "S" $12) in SEEN)) { SEEN[h SUBSEP "S" $12] = 1; NS[h]++ }
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
        for (z = 1; z <= npo; z++) { p = PORD[z]
            if (PN[p] + 0 == 1) { SOLE[PEL[p]]++ } }
        single = 0; multi = 0; inonly = 0
        for (z = 1; z <= npo; z++) { p = PORD[z]
            c = PN[p] + 0
            k = (c == 0) ? 3 : (c == 1) ? 1 : 2
            if (k == 1) single++; else if (k == 2) multi++; else inonly++
            cls = (k == 1) ? "single endpoint" : (k == 2) ? "multiple endpoints" : "inbound-only"
            printf "%d\t%s\t%s\t%d\t%s\t%d\n", k, p, cls, c, (PEL[p] == "" ? "-" : PEL[p]), PF[p] > T2
        }
        close(T2)
        for (z = 1; z <= noo; z++) { h = OORD[z]
            printf "%09d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\n", \
                999999999 - OF[h], h, OF[h], OB[h], NS[h] + 0, NA[h] + 0, ND[h] + 0, NP2[h] + 0, \
                (OPL[h] == "" ? "-" : OPL[h]), SOLE[h] + 0 > T1
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
' "$SPMAP" "$APMAP" "$TF"

sv() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$TMPD/stats.tsv"; }
n_out=$(sv outhosts); n_single=$(sv single); n_multi=$(sv multi); n_inonly=$(sv inonly)
n_shared=$(sv shared); n_ptn=$(sv ptn)

{
    printf 'TITLE\tEndpoint blast radius\n'
    printf 'DESC\tWhat dies with each remote host: per outbound endpoint the Files, volume, subscriptions, applications, domains and partners routed over it — plus which partners have no second endpoint and which endpoints serve several partners at once.\n'
    printf 'INTRO\tAn endpoint outage is never one flow. The first table answers **"if this host dies, what stops?"** — one row per outbound endpoint we dial, everything behind it counted; a **red** row is the sole recorded endpoint of at least one partner, so there is no second address to fail over to. The redundancy table turns the same census around per partner: **%s** partner(s) ride a single endpoint, **%s** have more than one, and **%s** are inbound-only — they dial us, so no endpoint of theirs can strand us (a legitimate class, not a gap). The last table lists the endpoints shared by several partner organisations: one address, several relationships in the blast radius.\n' \
        "$n_single" "$n_multi" "$n_inonly"
    printf 'STAT\twhite\t%s\tOutbound endpoints\n' "$n_out"
    printf 'STAT\twhite\t%s\tPartners seen\n' "$n_ptn"
    printf 'STAT\tred\t%s\tSingle-endpoint partners\n' "$n_single"
    printf 'STAT\tgreen\t%s\tMulti-endpoint partners\n' "$n_multi"
    printf 'STAT\twhite\t%s\tInbound-only partners\n' "$n_inonly"
    printf 'STAT\torange\t%s\tShared endpoints\n' "$n_shared"

    printf 'TABLE\tIf this host dies\twide\tnofilter\n'
    printf 'HEAD\tHost\tFiles\tVolume\tSubscriptions\tApplications\tDomains\tPartners\tPartner(s)\tSole endpoint for\n'
    printf 'KIND\thost\tnum\tnum\tnum\tnum\tnum\tnum\tclines\ttext\n'
    LC_ALL=C sort -t$'\t' -k1,1 -k2,2f "$TMPD/t1.pre" | awk -F'\t' '
        function human(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
            while (v >= 1024 && i < 6) { v /= 1024; i++ }
            return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
        {
            n++; f += $3; b += $4
            res = ($10 + 0 > 0) ? "\t@data:res=red" : ""
            printf "ROW\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%s\t%s%s\n", \
                $2, $3, human($4), $5, $6, $7, $8, $9, ($10 + 0 > 0 ? $10 " partner(s)" : "-"), res
        }
        END { printf "TOTAL\tTotal (%d host(s))\t@{class=num}%d\t@{class=num}%s\t\t\t\t\t\t\n", n + 0, f + 0, human(b) }'

    printf 'TABLE\tPartner redundancy\twide\tnofilter\trestint\n'
    printf 'HEAD\tPartner\tClass\tEndpoints\tEndpoint(s)\tFiles\n'
    printf 'KIND\tptn\ttext\tnum\tclines\tnum\n'
    LC_ALL=C sort -t$'\t' -k1,1n -k2,2f "$TMPD/t2.pre" | awk -F'\t' '{
            n++; f += $6
            res = ($1 == 1) ? "\t@data:res=orange" : ($1 == 2) ? "\t@data:res=green" : ""
            printf "ROW\t%s\t%s\t%s\t%s\t%d%s\n", $2, $3, ($4 + 0 > 0 ? $4 : ""), $5, $6, res
        }
        END { printf "TOTAL\tTotal (%d partner(s))\t\t\t\t@{class=num}%d\n", n + 0, f + 0 }'

    printf 'TABLE\tShared endpoints\tnofilter\tnosearch\n'
    printf 'HEAD\tHost\tPartners\tPartner(s)\tFiles\n'
    printf 'KIND\thost\tnum\tclines\tnum\n'
    if [ -s "$TMPD/t3.pre" ]; then
        LC_ALL=C sort -t$'\t' -k1,1 -k2,2f "$TMPD/t3.pre" | awk -F'\t' '{
                n++; f += $5
                printf "ROW\t%s\t%d\t%s\t%d\n", $2, $3, $4, $5
            }
            END { printf "TOTAL\tTotal (%d host(s))\t\t\t@{class=num}%d\n", n + 0, f + 0 }'
    else
        printf 'ROW\t@{colspan=4}No endpoint serves more than one partner.\n'
        printf 'TOTAL\tTotal (0 host(s))\t\t\t\n'
    fi

    printf 'NOTE\tThe first table counts OUT-connection Files only (the endpoints we dial); its Subscriptions/Applications/Domains/Partners columns are distinct counts over those Files, applications and partners by the site-wide UNION attribution. The redundancy and sharing views count each partner'\''s distinct recorded endpoints over ALL its Files — for an inbound flow that is the partner'\''s recorded source address, and a partner with no endpoint recorded anywhere is the inbound-only class. "Sole endpoint for" flags the hosts that are the ONLY recorded endpoint of at least one partner: losing that address strands those partners entirely.\n'
    printf 'KEYWORDS\tendpoint,host,blast radius,outage,redundancy,single point of failure,failover,shared endpoint,partner,dependency\n'
    printf 'SUMMARY\tOutbound endpoints: %s  |  Single-endpoint partners: %s  |  Multi-endpoint: %s  |  Inbound-only: %s  |  Shared endpoints: %s\n' \
        "$n_out" "$n_single" "$n_multi" "$n_inonly" "$n_shared"
    printf 'FOOT\tGenerated on %s\n' "$GENDATE"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_out outbound endpoint(s); $n_single/$n_multi/$n_inonly single/multi/inbound-only partner(s); $n_shared shared)." >&2
