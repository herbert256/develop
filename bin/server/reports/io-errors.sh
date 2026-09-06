#!/usr/bin/env bash
#
# io-errors.sh — "IO errors": the platform failing to READ (or write) a file
# on its OWN storage. From the TM message (2026-09-06, user request)
#
#   IO Error reading file /data/FlowManager/<account>@<login>/<file>
#
# The path is the account's FlowManager folder — the landing directory a
# partner pushes into (UC4/UC2) or the platform stages into — so the line
# names the ACCOUNT, its LOGIN (the "@" tail of the folder name) and the
# FILE. Nothing about the remote end is wrong here: the connection worked,
# the file arrived, and the platform could not read it back — a storage /
# NFS / permission problem (a file deleted or moved under a running route, a
# stale handle, a slow or full volume). The transfer log cannot show it: the
# upload leg was fine, and the route that failed to read the file writes no
# transfer row of its own — the File just ends one-legged (Failed) or, when
# a retry read it, goes through as if nothing happened.
#
# So every line is JOINED to the transfer log by its FILE NAME (_files.tsv
# col 11 — the File in flight at the time: the newest one starting before
# the error, else the first after it), which gives the subscription and the
# outcome: did the file still get through, or not? A line whose file the
# transfer log never saw stays "not logged" (a file that never became a
# transfer, or one outside the export window). The SESSION join (_parse.tsv
# col 6 = _transfers.tsv col 24) names the subscription when the file join
# cannot.
#
# Three tables: one row per FOLDER (account@login — the unit the path
# names) with the 10 most recent lines on click; the LINE LIST newest-first
# (the File cell opens the file's error page or File page when one exists,
# the row expands to the verbatim message); and the per-day count.
#
# Matcher: the message carries "IO Error" (any case, as a word) or
# "Input/output error" (the Java/POSIX EIO wording); the path is the first
# "/…" token after it, the operation the words between the two ("reading
# file"). A path not under a FlowManager folder is kept with an empty
# account, so nothing is dropped.
#
# Reads the parse cache (data/<env>/server/cache/_parse.tsv: 1=date, 2=time,
# 3=level, 4=component, 5=message, 6=session), the transfer caches
# (_files.tsv, _transfers.tsv) and the config rosters (base/_accounts.tsv,
# base/_logins.tsv — the configured SPELLING, so the cells link).
# Writes data/<env>/server/reports/io-errors.rpt.
#
# Usage:
#   ./io-errors.sh   # reads input/*.csv (via the cache), writes data/io-errors.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/io-errors.rpt"

FILES="$TRANSFER_CACHE/_files.tsv"          # one row per CoreId: 1 coreid 2 outcome 3 account 4 date 5 time 6 sortkey 11 file 12 site 14 login
TRANSFERS="$TRANSFER_CACHE/_transfers.tsv"  # the legs: 6 site, 24 session (the SESSION join)
ERRDIR="$TRANSFER_REPORTS/errors"           # failed.sh's per-CoreId error pages (docs/<env>/errors/)
FILEDIR="$TRANSFER_REPORTS/files"           # … and its File pages (docs/<env>/files/)
ACCB="$CONFIG_BASE/_accounts.tsv"           # configured spelling -> the cells link
LOGB="$CONFIG_BASE/_logins.tsv"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
ensure_config
ensure_parsed
# _files.tsv is the join input; the rosters give the linked spelling. The
# error/File page dirs are deliberately NOT deps: their .rpt files are
# rewritten every build (a FOOT carries the run time), which would re-scan
# the whole server cache for nothing — a page that appears later is picked
# up on the next data change.
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FILES" "$ACCB" "$LOGB"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

TMP=$(mktemp "${TMPDIR:-/tmp}/ioerr.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# Pass 1 — the IO lines out of the server cache. A cheap regex gate first
# (the cache is gigabytes in the real estate; the parse below runs on hits
# only), then the word-boundary test, the path and the operation.
# Emits: date time level comp session op path dir base account login msg sortkey
awk -F'\t' '
    $5 !~ /[Ii][Oo] [Ee]rror|[Ii]nput\/[Oo]utput [Ee]rror/ { next }
    {
        m = $5; l = tolower(m)
        if (!match(l, /(^|[^a-z])(io error|input\/output error)/)) next
        hit = RSTART + RLENGTH
        rest = substr(m, hit)
        path = ""; op = ""
        if (match(rest, /\/[^ \t}\]'"'"'"]+/)) {
            path = substr(rest, RSTART, RLENGTH); sub(/[.,;:)]+$/, "", path)
            op = substr(rest, 1, RSTART - 1)
        }
        gsub(/^[ \t:,-]+|[ \t:,-]+$/, "", op); op = tolower(op)
        dir = ""; base = ""
        if (path != "") { n = split(path, P, "/"); base = P[n]; dir = substr(path, 1, length(path) - length(base) - 1) }
        acct = ""; login = ""
        # the FlowManager folder: the component right after /FlowManager/ —
        # "<account>@<login>" (the transfer parse strips the same @ tail)
        if (match(tolower(dir "/"), /\/flowmanager\/[^\/]+\//)) {
            fld = substr(dir "/", RSTART + 13, RLENGTH - 14)
            at = index(fld, "@")
            if (at > 0) { acct = substr(fld, 1, at - 1); login = substr(fld, at + 1) } else acct = fld
        }
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        sk = substr(d, 1, 4) substr(d, 6, 2) substr(d, 9, 2) $2      # _files.tsv col 6 shape
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", d, $2, $3, $4, $6, op, path, dir, base, acct, login, substr(m, 1, 200), sk
    }
' "$PARSED" > "$TMP"

nline=$(wc -l < "$TMP" | tr -d ' ')
[ -f "$FILES" ] || FILES=/dev/null
[ -f "$TRANSFERS" ] || TRANSFERS=/dev/null
[ "$nline" -eq 0 ] && TRANSFERS=/dev/null   # nothing to join — skip the legs pass

# Pass 2 — the joins and the aggregation. Inputs in order: the IO lines, the
# Files (kept only for the file names in play), the legs (session -> site,
# only for the sessions in play). Emits the FINISHED ROW lines behind a
# sort prefix (the shell only sorts and cuts — a bash `read` over TAB-
# separated fields collapses an EMPTY field, and Login/Subscriptions can be
# empty), TAB-separated:
#   FLD <sortkey> <n> <acct> ROW <the folder row>
#   LIN <sortkey> ROW <the line row>
#   DAY <date> ROW <the day row>
#   TOT <n> <folders> <accounts> <files> <err> <ok> <nl> <days> <first> <last>
agg=$(awk -F'\t' -v IOF="$TMP" -v FILES="$FILES" -v TRANSFERS="$TRANSFERS" \
        -v ACCB="$ACCB" -v LOGB="$LOGB" -v ERRDIR="$ERRDIR" -v FILEDIR="$FILEDIR" "$LOGLINES_AWK"'
    function exists(f,   l, r) { r = (getline l < f); if (r >= 0) close(f); return r >= 0 }
    function canon(map, v) { return (toupper(v) in map) ? map[toupper(v)] : v }
    BEGIN {
        while ((getline l < ACCB) > 0) { split(l, a, "\t"); if (a[1] != "") ACC[toupper(a[1])] = a[1] } close(ACCB)
        while ((getline l < LOGB) > 0) { split(l, a, "\t"); if (a[1] != "") LOG[toupper(a[1])] = a[1] } close(LOGB)
    }
    FILENAME == IOF {
        N++
        L_d[N] = $1; L_t[N] = $2; L_lv[N] = $3; L_cp[N] = $4; L_ss[N] = $5; L_op[N] = $6
        L_path[N] = $7; L_dir[N] = $8; L_base[N] = $9; L_acct[N] = $10; L_login[N] = $11; L_msg[N] = $12; L_sk[N] = $13
        if ($9 != "") wantbase[$9] = 1
        if ($5 != "") wantsess[$5] = 1
        next
    }
    FILENAME == FILES {
        if (!($11 in wantbase)) next
        # sortkey SUBSEP coreid SUBSEP outcome SUBSEP site SUBSEP account SUBSEP login SUBSEP "date time"
        FC[$11] = FC[$11] _US $6 SUBSEP $1 SUBSEP $2 SUBSEP $12 SUBSEP $3 SUBSEP $14 SUBSEP $4 " " $5
        next
    }
    FILENAME == TRANSFERS {
        if (!($24 in wantsess) || $6 == "") next
        if (!($24 in SS)) SS[$24] = $6
        else if (SS[$24] != $6) SS[$24] = "*"      # a session running two flows names neither
        next
    }
    END {
        for (i = 1; i <= N; i++) {
            # the File in flight: the newest one starting at or before the
            # error, else the first one after it
            cid = ""; oc = ""; site = ""; tdate = ""; bestb = ""; besta = ""
            if (L_base[i] in FC) {
                n = split(substr(FC[L_base[i]], 2), C, _US)
                for (j = 1; j <= n; j++) { split(C[j], f, SUBSEP)
                    if (f[1] <= L_sk[i]) { if (bestb == "" || f[1] > bestb) { bestb = f[1]; pick = C[j] } }
                    else if (bestb == "" && (besta == "" || f[1] < besta)) { besta = f[1]; pick = C[j] } }
                split(pick, f, SUBSEP); cid = f[2]; oc = f[3]; site = f[4]; tdate = f[7]
                if (L_acct[i] == "" && f[5] != "") L_acct[i] = f[5]     # a path outside FlowManager: the File names the account
                if (L_login[i] == "" && f[6] != "") L_login[i] = f[6]
            }
            if (site == "" && L_ss[i] != "" && (L_ss[i] in SS) && SS[L_ss[i]] != "*") site = SS[L_ss[i]]
            acct = canon(ACC, L_acct[i]); login = canon(LOG, L_login[i])
            k = acct SUBSEP login; d = L_d[i]
            # ---- the folder row
            F_n[k]++; T_n++
            if (!(k in F_fold)) { F_fold[k] = (L_dir[i] != "" ? L_dir[i] : "-"); NF_++ }
            if (!(k in F_first) || d < F_first[k]) F_first[k] = d
            if (!(k in F_last)  || d > F_last[k])  { F_last[k] = d; F_lsk[k] = L_sk[i] }
            if (!((k SUBSEP d) in dseen)) { dseen[k, d] = 1; F_days[k]++ }
            if (L_base[i] != "" && !((k SUBSEP L_base[i]) in fseen)) { fseen[k, L_base[i]] = 1; F_files[k]++ }
            if (site != "" && !((k SUBSEP site) in sseen)) { sseen[k, site] = 1; F_subs[k] = F_subs[k] (F_subs[k] == "" ? "" : _US) site }
            b_n[k, d]++
            if (cid == "") { F_nl[k]++; b_nl[k, d]++; T_nl++ }
            else if (!((k SUBSEP cid) in cseen)) { cseen[k, cid] = 1
                if (oc == "Failed" || oc == "Expired") { F_err[k]++; b_err[k, d]++; T_err++ } else { F_ok[k]++; b_ok[k, d]++; T_ok++ } }
            addline("F" SUBSEP k, d " " L_t[i], lvlname(L_lv[i]) " " compname(L_cp[i]) "  " L_msg[i])
            if (!(acct in aseen)) { aseen[acct] = 1; NA++ }
            if (L_base[i] != "" && !(L_base[i] in bseen)) { bseen[L_base[i]] = 1; NB++ }
            if (T_first == "" || d < T_first) T_first = d
            if (T_last == "" || d > T_last) T_last = d
            # ---- the per-day row
            D_n[d]++
            if (!((d SUBSEP k) in dfs)) { dfs[d, k] = 1; D_f[d]++ }
            if (L_base[i] != "" && !((d SUBSEP L_base[i]) in dfb)) { dfb[d, L_base[i]] = 1; D_b[d]++ }
            # ---- the line row
            fcell = (L_base[i] != "" ? L_base[i] : (L_path[i] != "" ? L_path[i] : "-"))
            if (cid != "") {
                if (exists(ERRDIR "/" cid ".rpt")) fcell = "@{href=../errors/" cid ".html}" fcell
                else if (exists(FILEDIR "/" cid ".rpt")) fcell = "@{href=../files/" cid ".html}" fcell
            }
            if (oc == "Failed" || oc == "Expired") scell = "@{class=failed}" oc
            else if (oc != "") scell = "@{class=processed}" oc
            else scell = "not logged"
            printf "LIN\t%s\tROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:loglines=%s\n", L_sk[i], d, L_t[i], acct, login, site, fcell, \
                (L_op[i] != "" ? L_op[i] : "-"), scell, (tdate != "" ? tdate : "-"), \
                d " " L_t[i] "  " lvlname(L_lv[i]) " " compname(L_cp[i]) "  " L_msg[i]
        }
        for (k in F_n) { split(k, a, SUBSEP)
            bk = ""
            for (x in b_n) { split(x, y, SUBSEP); if (y[1] != a[1] || y[2] != a[2]) continue
                bk = bk (bk == "" ? "" : ",") y[3] ":" b_n[x] ":" (b_err[x] + 0) ":" (b_ok[x] + 0) ":" (b_nl[x] + 0) }
            printf "FLD\t%s\t%d\t%s\tROW\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n", \
                F_lsk[k], F_n[k], a[1], F_last[k], a[1], a[2], F_subs[k], \
                F_n[k], F_files[k] + 0, F_err[k] + 0, F_ok[k] + 0, F_nl[k] + 0, F_days[k], F_first[k], F_fold[k], bk, lastlines("F" SUBSEP k)
        }
        for (d in D_n) { ND++; printf "DAY\t%s\tROW\t%s\t%d\t%d\t%d\n", d, d, D_n[d], D_f[d], D_b[d] + 0 }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n", T_n + 0, NF_ + 0, NA + 0, NB + 0, T_err + 0, T_ok + 0, T_nl + 0, ND + 0, T_first, T_last
    }
' "$TMP" "$FILES" "$TRANSFERS")

IFS=$'\t' read -r _ n_lines n_fold n_acct n_files n_err n_ok n_nl n_days d_first d_last <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"

# The row writers print STRAIGHT to stdout inside the page block below: the
# ROW lines are finished in awk, the shell only orders them (folders by
# newest line, then most lines; the line list newest-first; days ascending)
# and drops the sort prefix.
TAB=$(printf '\t')
fld_rows() { printf '%s\n' "$agg" | grep $'^FLD\t' | sort -t"$TAB" -k2,2r -k3,3nr -k4,4 | cut -f5-; }
lin_rows() { printf '%s\n' "$agg" | grep $'^LIN\t' | sort -t"$TAB" -k2,2r | cut -f3-; }
day_rows() { printf '%s\n' "$agg" | grep $'^DAY\t' | sort -t"$TAB" -k2,2 | cut -f3-; }

{
    printf 'TITLE\tIO errors\n'
    printf 'DESC\tThe platform failing to read (or write) a file on its own storage — "IO Error reading file /data/FlowManager/<account>@<login>/<file>" — per folder, per line and per day, each line joined to the File it concerns and its outcome.\n'
    printf 'KEYWORDS\tio error,input/output error,reading file,writing file,flowmanager folder,disk,storage,nfs,stale handle,permission,one-legged,retry\n'
    if [ "${n_lines:-0}" -eq 0 ]; then
        printf 'INTRO\tThe server log carries **no IO error** in this window: no "IO Error reading file …" (or "Input/output error") line at all. The platform read every file it was asked to read from its own storage.\n'
    else
        printf 'INTRO\t**%s** IO error line(s) in **%s** FlowManager folder(s) of **%s** account(s), over **%s** day(s) (**%s** to **%s**). The connection and the upload were fine — the platform then **could not read the file back from its own storage** (a file deleted or moved while a route ran, a stale NFS handle, a slow or full volume, a permission). The transfer log cannot show this on its own: the route that failed to read the file writes no transfer row, so each line is **joined to the File it concerns by its file name** — **%s** File(s) ended in **Error** (the route never read the file: a one-legged File), **%s** went **OK** anyway (a retry read it), and **%s** line(s) name a file the transfer log never saw.\n' \
            "$n_lines" "$n_fold" "$n_acct" "$n_days" "$d_first" "$d_last" "$n_err" "$n_ok" "$n_nl"
    fi

    printf 'TABLE\tIO errors per folder\twide\n'
    printf 'HEAD\tLast\tAccount\tLogin\tSubscriptions\tIO errors\tFiles\tError\tOK\tNot logged\tDays\tFirst\tFolder\n'
    printf 'KIND\ttext\tacct\tlogin\tclines\tnumfailed\tnum\tnumfailed\tnumprocessed\tnum\tnum\ttext\tmono\n'
    printf 'RECALC\t-\t-\t-\t-\ts0\tk\ts1\ts2\ts3\tc\t-\t-\n'
    [ "${n_lines:-0}" -gt 0 ] && fld_rows
    printf 'TOTAL\t@{colspan=4}Total (%s folder(s))\t@{class=num failed}%s\t%s\t@{class=num failed}%s\t@{class=num processed}%s\t%s\t%s\t\t\n' \
        "${n_fold:-0}" "${n_lines:-0}" "${n_files:-0}" "${n_err:-0}" "${n_ok:-0}" "${n_nl:-0}" "${n_days:-0}"

    printf 'TABLE\tIO error lines\twide pager=100\n'
    printf 'HEAD\tDate\tTime\tAccount\tLogin\tSubscription\tFile\tOperation\tState\tTransfer\n'
    printf 'KIND\ttext\ttext\tacct\tlogin\tsite\tfile\ttext\ttext\ttext\n'
    [ "${n_lines:-0}" -gt 0 ] && lin_rows
    printf 'TOTAL\t@{colspan=9}Total (%s line(s))\n' "${n_lines:-0}"

    printf 'TABLE\tPer day\n'
    printf 'HEAD\tDate\tIO errors\tFolders\tFiles\n'
    printf 'KIND\ttext\tnumfailed\tnum\tnum\n'
    [ "${n_lines:-0}" -gt 0 ] && day_rows
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num failed}%s\t\t\n' "${n_days:-0}" "${n_lines:-0}"

    printf 'NOTE\tSource: every server-log line carrying **IO Error** (as a word, any case) or **Input/output error**; the path is the first /… token after it and the **Folder** its directory — a FlowManager folder is named **account@login**, which is where the Account and Login columns come from (a path outside FlowManager keeps an empty account unless the joined File names one). Each line is joined to the transfer log **by file name**: the File in flight at the time (the newest one starting before the error, else the first after), whose subscription and **State** the line shows — **Failed** means the route never read the file (a one-legged File), **Processed** that a retry read it and the file went through, **not logged** that no File carries that name. A File cell opens the file'"'"'s error page (or File page) when the site has one. **IO errors** counts lines; **Files** distinct file names; **Error** / **OK** distinct Files by their outcome (Waiting counts as OK, Expired as Error). Line and File counts are additive and re-total under the date filter; click a folder row for its 10 most recent lines, a line row for the verbatim message.\n'
    printf 'SUMMARY\tIO errors: %s  |  Folders: %s  |  Files in error: %s  |  Days: %s\n' "${n_lines:-0}" "${n_fold:-0}" "${n_err:-0}" "${n_days:-0}"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (${n_lines:-0} IO error line(s), ${n_fold:-0} folder(s))." >&2
