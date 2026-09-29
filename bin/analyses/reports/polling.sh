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
# 2026-09-05 (later): the UC3 status table joined (user request) — first with
# Status / Files / OK / Error / Last file / Last log and the status boxes,
# then trimmed on request to OK and Error only; the INTRO, the boxes and the
# Active days / First / Last columns went in the same trim. The page is the
# bare table: Subscription · OK · Error · Cron expression · Observed · Polls ·
# Empty polls · Files matched · Empty % · Listing errors · Poll starts ·
# Failure lines · Schedule · What goes wrong (Schedule moved behind Failure
# lines on request, so the two prose columns sit together at the right).
#
# 2026-09-13 (user request): UC3 ONLY — a row is a configured UC3 flow (the
# UC3 status roster, name-prefixed or derived) or a UC3-named flow the server
# log shows polling; the other pollers (the UC5 pull side, a UC1 flow with a
# cron) are dropped. OK and Error are gone, and the cron columns lead: the
# page is Subscription · Cron expression · Schedule · Observed · Polls · Empty
# polls · Files matched · Empty % · Listing errors · Poll starts · Failure
# lines · What goes wrong.
#
# 2026-09-20 (user request): ACTIVE, the second column — the Subscriptions
# page's Active column (bin/analyses/publish.sh): "Yes", or the ", "-joined
# bin/subscription-active.jq codes of why the subscription is not active
# (1 status Undeployed, 2 status SAVED_NOT_DEPLOYED, 3 a receive schedule set
# to No, 4 folder monitoring Inactive) with the words as the hover title,
# "CFT" for a name containing SWIFT, blank for a flow the JSON does not name.
# The name resolves exactly, else through the UC3 status roster, else by the
# unique prefix either way (the join rule of the other columns).
#
# Reads (after the server report pool, bin/server/reports.sh):
#   $REPORTS_DIR/uc3-status.rpt           the UC3 status table (bin/analyses/reports/uc3-status.sh)
#   $REPORTS_DIR/remote-poll.rpt          the polls + listing-failure tables
#                                         (bin/server/reports/remote-poll.sh, an
#                                         unpublished intermediate)
#   $REPORTS_DIR/poll-times.tsv, poll-failures.tsv   its sidecars
#   $TRANSFER_REPORTS/punctuality-src.rpt the file-arrival fallback slot
#   $FM_INPUT_DIR/subscriptions.json      the cron expressions (jq + cron2human)
#   bin/subscription-active.jq            the Active codes (the ONE definition, shared with
#                                         the Subscriptions page and the detail pages)
#   $CONFIG_XREF/_subscriptions-hosts.tsv the host-keyed auth failures
#   bin/cron-observed.awk                 the schedule-vs-observed classifier
#                                         (shared with uc3-polling.sh)
# Writes $REPORTS_DIR/polling.rpt (page docs/analyses/polling.html).
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
PUNCT="$TRANSFER_REPORTS/punctuality-src.rpt"   # the component (2026-09-29: punctuality.rpt is the merged page)
SUBJSON="$FM_INPUT_DIR/subscriptions.json"   # the SKIP-filtered copy when present (server/lib.sh)
XSH="$CONFIG_XREF/_subscriptions-hosts.tsv"
CRON_AWK="$ROOT/bin/cron2human.awk"
COBS="$ROOT/bin/cron-observed.awk"
ACTJQ="$ROOT/bin/subscription-active.jq"

if [ ! -f "$RP" ] && [ ! -f "$SUBJSON" ] && [ ! -f "$US" ]; then
    rm -f "$OUT"; echo "polling: no remote-poll.rpt, no uc3-status.rpt, no config export — page not published." >&2; exit 0
fi
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
# ---- the Active codes (2026-09-20): name ⇥ the comma-joined codes, empty = active
actf=$(mktemp "${TMPDIR:-/tmp}/pollact.XXXXXX")
trap 'rm -f "$actf"' EXIT
if [ -f "$SUBJSON" ] && command -v jq >/dev/null 2>&1; then
    jq -r -f "$ACTJQ" "$SUBJSON" > "$actf" 2>/dev/null || : > "$actf"
fi
_rp="$RP"; [ -f "$_rp" ] || _rp=/dev/null
_us="$US"; [ -f "$_us" ] || _us=/dev/null

# ---- the join: ONE awk over the cron TSV (stdin) and remote-poll.rpt -------
agg=$(printf '%s\n' "$cron" | awk -F'\t' -v RPF="$_rp" -v USF="$_us" -v ACTF="$actf" '
    function strip(c) { sub(/^@\{[^}]*\}/, "", c); return c }
    # the ONE poll/listing key a name resolves to: exact, else the UNIQUE
    # truncation among the keys of map M (its index list I, count n) — dir 1:
    # a key the server truncated, a proper prefix of the full name u; dir 2:
    # u is the truncated one, a proper prefix of a key. 2026-09-28 fix: the
    # prefix matched either way, so a configured UC3_X with no polls of its
    # own took the row of a longer flow UC3_X_2 (whose own row then vanished
    # as used)
    function resolve(u, I, n, M, dir,   i, c, hit, k) {
        if (u in M) return u
        c = 0
        for (i = 1; i <= n; i++) { k = I[i]
            if (dir == 1 ? (length(k) < length(u) && substr(u, 1, length(k)) == k && truncok(k)) \
                         : (length(u) < length(k) && substr(k, 1, length(u)) == u)) { c++; hit = k; if (c > 1) break } }
        return (c == 1) ? hit : ""
    }
    # a key may stand for a longer configured name only when it is a real
    # TRUNCATION: no configured flow owns it as its own name, and exactly one
    # configured name extends it. 2026-09-28 (production run): the own key of
    # UC3_X was also taken by UC3_X_2, and its polls were summed twice
    function truncok(k,   i, c) {
        if (k in TRUNCM) return TRUNCM[k]
        if ((k in CN) || (k in SN)) { TRUNCM[k] = 0; return 0 }
        c = 0
        for (i = 1; i <= nck; i++) if (length(k) < length(CU[i]) && substr(CU[i], 1, length(k)) == k) c++
        for (i = 1; i <= nsk; i++) if (!(SU[i] in CN) && length(k) < length(SU[i]) && substr(SU[i], 1, length(k)) == k) c++
        TRUNCM[k] = (c == 1); return TRUNCM[k]
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
            if (t == 1) { if (!(u in PN)) { PU[++npk] = u }; PN[u] = nm; PP[u] = a[3]; PE[u] = a[4]; PM[u] = a[5]; PPCT[u] = a[6]
                for (i = 9; i <= n; i++) { if (index(a[i], "@data:buckets=") == 1) PB[u] = substr(a[i], 15); else if (index(a[i], "@data:loglines=") == 1) PLL[u] = substr(a[i], 16) } }
            else if (t == 2) { if (!(u in LN)) { LU[++nlk] = u }; LN[u] = nm; LE[u] = a[3]
                for (i = 6; i <= n; i++) if (index(a[i], "@data:buckets=") == 1) LB[u] = substr(a[i], 15) }
        }
        close(RPF)
        # uc3-status.rpt: Status ⇥ Subscription ⇥ Files ⇥ OK ⇥ Error ⇥ Last file ⇥ Polls ⇥ Empty ⇥ Problems ⇥ Last log ⇥ loglines
        # — the ROSTER (every configured UC3 flow) and its status drill; the
        # status / count columns themselves left the page 2026-09-13
        while ((getline l < USF) > 0) {
            n = split(l, a, "\t")
            if (a[1] != "ROW" || n < 11) continue
            nm = strip(a[3]); u = toupper(nm); if (nm == "") continue
            if (!(u in SN)) { SU[++nsk] = u }
            SN[u] = nm
            SDL[u] = (n >= 12 && index(a[12], "@data:loglines=") == 1) ? substr(a[12], 16) : ""
        }
        close(USF)
        # the Active codes: name ⇥ codes (empty = active)
        while ((getline l < ACTF) > 0) {
            n = split(l, a, "\t"); u = toupper(a[1]); if (u == "") continue
            if (!(u in AN)) { AU[++nak] = u }
            AN[u] = a[1]; AC[u] = (n >= 2 ? a[2] : "")
        }
        close(ACTF)
    }
    # the cron rows (stdin): name ⇥ cron ⇥ schedule ⇥ observed ⇥ bad ⇥ polls ⇥ days ⇥ never ⇥ starts ⇥ failures ⇥ why
    NF >= 11 { u = toupper($1); if (!(u in CN)) { CU[++nck] = u }
               CN[u] = $1; CC[u] = $2; CS[u] = $3; CO[u] = $4; CBAD[u] = $5; CPOLLS[u] = $6; CNEV[u] = $8; CST[u] = $9; CFL[u] = $10; CWHY[u] = $11 }
    # merge the two bucket strings of one row: date:polls:empty:matched (+ date:count) -> date:p:e:m:l, dates sorted
    function buckets(pb, lb,   n, i, k, d, A, B, keys, nk, out, v, j, x) {
        split("", D); split("", E); split("", M); split("", L); nk = 0; split("", keys)
        n = split(pb, A, ","); for (i = 1; i <= n; i++) { if (split(A[i], B, ":") < 4) continue; d = B[1]; if (!(d in D)) { keys[++nk] = d; D[d] = 0; E[d] = 0; M[d] = 0; L[d] = 0 }; D[d] += B[2]; E[d] += B[3]; M[d] += B[4] }
        n = split(lb, A, ","); for (i = 1; i <= n; i++) { if (split(A[i], B, ":") < 2) continue; d = B[1]; if (!(d in D)) { keys[++nk] = d; D[d] = 0; E[d] = 0; M[d] = 0; L[d] = 0 }; L[d] += B[2] }
        for (i = 2; i <= nk; i++) { v = keys[i]; j = i - 1; while (j >= 1 && keys[j] > v) { keys[j+1] = keys[j]; j-- } keys[j+1] = v }
        out = ""; for (i = 1; i <= nk; i++) { d = keys[i]; out = out (out == "" ? "" : ",") d ":" D[d] ":" E[d] ":" M[d] ":" L[d] }
        return out
    }
    # the Active cell (2026-09-20) — the Subscriptions page rules: CFT for a
    # SWIFT name, blank when the JSON does not name the flow, Yes, else the
    # codes with their words as the hover title ("; "-joined — the cell attr
    # list splits on ",")
    function actcell(u, sk,   ak, c, n3, A3, W3, i3, o, t) {
        if (index(u, "SWIFT") > 0) return "@{class=act,title=SWIFT: runs through CFT}CFT"
        ak = (u in AN) ? u : ((sk != "" && (sk in AN)) ? sk : resolve(u, AU, nak, AN, 2))
        if (ak == "") return "@{class=act}"
        c = AC[ak]; if (c == "") return "@{class=act}Yes"
        split("status Undeployed|status SAVED_NOT_DEPLOYED|schedule No|folder monitoring Inactive", W3, "|")
        n3 = split(c, A3, ","); o = ""; t = ""
        for (i3 = 1; i3 <= n3; i3++) { o = o (o == "" ? "" : ", ") A3[i3]; t = t (t == "" ? "" : "; ") A3[i3] " " W3[A3[i3] + 0] }
        return "@{class=act,title=" t "}" o
    }
    function emit(name, u, pk, lk, sk,   cronx, sched, obs, polls, empty, matched, pct, lst, starts, fails, why, ll, nm) {
        # UC3 ONLY (2026-09-13): in the UC3 status roster, or UC3-named
        if (sk == "" && toupper(substr(name, 1, 3)) != "UC3") return
        cronx = ""; sched = ""; obs = ""; starts = ""; fails = ""; why = ""
        if (u in CN) { cronx = CC[u]; sched = CS[u]; obs = (CBAD[u] ? "@{class=obsbad}" : "") CO[u]
                       if (CST[u] > 0) starts = CST[u]; if (CFL[u] > 0) fails = CFL[u]; why = CWHY[u] }
        else sched = "no cron"   # a UC3 without a receive schedule: it never polls on its own (the former Missing cronjobs page, 2026-09-29)
        polls = "-"; empty = ""; matched = ""; pct = ""; ll = ""; lst = ""
        if (pk != "") { polls = PP[pk]; empty = PE[pk]; matched = PM[pk]; pct = PPCT[pk]; ll = PLL[pk] }
        else if (u in CN && CPOLLS[u] > 0) polls = CPOLLS[u]
        if (lk != "") lst = LE[lk]
        if (ll == "" && sk != "") ll = SDL[sk]   # no poll lines: the status drill (the lines that decided the status)
        nm = "@{alink=subscriptions/" name "}" name
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n", \
            nm, actcell(u, sk), cronx, sched, (obs != "" ? obs : (pk != "" ? "" : "-")), polls, empty, matched, pct, lst, starts, fails, why, buckets((pk != "" ? PB[pk] : ""), (lk != "" ? LB[lk] : "")), ll
        # the totals (this pass): rows, polls, empty, matched, listing, starts, failures, schedules, never
        NR9++; if (polls != "-" && polls != "") TP += polls; TE += empty; TM += matched; TL += lst; TS += starts; TF += fails
        if (u in CN) { NC++; if (CNEV[u]) NNEV++ }
    }
    END {
        # cron rows first (their own order), then the poll-only names
        for (i = 1; i <= nck; i++) { u = CU[i]
            pk = resolve(u, PU, npk, PN, 1); lk = resolve(u, LU, nlk, LN, 1); sk = resolve(u, SU, nsk, SN, 1)
            if (pk != "") used[pk] = 1; if (lk != "") usedl[lk] = 1; if (sk != "") useds[sk] = 1
            emit(CN[u], u, pk, lk, sk) }
        for (i = 1; i <= npk; i++) { u = PU[i]; if (u in used) continue
            lk = (u in LN) ? u : ""; if (lk != "") usedl[lk] = 1
            sk = resolve(u, SU, nsk, SN, 2); if (sk != "") useds[sk] = 1
            emit(PN[u], u, u, lk, sk) }
        for (i = 1; i <= nlk; i++) { u = LU[i]; if (u in usedl) continue
            sk = resolve(u, SU, nsk, SN, 2); if (sk != "") useds[sk] = 1
            emit(LN[u], u, "", u, sk) }
        # the configured UC3 flows nothing else knows: never seen polling, no cron
        for (i = 1; i <= nsk; i++) { u = SU[i]; if (u in useds) continue
            emit(SN[u], u, "", "", u) }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", NR9+0, TP+0, TE+0, TM+0, TL+0, TS+0, TF+0, NC+0, NNEV+0
    }')
IFS=$'\t' read -r _ n_rows t_polls t_empty t_matched t_list t_starts t_fails n_cron n_never <<< "$(printf '%s\n' "$agg" | command grep $'^TOT\t')"
pct_empty=$(awk -v p="$t_polls" -v e="$t_empty" 'BEGIN { printf "%.1f%%", (p > 0 ? 100 * e / p : 0) }')

{
    printf 'TITLE\tPolling\n'
    printf 'DESC\tEvery UC3 polling subscription in one row — whether it is active, its configured cron expression and schedule, and what the server log observed: polls, empty polls, files matched, listing failures, the poll starts and failure lines of a schedule that never completes, and the contradiction alarm.\n'
    printf 'TABLE\tPolling\twide\n'   # (its anchor=polling went 2026-09-29: the heading is dropped, nothing linked it)
    printf 'HEAD\tSubscription\tActive\tCron expression\tSchedule\tObserved\tPolls\tEmpty polls\tFiles matched\tEmpty %%\tListing errors\tPoll starts\tFailure lines\tWhat goes wrong\n'
    printf 'KIND\tmono\ttext\tmono\ttext\ttext\tnum\tnumwarn\tnumprocessed\tnum\tnumfailed\tnum\tnum\ttext\n'
    printf 'RECALC\t-\t-\t-\t-\t-\ts0\ts1\ts2\tp1.0\ts3\t-\t-\t-\n'
    printf '%s\n' "$agg" | command grep $'^ROW\t' || true
    printf 'TOTAL\tTotal (%s subscription(s))\t\t\t\t\t@{class=num}%s\t@{class=num warn}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num failed}%s\t@{class=num}%s\t@{class=num}%s\t\n' \
        "$n_rows" "$t_polls" "$t_empty" "$t_matched" "$pct_empty" "$t_list" "$t_starts" "$t_fails"
    printf 'LINK\thttps://www.quartz-scheduler.org/documentation/quartz-2.3.0/tutorials/crontrigger.html\tQuartz cron trigger reference\n'
    printf 'SUMMARY	UC3 polling subscriptions: %s  |  Polls: %s  |  Empty: %s  |  Listing failures: %s  |  Cron schedules: %s  |  Never complete a poll: %s
' "$n_rows" "$t_polls" "$pct_empty" "$t_list" "$n_cron" "$n_never"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_rows row(s): $n_cron with a cron schedule, $t_polls poll(s))." >&2
