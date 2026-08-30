#!/usr/bin/env bash
#
# cleanup-backlog.sh — "Cleanup backlog": ONE ranked decommission-candidate
# list, merging the cleanup signals the site already computes in separate
# places — read from the SOURCE DATA (config caches, coverage TSVs, the
# transfer cache, the subscriptions export), never from other .rpt files, so
# the ordering is stable run to run. Five reason classes, SAFEST first:
#
#   config-orphan       accounts no subscription references (nothing can
#                       route a file through them)
#   never-any-traffic   configured subscriptions with zero Files ever
#                       (the coverage seen flag)
#   unused-whitelist    allowed partner addresses that never connected —
#                       no transfer AND no server mention (the established
#                       whitelist result rollup), grouped per allowing account
#   no-cron             cron-triggered subscriptions with no cron expression
#                       (the Missing-cronjobs condition): they can never run —
#                       a config gap to fix or remove
#   long-quiet          entities (partners, subscriptions, accounts, logins,
#                       hosts) whose last activity is 45+ days old
#
# An object appears ONCE, under its safest applicable class. The safety
# column is the honest hint: green = no traffic ever (safest to remove),
# orange = had traffic or is a config gap — check before acting.
#
# PARTNER = UNION attribution for the partner recency (the site-wide rule).
# Config/analysis page: the table is `nofilter`.
#
# Usage:
#   ./cleanup-backlog.sh   # -> data/<env>/analyses/reports/cleanup-backlog.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/uc-cases.sh"    # uc_meta: which use cases are cron-triggered
OUT="$REPORTS_DIR/cleanup-backlog.rpt"

TF="$DATA/transfer/cache/_files.tsv"
BASE="$DATA/flow-manager/base"
XREF="$DATA/flow-manager/xref"
COV="$DATA/transfer/reports/coverage"
SUBJSON="$ROOT/input/$AXWAY_ENV/flow-manager/subscriptions.json"
if [ ! -f "$TF" ] || [ ! -f "$BASE/_accounts.tsv" ]; then
    echo "cleanup-backlog: transfer cache or config caches missing; skipping." >&2
    rm -f "$OUT"
    exit 0
fi

deps=("$TF" "$BASE/_accounts.tsv" "$ROOT/bin/uc-cases.sh")
for f in "$BASE/_subscriptions.tsv" "$BASE/_white.tsv" \
         "$XREF/_accounts-subscriptions.tsv" "$XREF/_accounts-white.tsv" "$XREF/_subscriptions-partners.tsv" \
         "$COV/accounts.tsv" "$COV/subscriptions.tsv" "$COV/logins.tsv" "$COV/hosts.tsv" "$SUBJSON"; do
    [ -f "$f" ] && deps+=("$f")
done
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "${deps[@]}"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
GENDATE=$(date '+%Y-%m-%d %H:%M:%S')

# ---- the Missing-cronjobs condition, from the subscriptions export ----------
# (the cron expressions live in .parameters, which the config caches do not
# carry — the same jq as bin/transfer/reports/missing-cronjobs.sh)
NOCRON="$TMPD/nocron.tsv"
: > "$NOCRON"
cron_ucs=""
for u in UC1 UC2 UC3 UC4 UC5 UC6 UC7 UC8; do
    [ "$(uc_meta "$u" | cut -f7)" = "Cronjob" ] && cron_ucs="${cron_ucs}${cron_ucs:+|}$u"
done
if [ -n "$cron_ucs" ] && [ -f "$SUBJSON" ] && command -v jq >/dev/null 2>&1; then
    jq -r --arg re "^($cron_ucs)_" '
        .[] | select(.name | test($re))
        | select([.parameters // {} | to_entries[]
                  | select(.key | test("cron")) | select(.value != null and .value != "")] | length == 0)
        | [ .name, (.name | capture("^(?<uc>UC[0-9]+)").uc) ] | @tsv
    ' "$SUBJSON" > "$NOCRON" 2>/dev/null || : > "$NOCRON"
fi

nul() { [ -f "$1" ] && printf '%s' "$1" || printf '/dev/null'; }

# ---- one pass over every source, dedup in rank order ------------------------
# Emits sortable rows: rank, type-order, NAME, type, alink sub-dir, reason,
# evidence, last activity, safety text, result colour. Every class walks an
# ordered roster (file order), the final sort(1) fixes the page order.
awk -F'\t' -v ROWS="$TMPD/rows.pre" -v STATS="$TMPD/stats.tsv" '
    function jdn(y, m, d,   a2, y2, m2) { a2 = int((14 - m) / 12); y2 = y + 4800 - a2; m2 = m + 12 * a2 - 3
        return d + int((153 * m2 + 2) / 5) + 365 * y2 + int(y2 / 4) - int(y2 / 100) + int(y2 / 400) - 32045 }
    function djdn(s) { return jdn(substr(s,1,4)+0, substr(s,6,2)+0, substr(s,9,2)+0) }
    function emit(rank, to, name, type, sd, reason, ev, last, safe, res,   k) {
        k = type SUBSEP toupper(name)
        if (k in EM) return
        EM[k] = 1; NCLS[rank]++
        printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", rank, to, name, type, sd, reason, ev, last, safe, res > ROWS
    }
    FILENAME ~ /nocron\.tsv$/                    { if ($1 != "") { NC[++nnc] = $1; NCU[$1] = $2 }; next }
    FILENAME ~ /base\/_accounts\.tsv$/           { if ($1 != "") ACC[++nacc] = $1; next }
    FILENAME ~ /base\/_subscriptions\.tsv$/      { if ($1 != "") SRES[toupper($1)] = $3; next }
    FILENAME ~ /base\/_white\.tsv$/              { if ($1 != "") WRES[$1] = $3; next }
    FILENAME ~ /_accounts-subscriptions\.tsv$/   { if ($1 != "") HASSUB[toupper($1)] = 1; next }
    FILENAME ~ /_accounts-white\.tsv$/           { if ($1 != "" && $2 != "" && !(($1 SUBSEP $2) in AWP)) { AWP[$1 SUBSEP $2] = 1
                                                       if (AWT[$1] == "") AWORD[++naw] = $1     # emptiness, not membership (mawk)
                                                       AWT[$1]++; if (WRES[$2] == "orange") AWU[$1]++ }; next }
    FILENAME ~ /coverage\/accounts\.tsv$/        { CA[++nca] = $1; CAS[toupper($1)] = $3; CAT[toupper($1)] = substr($5, 1, 10); next }
    FILENAME ~ /coverage\/subscriptions\.tsv$/   { CS[++ncs] = $1; CSD[toupper($1)] = $2; CSS[toupper($1)] = $3; CST[toupper($1)] = substr($5, 1, 10); next }
    FILENAME ~ /coverage\/logins\.tsv$/          { CL[++ncl] = $1; CLS[toupper($1)] = $3; CLT[toupper($1)] = substr($5, 1, 10); next }
    FILENAME ~ /coverage\/hosts\.tsv$/           { CH[++nch] = $1; CHS[toupper($1)] = $3; CHT[toupper($1)] = substr($5, 1, 10); next }
    FILENAME ~ /_subscriptions-partners\.tsv$/   { if ($1 != "" && $2 != "") SP[toupper($1)] = SP[toupper($1)] (SP[toupper($1)] == "" ? "" : "\037") $2; next }
    {   # _files.tsv: the newest log day + the partner last-seen (union rule)
        if ($4 != "" && $4 > maxd) maxd = $4
        set = $20
        if ($12 != "" && (toupper($12) in SP)) { n = split(SP[toupper($12)], Z, "\037")
            for (i = 1; i <= n; i++) if (index("\037" set "\037", "\037" Z[i] "\037") == 0)
                set = set (set == "" ? "" : "\037") Z[i] }
        if (set == "") next
        n = split(set, Z, "\037")
        for (i = 1; i <= n; i++) { p = Z[i]; pu = toupper(p)
            if (PN[pu] == "") { PORD[++npn] = pu; PN[pu] = p }
            PF[pu]++
            if ($4 != "" && $4 > PL[pu]) PL[pu] = $4 }
    }
    END {
        mj = (maxd != "") ? djdn(maxd) : 0
        # rank 1: config-orphan accounts
        for (z = 1; z <= nacc; z++) { a = ACC[z]
            if (toupper(a) in HASSUB) continue
            last = CAT[toupper(a)]
            if (last == "") { safe = "no traffic ever"; res = "green"; last = "never" }
            else           { safe = "had traffic - check first"; res = "orange" }
            emit(1, 1, a, "account", "accounts", "config-orphan", "no subscription references this account", last, safe, res)
        }
        # rank 2: never-any-traffic subscriptions (skip the no-cron ones —
        # rank 4 explains WHY those never ran)
        for (z = 1; z <= nnc; z++) SKIPNC[toupper(NC[z])] = 1
        for (z = 1; z <= ncs; z++) { s = CS[z]; su = toupper(s)
            if (CSS[su] != "0") continue
            if (su in SKIPNC) continue
            d = (CSD[su] == "I") ? "in" : (CSD[su] == "O") ? "out" : "?"
            uc = "other"; if (match(s, /^UC[0-9]+/)) uc = substr(s, 1, RLENGTH)
            if (SRES[su] == "blue") emit(2, 2, s, "subscription", "subscriptions", "never-any-traffic", \
                "configured " d " (" uc "), zero Files ever - seen in the server log only", "never", "server contact only - check first", "orange")
            else emit(2, 2, s, "subscription", "subscriptions", "never-any-traffic", \
                "configured " d " (" uc "), zero Files ever", "never", "no traffic ever", "green")
        }
        # rank 3: unused whitelist addresses, grouped per allowing account
        totun = 0
        for (z = 1; z <= naw; z++) { a = AWORD[z]
            if (AWU[a] + 0 == 0) continue
            totun += AWU[a]
            last = CAT[toupper(a)]; if (last == "") last = "never"
            emit(3, 3, a, "whitelist", "accounts", "unused-whitelist", \
                AWU[a] " of " AWT[a] " allowed address(es) never seen - no transfer, no server mention", last, "addresses never connected - safe to prune", "green")
        }
        # rank 4: cron-triggered subscriptions with no cron expression
        for (z = 1; z <= nnc; z++) { s = NC[z]
            last = CST[toupper(s)]; if (last == "") last = "never"
            emit(4, 4, s, "subscription", "subscriptions", "no-cron", \
                "cron-triggered use case (" NCU[s] "), no cron expression - it can never poll", last, "config gap - fix or remove", "orange")
        }
        # rank 5: long-quiet (45+ days against the newest log day)
        for (z = 1; z <= npn; z++) { pu = PORD[z]
            if (PL[pu] == "" || mj - djdn(PL[pu]) < 45) continue
            emit(5, 1, PN[pu], "partner", "partners", "long-quiet", \
                "last File " (mj - djdn(PL[pu])) " day(s) before the newest log day (" PF[pu] " File(s) in total)", PL[pu], "had traffic - verify before removing", "orange")
        }
        for (z = 1; z <= ncs; z++) { s = CS[z]; su = toupper(s)
            if (CSS[su] != "1" || CST[su] == "" || mj - djdn(CST[su]) < 45) continue
            emit(5, 2, s, "subscription", "subscriptions", "long-quiet", \
                "last File " (mj - djdn(CST[su])) " day(s) before the newest log day", CST[su], "had traffic - verify before removing", "orange")
        }
        for (z = 1; z <= nca; z++) { a = CA[z]; au = toupper(a)
            if (CAS[au] != "1" || CAT[au] == "" || mj - djdn(CAT[au]) < 45) continue
            emit(5, 3, a, "account", "accounts", "long-quiet", \
                "last File " (mj - djdn(CAT[au])) " day(s) before the newest log day", CAT[au], "had traffic - verify before removing", "orange")
        }
        for (z = 1; z <= ncl; z++) { l = CL[z]; lu = toupper(l)
            if (CLS[lu] != "1" || CLT[lu] == "" || mj - djdn(CLT[lu]) < 45) continue
            emit(5, 4, l, "login", "logins", "long-quiet", \
                "last transfer " (mj - djdn(CLT[lu])) " day(s) before the newest log day", CLT[lu], "had traffic - verify before removing", "orange")
        }
        for (z = 1; z <= nch; z++) { h = CH[z]; hu = toupper(h)
            if (CHS[hu] != "1" || CHT[hu] == "" || mj - djdn(CHT[hu]) < 45) continue
            emit(5, 5, h, "host", "hosts", "long-quiet", \
                "last transfer " (mj - djdn(CHT[hu])) " day(s) before the newest log day", CHT[hu], "had traffic - verify before removing", "orange")
        }
        close(ROWS)
        printf "orphan\t%d\nnever\t%d\nwhite\t%d\nwhiteips\t%d\nnocron\t%d\nquiet\t%d\nmaxd\t%s\n", \
            NCLS[1] + 0, NCLS[2] + 0, NCLS[3] + 0, totun, NCLS[4] + 0, NCLS[5] + 0, maxd > STATS
        close(STATS)
    }
' "$NOCRON" "$(nul "$BASE/_accounts.tsv")" "$(nul "$BASE/_subscriptions.tsv")" "$(nul "$BASE/_white.tsv")" \
  "$(nul "$XREF/_accounts-subscriptions.tsv")" "$(nul "$XREF/_accounts-white.tsv")" \
  "$(nul "$COV/accounts.tsv")" "$(nul "$COV/subscriptions.tsv")" "$(nul "$COV/logins.tsv")" "$(nul "$COV/hosts.tsv")" \
  "$(nul "$XREF/_subscriptions-partners.tsv")" "$TF"

sv() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$TMPD/stats.tsv"; }
n_orphan=$(sv orphan); n_never=$(sv never); n_white=$(sv white); n_whiteips=$(sv whiteips)
n_nocron=$(sv nocron); n_quiet=$(sv quiet); maxd=$(sv maxd)
n_total=$(( n_orphan + n_never + n_white + n_nocron + n_quiet ))

{
    printf 'TITLE\tCleanup backlog\n'
    printf 'DESC\tOne ranked decommission-candidate list: config-orphan accounts, subscriptions that never carried a File, whitelist addresses that never connected, cron-triggered subscriptions that can never run, and entities quiet for 45+ days — safest class first.\n'
    printf 'INTRO\tEvery cleanup signal the site computes, merged into **one ranked list** and ordered safest-first: an object whose row is **green** never showed ANY traffic — removing it cannot break a working flow — while an **orange** row had traffic once (or is a config gap) and deserves a check before acting. Each object appears once, under its safest applicable class, and every row names its evidence. The classes, in rank order: **config-orphan** (no subscription references the account — nothing can route through it), **never-any-traffic** (configured subscription, zero Files ever), **unused-whitelist** (%s allowed addresses that never connected, grouped per allowing account), **no-cron** (a cron-triggered subscription with no cron expression can never poll — the quietest failure mode there is), and **long-quiet** (no activity for 45+ days, measured against the newest log day, %s).\n' \
        "$n_whiteips" "$maxd"
    printf 'STAT\twhite\t%s\tFindings\n' "$n_total"
    printf 'STAT\tgreen\t%s\tConfig-orphan accounts\n' "$n_orphan"
    printf 'STAT\tgreen\t%s\tNever-seen subscriptions\n' "$n_never"
    printf 'STAT\tgreen\t%s\tAccounts with unused whitelist\n' "$n_white"
    printf 'STAT\torange\t%s\tMissing a cronjob\n' "$n_nocron"
    printf 'STAT\torange\t%s\tLong quiet (45d+)\n' "$n_quiet"

    printf 'TABLE\tThe backlog, safest first\twide\tnofilter\trestint\tpager=100\n'
    printf 'HEAD\tObject\tType\tReason\tEvidence\tLast activity\tSafety\n'
    printf 'KIND\ttext\ttext\ttext\ttext\ttext\ttext\n'
    if [ -s "$TMPD/rows.pre" ]; then
        LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3f "$TMPD/rows.pre" | awk -F'\t' '{
            lnk = ($5 != "") ? "@{alink=" $5 "/" $3 "}" : ""
            printf "ROW\t%s%s\t%s\t%s\t%s\t%s\t%s\t@data:res=%s\n", lnk, $3, $4, $6, $7, $8, $9, $10
        }'
    else
        printf 'ROW\t@{colspan=6}Nothing to clean up — no orphans, no dead configuration, nothing long quiet.\n'
    fi
    printf 'TOTAL\tTotal (%s object(s))\t\t\t\t\t\n' "$n_total"

    printf 'NOTE\tEverything here reads SOURCE data — the flow-manager config caches, the coverage TSVs, the transfer cache and the subscriptions export — never another report, so the ranking is stable. "Never seen" for a whitelist address is the established result rollup: no transfer from that address AND no server-log mention (a server-contact-only address is NOT listed). The no-cron class is the Missing-cronjobs condition (the use-case definitions decide which UCs are cron-triggered); those subscriptions leave no trace in any log, so only the configuration can reveal them. Whitelist entries paired with no account at all are on **Config hygiene**. A partner'\''s recency uses the site-wide UNION attribution, so it matches the lifecycle and Entities views.\n'
    printf 'KEYWORDS\tcleanup,backlog,decommission,orphan,unused,whitelist,never seen,no cron,quiet,dormant,prune,legacy,attack surface\n'
    printf 'SUMMARY\tFindings: %s  |  Orphan accounts: %s  |  Never-seen subscriptions: %s  |  Unused-whitelist accounts: %s (%s addresses)  |  No cron: %s  |  Long quiet: %s\n' \
        "$n_total" "$n_orphan" "$n_never" "$n_white" "$n_whiteips" "$n_nocron" "$n_quiet"
    printf 'FOOT\tGenerated on %s\n' "$GENDATE"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_total finding(s): $n_orphan orphan, $n_never never-seen, $n_white whitelist, $n_nocron no-cron, $n_quiet long-quiet)." >&2
