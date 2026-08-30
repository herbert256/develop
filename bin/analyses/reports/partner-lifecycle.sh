#!/usr/bin/env bash
#
# partner-lifecycle.sh — "Partner lifecycle": the three lifecycle edges of a
# partner relation, in one page:
#
#   Configured, never live   configured partner organisations with ZERO
#                            union-attributed Files. The names also appear in
#                            the Entities views — the value here is context:
#                            the configured direction and how many
#                            subscriptions sit ready behind each name.
#   Gone quiet               partners WITH Files whose last File is 14+ days
#                            old (against the newest log day): silence where
#                            there used to be traffic.
#   Shrinking                partners whose count of ACTIVE subscriptions
#                            (distinct subscriptions with at least one File)
#                            dropped by 2+ between the previous 14 log days
#                            and the last 14.
#
# PARTNER = UNION attribution (xref/_subscriptions-partners.tsv on _files
# col 12 unioned with col 20) — the site-wide rule. Sources: the configured
# partner list (flow-manager base), the partner-subscriptions xref and the
# _files cache. Config/analysis page: every table is `nofilter`.
#
# Usage:
#   ./partner-lifecycle.sh   # -> data/<env>/analyses/reports/partner-lifecycle.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/partner-lifecycle.rpt"

TF="$DATA/transfer/cache/_files.tsv"
PBASE="$DATA/flow-manager/base/_partners.tsv"
SPMAP="$DATA/flow-manager/xref/_subscriptions-partners.tsv"
PSUB="$DATA/flow-manager/xref/_partners-subscriptions.tsv"
if [ ! -f "$TF" ] || [ ! -f "$PBASE" ]; then
    echo "partner-lifecycle: transfer cache or partner config missing; skipping." >&2
    rm -f "$OUT"
    exit 0
fi
[ -f "$SPMAP" ] || SPMAP=/dev/null
[ -f "$PSUB" ] || PSUB=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TF" "$PBASE" "$SPMAP" "$PSUB"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
GENDATE=$(date '+%Y-%m-%d %H:%M:%S')

# One pass over the config lists + $FILES: per partner (union) the Files,
# errors, last-seen and the per-(day, subscription) activity for the two
# 14-day windows. END emits sortable row files (explicit keys, no hash order).
awk -F'\t' -v T1="$TMPD/t1.pre" -v T2="$TMPD/t2.pre" -v T3="$TMPD/t3.pre" -v STATS="$TMPD/stats.tsv" '
    function jdn(y, m, d,   a2, y2, m2) { a2 = int((14 - m) / 12); y2 = y + 4800 - a2; m2 = m + 12 * a2 - 3
        return d + int((153 * m2 + 2) / 5) + 365 * y2 + int(y2 / 4) - int(y2 / 100) + int(y2 / 400) - 32045 }
    function djdn(s) { return jdn(substr(s,1,4)+0, substr(s,6,2)+0, substr(s,9,2)+0) }
    FILENAME ~ /base\/_partners\.tsv$/ {
        if ($1 == "") next
        cu = toupper($1)
        if (CNAME[cu] == "") CORD[++nc] = cu               # emptiness, not membership (mawk)
        CNAME[cu] = $1; CDIR[cu] = $2; CRES[cu] = $3
        next }
    FILENAME ~ /_partners-subscriptions\.tsv$/ {
        if ($1 != "" && $2 != "" && !((toupper($1) SUBSEP $2) in PSJ)) { PSJ[toupper($1) SUBSEP $2] = 1; NSUB[toupper($1)]++ }
        next }
    FILENAME ~ /_subscriptions-partners\.tsv$/ {
        if ($1 != "" && $2 != "") SP[toupper($1)] = SP[toupper($1)] (SP[toupper($1)] == "" ? "" : "\037") $2
        next }
    {
        set = $20
        if ($12 != "" && (toupper($12) in SP)) { n = split(SP[toupper($12)], Z, "\037")
            for (i = 1; i <= n; i++) if (index("\037" set "\037", "\037" Z[i] "\037") == 0)
                set = set (set == "" ? "" : "\037") Z[i] }
        if (set == "") next
        err = ($2 == "Failed" || $2 == "Expired") ? 1 : 0
        if ($4 != "" && $4 > maxd) maxd = $4
        n = split(set, Z, "\037")
        for (i = 1; i <= n; i++) { p = Z[i]; pu = toupper(p)
            if (SEENN[pu] == "") { SORD[++ns] = pu; SEENN[pu] = p }
            F[pu]++; E[pu] += err
            if ($4 != "") { if ($4 > L[pu]) L[pu] = $4
                if ($12 != "" && !((pu SUBSEP $4 SUBSEP $12) in SA)) { SA[pu SUBSEP $4 SUBSEP $12] = 1
                    DAYS[pu SUBSEP $4] = DAYS[pu SUBSEP $4] "\036" $12 } }
        }
        next }
    END {
        mj = (maxd != "") ? djdn(maxd) : 0
        # window-distinct active subscriptions per partner from the per-day sets
        for (k in DAYS) { split(k, X, SUBSEP); pu = X[1]; dd = djdn(X[2])
            w = ""
            if (mj - dd < 14) w = "L"; else if (mj - dd < 28) w = "P"
            if (w == "") continue
            m = split(substr(DAYS[k], 2), SS, "\036")
            for (i = 1; i <= m; i++) if (!((pu SUBSEP w SUBSEP SS[i]) in WA)) { WA[pu SUBSEP w SUBSEP SS[i]] = 1; WC[pu SUBSEP w]++ }
        }
        # table 1: configured, never live (includes the server-log-only blues
        # — blue always means "never transferred")
        n1 = 0
        for (z = 1; z <= nc; z++) { cu = CORD[z]
            if (cu in SEENN) continue
            n1++
            res = CRES[cu]; if (res != "green" && res != "red" && res != "orange" && res != "blue") res = "orange"
            printf "%s\t%s\t%d\t%s\n", CNAME[cu], CDIR[cu], NSUB[cu] + 0, res > T1
        }
        close(T1)
        # table 2: gone quiet (14+ days against the newest log day)
        n2 = 0
        for (z = 1; z <= ns; z++) { pu = SORD[z]
            if (L[pu] == "") continue
            dq = mj - djdn(L[pu])
            if (dq < 14) continue
            n2++
            printf "%04d\t%s\t%d\t%.1f\t%s\t%d\n", 9999 - dq, SEENN[pu], F[pu], 100 * E[pu] / F[pu], L[pu], dq > T2
        }
        close(T2)
        # table 3: shrinking (active subscriptions, prior 14 days vs last 14)
        n3 = 0
        for (z = 1; z <= ns; z++) { pu = SORD[z]
            lw = WC[pu SUBSEP "L"] + 0; pw = WC[pu SUBSEP "P"] + 0
            if (pw - lw < 2) continue
            n3++
            printf "%03d\t%s\t%d\t%d\t%d\n", 999 - (pw - lw), SEENN[pu], pw, lw, pw - lw > T3
        }
        close(T3)
        printf "configured\t%d\nseen\t%d\nnever\t%d\nquiet\t%d\nshrink\t%d\nmaxd\t%s\n", nc, ns, n1, n2, n3, maxd > STATS
        close(STATS)
    }
' "$PBASE" "$PSUB" "$SPMAP" "$TF"

sv() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$TMPD/stats.tsv"; }
n_conf=$(sv configured); n_seen=$(sv seen); n_never=$(sv never)
n_quiet=$(sv quiet); n_shrink=$(sv shrink); maxd=$(sv maxd)

{
    printf 'TITLE\tPartner lifecycle\n'
    printf 'DESC\tThe three lifecycle edges of a partner relation: configured organisations that never carried a File, partners gone quiet for 14+ days, and partners whose set of active subscriptions is shrinking.\n'
    printf 'INTRO\tA partner relation has three quiet failure modes, and each one looks different in the data. **Configured, never live** is the onboarding that never happened: the name and its subscriptions exist, no File ever flowed. **Gone quiet** is the opposite end — traffic that stopped: the partner has history, then 14+ days of silence (measured against the newest log day, **%s**). **Shrinking** is the subtle middle: the partner still transfers, but the number of its subscriptions actually carrying Files dropped by 2 or more between the previous 14 log days and the last 14 — flows are dying one by one while the relation as a whole still looks alive.\n' \
        "$maxd"
    printf 'STAT\twhite\t%s\tConfigured partners\n' "$n_conf"
    printf 'STAT\twhite\t%s\tSeen (with Files)\n' "$n_seen"
    printf 'STAT\torange\t%s\tNever live\n' "$n_never"
    printf 'STAT\torange\t%s\tGone quiet (14d+)\n' "$n_quiet"
    printf 'STAT\tred\t%s\tShrinking\n' "$n_shrink"

    printf 'TABLE\tConfigured, never live\tnofilter\trestint\n'
    printf 'HEAD\tPartner\tDirection\tSubscriptions\n'
    printf 'KIND\tptn\ttext\tnum\n'
    if [ -s "$TMPD/t1.pre" ]; then
        LC_ALL=C sort -t$'\t' -k1,1f "$TMPD/t1.pre" | awk -F'\t' '{
                n++; s += $3
                printf "ROW\t%s\t%s\t%d\t@data:res=%s\n", $1, $2, $3, $4
            }
            END { printf "TOTAL\tTotal (%d partner(s))\t\t@{class=num}%d\n", n + 0, s + 0 }'
    else
        printf 'ROW\t@{colspan=3}Every configured partner has carried at least one File.\n'
        printf 'TOTAL\tTotal (0 partner(s))\t\t\n'
    fi

    printf 'TABLE\tGone quiet\tnofilter\n'
    printf 'HEAD\tPartner\tFiles\tError %%\tLast seen\tDays quiet\n'
    printf 'KIND\tptn\tnum\tnum\ttext\tnum\n'
    if [ -s "$TMPD/t2.pre" ]; then
        LC_ALL=C sort -t$'\t' -k1,1 -k2,2f "$TMPD/t2.pre" | awk -F'\t' '{
                n++; f += $3
                printf "ROW\t%s\t%d\t%s\t%s\t%d\t@data:res=orange\n", $2, $3, $4, $5, $6
            }
            END { printf "TOTAL\tTotal (%d partner(s))\t@{class=num}%d\t\t\t\n", n + 0, f + 0 }'
    else
        printf 'ROW\t@{colspan=5}No partner with Files has been quiet for 14 days or more.\n'
        printf 'TOTAL\tTotal (0 partner(s))\t\t\t\t\n'
    fi

    printf 'TABLE\tShrinking\tnofilter\tnosearch\n'
    printf 'HEAD\tPartner\tActive subs, prior 14d\tActive subs, last 14d\tDropped\n'
    printf 'KIND\tptn\tnum\tnum\tnum\n'
    if [ -s "$TMPD/t3.pre" ]; then
        LC_ALL=C sort -t$'\t' -k1,1 -k2,2f "$TMPD/t3.pre" | awk -F'\t' '{
                n++; d += $5
                printf "ROW\t%s\t%d\t%d\t%d\t@data:res=orange\n", $2, $3, $4, $5
            }
            END { printf "TOTAL\tTotal (%d partner(s))\t\t\t@{class=num}%d\n", n + 0, d + 0 }'
    else
        printf 'ROW\t@{colspan=4}No partner dropped 2 or more active subscriptions between the two windows.\n'
        printf 'TOTAL\tTotal (0 partner(s))\t\t\t\n'
    fi

    printf 'NOTE\tPartner attribution is the site-wide UNION rule (the subscription'\''s configured partners unioned with the parse attribution), so these figures match the Entities and coverage views. In the never-live table the row colour is the partner'\''s standard result colour — **orange** never seen anywhere, **blue** seen in the server log only (a connection, still zero Files); its Subscriptions column counts the configured subscriptions waiting behind the name. "Active subscription" in the shrinking table means a distinct subscription with at least one File in the window — the drop threshold of 2 filters ordinary week-to-week noise.\n'
    printf 'KEYWORDS\tpartner,lifecycle,never live,onboarding,gone quiet,silent,shrinking,active subscriptions,decommission,dormant\n'
    printf 'SUMMARY\tConfigured: %s  |  Seen: %s  |  Never live: %s  |  Gone quiet: %s  |  Shrinking: %s\n' \
        "$n_conf" "$n_seen" "$n_never" "$n_quiet" "$n_shrink"
    printf 'FOOT\tGenerated on %s\n' "$GENDATE"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_never never live, $n_quiet gone quiet, $n_shrink shrinking of $n_conf configured partner(s))." >&2
