#!/usr/bin/env bash
#
# polling.sh — "Polling" (2026-09-05, user request): ONE flat table, one row
# per polling subscription, with the columns of the two pages retired the same
# day — the Remote polls report (polls / empty polls / files matched / empty %
# / listing errors, per subscription, date-filterable with the log-line drill)
# and the analyses Cronjobs page (the configured cron expression, its plain-
# English schedule, the OBSERVED firing, the contradiction alarm, the poll
# starts and failure lines of a schedule that never completes a poll). The
# page sits where the Cronjobs page sat: the Analyses -> Configuration row.
# (The UC3 tab of UC status keeps the same information as separate tables.)
#
# Rows = the union of every configured UC3 subscription (the UC3 status table,
# uc3-status.rpt — so the never-seen ones appear too), the configured cron
# schedules and the subscriptions the server log shows polling (a flow polling
# without a configured schedule still appears, its cron columns empty). Names
# join exactly, else by the unique prefix either way (the server truncates
# long site names — the rule the Cronjobs page applied).
#
# 2026-09-05 (later): the UC3 STATUS columns came along (user request) —
# Status (the seven UC3 statuses, coloured as on the UC3 tab), Files / OK /
# Error / Last file (the transfer log) and Last log (the newest server-log
# line of any counted kind), plus the seven status boxes. Problems was left
# out on purpose: it overlaps Listing errors + Failure lines.
#
# Reads (after the server report pool, bin/server/reports.sh):
#   $REPORTS_DIR/uc3-status.rpt           the UC3 status table (bin/analyses/reports/uc3-status.sh)
#   $REPORTS_DIR/remote-poll.rpt          the polls + listing-failure tables
#                                         (bin/server/reports/remote-poll.sh, an
#                                         unpublished intermediate)
#   $REPORTS_DIR/poll-times.tsv, poll-failures.tsv   its sidecars
#   $TRANSFER_REPORTS/punctuality.rpt     the file-arrival fallback slot
#   $FM_INPUT_DIR/subscriptions.json      the cron expressions (jq + cron2human)
#   $CONFIG_XREF/_subscriptions-hosts.tsv the host-keyed auth failures
#   bin/cron-observed.awk                 the schedule-vs-observed classifier
#                                         (shared with uc3-polling.sh)
# Writes $REPORTS_DIR/polling.rpt (page docs/<env>/analyses/polling.html).
#
# Usage:
#   ./polling.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../server/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/polling.rpt"
US="$REPORTS_DIR/uc3-status.rpt"
RP="$REPORTS_DIR/remote-poll.rpt"
PT="$REPORTS_DIR/poll-times.tsv"
PF="$REPORTS_DIR/poll-failures.tsv"
PUNCT="$TRANSFER_REPORTS/punctuality.rpt"
SUBJSON="$FM_INPUT_DIR/subscriptions.json"   # the SKIP-filtered copy when present (server/lib.sh)
XSH="$CONFIG_XREF/_subscriptions-hosts.tsv"
CRON_AWK="$ROOT/bin/cron2human.awk"
COBS="$ROOT/bin/cron-observed.awk"
ensure_config

if [ ! -f "$RP" ] && [ ! -f "$SUBJSON" ] && [ ! -f "$US" ]; then
    rm -f "$OUT"; echo "polling: no remote-poll.rpt, no uc3-status.rpt, no config export — page not published." >&2; exit 0
fi
# a VANISHED input must force a rebuild (skip_if_fresh only sees NEWER deps):
# the FOOT records which inputs the file was built from
have="polls=$([ -f "$RP" ] && echo yes || echo no) cron=$([ -f "$SUBJSON" ] && echo yes || echo no) status=$([ -f "$US" ] && echo yes || echo no)"
if [ -f "$OUT" ] && ! command grep -q "inputs: $have" "$OUT"; then rm -f "$OUT"; fi
deps=()
for d in "$US" "$RP" "$PT" "$PF" "$PUNCT" "$SUBJSON" "$XSH" "$CRON_AWK" "$COBS"; do [ -f "$d" ] && deps+=("$d"); done
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" ${deps[@]+"${deps[@]}"}
echo "polling: building the flat Polling table ..." >&2

# ---- the cron side: name ⇥ cron ⇥ schedule ⇥ observed ⇥ bad ⇥ polls ⇥ days ⇥ never ⇥ starts ⇥ failures ⇥ why
cron=""
if [ -f "$SUBJSON" ] && command -v jq >/dev/null 2>&1; then
    _pu="$PUNCT"; [ -f "$_pu" ] || _pu=/dev/null
    _pt="$PT";    [ -f "$_pt" ] || _pt=/dev/null
    _pf="$PF";    [ -f "$_pf" ] || _pf=/dev/null
    _xs="$XSH";   [ -f "$_xs" ] || _xs=/dev/null
    cron=$(jq -r '
        .[] | . as $s
        | (["sftp","ftp"][] as $p
           | ($s.parameters["hybrid_partner_\($p)_relay0_receive_scheduler_cron_expression"]) as $c
           | select($c != null and $c != "")
           | [ $s.name, ($p|ascii_upcase), $c ] | @tsv)
      ' "$SUBJSON" | awk -F'\t' -v CF=3 -f "$CRON_AWK" | LC_ALL=C sort -f \
      | awk -F'\t' -v PUNCT="$_pu" -v POLLT="$_pt" -v PF="$_pf" -v XSH="$_xs" -f "$COBS")
fi
_rp="$RP"; [ -f "$_rp" ] || _rp=/dev/null
_us="$US"; [ -f "$_us" ] || _us=/dev/null

# ---- the join: ONE awk over the cron TSV (stdin) and remote-poll.rpt -------
agg=$(printf '%s\n' "$cron" | awk -F'\t' -v RPF="$_rp" -v USF="$_us" '
    function strip(c) { sub(/^@\{[^}]*\}/, "", c); return c }
    function pfx(a, b) { return substr(a, 1, length(b)) == b || substr(b, 1, length(a)) == a }
    # the ONE poll/listing key a name resolves to: exact, else the unique
    # prefix either way among the keys of map M (its index list I, count n)
    function resolve(u, I, n, M,   i, c, hit) {
        if (u in M) return u
        c = 0; for (i = 1; i <= n; i++) if (pfx(I[i], u)) { c++; hit = I[i]; if (c > 1) break }
        return (c == 1) ? hit : ""
    }
    BEGIN {
        US = sprintf("%c", 31)
        # remote-poll.rpt: table 1 = polls per subscription, table 2 = listing failures
        t = 0
        while ((getline l < RPF) > 0) {
            n = split(l, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (a[1] != "ROW") continue
            nm = strip(a[2]); u = toupper(nm); if (nm == "") continue
            if (t == 1) { if (!(u in PN)) { PU[++npk] = u }; PN[u] = nm; PP[u] = a[3]; PE[u] = a[4]; PM[u] = a[5]; PPCT[u] = a[6]; PF1[u] = a[7]; PL1[u] = a[8]
                for (i = 9; i <= n; i++) { if (index(a[i], "@data:buckets=") == 1) PB[u] = substr(a[i], 15); else if (index(a[i], "@data:loglines=") == 1) PLL[u] = substr(a[i], 16) } }
            else if (t == 2) { if (!(u in LN)) { LU[++nlk] = u }; LN[u] = nm; LE[u] = a[3]; LF1[u] = a[4]; LL1[u] = a[5]
                for (i = 6; i <= n; i++) if (index(a[i], "@data:buckets=") == 1) LB[u] = substr(a[i], 15) }
        }
        close(RPF)
        # uc3-status.rpt: Status ⇥ Subscription ⇥ Files ⇥ OK ⇥ Error ⇥ Last file ⇥ Polls ⇥ Empty ⇥ Problems ⇥ Last log ⇥ loglines
        while ((getline l < USF) > 0) {
            n = split(l, a, "\t")
            if (a[1] != "ROW" || n < 11) continue
            nm = strip(a[3]); u = toupper(nm); if (nm == "") continue
            if (!(u in SN)) { SU[++nsk] = u }
            SN[u] = nm; SST[u] = a[2]; SFI[u] = a[4]; SOK[u] = a[5]; SER[u] = a[6]; SLF[u] = a[7]; SLG[u] = a[11]
            SDL[u] = (n >= 12 && index(a[12], "@data:loglines=") == 1) ? substr(a[12], 16) : ""
            st = a[2]; sub(/^@\{[^}]*\}/, "", st); SCNT[st]++
        }
        close(USF)
    }
    # the cron rows (stdin): name ⇥ cron ⇥ schedule ⇥ observed ⇥ bad ⇥ polls ⇥ days ⇥ never ⇥ starts ⇥ failures ⇥ why
    NF >= 11 { u = toupper($1); if (!(u in CN)) { CU[++nck] = u }
               CN[u] = $1; CC[u] = $2; CS[u] = $3; CO[u] = $4; CBAD[u] = $5; CPOLLS[u] = $6; CDAYS[u] = $7; CNEV[u] = $8; CST[u] = $9; CFL[u] = $10; CWHY[u] = $11 }
    # merge the two bucket strings of one row: date:polls:empty:matched (+ date:count) -> date:p:e:m:l, dates sorted
    function buckets(pb, lb,   n, i, k, d, A, B, keys, nk, out, v, j, x) {
        split("", D); split("", E); split("", M); split("", L); nk = 0; split("", keys)
        n = split(pb, A, ","); for (i = 1; i <= n; i++) { if (split(A[i], B, ":") < 4) continue; d = B[1]; if (!(d in D)) { keys[++nk] = d; D[d] = 0; E[d] = 0; M[d] = 0; L[d] = 0 }; D[d] += B[2]; E[d] += B[3]; M[d] += B[4] }
        n = split(lb, A, ","); for (i = 1; i <= n; i++) { if (split(A[i], B, ":") < 2) continue; d = B[1]; if (!(d in D)) { keys[++nk] = d; D[d] = 0; E[d] = 0; M[d] = 0; L[d] = 0 }; L[d] += B[2] }
        for (i = 2; i <= nk; i++) { v = keys[i]; j = i - 1; while (j >= 1 && keys[j] > v) { keys[j+1] = keys[j]; j-- } keys[j+1] = v }
        out = ""; for (i = 1; i <= nk; i++) { d = keys[i]; out = out (out == "" ? "" : ",") d ":" D[d] ":" E[d] ":" M[d] ":" L[d] }
        return out
    }
    function emit(name, u, pk, lk, sk,   cronx, sched, obs, polls, empty, matched, pct, lst, starts, fails, why, days, first, last, bk, ll, nm, stc, fi, ok, er, lf, lg) {
        cronx = ""; sched = ""; obs = ""; starts = ""; fails = ""; why = ""; days = ""
        stc = ""; fi = ""; ok = ""; er = ""; lf = ""; lg = ""
        if (sk != "") { stc = SST[sk]; fi = SFI[sk]; ok = SOK[sk]; er = SER[sk]; lf = SLF[sk]; lg = SLG[sk]; TFI += fi; TOK += ok; TER += er }
        if (u in CN) { cronx = CC[u]; sched = CS[u]; obs = (CBAD[u] ? "@{class=obsbad}" : "") CO[u]
                       days = CDAYS[u]; if (CST[u] > 0) starts = CST[u]; if (CFL[u] > 0) fails = CFL[u]; why = CWHY[u] }
        polls = "-"; empty = ""; matched = ""; pct = ""; first = ""; last = ""; bk = ""; ll = ""; lst = ""
        if (pk != "") { polls = PP[pk]; empty = PE[pk]; matched = PM[pk]; pct = PPCT[pk]; first = PF1[pk]; last = PL1[pk]; bk = PB[pk]; ll = PLL[pk]
                        if (days == "" || days == 0) days = "" }
        else if (u in CN && CPOLLS[u] > 0) polls = CPOLLS[u]
        if (lk != "") { lst = LE[lk]; if (first == "" || LF1[lk] < first) first = LF1[lk]; if (LL1[lk] > last) last = LL1[lk] }
        if (ll == "" && sk != "") ll = SDL[sk]   # no poll lines: the status drill (the lines that decided the status)
        if (days == 0) days = ""
        nm = "@{alink=subscriptions/" name "}" name
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n", \
            stc, nm, fi, ok, er, lf, cronx, sched, (obs != "" ? obs : (pk != "" ? "" : "-")), polls, empty, matched, pct, lst, starts, fails, why, days, first, last, lg, buckets((pk != "" ? PB[pk] : ""), (lk != "" ? LB[lk] : "")), ll
        # the totals (this pass): rows, polls, empty, matched, listing, starts, failures, schedules, never
        NR9++; if (polls != "-" && polls != "") TP += polls; TE += empty; TM += matched; TL += lst; TS += starts; TF += fails
        if (u in CN) { NC++; if (CNEV[u]) NNEV++ }
    }
    END {
        # cron rows first (their own order), then the poll-only names
        for (i = 1; i <= nck; i++) { u = CU[i]
            pk = resolve(u, PU, npk, PN); lk = resolve(u, LU, nlk, LN); sk = resolve(u, SU, nsk, SN)
            if (pk != "") used[pk] = 1; if (lk != "") usedl[lk] = 1; if (sk != "") useds[sk] = 1
            emit(CN[u], u, pk, lk, sk) }
        for (i = 1; i <= npk; i++) { u = PU[i]; if (u in used) continue
            lk = (u in LN) ? u : ""; if (lk != "") usedl[lk] = 1
            sk = resolve(u, SU, nsk, SN); if (sk != "") useds[sk] = 1
            emit(PN[u], u, u, lk, sk) }
        for (i = 1; i <= nlk; i++) { u = LU[i]; if (u in usedl) continue
            sk = resolve(u, SU, nsk, SN); if (sk != "") useds[sk] = 1
            emit(LN[u], u, "", u, sk) }
        # the configured UC3 flows nothing else knows: never seen polling, no cron
        for (i = 1; i <= nsk; i++) { u = SU[i]; if (u in useds) continue
            emit(SN[u], u, "", "", u) }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", NR9+0, TP+0, TE+0, TM+0, TL+0, TS+0, TF+0, NC+0, NNEV+0, TFI+0, TOK+0, TER+0
        printf "SC\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", SCNT["ok"]+0, SCNT["error"]+0, SCNT["ok -> error"]+0, SCNT["server - no files"]+0, SCNT["server - error"]+0, SCNT["server - no result"]+0, SCNT["not seen"]+0
    }')
IFS=$'\t' read -r _ n_rows t_polls t_empty t_matched t_list t_starts t_fails n_cron n_never t_files t_ok t_err <<< "$(printf '%s\n' "$agg" | command grep $'^TOT\t')"
IFS=$'\t' read -r _ s_ok s_err s_regr s_nofiles s_srverr s_nores s_notseen <<< "$(printf '%s\n' "$agg" | command grep $'^SC\t')"
pct_empty=$(awk -v p="$t_polls" -v e="$t_empty" 'BEGIN { printf "%.1f%%", (p > 0 ? 100 * e / p : 0) }')

{
    printf 'TITLE\tPolling\n'
    printf 'DESC\tEvery polling subscription in one row — its UC3 status and transfer-log figures, its configured cron schedule and what the server log observed: polls, empty polls, files matched, listing failures, the poll starts and failure lines of a schedule that never completes, and the contradiction alarm.\n'
    printf 'KEYWORDS\tpoll,polls,polling,remote poll,empty polls,listing failures,cron,cronjobs,schedule,quartz,observed,uc3,uc3 status\n'
    printf 'INTRO\tOne row per subscription that polls a partner — **UC3**, where we are the client and pull on a timer — every configured UC3 flow, plus any other flow the server log shows polling. **Status** is the UC3 status of the flow (the UC status / UC3 tab): **ok** = its latest File was delivered; **error** = never once delivered an OK File; **ok -> error** = red now but it HAS delivered before; **server - no files** / **server - error** / **server - no result** = seen in the server log only, by the latest word of the log on it (last poll found nothing / could not retrieve from the partner / the poll is only ever prepared); **not seen** = in neither log. **Files** / **OK** / **Error** / **Last file** are its logical transfers from the transfer log. Then the **configuration**: the Quartz cron expression (sec min hour day-of-month month day-of-week) and its plain-English **Schedule**. The right half is the **server log**: **Observed** (when the schedule actually fires — the median of the first poll of each day ± one standard deviation, the poll rate for a schedule firing more than 3× a day, **· files** when only file arrivals give a slot; **-** when nothing was ever observed), **Polls** / **Empty polls** / **Files matched** / **Empty %%** (every scheduled poll and what it picked up), **Listing errors** (the poll could not even list the remote folder), and for a schedule that never completes a poll its **Poll starts** and **Failure lines** with the dominant reason under **What goes wrong**. A **dark red** Observed cell contradicts its schedule. **Last log** is the newest server-log line of ANY counted kind, the ones that merely prepare a poll included — it answers whether the flow still runs at all. Rows are tinted by the result of the subscription. The poll figures re-total for a From/To range; click a row for its 10 most recent poll lines (on a flow without poll lines, the lines that decided its status).\n'
    printf 'STAT\twhite\t%s\tpolling subscriptions\n' "$n_rows"
    if [ -f "$US" ]; then
        printf 'STAT\tgreen\t%s\tok\n' "$s_ok"
        printf 'STAT\tred\t%s\terror\n' "$s_err"
        printf 'STAT\torange\t%s\tok -> error\n' "$s_regr"
        printf 'STAT\tblue\t%s\tserver - no files\n' "$s_nofiles"
        printf 'STAT\tred\t%s\tserver - error\n' "$s_srverr"
        printf 'STAT\tblue\t%s\tserver - no result\n' "$s_nores"
        printf 'STAT\torange\t%s\tnot seen\n' "$s_notseen"
    fi
    printf 'STAT\twhite\t%s\tcron schedules\n' "$n_cron"
    printf 'STAT\twhite\t%s\tpolls\n' "$t_polls"
    printf 'STAT\torange\t%s\tempty\n' "$pct_empty"
    printf 'STAT\tred\t%s\tlisting failures\n' "$t_list"
    printf 'STAT\tred\t%s\tnever complete a poll\n' "$n_never"
    printf 'TABLE\tPolling\twide\tanchor=polling\n'
    printf 'HEAD\tStatus\tSubscription\tFiles\tOK\tError\tLast file\tCron expression\tSchedule\tObserved\tPolls\tEmpty polls\tFiles matched\tEmpty %%\tListing errors\tPoll starts\tFailure lines\tWhat goes wrong\tActive days\tFirst\tLast\tLast log\n'
    printf 'KIND\ttext\tmono\tnum\tnumprocessed\tnumfailed\ttext\tmono\ttext\ttext\tnum\tnumwarn\tnumprocessed\tnum\tnumfailed\tnum\tnum\ttext\tnum\ttext\ttext\ttext\n'
    printf 'RECALC\t-\t-\t-\t-\t-\t-\t-\t-\t-\ts0\ts1\ts2\tp1.0\ts3\t-\t-\t-\t-\t-\t-\t-\n'
    printf '%s\n' "$agg" | command grep $'^ROW\t' || true
    printf 'TOTAL\t\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num processed}%s\t@{class=num failed}%s\t\t\t\t\t@{class=num}%s\t@{class=num warn}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num}%s\t\t\t\t\t\n' \
        "$n_rows" "$t_files" "$t_ok" "$t_err" "$t_polls" "$t_empty" "$t_matched" "$pct_empty" "$t_list" "$t_starts" "$t_fails"
    printf 'NOTE\tSources: the TM lines "Applying the search pattern … for transfer site SITE: N file(s) were found of which M matched the pattern" (a poll; empty when M = 0), "Error occurred while listing files from partner SITE" (a listing failure), the "Remote files pattern … evaluated" setup lines (a poll start), the connection and authentication failures naming the flow or its host (the failure lines), and the cron expressions of subscriptions.json; the Status, Files / OK / Error / Last file and Last log columns are those of the UC status / UC3 tab (its Problems column is left out here — it overlaps Listing errors and Failure lines). Subscription names are the configured ones (the logged _SCP_ / _SFTP_SERVER_ tails dropped); a flow polling without a configured schedule still gets a row, its cron columns empty. Matching is name-prefix both ways where the server truncated a name.\n'
    printf 'NOTE\tThe same information sits on the **UC status / UC3** tab as separate tables, beside the UC3 status of every flow. Where we are the client (UC3, and the pull side of UC5) SecureTransport connects to the server of the partner on a timer and collects whatever is waiting — an empty poll consumes a slot, a connection and a listing but leaves no trace in the transfer log, so chronic empty polling is visible only here. UC1 is a client use case too, but pushes on directory scanning — no cron. All schedules are enabled; none skip holidays.\n'
    printf 'LINK\thttps://www.quartz-scheduler.org/documentation/quartz-2.3.0/tutorials/crontrigger.html\tQuartz cron trigger reference\n'
    printf 'SUMMARY\tPolling subscriptions: %s  |  ok: %s  |  error: %s  |  ok -> error: %s  |  server-side: %s  |  not seen: %s  |  Polls: %s  |  Empty: %s  |  Listing failures: %s  |  Cron schedules: %s  |  Never complete a poll: %s\n' "$n_rows" "$s_ok" "$s_err" "$s_regr" "$((s_nofiles + s_srverr + s_nores))" "$s_notseen" "$t_polls" "$pct_empty" "$t_list" "$n_cron" "$n_never"
    printf 'FOOT\tGenerated on %s (inputs: %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$have"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_rows row(s): $n_cron with a cron schedule, $t_polls poll(s))." >&2
