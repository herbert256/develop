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
# UC status / UC3 tab (its Polls by subscription table, the former Remote Polls
# report), which also covers the polls that DO list a directory.
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
# server parse cache and writes data/server/reports/). It lives HERE
# because its page is an analyses/ page (the UC status report group of the one
# Reports menu, 2026-09-29) — the same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
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
# The RESOLVED filter: per subscription, the END of its LAST OK File
# (_files.tsv col 12 = subscription, 24 = the File end "YYYY-MM-DD hh:mm:ss.mmm"
# put in the col 6 sortkey shape "YYYYMMDDhh:mm:ss.mmm" — the start when the
# parse wrote no end; 2 = outcome — OK is the site-wide "not Failed/Expired",
# which on these pull flows is exactly Processed). A row whose last error
# PRECEDES that File's end is dropped: the directory was found again
# afterwards, so it is fixed, not broken (result.sh's "ended OK after it" rule).
last_ok_files() {   # emits "KF<TAB>subscription<TAB>sortkey" lines
    [ -f "$FILESC" ] || return 0
    awk -F'\t' '$12 != "" && $2 != "Failed" && $2 != "Expired" {
                    k = $6; if ($24 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) k = substr($24, 1, 4) substr($24, 6, 2) substr($24, 9, 2) substr($24, 12)
                    if (k > m[$12]) m[$12] = k }
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
    function sitecanon(t,   k, hits, full, c, t0) {
        if (t in SCMEMO) return SCMEMO[t]   # memo (2026-09-29): rows are keyed on it now, per line
        t0 = t
        c = rn_canon_pfx(t)
        if (c in ksite) return (SCMEMO[t0] = c)
        hits = 0
        for (k in ksite) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) { hits = 0; break } }
        return (SCMEMO[t0] = (hits == 1 ? full : c))
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
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass over the failed listings. The site may CONTAIN spaces ("Clone - UC3_…"),
# so it is captured up to the " defined in account " anchor, and the account up to
# the "." that opens the reason. Emits TAB-separated (the loglines drill LAST, it
# carries the raw message):
#   DIR <TAB> count <TAB> subscription <TAB> account <TAB> path <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   DAY <TAB> date <TAB> count <TAB> nsubs
#   TOT <TAB> errors <TAB> nsubs <TAB> naccounts <TAB> npaths <TAB> ndays <TAB> resolved rows <TAB> resolved errors
# the DERIVED use case map: a production hybrid flow carries no UC prefix, so
# the UC3 poll-recovery test must ask the config, not the name (2026-08-31 audit)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" -v ucdf="$UCDF" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK"'
    BEGIN { rn_load(RNF)
            while ((getline l9 < ucdf) > 0) { n9 = split(l9, a9, "\t"); if (n9 >= 2 && a9[2] == "UC3") ucd3[toupper(a9[1])] = 1 } close(ucdf) }
    BEGIN { US = sprintf("%c", 31) }                         # the lines/clines cell separator
    $1 == "KA" { kacct[$2] = 1; next }                       # known-account list       (first input)
    $1 == "KS" { ksite[$2] = 1; next }                       # known-subscription list  (first input)
    $1 == "KF" { okmax[$2] = $3; next }                      # last OK File per subscription (first input)
    # the logged site (the server truncates names) -> the configured name the
    # OK-File map is keyed by: exact, else the ONE known subscription it
    # prefixes (2026-08-31 audit: a truncated name never met its own recovery
    # evidence and stayed on the page for ever). Memoised.
    function okkey(s,   k, c, hit, sc) {
        if (s in okmax) return s
        sc = sitecanon(s); if (sc in okmax) return sc   # rename-folded / roster-matched (2026-09-05)
        if (s in OKM) return OKM[s]
        c = 0; for (k in ksite) if (index(k, s) == 1) { c++; hit = k; if (c > 1) break }
        return OKM[s] = (c == 1) ? hit : s
    }
    # the poll map key for a logged site: exact, else the one poll site that
    # prefixes it or that it prefixes (the server truncates long names on
    # either line, 2026-09-05)
    function pollkey(s,   k, c, hit) {
        if (s in pollmax) return s
        c = 0; for (k in pollmax) if (index(k, s) == 1 || index(s, k) == 1) { c++; hit = k; if (c > 1) break }
        return (c == 1) ? hit : s
    }
    # a _files.tsv-shaped sortkey (YYYYMMDDhh:mm:ss.mmm) as "YYYY-MM-DD hh:mm:ss"
    function skdisp(sk) { return (sk == "") ? "\342\200\224" : substr(sk, 1, 4) "-" substr(sk, 5, 2) "-" substr(sk, 7, 2) " " substr(sk, 9, 8) }
    # A SUCCESSFUL listing on the same site: "Applying the search pattern … for
    # transfer site SITE: N file(s) were found of which M matched" — the poll
    # reached the directory, even when it downloaded nothing. On a UC3 (pull)
    # flow that is the recovery proof an empty poll can never leave in the
    # transfer log, so the last one per site is kept alongside the last OK File.
    $5 ~ /Applying the search pattern .* for transfer site / {
        if (!match($5, /for transfer site '\''[^'\'']*'\''/)) next
        psite = substr($5, RSTART + 19, RLENGTH - 20); sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", psite)
        if (psite != "") psite = sitecanon(psite)   # the same key space as the rows
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
        # (Permission denied, …) belong to the UC3 tab of UC status (Polls by subscription)
        if (m !~ /No such file/) next
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        rest = substr(m, index(m, "listing files from partner ") + 27)
        p = index(rest, " defined in account "); if (p <= 1) next
        site = substr(rest, 1, p - 1); sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", site)   # clean subscription name
        if (site == "") next
        site = sitecanon(site)   # the ROW key (2026-09-29): a truncated or old spelling of one flow made a second row
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
            ok9 = okkey(a[1])
            if (lsk[k] != "" && (ok9 in okmax) && okmax[ok9] > lsk[k]) { nres++; nresf++; reserr += c[k]; continue }
            pk9 = pollkey(a[1])
            if (lsk[k] != "" && (a[1] ~ /^UC3/ || (toupper(a[1]) in ucd3)) && (pk9 in pollmax) && pollmax[pk9] > lsk[k]) { nres++; nresp++; reserr += c[k]; continue }
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
        # per surviving subscription: Last = its newest error WITH the time, and
        # the two recovery stamps the row did NOT pass — its last OK File and
        # (UC3) its newest successful listing — so the reader sees why it is
        # still open (2026-09-05, user report: a same-day OK File that
        # PRECEDED the error read as a recovery on a date-only Last)
        for (s in secnt) {
            ok9 = okkey(s); pk9 = pollkey(s)
            printf "DIR\t%d\t%s\t%s%s\t%s\t%s\t%s\t%s\t%s\n", secnt[s], skdisp(sesk[s]), sitelink(s), sitecanon(s), sedir[s], \
                skdisp((ok9 in okmax) ? okmax[ok9] : ""), ((pk9 in pollmax) ? skdisp(pollmax[pk9]) : "\342\200\224"), bk[s], lastlines("S" SUBSEP s)
        }
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
    while IFS=$'\t' read -r _ count last site path okst pollst bk lines; do
        [ -z "$site" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$last" "$site" "$path" "$okst" "$pollst" "$count" "$bk" "$lines"
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
    printf 'KEYWORDS\tno such file,missing directory,remote directory,listing,scan directory,path,configuration fault\n'

    # tab=uc3 (2026-09-29): both tables ride the UC3 tab of UC status
    printf 'TABLE\tMissing remote directories\twide\ttab=uc3\n'
    printf 'HEAD\tLast error\tSubscription\tRemote directory\tLast OK File\tLast good poll\tErrors\n'
    printf 'KIND\ttext\tmono\tclines\ttext\ttext\tnumfailed\n'
    printf 'RECALC\t-\t-\t-\t-\t-\ts0\n'
    dir_rows
    printf 'TOTAL\t@{colspan=5}Total (%s subscription(s) · %s director(y/ies))\t@{class=num failed}%s\n' "$n_sub" "$n_path" "$tot_err"

    printf 'TABLE\tMissing remote directories per day\ttab=uc3\n'   # its own heading on the shared UC3 tab (2026-09-29: two tables read "Per day")
    printf 'HEAD\tDate\tErrors\tSubscriptions\n'
    printf 'KIND\ttext\tnumfailed\tnum\n'
    day_rows
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num failed}%s\t\n' "$n_day" "$tot_err"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot_err error(s), $n_sub subscription(s), $n_path director(y/ies))." >&2
