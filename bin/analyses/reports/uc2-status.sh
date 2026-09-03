#!/usr/bin/env bash
#
# uc2-status.sh — "UC2 status": the UC2 (partner collects from
# us) flows by outcome. UC2 ONLY (a pickup account = one with a UC2 subscription).
# Keyed by account/subscription. FIVE statuses — a complete partition from the
# signals expired / pickup / staged-a-file:
#   Never collected  files expired AND nothing ever collected
#   No files         partner logs in (pickups > 0) but the app never staged a file
#   Both             the partner provably collects, and files still expired
#   OK               collected and none expired — healthy
#   Nothing          no collection and no expiry — a quiet flow, one collected
#                    over CFT (invisible here), or only empty-handed visits
# Since 2026-08 "collects" needs PROOF (a collected File in the transfer
# log), not mere logon evidence — see the partition comment in END.
# Info boxes (STAT) show the per-status counts above the table.
# (Named "Pickup information" / basename pickups until 2026-07, renamed to pair
# with uc3-status.sh, its pull-side counterpart. The word "pickup" below still
# means the ACT of collecting — the domain term, not the report.)
#
# Detection is EXPIRY-based on purpose: a file the retention sweep deleted was
# collected by nobody. We tried arrival-based detection ("files staged AND no
# SSH pickup"), but 101 of 113 pickup subscriptions have an account that never
# logs an SSH pickup — most partners collect over CFT/PESIT, which ST's SSH log
# can't see — so arrival + no-pickup flags almost everything. The sweep deleting
# the file is the one reliable "uncollected" proof. But the deletion date is a
# lagging signal, so we ALSO show the ARRIVAL date (from the transfer log — when
# the app last staged a file for the flow), which is the actionable timeline.
#
# Signals:
#   Expired   "File Maintenance for account [X@FEnnn] finished. Deleted files
#             [/f1, /f2]." (server log) — files purged uncollected, per file.
#   Arrived   transfer _files.tsv: files this subscription staged for pickup
#             (dest_site = the subscription, movement = out) — the first/last
#             time the app fed the flow.
#   Pickup    "[Ssh Default] User with login name \"FEnnn\", associated with
#             'X@FEnnn'" (server log) — a successful partner SFTP logon.
#
# An account with expired files but ZERO successful pickups never collected over
# SSH/SFTP — the red flag. The signal is protocol-independent: a direct-SFTP
# pickup would log the connection, and a CFT pickup would have removed the file
# before it could expire.
#
# Reads data/_parse.tsv + the transfer _files.tsv cache; writes
# data/uc2-status.rpt. The subscription cell links to its detail page.
# The server signals are KEYED by account (that is the token the server lines
# carry); the ROWS are the (account, UC2 subscription) PAIRS — one per flow
# (2026-08-31 audit: it was one row per ACCOUNT labelled with its
# alphabetically-first UC2 flow, so a hybrid production account with eight
# UC2 flows showed one, and a broken flow hid behind a healthy sibling). The
# staged / collected / expired signals are this flow's own from the transfer
# cache; the pickup-attempt (logon) figures are the account's, shared by its
# flows — the partner logs on to the account. The account is not a column.
#
# Usage:
#   ./uc2-status.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SERVER lib, not the analyses one: this is a server-DATA report (it reads the
# server parse cache and writes data/<env>/server/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../../server/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/uc2-status.rpt"

TFILES="$TRANSFER_CACHE/_files.tsv"       # the logical-transfer cache (for arrival + subscription)
XREF="$CONFIG_XREF/_accounts-subscriptions.tsv"   # account -> its subscriptions (a pickup account = has a UC2 sub)
# the DERIVED use case map (bin/flow-manager.sh): a subscription with no UC
# name prefix whose pattern + movement say UC2 (the production hybrid flows)
# counts as a UC2 flow here exactly like a UC2_-named one
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"
[ -f "$UCDF" ] || UCDF=/dev/null
# the MULTI-FE-ACCOUNT maps (2026-08-31, user report — see the awk BEGIN):
# subscription -> its configured login(s), and how many logins the account has
SLF="$CONFIG_XREF/_subscriptions-logins.tsv"; [ -f "$SLF" ] || SLF=/dev/null
ALF="$CONFIG_XREF/_accounts-logins.tsv";      [ -f "$ALF" ] || ALF=/dev/null
# The per-HOUR status sidecar for the Overview's UC2 status card — written HERE
# because the classification lives here (cf. pesit-slots.tsv). date <TAB> hour
# <TAB> the FIVE statuses in STACK order: ok, both, no-files, never-collected,
# nothing. All three signals (expiry / pickup / staging) are timestamped and
# CUMULATIVE, so the state is carried forward; the Overview re-buckets by taking
# the LAST hour of each coarse slot, since a status is a STATE, never a sum.
SLOTS_OUT="$REPORTS_DIR/uc2-slots.tsv"
# The per-SUBSCRIPTION pickup sidecar for the detail pages' "Pickup
# information" table (subscription-verdict.awk renders it): one line per
# (account, UC2 subscription) pair —
#   sub <TAB> account <TAB> first-pickup <TAB> last-pickup <TAB> pickups <TAB>
#   pickups-with-files <TAB> files-picked-up <TAB> pattern <TAB>
#   delivery-logons <TAB> raw-logons <TAB> visits <TAB> collect-only-visits
#   <TAB> collect+deliver-visits <TAB> deliver-only-visits <TAB> empty-visits
#   <TAB> waiting-files <TAB> expired-files <TAB> shared-sessions
# (cols 11-15 are the account's VISIT classification — the uc2-visits report
# renders them; visits = the four classes summed. Cols 16-17 are THIS
# subscription's staged files still Waiting / Expired uncollected, from
# _files.tsv outcomes — the same figures its detail page's Waiting/Expired
# table carries. Col 18 is the account's SHARED-SESSION count: distinct
# transfer-log Session IDs — one id = one technical SSH connection — in
# which the account BOTH delivered (Inbound ssh) and collected (Outbound
# ssh, Processed) a file. THE one same-connection proof: the detail pages'
# "Connection shared with UC4 drop" row and the pickups report's UC4-drop
# flag fire on it, never on the time-window visit classes (2026-08).)
# Pickups are the ACCOUNT's classified PICKUP logons (shared across its UC2
# subscriptions) — or, on an account carrying SEVERAL FE logins (production
# 2026-08-31), the subscription's OWN LOGIN's: every logon-derived figure is
# scoped per (account, login) group there, since each login is a different
# partner credential and its logons say nothing about the other logins'
# flows. A logon whose session only DELIVERED files (an Inbound ssh
# row — the UC4 twin flow handing files over) is a delivery-logon, counted
# separately and NOT a pickup (2026-08). Pickups-with-files counts the pickup
# VISITS whose window collected a file of THIS subscription; files-picked-up is the subscription's Processed Files (so it matches
# its page's OK count); pattern = the cadence read from the median gap
# between the pickup logons ("Daily", "Every 15 minutes", …).
PICKUPS_OUT="$REPORTS_DIR/uc2-pickups.tsv"
TTRANS="$TRANSFER_CACHE/_transfers.tsv"   # collect-leg timestamps (Outbound rows)
# sublink() prefixes an @{alink=subscriptions/<name>} UNCONDITIONALLY — the
# renderer resolves the name through the details slugmap and drops the link when
# it has no page. So every configured subscription links to its detail page,
# including one whose UC2 account has no transfer activity (which used to be
# gated out because it is absent from the transfer account.rpt roster).
LINK_AWK='
    function sublink(s) { return (s != "") ? "@{alink=subscriptions/" s "}" : "" }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
ensure_config
[ -f "$SLOTS_OUT" ] && [ -f "$PICKUPS_OUT" ] || rm -f "$OUT"   # a missing sidecar must force a rebuild (skip_if_fresh checks $OUT only)
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TFILES" "$TTRANS" "$XREF" "$UCDF"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One awk over three inputs: _accounts-subscriptions (the account's UC2 sub), the
# transfer _files.tsv (arrival + whether a file was staged), then the server
# cache (expiry / pickups). The account token on the server lines is
# NAME@FEnnn — the only such token — so a single [A-Za-z0-9_.-]+@FE[0-9]+ match
# isolates it.
#   A <TAB> never <TAB> <sub cell> <TAB> account <TAB> expired <TAB>
#           first-arrived <TAB> last-arrived <TAB> pickups <TAB> last-pickup <TAB>
#           loglines
# (the account rides along as the row KEY — the guard below tests it — but it is
# not rendered; only the subscription cell reaches the table)
#   TOT <TAB> nnever <TAB> ncollects <TAB> total-expired <TAB> total-expired-never
agg=$(awk -F'\t' -v tf="$TFILES" -v tt="$TTRANS" -v xf="$XREF" -v ucdf="$UCDF" -v slf="$SLF" -v alf="$ALF" -v SL="$SLOTS_OUT" -v PKF="$PICKUPS_OUT" "$LOGLINES_AWK$LINK_AWK"'
    BEGIN { while ((getline ucl < ucdf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[2] == "UC2") ucd[toupper(uca[1])] = 1 } close(ucdf)
            # MULTI-FE ACCOUNTS (2026-08-31, user report: new in production —
            # one account carries SEVERAL FE logins, each serving its own
            # flows): the subscription -> login map and the per-account login
            # count. On an account with >= 2 configured logins every
            # LOGON-derived figure (pickup attempts, visits, cadence,
            # first/last pickup) is scoped to the subscription OWN login(s) —
            # a partner connecting with login A is no pickup evidence for the
            # flows of login B, which used to read "No files" (partner
            # connects, nothing staged) though THEIR partner never connected.
            # Single-login accounts keep the account rule, output-identical.
            while ((getline ucl < slf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[1] != "" && uca[2] != "") SUBL[toupper(uca[1])] = SUBL[toupper(uca[1])] SUBSEP toupper(uca[2]) } close(slf)
            while ((getline ucl < alf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[1] != "") aln[uca[1]]++ } close(alf) }
    function acctof(m,   a) { a=""; if (match(m, /[A-Za-z0-9_.-]+@FE[0-9]+/)) { a=substr(m,RSTART,RLENGTH); sub(/@.*/,"",a) } return a }
    # the per-(account,login) GROUP classification: the same visit rules as
    # the per-account loop in END, over the group own logon / delivery /
    # collect minutes (multi-FE accounts only — groups register only there)
    function classify_group(g,   nl, LG, m, nd, DM, nk, KM, nv, VB, VE, dj, kj, nat, lo, vi, hi, dhit, khit, li, k2, ATM, gh, dh, maxg, ng, half, c2, med, ns, SS, SE, maxd, meddur, gsp) {
        nl = 0
        if (g in lg0) for (m = lg0[g]; m <= lg1[g]; m++) if ((g SUBSEP m) in lgmG) LG[++nl] = m
        if (nl == 0) return
        nd = 0
        if (g in adG0) for (m = adG0[g]; m <= adG1[g]; m++) if ((g SUBSEP m) in admnG) DM[++nd] = m
        nk = 0
        if (g in ck0) for (m = ck0[g]; m <= ck1[g]; m++) if ((g SUBSEP m) in cmG) KM[++nk] = m
        nv = 0
        for (li = 1; li <= nl; li++) { if (li == 1 || LG[li] - LG[li - 1] > 30) VB[++nv] = LG[li]; VE[nv] = li }
        dj = 1; kj = 1; nat = 0; lo = 1
        for (vi = 1; vi <= nv; vi++) {
            hi = (vi < nv) ? VB[vi + 1] : 9999999999999
            dhit = 0; while (dj <= nd && DM[dj] < hi) { if (DM[dj] >= VB[vi]) dhit = 1; dj++ }
            khit = 0; while (kj <= nk && KM[kj] < hi) { if (KM[kj] >= VB[vi]) khit = 1; kj++ }
            vt2G[g]++
            if (dhit && khit) vb2G[g]++
            else if (dhit)    vd2G[g]++
            else if (khit)    vc2G[g]++
            else              vn2G[g]++
            for (li = lo; li <= VE[vi]; li++) {
                k2 = g SUBSEP LG[li]
                if (dhit && !khit) del2G[g] += lgcG[k2]
                else { attG[g] += lgcG[k2]; ATM[++nat] = LG[li]
                       hpaG[g SUBSEP int(LG[li] / 60)] = 1
                       if (fatG[g] == "" || ftsG[k2] < fatG[g]) fatG[g] = ftsG[k2]
                       if (latG[g] == "" || ltsG[k2] > latG[g]) latG[g] = ltsG[k2] }
            }
            lo = VE[vi] + 1
        }
        # cadence over the group pickup minutes — the two-scale rule of the
        # per-account loop, verbatim
        if (nat >= 3) {
            delete gh
            maxg = 0; ng = 0
            for (li = 2; li <= nat; li++) { gsp = ATM[li] - ATM[li - 1]; gh[gsp]++; ng++; if (gsp > maxg) maxg = gsp }
            half = int(ng / 2) + 1; c2 = 0; med = 0
            for (gsp = 1; gsp <= maxg; gsp++) if (gsp in gh) { c2 += gh[gsp]; if (c2 >= half) { med = gsp; break } }
            ns = 0
            for (li = 1; li <= nat; li++) {
                if (li == 1 || ATM[li] - ATM[li - 1] > 30) { SS[++ns] = ATM[li]; SE[ns] = ATM[li] }
                else SE[ns] = ATM[li]
            }
            # the median visit SPAN, whatever the visit count: short spans = a
            # bursty client, whose cadence is a statement about VISITS — and
            # fewer than 3 visits is no cadence at all (2026-09-03, user
            # report: one burst of 6 connections read "Continuous"), so the
            # label is then the plain visit count. A sustained single visit
            # (a poller the 30-minute rule never splits) keeps its real cadence.
            delete dh
            maxd = 0
            for (li = 1; li <= ns; li++) { gsp = SE[li] - SS[li]; dh[gsp]++; if (gsp > maxd) maxd = gsp }
            half = int((ns + 1) / 2); c2 = 0; meddur = 0
            for (gsp = 0; gsp <= maxd; gsp++) if (gsp in dh) { c2 += dh[gsp]; if (c2 >= half) { meddur = gsp; break } }
            if (meddur <= 15 && ns < 3) patG[g] = ns " visit" (ns == 1 ? "" : "s")
            else {
                if (meddur <= 15) {
                    delete gh
                    maxg = 0; ng = 0
                    for (li = 2; li <= ns; li++) { gsp = SS[li] - SS[li - 1]; gh[gsp]++; ng++; if (gsp > maxg) maxg = gsp }
                    half = int(ng / 2) + 1; c2 = 0
                    for (gsp = 1; gsp <= maxg; gsp++) if (gsp in gh) { c2 += gh[gsp]; if (c2 >= half) { med = gsp; break } }
                }
                patG[g] = patron(med)
            }
        }
    }
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
    function span(h) { if (hmin == "" || h < hmin) hmin = h; if (h > hmax) hmax = h }
    # minute-of-era from "YYYY-MM-DD" + "HH:MM…" (the pickup cadence + the
    # logon/collect session matching both work at minute resolution)
    function minof(d, t) { return jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 1440 + substr(t,1,2) * 60 + substr(t,4,2) + 0 }
    # the cadence label from the MEDIAN gap between logon minutes
    function patron(m,   n) {
        if (m <= 0)   return "Rarely"   # never an em dash (2026-09-03, user request)
        if (m <= 2)   return "Continuous"
        if (m < 58)   { n = int((m + 2.5) / 5) * 5; if (n < 5) n = 5; return "Every " n " minutes" }
        if (m <= 75)  return "Hourly"
        if (m < 1320) { n = int((m + 30) / 60); return (n <= 1) ? "Hourly" : "Every " n " hours" }
        n = int((m + 720) / 1440)
        if (n <= 1)   return "Daily"
        if (n >= 6 && n <= 8) return "Weekly"
        if (n <= 15)  return "Every " n " days"
        return "Rarely"
    }
    FILENAME == xf {                                         # account -> its UC2 (collect-from-us) subscription
        if ($2 ~ /^UC2/ || (toupper($2) in ucd)) { if (!($1 in pickupacct)) A[++na] = $1   # ordered roster for the visit classification
                           pickupacct[$1] = 1
                           pr[++npr] = $1 SUBSEP $2; u2s[toupper($2)] = 1 }          # every (account, UC2 sub) pair, ordered — the ROW roster
        next
    }
    FILENAME == tf {                                         # transfer _files.tsv: staged pickup files
        if ($12 != "" && $17 == "out") {                     # dest_site set, file movement OUT (collect from us)
            a = $3; s = $12; d = $4; ps = a SUBSEP s
            subc[ps]++                                       # per (account, subscription) staged count
            if ($2 == "Processed") { prc[ps]++; pco[$1] = 1 }   # collected (the page'\''s OK figure); CoreId feeds the collect-stamp filter
            else if ($2 == "Waiting") wtg[ps]++              # staged, still waiting for pickup
            else if ($2 == "Expired") { xpd[ps]++; xany[a] = 1   # expired uncollected (the retention sweep) — THIS flow'\''s own
                # col 22 = the deletion stamp: the hour this flow'\''s expiry
                # signal appears in the per-hour sidecar
                if ($22 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:/) {
                    hx = jdn(substr($22,1,4)+0, substr($22,6,2)+0, substr($22,9,2)+0) * 24 + int(substr($22,12,2)); span(hx); hexs[ps SUBSEP hx] = 1 } }
            stagedany[a] = 1                                 # this account staged >=1 pickup file
            if (d != "") { if (!(a in afst)||d<afst[a]) afst[a]=d; if (!(a in alst)||d>alst[a]) alst[a]=d
                           if (!(ps in sfst)||d<sfst[ps]) sfst[ps]=d; if (!(ps in slst)||d>slst[ps]) slst[ps]=d }
            if ($5 ~ /^[0-9][0-9]:/) { hs = $7 * 24 + int(substr($5, 1, 2)); span(hs); hst[a SUBSEP hs] = 1; hsts[ps SUBSEP hs] = 1 }
        }
        next
    }
    FILENAME == tt {                                         # transfer _transfers.tsv: the COLLECT legs (partner downloads)
        # only legs of a PROCESSED File (pco, from the tf pass just before)
        # count as collect stamps, so "pickups with actual files" can never
        # exceed what "files picked up" shows
        if ($2 == "Outbound" && $6 != "" && $11 != "" && $12 ~ /^[0-9][0-9]:/ && ($1 in pco)) {
            su = toupper($6)
            if (su in u2s) {
                st = $3; sub(/ Subtransmission$/, "", st)
                if (st == "Processed") {
                    # ONE stamp per File — its newest Processed collect leg
                    # (a retried/split collect has several) — so a File can
                    # credit only one pickup session; materialized into the
                    # cmn minute set in END
                    cm = minof($11, $12)
                    if (cm > ccm[$1] + 0) { ccm[$1] = cm; csu[$1] = su; cac[$1] = $4; clg[$1] = toupper($5) }   # + the leg account/login (the multi-FE groups)
                    # SHARED-SESSION proof (2026-08): an ssh collect leg
                    # carries the technical connection id (col 24); a session
                    # in which the account ALSO delivered is counted once in
                    # shc[] — the counter is bumped by whichever side sees
                    # the pair complete, so no END iteration (hash order)
                    if ($10 == "ssh" && $4 != "" && ($4 in pickupacct) && $24 != "" && $24 != "UNKNOWN") {
                        k9 = $4 SUBSEP $24
                        if (!(k9 in sesC)) { sesC[k9] = 1; if ((k9 in sesD) && !(k9 in sesB)) { sesB[k9] = 1; shc[$4]++ } }
                    }
                }
            }
        }
        # DELIVERY minutes: an Inbound ssh row of a pickup account is the
        # partner handing a file over — the account'\''s UC4 twin flow. A
        # logon whose session only shows deliveries is NOT a pickup attempt
        # (2026-08); the classification happens per logon minute in END.
        if ($2 == "Inbound" && $10 == "ssh" && $4 != "" && ($4 in pickupacct) && $11 != "" && $12 ~ /^[0-9][0-9]:/) {
            dm = minof($11, $12)
            admn[$4 SUBSEP dm] = 1
            # the multi-FE mirror: the delivery minute per (account, login) —
            # the leg carries the login in col 5
            if (aln[$4] + 0 >= 2 && $5 != "" && $5 != "UNKNOWN") { gd9 = $4 SUBSEP toupper($5)
                admnG[gd9 SUBSEP dm] = 1
                if (!(gd9 in adG0) || dm < adG0[gd9]) adG0[gd9] = dm
                if (!(gd9 in adG1) || dm > adG1[gd9]) adG1[gd9] = dm }
            if (!($4 in ad0) || dm < ad0[$4]) ad0[$4] = dm
            if (!($4 in ad1) || dm > ad1[$4]) ad1[$4] = dm
            # the delivery side of the SHARED-SESSION pair (see the collect leg)
            if ($24 != "" && $24 != "UNKNOWN") {
                k9 = $4 SUBSEP $24
                if (!(k9 in sesD)) { sesD[k9] = 1; if ((k9 in sesC) && !(k9 in sesB)) { sesB[k9] = 1; shc[$4]++ } }
            }
        }
        next
    }
    {                                                        # server _parse.tsv
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        if (m ~ /Deleted files \[\//) {                      # File Maintenance actually deleted file(s)
            a = acctof(m); if (a == "") next
            nf = 0
            if (match(m, /Deleted files \[[^]]*\]/)) { content = substr(m, RSTART+15, RLENGTH-16); if (content != "") nf = split(content, z, ", ") }
            if (nf == 0) nf = 1
            ef[a] += nf; aseen[a] = 1
            if (d != "" && $2 ~ /^[0-9][0-9]:/) { hs = jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 24 + int(substr($2,1,2)); span(hs); hex[a SUBSEP hs] = 1 }
            addline(a, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
        } else if (m ~ /\[Ssh Default\] User with login name/ && m ~ /successfully authenticated/) {
            # THE logon signal (2026-08): exactly one such line per SSH logon,
            # over the whole log window. The "Allowed user … corresponding
            # account" line is NOT used: a mid-window logging change means it
            # only exists from 2026-07-06 in the acceptance window (it made
            # every first pickup look like Jul 6 and hid the earlier collects),
            # and it is a whitelist ADMISSION that can fire without successful
            # authentication — not a logon.
            a = acctof(m); if (a != "") { pk[a]++
                # the multi-FE mirror: the same minute bookkeeping per
                # (account, login) GROUP — recorded only for accounts with
                # several configured logins, so memory stays proportional
                lg9 = ""; if (match(m, /login name "[^"]*"/)) lg9 = toupper(substr(m, RSTART + 12, RLENGTH - 13))
                g9 = ""
                if (aln[a] + 0 >= 2) { g9 = a SUBSEP lg9
                    pkG[g9]++
                    if (!(g9 in GSEEN)) { GSEEN[g9] = 1; GRO[++ngr] = g9 } }
                if (d != "" && $2 ~ /^[0-9][0-9]:/) {
                    hs = jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 24 + int(substr($2,1,2)); span(hs)
                    ts = $1 " " $2
                    lm = minof(d, $2)
                    lgm[a SUBSEP lm] = 1                                # logon minutes (distinct)
                    lgc[a SUBSEP lm]++                                  # raw logons in that minute
                    if (fts[a SUBSEP lm] == "" || ts < fts[a SUBSEP lm]) fts[a SUBSEP lm] = ts
                    if (lts[a SUBSEP lm] == "" || ts > lts[a SUBSEP lm]) lts[a SUBSEP lm] = ts
                    if (!(a in lm0) || lm < lm0[a]) lm0[a] = lm
                    if (!(a in lm1) || lm > lm1[a]) lm1[a] = lm
                    if (g9 != "") { k9 = g9 SUBSEP lm
                        lgmG[k9] = 1; lgcG[k9]++
                        if (ftsG[k9] == "" || ts < ftsG[k9]) ftsG[k9] = ts
                        if (ltsG[k9] == "" || ts > ltsG[k9]) ltsG[k9] = ts
                        if (!(g9 in lg0) || lm < lg0[g9]) lg0[g9] = lm
                        if (!(g9 in lg1) || lm > lg1[g9]) lg1[g9] = lm }
                }
                addline("PK" SUBSEP a, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200)) }
        }
    }
    END {
        # ---- collect stamps, per sub and per account -------------------------
        # Materialize the per-File collect stamps (newest Processed leg per
        # CoreId) into the per-sub minute set; hash order here only FILLS a
        # set, it never reaches the output.
        for (cid in ccm) {
            su = csu[cid]; cm = ccm[cid]
            cmn[su SUBSEP cm] = 1
            h9 = int(cm / 60); span(h9); hcs[su SUBSEP h9] = 1   # this flow'\''s collect HOURS (the per-hour sidecar)
            if (!(su in cm0) || cm < cm0[su]) cm0[su] = cm
            if (!(su in cm1) || cm > cm1[su]) cm1[su] = cm
            # the multi-FE mirror: the collect minute per (account, login)
            if (aln[cac[cid]] + 0 >= 2 && clg[cid] != "" && clg[cid] != "UNKNOWN") { gk9 = cac[cid] SUBSEP clg[cid]
                cmG[gk9 SUBSEP cm] = 1
                if (!(gk9 in ck0) || cm < ck0[gk9]) ck0[gk9] = cm
                if (!(gk9 in ck1) || cm > ck1[gk9]) ck1[gk9] = cm }
        }
        # account-level collect minutes (any of the account'\''s UC2 subs) —
        # a logon that collected is a pickup even when it also delivered; the
        # HOURLY collect marks (hca) feed the per-hour sidecar, which must use
        # the same collection signal as the final partition
        for (i = 1; i <= npr; i++) {
            split(pr[i], PA, SUBSEP); a = PA[1]; su = toupper(PA[2])
            if (su in cm0) for (m = cm0[su]; m <= cm1[su]; m++) if ((su SUBSEP m) in cmn) {
                acm[a SUBSEP m] = 1
                if (!(a in ak0) || m < ak0[a]) ak0[a] = m
                if (!(a in ak1) || m > ak1[a]) ak1[a] = m
                h9 = int(m / 60); span(h9); hca[a SUBSEP h9] = 1
            }
        }
        # ---- per-account logon classification (2026-08) ----------------------
        # Logons group into VISITS (a gap > 30 min between logon minutes
        # starts a new one — an SFTP client opens several connections per
        # visit); every visit is classified by what its window (up to the
        # next visit) shows in the transfer log:
        #   collected (this account)      -> a PICKUP visit (even if it also
        #                                    delivered)
        #   only delivered (Inbound ssh)  -> a DELIVERY visit — the UC4 twin
        #                                    handing files over, NOT a pickup
        #   neither                       -> a pickup ATTEMPT (came, took
        #                                    nothing, delivered nothing)
        # att/del split the raw logon counts by their visit'\''s class;
        # fat/lat are the first/last PICKUP stamps; patA is the cadence over
        # the pickup minutes only; hpa marks the pickup HOURS for the
        # per-hour sidecar (the same signal the final partition uses, so the
        # two can never disagree).
        for (ai = 1; ai <= na; ai++) {
            a = A[ai]
            nl = 0
            if (a in lm0) for (m = lm0[a]; m <= lm1[a]; m++) if ((a SUBSEP m) in lgm) LG[++nl] = m
            if (nl == 0) continue
            nd = 0
            if (a in ad0) for (m = ad0[a]; m <= ad1[a]; m++) if ((a SUBSEP m) in admn) DM[++nd] = m
            nk = 0
            if (a in ak0) for (m = ak0[a]; m <= ak1[a]; m++) if ((a SUBSEP m) in acm) KM[++nk] = m
            # visits: VB[v] = first logon minute, VE[v] = index of the last
            # logon minute belonging to visit v
            nv = 0
            for (li = 1; li <= nl; li++) {
                if (li == 1 || LG[li] - LG[li - 1] > 30) { VB[++nv] = LG[li] }
                VE[nv] = li
            }
            dj = 1; kj = 1; nat = 0; lo = 1
            for (vi = 1; vi <= nv; vi++) {
                hi = (vi < nv) ? VB[vi + 1] : 9999999999999   # past any minute-of-era (jdn*1440 ~ 3.5e9 in 2026)
                dhit = 0; while (dj <= nd && DM[dj] < hi) { if (DM[dj] >= VB[vi]) dhit = 1; dj++ }
                khit = 0; while (kj <= nk && KM[kj] < hi) { if (KM[kj] >= VB[vi]) khit = 1; kj++ }
                # the per-class visit counts (the uc2-visits report)
                vt2[a]++
                if (dhit && khit) vb2[a]++
                else if (dhit)    vd2[a]++
                else if (khit)    vc2[a]++
                else              vn2[a]++
                for (li = lo; li <= VE[vi]; li++) {
                    k2 = a SUBSEP LG[li]
                    if (dhit && !khit) {
                        del[a] += lgc[k2]
                    } else {
                        att[a] += lgc[k2]
                        ATM[++nat] = LG[li]
                        hpa[a SUBSEP int(LG[li] / 60)] = 1
                        if (fat[a] == "" || fts[k2] < fat[a]) fat[a] = fts[k2]
                        if (lat[a] == "" || lts[k2] > lat[a]) lat[a] = lts[k2]
                    }
                }
                lo = VE[vi] + 1
            }
            # cadence over the PICKUP minutes, two-scale: a partner arriving
            # in short BURSTS of connections must read as how often it
            # VISITS, not as the burst spacing. Minutes collapse into visits
            # (a gap > 30 min starts a new one); when the visits themselves
            # are short (median span <= 15 min) the cadence is the median gap
            # between visit STARTS — otherwise (a sustained poller) the raw
            # median gap tells it straight.
            if (nat >= 3) {
                delete gh
                maxg = 0; ng = 0
                for (li = 2; li <= nat; li++) { g = ATM[li] - ATM[li - 1]; gh[g]++; ng++; if (g > maxg) maxg = g }
                half = int(ng / 2) + 1; c2 = 0; med = 0
                for (g = 1; g <= maxg; g++) if (g in gh) { c2 += gh[g]; if (c2 >= half) { med = g; break } }
                ns = 0
                for (li = 1; li <= nat; li++) {
                    if (li == 1 || ATM[li] - ATM[li - 1] > 30) { SS[++ns] = ATM[li]; SE[ns] = ATM[li] }
                    else SE[ns] = ATM[li]
                }
                # the median visit SPAN, whatever the visit count: short spans
                # = a bursty client, whose cadence is a statement about VISITS
                # — and fewer than 3 visits is no cadence at all (2026-09-03,
                # user report: one burst of 6 connections read "Continuous"),
                # so the label is then the plain visit count. A sustained
                # single visit (a poller the 30-minute rule never splits)
                # keeps its real cadence. classify_group() mirrors this.
                delete dh
                maxd = 0
                for (li = 1; li <= ns; li++) { g = SE[li] - SS[li]; dh[g]++; if (g > maxd) maxd = g }
                half = int((ns + 1) / 2); c2 = 0; meddur = 0
                for (g = 0; g <= maxd; g++) if (g in dh) { c2 += dh[g]; if (c2 >= half) { meddur = g; break } }
                delete dh
                if (meddur <= 15 && ns < 3) patA[a] = ns " visit" (ns == 1 ? "" : "s")
                else {
                    if (meddur <= 15) {
                        delete gh
                        maxg = 0; ng = 0
                        for (li = 2; li <= ns; li++) { g = SS[li] - SS[li - 1]; gh[g]++; ng++; if (g > maxg) maxg = g }
                        half = int(ng / 2) + 1; c2 = 0
                        for (g = 1; g <= maxg; g++) if (g in gh) { c2 += gh[g]; if (c2 >= half) { med = g; break } }
                    }
                    patA[a] = patron(med)
                }
            }
        }
        # the multi-FE groups get the same classification, per (account, login)
        for (gi = 1; gi <= ngr; gi++) classify_group(GRO[gi])
        nnever=0; nnofiles=0; ncoll=0; nok=0; nnothing=0; tef=0; tefn=0; tpk=0
        # One pass over the (account, UC2 subscription) PAIRS — one row per
        # flow — a COMPLETE partition from the signals expired(e) /
        # attempted(p) / staged-a-file(sh) / COLLECTED(c). Since 2026-08 the
        # collects side needs PROOF: c = at least one File of THIS flow
        # actually collected (transfer log), not mere logon evidence — a
        # partner that visits but never takes anything no longer reads as
        # "collecting". The attempt signal p keeps one job: distinguishing
        # "No files" (the partner DOES come, nothing is ever staged); it is
        # the ACCOUNT'\''s, the SSH logon being to the account. A pure-CFT
        # collector behaves exactly as before: no visible collect legs, no SSH
        # logons — Nothing, or Never collected once files expire.
        # The EXPIRY signal (2026-08-31): this flow'\''s own expired Files
        # (the retention sweep joined onto ITS staged files, _files.tsv col 2)
        # when any flow of the account has such attributable expiries; else
        # the account'\''s server-side deletion evidence, which then holds for
        # every flow of the account — attribute when possible, warn all when
        # not. (A single-flow account reads exactly as before.)
        #   0 Never collected  e & !c        files expired, nothing ever collected
        #   1 No files        !e &  p & !sh  partner logs in but nothing was staged
        #   2 Both             e &  c        collects, and files still expired
        #   3 OK              !e &  c &  sh  collected and none expired — healthy
        #   4 Nothing          everything else (quiet, CFT-collected, or only
        #                      empty-handed visits so far)
        # Drill: deletes for the expiry rows, pickup logons for No files/OK,
        # nothing for Nothing. Walked over the ordered pr[] roster — never
        # "for (a in ...)", awk hash order must not reach output.
        for (i = 1; i <= npr; i++) {
            split(pr[i], PA, SUBSEP); a = PA[1]; s = PA[2]; su = toupper(s); ps = a SUBSEP s
            attr = (a in xany)                                   # expiries attributable per flow on this account
            e = attr ? (xpd[ps] + 0 > 0) : (a in aseen)
            efp = attr ? xpd[ps] + 0 : ef[a] + 0                 # the Expired column: this flow'\''s, or the account'\''s
            # the LOGON-derived figures per pair (attP/delP/pkP/fatP/latP/
            # patP + the visit classes): the subscription OWN login group(s)
            # on a multi-FE account (scP=1), else the account figures — see
            # the BEGIN comment. Stored per ps; the two sidecar walks reuse them.
            scP[ps] = (aln[a] + 0 >= 2 && SUBL[su] != "") ? 1 : 0
            if (scP[ps]) {
                attP[ps]=0; delP[ps]=0; pkP[ps]=0; fatP[ps]=""; latP[ps]=""; patP[ps]=""
                vtP[ps]=0; vcP[ps]=0; vbP[ps]=0; vdP[ps]=0; vnP[ps]=0
                nls = split(substr(SUBL[su], 2), LS9, SUBSEP)
                for (li9 = 1; li9 <= nls; li9++) { g9 = a SUBSEP LS9[li9]
                    attP[ps] += attG[g9]; delP[ps] += del2G[g9]; pkP[ps] += pkG[g9]
                    vtP[ps] += vt2G[g9]; vcP[ps] += vc2G[g9]; vbP[ps] += vb2G[g9]; vdP[ps] += vd2G[g9]; vnP[ps] += vn2G[g9]
                    if (fatG[g9] != "" && (fatP[ps] == "" || fatG[g9] < fatP[ps])) fatP[ps] = fatG[g9]
                    if (latG[g9] != "" && (latP[ps] == "" || latG[g9] > latP[ps])) latP[ps] = latG[g9]
                    if (patP[ps] == "" && patG[g9] != "") patP[ps] = patG[g9]
                }
            } else { attP[ps] = att[a]+0; delP[ps] = del[a]+0; pkP[ps] = pk[a]+0
                     fatP[ps] = fat[a]; latP[ps] = lat[a]; patP[ps] = patA[a]
                     vtP[ps] = vt2[a]+0; vcP[ps] = vc2[a]+0; vbP[ps] = vb2[a]+0; vdP[ps] = vd2[a]+0; vnP[ps] = vn2[a]+0 }
            p = (attP[ps] > 0); sh = (subc[ps] + 0 > 0); c = (su in cm0)
            if      (e && !c)         stc = 0
            else if (!e && p && !sh)  stc = 1
            else if (e &&  c)         stc = 2
            else if (!e && c && sh)   stc = 3
            else                      stc = 4
            dl = (stc==0 || stc==2) ? lastlines(a) : (stc==1 || stc==3) ? lastlines("PK" SUBSEP a) : ""
            printf "A\t%d\t%s%s\t%s\t%d\t%s\t%s\t%d\t%s\t%s\n", stc, sublink(s), s, a, efp, (ps in sfst?sfst[ps]:"-"), (ps in slst?slst[ps]:"-"), attP[ps], (latP[ps]=="" ? "-" : substr(latP[ps], 1, 10)), dl
            if (!(a in adone)) { adone[a] = 1; tef += ef[a]+0; tpk += att[a]+0 }   # account-level figures, once per account
            if      (stc==0) { nnever++; tefn += efp }
            else if (stc==1) nnofiles++
            else if (stc==2) ncoll++
            else if (stc==3) nok++
            else             nnothing++
        }
        # The per-hour sidecar: the SAME partition, over the cumulative signals as
        # they stood at the end of each hour (the pickup signal = the classified
        # pickup hours, hpa). Walked NUMERICALLY over the ordered pr[] roster —
        # never "for (a in ...)", awk hash order must not reach output.
        if (hmin != "" && SL != "") {
            for (h = hmin; h <= hmax; h++) {
                delete cnt
                for (i = 1; i <= npr; i++) {
                    split(pr[i], PA, SUBSEP); a = PA[1]; s = PA[2]; su = toupper(s); ps = a SUBSEP s
                    if ((a in xany) ? ((ps SUBSEP h) in hexs) : ((a SUBSEP h) in hex)) E[ps] = 1
                    if (scP[ps]) { nls = split(substr(SUBL[su], 2), LS9, SUBSEP)
                        for (li9 = 1; li9 <= nls; li9++) if (((a SUBSEP LS9[li9]) SUBSEP h) in hpaG) { P[ps] = 1; break } }
                    else if ((a SUBSEP h) in hpa)  P[ps] = 1
                    if ((ps SUBSEP h) in hsts) S[ps] = 1
                    if ((su SUBSEP h) in hcs)  C[ps] = 1
                    if      (E[ps] && !C[ps])            stc = 0
                    else if (!E[ps] && P[ps] && !S[ps])  stc = 1
                    else if (E[ps] &&  C[ps])            stc = 2
                    else if (!E[ps] && C[ps] &&  S[ps])  stc = 3
                    else                                 stc = 4
                    cnt[stc]++
                }
                printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", fromjdn(int(h/24)), h%24, \
                    cnt[3]+0, cnt[2]+0, cnt[1]+0, cnt[0]+0, cnt[4]+0 > SL
            }
            close(SL)
        }
        # ---- the per-subscription pickup sidecar (see PICKUPS_OUT above) ------
        # Walked NUMERICALLY over the ordered pr[] pair roster — never hash
        # order. The logon figures are the account'\''s (shared across its UC2
        # subs); wf and files-picked are this subscription'\''s own.
        for (i = 1; i <= npr; i++) {
            split(pr[i], PA, SUBSEP); a = PA[1]; s = PA[2]; su = toupper(s); ps = a SUBSEP s
            nl = 0
            if (scP[ps]) {
                # the pair logon minutes = the union over its login groups
                mn9 = ""; mx9 = ""
                nls = split(substr(SUBL[su], 2), LS9, SUBSEP)
                for (li9 = 1; li9 <= nls; li9++) { g9 = a SUBSEP LS9[li9]
                    if (g9 in lg0) { if (mn9 == "" || lg0[g9] < mn9) mn9 = lg0[g9]
                                     if (mx9 == "" || lg1[g9] > mx9) mx9 = lg1[g9] } }
                if (mn9 != "") for (m = mn9; m <= mx9; m++)
                    for (li9 = 1; li9 <= nls; li9++) if (((a SUBSEP LS9[li9]) SUBSEP m) in lgmG) { LG[++nl] = m; break }
            }
            else if (a in lm0) for (m = lm0[a]; m <= lm1[a]; m++) if ((a SUBSEP m) in lgm) LG[++nl] = m
            nc = 0
            if (su in cm0) for (m = cm0[su]; m <= cm1[su]; m++) if ((su SUBSEP m) in cmn) CM[++nc] = m
            # PICKUPS with >=1 collect of THIS sub: each collect stamp
            # credits the newest logon MINUTE at or before it — the poll
            # that took the file — and wf counts the credited logon minutes.
            # NOT visits (2026-08): the 30-min visit rule collapses a
            # continuous poller (a logon every minute for weeks) into a
            # handful of visits, and wf read as 5 beside 78k pickups and
            # 2.3k files picked up (UC2_IT_EKDSI_RABOBANK). A collect BEFORE
            # the first logon — a CFT pickup, no SSH logon — still matches
            # nothing, by design; wf <= the collect-minute count <= Files
            # picked up, so the table stays internally consistent.
            wf = 0; j = 1
            for (li = 1; li <= nl; li++) {
                hi = (li < nl) ? LG[li + 1] : 9999999999999   # past any minute-of-era (jdn*1440 ~ 3.5e9 in 2026)
                hit = 0
                while (j <= nc && CM[j] < hi) { if (CM[j] >= LG[li]) hit = 1; j++ }
                if (hit) wf++
            }
            printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", s, a, \
                (fatP[ps] == "" ? "-" : fatP[ps]), (latP[ps] == "" ? "-" : latP[ps]), \
                attP[ps] + 0, wf, prc[ps] + 0, \
                (patP[ps] != "" ? patP[ps] : (attP[ps] + 0 > 0 ? "Rarely" : "")), delP[ps] + 0, pkP[ps] + 0, \
                vtP[ps] + 0, vcP[ps] + 0, vbP[ps] + 0, vdP[ps] + 0, vnP[ps] + 0, \
                wtg[ps] + 0, xpd[ps] + 0, shc[a] + 0 > PKF
        }
        close(PKF)
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", nnever, nnofiles, ncoll, nok, nnothing, tef, tefn, tpk
    }
' "$XREF" "$TFILES" "$TTRANS" "$PARSED")

IFS=$'\t' read -r _ n_never n_nofiles n_coll n_ok n_nothing t_ef t_efn t_pk <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "$(( n_never + n_nofiles + n_coll + n_ok + n_nothing ))" -eq 0 ]; then
    echo "No pickup activity found." >&2
    rm -f "$OUT" "$SLOTS_OUT" "$PICKUPS_OUT"   # no data for this ENV — page not published
    exit 0
fi

# Rows ordered by status (stc 0..4): Never collected, No files, Both,
# OK, Nothing; within a status by files-expired desc, then pickups desc — and
# then by sort(1)'s last-resort WHOLE-LINE compare, which is what orders the
# rest, so nothing may be added to or moved within an A line before the sort.
# ONE awk then turns each sorted A line into its ROW — the status label, an
# em-dash for an absent date, the loglines attribute; display order is Status,
# then the Subscription the flow IS. The account ($4) stays the row key and the
# guard, never a column. This was a bash while-read forking a $(printf) per row
# into an O(n^2) append.
rows=$(awk -F'\t' '
    $4 == "" { next }          # no account (and the blank line an empty stream feeds in)
    {
        st = ($2 == 0) ? "@{class=failed}Never collected" : \
             ($2 == 1) ? "@{class=warn}No files" : \
             ($2 == 2) ? "@{class=processed}Both" : \
             ($2 == 3) ? "@{class=processed}OK" : "Nothing"
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:loglines=%s\n", st, $3, $5, \
            ($6 == "-" ? "—" : $6), ($7 == "-" ? "—" : $7), $8, ($9 == "-" ? "—" : $9), $10
    }
' <<< "$(printf '%s\n' "$agg" | grep $'^A\t' | sort -t$'\t' -k2,2n -k5,5nr -k8,8nr)")
[ -n "$rows" ] && rows+=$'\n'   # put back the newline the command substitution stripped (the loop ended every row with one)

# A run with data but NO timestamped rows writes no sidecar at all, and the
# missing-sidecar guard above would then delete this .rpt on every build,
# for ever. An EMPTY sidecar is the valid "no per-hour data" answer (the
# unknown-* sidecars carry the same rule). Created only when absent, never
# touched — overview.rpt lists it as a dep and a bumped mtime would drag it.
[ -f "$SLOTS_OUT" ] || : > "$SLOTS_OUT"
[ -f "$PICKUPS_OUT" ] || : > "$PICKUPS_OUT"

{
    printf 'TITLE\tUC2 status\n'
    printf 'DESC\tEvery UC2 (partner collects from us) pickup flow, classified: files expired uncollected, partner logs in but nothing was staged, both collects and expiries, healthy, or nothing at all.\n'
    printf 'INTRO\tEvery **UC2** (partner collects from us) pickup flow, classified by outcome. **Never collected** = staged files expired and nothing was ever collected; **No files** = the partner logs in to collect but the app never staged a file; **Both** = the partner provably collects, yet files still expired; **OK** = collected and nothing expired; **Nothing** = no collection and no expiry (quiet, CFT-collected, or only empty-handed visits). "Collects" needs proof — a collected File in the transfer log, not mere logon evidence. **Arrived** is when the app last staged a file (transfer log). Click a row for its recent server-log lines.\n'

    printf 'STAT\twhite\t%s\tUC2 pickup flows\n' "$(( n_never + n_nofiles + n_coll + n_ok + n_nothing ))"
    printf 'STAT\tred\t%s\tNever collected\n' "$n_never"
    printf 'STAT\torange\t%s\tNo files\n' "$n_nofiles"
    printf 'STAT\tgreen\t%s\tBoth\n' "$n_coll"
    printf 'STAT\tgreen\t%s\tOK\n' "$n_ok"
    printf 'STAT\twhite\t%s\tNothing\n' "$n_nothing"

    printf 'TABLE\tUC2 subscriptions\twide\tnofilter\n'
    printf 'HEAD\tStatus\tSubscription\tExpired\tFirst\tLast\tPickups\tLast pickup\n'
    printf 'KIND\ttext\tmono\tnum\ttext\ttext\tnum\ttext\n'
    printf '%s\n' "$rows"   # %s\n: $rows already ends in one, so this is the blank line before TOTAL
    printf 'TOTAL\tTotal (%s subscription(s))\t\t@{class=num}%s\t\t\t@{class=num}%s\t\n' \
        "$(( n_never + n_nofiles + n_coll + n_ok + n_nothing ))" "$t_ef" "$t_pk"
    printf 'NOTE\tEvery **UC2** (collect-from-us) flow, classified. **Never collected** (red): File Maintenance deleted staged files and **nothing was ever collected** — logon visits alone do not count. **No files** (amber): the partner DOES log in to collect (pickups > 0) but the app **never staged a single file** — a dormant or broken source side. **Both** (green): the partner **provably collects** (Files in the transfer log) AND the odd file still expired — both outcomes on the one flow. **OK** (green): files collected, none expired — healthy. **Nothing** (plain): no collection and no expiry — a quiet flow, one whose partner collects over CFT (which logs no SSH pickup), or one whose visits have so far come up empty. Uncollected detection stays on the retention delete on purpose — arrival + no-pickup would flag almost every pickup flow, since CFT-collecting partners never log an SSH pickup; **No files** and **OK** need the SSH signal, so they only distinguish SFTP-collecting partners (a CFT partner with no expiry lands in **Nothing**). A logon whose session only **delivered** files (the account'\''s UC4 twin flow handing files over) is not a pickup and is not counted. **Arrived** dates come from the transfer log. One row per **flow**: an account serving several UC2 flows (the hybrid production accounts) lists each with its own staged, collected and expired Files, while the **Pickups** figures are the account'\''s — the partner logs on to the account, not to a flow. On an account carrying **several FE logins**, the Pickups figures are the flow'\''s own **login'\''s** instead: each login is a different partner credential, so its logons prove nothing about the other logins'\'' flows. Click a row for its recent server-log lines.\n'

    printf 'SUMMARY\tNever collected: %s  |  No files: %s  |  Both: %s  |  OK: %s  |  Nothing: %s  |  Files uncollected: %s\n' "$n_never" "$n_nofiles" "$n_coll" "$n_ok" "$n_nothing" "$t_efn"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n_never never-collected, $n_nofiles no-files, $n_coll both, $n_ok ok, $n_nothing nothing, $t_efn file(s) uncollected)." >&2
