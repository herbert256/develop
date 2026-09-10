#!/usr/bin/env bash
#
# bin/sample/verify.sh — assert that a FULL BUILD over the generated sample
# estate produced what the generator planted. Run AFTER bin/fresh.sh:
#
#   bin/sample/verify.sh            # both environments
#
# Checks the parse caches and the report descriptors against
# input/<env>/.sample/_expected.tsv plus a fixed scenario list. Exit 0 with
# "verify: OK" when everything holds; every failed assertion is one FAIL line.
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
cd "$ROOT"

fails=0
ok()   { :; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
check() {   # check <condition-result 0|1> <label>
    if [ "$1" -eq 0 ]; then ok; else fail "$2"; fi
}
# rows <file> -> data row count (0 when absent)
rows() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
# rpt_rows <rpt> -> ROW-directive count
rpt_rows() { [ -f "$1" ] && grep -c $'^ROW\t' "$1" || echo 0; }
exp() {   # exp <env> <key> -> expected figure (0 when absent)
    awk -F'\t' -v k="$2" '$2 == k { print $3; f = 1 } END { if (!f) print 0 }' "input/$1/.sample/_expected.tsv"
}

for env in acceptance production; do
    EXP="input/$env/.sample/_expected.tsv"
    [ -f "$EXP" ] || { fail "[$env] no _expected.tsv (generator not run?)"; continue; }
    F="data/$env/transfer/cache/_files.tsv"
    T="data/$env/transfer/cache/_transfers.tsv"
    P="data/$env/server/cache/_parse.tsv"

    nf=$(rows "$F"); nt=$(rows "$T"); np=$(rows "$P")
    check $([ "$nf" -ge 3000 ] && echo 0 || echo 1) "[$env] _files.tsv rows $nf < 3000"
    check $([ "$np" -ge 10000 ] && echo 0 || echo 1) "[$env] _parse.tsv rows $np < 10000"
    r=$(awk -v a="$nt" -v b="$nf" 'BEGIN { print (b > 0 && a / b >= 1.8 && a / b <= 4.5) ? 0 : 1 }')
    check "$r" "[$env] legs/files ratio $nt/$nf outside 1.8..4.5"

    # outcomes: all four present; Expired + Waiting non-zero
    for oc in Processed Failed Expired Waiting; do
        n=$(awk -F'\t' -v o="$oc" '$2 == o { n++ } END { print n + 0 }' "$F")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] outcome $oc has 0 files"
    done
    # global failure share in a sane band (the monitor's near-all-OK beat and
    # production's quiet UC4-heavy mix keep the floor LOW, like the real estate)
    r=$(awk -F'\t' '$2 == "Failed" || $2 == "Expired" { e++ } END { s = e / NR * 100; print (s >= 1 && s <= 30) ? 0 : 1 }' "$F")
    check "$r" "[$env] failure share outside 1..30%"

    # every configured-and-seen flow attributed: no empty site in _files.tsv
    n=$(awk -F'\t' '$12 == "" { n++ } END { print n + 0 }' "$F")
    check $([ "$n" -eq 0 ] && echo 0 || echo 1) "[$env] $n files with EMPTY site"

    # colour distribution vs the estate's expectations (loose bands)
    B="data/$env/flow-manager/base/_subscriptions.tsv"
    blue=$(awk -F'\t' '$3 == "blue" { n++ } END { print n + 0 }' "$B")
    orange=$(awk -F'\t' '$3 == "orange" { n++ } END { print n + 0 }' "$B")
    eb=$(exp "$env" blue); eo=$(exp "$env" orange)
    check $([ "$blue" -ge $((eb / 2)) ] && echo 0 || echo 1) "[$env] blue subscriptions $blue < half of planted $eb"
    check $([ "$orange" -ge "$eo" ] && echo 0 || echo 1) "[$env] orange subscriptions $orange < planted $eo"
    gp=$(rows "data/$env/blue/_greenpoll.tsv")
    egp=$(exp "$env" greenpoll)
    [ "$egp" -gt 0 ] && check $([ "$gp" -gt 0 ] && echo 0 || echo 1) "[$env] greenpoll empty (planted $egp)"

    # the monitor dashboard flag
    check $([ -f "data/$env/dashboards/reports/monitor.rpt" ] && echo 0 || echo 1) "[$env] monitor.rpt missing"

    # the Logical entity derivation (bin/flow-manager.sh): every configured
    # FlowID maps to exactly one Logical, the entity report exists, and every
    # derived name is 3 "_"-parts or a fixed input/<env>/logical.txt target
    nmap=$(rows "data/$env/flow-manager/xref/_profiles-logicals.tsv")
    nprof=$(rows "data/$env/flow-manager/base/_profiles.tsv")
    check $([ "$nmap" -eq "$nprof" ] && echo 0 || echo 1) "[$env] FlowID map rows $nmap != profiles $nprof"
    n=$(rpt_rows "data/$env/transfer/reports/logical.rpt")
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] logical.rpt has 0 rows"
    n=$(awk -F'\t' 'FNR == NR { if ($0 !~ /^[ \t]*#/ && $0 !~ /^[ \t]*$/) { n2 = split($0, fa, /[ \t]+/); if (n2 >= 2 && fa[2] != "") fix[fa[2]] = 1 }; next }
        !($1 in fix) && split($1, P, "_") != 3 { n++ } END { print n + 0 }' \
        "input/$env/logical.txt" "data/$env/flow-manager/base/_logicals.tsv" 2>/dev/null || echo 0)
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] $n logical name(s) not 3-part and not pinned"

    # the BL entity (subscriptions.json tags entries starting with BL): the
    # subscription -> tag map is non-empty and the entity report has rows
    n=$(rows "data/$env/flow-manager/xref/_subscriptions-bl.tsv")
    check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] _subscriptions-bl.tsv is empty"
    # input/<env>/BL.txt rows join the tags (union, several per subscription):
    # the GLOBEX billing flow carries its BL_FIN tag AND the two planted numbers
    n=$(awk -F'\t' '$1=="UC1_FIN_BILLING_GLOBEX"' "data/$env/flow-manager/xref/_subscriptions-bl.tsv" 2>/dev/null | wc -l | tr -d ' ')
    check $([ "${n:-0}" -ge 3 ] && echo 0 || echo 1) "[$env] UC1_FIN_BILLING_GLOBEX has $n BL row(s), expected >= 3 (tag + input/$env/BL.txt)"
    # the "Added BL" sidecar + page (2026-09-01, user request): the BL.txt
    # rows the tags do NOT carry. The planted GLOBEX numbers are exactly that.
    n=$(awk -F'\t' '$1=="UC1_FIN_BILLING_GLOBEX"' "data/$env/flow-manager/xref/_subscriptions-bl-added.tsv" 2>/dev/null | wc -l | tr -d ' ')
    check $([ "${n:-0}" -ge 2 ] && echo 0 || echo 1) "[$env] _subscriptions-bl-added.tsv has $n row(s) for UC1_FIN_BILLING_GLOBEX, expected >= 2 (its input/$env/BL.txt numbers)"
    n=$(awk -F'\t' '$2 ~ /^BL_/' "data/$env/flow-manager/xref/_subscriptions-bl-added.tsv" 2>/dev/null | wc -l | tr -d ' ')
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] _subscriptions-bl-added.tsv carries $n tag-style BL_ value(s) — those come from subscriptions.json and must not count as added"
    check $([ -f "docs/$env/analyses/added-bl.html" ] && echo 0 || echo 1) "[$env] docs/$env/analyses/added-bl.html missing"
    # Partners - Incoming (2026-09-02): the page exists and its rows carry the login tints
    check $([ -f "docs/$env/analyses/fe-overview.html" ] && echo 0 || echo 1) "[$env] docs/$env/analyses/fe-overview.html missing"
    n=$(command grep -c '@data:res=' "data/$env/analyses/reports/fe-overview.rpt" 2>/dev/null || echo 0)
    check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] fe-overview.rpt has 0 tinted rows"
    # a LOGIN skip rule (2026-09-03, user report): the comm-profile login goes
    # from the configuration — no roster row, no detail page — and the Skipped
    # report lists it (the sample rule: login exact FE748281)
    check $([ ! -f "docs/$env/details/logins/fe748281.html" ] && echo 0 || echo 1) "[$env] docs/$env/details/logins/fe748281.html exists — the login skip rule did not reach the config roster"
    n=$(awk -F'\t' '$1=="FE748281"' "data/$env/flow-manager/base/_logins.tsv" 2>/dev/null | wc -l | tr -d ' ')
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] base/_logins.tsv still lists FE748281 (login skip rule)"
    if [ "$env" = production ]; then
        n=$(awk -F'\t' '$1=="Login" && $2=="FE748281"' "data/$env/flow-manager/filtered/_skipped.tsv" 2>/dev/null | wc -l | tr -d ' ')
        check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "[$env] filtered/_skipped.tsv has no Login row for FE748281"
    fi
    # the EXTENDED transfer-site fold (2026-09-01, user report): a logged
    # "<subscription>_<PROTO>_SERVER_<partner>" must be folded back onto its
    # subscription — unfolded, the flow is unattributed, its movement is
    # empty and the outcome rule can never say Processed
    n=$(awk -F'\t' '$12 ~ /_SFTP_SERVER_/ { n++ } END { print n+0 }' "$F")
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] $n file(s) keep an EXTENDED _SFTP_SERVER_ site (the fold did not fire)"
    if [ "$env" = production ]; then
        n=$(awk -F'\t' '$12=="UC3_APS_FMGENLOG_PIEDPIPER" && $2=="Processed" && $17=="in" { n++ } END { print n+0 }' "$F")
        check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] the extended-site flow UC3_APS_FMGENLOG_PIEDPIPER has 0 Processed file(s) with movement 'in'"
    fi
    # the UNCONFIGURED no-account name (2026-09-04): the funnel's own
    # "Unable to find account with username: svc-backup" rejection is a door
    # knocker — a Scanners row, never an Incoming row (it would be the one
    # Incoming row without a detail page)
    R="data/$env/server/reports/logon.rpt"
    inc=$(awk -F'\t' '$1=="TABLE" { t=$2 } $1=="ROW" && t=="Incoming" && index($2, "svc-backup") { n++ } END { print n+0 }' "$R" 2>/dev/null)
    scn=$(awk -F'\t' '$1=="TABLE" { t=$2 } $1=="ROW" && t ~ /scanner names/ && index($2, "svc-backup") { n++ } END { print n+0 }' "$R" 2>/dev/null)
    check $([ "${inc:-1}" -eq 0 ] && echo 0 || echo 1) "[$env] logon Incoming lists svc-backup ($inc row(s)), expected none (unconfigured no-account name is a door knocker)"
    check $([ "${scn:-0}" -ge 1 ] && echo 0 || echo 1) "[$env] logon Scanners lacks svc-backup, expected a row (the funnel no-account rejection)"
    # the PERSISTENT connection (2026-09-06, the FE000508 finding): the first
    # login's hourly re-key screenings count under Re-screens, not Allowed,
    # its row stays green, its weekly CMS-parsing pair lands in Session
    # errors — and the report's figures equal the detail pages' sidecar
    # (the two matchers must agree)
    rs=$(awk -F'\t' '$1=="TABLE" { t++ } t==1 && $1=="HEAD" { for (i=2;i<=NF;i++) { if ($i=="Re-screens") c=i; if ($i=="Session errors") x=i } } t==1 && $1=="ROW" && c && $c+0>0 && $x+0>0 && index($0, "@data:res=green") { n++ } END { print n+0 }' "$R" 2>/dev/null)
    check $([ "${rs:-0}" -ge 1 ] && echo 0 || echo 1) "[$env] logon Incoming has $rs green row(s) with both Re-screens and Session errors, expected the persistent connection"
    tw=$(awk -F'\t' -v LG="data/$env/server/cache/_logons.tsv" 'BEGIN { while ((getline l < LG) > 0) { split(l, A, "\t"); LA[A[1]] = A[6] + 0; LR[A[1]] = A[22] + 0; LX[A[1]] = A[23] + 0 } } $1=="TABLE" { t++ } t==1 && $1=="HEAD" { for (i=2;i<=NF;i++) { if ($i=="Allowed") a=i; if ($i=="Re-screens") c=i; if ($i=="Session errors") x=i } } t==1 && $1=="ROW" && c && ($a+0>0 || $c+0>0 || $x+0>0) { u=toupper($2); if (LA[u] != $a+0 || LR[u] != $c+0 || LX[u] != $x+0) bad++ } END { print bad+0 }' "$R" 2>/dev/null)
    check $([ "${tw:-1}" -eq 0 ] && echo 0 || echo 1) "[$env] $tw Incoming row(s) whose Allowed/Re-screens/Session errors differ from the _logons.tsv sidecar (the two matchers must agree)"
    # the MULTI-FE account (2026-08-31, user report): CD-PARCEL-BLUTH carries
    # TWO logins; its quiet second flow (its own login, never used) must read
    # Nothing — never "No files": the other login's logons are no pickup
    # evidence for it (uc2-status login scoping)
    if [ "$env" = production ]; then
        n=$(awk -F'\t' '$1=="CD-PARCEL-BLUTH"' "data/$env/flow-manager/xref/_accounts-logins.tsv" 2>/dev/null | wc -l | tr -d ' ')
        check $([ "${n:-0}" -eq 2 ] && echo 0 || echo 1) "[$env] CD-PARCEL-BLUTH has $n login(s), expected 2 (the multi-FE account)"
        st=$(awk -F'\t' '$1=="ROW" && index($0, "UC2_CD_PARCELX_BLUTH") { s=$2; sub(/^@\{[^}]*\}/, "", s); print s; exit }' "data/$env/server/reports/uc2-status.rpt" 2>/dev/null)
        check $([ "$st" = "Nothing" ] && echo 0 || echo 1) "[$env] UC2_CD_PARCELX_BLUTH uc2-status is '${st:-absent}', expected Nothing (multi-FE login scoping)"
        # Partners - Incoming (2026-09-02): the pickup sidecar joins to LOGINS, once per
        # login and account — the multi-FE account's pickups land on FE133269
        # alone (FE359263 stays empty), and the 8-flow GLOBEX account's count
        # lands once on FE343512 (never the x8 per-subscription repeat)
        R="data/$env/analyses/reports/fe-overview.rpt"; SC="data/$env/server/reports/uc2-pickups.tsv"
        # the Logon problems column (2026-09-04): the sample plants Disallowed
        # lines for configured logins, so at least one row carries a problem
        # cell whose lines link the Incoming page
        pc=$(awk -F'\t' '$1=="HEAD" { for (i=2;i<=NF;i++) if ($i=="Logon problems") c=i } $1=="ROW" && c && index($c, "logons-incoming.html?axway_row=") { n++ } END { print n+0 }' "$R" 2>/dev/null)
        check $([ "${pc:-0}" -ge 1 ] && echo 0 || echo 1) "[$env] Partners - Incoming has $pc row(s) with a Logon problems cell, expected at least 1 (the Disallowed logins)"
        pk=$(awk -F'\t' '$1=="HEAD" { for (i = 2; i <= NF; i++) if ($i == "Pickups") c = i } $1=="ROW" && $2=="FE133269" { print $c+0; exit }' "$R" 2>/dev/null)
        sp=$(awk -F'\t' '$1=="UC2_CD_PARCEL_BLUTH" { print $5+0; exit }' "$SC" 2>/dev/null)
        check $([ "${pk:-0}" -gt 0 ] && [ "$pk" = "${sp:-x}" ] && echo 0 || echo 1) "[$env] fe-overview FE133269 pickups '${pk:-absent}' != sidecar UC2_CD_PARCEL_BLUTH '${sp:-absent}'"
        pk=$(awk -F'\t' '$1=="HEAD" { for (i = 2; i <= NF; i++) if ($i == "Pickups") c = i } $1=="ROW" && $2=="FE359263" { print $c+0; exit }' "$R" 2>/dev/null)
        check $([ "${pk:-1}" -eq 0 ] && echo 0 || echo 1) "[$env] fe-overview FE359263 pickups '${pk:-absent}', expected empty (multi-FE login scoping)"
        pk=$(awk -F'\t' '$1=="HEAD" { for (i = 2; i <= NF; i++) if ($i == "Pickups") c = i } $1=="ROW" && $2=="FE343512" { print $c+0; exit }' "$R" 2>/dev/null)
        sp=$(awk -F'\t' '$1=="STMT_EXPORT_GLOBEX_01" { print $5+0; exit }' "$SC" 2>/dev/null)
        check $([ "${pk:-0}" -gt 0 ] && [ "$pk" = "${sp:-x}" ] && echo 0 || echo 1) "[$env] fe-overview FE343512 pickups '${pk:-absent}' != sidecar 393 once (the 8-flow account double-counted?)"
        # ... and entity-coverage: the quiet flow's own application PARCELX
        # must be NOT covered (red) — login A's logons are no In-side proof
        # for login B's flow — while PARCEL (flow A) is covered
        st=$(awk -F'\t' '$1=="ROW" && $2=="PARCELX" { print ($0 ~ /@data:res=red/) ? "red" : "notred"; exit }' "data/$env/transfer/reports/entity-coverage.rpt" 2>/dev/null)
        check $([ "$st" = "red" ] && echo 0 || echo 1) "[$env] entity-coverage PARCELX is '${st:-absent}', expected red / not covered (multi-FE logon-proof scoping)"
    fi
    # the IO ERRORS report (2026-09-06, user request): the tagged UC4 flow's
    # folder logs "IO Error reading file /data/FlowManager/<acct>@<login>/…"
    # — one folder row naming the account AND its login (the @ split), the
    # line list joined to the Files by name with BOTH states present (Failed:
    # the route never read the file; Processed: a retry did), the lines
    # attributed to the flow, and the Error/OK split ties to the line list
    if [ "$(exp "$env" ioerr)" -gt 0 ]; then
        R="data/$env/server/reports/io-errors.rpt"
        n=$(rpt_rows "$R")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] io-errors.rpt has 0 rows"
        n=$(awk -F'\t' '$1=="TABLE" { t++ } t==1 && $1=="ROW" && $3=="ZG-ZKA-HOOLI" && $4 ~ /^FE[0-9]+$/ && index($5, "UC4_ZG_ZKA_HOOLI") { n++ } END { print n+0 }' "$R" 2>/dev/null)
        check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "[$env] io-errors folder table has $n ZG-ZKA-HOOLI row(s) with an FE login and the UC4 subscription, expected 1"
        for st in Failed Processed; do
            n=$(awk -F'\t' -v s="@{class=failed}Failed" '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, s) { n++ } END { print n+0 }' "$R" 2>/dev/null)
            [ "$st" = Processed ] && n=$(awk -F'\t' '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, "@{class=processed}Processed") { n++ } END { print n+0 }' "$R" 2>/dev/null)
            check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] io-errors line list has no $st line (the file-name join to _files.tsv)"
        done
        n=$(awk -F'\t' '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, "not logged") { n++ } END { print n+0 }' "$R" 2>/dev/null)
        check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] io-errors line list has $n 'not logged' line(s) — every planted line names an uploaded file"
        e1=$(awk -F'\t' '$1=="TABLE" { t++ } t==1 && $1=="TOTAL" { v=$5; sub(/^@\{[^}]*\}/, "", v); print v+0; exit }' "$R" 2>/dev/null)
        e2=$(awk -F'\t' '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, "@{class=failed}") { n++ } END { print n+0 }' "$R" 2>/dev/null)
        check $([ "${e1:-0}" -gt 0 ] && [ "$e1" = "$e2" ] && echo 0 || echo 1) "[$env] io-errors Error total $e1 != $e2 Failed line(s) (one IO line per failed File in the sample)"
    fi
    # the EMPTY OUTBOUND SSH PROBES (2026-09-08, user request): the tagged
    # flow's lone Outbound ssh 0-byte records with Application "none" are
    # dropped from both caches (never a one-legged Failed File), set aside in
    # _skipped.csv, and the Skipped report lists them under their own reason
    if [ "$(exp "$env" sshprobe)" -gt 0 ]; then
        n=$(awk -F'\t' '$2=="Outbound" && $10=="ssh" && ($9+0)==0 && tolower($25)=="none" { c[$1]++ } END { for (k in c) n++; print n+0 }' "$T")
        check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] $n probe CoreId(s) (Outbound ssh, size 0, Application none) survived in _transfers.tsv"
        n=$(awk -F'\t' '$2=="Outbound" && $10=="ssh" && ($9+0)==0 && tolower($25)=="none" && NF>=25 { n++ } END { print n+0 }' "$T")
        check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] $n probe record(s) survived in _transfers.tsv"
        n=$(command grep -c ',"none",' "data/$env/transfer/_skipped.csv" 2>/dev/null || echo 0)
        check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] _skipped.csv holds no Application-none record (the planted probes were not set aside)"
        n=$(awk -F'\t' '$1=="ROW" && $3=="empty ssh probe" { n++ } END { print n+0 }' "data/$env/transfer/reports/skipped.rpt" 2>/dev/null)
        check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] skipped.rpt lists no 'empty ssh probe' row"
        n=$(awk -F'\t' 'NF < 25 { n++ } END { print n+0 }' "$T")
        check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] $n _transfers.tsv row(s) short of 25 columns"
    fi
    # the COLLECT DROP + ok BOOKEND (2026-09-09, user request): the JSON
    # transfer bookends are in the server cache (no longer noise-filtered) but
    # out of the mention rings; the tagged flow's torn-down collects — a Failed
    # ssh leg with an ok "Transfer end logged." on the CoreId and no error line
    # — are settled Processed by bin/bookend-ok.sh (col 23 = the ok stamp)
    if [ "$(exp "$env" collectdrop)" -gt 0 ]; then
        n=$(command grep -c 'Transfer end logged' "$P")
        check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] _parse.tsv holds no 'Transfer end logged' bookend (still noise-filtered?)"
        n=$(awk -F'\t' '$23 != "" { n++; if ($2 != "Processed") bad++ } END { print n+0 "\t" bad+0 }' "$F"); nb=${n#*	}; n=${n%	*}
        check $([ "${n:-0}" -gt 0 ] && [ "${nb:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] $n settled File(s) in _files.tsv ($nb not Processed) — expected some, all Processed"
        n=$(awk -F'\t' '$12=="UC2_ZG_MATCH_HOOLI" && $23 != "" { n++ } END { print n+0 }' "$F")
        check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] no settled File on UC2_ZG_MATCH_HOOLI (the collectdrop flow)"
        n=$(rows "data/$env/transfer/cache/_bookendok.tsv")
        check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] _bookendok.tsv is empty"
        n=$(command grep -c 'Transfer end logged' "data/$env/server/cache/_accounts.tsv" 2>/dev/null || true)   # grep -c prints the 0 itself (exit 1)
        check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] $n bookend(s) leaked into the account mention cache"
    fi
    # the UC3 that never transfers and CANNOT CONNECT (2026-09-10, user rule):
    # no File, every poll a Connection failure — red (not blue/orange), with
    # its newest failure in the _redflip sidecar, an error page of its own,
    # and a row on the home page's "Failing subscriptions in Server log"
    if [ "$(exp "$env" pollconnfail)" -gt 0 ]; then
        c=$(awk -F'\t' '$1=="UC3_ZG_RATES_OSCORP" { print $3 }' "$B")
        check $([ "$c" = red ] && echo 0 || echo 1) "[$env] UC3_ZG_RATES_OSCORP is '${c:-absent}', expected red (every poll a connection failure, no transfer)"
        n=$(awk -F'\t' '$12=="UC3_ZG_RATES_OSCORP" { n++ } END { print n+0 }' "$F")
        check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] UC3_ZG_RATES_OSCORP has $n File(s) — the sample must plant none"
        n=$(awk -F'\t' '$1=="UC3_ZG_RATES_OSCORP" { n++ } END { print n+0 }' "data/$env/blue/_redflip.tsv" 2>/dev/null)
        check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "[$env] _redflip.tsv has $n row(s) for UC3_ZG_RATES_OSCORP, expected 1"
        check $([ -f "docs/$env/errors/uc3-zg-rates-oscorp.html" ] && echo 0 || echo 1) "[$env] docs/$env/errors/uc3-zg-rates-oscorp.html missing (the server-failing error page)"
        n=$(awk 'BEGIN{RS="<h2"} /Failing subscriptions in Server log/ && /UC3_ZG_RATES_OSCORP/ { n++ } END { print n+0 }' docs/index.html 2>/dev/null)
        check $([ "${n:-0}" -ge 1 ] && echo 0 || echo 1) "[$env] the home worklist 'Failing subscriptions in Server log' does not list UC3_ZG_RATES_OSCORP"
    fi
    if [ "$env" = production ]; then
        # the MULTI-HOST account (2026-08-31): CD_ROUTE_WONKA carries TWO
        # endpoints, and its _ALT flow logs half its rows as the raw ADDRESS.
        # The endpoint vote rides the SUBSCRIPTION, so those rows must resolve
        # to the alt endpoint — never stay a raw IP (which would invent an
        # address-shaped host entity).
        n=$(awk -F'\t' '$1=="CD_ROUTE_WONKA"' "data/$env/flow-manager/xref/_accounts-hosts.tsv" 2>/dev/null | wc -l | tr -d ' ')
        check $([ "${n:-0}" -eq 2 ] && echo 0 || echo 1) "[$env] CD_ROUTE_WONKA has $n host(s), expected 2 (the multi-host account)"
        alth=$(awk -F'\t' '$1=="CD_ROUTE_WONKA" && $2 ~ /^sftp2\./ { print $2; exit }' "data/$env/flow-manager/xref/_accounts-hosts.tsv" 2>/dev/null)
        n=$(awk -F'\t' '$12=="UC3_CD_ROUTE_WONKA_ALT" && $15 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { n++ } END { print n+0 }' "$F")
        check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] UC3_CD_ROUTE_WONKA_ALT has $n file(s) with a RAW IP host (the multi-host endpoint vote failed)"
        n=$(awk -F'\t' -v h="${alth:-none}" '$12=="UC3_CD_ROUTE_WONKA_ALT" && $15==h { n++ } END { print n+0 }' "$F")
        check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "[$env] UC3_CD_ROUTE_WONKA_ALT has 0 file(s) on its own endpoint '${alth:-absent}'"
        # the endpoint's NEWER address is seeded into no map (see
        # bin/sample/generate.sh): the parse must LEARN it from the logged
        # rows, which only an unpoisoned endpoint vote does
        n=$(awk -F'\t' -v h="${alth:-none}" '$2==h { n++ } END { print n+0 }' "input/$env/ip/ip-hosts.tsv" 2>/dev/null)
        check $([ "${n:-0}" -ge 2 ] && echo 0 || echo 1) "[$env] ip-hosts.tsv maps $n address(es) to '${alth:-absent}', expected 2 (the parse must LEARN the endpoint's second address — a multi-host account must not poison the endpoint vote)"
    fi
    # the nine policy files are PER ENVIRONMENT (2026-08-31): present in the
    # env dir, and none left at the input root
    for pf in blacklist.txt skip.txt rename.txt logical.txt logical_domains.txt logical_apps.txt logical_partners.txt BL.txt coreid-url.txt; do
        check $([ -f "input/$env/$pf" ] && echo 0 || echo 1) "[$env] input/$env/$pf missing"
        check $([ ! -e "input/$pf" ] && echo 0 || echo 1) "input/$pf still at the input root (per-environment since 2026-08-31)"
    done
    # partner-aliases.tsv is RETIRED (2026-09-01): its pairs live in
    # logical_partners.txt as part replacements, so the misspelled GLOBEXX
    # token must never surface as a partner entity of its own
    check $([ ! -e "input/$env/partner-aliases.tsv" ] && echo 0 || echo 1) "[$env] input/$env/partner-aliases.tsv still exists (retired — fold it into logical_partners.txt)"
    n=$(awk -F'\t' '$1=="GLOBEXX" { n++ } END { print n+0 }' "data/$env/flow-manager/base/_partners.tsv" 2>/dev/null)
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "[$env] GLOBEXX is a partner entity of its own — the logical_partners.txt alias replacement did not fire"
    n=$(awk -F'\t' '$1=="GLOBEX" { n++ } END { print n+0 }' "data/$env/flow-manager/base/_partners.tsv" 2>/dev/null)
    check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "[$env] GLOBEX is not a partner entity (expected exactly 1 row)"
    n=$(rpt_rows "data/$env/transfer/reports/bl.rpt")
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] bl.rpt has 0 rows"

    # planted reports carry rows
    for rpt in expired waiting went-quiet duplicate-files; do
        n=$(rpt_rows "data/$env/transfer/reports/$rpt.rpt")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] $rpt.rpt has 0 rows"
    done
    n=$(rpt_rows "data/$env/transfer/reports/missing-cronjobs.rpt"); en=$(exp "$env" nocron)
    [ "$en" -gt 0 ] && check $([ "$n" -ge "$en" ] && echo 0 || echo 1) "[$env] missing-cronjobs rows $n < planted $en"

    # AV verdicts beyond Allowed/Not performed (acceptance plants Blocked+Error)
    if [ "$env" = acceptance ]; then
        n=$(awk -F'\t' '$17 == "Blocked" || $17 == "Error" { n++ } END { print n + 0 }' "$T")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] no Blocked/Error AV rows"
        n=$(rows "data/$env/transfer/cache/_sessionsites.tsv")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] _sessionsites.tsv empty (session join unexercised)"
        n=$(rows "data/$env/transfer/_skipped.tsv")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] skip list caught 0 transfer rows"
        n=$(awk -F'\t' '$6 ~ /^UCx_/ { n++ } END { print n + 0 }' "$T")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] no UCx_ synthetic-site legs"
        n=$(awk -F'\t' '$22 == "true" { n++ } END { print n + 0 }' "$T")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] no resubmitted legs"
    fi

    # production: the NON-UC-NAMED hybrid flows must come out attributed to
    # their real site (the reverse profile fallback) — never UCx_
    if [ "$env" = production ]; then
        n=$(awk -F'\t' '$12 ~ /^(STMT_EXPORT|INV_PAYMENTS|REC_FEEDS|GL_POSTINGS|CRM_SYNC|HR_ROSTER)/ { n++ } END { print n + 0 }' "$F")
        check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[$env] no files attributed to the non-UC hybrid flows"
    fi
done

# the failing-reasons catalogue: every planted category non-empty (acceptance);
# the "routestop" scenario (an ARSP0001 "while sending the file … to a partner
# site" line) reads "Could not send to CFT" since the 2026-09-06 wording rule
FR="data/acceptance/transfer/reports/failed-sub-all.rpt"
for reason in "Connection failures" "Wrong server fingerprint" "No Dir" "Listing failed" \
              "Login errors (out)" "Could not send to CFT" "Transfer site missing" "Receive File As not set" \
              "PeSIT transfer aborted" "PeSIT delivery refused" "Staged file missing" \
              "File Tracking entry missing" "Remote file unavailable" "Post client action failed" \
              "Pull via FTPS failed" "Delete remote file failed" "IO error" "Read timed out"; do
    n=$(grep -l -- "$reason" data/acceptance/transfer/reports/failed*.rpt data/acceptance/transfer/reports/errors/*.rpt 2>/dev/null | wc -l | tr -d ' ')
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[acceptance] reason \"$reason\" appears in no failed/error report"
done

if [ "$fails" -eq 0 ]; then
    echo "verify: OK — the sample estate exercises every planted scenario." >&2
else
    echo "verify: $fails assertion(s) FAILED." >&2
    exit 1
fi
