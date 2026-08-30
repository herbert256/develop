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
# Reads $PARSED (1=coreid, 6=site, 11=date_iso, 14=jdn, 19=secparams) +
# $FILES (1=coreid, 20=partner) + xref/_subscriptions-partners.tsv.
# Writes data/transfer/reports/security-outreach.rpt.
#
# Usage:
#   ./security-outreach.sh   # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/security-outreach.rpt"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
SPX="$CONFIG_XREF/_subscriptions-partners.tsv"   # subscription -> partner (UNION attribution)
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$SPX"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass: file 1 = $FILES (the host-resolved partner per CoreId), file 2 =
# $PARSED. Only the two attributes that carry a deprecated value are tracked
# ("Public Key" and "Protocol") — table 2 needs their NON-deprecated values
# too, for the old -> new pairs. Emits pipe-separated:
#   D1|legs|partner|param|first|last              still using (last 7 days)
#   D2|partner|param_old|new_val|oldlast|newfirst|cut   cut = date | mixed
#   D3|param|nstill|npartners|legs|newest         one per deprecated value
#   T|maxdate|cutoffdate
agg=$(awk -F'\t' -v spx="$SPX" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function label(a) { return (a == "Protocol") ? "TLS version" : a }
    BEGIN {
        dep["Public Key" SUBSEP "ssh-rsa"] = 1
        dep["Protocol" SUBSEP "TLSv1.2"]   = 1
        want["Public Key"] = 1; want["Protocol"] = 1
        while ((getline _l < spx) > 0) { split(_l, _a, "\t")
            if (_a[1] != "" && _a[2] != "") sp[_a[1]] = (sp[_a[1]] == "" ? _a[2] : sp[_a[1]] SUBSEP _a[2]) }
        close(spx)
    }
    # file 1 = $FILES: the per-CoreId host-resolved partner (col 20) — the
    # OTHER half of the site-wide PARTNER UNION
    FNR == NR { if ($20 != "") { hpv = $20; gsub(/[|\t]/, " ", hpv); hp[$1] = hpv } next }
    { if ($14 + 0 > maxj) { maxj = $14 + 0; maxdate = $11 } }
    {
        s = $19
        if (s == "" || s == "UNKNOWN") next
        if ($11 == "") next
        # the partner UNION for this leg: the subscription configured partners
        # plus the CoreId host-resolved one, deduped
        pl = ($6 in sp) ? sp[$6] : ""
        h = ($1 in hp) ? hp[$1] : ""
        if (h != "") { inp = 0; np = split(pl, pa, SUBSEP)
            for (j = 1; j <= np; j++) if (pa[j] == h) { inp = 1; break }
            if (!inp) pl = (pl == "" ? h : pl SUBSEP h) }
        if (pl == "") pl = "(none)"
        np = split(pl, pa, SUBSEP)
        # the security-params.sh parsing idiom: insert a marker before each
        # known attribute key so both the ssh format ("Cipher: x, MAC: y, ...")
        # and the TLS format ("Protocol: TLSv1.3 Cipher suite: z") split into
        # Key/Value chunks.
        gsub(/\.$/, "", s)
        gsub(/(Cipher suite|Public Key|Key Exchange|Cipher|MAC|Protocol): /, SUBSEP "&", s)
        m = split(s, pairs, SUBSEP)
        for (pi = 1; pi <= m; pi++) {
            seg = trim(pairs[pi]); gsub(/,$/, "", seg)
            ci = index(seg, ": ")
            if (ci <= 0) continue
            key = trim(substr(seg, 1, ci - 1))
            val = trim(substr(seg, ci + 2)); gsub(/,$/, "", val)
            gsub(/[|\t]/, " ", key); gsub(/[|\t]/, " ", val)
            if (key == "" || val == "") continue
            if (!(key in want)) continue
            for (j = 1; j <= np; j++) { pt = pa[j]
                k = pt SUBSEP key SUBSEP val
                if (C[k] == "") {                              # EMPTINESS, not membership (mawk LHS trap)
                    pak = pt SUBSEP key
                    if (PAV[pak] == "") PAL[++npa] = pak
                    PAV[pak] = (PAV[pak] == "" ? val : PAV[pak] SUBSEP val)
                    FD[k] = $11; LD[k] = $11; LJ[k] = $14 + 0
                }
                C[k]++
                if ($11 < FD[k]) FD[k] = $11
                if ($11 > LD[k]) { LD[k] = $11; LJ[k] = $14 + 0 }
            }
        }
    }
    END {
        cutoff = maxj - 6                                     # "still using" = seen in the last 7 days
        for (i = 1; i <= npa; i++) {
            split(PAL[i], q, SUBSEP); pt = q[1]; a = q[2]
            nv = split(PAV[PAL[i]], vs, SUBSEP)
            for (vi = 1; vi <= nv; vi++) {
                v = vs[vi]
                if (!((a SUBSEP v) in dep)) continue
                k = pt SUBSEP a SUBSEP v
                dk = a SUBSEP v
                d3n[dk]++; d3l[dk] += C[k]
                if (LD[k] > d3d[dk]) d3d[dk] = LD[k]
                if (LJ[k] >= cutoff) { d3s[dk]++
                    printf "D1|%d|%s|%s: %s|%s|%s\n", C[k], pt, label(a), v, FD[k], LD[k] }
                # the old -> new pairs: every OTHER value of the same attribute
                for (wi = 1; wi <= nv; wi++) {
                    if (wi == vi) continue
                    w = vs[wi]
                    if ((a SUBSEP w) in dep) continue
                    k2 = pt SUBSEP a SUBSEP w
                    cut = (FD[k2] >= LD[k]) ? FD[k2] : "mixed"
                    printf "D2|%s|%s: %s|%s|%s|%s|%s\n", pt, label(a), v, w, LD[k], FD[k2], cut
                }
            }
        }
        n3 = split("Public Key" SUBSEP "ssh-rsa" SUBSEP "Protocol" SUBSEP "TLSv1.2", t3, SUBSEP)
        for (i = 1; i <= n3; i += 2) { dk = t3[i] SUBSEP t3[i+1]
            printf "D3|%s: %s|%d|%d|%d|%s\n", label(t3[i]), t3[i+1], d3s[dk]+0, d3n[dk]+0, d3l[dk]+0, (d3d[dk] == "" ? "-" : d3d[dk]) }
        printf "T|%s|%s\n", maxdate, (cutoff > 0 ? "last 7 days" : "-")
    }
' "$FILES" "$PARSED")

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
    printf 'KEYWORDS\tssh-rsa, sha-1, sha1, tlsv1.2, tls 1.2, deprecated, legacy, weak, outreach, call list, upgrade, cutover, mixed fleet, rsa-sha2, migration, host key, public key\n'
    printf 'INTRO\tTwo SecurityParameters values in this data are DEPRECATED: **Public Key ssh-rsa** (an RSA key still signing with SHA-1 — modern OpenSSH disables it by default) and **Protocol TLSv1.2** (the legacy TLS version). This is the OUTREACH view of the Security parameters report: which partner still connects with a deprecated value, who already cut over to a modern one, and who runs a mixed fleet. "Still using" means seen in the **last 7 days** of the window (dataset end: %s).\n' "$last_date"

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
    printf 'NOTE\tOne row per (partner, deprecated parameter) seen in the **last 7 days** — the partners to contact about an upgrade. Transfers counts every leg in the window negotiated with that value, so the busiest offenders sort to the top. A partner that stopped using the value earlier in the window (a completed cutover) is NOT listed here — the Upgrades table below carries it.\n'

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
    printf 'NOTE\tEvery partner that used a deprecated value AND a modern value of the same parameter in the window. A **clean cutover** shows its date — the modern value'\''s first sighting, on or after the deprecated value'\''s last (same-day switches count as clean). **Mixed fleet** means the deprecated value kept appearing after the modern one started — typically several client systems or keys on the partner side, only some of them upgraded; those partners also stay on the outreach list above while the old value keeps showing up.\n'

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
    printf 'NOTE\tWhy these two count as deprecated: **ssh-rsa** is the SSH signature algorithm that pairs an RSA key with **SHA-1** — broken enough that OpenSSH disables it by default since 8.8; the same RSA key works fine with the rsa-sha2-256/-512 algorithms, so this is a partner-side software/config upgrade, not a new key. **TLSv1.2** is the legacy TLS version; TLSv1.3 is current. Reading the Public Key rows: an OUTBOUND leg (we connect out) shows the REMOTE SERVER'\''s host key — the partner must upgrade their server — while an INBOUND leg shows the connecting CLIENT'\''s authentication key, so the fix sits in the partner'\''s client software. Partners use the site-wide UNION attribution (a leg counts for every partner of its subscription plus the host-resolved one).\n'

    printf 'SUMMARY\tStill using a deprecated parameter: %s partner/parameter pair(s), %s transfer(s)  |  Upgrade pairs seen: %s (%s mixed fleet)  |  Deprecated transfers in window: %s  |  Dataset end: %s\n' \
        "$n_d1" "$d1_legs" "$n_d2" "$n_mixed" "$d3_legs" "$last_date"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_d1 outreach row(s), $n_d2 upgrade pair(s), $n_mixed mixed)." >&2
