# bin/cron-observed.awk — the configured cron schedules against the OBSERVED
# polling, shared text (2026-09-05): run with -f by
#   bin/analyses/reports/uc3-polling.sh   the UC3 tab's Configured cronjobs +
#                                         Schedules that never complete a poll
#   bin/analyses/reports/polling.sh       the flat Polling page (one row per
#                                         polling subscription)
# so both classify a schedule identically. Input rows (stdin, TAB):
#   name ⇥ PROTO ⇥ cron expression(s, \037-joined) ⇥ plain-English schedule
# (jq over subscriptions.json piped through bin/cron2human.awk -v CF=3).
# Variables: PUNCT (transfer punctuality.rpt — the file-arrival fallback slot),
# POLLT (poll-times.tsv), PF (poll-failures.tsv), XSH (subscription -> host
# xref) — each may be /dev/null. Output, one TAB line per input row:
#   name ⇥ cron (joined " ; ") ⇥ schedule ⇥ observed cell ⇥ bad (1 = the
#   evidence CONTRADICTS the cron) ⇥ polls ⇥ active days ⇥ never (1 = no
#   poll and no File observed) ⇥ poll starts ⇥ failure lines ⇥ what goes wrong
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
    # the failure evidence (poll starts, failure lines, the dominant
    # reason) — for EVERY row (the never-completes table takes the rows
    # with no observed poll; the flat Polling page shows them all)
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
    never = (polls == 0 && otyp == "") ? 1 : 0
    ec = cronx; gsub(US, " ; ", ec)   # several expressions on one flow -> one cell
    # name ⇥ cron ⇥ schedule ⇥ observed ⇥ bad ⇥ polls ⇥ active days ⇥ never ⇥ starts ⇥ failures ⇥ why
    printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", name, ec, human, ocell, bad, polls, odays, never, st2, tot2, why
}
