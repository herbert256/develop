#!/usr/bin/env bash
#
# bin/sample/verify.sh — assert that a FULL BUILD over the generated sample
# estate produced what the generator planted. Run AFTER bin/fresh.sh:
#
#   bin/sample/verify.sh            # one repo, one estate (2026-09-11)
#
# Checks the parse caches and the report descriptors against
# input/.sample/_expected.tsv plus a fixed scenario list — every scenario of
# BOTH former sample environments, now planted in the one estate. Exit 0 with
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
exp() {   # exp <key> -> expected figure (0 when absent)
    awk -F'\t' -v k="$1" '$1 == k { print $2; f = 1 } END { if (!f) print 0 }' "input/.sample/_expected.tsv"
}

EXP="input/.sample/_expected.tsv"
[ -f "$EXP" ] || { fail "no $EXP (generator not run?)"; echo "verify: 1 assertion FAILED." >&2; exit 1; }
F="data/transfer/cache/_files.tsv"
T="data/transfer/cache/_transfers.tsv"
P="data/server/cache/_parse.tsv"

nf=$(rows "$F"); nt=$(rows "$T"); np=$(rows "$P")
check $([ "$nf" -ge 3000 ] && echo 0 || echo 1) "_files.tsv rows $nf < 3000"
check $([ "$np" -ge 10000 ] && echo 0 || echo 1) "_parse.tsv rows $np < 10000"
r=$(awk -v a="$nt" -v b="$nf" 'BEGIN { print (b > 0 && a / b >= 1.8 && a / b <= 4.5) ? 0 : 1 }')
check "$r" "legs/files ratio $nt/$nf outside 1.8..4.5"

# outcomes: all four present; Expired + Waiting non-zero
for oc in Processed Failed Expired Waiting; do
    n=$(awk -F'\t' -v o="$oc" '$2 == o { n++ } END { print n + 0 }' "$F")
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "outcome $oc has 0 files"
done
# global failure share in a sane band (the monitor's near-all-OK beat and the
# quiet UC4-heavy hybrid flows keep the floor LOW, like the real estate)
r=$(awk -F'\t' '$2 == "Failed" || $2 == "Expired" { e++ } END { s = e / NR * 100; print (s >= 1 && s <= 30) ? 0 : 1 }' "$F")
check "$r" "failure share outside 1..30%"

# every configured-and-seen flow attributed: no empty site in _files.tsv
n=$(awk -F'\t' '$12 == "" { n++ } END { print n + 0 }' "$F")
check $([ "$n" -eq 0 ] && echo 0 || echo 1) "$n files with EMPTY site"

# colour distribution vs the estate's expectations (loose bands)
B="data/flow-manager/base/_subscriptions.tsv"
blue=$(awk -F'\t' '$3 == "blue" { n++ } END { print n + 0 }' "$B")
orange=$(awk -F'\t' '$3 == "orange" { n++ } END { print n + 0 }' "$B")
eb=$(exp blue); eo=$(exp orange)
check $([ "$blue" -ge $((eb / 2)) ] && echo 0 || echo 1) "blue subscriptions $blue < half of planted $eb"
check $([ "$orange" -ge "$eo" ] && echo 0 || echo 1) "orange subscriptions $orange < planted $eo"
gp=$(rows "data/blue/_greenpoll.tsv")
egp=$(exp greenpoll)
[ "$egp" -gt 0 ] && check $([ "$gp" -gt 0 ] && echo 0 || echo 1) "greenpoll empty (planted $egp)"

# the monitor dashboard flag
check $([ -f "data/dashboards/reports/monitor.rpt" ] && echo 0 || echo 1) "monitor.rpt missing"

# BOTH config shapes in the one export (2026-09-11): the classic folder
# parameters and the HYBRID participant parameters
n=$(command grep -c 'source_folder_monitoring_scan_dir' input/flow-manager/subscriptions.json 2>/dev/null || echo 0)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "subscriptions.json carries no classic (scan_dir) subscription"
n=$(command grep -c '_hybrid_participant' input/flow-manager/subscriptions.json 2>/dev/null || echo 0)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "subscriptions.json carries no HYBRID subscription"

# the Logical entity derivation (bin/flow-manager.sh): every configured
# FlowID maps to exactly one Logical, the entity report exists, and every
# derived name is 3 "_"-parts or a fixed input/logical.txt target
nmap=$(rows "data/flow-manager/xref/_profiles-logicals.tsv")
nprof=$(rows "data/flow-manager/base/_profiles.tsv")
check $([ "$nmap" -eq "$nprof" ] && echo 0 || echo 1) "FlowID map rows $nmap != profiles $nprof"
n=$(rpt_rows "data/transfer/reports/logical.rpt")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "logical.rpt has 0 rows"
n=$(awk -F'\t' 'FNR == NR { if ($0 !~ /^[ \t]*#/ && $0 !~ /^[ \t]*$/) { n2 = split($0, fa, /[ \t]+/); if (n2 >= 2 && fa[2] != "") fix[fa[2]] = 1 }; next }
    !($1 in fix) && split($1, P, "_") != 3 { n++ } END { print n + 0 }' \
    "input/logical.txt" "data/flow-manager/base/_logicals.tsv" 2>/dev/null || echo 0)
check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n logical name(s) not 3-part and not pinned"

# the BL entity (subscriptions.json tags entries starting with BL): the
# subscription -> tag map is non-empty and the entity report has rows
n=$(rows "data/flow-manager/xref/_subscriptions-bl.tsv")
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "_subscriptions-bl.tsv is empty"
# input/BL.txt rows join the tags (union, several per subscription):
# the GLOBEX billing flow carries its BL_FIN tag AND the two planted numbers
n=$(awk -F'\t' '$1=="UC1_FIN_BILLING_GLOBEX"' "data/flow-manager/xref/_subscriptions-bl.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -ge 3 ] && echo 0 || echo 1) "UC1_FIN_BILLING_GLOBEX has $n BL row(s), expected >= 3 (tag + input/BL.txt)"
# the "Added BL" sidecar + page (2026-09-01, user request): the BL.txt
# rows the tags do NOT carry. The planted GLOBEX numbers are exactly that.
n=$(awk -F'\t' '$1=="UC1_FIN_BILLING_GLOBEX"' "data/flow-manager/xref/_subscriptions-bl-added.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -ge 2 ] && echo 0 || echo 1) "_subscriptions-bl-added.tsv has $n row(s) for UC1_FIN_BILLING_GLOBEX, expected >= 2 (its input/BL.txt numbers)"
n=$(awk -F'\t' '$2 ~ /^BL_/' "data/flow-manager/xref/_subscriptions-bl-added.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "_subscriptions-bl-added.tsv carries $n tag-style BL_ value(s) — those come from subscriptions.json and must not count as added"
check $([ -f "docs/analyses/added-bl.html" ] && echo 0 || echo 1) "docs/analyses/added-bl.html missing"
# Partners - Incoming (2026-09-02): the page exists and its rows carry the login tints
check $([ -f "docs/analyses/fe-overview.html" ] && echo 0 || echo 1) "docs/analyses/fe-overview.html missing"
n=$(command grep -c '@data:res=' "data/analyses/reports/fe-overview.rpt" 2>/dev/null || echo 0)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "fe-overview.rpt has 0 tinted rows"
# a LOGIN skip rule (2026-09-03, user report): the comm-profile login goes
# from the configuration — no roster row, no detail page — and the Skipped
# report lists it (the sample rule: login exact FE672382, the CD-ZIBA-GEKKO
# login under the estate's PRNG namespace)
check $([ ! -f "docs/details/logins/fe672382.html" ] && echo 0 || echo 1) "docs/details/logins/fe672382.html exists — the login skip rule did not reach the config roster"
n=$(awk -F'\t' '$1=="FE672382"' "data/flow-manager/base/_logins.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "base/_logins.tsv still lists FE672382 (login skip rule)"
n=$(awk -F'\t' '$1=="Login" && $2=="FE672382"' "data/flow-manager/filtered/_skipped.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "filtered/_skipped.tsv has no Login row for FE672382"
# the EXTENDED transfer-site fold (2026-09-01, user report): a logged
# "<subscription>_<PROTO>_SERVER_<partner>" must be folded back onto its
# subscription — unfolded, the flow is unattributed, its movement is
# empty and the outcome rule can never say Processed
n=$(awk -F'\t' '$12 ~ /_SFTP_SERVER_/ { n++ } END { print n+0 }' "$F")
check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n file(s) keep an EXTENDED _SFTP_SERVER_ site (the fold did not fire)"
n=$(awk -F'\t' '$12=="UC3_APS_FMGENLOG_PIEDPIPER" && $2=="Processed" && $17=="in" { n++ } END { print n+0 }' "$F")
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "the extended-site flow UC3_APS_FMGENLOG_PIEDPIPER has 0 Processed file(s) with movement 'in'"
# the UNCONFIGURED no-account name (2026-09-04): the funnel's own
# "Unable to find account with username: svc-backup" rejection is a door
# knocker — a Scanners row, never an Incoming row (it would be the one
# Incoming row without a detail page)
R="data/server/reports/logon.rpt"
inc=$(awk -F'\t' '$1=="TABLE" { t=$2 } $1=="ROW" && t=="Incoming" && index($2, "svc-backup") { n++ } END { print n+0 }' "$R" 2>/dev/null)
scn=$(awk -F'\t' '$1=="TABLE" { t=$2 } $1=="ROW" && t ~ /scanner names/ && index($2, "svc-backup") { n++ } END { print n+0 }' "$R" 2>/dev/null)
check $([ "${inc:-1}" -eq 0 ] && echo 0 || echo 1) "logon Incoming lists svc-backup ($inc row(s)), expected none (unconfigured no-account name is a door knocker)"
check $([ "${scn:-0}" -ge 1 ] && echo 0 || echo 1) "logon Scanners lacks svc-backup, expected a row (the funnel no-account rejection)"
# the PERSISTENT connection (2026-09-06, the FE000508 finding): the first
# login's hourly re-key screenings count under Re-screens, not Allowed,
# its row stays green, its weekly CMS-parsing pair lands in Session
# errors — and the report's figures equal the detail pages' sidecar
# (the two matchers must agree)
rs=$(awk -F'\t' '$1=="TABLE" { t++ } t==1 && $1=="HEAD" { for (i=2;i<=NF;i++) { if ($i=="Re-screens") c=i; if ($i=="Session errors") x=i } } t==1 && $1=="ROW" && c && $c+0>0 && $x+0>0 && index($0, "@data:res=green") { n++ } END { print n+0 }' "$R" 2>/dev/null)
check $([ "${rs:-0}" -ge 1 ] && echo 0 || echo 1) "logon Incoming has $rs green row(s) with both Re-screens and Session errors, expected the persistent connection"
tw=$(awk -F'\t' -v LG="data/server/cache/_logons.tsv" 'BEGIN { while ((getline l < LG) > 0) { split(l, A, "\t"); LA[A[1]] = A[6] + 0; LR[A[1]] = A[22] + 0; LX[A[1]] = A[23] + 0 } } $1=="TABLE" { t++ } t==1 && $1=="HEAD" { for (i=2;i<=NF;i++) { if ($i=="Allowed") a=i; if ($i=="Re-screens") c=i; if ($i=="Session errors") x=i } } t==1 && $1=="ROW" && c && ($a+0>0 || $c+0>0 || $x+0>0) { u=toupper($2); if (LA[u] != $a+0 || LR[u] != $c+0 || LX[u] != $x+0) bad++ } END { print bad+0 }' "$R" 2>/dev/null)
check $([ "${tw:-1}" -eq 0 ] && echo 0 || echo 1) "$tw Incoming row(s) whose Allowed/Re-screens/Session errors differ from the _logons.tsv sidecar (the two matchers must agree)"
# the MULTI-FE account (2026-08-31, user report): CD-PARCEL-BLUTH carries
# TWO logins; its quiet second flow (its own login, never used) must read
# Nothing — never "No files": the other login's logons are no pickup
# evidence for it (uc2-status login scoping). Logins under the estate's PRNG
# namespace: FE186976 = the account login, FE624205 = flow B's own login,
# FE243615 = the 8-flow STMT-EXPORT-GLOBEX account.
n=$(awk -F'\t' '$1=="CD-PARCEL-BLUTH"' "data/flow-manager/xref/_accounts-logins.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -eq 2 ] && echo 0 || echo 1) "CD-PARCEL-BLUTH has $n login(s), expected 2 (the multi-FE account)"
st=$(awk -F'\t' '$1=="ROW" && index($0, "UC2_CD_PARCELX_BLUTH") { s=$2; sub(/^@\{[^}]*\}/, "", s); print s; exit }' "data/server/reports/uc2-status.rpt" 2>/dev/null)
check $([ "$st" = "Nothing" ] && echo 0 || echo 1) "UC2_CD_PARCELX_BLUTH uc2-status is '${st:-absent}', expected Nothing (multi-FE login scoping)"
# Partners - Incoming (2026-09-02): the pickup sidecar joins to LOGINS, once per
# login and account — the multi-FE account's pickups land on FE186976
# alone (FE624205 stays empty), and the 8-flow GLOBEX account's count
# lands once on FE243615 (never the x8 per-subscription repeat)
R="data/analyses/reports/fe-overview.rpt"; SC="data/server/reports/uc2-pickups.tsv"
# the Logon problems column (2026-09-04): the sample plants Disallowed
# lines for configured logins, so at least one row carries a problem
# cell whose lines link the Incoming page
pc=$(awk -F'\t' '$1=="HEAD" { for (i=2;i<=NF;i++) if ($i=="Logon problems") c=i } $1=="ROW" && c && index($c, "logons-incoming.html?axway_row=") { n++ } END { print n+0 }' "$R" 2>/dev/null)
check $([ "${pc:-0}" -ge 1 ] && echo 0 || echo 1) "Partners - Incoming has $pc row(s) with a Logon problems cell, expected at least 1 (the Disallowed logins)"
pk=$(awk -F'\t' '$1=="HEAD" { for (i = 2; i <= NF; i++) if ($i == "Pickups") c = i } $1=="ROW" && $2=="FE186976" { print $c+0; exit }' "$R" 2>/dev/null)
sp=$(awk -F'\t' '$1=="UC2_CD_PARCEL_BLUTH" { print $5+0; exit }' "$SC" 2>/dev/null)
check $([ "${pk:-0}" -gt 0 ] && [ "$pk" = "${sp:-x}" ] && echo 0 || echo 1) "fe-overview FE186976 pickups '${pk:-absent}' != sidecar UC2_CD_PARCEL_BLUTH '${sp:-absent}'"
pk=$(awk -F'\t' '$1=="HEAD" { for (i = 2; i <= NF; i++) if ($i == "Pickups") c = i } $1=="ROW" && $2=="FE624205" { print $c+0; exit }' "$R" 2>/dev/null)
check $([ "${pk:-1}" -eq 0 ] && echo 0 || echo 1) "fe-overview FE624205 pickups '${pk:-absent}', expected empty (multi-FE login scoping)"
pk=$(awk -F'\t' '$1=="HEAD" { for (i = 2; i <= NF; i++) if ($i == "Pickups") c = i } $1=="ROW" && $2=="FE243615" { print $c+0; exit }' "$R" 2>/dev/null)
sp=$(awk -F'\t' '$1=="STMT_EXPORT_GLOBEX_01" { print $5+0; exit }' "$SC" 2>/dev/null)
check $([ "${pk:-0}" -gt 0 ] && [ "$pk" = "${sp:-x}" ] && echo 0 || echo 1) "fe-overview FE243615 pickups '${pk:-absent}' != sidecar STMT_EXPORT_GLOBEX_01 '${sp:-absent}' once (the 8-flow account double-counted?)"
# ... and entity-coverage: the quiet flow's own application PARCELX
# must be NOT covered (red) — login A's logons are no In-side proof
# for login B's flow — while PARCEL (flow A) is covered
st=$(awk -F'\t' '$1=="ROW" && $2=="PARCELX" { print ($0 ~ /@data:res=red/) ? "red" : "notred"; exit }' "data/transfer/reports/entity-coverage.rpt" 2>/dev/null)
check $([ "$st" = "red" ] && echo 0 || echo 1) "entity-coverage PARCELX is '${st:-absent}', expected red / not covered (multi-FE logon-proof scoping)"
# the IO ERRORS report (2026-09-06, user request): the tagged UC4 flow's
# folder logs "IO Error reading file /data/FlowManager/<acct>@<login>/…"
# — one folder row naming the account AND its login (the @ split), the
# line list joined to the Files by name with BOTH states present (Failed:
# the route never read the file; Processed: a retry did), the lines
# attributed to the flow, and the Error/OK split ties to the line list
if [ "$(exp ioerr)" -gt 0 ]; then
    R="data/server/reports/io-errors.rpt"
    n=$(rpt_rows "$R")
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "io-errors.rpt has 0 rows"
    n=$(awk -F'\t' '$1=="TABLE" { t++ } t==1 && $1=="ROW" && $3=="ZG-ZKA-HOOLI" && $4 ~ /^FE[0-9]+$/ && index($5, "UC4_ZG_ZKA_HOOLI") { n++ } END { print n+0 }' "$R" 2>/dev/null)
    check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "io-errors folder table has $n ZG-ZKA-HOOLI row(s) with an FE login and the UC4 subscription, expected 1"
    for st in Failed Processed; do
        n=$(awk -F'\t' -v s="@{class=failed}Failed" '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, s) { n++ } END { print n+0 }' "$R" 2>/dev/null)
        [ "$st" = Processed ] && n=$(awk -F'\t' '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, "@{class=processed}Processed") { n++ } END { print n+0 }' "$R" 2>/dev/null)
        check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "io-errors line list has no $st line (the file-name join to _files.tsv)"
    done
    n=$(awk -F'\t' '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, "not logged") { n++ } END { print n+0 }' "$R" 2>/dev/null)
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "io-errors line list has $n 'not logged' line(s) — every planted line names an uploaded file"
    e1=$(awk -F'\t' '$1=="TABLE" { t++ } t==1 && $1=="TOTAL" { v=$5; sub(/^@\{[^}]*\}/, "", v); print v+0; exit }' "$R" 2>/dev/null)
    e2=$(awk -F'\t' '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, "@{class=failed}") { n++ } END { print n+0 }' "$R" 2>/dev/null)
    check $([ "${e1:-0}" -gt 0 ] && [ "$e1" = "$e2" ] && echo 0 || echo 1) "io-errors Error total $e1 != $e2 Failed line(s) (one IO line per failed File in the sample)"
fi
# the EMPTY OUTBOUND SSH PROBES (2026-09-08, user request): the tagged
# flow's lone Outbound ssh 0-byte records with Application "none" are
# dropped from both caches (never a one-legged Failed File), set aside in
# _skipped.csv, and the Skipped report lists them under their own reason
if [ "$(exp sshprobe)" -gt 0 ]; then
    n=$(awk -F'\t' '$2=="Outbound" && $10=="ssh" && ($9+0)==0 && tolower($25)=="none" { c[$1]++ } END { for (k in c) n++; print n+0 }' "$T")
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n probe CoreId(s) (Outbound ssh, size 0, Application none) survived in _transfers.tsv"
    n=$(awk -F'\t' '$2=="Outbound" && $10=="ssh" && ($9+0)==0 && tolower($25)=="none" && NF>=25 { n++ } END { print n+0 }' "$T")
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n probe record(s) survived in _transfers.tsv"
    n=$(command grep -c ',"none",' "data/transfer/_skipped.csv" 2>/dev/null || echo 0)
    check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "_skipped.csv holds no Application-none record (the planted probes were not set aside)"
    n=$(awk -F'\t' '$1=="ROW" && $3=="empty ssh probe" { n++ } END { print n+0 }' "data/transfer/reports/skipped.rpt" 2>/dev/null)
    check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "skipped.rpt lists no 'empty ssh probe' row"
    n=$(awk -F'\t' 'NF < 25 { n++ } END { print n+0 }' "$T")
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n _transfers.tsv row(s) short of 25 columns"
fi
# the COLLECT DROP + ok BOOKEND (2026-09-09, user request): the JSON
# transfer bookends are in the server cache (no longer noise-filtered) but
# out of the mention rings; the tagged flow's torn-down collects — a Failed
# ssh leg with an ok "Transfer end logged." on the CoreId and no error line
# — are settled Processed by bin/bookend-ok.sh (col 23 = the ok stamp)
if [ "$(exp collectdrop)" -gt 0 ]; then
    n=$(command grep -c 'Transfer end logged' "$P")
    check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "_parse.tsv holds no 'Transfer end logged' bookend (still noise-filtered?)"
    n=$(awk -F'\t' '$23 != "" { n++; if ($2 != "Processed") bad++ } END { print n+0 "\t" bad+0 }' "$F"); nb=${n#*	}; n=${n%	*}
    check $([ "${n:-0}" -gt 0 ] && [ "${nb:-0}" -eq 0 ] && echo 0 || echo 1) "$n settled File(s) in _files.tsv ($nb not Processed) — expected some, all Processed"
    n=$(awk -F'\t' '$12=="UC2_ZG_MATCH_HOOLI" && $23 != "" { n++ } END { print n+0 }' "$F")
    check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "no settled File on UC2_ZG_MATCH_HOOLI (the collectdrop flow)"
    n=$(rows "data/transfer/cache/_bookendok.tsv")
    check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "_bookendok.tsv is empty"
    n=$(command grep -c 'Transfer end logged' "data/server/cache/_accounts.tsv" 2>/dev/null || true)   # grep -c prints the 0 itself (exit 1)
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n bookend(s) leaked into the account mention cache"
fi
# the UC3 that never transfers and CANNOT CONNECT (2026-09-10, user rule):
# no File, every poll a Connection failure — red (not blue/orange), with
# its newest failure in the _redflip sidecar, an error page of its own,
# and a row on the home page's "Failing subscriptions in Server log"
if [ "$(exp pollconnfail)" -gt 0 ]; then
    c=$(awk -F'\t' '$1=="UC3_ZG_RATES_OSCORP" { print $3 }' "$B")
    check $([ "$c" = red ] && echo 0 || echo 1) "UC3_ZG_RATES_OSCORP is '${c:-absent}', expected red (every poll a connection failure, no transfer)"
    n=$(awk -F'\t' '$12=="UC3_ZG_RATES_OSCORP" { n++ } END { print n+0 }' "$F")
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "UC3_ZG_RATES_OSCORP has $n File(s) — the sample must plant none"
    n=$(awk -F'\t' '$1=="UC3_ZG_RATES_OSCORP" { n++ } END { print n+0 }' "data/blue/_redflip.tsv" 2>/dev/null)
    check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "_redflip.tsv has $n row(s) for UC3_ZG_RATES_OSCORP, expected 1"
    check $([ -f "docs/errors/uc3-zg-rates-oscorp.html" ] && echo 0 || echo 1) "docs/errors/uc3-zg-rates-oscorp.html missing (the server-failing error page)"
    n=$(awk 'BEGIN{RS="<h2"} /Failing subscriptions in Server log/ && /UC3_ZG_RATES_OSCORP/ { n++ } END { print n+0 }' docs/index.html 2>/dev/null)
    check $([ "${n:-0}" -ge 1 ] && echo 0 || echo 1) "the home worklist 'Failing subscriptions in Server log' does not list UC3_ZG_RATES_OSCORP"
fi
# the MULTI-HOST account (2026-08-31): CD_ROUTE_WONKA carries TWO
# endpoints, and its _ALT flow logs half its rows as the raw ADDRESS.
# The endpoint vote rides the SUBSCRIPTION, so those rows must resolve
# to the alt endpoint — never stay a raw IP (which would invent an
# address-shaped host entity).
n=$(awk -F'\t' '$1=="CD_ROUTE_WONKA"' "data/flow-manager/xref/_accounts-hosts.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -eq 2 ] && echo 0 || echo 1) "CD_ROUTE_WONKA has $n host(s), expected 2 (the multi-host account)"
alth=$(awk -F'\t' '$1=="CD_ROUTE_WONKA" && $2 ~ /^sftp2\./ { print $2; exit }' "data/flow-manager/xref/_accounts-hosts.tsv" 2>/dev/null)
n=$(awk -F'\t' '$12=="UC3_CD_ROUTE_WONKA_ALT" && $15 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { n++ } END { print n+0 }' "$F")
check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "UC3_CD_ROUTE_WONKA_ALT has $n file(s) with a RAW IP host (the multi-host endpoint vote failed)"
n=$(awk -F'\t' -v h="${alth:-none}" '$12=="UC3_CD_ROUTE_WONKA_ALT" && $15==h { n++ } END { print n+0 }' "$F")
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "UC3_CD_ROUTE_WONKA_ALT has 0 file(s) on its own endpoint '${alth:-absent}'"
# the endpoint's NEWER address is seeded into no map (see
# bin/sample/generate.sh): the parse must LEARN it from the logged
# rows, which only an unpoisoned endpoint vote does
n=$(awk -F'\t' -v h="${alth:-none}" '$2==h { n++ } END { print n+0 }' "input/ip/ip-hosts.tsv" 2>/dev/null)
check $([ "${n:-0}" -ge 2 ] && echo 0 || echo 1) "ip-hosts.tsv maps $n address(es) to '${alth:-absent}', expected 2 (the parse must LEARN the endpoint's second address — a multi-host account must not poison the endpoint vote)"
# the ten policy files + the label live at the FLAT input root (2026-09-11);
# the former per-environment dirs are gone
for pf in blacklist.txt skip.txt rename.txt logical.txt logical_domains.txt logical_apps.txt logical_partners.txt BL.txt logons_old.txt coreid-url.txt environment.txt; do
    check $([ -f "input/$pf" ] && echo 0 || echo 1) "input/$pf missing"
done
for ed in acceptance production; do
    check $([ ! -e "input/$ed" ] && echo 0 || echo 1) "input/$ed still exists (one repo = one environment since 2026-09-11 — the trees are flat)"
done
# partner-aliases.tsv is RETIRED (2026-09-01): its pairs live in
# logical_partners.txt as part replacements, so the misspelled GLOBEXX
# token must never surface as a partner entity of its own
check $([ ! -e "input/partner-aliases.tsv" ] && echo 0 || echo 1) "input/partner-aliases.tsv still exists (retired — fold it into logical_partners.txt)"
n=$(awk -F'\t' '$1=="GLOBEXX" { n++ } END { print n+0 }' "data/flow-manager/base/_partners.tsv" 2>/dev/null)
check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "GLOBEXX is a partner entity of its own — the logical_partners.txt alias replacement did not fire"
n=$(awk -F'\t' '$1=="GLOBEX" { n++ } END { print n+0 }' "data/flow-manager/base/_partners.tsv" 2>/dev/null)
check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "GLOBEX is not a partner entity (expected exactly 1 row)"
n=$(rpt_rows "data/transfer/reports/bl.rpt")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "bl.rpt has 0 rows"

# planted reports carry rows
for rpt in expired waiting went-quiet duplicate-files; do
    n=$(rpt_rows "data/transfer/reports/$rpt.rpt")
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "$rpt.rpt has 0 rows"
done
n=$(rpt_rows "data/transfer/reports/missing-cronjobs.rpt"); en=$(exp nocron)
[ "$en" -gt 0 ] && check $([ "$n" -ge "$en" ] && echo 0 || echo 1) "missing-cronjobs rows $n < planted $en"

# AV verdicts beyond Allowed/Not performed (the estate plants Blocked+Error),
# the session join, the skip list, the UCx_ synthetic sites, resubmissions
n=$(awk -F'\t' '$17 == "Blocked" || $17 == "Error" { n++ } END { print n + 0 }' "$T")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "no Blocked/Error AV rows"
n=$(rows "data/transfer/cache/_sessionsites.tsv")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "_sessionsites.tsv empty (session join unexercised)"
n=$(rows "data/transfer/_skipped.tsv")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "skip list caught 0 transfer rows"
n=$(awk -F'\t' '$6 ~ /^UCx_/ { n++ } END { print n + 0 }' "$T")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "no UCx_ synthetic-site legs"
n=$(awk -F'\t' '$22 == "true" { n++ } END { print n + 0 }' "$T")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "no resubmitted legs"

# the Retry · Resubmit columns of the Entities pages (Cured 2026-09-10, split
# 2026-09-12, user request): every entity .rpt Summary carries
# Files·Error·OK·Retry·Resubmit (ROW $3..$7; Retry + Resubmit = the OK Files
# that carried a failed leg — the home page Cured rule — Resubmit when a leg
# carries Resubmitted=true, like the Top view's Automatic/Manual), the
# rendered views show them between OK and Error, and the account totals
# equal an independent recount of the two caches
n=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "ROW" && ($6 + $7 > $5 + 0) { n++ } END { print n + 0 }' "data/transfer/reports/subscription.rpt" 2>/dev/null)
check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "subscription.rpt: ${n:-?} row(s) with Retry + Resubmit > OK"
hdr=$(grep -o '<th[^>]*>[^<]*</th>' "docs/transfer/entities/account-all.html" 2>/dev/null | sed 's/<[^>]*>//g' | head -9 | tr '\n' '|')
check $([ "$hdr" = "Account|Direction|Files|Volume|OK|Retry|Resubmit|Error|Last seen|" ] && echo 0 || echo 1) "entities/account-all.html header is '$hdr', expected Account|Direction|Files|Volume|OK|Retry|Resubmit|Error|Last seen|"
read -r want wantm <<< "$(awk -F'\t' 'FNR == 1 { fno++ } fno == 1 { if ($3 != "Processed") fl[$1] = 1; if ($22 == "true") rs[$1] = 1; next } $3 != "" && $4 != "" && $2 != "Failed" && $2 != "Expired" && ($1 in fl) { n++; if ($1 in rs) m++ } END { print n + 0, m + 0 }' "$T" "$F" 2>/dev/null)"
read -r got gotm <<< "$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "TOTAL" { a = $6; b = $7; sub(/^@\{[^}]*\}/, "", a); sub(/^@\{[^}]*\}/, "", b); print a + b, b + 0; exit }' "data/transfer/reports/account.rpt" 2>/dev/null)"
check $([ "${got:-x}" = "${want:-y}" ] && echo 0 || echo 1) "account.rpt Retry + Resubmit total is '${got:-absent}', an independent recount of the caches gives '${want:-?}'"
check $([ "${gotm:-x}" = "${wantm:-y}" ] && echo 0 || echo 1) "account.rpt Resubmit total is '${gotm:-absent}', an independent recount of the caches gives '${wantm:-?}'"
check $([ "${want:-0}" -gt "${wantm:-0}" ] && [ "${wantm:-0}" -gt 0 ] && echo 0 || echo 1) "the sample has no Retry (${want:-0} cured, ${wantm:-0} resubmitted) or no Resubmit File — an Entities column is never exercised"

# the Top view's six column groups (2026-09-12, user request): Files WITHOUT
# Recovered, then the Recovered group (Automatic · Manual) and the Resubmit
# group (Ok · Failed) between Files and Transfers — Manual = a recovered
# File with a Resubmitted=true leg (col 22), Resubmit = every File with such
# a leg, Ok/Failed by outcome; every figure on the File's START day. The
# totals must equal an independent recount of the two caches, all four new
# columns must be exercised, and the home page's Cured (= Automatic +
# Manual, ROW fields 9-10) must still equal the recovered total.
TV="data/transfer/reports/topview.rpt"
h=$(awk -F'\t' '$1 == "HEAD" { print; exit }' "$TV" 2>/dev/null)
check $([ "$h" = $'HEAD\tDate\tFirst\tLast\tCount\tOk\tError\tError %\tAutomatic\tManual\tOk\tFailed\tCount\tOk\tError\tError %\tProcessed\tFailed\tWaiting\tExpired' ] && echo 0 || echo 1) "topview.rpt HEAD is '$h' — expected the six groups Date|Files|Recovered|Resubmit|Transfers|State"
# the TOTAL cells carry an @{class=…} prefix; a blank amber cell is 0
read -r rva rvm rso rsf <<< "$(awk -F'\t' '$1 == "TOTAL" { a = $9; b = $10; c = $11; e = $12; sub(/^@\{[^}]*\}/, "", a); sub(/^@\{[^}]*\}/, "", b); sub(/^@\{[^}]*\}/, "", c); sub(/^@\{[^}]*\}/, "", e); print a + 0, b + 0, c + 0, e + 0; exit }' "$TV" 2>/dev/null)"
# independent recounts (the topview rule: every File with a start day)
read -r wrv wrm <<< "$(awk -F'\t' 'FNR == 1 { fno++ } fno == 1 { if ($3 != "Processed") fl[$1] = 1; if ($22 == "true") rs[$1] = 1; next } $4 != "" && $2 != "Failed" && $2 != "Expired" && ($1 in fl) { n++; if ($1 in rs) m++ } END { print n + 0, m + 0 }' "$T" "$F" 2>/dev/null)"
read -r wro wrf <<< "$(awk -F'\t' 'FNR == 1 { fno++ } fno == 1 { if ($22 == "true") rs[$1] = 1; next } $4 != "" && ($1 in rs) { if ($2 == "Failed" || $2 == "Expired") f++; else o++ } END { print o + 0, f + 0 }' "$T" "$F" 2>/dev/null)"
check $([ "$((${rva:-0} + ${rvm:-0}))" = "${wrv:-x}" ] && echo 0 || echo 1) "topview Recovered Automatic + Manual = $((${rva:-0} + ${rvm:-0})), the caches give ${wrv:-?}"
check $([ "${rvm:-x}" = "${wrm:-y}" ] && echo 0 || echo 1) "topview Recovered Manual = ${rvm:-absent}, the caches give ${wrm:-?}"
check $([ "${rso:-x}" = "${wro:-y}" ] && [ "${rsf:-x}" = "${wrf:-y}" ] && echo 0 || echo 1) "topview Resubmit Ok/Failed = ${rso:-?}/${rsf:-?}, the caches give ${wro:-?}/${wrf:-?}"
check $([ "${rva:-0}" -gt 0 ] && [ "${rvm:-0}" -gt 0 ] && echo 0 || echo 1) "the sample has no Automatic (${rva:-0}) or no Manual (${rvm:-0}) recovery — a Recovered column is never exercised"
check $([ "${rso:-0}" -gt 0 ] && [ "${rsf:-0}" -gt 0 ] && echo 0 || echo 1) "the sample has no Resubmit Ok (${rso:-0}) or Failed (${rsf:-0}) File — a Resubmit column is never exercised"
hc=$(grep -o '<a href="transfer/recovered-files.html">[0-9.]*</a>' docs/index.html 2>/dev/null | sed 's/<[^>]*>//g; s/\.//g' | head -1)
check $([ "${hc:-x}" = "${wrv:-y}" ] && echo 0 || echo 1) "home Cured total is '${hc:-absent}', expected the recovered total ${wrv:-?}"
hdr=$(grep -o '<th[^>]*>[^<]*</th>' "docs/transfer/topview.html" 2>/dev/null | sed 's/<[^>]*>//g' | tr '\n' '|')
check $([ "$hdr" = "|Files|Recovered|Resubmit|Transfers|State|Date|First|Last|Count|Ok|Error|Error %|Automatic|Manual|Ok|Failed|Count|Ok|Error|Error %|Processed|Failed|Waiting|Expired|" ] && echo 0 || echo 1) "transfer/topview.html headers are '$hdr'"
n=$(grep -c '<table' docs/transfer/topview.html 2>/dev/null || true)
check $([ "${n:-0}" = 1 ] && echo 0 || echo 1) "transfer/topview.html has ${n:-0} table(s), expected exactly 1 (the six groups share one per-day table)"

# the after-last-transfer banner with its log line (2026-09-12, user
# request): the planted kaput flow (estate.awk UC1_DPL_LEDGER_DUNDER —
# every File delivered, then a connection-failure E line) is server-failing,
# its page opens with the bare ERROR IN SERVER LOG AFTER LAST TRANSFER banner,
# a LOGCARD carrying the line's date/time + session id right under it, and
# NO "used to work and now fails" verdict prose above
ks=$(awk -F'\t' '$1 == "UC1_DPL_LEDGER_DUNDER" { print $2; exit }' "data/transfer/reports/details/subscriptions/_slugmap.tsv" 2>/dev/null)
kp="docs/details/subscriptions/${ks:-missing}.html"
check $([ -n "$ks" ] && [ -f "$kp" ] && echo 0 || echo 1) "the kaput flow UC1_DPL_LEDGER_DUNDER has no detail page ('${ks:-no slug}')"
check $([ "$(grep -c 'UC1_DPL_LEDGER_DUNDER' data/transfer/reports/_srvsubs-map.tsv 2>/dev/null)" = 1 ] && echo 0 || echo 1) "the kaput flow is not in the server-failing set (_srvsubs-map.tsv)"
check $([ "$(grep -c '<p class="alert">[^<]*ERROR IN SERVER LOG AFTER LAST TRANSFER</[a-z]*></p>\|<p class="alert">ERROR IN SERVER LOG AFTER LAST TRANSFER</p>' "$kp" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "the kaput page lacks the bare ERROR IN SERVER LOG AFTER LAST TRANSFER banner"
check $([ "$(grep -c 'class="logcard"><span class="lc-when">[0-9-]* [0-9:.]*  · *session [0-9a-f]*</span>' "$kp" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "the kaput page lacks the log line card (date/time · session id) under the banner"
check $([ "$(grep -c 'used to work and now fails' "$kp" 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the kaput page still carries the verdict prose above the banner"

# the Could not send file report (2026-09-12, user request): the planted
# cnsend flow (estate.awk UC1_CD_IDM_VANDELAY) closes every failed burst
# with an AR0074 line — the report lists them newest first, Date & time ·
# Subscription · File, at most 1000 rows and 10 per subscription
if [ "$(exp cnsend)" -gt 0 ]; then
    R="data/server/reports/could-not-send.rpt"
    n=$(rpt_rows "$R")
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "could-not-send.rpt has 0 rows"
    h=$(awk -F'\t' '$1 == "HEAD" { print; exit }' "$R" 2>/dev/null)
    check $([ "$h" = $'HEAD\tDate & time\tSubscription\tFile' ] && echo 0 || echo 1) "could-not-send.rpt HEAD is '$h', expected Date & time|Subscription|File"
    n=$(awk -F'\t' '$1 == "ROW" { s = $3; sub(/^@\{[^}]*\}/, "", s); if (s == "UC1_CD_IDM_VANDELAY") n++ } END { print n + 0 }' "$R" 2>/dev/null)
    check $([ "${n:-0}" -gt 0 ] && [ "${n:-0}" -le 10 ] && echo 0 || echo 1) "could-not-send.rpt has ${n:-0} row(s) for the planted flow, expected 1-10"
    n=$(awk -F'\t' '$1 == "ROW" { s = $3; sub(/^@\{[^}]*\}/, "", s); if (++c[s] > 10) over++ } END { print over + 0 }' "$R" 2>/dev/null)
    check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "could-not-send.rpt: ${n:-?} row(s) beyond the 10-per-subscription cap"
    n=$(rpt_rows "$R")
    check $([ "$n" -le 1000 ] && echo 0 || echo 1) "could-not-send.rpt has $n rows, beyond the 1000 cap"
    n=$(awk -F'\t' '$1 == "ROW" { if (p != "" && $2 > p) bad++; p = $2 } END { print bad + 0 }' "$R" 2>/dev/null)
    check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "could-not-send.rpt is not newest-first (${n:-?} row(s) out of order)"
    check $([ -f docs/server/could-not-send.html ] && echo 0 || echo 1) "docs/server/could-not-send.html is missing"
fi

# the TRANSFER-ENDED sessions rule (2026-09-12, user rule): an Error/Warning
# on a session that also logged {"message":"Transfer end logged." is not a
# server-log error — parse.sh lists those sessions in _sessions-ended.tsv
# and keeps their E/W lines out of every *_err_warn.tsv ring (the
# after-last-transfer judgement); the collectdrop flow plants an Error on
# such a session so the mute is exercised
SE="data/server/cache/_sessions-ended.tsv"
n=$(rows "$SE")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "_sessions-ended.tsv is missing or empty ($n)"
n=$(awk -F'\t' 'FNR == 1 { fno++ } fno == 1 { if ($1 != "") e[$1] = 1; next } $3 == "E" && ($6 in e) { n++ } END { print n + 0 }' "$SE" "$P" 2>/dev/null)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "the sample has no Error line on a transfer-ended session — the mute is never exercised"
n=$(awk -F'\t' 'FNR == 1 { fno++ } fno == 1 { if ($1 != "") e[$1] = 1; next } ($6 in e) { n++ } END { print n + 0 }' "$SE" data/server/cache/*/*_err_warn.tsv 2>/dev/null)
check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "${n:-?} err/warn ring line(s) sit on a transfer-ended session (must be 0)"
n=$(grep -c '50455253495354454e542d53455353494f4e2d' "$SE" 2>/dev/null || true)
check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "the PERSISTENT-SESSION pseudo-session is listed in _sessions-ended.tsv"

# the SHARED-HOST session rule (2026-09-12, user rule: read all server log
# lines with the same session id to find the right subscription):
# UC1_IT_LEADS_STARK (every File OK, then quiet) shares the STARK host with
# the poll-failing UC3_SI_TELEMETRY_STARK, whose "Authentication failure
# connecting to remote host …" lines name no flow — their sessions vote the
# UC3 (its failed legs), so the host's newest error is that flow's alone and
# the quiet flow stays green (before: the wholesale join reddened it)
h=$(awk -F'\t' '$1 == "UC3_SI_TELEMETRY_STARK" { print tolower($2); exit }' data/flow-manager/xref/_subscriptions-hosts.tsv 2>/dev/null)
n=$(awk -F'\t' -v H="$h" '$1 != "" && tolower($2) == H { n++ } END { print n + 0 }' data/flow-manager/xref/_subscriptions-hosts.tsv 2>/dev/null)
check $([ -n "$h" ] && [ "${n:-0}" -ge 2 ] && echo 0 || echo 1) "the STARK host '${h:-?}' is not shared (${n:-0} flow(s)) — the session rule is never exercised"
s=$(awk -F'\t' '$3 == "E" && $5 ~ /^Authentication failure connecting to remote host/ { print $6; exit }' "data/server/cache/hosts/${h:-none}_err_warn.tsv" 2>/dev/null)
v=$(awk -F'\t' -v S="$s" 'S != "" && $1 == S { print $2; exit }' data/blue/_sessvote.tsv 2>/dev/null)
check $([ -n "$s" ] && [ "$v" = "UC3_SI_TELEMETRY_STARK" ] && echo 0 || echo 1) "the STARK host ring's authentication failure (session '${s:-none}') votes '${v:-nothing}', expected UC3_SI_TELEMETRY_STARK"
c=$(awk -F'\t' '$1 == "UC1_IT_LEADS_STARK" { print $3; exit }' data/flow-manager/base/_subscriptions.tsv 2>/dev/null)
check $([ "$c" = green ] && echo 0 || echo 1) "UC1_IT_LEADS_STARK is '${c:-absent}', expected green — the shared host's authentication failure belongs to the UC3 poll flow"

# the NON-UC-NAMED hybrid flows must come out attributed to their real site
# (the reverse profile fallback) — never UCx_ — and every planted one is a
# configured subscription of the base roster
n=$(awk -F'\t' '$12 ~ /^(STMT_EXPORT|INV_PAYMENTS|REC_FEEDS|GL_POSTINGS|CRM_SYNC|HR_ROSTER)/ { n++ } END { print n + 0 }' "$F")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "no files attributed to the non-UC hybrid flows"
n=$(awk -F'\t' '$1 ~ /^(STMT_EXPORT|INV_PAYMENTS|REC_FEEDS|GL_POSTINGS|CRM_SYNC|HR_ROSTER)/ { n++ } END { print n + 0 }' "$B" 2>/dev/null); en=$(exp nonuc)
check $([ "${n:-0}" -eq "$en" ] && echo 0 || echo 1) "base/_subscriptions.tsv lists $n non-UC hybrid flow(s), planted $en"

# the failing-reasons catalogue: every planted category non-empty; the
# "routestop" scenario (an ARSP0001 "while sending the file … to a partner
# site" line) reads "Duplicate file" — the 2026-09-12 rename of the
# 2026-09-06 "Could not send to CFT" wording
for reason in "Connection failures" "Wrong server fingerprint" "No Dir" "Listing failed" \
              "Login errors (out)" "Duplicate file" "Transfer site missing" "Receive File As not set" \
              "PeSIT transfer aborted" "PeSIT delivery refused" "Staged file missing" \
              "File Tracking entry missing" "Remote file unavailable" "Post client action failed" \
              "Pull via FTPS failed" "Delete remote file failed" "IO error" "Read timed out" "Connection dropped mid-transfer" \
              "Stream read/write error"; do
    n=$(grep -l -- "$reason" data/transfer/reports/failed*.rpt data/transfer/reports/errors/*.rpt 2>/dev/null | wc -l | tr -d ' ')
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "reason \"$reason\" appears in no failed/error report"
done

if [ "$fails" -eq 0 ]; then
    echo "verify: OK — the sample estate exercises every planted scenario." >&2
else
    echo "verify: $fails assertion(s) FAILED." >&2
    exit 1
fi
