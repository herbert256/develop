#!/usr/bin/env bash
#
# uc3-polling.sh — the UC3 tab's POLLING tables (2026-09-05, user request: "one
# report about us polling partners"): the former Remote polls report and the
# former analyses Cronjobs page, folded onto uc-status-uc3.html. Writes
# data/<env>/server/reports/uc3-polling.rpt, the component
# bin/analyses/reports/uc-status.sh merges right behind uc3-status.rpt; every
# TABLE carries tab=uc3, so publish_lib's segment_rpt keeps them on the UC3 tab
# page, stacked under the status table, instead of opening tab pages of their
# own. (This script lives in bin/analyses/reports/ because its PAGE is in the
# Analyses menu; it sources the SERVER lib because its DATA is server data.)
#
#   Polls by subscription             } copied from remote-poll.rpt's TABLE blocks
#   Remote directory listing failures } (bin/server/reports/remote-poll.sh, an
#                                       unpublished intermediate since 2026-09-05;
#                                       its first table is also entity-coverage's
#                                       Out proof) — RECALC/@data:buckets/drills
#                                       come along verbatim
#   Configured cronjobs               } the former bin/analyses/publish.sh
#   Schedules that never complete     } write_cronjobs_page (hand-written HTML),
#   a poll                            } re-emitted as .rpt tables
#
# Runs AFTER the server report pool (bin/server/reports.sh): it reads
# remote-poll.rpt and its two sidecars poll-times.tsv / poll-failures.tsv, the
# transfer punctuality.rpt (the file-arrival fallback slot), the config export
# (the cron expressions, via jq + bin/cron2human.awk) and the subscription ->
# host xref (the host-keyed authentication failures).
#
# Usage:
#   ./uc3-polling.sh   # -> data/<env>/server/reports/uc3-polling.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../server/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc3-polling.rpt"
RP="$REPORTS_DIR/remote-poll.rpt"
PT="$REPORTS_DIR/poll-times.tsv"
PF="$REPORTS_DIR/poll-failures.tsv"
PUNCT="$TRANSFER_REPORTS/punctuality.rpt"
SUBJSON="$FM_INPUT_DIR/subscriptions.json"   # the SKIP-filtered copy when present (server/lib.sh)
XSH="$CONFIG_XREF/_subscriptions-hosts.tsv"
CRON_AWK="$ROOT/bin/cron2human.awk"
ensure_config

if [ ! -f "$RP" ] && [ ! -f "$SUBJSON" ]; then
    rm -f "$OUT"; echo "uc3-polling: neither remote-poll.rpt nor a config export — nothing to add to the UC3 tab." >&2; exit 0
fi
# a VANISHED input must force a rebuild: skip_if_fresh only sees NEWER deps,
# so an .rpt still carrying the table of an input that is gone is dropped
if [ -f "$OUT" ]; then
    if [ ! -f "$RP" ] && command grep -q $'^HEAD\tSubscription\tPolls\t' "$OUT"; then rm -f "$OUT"; fi
fi
if [ -f "$OUT" ]; then
    if [ ! -f "$SUBJSON" ] && command grep -q $'^TABLE\tConfigured cronjobs' "$OUT"; then rm -f "$OUT"; fi
fi
deps=()
for d in "$RP" "$PT" "$PF" "$PUNCT" "$SUBJSON" "$XSH" "$CRON_AWK"; do [ -f "$d" ] && deps+=("$d"); done
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" ${deps[@]+"${deps[@]}"}
echo "uc3-polling: building the UC3 tab's polling tables ..." >&2

# ---- (c)+(d): the cron tables, computed first (the emit block below prints in page order)
crows=""; xrows=""; total=0; sftp=0; ftp=0; distinct=0; sumpolls=0
if [ -f "$SUBJSON" ] && command -v jq >/dev/null 2>&1; then
    # name ⇥ PROTO ⇥ cron ⇥ human — cron2human.awk (shared with details.sh)
    # appends the plain-English column
    rows=$(jq -r '
        .[] | . as $s
        | (["sftp","ftp"][] as $p
           | ($s.parameters["hybrid_partner_\($p)_relay0_receive_scheduler_cron_expression"]) as $c
           | select($c != null and $c != "")
           | [ $s.name, ($p|ascii_upcase), $c ] | @tsv)
      ' "$SUBJSON" | awk -F'\t' -v CF=3 -f "$CRON_AWK" | LC_ALL=C sort -f)
    # `grep -c .` exits 1 on zero matches — an env with NO cron-scheduled
    # subscriptions must not abort under set -e
    total=$(printf '%s\n' "$rows" | grep -c . || true)
    sftp=$(printf '%s\n' "$rows" | awk -F'\t' '$2=="SFTP"' | grep -c . || true)
    ftp=$(printf '%s\n' "$rows"  | awk -F'\t' '$2=="FTP"'  | grep -c . || true)
    distinct=$(printf '%s\n' "$rows" | cut -f3 | LC_ALL=C sort -u | grep -c . || true)
    _pu="$PUNCT"; [ -f "$_pu" ] || _pu=/dev/null
    _pt="$PT";    [ -f "$_pt" ] || _pt=/dev/null
    _pf="$PF";    [ -f "$_pf" ] || _pf=/dev/null
    _xs="$XSH";   [ -f "$_xs" ] || _xs=/dev/null
    # ONE awk emits two row kinds: "C ⇥ ROW ⇥ …" (Configured cronjobs) and
    # "X ⇥ failures ⇥ starts ⇥ ROW ⇥ …" (the never-completes table, sorted by
    # the shell on its two leading numbers)
    body=$(printf '%s\n' "$rows" | awk -F'\t' -v PUNCT="$_pu" -v POLLT="$_pt" -v PF="$_pf" -v XSH="$_xs" '
        # one numeric cron field -> "count:min" (how many values it fires at
        # per cycle, and the smallest) — the Observed-vs-Schedule check
        function finfo(fld, cycle,   a, np, parts, i, seg, b, x, k, set, cnt, mn, st, step) {
            if (fld == "*" || fld == "?") return cycle ":0"
            if (fld ~ /^[0-9]+$/) return "1:" (fld+0)
            if (fld ~ /^([0-9]+|\*)\/[0-9]+$/) { split(fld, a, "/"); step = a[2]+0; st = (a[1] == "*" ? 0 : a[1]+0)
                if (step <= 0) return "1:" st
                cnt = 0; for (k = st; k < cycle; k += step) cnt++
                return cnt ":" st }
            split("", set)
            np = split(fld, parts, ",")
            for (i = 1; i <= np; i++) { seg = parts[i]
                if (seg ~ /-/) { split(seg, a, "-"); b = a[1]+0; x = a[2]+0; for (k = b; k <= x; k++) set[k] = 1 }
                else set[seg+0] = 1 }
            cnt = 0; mn = -1
            for (k = 0; k < cycle; k++) if (k in set) { cnt++; if (mn < 0) mn = k }
            return (cnt ? cnt : 1) ":" (mn < 0 ? 0 : mn)
        }
        # circular minute-of-day distance
        function mdist(a, b,   d) { d = a - b; if (d < 0) d = -d; if (1440 - d < d) d = 1440 - d; return d }
        # prefix either way (the server truncates long site names)
        function pfx(a, b) { return substr(a, 1, length(b)) == b || substr(b, 1, length(a)) == a }
        BEGIN {
            US = sprintf("%c", 31)
            # punctuality rows: site, days, typical, window, class — the
            # file-arrival fallback for schedules with no poll line
            while ((getline l < PUNCT) > 0) {
                n = split(l, a, "\t")
                if (a[1] != "ROW" || a[2] ~ /^@\{colspan/) continue
                u = toupper(a[2])
                if (!(u in PD) || a[3]+0 > PD[u]) { PD[u] = a[3]+0; PT[u] = a[4]; PW[u] = a[5]; PC[u] = a[6] }
            } close(PUNCT)
            npu = 0; for (u in PD) { npu++; PU[npu] = u }
            # poll-times.tsv (remote-poll.sh): name, polls, days, typical,
            # spread(min), class, polls/day — the schedule firing in the
            # SERVER log, empty polls included
            while ((getline l < POLLT) > 0) {
                n = split(l, a, "\t")
                if (n < 7 || a[1] == "") continue
                u = toupper(a[1])
                if (!(u in QN) || a[2]+0 > QN[u]) { QN[u] = a[2]+0; QD[u] = a[3]+0
                    QT[u] = a[4]; QW[u] = a[5]+0; QC[u] = a[6]; QPD[u] = a[7]+0 }
            } close(POLLT)
            nqu = 0; for (u in QN) { nqu++; QU[nqu] = u }
            # poll-failures.tsv (remote-poll.sh): S/C/L rows keyed by site,
            # A rows by HOST — per key the total count + the dominant reason
            while ((getline l < PF) > 0) { n = split(l, a, "\t")
                if (n < 3) continue
                if (a[1] == "S")      { u = toupper(a[2]); if (PS[u] == "") PSU[++nps] = u; PS[u] += a[3] }
                else if (a[1] == "C") { u = toupper(a[2]); if (PC2[u] == "") PCU[++npc] = u
                                        PC2[u] += a[3]; if (a[3]+0 > PCB[u]+0) { PCB[u] = a[3]+0; PCR[u] = a[4] } }
                else if (a[1] == "L") { u = toupper(a[2]); if (PL2[u] == "") PLU[++npl] = u
                                        PL2[u] += a[3]; if (a[3]+0 > PLB[u]+0) { PLB[u] = a[3]+0; PLR[u] = a[4] } }
                else if (a[1] == "A") { PA2[a[2]] += a[3]
                                        if (a[3]+0 > PAB[a[2]]+0) { PAB[a[2]] = a[3]+0; PAR[a[2]] = a[4] } }
            } close(PF)
            # subscription -> configured host(s), for the host-keyed A rows
            while ((getline l < XSH) > 0) { split(l, a, "\t")
                if (a[1] != "" && a[2] != "") HS[toupper(a[1])] = HS[toupper(a[1])] " " a[2] }
            close(XSH)
        }
        NF {
            name = $1; cronx = $3; human = $4
            un = toupper(name)
            # the schedule as numbers: expected firings/day E and the
            # earliest daily fire (minute-of-day), unioned over the row
            # cron expression(s) — dow only picks DAYS, so it is ignored
            # (observed rates are per ACTIVE day too)
            E = 0; early = -1
            nx = split(cronx, CX, US)
            for (i = 1; i <= nx; i++) {
                if (split(CX[i], CF2, /[ \t]+/) < 3) continue
                split(finfo(CF2[2], 60), A2, ":"); split(finfo(CF2[3], 24), A3, ":")
                E += A2[1] * A3[1]
                em = A3[2] * 60 + A2[2]
                if (early < 0 || em < early) early = em
            }
            # file-arrival observation (largest active-days prefix match)
            odays = 0; otyp = ""; owin = ""; ocls = ""
            for (i = 1; i <= npu; i++) { u = PU[i]
                if (substr(u, 1, length(un)) == un && PD[u] > odays) { odays = PD[u]; otyp = PT[u]; owin = PW[u]; ocls = PC[u] } }
            # the poll footprint (prefix BOTH ways — the server truncates
            # long site names); an exact name always wins
            polls = 0; ocell = ""
            if (un in QN) qk = un
            else {
                qk = ""
                for (i = 1; i <= nqu; i++) { u = QU[i]
                    if ((substr(u, 1, length(un)) == un || substr(un, 1, length(u)) == u) && QN[u] > polls) { qk = u; polls = QN[u] } }
            }
            if (qk != "") { polls = QN[qk]
                if (polls > 0) { odays = QD[qk]
                    ocell = (QPD[qk] <= 3) ? sprintf("%s ± %d min", QT[qk], QW[qk]) \
                                           : sprintf("~%d polls/day", QPD[qk]) }
            }
            if (polls == 0) ocell = (otyp != "") ? otyp " " owin " (" ocls ") · files" : "-"
            # Observed vs Schedule: dark-red the cell when the evidence
            # CONTRADICTS the cron — a slot schedule (<=3/day) whose median
            # first poll sits off the earliest scheduled fire, a rate more
            # than 3x off the expected one, or a continuous schedule seen
            # only as a daily slot. File-arrival evidence is compared only
            # for slot schedules (an interval poll collects whenever data
            # appears); a "-" (never observed) is absence, not contradiction.
            bad = 0
            if (E > 0 && early >= 0) {
                if (polls > 0) {
                    if (QPD[qk] > 3) { if (E <= 3 || QPD[qk] * 3 < E || QPD[qk] > E * 3) bad = 1 }
                    else if (E > 3) bad = 1
                    else { split(QT[qk], TT, ":")
                           tol = 2 * QW[qk] + 5; if (tol < 20) tol = 20
                           if (mdist(TT[1] * 60 + TT[2], early) > tol) bad = 1 }
                } else if (otyp != "" && E <= 3) {
                    split(otyp, TT, ":")
                    if (mdist(TT[1] * 60 + TT[2], early) > 30) bad = 1
                }
            }
            nm = "@{alink=subscriptions/" name "}" name
            ec = cronx; gsub(US, " ; ", ec)   # several expressions on one flow -> one mono cell
            # an Observed "-" row: collect its failure evidence for the
            # never-completes table (once per subscription — protocols share it)
            if (polls == 0 && otyp == "" && !(un in NEV)) {
                NEV[un] = 1
                st2 = 0; cf2 = 0; lf2 = 0; af2 = 0; best = 0; why = ""
                for (i = 1; i <= nps; i++) { u = PSU[i]
                    if (pfx(u, un) && PS[u] > st2) st2 = PS[u] }
                for (i = 1; i <= npc; i++) { u = PCU[i]
                    if (pfx(u, un)) { cf2 += PC2[u]
                        if (PCB[u]+0 > best) { best = PCB[u]+0; why = PCR[u] } } }
                for (i = 1; i <= npl; i++) { u = PLU[i]
                    if (pfx(u, un)) { lf2 += PL2[u]
                        if (PLB[u]+0 > best) { best = PLB[u]+0; why = PLR[u] " (after connecting)" } } }
                nh2 = split(HS[un], HH, " ")
                for (i = 1; i <= nh2; i++) { h2 = HH[i]
                    if (h2 != "" && (h2 in PA2)) { af2 += PA2[h2]
                        if (PAB[h2]+0 > best) { best = PAB[h2]+0; why = PAR[h2] } } }
                tot2 = cf2 + lf2 + af2
                printf "X\t%d\t%d\tROW\t%s\t%s\t%s\t%s\n", tot2, st2, nm, (st2 ? st2 : "-"), (tot2 ? tot2 : "-"), \
                    (why != "" ? why : "no failure line names this flow in the loaded logs")
            }
            printf "C\tROW\t%s\t%s\t%s\t%s%s\t%s\t%s\n", nm, ec, human, (bad ? "@{class=obsbad}" : ""), ocell, (polls ? polls : "-"), (odays ? odays : "-")
        }')
    crows=$(printf '%s\n' "$body" | command grep $'^C\t' | cut -f2- || true)
    xrows=$(printf '%s\n' "$body" | command grep $'^X\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k3,3nr -k5,5 || true)
    sumpolls=$(printf '%s\n' "$crows" | awk -F'\t' '$6 ~ /^[0-9]+$/ { s += $6 } END { print s+0 }')
fi

{
    printf 'TITLE\tUC3 polling\n'
    printf 'DESC\tThe polling evidence behind the UC3 status — polls per subscription, listing failures, the configured cron schedules against what the log observed, and the schedules that never complete a poll.\n'
    # ---- (a)+(b): remote-poll.rpt's TABLE blocks, verbatim (+ tab=uc3) ------
    if [ -f "$RP" ]; then
        awk -F'\t' '
            $1 == "INTRO" && !t { intro = $0; next }   # the figures paragraph -> the first NOTE under the polls table
            $1 == "TABLE" { t++; print $0 "\ttab=uc3" (t == 1 ? "\tanchor=polls" : ""); next }
            t && ($1 == "HEAD" || $1 == "GHEAD" || $1 == "KIND" || $1 == "RECALC" || $1 == "ROW" || $1 == "TOTAL") { print; next }
            t && $1 == "NOTE" { if (t == 1 && intro != "") { sub(/^INTRO/, "NOTE", intro); print intro; intro = "" }; print; next }
            { next }   # TITLE/DESC/SUMMARY/FOOT: the merged page has its own
        ' "$RP"
    else
        printf 'TABLE\tPolls by subscription\ttab=uc3\tanchor=polls\n'
        printf 'NOTE\tNo remote-poll lines ("Applying the search pattern … for transfer site …") in the loaded server log of this environment — no poll ran, or the export holds none.\n'
    fi
    # ---- (c) Configured cronjobs ------------------------------------------
    if [ -f "$SUBJSON" ]; then
        printf 'TABLE\tConfigured cronjobs\twide\tnofilter\ttab=uc3\tanchor=cronjobs\n'
        printf 'STAT\twhite\t%s\tpolling schedules\n' "$total"
        printf 'STAT\twhite\t%s\tSFTP\n' "$sftp"
        printf 'STAT\twhite\t%s\tFTP\n' "$ftp"
        printf 'STAT\twhite\t%s\tdistinct cron expressions\n' "$distinct"
        printf 'HEAD\tSubscription\tCron expression\tSchedule\tObserved\tPolls\tActive days\n'
        printf 'KIND\tmono\tmono\ttext\ttext\tnum\tnum\n'
        [ -n "$crows" ] && printf '%s\n' "$crows"
        printf 'TOTAL\tTotal (%s cronjobs)\t\t\t\t@{class=num}%s\t\n' "$total" "$sumpolls"
        printf 'NOTE\tThe client polling schedules in subscriptions.json, joined against what actually happens. Where we are the **client** and pull from the partner (**UC3**, and the pull side of UC5), SecureTransport connects to the server of the partner on a timer and collects whatever is waiting; the schedule is a Quartz cron expression (sec min hour day-of-month month day-of-week — reference below), translated to plain English in the **Schedule** column. UC1 is a client use case too, but pushes on directory scanning — no cron. All schedules are enabled; none skip holidays. Rows are tinted by the result of the subscription — **green** OK, **orange** never seen, **red** Error, **blue** seen only in the server log.\n'
        printf 'NOTE\t**Observed** says when the schedule actually fires — from the poll lines of the server log where they exist (the **Polls by subscription** table above: the median of the FIRST poll of each day, ± one standard deviation; a schedule firing more than 3× a day has no single slot and shows its poll rate instead), else from the file arrivals: slots marked **· files** fall back to the transfer **Punctuality** report (the same model over file arrivals). Matching is name-prefix, both ways (the server truncates long site names). A **-** means no poll and no File in the loaded logs — the schedule never fires. A **dark red** Observed cell contradicts its schedule: the observed slot sits off the scheduled time, the poll rate is more than 3× off the expected one, or a continuous schedule is only seen firing a few times a day.\n'
        printf 'LINK\thttps://www.quartz-scheduler.org/documentation/quartz-2.3.0/tutorials/crontrigger.html\tQuartz cron trigger reference\n'
        # ---- (d) Schedules that never complete a poll ----------------------
        if [ -n "$xrows" ]; then
            read -r x_n x_st x_fail <<< "$(printf '%s\n' "$xrows" | awk -F'\t' '{ n++; f += $2; s += $3 } END { printf "%d %d %d", n+0, s+0, f+0 }')"
            printf 'TABLE\tSchedules that never complete a poll\twide\tnofilter\ttab=uc3\n'
            printf 'HEAD\tSubscription\tPoll starts\tFailure lines\tWhat goes wrong\n'
            printf 'KIND\tmono\tnum\tnum\ttext\n'
            printf '%s\n' "$xrows" | cut -f4-
            printf 'TOTAL\tTotal (%s subscription(s))\t@{class=num}%s\t@{class=num}%s\t\n' "$x_n" "$x_st" "$x_fail"
            printf 'NOTE\tThe **%s** schedule(s) whose Observed column shows **-**: the server log holds **no completed poll** for them. Most DO fire — their setup lines appear right on the scheduled minutes (**Poll starts**) — but the poll dies before the listing. **What goes wrong** is the dominant failure line the server log pairs with the flow; **Failure lines** counts them all.\n' "$x_n"
            printf 'NOTE\tConnection and listing failures name the subscription in the log and are counted directly. **Authentication failures name only host + user**, so they are matched through the configured host of the subscription and can be shared between the flows of that host. A row with neither starts nor failure lines never fires at all in the loaded logs. The evidence comes from the same server-log pass as the Polls by subscription table above.\n'
        fi
    fi
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($(command grep -c '^TABLE' "$OUT") table(s): polls $( [ -f "$RP" ] && echo copied || echo absent ), $total cronjob(s))." >&2
