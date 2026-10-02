#!/usr/bin/env bash
#
# skipped.sh — "Skipped" (an ANALYSES report published with the transfer pages,
# like entity-coverage.sh): the accounts and subscriptions IGNORED because
# their name matches the environment's skip list (input/skip.txt), plus a count of the
# transfer- and server-log records set aside for the same reason.
#
# Writes ONE report (skipped.rpt): a count per skip rule, then the skipped
# accounts, subscriptions and logins each in ONE table with the rule that
# caught them (2026-09-29: the per-value skipped-<slug> pages and the three
# tables per value went — the same rows, 15 tables and 5 pages for 5 rules).
#
# The actual filtering happens at PARSE time (see bin/flow-manager.sh,
# bin/transfer/parse.sh, bin/server/parse.sh); this report only reads the
# sidecars those steps leave behind:
#   data/flow-manager/filtered/_skipped.tsv   type<TAB>name  (Account / Subscription)
#   data/transfer/_skipped.tsv       the skipped _transfers.tsv rows
#   data/server/_skipped.tsv         the skipped _parse.tsv rows
# No date filter — a static audit of what the skip list removed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../transfer/lib.sh"
mkdir -p "$REPORTS_DIR"

CFG_SKIP="$CONFIG_DIR/filtered/_skipped.tsv"   # data/flow-manager/filtered/_skipped.tsv (type<TAB>name)
T_SKIP="$DATA/transfer/_skipped.tsv"       # skipped transfer records
S_SKIP="$DATA/server/_skipped.tsv"         # skipped server records
SKIPFILE="$ROOT/input/skip.txt" # the rules (per environment since 2026-08-31)
source "$ROOT/bin/skiplist.sh"             # SKIPLIST_AWK (sl_load/sl_match) — the ONE reader

# All the inputs are parse-time products (the two _skipped.tsv sidecars and the
# config sidecar) plus the rule file and its reader.


awk -F'\t' -v cfg="$CFG_SKIP" -v skf="$SKIPFILE" -v tfile="$T_SKIP" -v sfile="$S_SKIP" \
    -v outdir="$REPORTS_DIR" "$SKIPLIST_AWK"'
    function z9(v) { return (v + 0 == 0) ? "" : v + 0 }   # a 0 count shows empty (2026-09-30 audit)
    # which skip RULE (1..nt) does value V match first? 0 = none. The rules come
    # from bin/skiplist.sh, so a value here is caught by exactly the rule that
    # dropped it at parse time — including a field-specific or regex rule, which
    # a flat token scan could not express. Config NAMES are accounts and
    # subscriptions, so they are tested against those fields; a config LOGIN
    # (2026-09-03) against the login field.
    function tokof(v,   k) { k = sl_match("account", v); return k ? k : sl_match("site", v) }
    function tokofl(v) { return sl_match("login", v) }
    BEGIN {
        sl_load(skf)
        nt = SL_N; tokens = ""
        for (ti = 1; ti <= nt; ti++) {
            ORIG[ti] = SL_RAW[ti]
            tokens = tokens (tokens == "" ? "" : ", ") SL_RAW[ti]
        }
        # config sidecar -> per-token accounts / subscriptions (attributed to the
        # first matching token; also kept in overall order for the All page)
        if (cfg != "") {
            while ((getline l < cfg) > 0) {
                n = split(l, a, "\t"); if (n < 2 || a[2] == "") continue
                if (a[1] == "Login") { k = tokofl(a[2]); if (k > 0) LOG[k, ++nlog[k]] = a[2]; continue }
                k = tokof(a[2]); if (k == 0) continue
                if (a[1] == "Account")           { ACC[k, ++nacc[k]] = a[2] }
                else if (a[1] == "Subscription") { SUB[k, ++nsub[k]] = a[2] }
            }
            close(cfg)
        }
        # transfer sidecar -> per-rule record counts, by the fields the
        # transfer parse tests (bin/transfer/parse.sh: account col 4, LOGIN
        # col 5, site col 6 — 2026-09-29 audit: the login rules were never
        # counted here, and account/site rules were tried on the wrong column)
        if (tfile != "") {
            while ((getline l < tfile) > 0) {
                n = split(l, a, "\t")
                k = sl_match("account", a[4]); if (k == 0) k = sl_match("login", a[5]); if (k == 0) k = sl_match("site", a[6])
                if (k > 0) tcnt[k]++
            }
            close(tfile)
        }
        # server sidecar -> per-rule record counts: the server parse tests the
        # MESSAGE (col 5) with the message / any rules (bin/server/parse.sh)
        if (sfile != "") {
            while ((getline l < sfile) > 0) {
                n = split(l, a, "\t"); k = sl_match("message", a[5]); if (k > 0) scnt[k]++
            }
            close(sfile)
        }

        # ---- the OVERVIEW report (skipped.rpt): totals + a section per value.
        # Written as .rpt.tmp — the splice pass below reads it and publishes the
        # final skipped.rpt atomically, so a killed run never leaves a truncated
        # report. ----
        main = outdir "/skipped.rpt.tmp"
        printf "TITLE\tSkipped\n" > main
        # totals across all values
        for (i = 1; i <= nt; i++) { TA += nacc[i]; TS += nsub[i]; TL += nlog[i]; TT += tcnt[i]; TV += scnt[i] }
        printf "STAT\twhite\t%d\tSkipped accounts\n", TA + 0 > main
        printf "STAT\twhite\t%d\tSkipped subscriptions\n", TS + 0 > main
        printf "STAT\twhite\t%d\tSkipped logins\n", TL + 0 > main
        printf "STAT\twhite\t%d\tSkipped transfer log lines\n", TT + 0 > main
        printf "STAT\twhite\t%d\tSkipped server log lines\n", TV + 0 > main

        # the per-rule counts, then one table per kind with the rule column
        printf "TABLE\tSkip rules\tnosort\tkeephead\n" > main
        printf "HEAD\tRule\tAccounts\tSubscriptions\tLogins\tTransfer log lines\tServer log lines\n" > main
        printf "KIND\ttext\tnum\tnum\tnum\tnum\tnum\n" > main
        if (nt == 0) printf "ROW\t(none — the skip list is empty)\t\t\t\t\t\n" > main
        for (i = 1; i <= nt; i++)
            printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\n", ORIG[i], z9(nacc[i]), z9(nsub[i]), z9(nlog[i]), z9(tcnt[i]), z9(scnt[i]) > main   # a 0 count blank (2026-09-30 audit)
        printf "TOTAL\tTotal (%d rule%s)\t%s\t%s\t%s\t%s\t%s\n", nt, (nt == 1 ? "" : "s"), z9(TA), z9(TS), z9(TL), z9(TT), z9(TV) > main
        emit_kind(main, "accounts", "Account", nacc, ACC)
        emit_kind(main, "subscriptions", "Subscription", nsub, SUB)
        # the comm-profile logins a LOGIN rule dropped from the configuration
        # (bin/flow-manager.sh, 2026-09-03) — with them go their detail pages
        emit_kind(main, "logins", "Login", nlog, LOG)
        printf "SUMMARY\tSkipped: %d account(s), %d subscription(s), %d login(s), %d transfer line(s), %d server line(s) across %d value(s)\n", TA+0, TS+0, TL+0, TT+0, TV+0, nt > main
        printf "FOOT\n" > main
        close(main)
    }
    # one table of every skipped name of a kind, each with the rule that caught it
    function emit_kind(f, plural, head, cnt, NAME,   i, j, n) {
        printf "TABLE\tSkipped %s\tnosort\n", plural > f
        printf "HEAD\t%s\tRule\n", head > f
        printf "KIND\ttext\ttext\n" > f
        n = 0
        for (i = 1; i <= nt; i++) for (j = 1; j <= cnt[i]; j++) { printf "ROW\t%s\t%s\n", NAME[i, j], ORIG[i] > f; n++ }
        if (n == 0) printf "ROW\t(none — no configured %s matched a rule)\t\n", tolower(head) > f
        printf "TOTAL\tTotal (%d %s)\t\n", n, (n == 1 ? tolower(head) : plural) > f
    }
' </dev/null

# (The NO-SUBSCRIPTION / HTTP / EMPTY PROBE table — the raw records
# bin/transfer/parse.sh sets aside in data/transfer/_skipped.csv before any
# File is formed — and its STAT box left this page 2026-10-02, user request:
# "Rows that are not because of skip.txt must go to /transfer/unknown-
# transfers.html or to /transfer/pirates-details.html". No skip.txt rule is
# involved in them: Unknown transfers lists the no-subscription / http
# records, One-legged › Details the empty ssh probes —
# bin/transfer/dropped-records.sh.)
mv "$REPORTS_DIR/skipped.rpt.tmp" "$REPORTS_DIR/skipped.rpt"

echo "Data written to $REPORTS_DIR/skipped.rpt." >&2
