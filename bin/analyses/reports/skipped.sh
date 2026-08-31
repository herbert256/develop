#!/usr/bin/env bash
#
# skipped.sh — "Skipped" (an ANALYSES report published with the transfer pages,
# like entity-coverage.sh): the accounts and subscriptions IGNORED because
# their name matches the environment's skip list (input/<env>/skip.txt), plus a count of the
# transfer- and server-log records set aside for the same reason.
#
# Writes ONE overview report (skipped.rpt) plus ONE report PER skip value
# (skipped-<slug>.rpt) — each scoped to the accounts/subscriptions/records that
# matched that value. The pages carry a button row (All + one per value); the
# per-value pages are discovered by bin/transfer/publish.sh (glob), the report
# finder and the sitemap.
#
# The actual filtering happens at PARSE time (see bin/flow-manager.sh,
# bin/transfer/parse.sh, bin/server/parse.sh); this report only reads the
# sidecars those steps leave behind:
#   data/<env>/flow-manager/filtered/_skipped.tsv   type<TAB>name  (Account / Subscription)
#   data/<env>/transfer/_skipped.tsv       the skipped _transfers.tsv rows
#   data/<env>/server/_skipped.tsv         the skipped _parse.tsv rows
# No date filter — a static audit of what the skip list removed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../transfer/lib.sh"
mkdir -p "$REPORTS_DIR"

CFG_SKIP="$CONFIG_DIR/filtered/_skipped.tsv"   # data/<env>/flow-manager/filtered/_skipped.tsv (type<TAB>name)
T_SKIP="$DATA/transfer/_skipped.tsv"       # skipped transfer records
S_SKIP="$DATA/server/_skipped.tsv"         # skipped server records
SKIPFILE="$ROOT/input/$AXWAY_ENV/skip.txt" # the rules (per environment since 2026-08-31)
source "$ROOT/bin/skiplist.sh"             # SKIPLIST_AWK (sl_load/sl_match) — the ONE reader

# All the inputs are parse-time products (the two _skipped.tsv sidecars and the
# config sidecar) plus the rule file and its reader. The per-value
# skipped-<slug>.rpt files are written in the same run as skipped.rpt, so the
# mtime check on the latter speaks for them too.
skip_if_fresh "$REPORTS_DIR/skipped.rpt" "${BASH_SOURCE[0]}" \
    "$CFG_SKIP" "$T_SKIP" "$S_SKIP" "$SKIPFILE" "$ROOT/bin/skiplist.sh"

# Remove any stale per-value reports from a previous skip list, then (re)write.
rm -f "$REPORTS_DIR"/skipped-*.rpt

awk -F'\t' -v cfg="$CFG_SKIP" -v skf="$SKIPFILE" -v tfile="$T_SKIP" -v sfile="$S_SKIP" \
    -v outdir="$REPORTS_DIR" -v now="$(date '+%Y-%m-%d %H:%M:%S')" "$SKIPLIST_AWK"'
    function slugify(x,   s) { s = tolower(x); gsub(/[^a-z0-9]+/, "-", s); gsub(/^-+|-+$/, "", s); return (s == "" ? "_" : s) }
    # which skip RULE (1..nt) does value V match first? 0 = none. The rules come
    # from bin/skiplist.sh, so a value here is caught by exactly the rule that
    # dropped it at parse time — including a field-specific or regex rule, which
    # a flat token scan could not express. Config NAMES are accounts and
    # subscriptions, so they are tested against those fields.
    function tokof(v,   k) { k = sl_match("account", v); return k ? k : sl_match("site", v) }
    BEGIN {
        sl_load(skf)
        nt = SL_N; tokens = ""
        for (ti = 1; ti <= nt; ti++) {
            ORIG[ti] = SL_RAW[ti]; SLUG[ti] = slugify(SL_RAW[ti])
            tokens = tokens (tokens == "" ? "" : ", ") SL_RAW[ti]
        }
        # config sidecar -> per-token accounts / subscriptions (attributed to the
        # first matching token; also kept in overall order for the All page)
        if (cfg != "") {
            while ((getline l < cfg) > 0) {
                n = split(l, a, "\t"); if (n < 2 || a[2] == "") continue
                k = tokof(a[2]); if (k == 0) continue
                if (a[1] == "Account")           { ACC[k, ++nacc[k]] = a[2] }
                else if (a[1] == "Subscription") { SUB[k, ++nsub[k]] = a[2] }
            }
            close(cfg)
        }
        # transfer sidecar -> per-token record counts (attributed account col 4 or subscription/site col 6)
        if (tfile != "") {
            while ((getline l < tfile) > 0) {
                n = split(l, a, "\t")
                k = tokof(a[4]); if (k == 0) k = tokof(a[6])
                if (k > 0) tcnt[k]++
            }
            close(tfile)
        }
        # server sidecar -> per-token record counts (message col 5)
        if (sfile != "") {
            while ((getline l < sfile) > 0) {
                n = split(l, a, "\t"); k = tokof(a[5]); if (k > 0) scnt[k]++
            }
            close(sfile)
        }

        # ---- the OVERVIEW report (skipped.rpt): totals + a section per value.
        # Written as .rpt.tmp — the splice pass below reads it and publishes the
        # final skipped.rpt atomically, so a killed run never leaves a truncated
        # report with a fresh mtime for skip_if_fresh to trust. ----
        main = outdir "/skipped.rpt.tmp"
        printf "TITLE\tSkipped\n" > main
        printf "DESC\tThe accounts and subscriptions ignored because their name matches the skip list (input/%s/skip.txt), plus the transfer- and server-log records set aside for the same reason.\n", ENVIRON["AXWAY_ENV"] > main
        printf "INTRO\tNames matching the **skip list** (**input/%s/skip.txt**, this environment'\''s own — %s) are removed at parse time — from the FlowManager config, the transfer logs and the server logs alike — so **no other report counts them**. Matching is a case-insensitive **substring** of the account or subscription name. The buttons below give a per-value report; this page lists them all.\n", ENVIRON["AXWAY_ENV"], (tokens == "" ? "(empty)" : tokens) > main
        printf "KEYWORDS\tskip, skipped, ignore, ignored, exclude, excluded, filter, filtered, skip.txt, %s\n", tokens > main
        # totals across all values
        for (i = 1; i <= nt; i++) { TA += nacc[i]; TS += nsub[i]; TT += tcnt[i]; TV += scnt[i] }
        printf "STAT\twhite\t%d\tSkipped accounts\n", TA + 0 > main
        printf "STAT\twhite\t%d\tSkipped subscriptions\n", TS + 0 > main
        printf "STAT\twhite\t%d\tSkipped transfer log lines\n", TT + 0 > main
        printf "STAT\twhite\t%d\tSkipped server log lines\n", TV + 0 > main
        if (nt == 0) printf "NOTE\tThe skip list (input/<env>/skip.txt) is empty — nothing was skipped.\n" > main

        for (i = 1; i <= nt; i++) {
            # per-value section on the overview
            emit_value(main, i, ORIG[i])
            # ---- the per-value report (skipped-<slug>.rpt) ----
            pv = outdir "/skipped-" SLUG[i] ".rpt"
            printf "TITLE\tSkipped: %s\n", ORIG[i] > pv
            printf "DESC\tThe accounts, subscriptions and log records skipped because their name matches the skip token \"%s\".\n", ORIG[i] > pv
            printf "INTRO\tEverything removed at parse time because its account or subscription name contains **%s** (a case-insensitive substring of the skip list, input/<env>/skip.txt).\n", ORIG[i] > pv
            printf "KEYWORDS\tskip, skipped, %s\n", ORIG[i] > pv
            printf "STAT\twhite\t%d\tSkipped accounts\n", nacc[i] + 0 > pv
            printf "STAT\twhite\t%d\tSkipped subscriptions\n", nsub[i] + 0 > pv
            printf "STAT\twhite\t%d\tSkipped transfer log lines\n", tcnt[i] + 0 > pv
            printf "STAT\twhite\t%d\tSkipped server log lines\n", scnt[i] + 0 > pv
            emit_value(pv, i, ORIG[i])
            printf "SUMMARY\tSkipped for %s: %d account(s), %d subscription(s), %d transfer line(s), %d server line(s)\n", ORIG[i], nacc[i]+0, nsub[i]+0, tcnt[i]+0, scnt[i]+0 > pv
            printf "FOOT\tGenerated on %s\n", now > pv
            close(pv)
        }
        printf "SUMMARY\tSkipped: %d account(s), %d subscription(s), %d transfer line(s), %d server line(s) across %d value(s)\n", TA+0, TS+0, TT+0, TV+0, nt > main
        printf "FOOT\tGenerated on %s\n", now > main
        close(main)
    }
    # emit the two tables (accounts, subscriptions) for token i to file f
    function emit_value(f, i, label,   j) {
        printf "TABLE\tSkipped accounts — %s\tnosort\tkeephead\n", label > f
        printf "HEAD\tAccount\n" > f
        printf "KIND\ttext\n" > f
        if (nacc[i] + 0 == 0) printf "ROW\t@{class=desc}(none — no configured account matched %s)\n", label > f
        else for (j = 1; j <= nacc[i]; j++) printf "ROW\t%s\n", ACC[i, j] > f
        printf "TOTAL\tTotal (%d account%s)\n", nacc[i]+0, (nacc[i]+0 == 1 ? "" : "s") > f

        printf "TABLE\tSkipped subscriptions — %s\tnosort\n", label > f
        printf "HEAD\tSubscription\n" > f
        printf "KIND\ttext\n" > f
        if (nsub[i] + 0 == 0) printf "ROW\t@{class=desc}(none — no configured subscription matched %s)\n", label > f
        else for (j = 1; j <= nsub[i]; j++) printf "ROW\t%s\n", SUB[i, j] > f
        printf "TOTAL\tTotal (%d subscription%s)\n", nsub[i]+0, (nsub[i]+0 == 1 ? "" : "s") > f
    }
' </dev/null

# ---- the NO-SUBSCRIPTION / HTTP skip table (data/<env>/transfer/_skipped.csv:
# the RAW input lines of the CoreIds bin/transfer/parse.sh dropped because no
# leg carried a subscription OR an account — a group with an account keeps a
# synthetic "UCx_<account>" site since 2026-08 and counts — or because a leg
# ran over http). Tokenize each
# raw CSV line into readable columns and splice the table into skipped.rpt
# just before its SUMMARY line (plus a 5th STAT box after the existing four).
RAW_SKIP="$DATA/transfer/_skipped.csv"
rows_tmp="$REPORTS_DIR/skipped.rows.tmp.$$"
# clean the temps on ANY exit — an orphan in the freshness-watched reports
# tree would force one extra publish (unmatched globs stay literal; rm -f
# ignores them)
trap 'rm -f "$rows_tmp" "$REPORTS_DIR"/skipped.rpt.tmp*' EXIT
if [ -f "$RAW_SKIP" ] && [ -s "$RAW_SKIP" ]; then
    awk '
        function f(line, want,    n, i, c, q, cur) {
            n = 0; cur = ""; q = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (q) { if (c == "\"") { if (substr(line, i+1, 1) == "\"") { cur = cur "\""; i++ } else q = 0 } else cur = cur c }
                else { if (c == "\"") q = 1
                       else if (c == ",") { n++; if (n == want) return cur; cur = "" }
                       else cur = cur c }
            }
            n++; return (n == want) ? cur : ""
        }
        # pass 1: which CoreIds have an http leg; pass 2: emit sortable rows
        FNR == NR { if (f($0, 20) == "http") ht[f($0, 34)] = 1; next }
        {
            ts = f($0, 23); cid = f($0, 34)
            split(ts, dt, " "); split(dt[1], m, "/")
            iso = (m[3] != "" ? sprintf("%04d-%02d-%02d", m[3], m[1], m[2]) : dt[1])
            reason = (cid in ht) ? "http" : "no subscription"
            printf "%s %s\tROW\t%s %s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                iso, dt[2], iso, dt[2], reason, f($0, 1), f($0, 2), f($0, 3), \
                f($0, 8), f($0, 20), f($0, 15), f($0, 19), cid
        }
    ' "$RAW_SKIP" "$RAW_SKIP" | LC_ALL=C sort -r | cut -f2- > "$rows_tmp"
else
    : > "$rows_tmp"
fi
nraw=$(grep -c . "$rows_tmp" || true)
awk -v rowsfile="$rows_tmp" -v nraw="$nraw" '
    /^STAT\t/ { print; laststat = 1; next }
    laststat { printf "STAT\twhite\t%d\tSkipped no-subscription / http lines\n", nraw; laststat = 0 }
    /^SUMMARY\t/ && !spliced {
        printf "TABLE\tNo subscription / http — skipped transfer records\twide\n"
        printf "HEAD\tDate & time\tReason\tStatus\tAccount\tLogin\tDirection\tProtocol\tFile\tSize\tCoreId\n"
        printf "KIND\ttext\ttext\ttext\ttext\ttext\ttext\ttext\tfile\tnum\tmono\n"
        n = 0
        while ((getline l < rowsfile) > 0) { print l; n++ }
        close(rowsfile)
        if (n == 0) printf "ROW\t@{class=desc}(none — every CoreId got a subscription attributed and none ran over http)\t\t\t\t\t\t\t\t\t\n"
        printf "TOTAL\tTotal (%d record(s))\t\t\t\t\t\t\t\t\t\n", n
        printf "NOTE\tThe RAW transfer-log records of the CoreIds dropped at parse time because **no leg** carried a subscription or even an **account** (after the propagation and config/xref/flow-direction fallbacks — a record with an account is never dropped: it keeps the synthetic subscription **UCx_account** and counts everywhere except First seen and the coverage figures), or because a leg ran over **http** (web-UI hand traffic, never flow traffic). Kept verbatim in data/<env>/transfer/_skipped.csv; no other report counts these. Reason **http** = the CoreId has an http leg; otherwise **no subscription**.\n"
        spliced = 1
    }
    { print }
' "$REPORTS_DIR/skipped.rpt.tmp" > "$REPORTS_DIR/skipped.rpt.tmp.$$"
mv "$REPORTS_DIR/skipped.rpt.tmp.$$" "$REPORTS_DIR/skipped.rpt"
rm -f "$rows_tmp" "$REPORTS_DIR/skipped.rpt.tmp"

echo "Data written to $REPORTS_DIR/skipped.rpt (+ $(ls "$REPORTS_DIR"/skipped-*.rpt 2>/dev/null | wc -l | tr -d ' ') per-value report(s), $nraw no-subscription/http line(s))." >&2
