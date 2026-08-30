#!/usr/bin/env bash
#
# no-remote-dir.sh — "No remote dir": we reach the partner, but the REMOTE
# DIRECTORY the subscription is configured to read does not exist. From the TM
# error
#
#   [Error during transfer operation: ]Error occurred while listing files from
#   partner <SITE> defined in account <ACCOUNT>. No such file[: '<PATH>'[: No such file.]]
#
# The connection itself worked (we authenticated and asked for a listing), so
# this is a CONFIGURATION fault on one side — the path was renamed, the partner
# never created it, or the account is chrooted elsewhere — not an outage. It
# never reaches the transfer logs: a listing that fails starts no transfer, so
# the flow simply looks silent there.
#
# The reason tail decides: only "No such file" rows are counted here. The other
# listing failures (Permission denied, …) are counted per subscription by the
# Remote Polls report, which also covers the polls that DO list a directory.
#
# The logged site keeps its "_SCP_…" suffix; we truncate it to the clean
# subscription name (as the transfer parser does), shown as logged (mono; a
# name resolving against the transfer-side lists links to its detail page).
#
# Reads the parse cache (data/_parse.tsv: 1=date, 2=time, 3=level, 5=message).
# Writes data/no-remote-dir.rpt.
#
# Usage:
#   ./no-remote-dir.sh   # reads input/*.csv (via the cache), writes data/no-remote-dir.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SERVER lib, not the analyses one: this is a server-DATA report (it reads the
# server parse cache and writes data/<env>/server/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/no-remote-dir.rpt"

# Entity cross-links: known account/subscription names from the transfer-side
# reports (ROW field 2 of each report's FIRST table). A resolved name gets an
# @{alink=…} prefix on its cell; unresolved names stay plain text.
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
TSITE="$TDATA/subscription.rpt"
FILESC="$TRANSFER_CACHE/_files.tsv"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# The RESOLVED filter: per subscription, the sortkey of its LAST OK File
# (_files.tsv col 12 = subscription, 6 = sortkey "YYYYMMDDhh:mm:ss.mmm",
# 2 = outcome — OK is the site-wide "not Failed/Expired", which on these pull
# flows is exactly Processed). A row whose last error PRECEDES that File is
# dropped: the directory was found again afterwards, so it is fixed, not broken.
last_ok_files() {   # emits "KF<TAB>subscription<TAB>sortkey" lines
    [ -f "$FILESC" ] || return 0
    awk -F'\t' '$12 != "" && $2 != "Failed" && $2 != "Expired" { if ($6 > m[$12]) m[$12] = $6 }
                END { for (s in m) print "KF\t" s "\t" m[s] }' "$FILESC"
}
# sitelink(): exact match or unique prefix of one known subscription (the server
# truncates long names; same rule as site-failures.sh) — and, like remote-poll.sh,
# an unresolved name still tries the RAW one: a subscription whose listing always
# fails has no transfer data to appear in the roster, yet it has a detail page
# from the config (alink resolves through the comprehensive slugmap at render
# time, so a genuine miss simply renders unlinked). acctlink(): exact match, also
# @endpoint-stripped.
LINK_AWK='
    # RENAMES (2026-08): a server line keeps the name that was current when it
    # was written, so fold it to the CURRENT one before matching the roster —
    # which carries current names, the transfer parse having folded them — and
    # DISPLAY the folded name, so the page names the flow as the configuration
    # does. rn_canon_pfx also covers the truncated old spelling the server
    # writes, folding only when every completion agrees.
    function sitecanon(t,   k, hits, full, c) {
        c = rn_canon_pfx(t)
        if (c in ksite) return c
        hits = 0
        for (k in ksite) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) { hits = 0; break } }
        return hits == 1 ? full : c
    }
    function sitelink(t,   k, hits, full) {
        t = sitecanon(t)
        if (t in ksite) return "@{alink=subscriptions/" t "}"
        hits = 0
        for (k in ksite) if (index(k, t) == 1) { hits++; full = k; if (hits > 1) { hits = 0; break } }
        return hits == 1 ? "@{alink=subscriptions/" full "}" : "@{alink=subscriptions/" t "}"
    }
    function acctlink(t,   s) {
        if (t in kacct) return "@{alink=accounts/" t "}"
        s = t; sub(/@.*$/, "", s)
        if (s in kacct) return "@{alink=accounts/" s "}"
        return ""
    }
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
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TACCT" "$TSITE" "$FILESC"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the failed listings. The site may CONTAIN spaces ("Clone - UC3_…"),
# so it is captured up to the " defined in account " anchor, and the account up to
# the "." that opens the reason. Emits TAB-separated (the loglines drill LAST, it
# carries the raw message):
#   DIR <TAB> count <TAB> subscription <TAB> account <TAB> path <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   DAY <TAB> date <TAB> count <TAB> nsubs
#   TOT <TAB> errors <TAB> nsubs <TAB> naccounts <TAB> npaths <TAB> ndays <TAB> resolved rows <TAB> resolved errors
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK"'
    BEGIN { rn_load(RNF) }
    BEGIN { US = sprintf("%c", 31) }                         # the lines/clines cell separator
    $1 == "KA" { kacct[$2] = 1; next }                       # known-account list       (first input)
    $1 == "KS" { ksite[$2] = 1; next }                       # known-subscription list  (first input)
    $1 == "KF" { okmax[$2] = $3; next }                      # last OK File per subscription (first input)
    # A SUCCESSFUL listing on the same site: "Applying the search pattern … for
    # transfer site SITE: N file(s) were found of which M matched" — the poll
    # reached the directory, even when it downloaded nothing. On a UC3 (pull)
    # flow that is the recovery proof an empty poll can never leave in the
    # transfer log, so the last one per site is kept alongside the last OK File.
    $5 ~ /Applying the search pattern .* for transfer site / {
        if (!match($5, /for transfer site '\''[^'\'']*'\''/)) next
        psite = substr($5, RSTART + 19, RLENGTH - 20); sub(/_(SS?|C)CP_.*$/, "", psite)
        pd = substr($1, 1, 10)
        if (psite != "" && pd ~ /^[0-9][0-9][0-9][0-9]-/) {
            psk = substr(pd, 1, 4) substr(pd, 6, 2) substr(pd, 9, 2) $2
            if (psk > pollmax[psite]) pollmax[psite] = psk
        }
        next
    }
    $5 !~ /listing files from partner / { next }
    {
        m = $5
        # only the missing-directory reason — the other listing failures
        # (Permission denied, …) belong to the Remote Polls report
        if (m !~ /No such file/) next
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        rest = substr(m, index(m, "listing files from partner ") + 27)
        p = index(rest, " defined in account "); if (p <= 1) next
        site = substr(rest, 1, p - 1); sub(/_(SS?|C)CP_.*$/, "", site)   # clean subscription name
        if (site == "") next
        tail = substr(rest, p + 20)
        q = index(tail, ".")                                  # "ACCOUNT. No such file…"
        acct = (q > 1) ? substr(tail, 1, q - 1) : tail
        if (acct == "") acct = "(unknown)"
        # the path: everything after "No such file: ", minus the quotes the
        # SFTP variant adds and its repeated ": No such file." tail
        path = ""
        r = index(tail, "No such file: ")
        if (r > 0) {
            path = substr(tail, r + 14)
            sub(/: No such file\.?[[:space:]]*$/, "", path)
            gsub(/^'\''|'\''$/, "", path)
            sub(/[[:space:]]+$/, "", path)
        }
        if (path == "") path = "(not logged)"
        k = site SUBSEP acct SUBSEP path
        c[k]++
        # the drill is per SUBSCRIPTION (one row each), so the lines collect
        # under the site: its 10 most recent failed listings, any directory
        addline("S" SUBSEP site, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        if (d != "") {
            # the last-error sortkey, in the _files.tsv shape (YYYYMMDDhh:mm:ss.mmm)
            sk = substr(d, 1, 4) substr(d, 6, 2) substr(d, 9, 2) $2
            if (sk > lsk[k]) lsk[k] = sk
            cd[k SUBSEP d]++
            if (!(k in fst) || d < fst[k]) fst[k] = d
            if (!(k in lst) || d > lst[k]) lst[k] = d
        }
    }
    END {
        # drop every row the subscription RECOVERED from, on either proof dated
        # after this row own last error: an OK File (any flow), or — UC3 only,
        # where a poll that finds nothing leaves no transfer record at all — a
        # successful listing of that same site. The figures are summed over the
        # SURVIVORS only, so the totals, the per-day table and the INTRO all
        # describe what the page shows.
        for (k in c) { split(k, a, SUBSEP)
            if (lsk[k] != "" && (a[1] in okmax) && okmax[a[1]] > lsk[k]) { nres++; nresf++; reserr += c[k]; continue }
            if (lsk[k] != "" && a[1] ~ /^UC3/ && (a[1] in pollmax) && pollmax[a[1]] > lsk[k]) { nres++; nresp++; reserr += c[k]; continue }
            keep[k] = 1; tot += c[k]
            sseen[a[1]] = 1; aseen[a[2]] = 1; pseen[a[3]] = 1
        }
        # ONE ROW PER SUBSCRIPTION: fold the surviving (subscription, directory)
        # keys onto their site — errors summed, per-day buckets merged, Last =
        # the newest error of any of its directories, and the directories
        # themselves stacked newest-first in one clines cell (a subscription
        # pointed at several spellings of a path keeps all of them visible)
        for (k in keep) { split(k, a, SUBSEP); s = a[1]
            secnt[s] += c[k]
            if (lst[k] > selst[s]) selst[s] = lst[k]
            if (lsk[k] > sesk[s]) sesk[s] = lsk[k]
            # insert the directory by its own last error, newest first, deduped
            if (!((s SUBSEP a[3]) in pdone)) { pdone[s, a[3]] = 1
                np = split(sedir[s], dz, US); ins = np + 1
                for (i = 1; i <= np; i++) if (lsk[k] > pkey[s SUBSEP dz[i]]) { ins = i; break }
                out = ""
                for (i = 1; i <= np + 1; i++) {
                    if (i == ins) out = out (out == "" ? "" : US) a[3]
                    if (i <= np) out = out (out == "" ? "" : US) dz[i]
                }
                sedir[s] = out; pkey[s, a[3]] = lsk[k] }
        }
        for (x in cd) { split(x, a, SUBSEP); kk = a[1] SUBSEP a[2] SUBSEP a[3]
            if (!(kk in keep)) continue
            sbk[a[1] SUBSEP a[4]] += cd[x]
            dc[a[4]] += cd[x]
            if (!((a[4] SUBSEP a[1]) in dsseen)) { dsseen[a[4], a[1]] = 1; dsn[a[4]]++ } }
        for (x in sbk) { split(x, a, SUBSEP)
            bk[a[1]] = bk[a[1]] (bk[a[1]] ? "," : "") a[2] ":" sbk[x] }
        for (s in secnt)
            printf "DIR\t%d\t%s\t%s%s\t%s\t%s\t%s\n", secnt[s], selst[s], sitelink(s), sitecanon(s), sedir[s], bk[s], lastlines("S" SUBSEP s)
        nday = 0
        for (d in dc) { nday++; printf "DAY\t%s\t%d\t%d\n", d, dc[d], dsn[d] }
        nsub = 0; for (x in sseen) nsub++
        nacc = 0; for (x in aseen) nacc++
        npath = 0; for (x in pseen) npath++
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", tot+0, nsub+0, nacc+0, npath+0, nday+0, nres+0, reserr+0, nresf+0, nresp+0
    }
' <(known_names KA "$TACCT"; known_names KS "$TSITE"; last_ok_files) "$PARSED")

IFS=$'\t' read -r _ tot_err n_sub n_acc n_path n_day n_res n_reserr n_resfile n_respoll <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${tot_err:-0}" -eq 0 ]; then
    echo "No OPEN missing-remote-directory errors (${n_res:-0} resolved since)." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

# Both row writers print STRAIGHT to stdout inside the page block below — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
dir_rows() {
    while IFS=$'\t' read -r _ count last site path bk lines; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$last" "$site" "$path" "$count" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^DIR\t' | sort -t"$(printf '\t')" -k3,3r -k2,2nr)"
}

day_rows() {
    while IFS=$'\t' read -r _ date count nsubs; do
        [ -z "$date" ] && continue
        printf 'ROW\t%s\t%s\t%s\n' "$date" "$count" "$nsubs"
    done <<< "$(printf '%s\n' "$agg" | grep $'^DAY\t' | sort -t"$(printf '\t')" -k2,2)"
}

{
    printf 'TITLE\tNo remote dir\n'
    printf 'DESC\tSubscriptions whose configured REMOTE directory does not exist — we reach the partner, the listing fails with "No such file".\n'
    printf 'KEYWORDS\tno such file,missing directory,remote directory,listing,scan directory,path,configuration fault\n'
    intro_res=""
    if [ "${n_res:-0}" -gt 0 ]; then
        intro_res=$(printf ' **%s** further director(y/ies) (**%s** error(s)) are NOT listed — the flow recovered afterwards: **%s** proven by a later OK File, **%s** by a later successful listing of that same UC3 site (a poll that finds nothing leaves no transfer record, so the server log is the only witness).' \
            "$n_res" "$n_reserr" "${n_resfile:-0}" "${n_respoll:-0}")
    fi
    printf 'INTRO\tWe reached the partner and asked for a directory listing, and the partner answered **No such file**: the configured REMOTE directory is not there. **%s** failed listing(s) over **%s** day(s), across **%s** subscription(s), **%s** account(s) and **%s** distinct director(y/ies) — all still UNRESOLVED.%s The connection itself is fine, so this is a **configuration fault** — a renamed or never-created path, or an account chrooted somewhere else — and it never shows in the transfer logs: a listing that fails starts no transfer, so the flow just looks silent there.\n' \
        "$tot_err" "$n_day" "$n_sub" "$n_acc" "$n_path" "$intro_res"

    printf 'TABLE\tMissing remote directories\twide\n'
    printf 'HEAD\tLast\tSubscription\tRemote directory\tErrors\n'
    printf 'KIND\ttext\tmono\tclines\tnumfailed\n'
    printf 'RECALC\t-\t-\t-\ts0\n'
    dir_rows
    printf 'TOTAL\t@{colspan=3}Total (%s subscription(s) · %s director(y/ies))\t@{class=num failed}%s\n' "$n_sub" "$n_path" "$tot_err"

    printf 'TABLE\tPer day\n'
    printf 'HEAD\tDate\tErrors\tSubscriptions\n'
    printf 'KIND\ttext\tnumfailed\tnum\n'
    day_rows
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num failed}%s\t\n' "$n_day" "$tot_err"

    printf 'NOTE\tSource: TM errors "Error occurred while listing files from partner … defined in account …. No such file[: '\''<path>'\''] " (with or without the "Error during transfer operation:" prefix). Only the **No such file** reason is counted — other listing failures (Permission denied, …) are counted per subscription by **Remote Polls**, which also covers the polls that do list a directory. **Only OPEN problems are listed**: a row is dropped when the flow recovered AFTER that row'\''s last error — either an OK File in the transfer cache, or, on a **UC3** subscription, a later "Applying the search pattern … for transfer site" line for that same site, which proves the poll reached the directory even though it downloaded nothing (an empty poll leaves no transfer record at all, so nothing else can witness it). Each row therefore still describes a directory the partner was rejecting at the end of the window. The subscription is the logged site truncated at its _SCP_ suffix, linked to its detail page when the name resolves. **One row per subscription**: a flow rejected on several directories (or several spellings of one) stacks them in the Remote directory cell, newest failure first — click the cell to expand a long list. **Last** is that subscription'\''s most recent failed listing. Error counts are additive, so a date-filtered range re-totals them. Click a row to expand its 10 most recent log lines.\n'
    printf 'SUMMARY\tOpen failed listings: %s  |  Subscriptions: %s  |  Directories: %s  |  Days: %s  |  Resolved since: %s\n' "$tot_err" "$n_sub" "$n_path" "$n_day" "${n_res:-0}"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_err error(s), $n_sub subscription(s), $n_path director(y/ies))." >&2
