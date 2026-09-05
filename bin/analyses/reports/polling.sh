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
# Rows = the union of the configured cron schedules and the subscriptions the
# server log shows polling (a flow polling without a configured schedule
# still appears, its cron columns empty). Names join exactly, else by the
# unique prefix either way (the server truncates long site names — the rule
# the Cronjobs page applied).
#
# Reads (after the server report pool, bin/server/reports.sh):
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
RP="$REPORTS_DIR/remote-poll.rpt"
PT="$REPORTS_DIR/poll-times.tsv"
PF="$REPORTS_DIR/poll-failures.tsv"
PUNCT="$TRANSFER_REPORTS/punctuality.rpt"
SUBJSON="$FM_INPUT_DIR/subscriptions.json"   # the SKIP-filtered copy when present (server/lib.sh)
XSH="$CONFIG_XREF/_subscriptions-hosts.tsv"
CRON_AWK="$ROOT/bin/cron2human.awk"
COBS="$ROOT/bin/cron-observed.awk"
ensure_config

if [ ! -f "$RP" ] && [ ! -f "$SUBJSON" ]; then
    rm -f "$OUT"; echo "polling: neither remote-poll.rpt nor a config export — page not published." >&2; exit 0
fi
# a VANISHED input must force a rebuild (skip_if_fresh only sees NEWER deps):
# the FOOT records which inputs the file was built from
have="polls=$([ -f "$RP" ] && echo yes || echo no) cron=$([ -f "$SUBJSON" ] && echo yes || echo no)"
if [ -f "$OUT" ] && ! command grep -q "inputs: $have" "$OUT"; then rm -f "$OUT"; fi
deps=()
for d in "$RP" "$PT" "$PF" "$PUNCT" "$SUBJSON" "$XSH" "$CRON_AWK" "$COBS"; do [ -f "$d" ] && deps+=("$d"); done
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

# ---- the join: ONE awk over the cron TSV (stdin) and remote-poll.rpt -------
agg=$(printf '%s\n' "$cron" | awk -F'\t' -v RPF="$_rp" '
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
    function emit(name, u, pk, lk,   cronx, sched, obs, polls, empty, matched, pct, lst, starts, fails, why, days, first, last, bk, ll, nm) {
        cronx = ""; sched = ""; obs = ""; starts = ""; fails = ""; why = ""; days = ""
        if (u in CN) { cronx = CC[u]; sched = CS[u]; obs = (CBAD[u] ? "@{class=obsbad}" : "") CO[u]
                       days = CDAYS[u]; if (CST[u] > 0) starts = CST[u]; if (CFL[u] > 0) fails = CFL[u]; why = CWHY[u] }
        polls = "-"; empty = ""; matched = ""; pct = ""; first = ""; last = ""; bk = ""; ll = ""; lst = ""
        if (pk != "") { polls = PP[pk]; empty = PE[pk]; matched = PM[pk]; pct = PPCT[pk]; first = PF1[pk]; last = PL1[pk]; bk = PB[pk]; ll = PLL[pk]
                        if (days == "" || days == 0) days = "" }
        else if (u in CN && CPOLLS[u] > 0) polls = CPOLLS[u]
        if (lk != "") { lst = LE[lk]; if (first == "" || LF1[lk] < first) first = LF1[lk]; if (LL1[lk] > last) last = LL1[lk]; if (ll == "") ll = "" }
        if (days == 0) days = ""
        nm = "@{alink=subscriptions/" name "}" name
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n", \
            nm, cronx, sched, (obs != "" ? obs : (pk != "" ? "" : "-")), polls, empty, matched, pct, lst, starts, fails, why, days, first, last, buckets((pk != "" ? PB[pk] : ""), (lk != "" ? LB[lk] : "")), ll
        # the totals (this pass): rows, polls, empty, matched, listing, starts, failures, schedules, never
        NR9++; if (polls != "-" && polls != "") TP += polls; TE += empty; TM += matched; TL += lst; TS += starts; TF += fails
        if (u in CN) { NC++; if (CNEV[u]) NNEV++ }
    }
    END {
        # cron rows first (their own order), then the poll-only names
        for (i = 1; i <= nck; i++) { u = CU[i]
            pk = resolve(u, PU, npk, PN); lk = resolve(u, LU, nlk, LN)
            if (pk != "") used[pk] = 1; if (lk != "") usedl[lk] = 1
            emit(CN[u], u, pk, lk) }
        for (i = 1; i <= npk; i++) { u = PU[i]; if (u in used) continue
            lk = (u in LN) ? u : ""; if (lk != "") usedl[lk] = 1
            emit(PN[u], u, u, lk) }
        for (i = 1; i <= nlk; i++) { u = LU[i]; if (u in usedl) continue
            emit(LN[u], u, "", u) }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", NR9+0, TP+0, TE+0, TM+0, TL+0, TS+0, TF+0, NC+0, NNEV+0
    }')
IFS=$'\t' read -r _ n_rows t_polls t_empty t_matched t_list t_starts t_fails n_cron n_never <<< "$(printf '%s\n' "$agg" | command grep $'^TOT\t')"
pct_empty=$(awk -v p="$t_polls" -v e="$t_empty" 'BEGIN { printf "%.1f%%", (p > 0 ? 100 * e / p : 0) }')

{
    printf 'TITLE\tPolling\n'
    printf 'DESC\tEvery polling subscription in one row — its configured cron schedule and what the server log observed: polls, empty polls, files matched, listing failures, the poll starts and failure lines of a schedule that never completes, and the contradiction alarm.\n'
    printf 'KEYWORDS\tpoll,polls,polling,remote poll,empty polls,listing failures,cron,cronjobs,schedule,quartz,observed,uc3\n'
    printf 'INTRO\tOne row per subscription that polls a partner — **UC3**, where we are the client and pull on a timer. The left half is the **configuration**: the Quartz cron expression (sec min hour day-of-month month day-of-week) and its plain-English **Schedule**. The right half is the **server log**: **Observed** (when the schedule actually fires — the median of the first poll of each day ± one standard deviation, the poll rate for a schedule firing more than 3× a day, **· files** when only file arrivals give a slot; **-** when nothing was ever observed), **Polls** / **Empty polls** / **Files matched** / **Empty %%** (every scheduled poll and what it picked up), **Listing errors** (the poll could not even list the remote folder), and for a schedule that never completes a poll its **Poll starts** and **Failure lines** with the dominant reason under **What goes wrong**. A **dark red** Observed cell contradicts its schedule. Rows are tinted by the result of the subscription. The poll figures re-total for a From/To range; click a row for its 10 most recent poll lines.\n'
    printf 'STAT\twhite\t%s\tpolling subscriptions\n' "$n_rows"
    printf 'STAT\twhite\t%s\tcron schedules\n' "$n_cron"
    printf 'STAT\twhite\t%s\tpolls\n' "$t_polls"
    printf 'STAT\torange\t%s\tempty\n' "$pct_empty"
    printf 'STAT\tred\t%s\tlisting failures\n' "$t_list"
    printf 'STAT\tred\t%s\tnever complete a poll\n' "$n_never"
    printf 'TABLE\tPolling\twide\tanchor=polling\n'
    printf 'HEAD\tSubscription\tCron expression\tSchedule\tObserved\tPolls\tEmpty polls\tFiles matched\tEmpty %%\tListing errors\tPoll starts\tFailure lines\tWhat goes wrong\tActive days\tFirst\tLast\n'
    printf 'KIND\tmono\tmono\ttext\ttext\tnum\tnumwarn\tnumprocessed\tnum\tnumfailed\tnum\tnum\ttext\tnum\ttext\ttext\n'
    printf 'RECALC\t-\t-\t-\t-\ts0\ts1\ts2\tp1.0\ts3\t-\t-\t-\t-\t-\t-\n'
    printf '%s\n' "$agg" | command grep $'^ROW\t' || true
    printf 'TOTAL\tTotal (%s subscription(s))\t\t\t\t@{class=num}%s\t@{class=num warn}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num}%s\t\t\t\t\n' \
        "$n_rows" "$t_polls" "$t_empty" "$t_matched" "$pct_empty" "$t_list" "$t_starts" "$t_fails"
    printf 'NOTE\tSources: the TM lines "Applying the search pattern … for transfer site SITE: N file(s) were found of which M matched the pattern" (a poll; empty when M = 0), "Error occurred while listing files from partner SITE" (a listing failure), the "Remote files pattern … evaluated" setup lines (a poll start), the connection and authentication failures naming the flow or its host (the failure lines), and the cron expressions of subscriptions.json. Subscription names are the configured ones (the logged _SCP_ / _SFTP_SERVER_ tails dropped); a flow polling without a configured schedule still gets a row, its cron columns empty. Matching is name-prefix both ways where the server truncated a name.\n'
    printf 'NOTE\tThe same information sits on the **UC status / UC3** tab as separate tables, beside the UC3 status of every flow. Where we are the client (UC3, and the pull side of UC5) SecureTransport connects to the server of the partner on a timer and collects whatever is waiting — an empty poll consumes a slot, a connection and a listing but leaves no trace in the transfer log, so chronic empty polling is visible only here. UC1 is a client use case too, but pushes on directory scanning — no cron. All schedules are enabled; none skip holidays.\n'
    printf 'LINK\thttps://www.quartz-scheduler.org/documentation/quartz-2.3.0/tutorials/crontrigger.html\tQuartz cron trigger reference\n'
    printf 'SUMMARY\tPolling subscriptions: %s  |  Polls: %s  |  Empty: %s  |  Listing failures: %s  |  Cron schedules: %s  |  Never complete a poll: %s\n' "$n_rows" "$t_polls" "$pct_empty" "$t_list" "$n_cron" "$n_never"
    printf 'FOOT\tGenerated on %s (inputs: %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$have"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_rows row(s): $n_cron with a cron schedule, $t_polls poll(s))." >&2
