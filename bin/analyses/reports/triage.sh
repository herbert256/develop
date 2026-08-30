#!/usr/bin/env bash
#
# triage.sh — "Triage": THE ranked action list. One row per subscription that
# needs eyes NOW, whatever the reason:
#
#   red              the base result cache says the flow is broken (its last
#                    File failed, or server-log evidence arrived after its
#                    last OK File — the bin/build/result.sh rules)
#   expiry-risk      the flow has Waiting (staged, uncollected) Files aged
#                    9 days or more against the window end — the nightly File
#                    Maintenance sweep (~11 days) is about to delete them
#   just-went-quiet  the flow's last File is 8-13 days before the window end:
#                    it crossed the went-quiet threshold (>7 days) RECENTLY —
#                    the freshest silences, before they fade into old news
#
# A subscription matching several classes gets ONE row, priority red >
# expiry-risk > just-went-quiet; the symptoms column mentions the rest.
#
# RANK: state recency x historical weight. Rank score = lifetime Files
# divided by (days in state + 1) — the newest flips with the biggest history
# land on top, ancient reds and one-file wonders sink. Documented in the NOTE.
#
# "Days in state" is measured against the LAST DAY IN THE DATA, not today
# (same convention as went-quiet.sh/stale-accounts.sh). Red-since comes from
# blue/_redflip.tsv (the server-log evidence stamp) where present, else the
# first failure of the current trailing failing run, else the last File.
#
# Sites are attributed to their CONFIGURED subscription by the longest
# uppercase prefix match (the logged values carry log-only tails, e.g. _SCP_);
# an unmatched logged site stands as its own row (it can be expiry-risk or
# just-went-quiet, never red — red is a configured-name verdict).
#
# This page is an ADDITION, not a replacement: the per-symptom deep-dives
# (From green to red, Went quiet, Waiting, Only red, the Boxes pages) remain
# where the full stories live — the evidence column points onward.
#
# Reads data/<env>/transfer/cache/_files.tsv (2=outcome, 4=date, 5=time,
# 6=sortkey, 7=jdn, 8=size, 12=dest_site), data/<env>/flow-manager/base/
# _subscriptions.tsv (name, dir, result) and data/<env>/blue/_redflip.tsv.
# Writes data/<env>/analyses/reports/triage.rpt.
#
# Usage:
#   ./triage.sh    # reads the caches, writes data/<env>/analyses/reports/triage.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

TF="$DATA/transfer/cache/_files.tsv"
BASE_SUBS="$DATA/flow-manager/base/_subscriptions.tsv"
RFLIP="$DATA/blue/_redflip.tsv"
OUT="$REPORTS_DIR/triage.rpt"

RISK_AGE=9     # a Waiting File staged this many days ago (or more) is at risk
QUIET_LO=8     # just-went-quiet window: last File 8..13 days before the window
QUIET_HI=13    # end (8 = just past went-quiet's >7-day rule; 13 = still fresh)

if [ ! -f "$TF" ] || [ ! -f "$BASE_SUBS" ]; then
    echo "triage: transfer cache or config cache missing; skipping." >&2
    exit 0
fi
[ -f "$RFLIP" ] || RFLIP=/dev/null
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TF" "$BASE_SUBS" "$RFLIP"

# ---- window end (last day in the data) --------------------------------------
read -r endj endd <<< "$(awk -F'\t' '$7 + 0 > j { j = $7 + 0; d = $4 } END { print j + 0, d }' "$TF")"

# ---- pass 1: attribute each File to its configured subscription --------------
# Longest-uppercase-prefix match against the configured names (memoized per
# distinct logged site); unmatched sites keep their own (uppercased) name.
# Emits: key <TAB> sortkey <TAB> jdn <TAB> date <TAB> time <TAB> outcome <TAB> size
# ---- pass 2 (after the sort): one aggregate line per key ---------------------
#   K <TAB> key <TAB> n <TAB> ok <TAB> err <TAB> bytes <TAB> lastdate <TAB>
#   lastj <TAB> lastfail <TAB> runstart <TAB> runjd <TAB> runlen <TAB>
#   lastokd <TAB> wtot <TAB> wrisk <TAB> wriskb <TAB> wriskolddate <TAB> wriskoldjd
agg=$(awk -F'\t' -v OFS='\t' '
    FILENAME ~ /_subscriptions\.tsv$/ { nc++; CFG[nc] = toupper($1); next }
    $12 == "" || $4 == "" || $7 == "" { next }
    {
        u = toupper($12)
        if (!(u in MAP)) {
            best = ""
            for (i = 1; i <= nc; i++)
                if (length(CFG[i]) > length(best) && index(u, CFG[i]) == 1) best = CFG[i]
            MAP[u] = (best != "") ? best : u
        }
        print MAP[u], $6, $7 + 0, $4, $5, $2, $8 + 0
    }
' "$BASE_SUBS" "$TF" \
| LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 \
| awk -F'\t' -v OFS='\t' -v endj="$endj" -v riskage="$RISK_AGE" '
    function flush() {
        if (key == "") return
        print "K", key, n, ok, err, bytes, lastdate, lastj, lastfail, runstart, runjd, runlen, lastokd, wtot, wrisk, wriskb, wrdate, wrjd
    }
    $1 != key {
        flush()
        key = $1; n = 0; ok = 0; err = 0; bytes = 0; lastdate = ""; lastj = 0
        lastfail = 0; runstart = ""; runjd = 0; runlen = 0; lastokd = ""
        wtot = 0; wrisk = 0; wriskb = 0; wrdate = ""; wrjd = 0
    }
    {
        n++; bytes += $7; lastdate = $4; lastj = $3
        if ($6 == "Failed" || $6 == "Expired") {
            err++
            if (runlen == 0) { runstart = $4 " " substr($5, 1, 8); runjd = $3 }
            runlen++; lastfail = 1
        } else {
            ok++; runlen = 0; runstart = ""; runjd = 0; lastfail = 0; lastokd = $4
            if ($6 == "Waiting") {
                wtot++
                if (endj - $3 >= riskage) {
                    wrisk++; wriskb += $7
                    if (wrdate == "") { wrdate = $4; wrjd = $3 }   # sortkey-sorted: first = oldest
                }
            }
        }
    }
    END { flush() }
')

# ---- pass 3: classify, rank, format ------------------------------------------
# Joins the aggregates with the base result column and the red-flip stamps.
# Emits row lines (sortable) + one TOT line:
#   R <TAB> iscore <TAB> key <TAB> cls <TAB> since <TAB> days <TAB> n <TAB> ok
#     <TAB> err <TAB> bytes <TAB> vol <TAB> score <TAB> sym <TAB> ev
#   TOT <TAB> rows <TAB> red <TAB> risk <TAB> quiet <TAB> volbytes
rows_raw=$(printf '%s\n' "$agg" | awk -F'\t' -v OFS='\t' \
    -v endj="$endj" -v qlo="$QUIET_LO" -v qhi="$QUIET_HI" '
    function jdn(y, m, d,   a) { a = int((14 - m) / 12); y = y + 4800 - a; m = m + 12 * a - 3
        return d + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045 }
    function dj(ds,   p) { split(ds, p, "-"); return jdn(p[1] + 0, p[2] + 0, p[3] + 0) }
    function hsize(b) { if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824)
        if (b >= 1048576) return sprintf("%.1f MB", b / 1048576)
        if (b >= 1024)    return sprintf("%.1f KB", b / 1024)
        return b " B" }
    function emit(key, cls, since, days, n, ok, err, volb, sym, ev,   sc) {
        sc = n / (1 + days)
        print "R", int(sc * 1000 + 0.5), key, cls, since, days, n, ok, err, volb, hsize(volb), sprintf("%.1f", sc), sym, ev
        rows++; tvol += volb
        if (cls == "red") nred++; else if (cls == "expiry-risk") nrisk++; else nquiet++
    }
    FILENAME ~ /_subscriptions\.tsv$/ {
        u = toupper($1); DISP[u] = $1; RES[u] = $3
        if ($3 == "red") { nr++; REDK[nr] = u }
        next
    }
    FILENAME ~ /_redflip\.tsv$/ { FLIP[toupper($1)] = $2; next }
    $1 != "K" { next }
    {
        key = $2; n = $3 + 0; ok = $4 + 0; err = $5 + 0; bytes = $6 + 0
        lastdate = $7; lastj = $8 + 0; lastfail = $9 + 0; runstart = $10
        runlen = $12 + 0; lastokd = $13; wtot = $14 + 0; wrisk = $15 + 0
        wriskb = $16 + 0; wrdate = $17; wrjd = $18 + 0
        seenk[key] = 1
        res = (key in RES) ? RES[key] : ""
        disp = (key in DISP) ? DISP[key] : key
        ago = endj - lastj
        if (res == "red") {
            if (key in FLIP)      { since = FLIP[key]; sjd = dj(substr(FLIP[key], 1, 10)) }
            else if (lastfail)    { since = runstart;  sjd = $11 + 0 }
            else                  { since = lastdate;  sjd = lastj }
            days = endj - sjd; if (days < 0) days = 0
            if (ok == 0)          sym = "never delivered — " err " Error in " n " File(s)"
            else if (lastfail)    sym = "used to work — " runlen " consecutive failure(s), last OK " lastokd
            else                  sym = "last File OK (" lastdate ") — flipped red by server-log evidence"
            if (wrisk > 0)        sym = sym "; " wrisk " staged at risk"
            if (key in FLIP)      ev = "server-log evidence " FLIP[key] " — see From green to red"
            else if (ok == 0)     ev = "never green — see Only red and the Boxes pages"
            else                  ev = "first failure of the run " runstart " — see From green to red"
            emit(disp, "red", since, days, n, ok, err, bytes, sym, ev)
        } else if (wrisk > 0) {
            days = endj - wrjd
            sym = wrisk " of " wtot " staged File(s) at risk — oldest staged " wrdate " (sweep deletes at ~11 days)"
            ev = "staged, uncollected — see Waiting"
            emit(disp, "expiry-risk", wrdate, days, n, ok, err, wriskb, sym, ev)
        } else if (ago >= qlo && ago <= qhi) {
            sym = "just went quiet — no traffic for " ago " day(s) after " n " File(s)"
            ev = "last File " lastdate " — see Went quiet"
            emit(disp, "just-went-quiet", lastdate, ago, n, ok, err, bytes, sym, ev)
        }
    }
    END {
        # a red subscription with no attributed Files at all still needs a row
        for (i = 1; i <= nr; i++) {
            u = REDK[i]
            if (u in seenk) continue
            since = (u in FLIP) ? FLIP[u] : "-"
            days = (u in FLIP) ? endj - dj(substr(FLIP[u], 1, 10)) : 0
            emit(DISP[u], "red", since, days, 0, 0, 0, 0, "no Files in the window", "see Only red and the Boxes pages")
        }
        print "TOT", rows + 0, nred + 0, nrisk + 0, nquiet + 0, tvol + 0
    }
' "$BASE_SUBS" "$RFLIP" -)

IFS=$'\t' read -r _ n_rows n_red n_risk n_quiet t_vol \
    <<< "$(printf '%s\n' "$rows_raw" | grep $'^TOT\t')"

# Highest score first, name as the tiebreaker — the baked order matches the
# table default sort (sort=8:-1), so a no-JS reader sees the same ranking.
# `|| true`: zero rows = nothing to triage, rendered as the placeholder below.
rows=$(printf '%s\n' "$rows_raw" | grep $'^R\t' \
       | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k3,3 || true)

t_vol_h=$(awk -v b="${t_vol:-0}" 'BEGIN{ if (b>=1073741824) printf "%.1f GB", b/1073741824
    else if (b>=1048576) printf "%.1f MB", b/1048576
    else if (b>=1024)    printf "%.1f KB", b/1024
    else                 printf "%d B", b }')

sum_n=0; sum_ok=0; sum_err=0
{
    printf 'TITLE\tTriage\n'
    printf 'DESC\tThe ranked action list: every subscription that is red, has staged Files about to expire, or just went quiet — newest flips with the biggest history first.\n'
    printf 'KEYWORDS\ttriage, action list, priority, ranked, broken, red, expiry, at risk, staged, quiet, silence, needs attention, worklist\n'
    printf 'INTRO\tOne worklist instead of six symptom pages: **%s** subscription(s) currently need eyes — **%s** are **red** (last File failed, or server-log evidence after the last OK), **%s** carry staged Files at **expiry risk** (Waiting for **%s+ days**; the retention sweep deletes at ~11), and **%s** **just went quiet** (last File %s-%s days before the window end **%s** — the freshest silences). Ranked by state recency times historical weight, so the newest problems on the busiest flows come first. The per-symptom pages remain the deep-dives; the Evidence column says where to read on.\n' \
        "${n_rows:-0}" "${n_red:-0}" "${n_risk:-0}" "$RISK_AGE" "${n_quiet:-0}" "$QUIET_LO" "$QUIET_HI" "${endd:-?}"

    printf 'STAT\twhite\t%s\tFlows to triage\n' "${n_rows:-0}"
    printf 'STAT\tred\t%s\tred\n' "${n_red:-0}"
    printf 'STAT\torange\t%s\texpiry risk\n' "${n_risk:-0}"
    printf 'STAT\torange\t%s\tjust went quiet\n' "${n_quiet:-0}"

    printf 'TABLE\tRanked action list\twide\tnofilter\tsort=8:-1\n'
    printf 'HEAD\tSubscription\tStatus\tSince\tDays in state\tFiles\tOK\tError\tVolume at stake\tScore\tSymptoms\tEvidence\n'
    printf 'KIND\tsite\ttext\ttext\tnum\tnum\tnumprocessed\tnumfailed\ttext\tnum\ttext\ttext\n'
    if [ "${n_rows:-0}" -eq 0 ]; then
        printf 'ROW\t@{colspan=11}Nothing to triage — no red, no staged Files at risk, no fresh silences.\n'
    else
        while IFS=$'\t' read -r _ _ key cls since days n ok err _ vol score sym ev; do
            [ -z "$key" ] && continue
            sum_n=$((sum_n + n)); sum_ok=$((sum_ok + ok)); sum_err=$((sum_err + err))
            printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$key" "$cls" "$since" "$days" "$n" "$ok" "$err" "$vol" "$score" "$sym" "$ev"
        done <<< "$rows"
    fi
    printf 'TOTAL\tTotal (%s subscriptions)\t\t\t\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num}%s\t\t\t\n' \
        "${n_rows:-0}" "$sum_n" "$sum_ok" "$sum_err" "$t_vol_h"
    printf 'NOTE\tRank score = **lifetime Files / (days in state + 1)** — state recency times historical weight: a flow that flipped yesterday after carrying hundreds of Files outranks one red for a month, which outranks a one-file wonder. **Days in state** counts against the last day in the data (**%s**), never the wall clock. Red-since is the server-log evidence stamp where one exists, else the first failure of the current failing run. **Volume at stake** is the flow'\''s lifetime volume — except for expiry-risk rows, where it is the staged bytes about to be deleted. One row per subscription, priority red > expiry-risk > just-went-quiet; the symptoms mention any second condition. This page is an ADDITION: **From green to red**, **Went quiet**, **Waiting**, **Expired**, **Only red** and the **Boxes** pages remain the per-symptom deep-dives — the Evidence column points the way.\n' \
        "${endd:-?}"
    printf 'LINK\t../transfer/from-green-to-red.html\tFrom green to red — the regression deep-dive\n'
    printf 'LINK\t../transfer/went-quiet-subscriptions.html\tWent quiet — every silence, not just the fresh ones\n'
    printf 'LINK\t../transfer/waiting.html\tWaiting — staged Files, expiries and pickup waits\n'
    printf 'LINK\t../analyses/subscriptions-in-boxes.html\tSubscriptions in boxes — every flow sorted into its box\n'
    printf 'SUMMARY\tTriage: %s flow(s) — %s red, %s expiry risk, %s just went quiet  |  Window ends: %s\n' \
        "${n_rows:-0}" "${n_red:-0}" "${n_risk:-0}" "${n_quiet:-0}" "${endd:-?}"
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${n_rows:-0} flow(s): ${n_red:-0} red, ${n_risk:-0} expiry risk, ${n_quiet:-0} just quiet)." >&2
