#!/usr/bin/env bash
#
# bin/sample/verify.sh — assert that a FULL BUILD over the generated sample
# estate produced what the generator planted. Run AFTER bin/build.sh:
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
# rpt_rows <rpt> -> ROW-directive count (0 when absent). NOT `grep -c … ||
# echo 0`: grep -c prints 0 AND exits 1 on no match, so that printed "0\n0"
# and garbled every numeric test downstream
rpt_rows() { local c=""; [ -f "$1" ] && c=$(grep -c $'^ROW\t' "$1"); echo "${c:-0}"; }
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
eo=$(exp orange)
# the blue (server-log-only) result is RETIRED (2026-09-27): the planted
# server-log-only flows are orange now (or green / red by the UC3 poll rules)
check $([ "$blue" -eq 0 ] && echo 0 || echo 1) "$blue subscription(s) still carry the retired blue result"
check $([ "$orange" -ge "$eo" ] && echo 0 || echo 1) "orange subscriptions $orange < planted $eo"
# the planted CLEAN POLLERS (tag greenpoll: UC3, polls fine, never a file) are
# ORANGE — no clean-poll green since 2026-09-28 (user rule: a UC3 subscription
# with no transfers is orange, not green); the rule's sidecar is gone
egp=$(exp greenpoll)
read -r gpf gpno <<< "$(awk -F'\t' 'NR == FNR { if ($30 ~ /(^|,)greenpoll(,|$)/) want[toupper($4)] = 1; next }
    (toupper($1) in want) { f++; if ($3 != "orange") no++ } END { print f + 0, no + 0 }' "input/.sample/_estate.tsv" "$B")"
check $([ "$gpf" -eq "$egp" ] && echo 0 || echo 1) "clean pollers in base/_subscriptions.tsv: $gpf, planted $egp"
check $([ "$gpno" -eq 0 ] && echo 0 || echo 1) "$gpno clean-polling UC3 flow(s) with no transfers are not orange"
check $([ -e "data/colour/_greenpoll.tsv" ] && echo 1 || echo 0) "the retired data/colour/_greenpoll.tsv still exists"

# the Monitor dashboard is GONE (2026-09-30, user request): no script, .rpt,
# page, help page, top-bar link or durfit chart kind may come back
n=$(ls bin/dashboards/reports/monitor.sh data/dashboards/reports/monitor.rpt docs/dashboards/monitor.html docs/help/monitor.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" = 0 ] && ! grep -rqs 'dashboards/monitor.html\|durfit' docs --include='*.html' --include='*.js' && echo 0 || echo 1) "the Monitor dashboard (monitor.sh / .rpt / page / help / link / durfit) is back"

# BOTH config shapes in the one export (2026-09-11): the classic folder
# parameters and the HYBRID participant parameters
n=$(command grep -c 'source_folder_monitoring_scan_dir' input/flow-manager/subscriptions.json 2>/dev/null || true)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "subscriptions.json carries no classic (scan_dir) subscription"
n=$(command grep -c '_hybrid_participant' input/flow-manager/subscriptions.json 2>/dev/null || true)
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
check $([ ! -f "docs/analyses/added-bl.html" ] && echo 0 || echo 1) "docs/analyses/added-bl.html still published (retired 2026-09-29: a + mark in the Subscriptions BL column)"
# the DESCRIPTION as a BL source (2026-09-18, user request): the planted
# "… BL 10042 …" description of UC1_WA_BATCH_WAYNE reaches the BL entity,
# normalised to BL<digits> — and counts as an EXPORT BL, so it must NOT
# appear in the input/BL.txt "Added BL" sidecar
n=$(awk -F'\t' '$1=="UC1_WA_BATCH_WAYNE" && $2=="BL10042"' "data/flow-manager/xref/_subscriptions-bl.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "the description BL10042 of UC1_WA_BATCH_WAYNE is not in _subscriptions-bl.tsv ($n row(s))"
n=$(awk -F'\t' '$2=="BL10042"' "data/flow-manager/xref/_subscriptions-bl-added.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "BL10042 comes from subscriptions.json but appears in _subscriptions-bl-added.tsv ($n row(s))"
# base/_bl.tsv is name<TAB>direction<TAB>result, so match COLUMN 1 — a
# whole-line test never matches (it cost this assertion a false FAIL)
n=$(awk -F'\t' '$1=="BL10042"' "data/flow-manager/base/_bl.tsv" 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "BL10042 is not an entity in base/_bl.tsv ($n row(s))"
# the FE overview data (2026-09-02; its PAGE went 2026-09-29 — Partners -
# Incoming carries every column): the rows carry the login tints, and the
# retired page is gone
check $([ ! -f "docs/analyses/fe-overview.html" ] && echo 0 || echo 1) "docs/analyses/fe-overview.html still published (retired 2026-09-29)"
n=$(command grep -c '@data:res=' "data/analyses/reports/fe-overview.rpt" 2>/dev/null || true)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "fe-overview.rpt has 0 tinted rows"
# Partners - Incoming (2026-09-13): the merged page exists and carries every FE overview row plus the funnel cell drills
check $([ -f "docs/analyses/partners-in.html" ] && echo 0 || echo 1) "docs/analyses/partners-in.html missing"
n=$(command grep -c '^ROW' "data/analyses/reports/partners-in.rpt" 2>/dev/null || true); m=$(command grep -c '^ROW' "data/analyses/reports/fe-overview.rpt" 2>/dev/null || true)
check $([ "${n:-0}" -ge "${m:-1}" ] && [ "${m:-0}" -gt 0 ] && echo 0 || echo 1) "partners-in.rpt has $n row(s), fewer than the FE overview ($m)"
n=$(command grep -c '@data:drill-cell-12=' "data/analyses/reports/partners-in.rpt" 2>/dev/null || true)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "partners-in.rpt carries no re-keyed funnel drill (Allowed at column 12)"
# Partners - Outgoing retired 2026-09-29 (= Entities › Remote Hosts column for column)
check $([ ! -f "docs/analyses/hosts-overview.html" ] && echo 0 || echo 1) "docs/analyses/hosts-overview.html still published (retired 2026-09-29)"
# the Subscriptions page's Active column (2026-09-14): Yes on the active ones, and exactly the planted
# inactive subscriptions carry codes — 1 undeployed, 2 saved-not-deployed, 3 schedule No, 4 folder monitoring Inactive
acts=$(grep -o '<td class="act"[^>]*>[^<]*</td>' "docs/analyses/subscriptions.html" 2>/dev/null | sed 's/<[^>]*>//g')
n=$(printf '%s\n' "$acts" | grep -c '^Yes$' || true)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "subscriptions.html: no Active cell reads Yes"
n=$(printf '%s\n' "$acts" | grep -c '^[1-4]' || true); en=$(exp act_inactive)
check $([ "${n:-0}" -eq "$en" ] && [ "$en" -gt 0 ] && echo 0 || echo 1) "subscriptions.html: $n inactive Active cell(s), planted $en"
for pair in 1:act_undeployed 2:act_notdeployed 3:act_schedoff 4:act_scanoff; do
    c=${pair%%:*}; en=$(exp "${pair#*:}")
    n=$(printf '%s\n' "$acts" | awk -v c="$c" '{ m = split($0, A, /, /); for (i = 1; i <= m; i++) if (A[i] == c) { n++; break } } END { print n + 0 }')
    check $([ "$n" -eq "$en" ] && [ "$en" -gt 0 ] && echo 0 || echo 1) "subscriptions.html: Active code $c on $n cell(s), planted $en"
done
# ... and the subscription detail pages' Features Status rows (2026-09-14): one row per planted reason
n=$(awk -F'\t' 'FNR == 1 { t = 0 } $1 == "TABLE" { t = ($2 == "Features") } t && $1 == "ROW" && $2 == "Status" { n++ } END { print n + 0 }' data/transfer/reports/details/subscriptions/*.rpt 2>/dev/null)
en=$(( $(exp act_undeployed) + $(exp act_notdeployed) + $(exp act_schedoff) + $(exp act_scanoff) ))
check $([ "${n:-0}" -eq "$en" ] && [ "$en" -gt 0 ] && echo 0 || echo 1) "subscription detail Features: $n Status row(s), planted $en"
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
# the sample plants Disallowed lines for configured logins, so at least one
# Partners - Incoming row carries a Disallowed count (the funnel column; the
# FE overview's summed "Logon problems" column and its _logon-problems.tsv
# sidecar went 2026-09-29)
pc=$(awk -F'\t' '$1=="HEAD" { for (i=2;i<=NF;i++) if ($i=="Disallowed") c=i } $1=="ROW" && c { v=$c; sub(/^@\{[^}]*\}/, "", v); if (v+0 > 0) n++ } END { print n+0 }' "data/analyses/reports/partners-in.rpt" 2>/dev/null)
check $([ "${pc:-0}" -ge 1 ] && echo 0 || echo 1) "Partners - Incoming has $pc row(s) with a Disallowed count, expected at least 1 (the planted Disallowed logins)"
check $([ ! -e "data/server/reports/_logon-problems.tsv" ] && echo 0 || echo 1) "the retired data/server/reports/_logon-problems.tsv still exists"
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
    # (the State words are the site's Error / OK since 2026-09-30 — Failed /
    # Processed before)
    for st in Error OK; do
        n=$(awk -F'\t' -v s="@{class=failed}Error" '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, s) { n++ } END { print n+0 }' "$R" 2>/dev/null)
        [ "$st" = OK ] && n=$(awk -F'\t' '$1=="TABLE" { t++ } t==2 && $1=="ROW" && index($0, "@{class=processed}OK") { n++ } END { print n+0 }' "$R" 2>/dev/null)
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
    n=$(command grep -c ',"none",' "data/transfer/_skipped.csv" 2>/dev/null || true)
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
    # (the flat _accounts.tsv mention cache went 2026-09-29 — no reader; the
    # per-account rings under accounts/ are what the pages read)
    n=$(find data/server/cache/accounts -name '*.tsv' -print0 2>/dev/null | xargs -0 grep -h 'Transfer end logged' 2>/dev/null | wc -l | tr -d ' ')
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n bookend(s) leaked into the account mention cache"
fi
# the RE-KEYED COLLECT (2026-09-29, user report): on the one-account,
# many-UC2 STMT_EXPORT_GLOBEX_nn flows some pickups lose their session
# cycleId and the transfer log books them under a FRESH CoreId (a lone
# siteless leg that read subscription Unknown — UCx_STMT-EXPORT-GLOBEX until
# 2026-09-29). bin/session-sites.sh learns _rekeys.tsv from the shared
# transferId of the JSON bookends and the derive moves each leg back: no
# Unknown leg on the account, no mapped lone
# CoreId left, every mapped transfer id inside its original CoreId, and
# none of those Files Failed
if [ "$(exp rekey)" -gt 0 ]; then
    RK="data/transfer/cache/_rekeys.tsv"
    nrk=$(rows "$RK")
    check $([ "${nrk:-0}" -gt 0 ] && echo 0 || echo 1) "_rekeys.tsv is empty (no re-keyed pickup learned)"
    n=$(awk -F'\t' '$6 == "Unknown" && $4 == "STMT-EXPORT-GLOBEX" { n++ } END { print n+0 }' "$T")
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n Unknown-subscription STMT-EXPORT-GLOBEX leg(s) left (re-keyed pickups not moved back)"
    r=$(awk -F'\t' 'NR == FNR { b[$1] = 1; mv[$3 SUBSEP $2] = 1; next } ($1 in b) { lone++ } (($1 SUBSEP $23) in mv) { hit++ } END { print lone+0, hit+0 }' "$RK" "$T")
    read -r rlone rhit <<< "$r"
    check $([ "$rlone" -eq 0 ] && echo 0 || echo 1) "$rlone re-keyed lone CoreId row(s) still in _transfers.tsv"
    check $([ "$rhit" -eq "${nrk:-0}" ] && echo 0 || echo 1) "$rhit of $nrk re-keyed leg(s) found inside their original CoreId"
    # none reads Failed (the lone leg always did); a few read Waiting where
    # the sample collect precedes the routing pair on a slow day — an
    # artifact ordinary collects show as well
    n=$(awk -F'\t' 'NR == FNR { a[$3] = 1; next } ($1 in a) && $2 == "Failed" { n++ } END { print n+0 }' "$RK" "$F")
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "$n File(s) that got a re-keyed pickup back read Failed"
    n=$(command grep -c 'No session cycleId for file' "$P" || true)
    check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "_parse.tsv holds no 'No session cycleId' warning (the re-key shape was not planted)"
fi
# the UC3 that never transfers and CANNOT CONNECT (2026-09-10, user rule):
# no File, every poll a Connection failure — red (not orange), with
# its newest failure in the _redflip sidecar, an error page of its own,
# and a row on Failed Subscriptions (the home page's "Failing subscriptions
# in Server log" table that listed it went 2026-09-29)
if [ "$(exp pollconnfail)" -gt 0 ]; then
    c=$(awk -F'\t' '$1=="UC3_ZG_RATES_OSCORP" { print $3 }' "$B")
    check $([ "$c" = red ] && echo 0 || echo 1) "UC3_ZG_RATES_OSCORP is '${c:-absent}', expected red (every poll a connection failure, no transfer)"
    n=$(awk -F'\t' '$12=="UC3_ZG_RATES_OSCORP" { n++ } END { print n+0 }' "$F")
    check $([ "${n:-0}" -eq 0 ] && echo 0 || echo 1) "UC3_ZG_RATES_OSCORP has $n File(s) — the sample must plant none"
    n=$(awk -F'\t' '$1=="UC3_ZG_RATES_OSCORP" { n++ } END { print n+0 }' "data/colour/_redflip.tsv" 2>/dev/null)
    check $([ "${n:-0}" -eq 1 ] && echo 0 || echo 1) "_redflip.tsv has $n row(s) for UC3_ZG_RATES_OSCORP, expected 1"
    check $([ -f "docs/files/uc3-zg-rates-oscorp.html" ] && echo 0 || echo 1) "docs/files/uc3-zg-rates-oscorp.html missing (the server-failing error page)"
    check $(grep -q 'UC3_ZG_RATES_OSCORP' docs/analyses/failed.html 2>/dev/null && echo 0 || echo 1) "analyses/failed.html does not list UC3_ZG_RATES_OSCORP"
fi
# the HOME PAGE (2026-09-29, user request): no red worklists, no "The log
# exports" table, no Show all button; the site is called "Axway ST reports"
check $(grep -qE 'Failing transfers|Failing subscriptions in Server log|The log exports|showallbtn|cap14' docs/index.html 2>/dev/null && echo 1 || echo 0) "docs/index.html still carries a red worklist, The log exports, or the Show all cap"
check $(grep -q '<h1>Axway ST reports' docs/index.html 2>/dev/null && echo 0 || echo 1) "the home title is not 'Axway ST reports …'"
check $([ -z "$(grep -rl 'Cloud Reports' docs --include='*.html' 2>/dev/null)" ] && echo 0 || echo 1) "a page still says 'Cloud Reports'"
nd=$(awk -F'\t' '$1 == "ROW" && $2 ~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { n++ } END { print n + 0 }' data/transfer/reports/topview.rpt 2>/dev/null)
nh=$(grep -c '<tr><td><a href="day/' docs/index.html 2>/dev/null || true)
# (later that day, user request: "have only 14 days in the Date tables" —
# the newest 14; the sample holds more, so the cap is exercised)
check $([ "${nd:-0}" -gt 14 ] && [ "${nh:-0}" = 14 ] && echo 0 || echo 1) "the home per-day table shows ${nh:-0} linked day(s) of ${nd:-?} (the newest 14 expected, the sample must hold more)"
# ... only the Files (Ok · Cured · Error · Error %) and Duration groups — the
# Transfers, UC2 state and First seen groups and Files In / Out went (2026-09-29)
hdr=$(awk '/<table class="index fit dayrows"/ { p = 1 } p && /<tr>/ && /<th/ { print; exit }' docs/index.html 2>/dev/null | grep -o '<th[^>]*>[^<]*</th>' | sed 's/<[^>]*>//g' | tr '\n' '|')
check $([ "$hdr" = "Date||Ok|Cured|Error|Error %||p50|p75|p90|p95|p99|" ] && echo 0 || echo 1) "the home per-day table headers are '$hdr'"
check $(grep -qE 'class="gband"[^>]*>(Transfers|UC2 state|First seen)<' docs/index.html 2>/dev/null && echo 1 || echo 0) "the home still carries a Transfers / UC2 state / First seen group"
# ... and BESIDE it the Errors table: Subscription · Date/time · Reason of
# every RED Failed Subscriptions row (no orange ones), in the same side-by-side row
ne=$(awk -F'\t' '$1 == "TABLE" { t++ } t == 1 && $1 == "ROW" && /\t@data:res=red(\t|$)/ { n++ } END { print n + 0 }' data/transfer/reports/failed.rpt 2>/dev/null)
nr=$(awk '/<table class="index fit dayrows homeerr"/ { p = 1 } p && /<tr[ >]/ && /<td/ { n++ } p && /<\/table>/ { exit } END { print n + 0 }' docs/index.html 2>/dev/null)
eh=$(awk '/<table class="index fit dayrows homeerr"/ { p = 1 } p && /<tr>/ && /<th/ { print; exit }' docs/index.html 2>/dev/null | grep -o '<th[^>]*>[^<]*</th>' | sed 's/<[^>]*>//g' | tr '\n' '|')
check $([ "${ne:-0}" -gt 0 ] && [ "$nr" = "$ne" ] && [ "$eh" = "Subscription|Date/time|Reason|" ] && echo 0 || echo 1) "the home Errors table: $nr row(s) for ${ne:-?} red Failed Subscriptions row(s), headers '$eh'"
check $(awk '/<table class="index fit dayrows homeerr"/ { p = 1 } p && /<\/table>/ { exit } p && /<tr[ >]/ && /<td/ && !/data-res="red"/ { bad = 1 } END { exit bad }' docs/index.html 2>/dev/null && echo 0 || echo 1) "the home Errors table carries a row that is not red"
# ... its Date/time to the minute (2026-09-29, user request: "only hh:mm, no ss.mmm")
n=$(awk '/<table class="index fit dayrows homeerr"/ { p = 1 } p && /<\/table>/ { exit } p && /<td/ && /[0-9]:[0-9][0-9]:[0-9][0-9]/ { n++ } END { print n + 0 }' docs/index.html 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "the home Errors table: $n row(s) whose Date/time still carries seconds"
check $(awk '/<div class="sxs homeday">/ { s = 1 } s && /<table class="index fit dayrows"/ { a = 1 } s && a && /homeerr/ { ok = 1; exit } END { exit !ok }' docs/index.html 2>/dev/null && echo 0 || echo 1) "the home Errors table does not sit beside the per-day table (one sxs row)"
# no detail page lists Files from the stream any more (the Latest 100
# table went 2026-09-29, user request)
check $([ -z "$(grep -rlE '<h2>Latest (100|1000) ' docs/details 2>/dev/null)" ] && echo 0 || echo 1) "a detail page still carries a Latest 100 / Latest 1000 Files table"
# the failure heatmap's By hour / By weekday sit side by side (2026-09-29)
# (the ONE flex row: no new sxs row may open between the two headings — the
# 2026-09-29 audit: the old test passed on stacked tables after any sxs)
check $(awk '/<div class="sxs">/ { s = NR } /By hour of day/ && s { h = s } /By weekday/ && h { ok = (s == h); exit } END { exit !ok }' docs/transfer/failure-heatmap.html 2>/dev/null && echo 0 || echo 1) "transfer/failure-heatmap.html: By hour of day and By weekday are not side by side"
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
# the session join, the skip list, the Unknown subscription, resubmissions
n=$(awk -F'\t' '$17 == "Blocked" || $17 == "Error" { n++ } END { print n + 0 }' "$T")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "no Blocked/Error AV rows"
n=$(rows "data/transfer/cache/_sessionsites.tsv")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "_sessionsites.tsv empty (session join unexercised)"
n=$(rows "data/transfer/_skipped.tsv")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "skip list caught 0 transfer rows"
n=$(awk -F'\t' '$6 == "Unknown" { n++ } END { print n + 0 }' "$T")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "no Unknown-subscription legs"
# UCx is GONE (2026-09-29, user request: "drop support for UCx on the
# complete site, give those the value Unknown for subscription, do not show
# Unknown rows in any subscription based table, add Unknown transfers"):
# no UCx_ name anywhere; Unknown is no entity (base, detail page, per-
# subscription Files data) and no row of a subscription table; the Unknown
# transfers page lists exactly the Unknown Files
n=$(awk -F'\t' '$6 ~ /^UCx_/ { n++ } END { print n + 0 }' "$T")
check $([ "$n" -eq 0 ] && echo 0 || echo 1) "$n UCx_ synthetic-site leg(s) — UCx went 2026-09-29"
check $(grep -q $'^Unknown\t' data/flow-manager/base/_subscriptions.tsv 2>/dev/null && echo 1 || echo 0) "base/_subscriptions.tsv lists Unknown (the no-subscription value)"
check $([ -f docs/details/subscriptions/unknown.html ] || [ -f docs/search/all/s/unknown.js ] && echo 1 || echo 0) "Unknown has a subscription detail page or per-subscription Files data"
n=$(grep -rlE $'^ROW\t(@\\{[^}]*\\})?Unknown\t' data/transfer/reports data/analyses/reports data/dashboards/reports 2>/dev/null | grep -v '/errors/\|/files/\|failed-files.rpt\|unknown-transfers.rpt' | wc -l | tr -d ' ')
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "$n subscription table(s) still carry an Unknown row"
nu=$(awk -F'\t' '$12 == "Unknown" && $4 != "" { n++ } END { print n + 0 }' "$F")
nr=$(awk -F'\t' '$1 == "TABLE" { t++ } $1 == "ROW" && t == 1 && $2 !~ /^@\{colspan/ { n++ } END { print n + 0 }' data/transfer/reports/unknown-transfers.rpt 2>/dev/null)
check $([ "${nu:-0}" -gt 0 ] && [ "$nu" = "$nr" ] && echo 0 || echo 1) "Unknown transfers lists ${nr:-0} File(s), _files.tsv holds ${nu:-0} Unknown File(s)"
check $([ -f docs/transfer/unknown-transfers.html ] && grep -q '<a class="tab" href="../transfer/unknown-transfers.html">Unknown transfers</a>' docs/analyses/failed.html 2>/dev/null && echo 0 || echo 1) "Unknown transfers is missing or not in the Errors group row"
n=$(awk -F'\t' '$22 == "true" { n++ } END { print n + 0 }' "$T")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "no resubmitted legs"

# the Retry / Resubmit group of the Entities pages (Cured 2026-09-10, split
# 2026-09-12, grouped 2026-09-13, user requests): Auto = an OK File with a
# failed leg and no resubmitted leg, Ok / Error = every File with a
# resubmitted leg, by its outcome (the Top view rule). Checked on the GROUPED
# entities/<name>.rpt since 2026-09-29 — the classic <name>.rpt records carry
# Files / Error / OK only: per row Auto + Ok never exceed the row's OK Files
# (its per-day buckets date:files:in:out:ferr:…), the rendered views show the
# group, and the account totals equal an independent recount of the two caches
EA="data/transfer/reports/entities/account.rpt"; ES="data/transfer/reports/entities/subscription.rpt"
n=$(awk -F'\t' '$1 == "ROW" { ok = 0
        for (i = 2; i <= NF; i++) if (index($i, "@data:buckets=") == 1) { nb = split(substr($i, 15), B, ","); for (j = 1; j <= nb; j++) { split(B[j], z, ":"); ok += z[2] - z[5] } }
        if ($7 + $8 > ok) n++ } END { print n + 0 }' "$ES" 2>/dev/null)
check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "entities/subscription.rpt: ${n:-?} row(s) with Auto + Resubmit Ok > the OK Files"
hdr=$(grep -o '<tr><th>Account</th>.*' "docs/transfer/entities/account-all.html" 2>/dev/null | head -1 | sed 's/^<tr>//; s/<\/tr>.*//; s/<th[^>]*>//g; s/<\/th>/|/g')
check $([ "$hdr" = "Account|In|Out|Error|Error %|Auto|Ok|Error|p90|p95|p99|p100|Total|Avg|Ok|Error|Error %|Waiting|Expired|First|Last|Days|" ] && echo 0 || echo 1) "entities/account-all.html header is '$hdr', expected the grouped layout Account|In|Out|Error|Error %|Auto|Ok|Error|p90|p95|p99|p100|Total|Avg|Ok|Error|Error %|Waiting|Expired|First|Last|Days"
read -r want wantm wante <<< "$(awk -F'\t' 'FNR == 1 { fno++ } fno == 1 { if ($3 != "Processed") fl[$1] = 1; if ($22 == "true") rs[$1] = 1; next }
    $3 != "" && $4 != "" { ok = ($2 != "Failed" && $2 != "Expired"); if (ok && ($1 in fl) && !($1 in rs)) a++; if ($1 in rs) { if (ok) m++; else e++ } }
    END { print a + 0, m + 0, e + 0 }' "$T" "$F" 2>/dev/null)"
read -r got gotm gote <<< "$(awk -F'\t' '$1 == "TOTAL" { a = $7; b = $8; c = $9; sub(/^@\{[^}]*\}/, "", a); sub(/^@\{[^}]*\}/, "", b); sub(/^@\{[^}]*\}/, "", c); print a + 0, b + 0, c + 0; exit }' "$EA" 2>/dev/null)"
check $([ "${got:-x}" = "${want:-y}" ] && echo 0 || echo 1) "entities/account.rpt Auto total is '${got:-absent}', an independent recount of the caches gives '${want:-?}'"
check $([ "${gotm:-x}" = "${wantm:-y}" ] && echo 0 || echo 1) "entities/account.rpt Resubmit Ok total is '${gotm:-absent}', an independent recount of the caches gives '${wantm:-?}'"
check $([ "${gote:-x}" = "${wante:-y}" ] && echo 0 || echo 1) "entities/account.rpt Resubmit Error total is '${gote:-absent}', an independent recount of the caches gives '${wante:-?}'"
check $([ "${want:-0}" -gt 0 ] && [ "${wantm:-0}" -gt 0 ] && echo 0 || echo 1) "the sample has no Auto (${want:-0}) or no Resubmit Ok (${wantm:-0}) File — an Entities column is never exercised"
# the Retry / Resubmit DRILLS (2026-09-13, user request): every row with an
# Auto / Ok / Error count carries a non-empty coreids-rauto / -rmok / -rmerr
# list of at most 10 entries, a row without one an empty list, and the
# rendered page ships the attributes
read -r dr1 dr2 dr3 <<< "$(awk -F'\t' '$1 == "ROW" {
        r = ""; s = ""; e = ""
        for (i = 2; i <= NF; i++) { if (index($i, "@data:coreids-rauto=") == 1) r = substr($i, 21); if (index($i, "@data:coreids-rmok=") == 1) s = substr($i, 20); if (index($i, "@data:coreids-rmerr=") == 1) e = substr($i, 21) }
        nr = (r == "" ? 0 : split(r, a, ",")); ns = (s == "" ? 0 : split(s, b, ",")); ne = (e == "" ? 0 : split(e, c, ","))
        if (($7 + 0 > 0) != (nr > 0) || ($8 + 0 > 0) != (ns > 0) || ($9 + 0 > 0) != (ne > 0)) bad++
        if (nr > 10 || ns > 10 || ne > 10) big++
        if (nr > 0) anyr++; if (ns > 0) anys++ }
    END { print bad + 0, big + 0, (anyr > 0 && anys > 0) + 0 }' "$ES" 2>/dev/null)"
check $([ "${dr1:-1}" = 0 ] && echo 0 || echo 1) "entities/subscription.rpt: ${dr1:-?} row(s) whose Auto / Resubmit count and drill list disagree"
check $([ "${dr2:-1}" = 0 ] && echo 0 || echo 1) "entities/subscription.rpt: ${dr2:-?} Auto / Resubmit drill list(s) longer than 10"
check $([ "${dr3:-0}" = 1 ] && echo 0 || echo 1) "the sample subscription table has no Auto drill or no Resubmit Ok drill — one of the two is never exercised"
# (the Entities rows' payload ships in <entity>-data.js since 2026-09-30 —
# publish_lib entity_payload_split; report.js puts it back on the rows)
check $([ "$(grep -c 'data-coreids-rauto="[0-9=#]' docs/transfer/entities/subscription-data.js 2>/dev/null)" -ge 1 ] && [ "$(grep -c 'data-coreids-rmok="[0-9=#]' docs/transfer/entities/subscription-data.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "entities/subscription-data.js ships no Retry / Resubmit drill lists"
# (the report.js binding of data-coreids-retry / -resubmit went 2026-09-29:
# no page ships those lists — the Entities pages drill rauto / rmok / rmerr)

# NO EMPTY GROUP TAB (2026-09-13, user report: transfer/files-by-size.html
# showed a blank second button — the merged "files" report had no
# member_label, so its own active tab rendered as an empty span): every
# group member must have a label, on every page
n=$(grep -rl '<span class="tab active"></span>' docs 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n page(s) render an EMPTY active group tab (a group member without a member_label)"
n=$(grep -rl '<a class="tab" href="[^"]*"></a>' docs 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n page(s) render an EMPTY group tab link (a group member without a member_label)"

# the Top view's six column groups (2026-09-12, user request): Files WITHOUT
# Recovered, then the Recovered group (Automatic · Manual) and the Resubmit
# group (Ok · Error — the UI Error/OK terms; "Failed" until 2026-09-29)
# between Files and Transfers — Manual = a recovered
# File with a Resubmitted=true leg (col 22), Resubmit = every File with such
# a leg, Ok/Failed by outcome; every figure on the File's START day. The
# totals must equal an independent recount of the two caches, all four new
# columns must be exercised, and the home page's Cured (= Automatic +
# Manual, ROW fields 9-10) must still equal the recovered total.
TV="data/transfer/reports/topview.rpt"
h=$(awk -F'\t' '$1 == "HEAD" { print; exit }' "$TV" 2>/dev/null)
check $([ "$h" = $'HEAD\tDate\tFirst\tLast\tCount\tOk\tError\tError %\tAutomatic\tManual\tOk\tError\tCount\tOk\tError\tError %\tProcessed\tFailed\tWaiting\tExpired\tVolume' ] && echo 0 || echo 1) "topview.rpt HEAD is '$h' — expected the seven groups Date|Files|Recovered|Resubmit|Transfers|State|Volume"
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
# the home Cured cells cover the SHOWN days (the newest 14, no Total row since
# 2026-09-29): their sum = the Top view's Automatic + Manual over those days
hc=$(grep -o '<a href="transfer/retries-recovered-files.html?axway_date=[0-9-]*">[0-9.]*</a>' docs/index.html 2>/dev/null | sed 's/<[^>]*>//g; s/\.//g' | awk '{ s += $1 } END { print s + 0 }')
w14=$(awk -F'\t' '$1 == "ROW" { d = $2; sub(/^@\{[^}]*\}/, "", d); d = substr(d, 1, 10); if (d ~ /^[0-9][0-9][0-9][0-9]-/) R[d] = ($9 + 0) + ($10 + 0) }
    END { n = 0; for (d in R) D[++n] = d; for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (D[j] > D[i]) { t = D[i]; D[i] = D[j]; D[j] = t }
          for (i = 1; i <= n && i <= 14; i++) s += R[D[i]]; print s + 0 }' data/transfer/reports/topview.rpt 2>/dev/null)
check $([ "${hc:-x}" = "${w14:-y}" ] && echo 0 || echo 1) "home Cured cells sum to '${hc:-absent}', expected the newest 14 days' recovered total ${w14:-?}"
# the Recovered files report's Retry / Resubmit split (2026-09-12, user
# request): every table carries the two columns after Recovered — the same
# Automatic / Manual rule as the Top view, so the per-subscription totals
# must equal the recount above, and the per-day totals the same
RF="data/transfer/reports/recovered-files.rpt"
h=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "HEAD" { print; exit }' "$RF" 2>/dev/null)
check $([ "$h" = $'HEAD\tSubscription\tRecovered\tAutomatic\tManual\tFiles\tRecovered %' ] && echo 0 || echo 1) "recovered-files.rpt table 1 HEAD is '$h' — expected Recovered · Automatic · Manual (the Top view words, 2026-09-29)"
read -r rfr rfa rfm <<< "$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "TOTAL" { a = $3; b = $4; c = $5; sub(/^@\{[^}]*\}/, "", a); sub(/^@\{[^}]*\}/, "", b); sub(/^@\{[^}]*\}/, "", c); print a + 0, b + 0, c + 0; exit }' "$RF" 2>/dev/null)"
check $([ "${rfr:-x}" = "${wrv:-y}" ] && [ "$((${rfa:-0} + ${rfm:-0}))" = "${wrv:-y}" ] && echo 0 || echo 1) "recovered-files Recovered/Retry/Resubmit = ${rfr:-?}/${rfa:-?}/${rfm:-?}, the caches give ${wrv:-?} recovered"
check $([ "${rfm:-x}" = "${wrm:-y}" ] && echo 0 || echo 1) "recovered-files Resubmit = ${rfm:-absent}, the caches give ${wrm:-?}"
read -r dfa dfm <<< "$(awk -F'\t' '/^TABLE\t/ { t++ } t == 3 && $1 == "TOTAL" { b = $5; c = $6; sub(/^@\{[^}]*\}/, "", b); sub(/^@\{[^}]*\}/, "", c); print b + 0, c + 0; exit }' "$RF" 2>/dev/null)"
check $([ "${dfa:-x}" = "${rfa:-y}" ] && [ "${dfm:-x}" = "${rfm:-y}" ] && echo 0 || echo 1) "recovered-files per-day Retry/Resubmit totals ${dfa:-?}/${dfm:-?} differ from the per-subscription ${rfa:-?}/${rfm:-?}"
check $([ "$(grep -c '>Automatic<\|>Manual<' "docs/transfer/retries-recovered-files.html" 2>/dev/null)" -ge 2 ] && echo 0 || echo 1) "transfer/recovered-files.html lacks the Automatic / Manual boxes"
# the Failed files list (2026-09-14, user request): one row per Failed/Expired File, per start day equal
# to the Top view's Files/Error column (the home Error cells), which now open it narrowed to their day
FF="data/transfer/reports/failed-files.rpt"
n=$(rpt_rows "$FF"); wn=$(awk -F'\t' '$2 == "Failed" || $2 == "Expired" { n++ } END { print n + 0 }' data/transfer/cache/_files.tsv 2>/dev/null)
check $([ "${n:-0}" -gt 0 ] && [ "$n" = "$wn" ] && echo 0 || echo 1) "failed-files.rpt has ${n:-0} row(s), the Files cache ${wn:-?} Failed/Expired File(s)"
n=$(awk -F'\t' 'FNR == NR { if ($1 == "TABLE") t++; if (t == 1 && $1 == "ROW") { d = $2; sub(/^@\{[^}]*\}/, "", d); d = substr(d, 1, 10); if (d ~ /^[0-9][0-9][0-9][0-9]-/) T[d] = $7 + 0 } next }
    $1 == "ROW" { F[substr($3, 1, 10)]++ }
    END { for (d in T) if (T[d] != F[d] + 0) b++; for (d in F) if (!(d in T)) b++; print b + 0 }' data/transfer/reports/topview.rpt "$FF" 2>/dev/null || echo 1)
check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "failed-files: $n day(s) whose row count differs from the Top view Files/Error"
# ... its rows carry the standard subscription colours (2026-09-14): a restint table, tinted rows
n=$(grep -c '@data:res=' "$FF" 2>/dev/null || true)
check $([ "${n:-0}" -gt 0 ] && grep -q 'restint' "$FF" 2>/dev/null && echo 0 || echo 1) "failed-files.rpt: ${n:-0} tinted row(s) or no restint table"
n=$(grep -c 'href="transfer/failed-files.html?axway_date=' docs/index.html 2>/dev/null || true)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "home Error cells do not open transfer/failed-files.html"

# NO "Last error" / "Last OK transfer" SECTION on a subscription page
# (2026-09-16, user request): both became Features ROWS — "Latest Error" and
# "Latest OK" — each reading "<date time>  <file name>" and linking that
# File's OWN page under files/, which failed.sh guarantees.
# The publish-time splice that folded the error in below Features went too.
n=0; m=0
for f in docs/details/subscriptions/*.html; do
    if grep -qE '<h2>Last error( |<)' "$f" 2>/dev/null; then n=$((n + 1)); fi
    if grep -q '<h2>Last OK transfer' "$f" 2>/dev/null; then n=$((n + 1)); fi
    if grep -q '<h2>Server log error' "$f" 2>/dev/null; then n=$((n + 1)); fi
    if grep -q '>Server log error<' "$f" 2>/dev/null; then
        if ! grep -q 'href="../../files/' "$f" 2>/dev/null; then m=$((m + 1)); fi
    fi
    if grep -q '>Latest Error<' "$f" 2>/dev/null; then
        if ! grep -q 'href="../../files/' "$f" 2>/dev/null; then m=$((m + 1)); fi
    fi
    if grep -q '>Latest OK<' "$f" 2>/dev/null; then
        if ! grep -q 'href="../../files/' "$f" 2>/dev/null; then m=$((m + 1)); fi
    fi
done
check $([ "$n" = 0 ] && echo 0 || echo 1) "$n subscription page section(s) still show the last error / last OK transfer inline"
check $([ "$m" = 0 ] && echo 0 || echo 1) "$m subscription page(s) carry a Latest Error / Latest OK row that links no page"
# ... and the rows must be EXERCISED: the sample estate has both failing and
# delivering flows, so at least one page carries each row
n=$(grep -l '>Latest Error<' docs/details/subscriptions/*.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "no sample subscription page carries a Features 'Latest Error' row"
n=$(grep -l '>Latest OK<' docs/details/subscriptions/*.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "no sample subscription page carries a Features 'Latest OK' row"

# the search pages live under docs/search/ (2026-09-12, user request):
# search.html + search-data.js and all-files.html — nothing of them left at
# the docs root, and the top bar / sitemap / finder link there
for p in search.html search-data.js all-files.html; do
    check $([ -f "docs/search/$p" ] && echo 0 || echo 1) "docs/search/$p is missing"
    check $([ ! -e "docs/$p" ] && echo 0 || echo 1) "docs/$p still sits at the docs root"
done
# the seven File search window pages went 2026-09-29 (user request): the
# All files search is the one file search
check $([ -z "$(ls docs/search/file-search-* docs/assets/file-search.js docs/help/file-search.html 2>/dev/null)" ] && echo 0 || echo 1) "the File search pages (search/file-search-*, assets/file-search.js, help/file-search.html) are still published"
check $([ "$(grep -c 'href="../search/search.html"' docs/tools/sitemap.html 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "tools/sitemap.html does not link ../search/search.html"
# the Report finder, the command palette and the dark theme went 2026-09-29
# (user request) — no page, no help page, no report.js code, no dark CSS
check $([ -z "$(ls docs/tools/report-finder.html docs/help/report-finder.html 2>/dev/null)" ] && echo 0 || echo 1) "the Report finder (tools/report-finder.html or its help page) is still published"
check $(grep -q 'setupPalette\|setupReportFinder\|setupTheme\|axway-theme' docs/assets/report.js 2>/dev/null && echo 1 || echo 0) "report.js still carries the palette / report finder / theme code"
check $(grep -q 'data-theme="dark"\|axway-theme' docs/assets/style.css docs/help/index.html docs/index.html 2>/dev/null && echo 1 || echo 0) "the dark theme (CSS or head script) is still published"
# THE TOP BAR is ONE implementation since 2026-09-30 (assets/topbar.js, on
# every page — the help pages and the build report included; the baked
# render_topbar copy went): every help page and the build report carry the
# placeholder and load topbar-data.js + topbar.js; topbar.js links the search
tb=docs/assets/topbar.js
n=0; nh=0; for f in docs/help/*.html; do nh=$((nh + 1)); grep -q '<div class="topbar" data-b="../" data-help="general"></div>' "$f" && grep -q '<script src="../assets/topbar-data.js' "$f" && grep -q '<script src="../assets/topbar.js' "$f" && n=$((n + 1)); done
check $([ "$nh" -gt 0 ] && [ "$n" = "$nh" ] && echo 0 || echo 1) "$n of $nh help page(s) carry the top-bar placeholder + topbar-data.js + topbar.js"
check $(grep -q '<div class="topbar" data-b="../" data-help="general"></div>' docs/tools/build.html 2>/dev/null && grep -q 'assets/topbar.js' docs/tools/build.html && echo 0 || echo 1) "tools/build.html lacks the top-bar placeholder or topbar.js"
check $(grep -q 'search/search.html" title="Search"' "$tb" 2>/dev/null && echo 0 || echo 1) "topbar.js does not link search/search.html"
n=$(grep -l 'assets/report.js' $(find docs -name '*.html') 2>/dev/null | xargs grep -L 'assets/topbar.js' 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n page(s) load report.js without topbar.js (the bar would stay empty)"
check $([ "$(grep -c 'href="\.\./details/' docs/search/search-data.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "search/search-data.js rows do not link ../details/ (one level below the root)"

# the SUBSCRIPTION FILES TABLE (2026-09-29, user request): docs/latest/ and
# the "Latest 1000 files" Features row are gone; every subscription page
# with Files carries the empty browser-built Files table (data-subfiles =
# its slug, data-v = the build id), loads assets/sub-files.js, and has its
# day list docs/search/all/s/<slug>.js whose Files add up to the page's own
# "<strong>N</strong> Files" count; every day it names has its shard
check $([ ! -e docs/latest ] && echo 0 || echo 1) "docs/latest/ is still published (the Latest files pages went 2026-09-29)"
check $([ -z "$(grep -l 'Latest 1000 files' docs/details/subscriptions/*.html 2>/dev/null)" ] && echo 0 || echo 1) "a subscription page still carries the Latest 1000 files row"
check $([ -f docs/assets/sub-files.js ] && echo 0 || echo 1) "docs/assets/sub-files.js is missing"
nsp=0; nst=0; nss=0; nsl=0; nsc=0; nsd=0
for f in docs/details/subscriptions/*.html; do
    [ -f "$f" ] || continue
    b=${f##*/}; b=${b%.html}
    pc=$(grep -o '<strong>[0-9]*</strong> Files' "$f" | head -1 | tr -dc '0-9')
    [ -n "$pc" ] && [ "$pc" -gt 0 ] || continue
    nsp=$((nsp + 1))
    grep -q "data-subfiles=\"$b\" data-v=\"[0-9][0-9]*\"" "$f" && nst=$((nst + 1))
    grep -q '<script src="../../assets/sub-files.js?v=' "$f" && nss=$((nss + 1))
    l="docs/search/all/s/$b.js"
    [ -f "$l" ] || continue
    nsl=$((nsl + 1))
    lc=$(awk -F'\t' '{ sub(/^AXWAY_AFS\("[^"]*",`/, ""); sub(/`\);$/, ""); n += $2 } END { print n + 0 }' "$l")
    [ "$lc" = "$pc" ] && nsc=$((nsc + 1))
    miss=$(awk -F'\t' '{ sub(/^AXWAY_AFS\("[^"]*",`/, ""); print $1 }' "$l" | while read -r d; do [ -f "docs/search/all/d-$d.js" ] || echo "$d"; done)
    [ -z "$miss" ] && nsd=$((nsd + 1))
done
check $([ "$nsp" -gt 0 ] && echo 0 || echo 1) "no subscription page with Files found"
check $([ "$nst" = "$nsp" ] && echo 0 || echo 1) "Files table: $nst of $nsp subscription pages with Files carry data-subfiles + data-v"
check $([ "$nss" = "$nsp" ] && echo 0 || echo 1) "Files table: $nss of $nsp subscription pages load assets/sub-files.js"
check $([ "$nsl" = "$nsp" ] && echo 0 || echo 1) "Files table: $nsl of $nsp subscription pages have a search/all/s/<slug>.js day list"
check $([ "$nsc" = "$nsl" ] && echo 0 || echo 1) "Files table: $nsc of $nsl day lists add up to their page's File count"
check $([ "$nsd" = "$nsl" ] && echo 0 || echo 1) "Files table: $nsd of $nsl day lists name only days that have a shard"
check $([ -z "$(grep -l 'data-subfiles=' docs/details/accounts/*.html docs/details/partners/*.html 2>/dev/null)" ] && echo 0 || echo 1) "a non-subscription detail page carries the subscription Files table"
# THE FILE COLOUR (2026-09-29, user request): _files.tsv col 25 is green /
# orange / red for every File — red = Failed or Expired, orange = Waiting or
# an OK File with a failed or resubmitted leg, green = an OK File without —
# and the Files tables tint their rows by it
FC=data/transfer/cache/_files.tsv
n=$(awk -F'\t' 'NF != 27 || $25 !~ /^(green|orange|red)$/ { n++ } END { print n + 0 }' "$FC" 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "_files.tsv: $n row(s) without 27 columns or a green / orange / red colour in col 25"
# THE LEG FLAGS (2026-09-29): col 26 = "1" when a leg FAILED (_transfers.tsv
# col 3 not Processed), col 27 = "1" when a leg was RESUBMITTED (col 22
# true), "" otherwise — each must equal a recount from the legs, both must
# be exercised, and an OK (Processed) File is orange exactly when one is set
read -r n n26 n27 <<< "$(awk -F'\t' 'FNR == 1 { f++ } f == 1 { if ($3 != "Processed") fl[$1] = 1; if ($22 == "true") rs[$1] = 1; next }
    { if (!($26 == "1" || $26 == "") || !($27 == "1" || $27 == "") || (($1 in fl) != ($26 == "1")) || (($1 in rs) != ($27 == "1"))) n++; if ($26 == "1") a++; if ($27 == "1") b++ }
    END { print n + 0, a + 0, b + 0 }' data/transfer/cache/_transfers.tsv "$FC" 2>/dev/null)"
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "_files.tsv: ${n:-?} row(s) whose col 26 / 27 leg flags disagree with a recount of _transfers.tsv (failed leg / resubmitted leg)"
check $([ "${n26:-0}" -gt 0 ] && [ "${n27:-0}" -gt 0 ] && echo 0 || echo 1) "_files.tsv: ${n26:-0} File(s) with the failed-leg flag, ${n27:-0} with the resubmitted-leg flag — one of the two is never exercised"
n=$(awk -F'\t' '$2 == "Processed" && (($25 == "orange") != ($26 == "1" || $27 == "1")) { n++ } END { print n + 0 }' "$FC" 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "_files.tsv: $n delivered File(s) whose orange colour (col 25) disagrees with the col 26 / 27 leg flags"
n=$(awk -F'\t' '(($2 == "Failed" || $2 == "Expired") && $25 != "red") || ($2 == "Waiting" && $25 != "orange") || ($2 == "Processed" && $25 == "red") { n++ } END { print n + 0 }' "$FC" 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "_files.tsv: $n row(s) whose col-25 colour contradicts the outcome"
n=$(awk -F'\t' 'FNR == 1 { f++ } f == 1 { if ($3 != "Processed" || $22 == "true") hit[$1] = 1; next } $2 == "Processed" { if (($1 in hit) != ($25 == "orange")) n++; if ($25 == "orange") o++ } END { print n + 0, o + 0 }' data/transfer/cache/_transfers.tsv "$FC" 2>/dev/null)
check $([ "${n%% *}" = 0 ] && [ "${n##* }" -gt 0 ] && echo 0 || echo 1) "_files.tsv: ${n%% *} delivered File(s) orange without a failed / resubmitted leg or green with one (${n##* } orange delivered File(s) — the sample plants retries, so some are expected)"
check $(grep -hq $'\t[oO]$' docs/search/all/d-*.js 2>/dev/null && echo 0 || echo 1) "no day shard carries the o / O flag (an OK File after a retry or resubmit)"
n=$(cat docs/transfer/waiting/*.html 2>/dev/null | grep -c '<tr data-res="orange"' || true); m=$(cat docs/transfer/expired/*.html 2>/dev/null | grep -c '<tr data-res="red"' || true)
check $([ "${n:-0}" -gt 0 ] && [ "${m:-0}" -gt 0 ] && echo 0 || echo 1) "the Waiting / Expired File list pages: ${n:-0} orange / ${m:-0} red row(s), expected both"
n=$(grep -c '<tr data-res="orange"' docs/transfer/duration-longest.html 2>/dev/null || true)
check $(grep -q 'data-restint' docs/transfer/duration-longest.html 2>/dev/null && grep -q '<tr data-res="green"' docs/transfer/duration-longest.html && echo 0 || echo 1) "transfer/duration-longest.html rows do not carry the File colour (${n:-0} orange)"
# the top bar's Files link opens the ALL FILES search (2026-09-28, user
# request; the Latest files search until then) — checked on the BAKED bar
# (help pages); report.js buildTopbar draws the same link. Since 2026-09-29
# it sits in ONE cluster with Entities and Errors (Errors = the Errors
# group's first page, Failed Subscriptions), the search icon after them.
# (checked in topbar.js, the ONE bar implementation since 2026-09-30: the
# cluster's links in this order)
n=$(awk '/<span class="entgroup">/ && !a { a = NR } />Overview<\/a>/ && !o { o = NR } />Entities<\/a>/ && !e { e = NR } />Errors<\/a>/ && !r { r = NR } />Files<\/a>/ && !f { f = NR } /search\/search.html" title="Search"/ && !s { s = NR }
    END { print (a && a <= o && o < e && e < r && r < f && f <= s) ? 1 : 0 }' docs/assets/topbar.js 2>/dev/null)
check $([ "${n:-0}" = 1 ] && grep -q 'subscription-all.html">Entities</a>' docs/assets/topbar.js && grep -q 'search/all-files.html">Files</a>' docs/assets/topbar.js && echo 0 || echo 1) "topbar.js lacks the Overview / Entities / Errors / Files cluster in that order (Files -> search/all-files.html)"
# Errors is a top-bar link, not a Reports pulldown line
check $(grep -oE 'reports:"([^"\\]|\\.)*"' docs/assets/topbar-data.js 2>/dev/null | grep -q 'analyses/failed.html' && echo 1 || echo 0) "the Reports pulldown still lists the Errors group"
check $(grep -q 'errors:"analyses/failed.html"' docs/assets/topbar-data.js 2>/dev/null && echo 0 || echo 1) "topbar-data.js lacks errors:\"analyses/failed.html\" (the runtime bar's Errors link)"
# the Implementation 1 | 2 tab row went with the File search pages
# (2026-09-29): the all-files page is the only implementation left
check $(grep -q 'Implementation 1, period' docs/search/all-files.html 2>/dev/null && echo 1 || echo 0) "search/all-files.html still carries the Implementation tab row"

# the ALL FILES SEARCH (2026-09-27, user request): the page loads its manifest
# and engine, has the shared From/To (rangehook), and the day shards hold
# EVERY dated File of the transfer cache — one shard per day, no row missing
check $([ -f docs/search/all-files.html ] && grep -q '<script src="all/index.js?v=' docs/search/all-files.html && grep -q '<script src="../assets/all-files-search.js?v=' docs/search/all-files.html && echo 0 || echo 1) "search/all-files.html is missing or does not load all/index.js + ../assets/all-files-search.js"
check $(grep -q '<meta name="report-dates" content="[0-9]' docs/search/all-files.html 2>/dev/null && grep -q 'data-rangehook="1"' docs/search/all-files.html && echo 0 || echo 1) "search/all-files.html lacks the report-dates meta or its rangehook table (no From/To)"
nfd=$(awk -F'\t' '$4 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { n++ } END { print n + 0 }' data/transfer/cache/_files.tsv 2>/dev/null)
nsr=$(cat docs/search/all/d-*.js 2>/dev/null | awk -F'\t' 'NF >= 6 { n++ } END { print n + 0 }')
check $([ "${nsr:-0}" -gt 0 ] && [ "$nsr" = "$nfd" ] && echo 0 || echo 1) "search/all/ day shards hold ${nsr:-0} File row(s), the transfer cache has $nfd dated File(s)"
nsd=$(ls docs/search/all/d-*.js 2>/dev/null | wc -l | tr -d ' ')
nmd=$(grep -oE "(^|\`)[0-9]{4}-[0-9]{2}-[0-9]{2}	[0-9]+	" docs/search/all/index.js 2>/dev/null | wc -l | tr -d " ")
check $([ "$nsd" = "$nmd" ] && [ "$nsd" -gt 0 ] && echo 0 || echo 1) "search/all/: $nsd day shard(s) but $nmd manifest day line(s)"
check $(grep -q 'href="../search/all-files.html"' docs/tools/sitemap.html 2>/dev/null && echo 0 || echo 1) "the sitemap does not link search/all-files.html"

# the tool pages live under docs/tools/ (2026-09-12, user request): the
# sitemap AND the build report (back on the site, written last by
# bin/build.sh) — nothing of them at the root, every outward link carrying
# ../, the sitemap Tools card linking the build report ./, the runtime bar
# data pointing at tools/. (The report finder went 2026-09-29, What is new
# the same day — "remove /tools/whats-new.html".)
for p in sitemap.html build.html; do
    check $([ -f "docs/tools/$p" ] && echo 0 || echo 1) "docs/tools/$p is missing"
    check $([ ! -e "docs/$p" ] && echo 0 || echo 1) "docs/$p still sits at the docs root"
done
check $([ "$(grep -c 'href="\./build.html"' docs/tools/sitemap.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "tools/sitemap.html does not link ./build.html under Tools"
check $([ -z "$(ls docs/tools/whats-new.html docs/help/whats-new.html bin/build/whats-new-history.tsv 2>/dev/null)" ] && echo 0 || echo 1) "What is new (tools/whats-new.html, its help page or bin/build/whats-new-history.tsv) still exists"
check $(grep -rlq 'whats-new' docs --include='*.html' 2>/dev/null && echo 1 || echo 0) "a page still links whats-new"
check $([ "$(grep -c 'href="\.\./reports/index.html"' docs/tools/sitemap.html 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "tools/sitemap.html does not link the Reports start page ../reports/index.html"
check $([ "$(grep -cE 'href="\.\./assets/style\.css(\?v=[0-9]+)?"' docs/tools/build.html 2>/dev/null)" = 1 ] && [ "$(grep -c '@B@' docs/tools/build.html build/index.html 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')" = 0 ] && echo 0 || echo 1) "tools/build.html does not load ../assets/style.css, or a @B@ placeholder survived"
check $([ "$(grep -cE 'href="\.\./docs/assets/style\.css(\?v=[0-9]+)?"' build/index.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "build/index.html (the local copy) does not load ../docs/assets/style.css"
check $([ "$(grep -c 'tools/sitemap.html' docs/assets/topbar.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "topbar.js does not point the top bar at tools/sitemap.html"
hdr=$(grep -o '<th[^>]*>[^<]*</th>' "docs/transfer/topview.html" 2>/dev/null | sed 's/<[^>]*>//g' | tr '\n' '|')
check $([ "$hdr" = "|Files|Recovered|Resubmit|Transfers|State||Date|First|Last|Count|Ok|Error|Error %|Automatic|Manual|Ok|Error|Count|Ok|Error|Error %|Processed|Failed|Waiting|Expired|Volume|" ] && echo 0 || echo 1) "transfer/topview.html headers are '$hdr'"
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

# the END rule (2026-09-12, user rule: "there are CoreIds from this
# subscription that ended ok after it — in those cases do not mark it as a
# Server Error"): the planted lateok flow (estate.awk UC1_DPL_PAYOUT_DUNDER)
# logs a connection-failure E line at X and ONE File that STARTED before X
# and was DELIVERED by its retry after X — start < error < end. The flow
# stays GREEN: no red flip, not server-failing, not in the kaput evidence, no banner
# on its page; _files.tsv col 24 carries that end; and every dated File has
# an end no earlier than its start
if [ "$(exp lateok)" -gt 0 ]; then
    lk="UC1_DPL_PAYOUT_DUNDER"
    lrow=$(awk -F'\t' -v s="$lk" '$12 == s && $6 > mx { mx = $6; r = $2 "\t" $4 " " $5 "\t" $24 } END { print r }' "$F" 2>/dev/null)
    loc=$(printf '%s' "$lrow" | cut -f1); lst=$(printf '%s' "$lrow" | cut -f2); len=$(printf '%s' "$lrow" | cut -f3)
    lerr=$(awk -F'\t' '$3 == "E" { print $1 " " $2; exit }' "data/server/cache/subscriptions/${lk}_err_warn.tsv" 2>/dev/null)
    check $([ "${loc:-x}" = "Processed" ] && echo 0 || echo 1) "the lateok flow's newest File is '${loc:-absent}', expected Processed (the retry delivered)"
    check $([ -n "$lerr" ] && [ -n "$len" ] && [ "$lst" \< "$lerr" ] && [ "$lerr" \< "$len" ] && echo 0 || echo 1) "the lateok shape is not start < error < end: start '${lst:-?}', error '${lerr:-none}', end '${len:-empty}'"
    c=$(awk -F'\t' -v s="$lk" '$1 == s { print $3; exit }' "$B" 2>/dev/null)
    check $([ "${c:-x}" = "green" ] && echo 0 || echo 1) "the lateok flow is '${c:-absent}', expected green (a File ended OK after the error)"
    check $([ "$(grep -c "^$lk"$'\t' data/colour/_redflip.tsv 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok flow is in _redflip.tsv — the error was counted as after the last transfer"
    check $([ "$(grep -c "$lk" data/transfer/reports/_srvsubs-map.tsv 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok flow is in the server-failing set (_srvsubs-map.tsv)"
    check $([ "$(grep -c "^$lk"$'\t' data/server/reports/_kaput-evidence.tsv 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok flow is in the kaput evidence (_kaput-evidence.tsv) — the error was counted as after its last OK transfer"
    ls9=$(awk -F'\t' -v s="$lk" '$1 == s { print $2; exit }' "data/transfer/reports/details/subscriptions/_slugmap.tsv" 2>/dev/null)
    lp="docs/details/subscriptions/${ls9:-missing}.html"
    check $([ -n "$ls9" ] && [ -f "$lp" ] && echo 0 || echo 1) "the lateok flow has no detail page ('${ls9:-no slug}')"
    check $([ "$(grep -c 'AFTER LAST TRANSFER' "$lp" 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok page carries an AFTER LAST TRANSFER banner"
    # the "Last OK transfer" SECTION became the Features "Latest OK" ROW
    # (2026-09-16, user request): the row names the File and links its page
    # under files/, which failed.sh guarantees exists
    check $([ "$(grep -c '>Latest OK<' "$lp" 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "the lateok page has no Features 'Latest OK' row"
    check $([ "$(grep -c 'href="../../files/' "$lp" 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "the lateok page's Latest OK row does not link a files/ page"
    check $([ "$(grep -c 'Last OK transfer' "$lp" 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok page still carries the removed Last OK transfer section"
fi
n=$(awk -F'\t' '$4 != "" && ($24 == "" || $24 < $4 " " $5) { n++ } END { print n+0 }' "$F" 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "_files.tsv has $n dated File(s) with an empty end (col 24) or an end before the start"

# the ENVIRONMENT SWITCH (2026-09-12, user request): the sample checkout keeps
# its single "Sample" brand link — no Acceptance / Production pair anywhere —
# while the shipped runtime (topbar-data.js, report.js) carries the switch
# function with the four site URLs, so a runtime checkout renders the pair
tbd="docs/assets/topbar-data.js"
check $([ "$(grep -c 'envkey:"sample"' "$tbd" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js does not carry envkey:\"sample\""
# (the switch is topbar.js envLinks since 2026-09-30 — a baked
# AXWAY_ENVLINKS string in topbar-data.js before; the data file keeps the URLs)
check $([ "$(grep -c 'function envLinks' docs/assets/topbar.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar.js does not define the environment switch (envLinks)"
# from the file system only the current environment shows (2026-09-14): the switch carries the file: branch
check $([ "$(grep -c 'location.protocol === "file:"' docs/assets/topbar.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar.js: the environment switch lacks the file-system branch (only the current environment from file://)"
for u in 'http://localhost/runtime-acceptance/' 'http://localhost/runtime-production/' 'https://probable-adventure-l6y6k83.pages.github.io/' 'https://expert-adventure-9myme9m.pages.github.io/'; do
    check $([ "$(grep -c "$u" "$tbd" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js lacks the site URL $u"
done
check $([ "$(grep -c 'data-envto' docs/assets/topbar.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "topbar.js does not render the Acceptance / Production pair (data-envto)"
check $([ "$(grep -c 'env:"Sample"' "$tbd" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js does not carry env:\"Sample\" (the single Sample brand link)"
check $([ "$(grep -rl 'data-envto' docs --include=*.html 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && echo 0 || echo 1) "a sample page bakes the Acceptance / Production pair (data-envto)"

# the home page's Duration group ends on p99 (2026-09-13, user request):
# p50 · p75 · p90 · p95 · p99, five cells per day and in the Total row
hdr=$(grep -o '<th class="num"[^>]*>p[0-9]*</th>' docs/index.html 2>/dev/null | sed 's/<[^>]*>//g' | tr '\n' '|')
check $([ "$hdr" = "p50|p75|p90|p95|p99|" ] && echo 0 || echo 1) "the home Duration group headers are '$hdr', expected p50|p75|p90|p95|p99|"
check $([ "$(grep -c '<th class="gband" colspan="5" data-href="transfer/duration.html?axway_date=[0-9-]*\.\.[0-9-]*">Duration</th>' docs/index.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "the home Duration banner does not span 5 columns or does not link the Duration report"
# every cell of the Duration group opens transfer/duration.html (2026-09-14,
# user request): the five p-headers at the shown days' range
# (?axway_date=FROM..TO since 2026-09-29, the 14-day home; ?axway_date=all
# before), five cells per day row with ?axway_row=<that row's date>;
# report.js binds them and outranks the row link
nrows=$(awk '/<table class="index fit dayrows/ { p = 1 } p && /<tr>/ && /<td/ { n++ } p && /<\/table>/ { exit } END { print n + 0 }' docs/index.html 2>/dev/null)
ncells=$(grep -o '<td class="num[^"]*" data-href="transfer/duration.html?axway_\(row=[0-9-]*\|date=[0-9-]*\.\.[0-9-]*\)">' docs/index.html 2>/dev/null | wc -l | tr -d ' ')
nth=$(grep -o '<th class="num" data-href="transfer/duration.html?axway_date=[0-9-]*\.\.[0-9-]*">p[0-9]*</th>' docs/index.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${nth:-0}" = 5 ] && [ "${nrows:-0}" -gt 0 ] && [ "${ncells:-0}" -ge $((${nrows:-0} * 5)) ] && echo 0 || echo 1) "the home Duration group links: $nth p-headers, $ncells day cells for $nrows rows (expected 5 and >= 5 per row)"
bad=$(awk '/<table class="index fit dayrows/ { p = 1 } p && /<\/table>/ { exit } p && /<tr>/ && /<td/ { if (!match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) next; d = substr($0, RSTART, RLENGTH); c = $0; if (gsub("axway_row=" d "\"", "", c) != 5) bad++ } END { print bad + 0 }' docs/index.html 2>/dev/null)
check $([ "${bad:-1}" = 0 ] && echo 0 || echo 1) "${bad:-?} home day row(s) whose five Duration cells do not open their own date (?axway_row=<date>)"
check $([ "$(grep -c 'axway_date=all' docs/assets/report.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "report.js does not accept ?axway_date=all"
check $([ "$(grep -c 'function setupCellLinks' docs/assets/report.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "report.js does not define setupCellLinks"

# the Activity over Time tables carry ONE Files column — the delivered
# count — and no Error / OK pair (2026-09-13, user request): no green/red
# cells on the four activity pages, the Per day Files total = the OK count
# of the caches
for h in $(awk -F'\t' '$1 == "HEAD" { print $0 }' data/transfer/reports/activity.rpt 2>/dev/null | grep -c $'\tOK\t\|\tOK$'); do
    check $([ "$h" = 0 ] && echo 0 || echo 1) "activity.rpt still has $h table header(s) with an OK column"
done
check $([ ! -f docs/transfer/activity-per-day.html ] && echo 0 || echo 1) "docs/transfer/activity-per-day.html still published (its table = the Top view, 2026-09-29)"
n=$(grep -c 'class="num failed"\|class="num processed"\|numfailed\|numprocessed' docs/transfer/activity-per-week.html docs/transfer/activity-per-hour.html docs/transfer/activity-per-weekday.html 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n green/red (OK/Error) cells left on the four Activity over Time pages"

# the Patterns group tables carry ONE Files column — the delivered count —
# and no Error / OK (Delivered / Errored) pair (2026-09-13, user request):
# no green/red cells on the file-journey pages, the leg-count / journey /
# arrived-left Files totals = the caches' OK count
n=$(awk -F'\t' '$1 == "HEAD" && (/\tOK\t|\tOK$|\tError\t|\tError$|\tDelivered\t|\tErrored\t/) { n++ } END { print n + 0 }' data/transfer/reports/file-journey.rpt 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "file-journey.rpt still has $n table header(s) with an OK / Error / Delivered / Errored column"
n=$(grep -c 'class="num failed"\|class="num processed"' docs/transfer/file-journey*.html 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n green/red (OK/Error) cells left on the Patterns group pages"
want=$(awk -F'\t' '$4 != "" && $2 != "Failed" && $2 != "Expired" { n++ } END { print n + 0 }' "$F" 2>/dev/null)
for t in "Files by leg count" "Files by protocol journey"; do
    got=$(awk -F'\t' -v t="$t" '$1 == "TABLE" && $2 == t { p = 1 } p && $1 == "TOTAL" { v = $3; sub(/^@\{[^}]*\}/, "", v); print v + 0; exit }' data/transfer/reports/file-journey.rpt 2>/dev/null)
    check $([ "${got:-x}" = "${want:-y}" ] && echo 0 || echo 1) "file-journey '$t' Files total is '${got:-absent}', the caches hold ${want:-?} OK Files"
done
# (the Arrived / Left tab and the Last leg table went 2026-09-29, user request)

# the Protocol & Security group tables carry ONE Transfers column — the OK
# legs — and no Error / OK pair (2026-09-13, user request): no green/red
# cells on the protocol / security-params pages and their per-value pages,
# the By protocol Transfers total = the caches' Processed legs
n=$(awk -F'\t' '$1 == "HEAD" && (/\tOK\t|\tOK$|\tError\t|\tError$/) { n++ } END { print n + 0 }' data/transfer/reports/protocol.rpt data/transfer/reports/security-params.rpt data/transfer/reports/secparams/*.rpt 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "protocol / security-params rpts still have $n table header(s) with an OK / Error column"
n=$(grep -c 'class="num failed"\|class="num processed"' docs/transfer/protocol-*.html docs/transfer/security-params.html docs/transfer/secparams/*.html 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n green/red (OK/Error) cells left on the Protocol & Security group pages"
want=$(awk -F'\t' '{ s = $3; sub(/ Subtransmission$/, "", s); if (s == "Processed") n++ } END { print n + 0 }' "$T" 2>/dev/null)
got=$(awk -F'\t' '$1 == "TABLE" && $2 == "Protocol × direction" { p = 1 } p && $1 == "TOTAL" { v = $3; sub(/^@\{[^}]*\}/, "", v); print v + 0; exit }' data/transfer/reports/protocol.rpt 2>/dev/null)
check $([ "${got:-x}" = "${want:-y}" ] && echo 0 || echo 1) "protocol Protocol × direction Transfers total is '${got:-absent}', the caches hold ${want:-?} Processed legs"

# the Duration report holds BOTH per-day tables side by side (2026-09-13,
# user request): percentiles first (the home page reads it by title), then
# min / avg / median / max; the Min/Avg/Max sibling pages are gone and the
# button row keeps only the OK / All pair — for both scopes
for p in duration duration-all; do
    n=$(grep -c '<table' "docs/transfer/$p.html" 2>/dev/null)
    check $([ "${n:-0}" = 2 ] && echo 0 || echo 1) "transfer/$p.html has ${n:-0} table(s), expected the two side-by-side per-day tables"
    check $([ "$(grep -c '<h2[^>]*>Duration per day — percentiles' "docs/transfer/$p.html" 2>/dev/null)" = 1 ] && [ "$(grep -c '<h2[^>]*>Duration per day — min / avg / median / max' "docs/transfer/$p.html" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "transfer/$p.html lacks one of the two per-day table headings"
    check $([ "$(grep -c 'class="sxs"' "docs/transfer/$p.html" 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "transfer/$p.html does not lay its tables out side by side (.sxs)"
    n=$(grep -o 'class="tab[^"]*"[^>]*>[^<]*<' "docs/transfer/$p.html" 2>/dev/null | grep -c 'Delivered Files\|All Files')
    check $([ "${n:-0}" = 2 ] && [ "$(grep -c 'Min/Avg/Max\|>Percentage<' "docs/transfer/$p.html" 2>/dev/null)" = 0 ] && echo 0 || echo 1) "transfer/$p.html button row: ${n:-0} scope buttons, and the Percentage / Min/Avg/Max pair must be gone"
done
check $([ ! -e docs/transfer/duration-minmax.html ] && [ ! -e docs/transfer/duration-all-minmax.html ] && [ ! -e data/transfer/reports/duration-minmax.rpt ] && echo 0 || echo 1) "the Min/Avg/Max sibling pages or .rpts still exist"
dr=$(awk '/<table class="index fit dayrows/ { p = 1 } p && /<tr>/ && /<td/ { print; exit }' docs/index.html 2>/dev/null | grep -o 'data-href="transfer/duration.html?axway_row=[0-9-]*">[^<][^<]*<' | wc -l | tr -d ' ')
check $([ "${dr:-0}" -ge 5 ] && echo 0 || echo 1) "the home page's newest day carries ${dr:-0} filled Duration cells (the extractor must still find the percentiles table)"

# the DATA PERIOD in the top bar (2026-09-13, user request): "yyyy-mm-dd /
# yyyy-mm-dd", the transfer data's first and last day (day.rpt META
# first/last), second after the environment — in the bar data, and placed
# right after the brand by topbar.js
per=$(awk -F'\t' '$1 == "META" && ($2 == "first" || $2 == "last") { v[$2] = substr($3, 1, 10) } END { print v["first"] " / " v["last"] }' data/transfer/reports/day.rpt 2>/dev/null)
check $([ "$per" != " / " ] && [ "$(grep -c "period:\"$per\"" docs/assets/topbar-data.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js does not carry period:\"$per\""
n=$(awk '/brandHtml \+$/ && !b { b = NR } /M\.period \? .<span class="period"/ && !p { p = NR } /<span class="entgroup">/ && !g { g = NR } END { print (b && p == b + 1 && g > p) ? 1 : 0 }' docs/assets/topbar.js 2>/dev/null)
check $([ "${n:-0}" = 1 ] && echo 0 || echo 1) "topbar.js does not place the period right after the brand, before the Entities cluster"

# the fixed duration axis of the Overview / day-page Duration heroes
# (2026-09-12, user request): the shipped slotchart.js carries the 19-tick
# scale verbatim, 1 s .. >= 48 h
check $([ "$(grep -c '"1 s", "2 s", "3 s", "5 s", "7 s", "10 s", "15 s", "20 s", "25 s", "30 s", "45 s", "1 m", "5 m", "30 m", "1 h", "5 h", "10 h", "24 h", ">= 48 h"' docs/assets/slotchart.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "slotchart.js does not carry the 19-tick duration scale"

# the Advanced Routing errors report (2026-09-28: the merge of the 2026-09-12
# Could not send file / Publish to account failed / Post client action error
# pages): one table, Date & time · Error · Code · Account or subscription ·
# File, newest first, at most 1000 rows and 10 per error and entity. The
# planted cnsend flow (estate.awk UC1_CD_IDM_VANDELAY) closes every failed
# burst with an AR0074 line, UC1_ODV_PUBLISH_PIEDPIPER (reason=publishfail)
# logs ARPA0001, and UC3_CD_NOTARY_BLUTH (pcaerr tag) ARRC0009 — listed per
# ACCOUNT, the first bracket before the @.
R="data/server/reports/routing-errors.rpt"
n=$(rpt_rows "$R")
check $([ "$n" -gt 0 ] && echo 0 || echo 1) "routing-errors.rpt has 0 rows"
h=$(awk -F'\t' '$1 == "HEAD" { print; exit }' "$R" 2>/dev/null)
check $([ "$h" = $'HEAD\tDate & time\tError\tCode\tAccount or subscription\tFile' ] && echo 0 || echo 1) "routing-errors.rpt HEAD is '$h', expected Date & time|Error|Code|Account or subscription|File"
arerr_rows() {   # $1 error label  $2 code  $3 entity -> the rows of that error for that entity
    awk -F'\t' -v E="$1" -v C="$2" -v N="$3" '$1 == "ROW" && $3 == E && $4 == C { s = $5; sub(/^@\{[^}]*\}/, "", s); if (s == N) n++ } END { print n + 0 }' "$R" 2>/dev/null
}
if [ "$(exp cnsend)" -gt 0 ]; then
    n=$(arerr_rows "Could not send file" AR0074 UC1_CD_IDM_VANDELAY)
    check $([ "${n:-0}" -gt 0 ] && [ "${n:-0}" -le 10 ] && echo 0 || echo 1) "routing-errors.rpt has ${n:-0} Could not send file row(s) for the planted flow, expected 1-10"
fi
n=$(arerr_rows "Publish to account failed" ARPA0001 UC1_ODV_PUBLISH_PIEDPIPER)
check $([ "${n:-0}" -gt 0 ] && [ "${n:-0}" -le 10 ] && echo 0 || echo 1) "routing-errors.rpt has ${n:-0} Publish to account failed row(s) for the planted flow, expected 1-10"
if [ "$(exp pcaerr)" -gt 0 ]; then
    # the planted flow's ACCOUNT, as the configuration spells it
    a=$(awk -F'\t' '$1 == "UC3_CD_NOTARY_BLUTH" { print $2; exit }' data/flow-manager/xref/_subscriptions-accounts.tsv 2>/dev/null)
    check $([ -n "$a" ] && echo 0 || echo 1) "UC3_CD_NOTARY_BLUTH has no account in _subscriptions-accounts.tsv"
    n=$(arerr_rows "Post client action error" ARRC0009 "$a")
    check $([ "${n:-0}" -gt 0 ] && [ "${n:-0}" -le 10 ] && echo 0 || echo 1) "routing-errors.rpt has ${n:-0} Post client action error row(s) for the planted account ${a:-?}, expected 1-10"
fi
n=$(awk -F'\t' '$1 == "ROW" { s = $3 "|" $5; sub(/@\{[^}]*\}/, "", s); if (++c[s] > 10) over++ } END { print over + 0 }' "$R" 2>/dev/null)
check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "routing-errors.rpt: ${n:-?} row(s) beyond the 10-per-error-and-entity cap"
check $([ "$(rpt_rows "$R")" -le 1000 ] && echo 0 || echo 1) "routing-errors.rpt has more than 1000 rows"
n=$(awk -F'\t' '$1 == "ROW" { if (p != "" && $2 > p) bad++; p = $2 } END { print bad + 0 }' "$R" 2>/dev/null)
check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "routing-errors.rpt is not newest-first (${n:-?} row(s) out of order)"
check $([ -f docs/server/routing-errors.html ] && echo 0 || echo 1) "docs/server/routing-errors.html is missing"
check $([ ! -f docs/server/could-not-send.html ] && [ ! -f docs/server/publish-failed.html ] && [ ! -f docs/server/post-client-action.html ] && echo 0 || echo 1) "a merged AR-line list page (could-not-send / publish-failed / post-client-action) is back"

# the EventQueue data (2026-09-14, user request): the server-log lines starting "[Pesit Default] Unable to
# submit event AgentEvent" (the sample plants bursts) — the cache and the 30-minute sidecar agree (the
# per-day .rpt went 2026-09-29: no reader), and the main dashboard and the day pages carry the EventQueue view
EQ="data/server/reports/event-queue-slots.tsv"
wn=$(awk -F'\t' 'index($5, "[Pesit Default] Unable to submit event AgentEvent") == 1 { n++ } END { print n + 0 }' data/server/cache/_parse.tsv 2>/dev/null)
sn=$(awk -F'\t' '{ n += $3 } END { print n + 0 }' "$EQ" 2>/dev/null)
check $([ "${wn:-0}" -gt 0 ] && [ "$sn" = "$wn" ] && [ ! -e data/server/reports/event-queue.rpt ] && echo 0 || echo 1) "event-queue: cache ${wn:-?} line(s), sidecar ${sn:-?} (and no event-queue.rpt)"
# ... but no PAGE since 2026-09-27 (the Operations & Capacity group was removed; the .rpt and
# the sidecar stay as the chart views' data), and neither is the group's other pages
check $([ ! -f docs/server/event-queue.html ] && [ ! -f docs/server/platform-health.html ] && [ ! -f docs/server/capacity.html ] && echo 0 || echo 1) "a removed Operations & Capacity page (event-queue / platform-health / capacity) is back"
check $(grep -q $'^CARDALT\tEventQueue\t' data/dashboards/reports/overview.rpt 2>/dev/null && echo 0 || echo 1) "the overview dashboard carries no EventQueue chart view"
d=$(awk -F'\t' '{ print $1; exit }' "$EQ" 2>/dev/null)
check $(grep -q $'^CARDALT\tEventQueue\t' "data/day/reports/${d:-none}.rpt" 2>/dev/null && echo 0 || echo 1) "day page ${d:-?} carries no EventQueue chart view"

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
v=$(awk -F'\t' -v S="$s" 'S != "" && $1 == S { print $2; exit }' data/colour/_sessvote.tsv 2>/dev/null)
check $([ -n "$s" ] && [ "$v" = "UC3_SI_TELEMETRY_STARK" ] && echo 0 || echo 1) "the STARK host ring's authentication failure (session '${s:-none}') votes '${v:-nothing}', expected UC3_SI_TELEMETRY_STARK"
c=$(awk -F'\t' '$1 == "UC1_IT_LEADS_STARK" { print $3; exit }' data/flow-manager/base/_subscriptions.tsv 2>/dev/null)
check $([ "$c" = green ] && echo 0 || echo 1) "UC1_IT_LEADS_STARK is '${c:-absent}', expected green — the shared host's authentication failure belongs to the UC3 poll flow"

# the NON-UC-NAMED hybrid flows must come out attributed to their real site
# (the reverse profile fallback) — never Unknown — and every planted one is a
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
              "Pull via FTPS failed" "Delete remote file failed" "IO error" "Read timed out" "Unknown error" \
              "Stream read/write error"; do
    n=$(grep -l -- "$reason" data/transfer/reports/failed*.rpt data/transfer/reports/errors/*.rpt 2>/dev/null | wc -l | tr -d ' ')
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "reason \"$reason\" appears in no failed/error report"
done
# the Error reasons pages (2026-09-14, user request): ONE main page counting every File in error — its
# Total is the Failed files row count, no selector row, no retired view page — and per reason a drill
# page with EVERY such File: Subscription / Date/time / CoreId / Filename, tinted rows, the date fields
frt() { awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "ROW" { c = $3; sub(/^@\{[^}]*\}/, "", c); n += c + 0 } END { print n + 0 }' "$1" 2>/dev/null; }
n=$(frt data/analyses/reports/failing-reasons.rpt); en=$(rpt_rows data/transfer/reports/failed-files.rpt)
check $([ "${n:-x}" = "${en:-y}" ] && [ "${en:-0}" -gt 0 ] && echo 0 || echo 1) "failing-reasons counts ${n:-?}, failed-files.rpt lists ${en:-?}"
t=$(grep -m1 $'^TABLE\t' data/analyses/reports/failing-reasons.rpt 2>/dev/null)
check $(printf '%s' "$t" | grep -q 'sort=2:-1' && ! printf '%s' "$t" | grep -q 'totaltop' && echo 0 || echo 1) "failing-reasons main table lacks the Last-descending default sort or still pins the total on top (TABLE: $t)"
# 2026-09-15 (user request): no row for a reason with nothing counted (the
# Count cell carries its @{href=…,class=num} prefix — strip it, then an empty
# or zero count is the failure)
z=$(awk -F'\t' '$1 == "ROW" { c = $3; sub(/^@\{[^}]*\}/, "", c); if (c == "" || c + 0 == 0) n++ } END { print n + 0 }' data/analyses/reports/failing-reasons.rpt 2>/dev/null)
check $([ "${z:-1}" = 0 ] && echo 0 || echo 1) "failing-reasons main table still lists ${z:-?} reason(s) with no count"
# the per-reason drill pages went 2026-09-29: a reason row opens the Failed
# files page searched on it (a quoted, whole-cell search)
n=$(ls data/analyses/reports/failing-reasons-*.rpt docs/analyses/failing-reasons-*.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "$n retired Error reason drill file(s) still produced"
n=$(awk -F'\t' '$1 == "ROW" && $2 !~ /failed-files\.html/ { n++ } END { print n + 0 }' data/analyses/reports/failing-reasons.rpt 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n Error reasons row(s) not linking the Failed files page"
n=$(ls docs/analyses 2>/dev/null | awk '/^failing-reasons-(history|errors)/ { n++ } END { print n + 0 }')
check $([ "$n" = 0 ] && echo 0 || echo 1) "$n retired Error reasons view page(s) still published"
n=$(grep -c 'tabs undertabs' docs/analyses/failing-reasons.html 2>/dev/null || true)
check $([ "${n:-0}" = 0 ] && [ -f docs/analyses/failing-reasons.html ] && echo 0 || echo 1) "analyses/failing-reasons.html missing or still carries a selector row"

# the UC4 to UC2 report (2026-09-14, user request): an independent recount of the pairs — a UC2 File with
# the same file name, login and post-prefix subscription name as a UC4 File that started earlier
FB="data/transfer/reports/uc4-to-uc2.rpt"
wn=$(LC_ALL=C awk -F'\t' '$11 != "" && $4 != "" && $12 ~ /^[Uu][Cc][24]/ { u = toupper(substr($12, 1, 3)); k = $11 SUBSEP toupper($14) SUBSEP toupper(substr($12, 4))
        if (u == "UC4") { if (!(k in M4) || $6 < M4[k]) M4[k] = $6 } else { n2++; K2[n2] = k; T2[n2] = $6 } }
    END { for (i = 1; i <= n2; i++) if ((K2[i] in M4) && M4[K2[i]] < T2[i]) n++; print n + 0 }' data/transfer/cache/_files.tsv 2>/dev/null)
fn=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 2 && $1 == "ROW" { n++ } END { print n + 0 }' "$FB" 2>/dev/null)
check $([ "${wn:-0}" -gt 0 ] && [ "$fn" = "$wn" ] && echo 0 || echo 1) "uc4-to-uc2: the Files table lists ${fn:-?} pair(s), the recount finds ${wn:-?}"
h=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 2 && $1 == "HEAD" { print; exit }' "$FB" 2>/dev/null)
check $([ "$h" = $'HEAD\tFile\tLogin\tUC4 subscription\tUC4 date/time\tUC2 subscription\tUC2 date/time\tGap\tUC4 CoreId\tUC2 CoreId' ] && echo 0 || echo 1) "uc4-to-uc2 Files HEAD is '$h'"
check $([ -f docs/transfer/file-in-file-out-uc4-to-uc2.html ] && [ -f docs/help/uc4-to-uc2.html ] && [ ! -f docs/transfer/uc4-to-uc2.html ] && echo 0 || echo 1) "the UC4 to UC2 tab of File in - File out (or its help page) is missing, or the retired uc4-to-uc2.html page is still published"
# ... and its gaps are real: none negative, and not every one "0 s" (the 2026-09-14 OFMT precision bug)
read -r gneg gnz <<< "$(awk -F'\t' '/^TABLE\t/ { t++ } t == 2 && $1 == "ROW" { if ($8 ~ /^-/) neg++; if ($8 != "0 s") nz++ } END { print neg + 0, nz + 0 }' "$FB" 2>/dev/null)"
check $([ "${gneg:-1}" = 0 ] && [ "${gnz:-0}" -gt 0 ] && echo 0 || echo 1) "uc4-to-uc2 gaps: ${gneg:-?} negative, ${gnz:-?} non-zero"

# the Inbound and Outbound same Protocol report (2026-09-14, user request): an independent recount — a File
# whose earliest Inbound leg and latest Outbound leg share one protocol, UC5-UC8 left out — the planted
# samecollect flow present, no UC5-UC8 row, the page and its help published
SP="data/transfer/reports/same-protocol.rpt"
wn=$(LC_ALL=C awk -F'\t' 'FNR == 1 { f++ } f == 1 { if ($1 != "" && $2 != "") U[toupper($1)] = toupper($2); next }
    f == 2 { c = $1; if ($2 == "Inbound") { if (!(c in IK) || $13 < IK[c]) { IK[c] = $13; IP[c] = $10 } } else if ($2 == "Outbound") { if (!(c in OK) || $13 > OK[c]) { OK[c] = $13; OP[c] = $10 } } next }
    { c = $1; if (!(c in IP) || !(c in OP) || IP[c] != OP[c] || IP[c] == "") next; s = toupper($12); u = ""
      if (match(s, /^UC[0-9]+/)) u = substr(s, 1, RLENGTH); else if (s in U) u = U[s]
      if (u !~ /^UC[5-8]$/) n++ } END { print n + 0 }' data/flow-manager/xref/_subscriptions-ucderived.tsv data/transfer/cache/_transfers.tsv data/transfer/cache/_files.tsv 2>/dev/null)
fn=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 2 && $1 == "ROW" { n++ } END { print n + 0 }' "$SP" 2>/dev/null)
check $([ "$fn" = "$wn" ] && { [ "$(exp samecollect)" -eq 0 ] || [ "${fn:-0}" -gt 0 ]; } && echo 0 || echo 1) "same-protocol: the Files table lists ${fn:-?} File(s), the recount finds ${wn:-?} (planted flows: $(exp samecollect))"
n=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 2 && $1 == "ROW" && $2 == "UC4_AIM_LAKE_PIEDPIPER" { n++ } END { print n + 0 }' "$SP" 2>/dev/null)
check $([ "$(exp samecollect)" -eq 0 ] || [ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "same-protocol lists no File of the planted UC4_AIM_LAKE_PIEDPIPER flow"
n=$(awk -F'\t' '$1 == "ROW" && toupper($2) ~ /^UC[5-8]/ { n++ } END { print n + 0 }' "$SP" 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "same-protocol lists ${n:-?} UC5-UC8 row(s)"
h=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 2 && $1 == "HEAD" { print; exit }' "$SP" 2>/dev/null)
check $([ "$h" = $'HEAD\tSubscription\tDate/time\tProtocol\tFirst inbound\tLast outbound\tLegs\tOutcome\tCoreId\tFilename' ] && echo 0 || echo 1) "same-protocol Files HEAD is '$h'"
check $([ -f docs/transfer/same-protocol.html ] && [ -f docs/help/same-protocol.html ] && echo 0 || echo 1) "docs/transfer/same-protocol.html or its help page is missing"

# the subscription pages' Activity per day Error cells (2026-09-15, user request): every nonzero Error cell
# opens transfer/failed-files.html for that day and that subscription (the name quoted: a whole-cell search)
SD="data/transfer/reports/details/subscriptions/uc1-fin-billing-globex.rpt"
read -r nz nl <<< "$(awk -F'\t' '$1 == "TABLE" { t = ($2 == "Activity per day") } t && $1 == "ROW" { v = $4; l = (index(v, "@{href=../../transfer/failed-files.html?axway_date=" $2 "&axway_search=\"UC1_FIN_BILLING_GLOBEX\"}") == 1); sub(/^@\{[^}]*\}/, "", v); if (v + 0 > 0) nz++; if (l) nl++ } END { print nz + 0, nl + 0 }' "$SD" 2>/dev/null)"
check $([ "${nz:-0}" -gt 0 ] && [ "$nz" = "$nl" ] && echo 0 || echo 1) "UC1_FIN_BILLING_GLOBEX Activity per day: ${nz:-?} nonzero Error cell(s), ${nl:-?} opening failed-files for their day and subscription"
check $([ "$(grep -c 'href="transfer/failed-files.html?axway_date=[0-9-]*&amp;axway_search="' docs/index.html 2>/dev/null || true)" -gt 0 ] && echo 0 || echo 1) "home Error cells do not clear the remembered failed-files search (&axway_search=)"

# the detail pages' Subscriptions table (2026-09-15, user request): every nonzero Error cell opens
# transfer/failed-files.html at the full range for that row's subscription (quoted: a whole-cell search)
read -r nz nl <<< "$(awk -F'\t' 'FNR == 1 { t = 0 } $1 == "TABLE" { t = ($2 == "Subscriptions") }
    t && $1 == "HEAD" { ec = 0; ic = 0; oc = 0; for (i = 2; i <= NF; i++) { if ($i == "Error") ec = i; if ($i == "In - Error") ic = i; if ($i == "Out - Error") oc = i } }
    t && $1 == "ROW" { nm = $2; sub(/^@\{[^}]*\}/, "", nm); n = split((ec ? ec : ic " " oc), C, " ")
      for (j = 1; j <= n; j++) { if (C[j] + 0 == 0) continue; v = $(C[j]); l = (index(v, "@{href=../../transfer/failed-files.html?axway_date=all&axway_search=\"" nm "\"}") == 1); sub(/^@\{[^}]*\}/, "", v); if (v + 0 > 0) { nz++; if (l) nl++ } } }
    END { print nz + 0, nl + 0 }' data/transfer/reports/details/*/*.rpt 2>/dev/null)"
check $([ "${nz:-0}" -gt 0 ] && [ "$nz" = "$nl" ] && echo 0 || echo 1) "detail Subscriptions tables: ${nz:-?} nonzero Error cell(s), ${nl:-?} opening failed-files for their own subscription"

# the Entities subscription pages (2026-09-15, user request): the Files group Error count opens Failed files
# for that subscription and the active dates — its drill is gone there, kept on the other entity pages
check $([ "$(grep -o 'data-drill-cols="[^"]*"' docs/transfer/entities/subscription-all.html 2>/dev/null | grep -c 'ferr:')" = 0 ] && [ "$(grep -o 'data-drill-cols="[^"]*"' docs/transfer/entities/account-all.html 2>/dev/null | grep -c 'ferr:3:')" = 1 ] && echo 0 || echo 1) "Entities: the subscription pages still drill Files Error, or the account pages lost that drill"
check $([ "$(grep -c 'function setupEntityErrorLinks' docs/assets/report.js 2>/dev/null)" = 1 ] && [ "$(grep -c 'setupEntityErrorLinks();' docs/assets/report.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "report.js does not define and run setupEntityErrorLinks"

# ONE Reports pulldown (2026-09-29, user request — the Transfer reports /
# Server reports / Analyses / Goodies four went): topbar-data.js carries the
# one `reports` menu (Start page + one line per group), the three area start
# pages are gone, docs/reports/index.html replaces them
t=docs/assets/topbar-data.js
check $(grep -q 'reports:"' "$t" 2>/dev/null && ! grep -qE '(transfer|server|analyses|goodies):"' "$t" && echo 0 || echo 1) "topbar-data.js lacks the reports menu or still carries a transfer / server / analyses / goodies menu"
n=$(grep -oE 'reports:"([^"\\]|\\.)*"' "$t" 2>/dev/null | grep -o '<a ' | wc -l | tr -d ' ')
# (2026-09-29, user request: Server log errors folded into Failures — 13
# groups — and Entities left off the menu, the top bar's own Entities link
# opens it; Failures renamed Errors the same day and taken off the menu too,
# a top-bar link of its own; later that day the Cleanup group went and
# Overview became a top-bar link too)
check $([ "${n:-0}" = 10 ] && echo 0 || echo 1) "the Reports menu has ${n:-0} line(s), expected 10 (Start page + 9 groups; Overview, Entities and Errors not listed)"
check $(grep -oE 'reports:"([^"\\]|\\.)*"' "$t" 2>/dev/null | grep -q 'transfer/topview.html' && echo 1 || echo 0) "the Reports menu still lists the Overview group"
check $(grep -q 'overview:"transfer/topview.html"' "$t" 2>/dev/null && echo 0 || echo 1) "topbar-data.js lacks overview:\"transfer/topview.html\" (the runtime bar's Overview link)"
check $(grep -oE 'reports:"([^"\\]|\\.)*"' "$t" 2>/dev/null | grep -q 'transfer/entities/' && echo 1 || echo 0) "the Reports menu still lists the Entities group"
check $(grep -q '>Server log errors<' docs/reports/index.html 2>/dev/null && echo 1 || echo 0) "reports/index.html still has a Server log errors group (folded into Failures)"
check $([ -f docs/reports/index.html ] && [ ! -f docs/transfer/index.html ] && [ ! -f docs/server/index.html ] && [ ! -f docs/analyses/index.html ] && echo 0 || echo 1) "docs/reports/index.html missing, or a retired area start page (transfer / server / analyses index.html) still published"
# the FIRST ROW links across directories: the Overview group joins both Top
# views, and every group member page carries exactly one group tag
check $(grep -q '<a class="tab" href="../server/topview.html">Server top view</a>' docs/transfer/topview.html 2>/dev/null && grep -q '<a class="tab" href="../transfer/topview.html">Transfer top view</a>' docs/server/topview.html 2>/dev/null && echo 0 || echo 1) "the Overview first row does not join transfer/topview.html and server/topview.html"
check $(grep -q '<a class="tab" href="../server/ssh-security.html">SSH security</a>' docs/transfer/av-scan-*.html 2>/dev/null; r1=$?; grep -q 'href="../transfer/protocol-' docs/server/ssh-security*.html 2>/dev/null; r2=$?; [ "$r1" = 0 ] && [ "$r2" = 0 ] && echo 0 || echo 1) "the Protocols & security first row does not join the transfer protocol pages and server SSH security"
bad=0; for f in docs/transfer/duration.html docs/transfer/duration-all.html docs/transfer/duration-longest.html docs/analyses/failed.html docs/analyses/failed-sub-all.html docs/analyses/xref/cross-account-subscriptions.html docs/transfer/entities/subscription-all.html docs/transfer/waiting.html; do
    [ "$(grep -o 'class="grouptag"' "$f" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] || { bad=$((bad + 1)); echo "  no single group tag: $f" >&2; }
done
check $([ "$bad" = 0 ] && echo 0 || echo 1) "$bad report page(s) without exactly one group tag"
check $(grep -q '<span class="tab active">Longest Files</span>' docs/transfer/duration-longest.html 2>/dev/null && grep -q '<span class="tab active">Duration</span>' docs/transfer/duration-all.html 2>/dev/null && echo 0 || echo 1) "the longest-stem rule: duration-longest.html must mark Longest Files, duration-all.html Duration"

# every detail page (2026-09-15, user request): a Features table whose FIRST row is the entity itself, Item = the type label and Value = the name its TITLE ends with
r=$(awk -F'\t' '
    function done_file() { if (fname != "") { np++; if (!ok) { bad++; if (ex == "") ex = fname } } }
    FNR == 1 { done_file(); fname = FILENAME; ok = 0; t = 0; got = 0; title = "" }
    $1 == "TITLE" { title = $2 }
    $1 == "TABLE" { t = ($2 == "Features") }
    t && $1 == "ROW" && !got { got = 1; s = $2 ": " $3; if (length(title) >= length(s) && substr(title, length(title) - length(s) + 1) == s) ok = 1 }
    END { done_file(); print np + 0, bad + 0, ex }' data/transfer/reports/details/{accounts,applications,bl,domains,hosts,logicals,logins,partners,subscriptions}/*.rpt 2>/dev/null)
read -r np bad ex <<< "$r"
check $([ "${np:-0}" -gt 0 ] && [ "${bad:-1}" = 0 ] && echo 0 || echo 1) "detail pages: ${bad:-?} of ${np:-?} lack a Features table led by the entity itself (first: ${ex:-?})"

# analyses/subscriptions.html (2026-09-15, user request): the skipped subscriptions listed with n/a counts and Color white, a Color word on every row, the newest failed-files reason per subscription, Active CFT on every SWIFT name
r=$(awk -F'\t' '
    function strip(s) { gsub(/<[^>]*>/, "", s); gsub(/&quot;/, "\"", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&amp;/, "\\&", s); return s }
    FILENAME ~ /_skipped\.tsv$/ { if ($1 == "Subscription") SK[toupper($2)] = 1; next }
    FILENAME ~ /failed-files\.rpt$/ { if ($1 == "ROW") { u = toupper($2); if (!(u in T) || $3 > T[u]) { T[u] = $3; x = $4; if (index(x, "@{") == 1) x = substr(x, index(x, "}") + 1); R[u] = x } } next }
    index($0, "<tr") == 1 && index($0, "class=\"act\"") > 0 {
        n = split($0, P, "</td>"); nm = toupper(strip(P[1])); col = ""; er = ""; act = ""; na = 0
        for (i = 1; i <= n; i++) {
            if (index(P[i], "class=\"rescol\"")) col = strip(P[i])
            if (index(P[i], "ereason\"")) er = strip(P[i])
            if (index(P[i], "class=\"act\"")) act = strip(P[i])
            if (index(P[i], "class=\"num na\"")) na++
        }
        rows++
        if (col !~ /^(green|red|orange|white)$/) badcol++
        if (nm in SK) { sk++; if (na != 9 || col != "white") badsk++ }
        else if (na != 0) badsk++
        want = (nm in R) ? R[nm] : ""
        if (er != want) { bader++; if (ex == "") ex = nm }
        if (er != "") withr++
        if (index(nm, "SWIFT")) { sw++; if (act != "CFT") badsw++ }
    }
    END { nsk = 0; for (k in SK) nsk++; print rows + 0, nsk, sk + 0, badsk + 0, badcol + 0, withr + 0, bader + 0, sw + 0, badsw + 0, (ex == "" ? "-" : ex) }' \
    data/flow-manager/filtered/_skipped.tsv data/transfer/reports/failed-files.rpt docs/analyses/subscriptions.html 2>/dev/null)
read -r srows snsk ssk sbadsk sbadcol swithr sbader ssw sbadsw sex <<< "$r"
check $([ "${srows:-0}" -gt 0 ] && [ "${snsk:-0}" -gt 0 ] && [ "${ssk:-0}" = "${snsk:-x}" ] && [ "${sbadsk:-1}" = 0 ] && echo 0 || echo 1) "analyses/subscriptions.html: ${ssk:-?} of ${snsk:-?} skipped subscription(s) listed, ${sbadsk:-?} row(s) with wrong n/a counts or colour"
check $([ "${sbadcol:-1}" = 0 ] && echo 0 || echo 1) "analyses/subscriptions.html: ${sbadcol:-?} row(s) without a green/red/orange/white Color"
check $([ "${swithr:-0}" -gt 0 ] && [ "${sbader:-1}" = 0 ] && echo 0 || echo 1) "analyses/subscriptions.html: ${sbader:-?} Error reason cell(s) differ from the newest failed-files reason (first: ${sex:-?}), ${swithr:-0} filled"
check $([ "${ssw:-0}" -gt 0 ] && [ "${sbadsw:-1}" = 0 ] && echo 0 || echo 1) "analyses/subscriptions.html: ${sbadsw:-?} of ${ssw:-0} SWIFT subscription(s) without Active CFT"

# analyses/subscriptions.html Direction (2026-09-15, user request): connection / movement, equal to the detail page title prefix lowercased, blank on the skipped rows
r=$(awk -F'\t' '
    function strip(s) { gsub(/<[^>]*>/, "", s); gsub(/&amp;/, "\\&", s); return s }
    FILENAME ~ /\.rpt$/ { if ($1 == "TITLE") { t = $2; nm = t; sub(/^.*Subscription: /, "", nm); p = ""; if (match(t, /^[A-Z?]+\/[A-Z?]+: /)) p = tolower(substr(t, 1, RLENGTH - 2)); W[toupper(nm)] = p; nextfile } next }
    index($0, "<tr") == 1 && index($0, "class=\"dir\"") > 0 {
        n = split($0, P, "</td>"); nm = toupper(strip(P[1])); d = "x"
        for (i = 1; i <= n; i++) if (index(P[i], "class=\"dir\"")) d = strip(P[i])
        if (index($0, "data-skipped")) { if (d != "") bad++; next }
        if (nm in W) { cmp++; if (d != W[nm]) { bad++; if (ex == "") ex = nm " page=" d " title=" W[nm] } }
    }
    END { print cmp + 0, bad + 0, (ex == "" ? "-" : ex) }' data/transfer/reports/details/subscriptions/*.rpt docs/analyses/subscriptions.html 2>/dev/null)
read -r dcmp dbad dex <<< "$r"
check $([ "${dcmp:-0}" -gt 0 ] && [ "${dbad:-1}" = 0 ] && echo 0 || echo 1) "analyses/subscriptions.html Direction: ${dbad:-?} of ${dcmp:-?} row(s) differ from the detail title prefix (first: ${dex:-?})"

# the fewer-server-reports round (2026-09-28, user request): the duplicate tab
# pages are gone — Errors Per day (= the Top view), By hour / By weekday (the
# heatmap marginals, now its Errors / Warnings / Total columns and Total row),
# the three ssh-key-auth tabs, Whitelist usage, the empty-by-construction Test
# outcomes and the Site failures page (= the Per flow connection rows)
gone=""
for p in errors-per-day errors-by-hour errors-by-weekday logons-key-mismatches logons-lockouts logons-outbound-key-failures connections-whitelist-usage connections-test-outcomes site-failures; do
    [ -f "docs/server/$p.html" ] && gone="$gone $p"
done
check $([ -z "$gone" ] && echo 0 || echo 1) "removed server page(s) are back:${gone:-}"
# ... and the lockouts the Lockouts tab listed are in the Incoming Locked
# column: its sum = every "is locked" + "locked due to too many failed login"
# line of the cache (the sample plants the lockouts)
wl=$(awk -F'\t' 'index($5, "[Ssh Default] User ") && (index($5, "is locked") || index($5, "locked due to too many failed login")) { n++ } END { print n + 0 }' data/server/cache/_parse.tsv 2>/dev/null)
rl=$(awk -F'\t' '$1 == "TABLE" { t++ } t == 1 && $1 == "HEAD" { for (i = 2; i <= NF; i++) if ($i == "Locked") c = i } t == 1 && $1 == "ROW" && c { v = $c; sub(/^@\{[^}]*\}/, "", v); n += v } END { print n + 0 }' data/server/reports/logon.rpt 2>/dev/null)
check $([ "${wl:-0}" -gt 0 ] && [ "$rl" = "$wl" ] && echo 0 || echo 1) "logon.rpt Incoming Locked sums to ${rl:-?}, the cache holds ${wl:-?} lock line(s)"
# the Errors heatmap Total column (field 12: ROW, Hour, 7 weekdays, Errors,
# Warnings, Total) sums to every Error + Warning line with a date and time
hm=$(awk -F'\t' '$1 == "TABLE" { h = ($2 == "Hour × weekday heatmap") } h && $1 == "ROW" { v = $12; sub(/^@\{[^}]*\}/, "", v); n += v } END { print n + 0 }' data/server/reports/errors.rpt 2>/dev/null)
ew=$(awk -F'\t' '($3 == "E" || $3 == "W") && $1 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 ~ /^[0-9][0-9]:/ { n++ } END { print n + 0 }' data/server/cache/_parse.tsv 2>/dev/null)
check $([ "${ew:-0}" -gt 0 ] && [ "$hm" = "$ew" ] && echo 0 || echo 1) "errors.rpt heatmap Total column sums to ${hm:-?}, the cache holds ${ew:-?} Error/Warning line(s)"

# the 2026-09-29 consolidation ("too many reports"): the retired pages stay
# gone, and their content rides the page that absorbed it
for f in transfer/expected-arrival.html transfer/entity-coverage-once-accounts.html transfer/entity-coverage-ok-accounts.html \
         transfer/entity-coverage-diff-accounts.html transfer/episodes-open-incidents.html analyses/accounts-in-boxes.html \
         analyses/partner-lifecycle.html analyses/use-case-patterns.html latest/search.html; do
    check $([ ! -f "docs/$f" ] && echo 0 || echo 1) "docs/$f still published (retired 2026-09-29)"
done
check $([ ! -d "docs/use-cases" ] && [ ! -d "docs/transfers" ] && echo 0 || echo 1) "a retired page directory (use-cases, transfers) is still published"
# brought back the same day (2026-09-29, user request): Month stats (18 pages,
# Activity & volume group) and Missing entities (five tabs, Coverage group)
n=$(ls docs/transfer/month-stats/*.html 2>/dev/null | wc -l | tr -d " ")
check $([ "${n:-0}" = 18 ] && echo 0 || echo 1) "docs/transfer/month-stats holds ${n:-0} page(s), expected the 18 Month stats pages"
check $(grep -q "grouptag\">&larr; Activity &amp; volume" docs/transfer/month-stats/previous-bl.html 2>/dev/null && echo 0 || echo 1) "transfer/month-stats/previous-bl.html lacks the Activity & volume group tag"
n=$(ls docs/server/missing-entities-*.html 2>/dev/null | wc -l | tr -d " ")
check $([ "${n:-0}" = 5 ] && echo 0 || echo 1) "docs/server holds ${n:-0} Missing entities tab page(s), expected 5"
check $(grep -q "grouptag\">&larr; Coverage" docs/server/missing-entities-subscriptions.html 2>/dev/null && echo 0 || echo 1) "server/missing-entities-subscriptions.html lacks the Coverage group tag"
check $(grep -q "class=\"dlicon\" href=\"../details/subscriptions/" docs/server/missing-entities-subscriptions.html 2>/dev/null && echo 0 || echo 1) "server/missing-entities-subscriptions.html: no detail-page icon next to a missing subscription"
# Trends, Route throughput and Punctuality went 2026-09-29 (user request):
# no page, no help page, no .rpt; punctuality-src.rpt stays (pageless — the
# Polling pages' file-arrival slot)
n=$(ls docs/transfer/trends*.html docs/transfer/punctuality*.html docs/transfer/route-throughput*.html docs/help/trends.html docs/help/punctuality.html docs/help/route-throughput.html docs/help/expected-arrival.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "$n Trends / Punctuality / Route throughput page(s) still published"
n=0; for r in trend duration-trend trends expected-arrival punctuality route-throughput; do [ -f "data/transfer/reports/$r.rpt" ] && n=$((n + 1)); done
check $([ "$n" = 0 ] && echo 0 || echo 1) "$n removed Trends / Punctuality / Route throughput .rpt file(s) still written"
check $([ -s data/transfer/reports/punctuality-src.rpt ] && echo 0 || echo 1) "punctuality-src.rpt (the Polling file-arrival slot) is missing"
check $(grep -rlqE 'href="[^"]*(trends|punctuality|route-throughput|expected-arrival)[^"]*\.html' docs --include='*.html' 2>/dev/null && echo 1 || echo 0) "a page still links a removed Trends / Punctuality / Route throughput page"
# Entity coverage: ONE page per entity with the verdicts as columns; the
# Regressed count equals Covered once minus Covered (Current), OK transfers
# is never above Current (OK transfers ⊆ Current ⊆ Once)
# (a missing .rpt or a missing STAT label FAILS — the all-zero default used
# to satisfy every relation vacuously)
cov=$(awk -F'\t' '$1 == "TABLE" { t = $2 } $1 == "STAT" && t == "Accounts" { v = $3; sub(/ .*/, "", v); S[$4] = v }
    END { if (!("Covered (Current)" in S) || !("Covered once" in S) || !("OK transfers" in S) || !("Regressed" in S)) { print "missing"; exit }
          print S["Covered (Current)"] + 0, S["Covered once"] + 0, S["OK transfers"] + 0, S["Regressed"] + 0 }' data/transfer/reports/entity-coverage.rpt 2>/dev/null)
if [ -z "$cov" ] || [ "$cov" = missing ]; then
    fail "entity-coverage.rpt missing, or its Accounts table lacks a Covered (Current) / Covered once / OK transfers / Regressed STAT box"
else
    read -r cc co ck cx <<< "$cov"
    check $([ "$cx" -eq $(( co - cc )) ] && [ "$ck" -le "$cc" ] && [ "$cc" -le "$co" ] && echo 0 || echo 1) "entity-coverage Accounts: Current $cc / Once $co / OK $ck / Regressed $cx break OK <= Current <= Once or Regressed = Once - Current"
fi
# the server Top view carries the per-component table (append_rpt_tables) —
# no reader may take its TM/PESITD/SSHD rows for days: every day page is
# date-named, and the dashboard's server record total equals the per-day sum
n=$(ls docs/day/ 2>/dev/null | command grep -vcE '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.html$' || true)
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "docs/day/ holds ${n:-?} page(s) not named after a date (the Top view's component rows read as days?)"
# Blast radius: the Partner redundancy table went; Sole endpoint for names partners
n=$(grep -c '^TABLE\tPartner redundancy' data/analyses/reports/blast-radius.rpt 2>/dev/null)
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "blast-radius.rpt still carries the Partner redundancy table (retired 2026-09-29)"

# ---- the 2026-09-29 site-audit fixes -----------------------------------------
# Failed Subscriptions: the Environment letter column went — Subscription leads
fh=$(grep -o '<tr><th[^>]*>[^<]*</th>' docs/analyses/failed.html 2>/dev/null | head -1 | sed 's/<[^>]*>//g')
n=$(grep -c '<th[^>]*>Environment</th>' docs/analyses/failed.html 2>/dev/null || true)
check $([ "$fh" = "Subscription" ] && [ "${n:-0}" = 0 ] && echo 0 || echo 1) "analyses/failed.html header starts with '${fh:-absent}' / carries ${n:-?} Environment column(s), expected Subscription first and no Environment"
# Entities › Remote Hosts: the group banner follows the columns — a Transfers
# band, and no State band (the sample hosts carry no Waiting / Expired)
n=$(grep -c 'class="gband[^"]*">Transfers</th>' docs/transfer/entities/remote-host-all.html 2>/dev/null || true)
m=$(grep -c 'class="gband[^"]*">State</th>' docs/transfer/entities/remote-host-all.html 2>/dev/null || true)
check $([ "${n:-0}" -ge 1 ] && [ "${m:-1}" = 0 ] && echo 0 || echo 1) "entities/remote-host-all.html group banner: ${n:-0} Transfers band(s), ${m:-?} State band(s), expected Transfers and no State"
# the Subscriptions page's all-time counts sidecar (entities.sh, month-stats.sh until 2026-09-30) and its count cells
check $([ -s data/transfer/reports/_alltime.tsv ] && echo 0 || echo 1) "data/transfer/reports/_alltime.tsv missing or empty"
n=$(grep -oE '<td class="num[^"]*">(<a [^>]*>)?[1-9][0-9]*(</a>)?</td>' docs/analyses/subscriptions.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "analyses/subscriptions.html: every count cell is blank"
# Connections split In / Out (the per-day volume tab)
n=$(grep -c '<th[^>]*>In</th>' docs/server/connections-per-day.html 2>/dev/null || true)
m=$(grep -c '<th[^>]*>Out</th>' docs/server/connections-per-day.html 2>/dev/null || true)
check $([ "${n:-0}" -ge 1 ] && [ "${m:-0}" -ge 1 ] && echo 0 || echo 1) "server/connections-per-day.html header lacks the In / Out columns"
# the sample plants INBOUND connection lines (2026-09-29: gen-events.awk
# s_authok names the partner's login on its connection line) — without them
# the In side of Connections goes untested (the TOTAL In cell below)
check $([ ! -e data/server/reports/_inbound-addr.tsv ] && [ ! -e data/server/cache/_subscriptions.tsv ] && echo 0 || echo 1) "a sidecar of the removed Cleanup reports (_inbound-addr.tsv, the flat server _subscriptions.tsv) is still written"
n=$(awk '/<tr class="total"/ { n = split($0, C, "<td"); if (n >= 3) { c = C[3]; sub(/^[^>]*>/, "", c); sub(/<.*/, "", c); print c } exit }' docs/server/connections-per-day.html 2>/dev/null)
check $([ "${n:-0}" -gt 0 ] 2>/dev/null && echo 0 || echo 1) "server/connections-per-day.html: the TOTAL row's In cell is empty ('${n:-}')"
# an overlapping-rows TOTAL ships its own distinct per-day buckets
n=$(grep -c '<tr class="total"[^>]* data-buckets="[^"]' docs/transfer/entities/bl-all.html 2>/dev/null || true)
check $([ "${n:-0}" -ge 1 ] && echo 0 || echo 1) "entities/bl-all.html: no TOTAL row carries data-buckets"
# the help pages: the home opens help/home.html, Failed files its own page
check $(grep -q 'data-help="home"' docs/index.html 2>/dev/null && echo 0 || echo 1) "docs/index.html does not link help home (data-help=\"home\")"
check $(grep -q 'data-help="failed-files"' docs/transfer/failed-files.html 2>/dev/null && echo 0 || echo 1) "transfer/failed-files.html does not carry data-help=\"failed-files\""
# a report page's title is its Reports-menu label: the two Top views are
# "Transfer top view" / "Server top view", never a bare "Top view"
n=$(grep -rhoE --include='*.html' '<h1[^>]*>[^<]*' docs 2>/dev/null | sed 's/<h1[^>]*>//; s/[[:space:]]*$//' | grep -cx 'Top view' || true)
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "$n page(s) still titled a bare \"Top view\" (<h1>)"
# retired 2026-09-29: the Skipped sub-pages (the main skipped.html stays), the
# Slowest subscriptions, Failure rate, Volume and Missing cronjobs pages and
# the Failed Subscriptions every-File views
check $([ -f docs/transfer/skipped.html ] && echo 0 || echo 1) "docs/transfer/skipped.html missing"
for g in 'transfer/skipped-*.html' 'transfer/duration-slowest*.html' 'transfer/failure-rate*.html' 'transfer/volume*.html' \
         'transfer/missing-cronjobs*.html' 'analyses/missing-cronjobs*.html' 'analyses/failed-all-*.html'; do
    n=$(ls docs/$g 2>/dev/null | wc -l | tr -d ' ')
    check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "docs/$g: $n retired page(s) still published (retired 2026-09-29)"
done

# ---- the 2026-09-29 audit's gate additions ----------------------------------
# linkcheck runs here (read-only): 0 broken, 0 unexpected unreachable
lc=$(bin/build/linkcheck.sh 2>&1 | grep '^linkcheck: [0-9]* pages' | head -1)
check $(printf '%s' "$lc" | grep -q ' 0 broken, 0 unreachable' && echo 0 || echo 1) "linkcheck: ${lc:-no summary line}"
# the home-figure gate only WARNS in the build — a CONSISTENCY WARNING fails verify
if [ -f build/build.log ]; then
    n=$(grep -c 'CONSISTENCY WARNING' build/build.log || true)
    check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "build/build.log holds ${n:-?} CONSISTENCY WARNING line(s)"
fi
# the planted display rename (input/rename.txt: login FE000000 FE-MONITOR)
# lands on the rendered pages
n=$(grep -rl 'FE-MONITOR' docs --include='*.html' 2>/dev/null | wc -l | tr -d ' ')
m=$(grep -rl '>FE000000<' docs --include='*.html' 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" -gt 0 ] && [ "${m:-1}" = 0 ] && echo 0 || echo 1) "display rename FE000000 -> FE-MONITOR: ${n:-0} page(s) show the new name, ${m:-?} still show the old one"
# the Errors group (Failures until 2026-09-29) carries the former Server log
# errors members, collapsed into ONE "Server log" entry of the first row with
# a SECOND row of the four (2026-09-29, user request) — positive
for p in server/errors-log-reasons server/failure-flows server/io-errors server/routing-errors; do
    check $(grep -q 'grouptag">&larr; Errors' "docs/$p.html" 2>/dev/null && echo 0 || echo 1) "docs/$p.html lacks the Errors group tag"
    check $(grep -q '<span class="tab active">Server log</span>' "docs/$p.html" 2>/dev/null && echo 0 || echo 1) "docs/$p.html: the first row lacks the active Server log entry"
    check $(grep -c '<a class="tab" href="[^"]*">\(Errors\|Per flow\|IO errors\|Routing errors\)</a>' "docs/$p.html" 2>/dev/null | awk '{ exit !($1 >= 1) }' && echo 0 || echo 1) "docs/$p.html lacks the Server log second row"
done
check $(grep -q '<a class="tab" href="../server/errors-log-reasons.html">Server log</a>' docs/analyses/failed.html 2>/dev/null && grep -q '>Per flow</a>' docs/analyses/failed.html && echo 1 || echo 0) "analyses/failed.html: the Server log entry is missing or the four server members are still in the first row"
# went-kaput.html is gone (2026-09-29, user request) and its .rpt with the
# day pages' Trouble after success line (2026-09-30: bin/build/kaput-evidence.sh
# writes only the evidence sidecar the Reason readers take)
check $([ -f docs/server/went-kaput.html ] && echo 1 || echo 0) "docs/server/went-kaput.html still exists"
check $([ -f data/server/reports/went-kaput.rpt ] || [ -f bin/server/reports/went-kaput.sh ] && echo 1 || echo 0) "went-kaput.rpt / bin/server/reports/went-kaput.sh still exists"
check $([ -s data/server/reports/_kaput-evidence.tsv ] && echo 0 || echo 1) "the kaput evidence sidecar (_kaput-evidence.tsv) is missing or empty"
check $(grep -rlq 'went-kaput.html' docs --include='*.html' --include='*.js' 2>/dev/null && echo 1 || echo 0) "a page still links went-kaput.html"
# the home per-day table has NO Total row (2026-09-29, user request: "remove
# the Total row in the date tables")
check $(grep -q '<tr class="total"><td>Total</td>' docs/index.html 2>/dev/null && echo 1 || echo 0) "the home per-day table still has a Total row"

# the second 2026-09-29 removal batch (user request): Sources and targets,
# Data diff, Triage, File journey Last leg / In and out, Episodes › Episodes,
# Subscriptions in boxes and the whole Cleanup group (Cleanup backlog, Config
# hygiene, Whitelist audit, Account sharing, Twins) — no page, no help page,
# no .rpt, no link
n=$(ls docs/transfer/sources-and-targets*.html docs/analyses/data-diff*.html docs/analyses/triage*.html docs/transfer/file-journey-last-leg.html docs/transfer/file-journey-in-and-out.html docs/transfer/episodes-episodes.html docs/analyses/subscriptions-in-boxes*.html docs/*/cleanup-backlog*.html docs/*/config-hygiene*.html docs/*/whitelist-audit*.html docs/*/account-sharing*.html docs/*/twins*.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "$n removed report page(s) (sources-and-targets, data-diff, triage, last leg, in and out, episodes, boxes, Cleanup) still published"
# the red-run producers became ONE sidecar writer (2026-09-30): no
# from-green-to-red / only-red .rpt or script may come back, the sidecar exists
n=$(ls data/transfer/reports/from-green-to-red.rpt data/transfer/reports/only-red.rpt bin/transfer/reports/from-green-to-red.sh bin/transfer/reports/only-red.sh 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" = 0 ] && [ -s data/transfer/reports/_red-run.tsv ] && echo 0 || echo 1) "the red-run sidecar _red-run.tsv is missing/empty, or $n from-green-to-red / only-red file(s) still exist"
n=$(ls docs/help/sources-and-targets.html docs/help/data-diff.html docs/help/triage.html docs/help/subscriptions-in-boxes.html docs/help/cleanup-backlog.html docs/help/config-hygiene.html docs/help/whitelist-audit.html docs/help/account-sharing.html docs/help/twins.html docs/help/episodes.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "$n help page(s) of removed reports still published"
n=$(ls data/*/reports/sources-and-targets.rpt data/*/reports/data-diff.rpt data/*/reports/triage.rpt data/*/reports/cleanup-backlog.rpt data/*/reports/account-sharing.rpt data/*/reports/twins.rpt data/*/reports/config-defects.rpt data/*/reports/arrived-left.rpt data/*/reports/episodes-src.rpt 2>/dev/null | wc -l | tr -d ' ')
check $([ "${n:-0}" = 0 ] && echo 0 || echo 1) "$n removed .rpt file(s) still written"
check $(grep -rlqE 'href="[^"#]*(sources-and-targets|data-diff|triage|subscriptions-in-boxes|cleanup-backlog|config-hygiene|whitelist-audit|account-sharing|twins|file-journey-last-leg|file-journey-in-and-out|episodes-episodes)[^"]*\.html' docs --include='*.html' 2>/dev/null && echo 1 || echo 0) "a page still links a removed report"
check $(grep -q '>Cleanup<' docs/reports/index.html 2>/dev/null && echo 1 || echo 0) "reports/index.html still lists the Cleanup group"
# analyses/accounts.html lost its Breaking naming rules table; Failed
# Subscriptions' All view ends with the CoreId / SessionId column
check $(grep -q 'Breaking naming rules' docs/analyses/accounts.html 2>/dev/null && echo 1 || echo 0) "analyses/accounts.html still carries the Breaking naming rules table"
h=$(awk -F'\t' '$1 == "HEAD" { print $NF; exit }' data/transfer/reports/failed-sub-all.rpt 2>/dev/null)
check $([ "$h" = "CoreId / SessionId" ] && echo 0 || echo 1) "failed-sub-all.rpt's table ends with '${h:-?}', expected the CoreId / SessionId column last"
# the sitemap: ONE flow of cards (no Reports / Dashboards / Tools sections),
# the former "Data pages & tools" card now "Tools"
check $(grep -q 'Data pages &amp; tools\|class="smarea"\|sm-reports' docs/tools/sitemap.html 2>/dev/null && echo 1 || echo 0) "tools/sitemap.html still has the sections or the Data pages & tools card"
check $(grep -q '<h3>Tools</h3>' docs/tools/sitemap.html 2>/dev/null && echo 0 || echo 1) "tools/sitemap.html lacks the Tools card"
# docs/files/ holds ONLY the published File set (bin/transfer/filepages.sh:
# per subscription the newest OK File + the three newest Failed ones): every
# CoreId of _filepages.tsv has its page, no other CoreId-named page exists
FP=data/transfer/cache/_filepages.tsv
nw=$(cut -f1 "$FP" 2>/dev/null | LC_ALL=C sort -u | wc -l | tr -d ' ')
nh=$(ls docs/files/ 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.html$' || true)
nm=$(cut -f1 "$FP" 2>/dev/null | LC_ALL=C sort -u | while read -r c; do [ -f "docs/files/$c.html" ] || echo "$c"; done | wc -l | tr -d ' ')
check $([ "${nw:-0}" -gt 0 ] && [ "$nw" = "$nh" ] && [ "${nm:-1}" = 0 ] && echo 0 || echo 1) "docs/files/: $nh CoreId page(s), the published set holds ${nw:-0} ($nm without a page)"
n=$(awk -F'\t' '$2 == "O" { o[$3]++ } $2 == "E" { e[$3]++ } END { for (k in o) if (o[k] > 1) b++; for (k in e) if (e[k] > 3) b++; print b + 0 }' "$FP" 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "_filepages.tsv: $n subscription(s) with more than one OK or three Error File pages"
# UC status and the Polling page count the SAME polls (2026-09-29 audit): a
# renamed flow's polls logged under its old name fold into UC3 status too
# (the sample renames UC3_AB_NAS2_GLOBEX), and the UC3 tab's copied poll
# table keeps only UC3 flows, so its total equals the Polling page's
n=$(awk -F'\t' '
    function strip(c) { sub(/^@\{[^}]*\}/, "", c); return c }
    FNR == 1 { f++ }
    f == 1 && $1 == "ROW" && $8 ~ /^[0-9]+$/ { us[toupper(strip($3))] = $8 }
    f == 2 && $1 == "ROW" && $7 ~ /^[0-9]+$/ { u = toupper(strip($2)); if ((u in us) && us[u] != $7) { b++; print "  " u ": UC status " us[u] ", Polling " $7 > "/dev/stderr" } }
    END { print b + 0 }' data/server/reports/uc3-status.rpt data/server/reports/polling.rpt 2>&1 | tail -1)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n UC3 flow(s) whose UC status Polls differ from the Polling page"
a=$(awk -F'\t' '$1 == "TABLE" { t++ } t == 1 && $1 == "TOTAL" { sub(/^@\{[^}]*\}/, "", $3); print $3; exit }' data/server/reports/uc3-polling.rpt 2>/dev/null)
b=$(awk -F'\t' '$1 == "TOTAL" { sub(/^@\{[^}]*\}/, "", $7); print $7; exit }' data/server/reports/polling.rpt 2>/dev/null)
check $([ -n "$a" ] && [ "$a" = "$b" ] && echo 0 || echo 1) "UC3 tab Polls total ${a:-?} differs from the Polling page's ${b:-?}"
# the two tables the sample left empty until the 2026-09-29 audit: the server
# log's resubmit trail (gen-events.awk plants it beside the "resub" flows'
# resubmits) and the admin-UI test connections
n=$(awk -F'\t' '$1 == "TABLE" { t = ($2 ~ /^Resubmission outcomes/) } t && $1 == "ROW" && $3 ~ /^[0-9]+$/ { n++ } END { print n + 0 }' data/transfer/reports/resubmissions.rpt 2>/dev/null)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "resubmissions.rpt: the Resubmission outcomes (server log) table has no dated row"
n=$(awk -F'\t' '$1 == "TABLE" { t = ($2 == "Test connections") } t && $1 == "ROW" && $0 ~ /\tssh\t|\tpesit\t/ { n++ } END { print n + 0 }' data/server/reports/connection-diagnostics.rpt 2>/dev/null)
check $([ "${n:-0}" -ge 2 ] && echo 0 || echo 1) "connection-diagnostics.rpt: the Test connections table lacks its ssh / pesit rows (${n:-0})"

# the four columns the sample left empty until the 2026-09-30 audit (S-14;
# gen-events.awk plants each without a PRNG draw):
# 1. Logons > Incoming "Auth failed" = every planted anonymous failure (the
#    one-second window attributes each to the login screened just before it)
P=data/server/cache/_parse.tsv
want=$(awk -F'\t' 'index($5, "[Ssh Default] Authentication failed using local.") { n++ } END { print n + 0 }' "$P" 2>/dev/null)
got=$(awk -F'\t' '$1 == "TABLE" { t = ($2 ~ /Incoming/) } t && $1 == "HEAD" { for (i = 2; i <= NF; i++) if ($i == "Auth failed") c = i }
                  t && c && $1 == "TOTAL" { v = $c; sub(/^@\{[^}]*\}/, "", v); print v + 0; exit }' data/server/reports/logon.rpt 2>/dev/null)
check $([ "${want:-0}" -gt 0 ] && [ "${got:-x}" = "$want" ] && echo 0 || echo 1) "logon.rpt Incoming: Auth failed total ${got:-?}, planted anonymous failures ${want:-?}"
# 2. Connections per day PESIT / FTP / Other = the planted inbound lines of
#    those protocols (every other sampled connection line is SSH)
for pr in PESIT FTP Other; do
    col=$([ $pr = PESIT ] && echo 6 || { [ $pr = FTP ] && echo 7 || echo 8; })
    want=$(awk -F'\t' -v p="$pr" 'match($5, /had initiated a connection over [A-Za-z0-9]+/) { x = substr($5, RSTART + 32, RLENGTH - 32)
            if (p == "Other" ? (x != "SSH" && x != "PESIT" && x != "FTP") : (x == p)) n++ } END { print n + 0 }' "$P" 2>/dev/null)
    got=$(awk -F'\t' -v c="$col" '$1 == "TABLE" { t = ($2 == "Connections per day") } t && $1 == "TOTAL" { v = $c; sub(/^@\{[^}]*\}/, "", v); print v + 0; exit }' data/server/reports/connections.rpt 2>/dev/null)
    check $([ "${want:-0}" -gt 0 ] && [ "${got:-x}" = "$want" ] && echo 0 || echo 1) "connections.rpt Connections per day: $pr total ${got:-?}, planted $pr lines ${want:-?}"
done
# 3. the nodirall UC3 (never transfers: its remote directory does not exist)
#    lists on the UC3 tab's Missing remote directories, and stays orange
nd=$(awk -F'\t' '("," $30 ",") ~ /,nodirall,/ { print $4; exit }' input/.sample/_estate.tsv 2>/dev/null)
n=$(awk -F'\t' -v s="$nd" '$1 == "TABLE" { t = ($2 == "Missing remote directories") } t && $1 == "ROW" && index($3, s) { n++ } END { print n + 0 }' data/server/reports/no-remote-dir.rpt 2>/dev/null)
check $([ -n "$nd" ] && [ "${n:-0}" = 1 ] && grep -q 'Missing remote directories' docs/analyses/uc-status-uc3.html 2>/dev/null && echo 0 || echo 1) "no-remote-dir.rpt: the nodirall flow ${nd:-?} is not on the UC3 tab's Missing remote directories (${n:-0} row(s))"
c=$(awk -F'\t' -v s="$nd" '$1 == s { print $3; exit }' data/flow-manager/base/_subscriptions.tsv 2>/dev/null)
check $([ "${c:-x}" = orange ] && echo 0 || echo 1) "the nodirall flow ${nd:-?} is ${c:-?}, expected orange (never transferred; only a Connection failure streak reddens one)"
# 4. the shareduc4 account delivers AND collects on one connection: its UC2
#    row's Same connection is filled
su=$(awk -F'\t' '$3 == 2 && ("," $30 ",") ~ /,shareduc4,/ { print $4; exit }' input/.sample/_estate.tsv 2>/dev/null)
n=$(awk -F'\t' -v s="$su" '$1 == "ROW" && index($2, "}" s) { v = $7; print v + 0; exit }' data/server/reports/uc2-visits.rpt 2>/dev/null)
check $([ -n "$su" ] && [ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "uc2-visits.rpt: the shareduc4 flow ${su:-?} has no Same connection (${n:-0})"

if [ "$fails" -eq 0 ]; then
    echo "verify: OK — the sample estate exercises every planted scenario." >&2
else
    echo "verify: $fails assertion(s) FAILED." >&2
    exit 1
fi
