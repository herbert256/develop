#!/usr/bin/env bash
#
# connection-efficiency.sh — how well the TECHNICAL CONNECTIONS are used, from
# the Session ID column of data/_transfers.tsv (col 24, added 2026-08). A
# session is one technical connection (an SFTP login, a PeSIT session); it can
# carry many Files or just one. Three views:
#   1. Files per connection, per account — User-initiated sessions only (the
#      partner chose to reconnect per file or batch), accounts with >= 200
#      sessions, least efficient first; the TOTAL row shows the whole platform.
#   2. Connection storms — the peak number of sessions STARTED in one minute,
#      per account.
#   3. Session failure anatomy — all-Error multi-leg sessions, mixed OK+Error
#      sessions, and retry marathons (8+ legs, one File, all Error).
#
# A session is attributed to its FIRST leg's account (earliest sortkey);
# records with no usable session id (blank or UNKNOWN) are excluded.
#
# Reads data/_transfers.tsv (1 = coreid, 3 = status, 4 = account, 7 = action_by,
# 11 = date, 12 = time, 13 = sortkey, 24 = session_id). Writes
# data/connection-efficiency.rpt.
#
# Usage:
#   ./connection-efficiency.sh    # reads input/*.csv (via the cache), writes the .rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/connection-efficiency.rpt"
MIN_SESS=200    # sessions an account needs to enter the efficiency league
TOP_N=20        # rows in the storms and failure-anatomy tables
MARATHON=8      # legs at/above this, one File, all Error = a retry marathon

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass building the per-session facts (first leg, leg count, distinct
# Files, OK/Error split), then END rolls them up per account.
agg=$(awk -F'\t' -v minsess="$MIN_SESS" -v marathon="$MARATHON" '
    $24 == "" || $24 == "UNKNOWN" { unk++; next }
    {
        s = $24
        if (!(s in legs)) legs[s] = 0                       # register the session
        if (bsk[s] == "" || $13 < bsk[s]) {                 # earliest leg wins (input order breaks exact ties)
            bsk[s] = $13; bact[s] = $4; binit[s] = $7
            bmin[s] = ($11 == "") ? "(no date)" : $11 " " substr($12, 1, 5)
        }
        legs[s]++
        if (!((s SUBSEP $1) in fseen)) { fseen[s SUBSEP $1] = 1; nf[s]++ }
        if ($3 == "Processed") okc[s]++; else erc[s]++
    }
    END {
        for (s in legs) {
            a = bact[s]; if (a == "") a = "(no account)"
            alls++; allf += nf[s]; if (nf[s] == 1) allsf++
            sa[a]++
            st[a SUBSEP bmin[s]]++
            if (binit[s] == "User") {
                usess++
                us[a]++; uf[a] += nf[s]; if (nf[s] == 1) usf[a]++
            }
            if (legs[s] >= 2 && okc[s] + 0 == 0) af[a]++
            if (okc[s] + 0 > 0 && erc[s] + 0 > 0) mx[a]++
            if (legs[s] >= marathon && nf[s] == 1 && okc[s] + 0 == 0) rm[a]++
        }
        if (alls == 0) { print "EMPTY"; exit }
        for (a in us) {
            if (us[a] < minsess) continue
            printf "L\t%012.6f\t%s\t%d\t%d\t%.2f\t%.1f%%\n", \
                uf[a] / us[a], a, us[a], uf[a], uf[a] / us[a], usf[a] * 100 / us[a]
        }
        # peak session-starts per minute per account (earliest minute wins a tie)
        for (k in st) {
            split(k, q, SUBSEP); a = q[1]; mnt = q[2]; c = st[k]
            if (c > pk[a] || (c == pk[a] && mnt < pkm[a])) { pk[a] = c; pkm[a] = mnt }
        }
        for (a in pk)
            printf "S\t%s\t%d\t%s\t%d\n", a, pk[a], pkm[a], sa[a]
        for (a in sa) {
            fa = af[a] + 0; ma = mx[a] + 0; ra = rm[a] + 0
            if (fa + ma + ra > 0) { printf "F\t%s\t%d\t%d\t%d\n", a, fa, ma, ra
                tfa += fa; tma += ma; tra += ra; nfa++ }
        }
        printf "PL\t%d\t%d\t%.2f\t%.1f\t%d\t%d\t%d\t%d\t%d\t%d\n", \
            alls, allf, allf / alls, allsf * 100 / alls, usess+0, unk+0, tfa+0, tma+0, tra+0, nfa+0
    }
' "$PARSED")

if [ "$(printf '%s\n' "$agg" | awk 'NR==1 { print $1 }')" = "EMPTY" ]; then
    {
        printf 'TITLE\tConnection efficiency\n'
        printf 'DESC\tHow the technical connections (Session IDs) are used: Files per connection per account, connection storms per minute, and the anatomy of failing sessions.\n'
        printf 'INTRO\tNo records with a usable Session ID in this dataset.\n'
        printf 'TABLE\tConnection efficiency\tnofilter\n'
        printf 'HEAD\tAccount\n'
        printf 'KIND\ttext\n'
        printf 'ROW\tNo records with a usable Session ID in this dataset.\n'
        printf 'TOTAL\tTotal (0 rows)\n'
        printf 'FOOT\n'
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "No usable Session IDs found — wrote empty-state $OUT." >&2
    exit 0
fi

IFS=$'\t' read -r _ p_sess p_files p_ratio p_sf p_user p_unk p_af p_mx p_rm p_facct \
    <<< "$(printf '%s\n' "$agg" | grep $'^PL\t')"

# league: least Files per connection first (the 1.00 rows are the reconnect-per-
# file partners), biggest session count breaking the tie, then the name.
lg_rows=$(printf '%s\n' "$agg" | { grep $'^L\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k2,2 -k4,4nr -k3,3 \
    | awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $5, $6, $7 }')

storm_rows=$(printf '%s\n' "$agg" | { grep $'^S\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2 \
    | awk -F'\t' -v n="$TOP_N" 'NR<=n { printf "ROW\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5 }')
n_storm_all=$(printf '%s\n' "$agg" | grep -c $'^S\t' || true)
storm_tot=$(printf '%s\n' "$agg" | { grep $'^S\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2 \
    | awk -F'\t' -v n="$TOP_N" 'NR<=n { c++; s += $5 } END { printf "%d\t%d", c+0, s+0 }')
IFS=$'\t' read -r n_storm storm_sess <<< "$storm_tot"

# a count cell shows blank, never 0 (2026-09-29: a row qualifies on ANY of
# its three counts, so the other two were often 0)
fail_rows=$(printf '%s\n' "$agg" | { grep $'^F\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2 \
    | awk -F'\t' -v n="$TOP_N" 'function z(v) { return (v + 0 == 0) ? "" : v }
        NR<=n { printf "ROW\t%s\t%s\t%s\t%s\n", $2, z($3), z($4), z($5) }')
fail_tot=$(printf '%s\n' "$agg" | { grep $'^F\t' || true; } | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2 \
    | awk -F'\t' -v n="$TOP_N" 'NR<=n { c++; a += $3; m += $4; r += $5 } END { printf "%d\t%d\t%d\t%d", c+0, a+0, m+0, r+0 }')
IFS=$'\t' read -r n_fail f_af f_mx f_rm <<< "$fail_tot"
nz0() { [ "${1:-0}" = 0 ] || printf '%s' "$1"; }

{
    printf 'TITLE\tConnection efficiency\n'
    printf 'DESC\tHow the technical connections (Session IDs) are used: Files per connection per account, connection storms per minute, and the anatomy of failing sessions.\n'
    printf 'INTRO\tA **session** is one technical connection — an SFTP login, a PeSIT session — identified by the log'\''s Session ID column (added to the exports 2026-08). One session can carry many Files, but on this platform it mostly does not: **%s** sessions carried **%s** Files between them (a File counted once per session it used — **%s** per connection) and **%s%%** of all sessions moved a single File. **%s** sessions were User-initiated (the partner connected in), the rest Server-initiated; **%s** record(s) without a usable Session ID are excluded. A session is attributed to the account of its first record.\n' \
        "$p_sess" "$p_files" "$p_ratio" "$p_sf" "$p_user" "$p_unk"

    # noagg: the TOTAL is the PLATFORM-wide figure, not the sum of the listed
    # accounts — a search must not re-sum it (2026-09-29 audit)
    printf 'TABLE\tFiles per connection\twide\tnofilter\tnoagg=1,2,3,4\n'
    printf 'HEAD\tAccount\tSessions\tFiles carried\tFiles per session\tSingle-File sessions\n'   # a File counts once per session it used (in + out: twice) — so "carried", not a distinct File count (2026-09-29)
    printf 'KIND\tacct\tnum\tnum\tnum\tnum\n'
    if [ -n "$lg_rows" ]; then
        printf '%s\n' "$lg_rows"
    else
        printf 'ROW\t@{colspan=5}No account reaches %s User-initiated sessions.\n' "$MIN_SESS"
    fi
    printf 'TOTAL\tAll sessions (platform, any initiator)\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s%%\n' \
        "$p_sess" "$p_files" "$p_ratio" "$p_sf"

    printf 'TABLE\tConnection storms (top %s accounts by peak starts per minute)\twide\tnofilter\n' "$TOP_N"
    printf 'HEAD\tAccount\tPeak sessions/min\tMinute\tSessions\n'
    printf 'KIND\tacct\tnum\tmono\tnum\n'
    if [ -n "$storm_rows" ]; then
        printf '%s\n' "$storm_rows"
        printf 'TOTAL\tTop %s of %s account(s)\t\t\t@{class=num}%s\n' "$n_storm" "$n_storm_all" "$storm_sess"
    else
        printf 'ROW\t@{colspan=4}No sessions in this dataset.\n'
        printf 'TOTAL\tTotal (0 accounts)\t\t\t\n'
    fi

    printf 'TABLE\tSession failure anatomy (top %s accounts by all-Error sessions)\twide\tnofilter\n' "$TOP_N"
    printf 'HEAD\tAccount\tAll-Error sessions\tMixed OK+Error\tRetry marathons\n'
    printf 'KIND\tacct\tnumfailed\tnumwarn\tnum\n'
    if [ -n "$fail_rows" ]; then
        printf '%s\n' "$fail_rows"
        printf 'TOTAL\tTop %s of %s account(s)\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num}%s\n' \
            "$n_fail" "$p_facct" "$(nz0 "$f_af")" "$(nz0 "$f_mx")" "$(nz0 "$f_rm")"
    else
        printf 'ROW\t@{colspan=4}No failing sessions in this dataset.\n'
        printf 'TOTAL\tTotal (0 accounts)\t\t\t\n'
    fi

    printf 'SUMMARY\tSessions: %s  |  Files/connection: %s  |  Single-File: %s%%  |  All-Error sessions: %s\n' \
        "$p_sess" "$p_ratio" "$p_sf" "$p_af"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT ($p_sess sessions, $p_ratio Files/connection, $p_sf% single-File)." >&2
