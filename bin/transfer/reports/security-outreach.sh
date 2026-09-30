#!/usr/bin/env bash
#
# security-outreach.sh — "Security outreach": the partner call list for
# DEPRECATED connection-security parameters. security-params.sh shows every
# value in use; this report turns the two deprecated ones into action:
#   Public Key: ssh-rsa   RSA keys still signing with SHA-1 (the ssh-rsa
#                         signature algorithm) — disabled by default in
#                         modern OpenSSH; partners must move to rsa-sha2-*.
#   Protocol:   TLSv1.2   the legacy TLS version; TLSv1.3 is current.
# Three views, all full period (`nofilter`):
#   Deprecation outreach list   one row per (partner, deprecated parameter)
#                               still in use — seen in the LAST 7 DAYS of the
#                               window — with legs and first/last sighting.
#   Upgrades in the window      per (partner, old -> new value): the clean
#                               cutover date, or "mixed fleet" when the old
#                               value kept appearing after the new one started.
#   Deprecated-parameter timeline   per deprecated value: partners still on
#                               it, total legs, newest sighting.
#
# Reuses security-params.sh's SecurityParameters parsing idiom (the marker
# gsub over col 19) and the site-wide PARTNER UNION attribution: a leg counts
# for every configured partner of its subscription (xref/_subscriptions-
# partners.tsv) PLUS the host-resolved partner of its CoreId (_files.tsv
# col 20), deduped.
#
# The lines come from security-params.sh's pass over $PARSED (1=coreid,
# 6=site, 11=date_iso, 14=jdn, 19=secparams) + $FILES (1=coreid, 20=partner) +
# xref/_subscriptions-partners.tsv.
# Writes data/transfer/reports/security-outreach.rpt.
#
# Usage (by security-params.sh):
#   ./security-outreach.sh <outreach-lines-file>   # writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/security-outreach.rpt"

# (2026-09-30, the lean round) This script is the WRITER only:
# bin/transfer/reports/security-params.sh computes the outreach lines in its
# one pass over _files + _transfers (the same attribute split both reports
# read) and calls this script with the file holding them — pipe-separated:
#   D1|legs|partner|param|first|last              still using (last 7 days)
#   D2|partner|param_old|new_val|oldlast|newfirst|cut   cut = date | mixed
#   D3|param|nstill|npartners|legs|newest         one per deprecated value
#   T|maxdate|cutoffdate
[ -n "${1:-}" ] && [ -f "$1" ] || { echo "security-outreach.sh: run by security-params.sh (the outreach lines file as \$1)" >&2; exit 2; }
agg=$(cat "$1")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 1
fi

IFS='|' read -r _ last_date _cutoff <<< "$(printf '%s\n' "$agg" | grep '^T|')"

n_d1=0; d1_legs=0
n_d2=0; n_mixed=0
n_d3=0; d3_legs=0; d3_still=0

{
    printf 'TITLE\tSecurity outreach\n'
    printf 'DESC\tThe partner call list for deprecated connection-security parameters: who still connects with ssh-rsa (SHA-1) keys or TLSv1.2, who already upgraded, and who runs a mixed fleet.\n'

    printf 'TABLE\tDeprecation outreach list\twide\tnofilter\n'
    printf 'HEAD\tPartner\tDeprecated parameter\tTransfers\tFirst seen\tLast seen\n'
    printf 'KIND\tptn\ttext\tnum\ttext\ttext\n'
    # D1 fields: 2=legs 3=partner 4=param 5=first 6=last
    while IFS='|' read -r _ legs ptn param first last; do
        [ -z "$ptn" ] && continue
        n_d1=$((n_d1 + 1)); d1_legs=$((d1_legs + legs))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\n' "$ptn" "$param" "$legs" "$first" "$last"
    done <<< "$(printf '%s\n' "$agg" | grep '^D1|' | LC_ALL=C sort -t'|' -k2,2nr -k3,3 -k4,4)"
    if [ "$n_d1" -eq 0 ]; then
        printf 'ROW\t@{colspan=5}No partner used a deprecated parameter in the last 7 days of the window.\n'
    fi
    printf 'TOTAL\tTotal (%s rows)\t\t@{class=num}%s\t\t\n' "$n_d1" "$d1_legs"

    printf 'TABLE\tUpgrades in the window\twide\tnofilter\n'
    printf 'HEAD\tPartner\tDeprecated parameter\tUpgraded to\tOld last seen\tNew first seen\tCutover\n'
    printf 'KIND\tptn\ttext\ttext\ttext\ttext\ttext\n'
    # D2 fields: 2=partner 3=param_old 4=new 5=oldlast 6=newfirst 7=cut
    while IFS='|' read -r _ ptn param newv oldlast newfirst cut; do
        [ -z "$ptn" ] && continue
        n_d2=$((n_d2 + 1))
        if [ "$cut" = "mixed" ]; then
            n_mixed=$((n_mixed + 1))
            printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@{class=failed}mixed fleet\n' "$ptn" "$param" "$newv" "$oldlast" "$newfirst"
        else
            printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@{class=processed}%s\n' "$ptn" "$param" "$newv" "$oldlast" "$newfirst" "$cut"
        fi
    done <<< "$(printf '%s\n' "$agg" | grep '^D2|' | LC_ALL=C sort -t'|' -k2,2 -k3,3 -k4,4)"
    if [ "$n_d2" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}No partner used both a deprecated value and a modern one of the same parameter in this window.\n'
    fi
    printf 'TOTAL\tTotal (%s upgrade pairs, %s mixed)\t\t\t\t\t\n' "$n_d2" "$n_mixed"

    printf 'TABLE\tDeprecated-parameter timeline\tnofilter\tnosearch\n'
    printf 'HEAD\tDeprecated parameter\tPartners still on it\tPartners in window\tTransfers\tNewest seen\n'
    printf 'KIND\ttext\tnumwarn\tnum\tnum\ttext\n'
    # D3 fields: 2=param 3=nstill 4=npartners 5=legs 6=newest
    while IFS='|' read -r _ param nstill nptn legs newest; do
        [ -z "$param" ] && continue
        n_d3=$((n_d3 + 1)); d3_legs=$((d3_legs + legs)); d3_still=$((d3_still + nstill))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\n' "$param" "$nstill" "$nptn" "$legs" "$newest"
    done <<< "$(printf '%s\n' "$agg" | grep '^D3|')"
    printf 'TOTAL\tTotal (%s parameters)\t@{class=num warn}%s\t\t@{class=num}%s\t\n' "$n_d3" "$d3_still" "$d3_legs"

    printf 'SUMMARY\tStill using a deprecated parameter: %s partner/parameter pair(s), %s transfer(s)  |  Upgrade pairs seen: %s (%s mixed fleet)  |  Deprecated transfers in window: %s  |  Dataset end: %s\n' \
        "$n_d1" "$d1_legs" "$n_d2" "$n_mixed" "$d3_legs" "$last_date"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_d1 outreach row(s), $n_d2 upgrade pair(s), $n_mixed mixed)." >&2
