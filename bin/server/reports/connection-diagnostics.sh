#!/usr/bin/env bash
#
# connection-diagnostics.sh — WHY and WHERE outbound connections fail, plus the
# explicit partner test-connections. The Connection Failures report counts the
# same "Connection failure while <SITE> tried to connect …" messages per
# SUBSCRIPTION; this one is the complementary view they lack:
#   Failure reasons  the reason tail classified (Timeout / Bad certificate /
#                    Incompatible security protocols / Algorithm negotiation /
#                    Connection refused / generic SSH exception / Other).
#   By remote host   per partner endpoint (the physical host, not the
#                    subscription), with its dominant failure reason.
#   Test connections the proactive "Performs test connection for <proto> protocol"
#                    admin/API checks, by protocol.
#
# Also folds in the "Connection to <host> could not be established due to
# incompatible security protocols" message (a different shape, same intent).
#
# Reads the parse cache (data/_parse.tsv). Writes data/connection-diagnostics.rpt.
#
# Usage:
#   ./connection-diagnostics.sh   # reads input/*.csv (via the cache), writes data/connection-diagnostics.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/connection-diagnostics.rpt"

# Entity cross-links: every host with a detail page links to it. The roster =
# the CONFIGURED hosts (base cache, written in build step 1) ∪ the
# transfer-seen hosts (the Remote Host report's first table, a phase-1
# report) — both exist BEFORE the server pool. Matched CASE-FOLDED: this
# table shows the host as logged, and the server occasionally logs an
# endpoint uppercased while endpoints are canonically lowercase (2026-08-15
# audit D4: the old roster was the seen table alone, exact-case —
# configured-only hosts and case-variant spellings stayed unlinked). NOT the
# details slugmap: details.sh rewrites it in the background BESIDE this pool
# (the documented phase overlap), which raced to an empty roster. The alink
# resolves through the slugmap at render time, so a roster name without a
# page degrades to plain text; the cell keeps the logged spelling.
THOST="$TRANSFER_REPORTS/remote-host.rpt"
HBASE="$DATA/flow-manager/base/_hosts.tsv"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
base_names() {     # $1 base cache — every configured host
    [ -f "$1" ] || return 0
    awk -F'\t' '$1 != "" { print "KH\t" $1 }' "$1"
}
# LINK_AWK — slug() matches bin/publish_lib.sh's slugify (the same function as
# entity-search.sh's SLUG_AWK); hostlink() returns the @{alink=…} cell prefix
# for a page-bearing host, or "" when it stays unresolved.
LINK_AWK='
    function slug(x){ x=tolower(x); gsub(/[^a-z0-9]+/,"-",x); sub(/^-+/,"",x); sub(/-+$/,"",x); return x }
    function hostlink(t) { return (tolower(t) in khost) ? "@{alink=hosts/" khost[tolower(t)] "}" : "" }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$THOST" "$HBASE"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass. Emits TAB-separated:
#   R <TAB> reason <TAB> count <TAB> share <TAB> buckets(date:count) <TAB> loglines
#   H <TAB> host <TAB> count <TAB> topreason <TAB> first <TAB> last <TAB> buckets(date:count) <TAB> loglines
#   T <TAB> protocol <TAB> count <TAB> buckets(date:count) <TAB> loglines
#   F <TAB> got <TAB> expected <TAB> count <TAB> first <TAB> last <TAB> buckets <TAB> loglines   (host-key mismatches)
#   E <TAB> reason <TAB> count <TAB> share <TAB> first <TAB> last <TAB> buckets <TAB> loglines   (test-connection errors)
#   FT <TAB> fp_total <TAB> fp_pairs <TAB> top_got <TAB> top_got_expected_keys <TAB> top_got_count
#   ET <TAB> err_total <TAB> nreasons <TAB> top_attempt_day <TAB> its_count <TAB> top_error_day <TAB> its_count
#   TOT <TAB> failures <TAB> nreasons <TAB> nhosts <TAB> tests
agg=$(awk -F'\t' "$LOGLINES_AWK$LINK_AWK"'
    $1 == "KH" { khost[tolower($2)] = $2; next }             # page-bearing hosts: folded key -> canonical spelling (first input)
    {
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        line = lvlname($3) " " compname($4) "  " substr(m, 1, 200)

        if (m ~ /^Connection failure while / || m ~ /^Connection to .* could not be established/) {
            ml = tolower(m)
            if (m ~ /bad_certificate/)                          r = "Bad certificate"
            else if (m ~ /incompatible security protocols/)     r = "Incompatible security protocols"
            else if (ml ~ /connection refused/)                 r = "Connection refused"
            else if (ml ~ /timed out|timeout/)                  r = "Timeout"
            else if (ml ~ /no route to host/)                   r = "No route to host"
            else if (ml ~ /unknownhost|name or service not known|unknown host/) r = "Unknown host"
            else if (ml ~ /failed to negotiate|no common|algorithm|kex /) r = "Algorithm negotiation"
            else if (m ~ /SshException/)                        r = "SSH exception (generic)"
            else                                                r = "Other"

            h = "(unknown)"
            if (match(m, /remote host [^: ]+/)) h = substr(m, RSTART+12, RLENGTH-12)
            else if (match(m, /^Connection to [^: ]+/)) h = substr(m, RSTART+14, RLENGTH-14)
            h = tolower(h)   # endpoints are canonically lowercase; the server occasionally logs one uppercased (see the header) — one row per endpoint, not per spelling

            tfail++
            rc[r]++; if (d!="") rd[r SUBSEP d]++
            hc[h]++; if (d!="") hd[h SUBSEP d]++
            hr[h SUBSEP r]++
            if (d!="") { if (!(h in hfst)||d<hfst[h]) hfst[h]=d; if (!(h in hlst)||d>hlst[h]) hlst[h]=d }
            addline("R" SUBSEP r, $1 " " $2, line); addline("H" SUBSEP h, $1 " " $2, line)
        } else if (tolower(m) ~ /performs test connection/) {
            p = "(unknown)"; if (match(m, /for [a-z]+ protocol/)) p = substr(m, RSTART+4, RLENGTH-13)
            ttest++; tc[p]++; if (d!="") { td[p SUBSEP d]++; tad[d]++ }
            addline("T" SUBSEP p, $1 " " $2, line)
        } else if (m ~ /^Error during test connection/) {
            # the explicit test-connection failures: the reason is the message
            # tail after the fixed prefix, shown as logged (trimmed)
            r2 = m; sub(/^Error during test connection\.? */, "", r2)
            sub(/[. ]+$/, "", r2); r2 = substr(r2, 1, 90)
            if (r2 == "") r2 = "(no reason given)"
            terr++; ec[r2]++
            if (d != "") { ed[r2 SUBSEP d]++; ted[d]++
                if (efst[r2] == "" || d < efst[r2]) efst[r2] = d
                if (d > elst[r2]) elst[r2] = d }
            addline("E" SUBSEP r2, $1 " " $2, line)
        } else if (m ~ /^Wrong server fingerprint: got /) {
            # host-key mismatches: the presented (got) vs the stored expected
            # fingerprint; the got value is occasionally truncated in the log
            # and is kept as logged
            g2 = ""; x2 = ""
            if (match(m, /got [^,]+,/))     g2 = substr(m, RSTART + 4, RLENGTH - 5)
            if (match(m, /expected [^.]+/)) x2 = substr(m, RSTART + 9, RLENGTH - 9)
            if (g2 == "") g2 = "(unlogged)"
            if (x2 == "") x2 = "(unlogged)"
            fk = g2 SUBSEP x2
            fpn++; fc[fk]++; gcnt[g2]++
            if (!(fk in gseen)) { gseen[fk] = 1; gexp[g2]++ }
            if (d != "") { fdd[fk SUBSEP d]++
                if (ffst[fk] == "" || d < ffst[fk]) ffst[fk] = d
                if (d > flst[fk]) flst[fk] = d }
            addline("F" SUBSEP fk, $1 " " $2, line)
        }
    }
    END {
        # reason buckets
        for (x in rd) { split(x, a, SUBSEP); rbk[a[1]] = rbk[a[1]] (rbk[a[1]]?",":"") a[2] ":" rd[x] }
        # the share is field 4 — computed HERE, where the failure total already
        # is, not by an awk fork per row down in the shell
        nr=0; for (r in rc) { nr++; printf "R\t%s\t%d\t%.1f\t%s\t%s\n", r, rc[r], (tfail ? rc[r]*100/tfail : 0), rbk[r], lastlines("R" SUBSEP r) }
        # host buckets + dominant reason
        for (x in hd) { split(x, a, SUBSEP); hbk[a[1]] = hbk[a[1]] (hbk[a[1]]?",":"") a[2] ":" hd[x] }
        nh=0
        for (h in hc) { nh++
            # dominant reason; count ties break on the name so the pick never
            # depends on awk hash-iteration order
            best=""; bestn=-1
            for (x in hr) { split(x, a, SUBSEP); if (a[1]==h && (hr[x]>bestn || (hr[x]==bestn && a[2]<best))) { bestn=hr[x]; best=a[2] } }
            printf "H\t%s%s\t%d\t%s\t%s\t%s\t%s\t%s\n", hostlink(h), h, hc[h], best, hfst[h], hlst[h], hbk[h], lastlines("H" SUBSEP h)
        }
        # test-connection buckets
        for (x in td) { split(x, a, SUBSEP); tbk[a[1]] = tbk[a[1]] (tbk[a[1]]?",":"") a[2] ":" td[x] }
        for (p in tc) printf "T\t%s\t%d\t%s\t%s\n", p, tc[p], tbk[p], lastlines("T" SUBSEP p)
        # host-key mismatch pairs (fk = got SUBSEP expected)
        for (x in fdd) { split(x, a, SUBSEP); kk = a[1] SUBSEP a[2]; fbk[kk] = fbk[kk] (fbk[kk]?",":"") a[3] ":" fdd[x] }
        nfp = 0
        for (k in fc) { nfp++; split(k, a, SUBSEP)
            printf "F\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n", a[1], a[2], fc[k], ffst[k], flst[k], fbk[k], lastlines("F" SUBSEP k) }
        # the dominant presented key (count ties break on the value, never hash order)
        bg = ""; bgn = -1
        for (g in gcnt) if (gcnt[g] > bgn || (gcnt[g] == bgn && g < bg)) { bgn = gcnt[g]; bg = g }
        printf "FT\t%d\t%d\t%s\t%d\t%d\n", fpn+0, nfp+0, bg, gexp[bg]+0, (bgn < 0 ? 0 : bgn)
        # test-connection error reasons + the top attempt/error days
        for (x in ed) { split(x, a, SUBSEP); ebk[a[1]] = ebk[a[1]] (ebk[a[1]]?",":"") a[2] ":" ed[x] }
        nrs = 0
        for (r in ec) { nrs++
            printf "E\t%s\t%d\t%.1f\t%s\t%s\t%s\t%s\n", r, ec[r], (terr ? ec[r]*100/terr : 0), efst[r], elst[r], ebk[r], lastlines("E" SUBSEP r) }
        bad = ""; badn = -1; for (x in tad) if (tad[x] > badn || (tad[x] == badn && x < bad)) { badn = tad[x]; bad = x }
        bed = ""; bedn = -1; for (x in ted) if (ted[x] > bedn || (ted[x] == bedn && x < bed)) { bedn = ted[x]; bed = x }
        printf "ET\t%d\t%d\t%s\t%d\t%s\t%d\n", terr+0, nrs+0, bad, (badn < 0 ? 0 : badn), bed, (bedn < 0 ? 0 : bedn)
        printf "TOT\t%d\t%d\t%d\t%d\n", tfail+0, nr+0, nh+0, ttest+0
    }
' <(known_names KH "$THOST"; base_names "$HBASE") "$PARSED")

IFS=$'\t' read -r _ t_fail n_reason n_host t_test <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${t_fail:-0}" -eq 0 ]; then
    echo "No connection-diagnostics messages found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
n_tproto=$(printf '%s\n' "$agg" | grep -c $'^T\t' || true)

# The three row writers print STRAIGHT to stdout inside the page block below —
# a `rows+=$(printf …)` per row forks a subshell per row for nothing.
reason_rows() {
    while IFS=$'\t' read -r _ reason count share bk lines; do
        [ -z "$reason" ] && continue
        printf 'ROW\t%s\t%s\t%s%%\t@data:buckets=%s\t@data:loglines=%s\n' "$reason" "$count" "$share" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^R\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

host_rows() {
    while IFS=$'\t' read -r _ host count top fst lst bk lines; do
        [ -z "$host" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$host" "$count" "$top" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^H\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

test_rows() {
    while IFS=$'\t' read -r _ proto count bk lines; do
        [ -z "$proto" ] && continue
        printf 'ROW\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$proto" "$count" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^T\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

# The two 2026-08 tables (host-key mismatches + test-connection outcomes) are
# emitted UNCONDITIONALLY: this report is a merged-component of Connections,
# whose tab bar enumerates tables, so the TABLE count must not vary per env —
# an empty family renders the placeholder row instead.
IFS=$'\t' read -r _ fp_tot fp_pairs fp_topgot fp_topexp fp_topcnt <<< "$(printf '%s\n' "$agg" | grep $'^FT\t' || printf 'FT\t0\t0\t\t0\t0\n')"
IFS=$'\t' read -r _ te_err te_reasons te_topday te_topdayn te_errday te_errdayn <<< "$(printf '%s\n' "$agg" | grep $'^ET\t' || printf 'ET\t0\t0\t\t0\t\t0\n')"

fp_rows() {
    while IFS=$'\t' read -r _ got expd count fst lst bk lines; do
        [ -z "$got" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$got" "$expd" "$count" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^F\t' | sort -t"$(printf '\t')" -k4,4nr -k2,2 -k3,3)"
}

terr_rows() {
    while IFS=$'\t' read -r _ reason count share fst lst bk lines; do
        [ -z "$reason" ] && continue
        printf 'ROW\t%s\t%s\t%s%%\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$reason" "$count" "$share" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^E\t' | sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

{
    printf 'TITLE\tConnection Diagnostics\n'
    printf 'DESC\tWhy and where outbound connections fail — the failure-reason breakdown and per-remote-host view that Connection Failures (counted per subscription) does not provide, plus the explicit partner test connections.\n'
    printf 'INTRO\t**%s** outbound connection failure(s) classified into **%s** reason(s) across **%s** remote host(s), plus **%s** explicit test-connection attempt(s). Connection Failures counts these per subscription; this answers **why** (reason) and **where** (host). Click a row for its 10 most recent messages.\n' \
        "$t_fail" "$n_reason" "$n_host" "$t_test"

    printf 'TABLE\tFailure reasons\twide\n'
    printf 'HEAD\tReason\tFailures\tShare\n'
    printf 'KIND\ttext\tnumfailed\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    reason_rows
    printf 'TOTAL\tTotal (%s reason(s))\t@{class=num failed}%s\t@{class=num}100.0%%\n' "$n_reason" "$t_fail"
    printf 'NOTE\tThe reason is classified from the failure tail. "SSH exception (generic)" is a com.maverick.ssh.SshException without a more specific cause (often a reset/aborted SSH connection); Timeout, Bad certificate, Incompatible security protocols and Algorithm negotiation each point at a different fix. Failures and share re-aggregate over the selected dates.\n'

    printf 'TABLE\tBy remote host\twide\n'
    printf 'HEAD\tRemote host\tFailures\tTop reason\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnumfailed\ttext\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    host_rows
    printf 'TOTAL\tTotal (%s host(s))\t@{class=num failed}%s\t\t\t\n' "$n_host" "$t_fail"
    printf 'NOTE\tThe physical partner endpoint (host, not subscription — a host can serve several subscriptions), with the reason that dominates its failures. Shown as logged; a host with a detail page links to it (matched case-insensitively — the canonical endpoint spelling is lowercase). Click a host for its 10 most recent failures.\n'

    printf 'TABLE\tTest connections\n'
    printf 'HEAD\tProtocol\tAttempts\n'
    printf 'KIND\ttext\tnum\n'
    printf 'RECALC\t-\ts0\n'
    test_rows
    printf 'TOTAL\tTotal (%s protocol(s))\t@{class=num}%s\n' "$n_tproto" "$t_test"
    printf 'NOTE\tExplicit "Performs test connection for <protocol> protocol" checks — an admin/API testing a partner configuration before real transfers.\n'

    # ---- host-key mismatches (2026-08) ----
    if [ "${fp_tot:-0}" -gt 0 ]; then
        printf 'TABLE\tHost-key mismatches\twide\n'
    else
        printf 'TABLE\tHost-key mismatches\tnofilter\tnosort\n'
    fi
    printf 'HEAD\tPresented fingerprint\tExpected fingerprint\tWarnings\tFirst\tLast\n'
    printf 'KIND\tmono\tmono\tnumwarn\ttext\ttext\n'
    printf 'RECALC\t-\t-\ts0\t-\t-\n'
    if [ "${fp_tot:-0}" -gt 0 ]; then
        fp_rows
    else
        printf 'ROW\t@{colspan=5}No host-key mismatch warnings in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s pair(s))\t\t@{class=num warn}%s\t\t\n' "${fp_pairs:-0}" "${fp_tot:-0}"
    if [ -n "${fp_topgot:-}" ] && [ "${fp_topcnt:-0}" -gt 0 ]; then
        printf 'NOTE\tThe "Wrong server fingerprint: got X, expected Y" warnings, per fingerprint pair: a partner endpoint presenting an SSH host key that does not match the stored known-host entry. One presented key (`%s`) accounts for **%s** of the **%s** warning(s), checked against **%s** different expected keys — ONE endpoint presenting a NEW key that many stored entries no longer match (a server-side key rotation), not many endpoints drifting at once. A short "got" value is the log itself truncating; shown as logged. Click a pair for its 10 most recent warnings.\n' \
            "$fp_topgot" "$fp_topcnt" "$fp_tot" "$fp_topexp"
    else
        printf 'NOTE\tThe "Wrong server fingerprint: got X, expected Y" warnings, per fingerprint pair: a partner endpoint presenting an SSH host key that does not match the stored known-host entry.\n'
    fi

    # ---- test-connection outcomes (2026-08) ----
    if [ "${te_err:-0}" -gt 0 ]; then
        printf 'TABLE\tTest-connection outcomes\twide\n'
    else
        printf 'TABLE\tTest-connection outcomes\tnofilter\tnosort\n'
    fi
    printf 'HEAD\tError reason\tErrors\tShare\tFirst\tLast\n'
    printf 'KIND\ttext\tnumfailed\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t%%0\t-\t-\n'
    if [ "${te_err:-0}" -gt 0 ]; then
        terr_rows
    else
        printf 'ROW\t@{colspan=5}No test-connection errors in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s reason(s))\t@{class=num failed}%s\t@{class=num}100.0%%\t\t\n' "${te_reasons:-0}" "${te_err:-0}"
    if [ "${te_err:-0}" -gt 0 ]; then
        printf 'NOTE\tHow the **%s** explicit test connection(s) failed: the "Error during test connection" reason tail, as logged. Of the attempts, **%s** logged an explicit error; the busiest test day was **%s** (**%s** attempts) and the worst error day **%s** (**%s** errors) — narrow the date range to see a single campaign. "The host key was not accepted" pairs with the Host-key mismatches table above; the timeouts and negotiation failures pair with the Failure reasons table. Click a reason for its 10 most recent errors.\n' \
            "$t_test" "$te_err" "$te_topday" "$te_topdayn" "$te_errday" "$te_errdayn"
    else
        printf 'NOTE\tHow the explicit test connections failed: the "Error during test connection" reason tail, as logged.\n'
    fi

    printf 'SUMMARY\tConnection failures: %s  |  Reasons: %s  |  Remote hosts: %s  |  Test connections: %s  |  Test errors: %s  |  Host-key mismatches: %s\n' "$t_fail" "$n_reason" "$n_host" "$t_test" "${te_err:-0}" "${fp_tot:-0}"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_fail failure(s), $n_reason reason(s), $n_host host(s), $t_test test(s))." >&2
