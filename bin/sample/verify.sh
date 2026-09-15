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
# Partners - Incoming (2026-09-13): the merged page exists and carries every FE overview row plus the funnel cell drills
check $([ -f "docs/analyses/partners-in.html" ] && echo 0 || echo 1) "docs/analyses/partners-in.html missing"
n=$(command grep -c '^ROW' "data/analyses/reports/partners-in.rpt" 2>/dev/null || echo 0); m=$(command grep -c '^ROW' "data/analyses/reports/fe-overview.rpt" 2>/dev/null || echo 1)
check $([ "${n:-0}" -ge "${m:-1}" ] && [ "${m:-0}" -gt 0 ] && echo 0 || echo 1) "partners-in.rpt has $n row(s), fewer than the FE overview ($m)"
n=$(command grep -c '@data:drill-cell-12=' "data/analyses/reports/partners-in.rpt" 2>/dev/null || echo 0)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "partners-in.rpt carries no re-keyed funnel drill (Allowed at column 12)"
# Partners - Outgoing (2026-09-13): the hosts twin exists, its rows carry the host tints, and its host figures agree with the Entities host page
check $([ -f "docs/analyses/hosts-overview.html" ] && echo 0 || echo 1) "docs/analyses/hosts-overview.html missing"
n=$(command grep -c '@data:res=' "data/analyses/reports/hosts-overview.rpt" 2>/dev/null || echo 0)
check $([ "${n:-0}" -gt 0 ] && echo 0 || echo 1) "hosts-overview.rpt has 0 tinted rows"
n=$(awk -F'\t' 'FNR==NR { if ($1=="ROW") { l=$0; gsub(/@\{[^}]*\}/, "", l); split(l, F, "\t"); E[toupper(F[2])] = (F[3]+0) "|" (F[4]+0) "|" (F[7]+0) } next }
    $1=="ROW" { l=$0; gsub(/@\{[^}]*\}/, "", l); split(l, F, "\t"); k=toupper(F[2]); if (!(k in E)) next; if (E[k] != (F[6]+0) "|" (F[7]+0) "|" (F[9]+0)) bad++ } END { print bad+0 }' data/transfer/reports/entities/remote-host.rpt data/analyses/reports/hosts-overview.rpt 2>/dev/null || echo 1)
check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "hosts-overview: $n host row(s) disagree with the Entities host page on Files in / out / Auto retries"
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
hdr=$(grep -o '<tr><th>Account</th>.*' "docs/transfer/entities/account-all.html" 2>/dev/null | head -1 | sed 's/^<tr>//; s/<\/tr>.*//; s/<th[^>]*>//g; s/<\/th>/|/g')
check $([ "$hdr" = "Account|In|Out|Error|Error %|Auto|Ok|Error|p90|p95|p99|p100|Total|Avg|Ok|Error|Error %|Waiting|Expired|First|Last|Days|" ] && echo 0 || echo 1) "entities/account-all.html header is '$hdr', expected the grouped layout Account|In|Out|Error|Error %|Auto|Ok|Error|p90|p95|p99|p100|Total|Avg|Ok|Error|Error %|Waiting|Expired|First|Last|Days"
read -r want wantm <<< "$(awk -F'\t' 'FNR == 1 { fno++ } fno == 1 { if ($3 != "Processed") fl[$1] = 1; if ($22 == "true") rs[$1] = 1; next } $3 != "" && $4 != "" && $2 != "Failed" && $2 != "Expired" && ($1 in fl) { n++; if ($1 in rs) m++ } END { print n + 0, m + 0 }' "$T" "$F" 2>/dev/null)"
read -r got gotm <<< "$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "TOTAL" { a = $6; b = $7; sub(/^@\{[^}]*\}/, "", a); sub(/^@\{[^}]*\}/, "", b); print a + b, b + 0; exit }' "data/transfer/reports/account.rpt" 2>/dev/null)"
check $([ "${got:-x}" = "${want:-y}" ] && echo 0 || echo 1) "account.rpt Retry + Resubmit total is '${got:-absent}', an independent recount of the caches gives '${want:-?}'"
check $([ "${gotm:-x}" = "${wantm:-y}" ] && echo 0 || echo 1) "account.rpt Resubmit total is '${gotm:-absent}', an independent recount of the caches gives '${wantm:-?}'"
check $([ "${want:-0}" -gt "${wantm:-0}" ] && [ "${wantm:-0}" -gt 0 ] && echo 0 || echo 1) "the sample has no Retry (${want:-0} cured, ${wantm:-0} resubmitted) or no Resubmit File — an Entities column is never exercised"
# the Retry / Resubmit DRILLS (2026-09-13, user request): every summary row
# with a Retry (Resubmit) count carries a non-empty coreids-retry
# (coreids-resubmit) list of at most 10 entries, a row without one carries
# an empty list, and the rendered page ships the attributes
read -r dr1 dr2 dr3 <<< "$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "ROW" {
        r = ""; s = ""; for (i = 8; i <= NF; i++) { if (index($i, "@data:coreids-retry=") == 1) r = substr($i, 21); if (index($i, "@data:coreids-resubmit=") == 1) s = substr($i, 24) }
        nr = (r == "" ? 0 : split(r, a, ",")); ns = (s == "" ? 0 : split(s, b, ","))
        if (($6 + 0 > 0) != (nr > 0) || ($7 + 0 > 0) != (ns > 0)) bad++
        if (nr > 10 || ns > 10) big++
        if (nr > 0) anyr++; if (ns > 0) anys++ }
    END { print bad + 0, big + 0, (anyr > 0 && anys > 0) + 0 }' "data/transfer/reports/subscription.rpt" 2>/dev/null)"
check $([ "${dr1:-1}" = 0 ] && echo 0 || echo 1) "subscription.rpt: ${dr1:-?} row(s) whose Retry/Resubmit count and drill list disagree"
check $([ "${dr2:-1}" = 0 ] && echo 0 || echo 1) "subscription.rpt: ${dr2:-?} Retry/Resubmit drill list(s) longer than 10"
check $([ "${dr3:-0}" = 1 ] && echo 0 || echo 1) "the sample subscription table has no Retry drill or no Resubmit drill — one of the two is never exercised"
check $([ "$(grep -c 'data-coreids-rauto="[0-9]' docs/transfer/entities/subscription-all.html 2>/dev/null)" -ge 1 ] && [ "$(grep -c 'data-coreids-rmok="[0-9]' docs/transfer/entities/subscription-all.html 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "entities/subscription-all.html ships no Retry / Resubmit drill lists"
check $([ "$(grep -c 'data-coreids-retry' docs/assets/report.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "report.js does not bind the Retry / Resubmit drills"

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
# the Recovered files report's Retry / Resubmit split (2026-09-12, user
# request): every table carries the two columns after Recovered — the same
# Automatic / Manual rule as the Top view, so the per-subscription totals
# must equal the recount above, and the per-day totals the same
RF="data/transfer/reports/recovered-files.rpt"
h=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "HEAD" { print; exit }' "$RF" 2>/dev/null)
check $([ "$h" = $'HEAD\tSubscription\tRecovered\tRetry\tResubmit\tFiles\tRecovered %' ] && echo 0 || echo 1) "recovered-files.rpt table 1 HEAD is '$h' — expected Recovered · Retry · Resubmit"
read -r rfr rfa rfm <<< "$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "TOTAL" { a = $3; b = $4; c = $5; sub(/^@\{[^}]*\}/, "", a); sub(/^@\{[^}]*\}/, "", b); sub(/^@\{[^}]*\}/, "", c); print a + 0, b + 0, c + 0; exit }' "$RF" 2>/dev/null)"
check $([ "${rfr:-x}" = "${wrv:-y}" ] && [ "$((${rfa:-0} + ${rfm:-0}))" = "${wrv:-y}" ] && echo 0 || echo 1) "recovered-files Recovered/Retry/Resubmit = ${rfr:-?}/${rfa:-?}/${rfm:-?}, the caches give ${wrv:-?} recovered"
check $([ "${rfm:-x}" = "${wrm:-y}" ] && echo 0 || echo 1) "recovered-files Resubmit = ${rfm:-absent}, the caches give ${wrm:-?}"
read -r dfa dfm <<< "$(awk -F'\t' '/^TABLE\t/ { t++ } t == 3 && $1 == "TOTAL" { b = $5; c = $6; sub(/^@\{[^}]*\}/, "", b); sub(/^@\{[^}]*\}/, "", c); print b + 0, c + 0; exit }' "$RF" 2>/dev/null)"
check $([ "${dfa:-x}" = "${rfa:-y}" ] && [ "${dfm:-x}" = "${rfm:-y}" ] && echo 0 || echo 1) "recovered-files per-day Retry/Resubmit totals ${dfa:-?}/${dfm:-?} differ from the per-subscription ${rfa:-?}/${rfm:-?}"
check $([ "$(grep -c 'Retry (automatic)\|Resubmit (manual)' "docs/transfer/recovered-files.html" 2>/dev/null)" -ge 2 ] && echo 0 || echo 1) "transfer/recovered-files.html lacks the Retry (automatic) / Resubmit (manual) boxes"
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

# ONE "Last error" per subscription page (2026-09-12, user request): a red
# flow's page carries the publish-time splice "Last error - <reason>" below
# Features, and the writer's own "Last error — <file>" section must then be
# gone — no page shows the same error twice; and the splice must exist on
# at least one sample page, or the rule is never exercised
n=0; m=0
for f in docs/details/subscriptions/*.html; do
    if grep -q '<h2>Last error - ' "$f" 2>/dev/null; then m=$((m + 1)); grep -q '<h2>Last error — ' "$f" 2>/dev/null && n=$((n + 1)); fi
done
check $([ "$n" = 0 ] && echo 0 || echo 1) "$n subscription page(s) show the last error twice (the splice below Features AND the writer's section)"
check $([ "$m" -gt 0 ] && echo 0 || echo 1) "no sample subscription page carries the spliced 'Last error - <reason>' section"

# the search pages live under docs/search/ (2026-09-12, user request):
# search.html + search-data.js and the six file-search pages + payloads —
# nothing of them left at the docs root, the pages load their engine and
# payload from the right places, and the top bar / sitemap link there
for p in search.html search-data.js file-search-24-hours.html file-search-24-hours-data.js file-search-month.html file-search-month-data.js; do
    check $([ -f "docs/search/$p" ] && echo 0 || echo 1) "docs/search/$p is missing"
    check $([ ! -e "docs/$p" ] && echo 0 || echo 1) "docs/$p still sits at the docs root"
done
check $([ "$(ls docs/search/file-search-*.html 2>/dev/null | wc -l | tr -d ' ')" = 6 ] && echo 0 || echo 1) "docs/search/ has $(ls docs/search/file-search-*.html 2>/dev/null | wc -l | tr -d ' ') file-search pages, expected 6"
check $([ "$(grep -c '<script src="../assets/file-search.js?v=' docs/search/file-search-24-hours.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "search/file-search-24-hours.html does not load ../assets/file-search.js"
check $([ "$(grep -c '<script src="file-search-24-hours-data.js?v=' docs/search/file-search-24-hours.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "search/file-search-24-hours.html does not load its sibling payload"
check $([ "$(grep -c 'href="../search/search.html"' docs/tools/sitemap.html 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "tools/sitemap.html does not link ../search/search.html"
check $([ "$(grep -c 'search/file-search-24-hours.html' docs/tools/report-finder.html 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "tools/report-finder.html does not link search/file-search-24-hours.html"
check $([ "$(grep -c 'href="../search/search.html"' docs/help/index.html 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "the baked top bar does not link ../search/search.html"
check $([ "$(grep -c 'href="\.\./details/' docs/search/search-data.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "search/search-data.js rows do not link ../details/ (one level below the root)"

# the tool pages live under docs/tools/ (2026-09-12, user request): the
# sitemap, the report finder, whats-new AND the build report (back on the
# site, written last by bin/build.sh) — nothing of them at the root, every
# outward link carrying ../, the sibling tools ./, the sitemap Tools card
# linking the build report, the runtime bar data pointing at tools/
for p in sitemap.html report-finder.html whats-new.html build.html; do
    check $([ -f "docs/tools/$p" ] && echo 0 || echo 1) "docs/tools/$p is missing"
    check $([ ! -e "docs/$p" ] && echo 0 || echo 1) "docs/$p still sits at the docs root"
done
check $([ "$(grep -c 'href="\./build.html"' docs/tools/sitemap.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "tools/sitemap.html does not link ./build.html under Tools"
check $([ "$(grep -c 'href="\./report-finder.html"\|href="\./whats-new.html"' docs/tools/sitemap.html 2>/dev/null)" = 2 ] && echo 0 || echo 1) "tools/sitemap.html does not link its sibling tools with ./"
check $([ "$(grep -c 'href="\.\./transfer/index.html"' docs/tools/sitemap.html 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "tools/sitemap.html does not link ../transfer/index.html"
check $([ "$(grep -c '<a href="\.\./transfer/' docs/tools/report-finder.html 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "tools/report-finder.html rows do not carry ../ hrefs"
check $([ "$(grep -c 'href="\.\./assets/style.css"' docs/tools/build.html 2>/dev/null)" = 1 ] && [ "$(grep -c '@B@' docs/tools/build.html build/index.html 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')" = 0 ] && echo 0 || echo 1) "tools/build.html does not load ../assets/style.css, or a @B@ placeholder survived"
check $([ "$(grep -c 'href="\.\./docs/assets/style.css"' build/index.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "build/index.html (the local copy) does not load ../docs/assets/style.css"
check $([ "$(grep -c 'tools/report-finder.html\|tools/sitemap.html' docs/assets/report.js 2>/dev/null)" -ge 3 ] && echo 0 || echo 1) "report.js does not point the top bar and the palette at tools/"
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

# the END rule (2026-09-12, user rule: "there are CoreIds from this
# subscription that ended ok after it — in those cases do not mark it as a
# Server Error"): the planted lateok flow (estate.awk UC1_DPL_PAYOUT_DUNDER)
# logs a connection-failure E line at X and ONE File that STARTED before X
# and was DELIVERED by its retry after X — start < error < end. The flow
# stays GREEN: no red flip, not server-failing, not on went-kaput, no banner
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
    check $([ "$(grep -c "^$lk"$'\t' data/blue/_redflip.tsv 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok flow is in _redflip.tsv — the error was counted as after the last transfer"
    check $([ "$(grep -c "$lk" data/transfer/reports/_srvsubs-map.tsv 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok flow is in the server-failing set (_srvsubs-map.tsv)"
    check $([ "$(grep -c $'^ROW\t'"$lk" data/server/reports/went-kaput.rpt 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok flow has a went-kaput row"
    ls9=$(awk -F'\t' -v s="$lk" '$1 == s { print $2; exit }' "data/transfer/reports/details/subscriptions/_slugmap.tsv" 2>/dev/null)
    lp="docs/details/subscriptions/${ls9:-missing}.html"
    check $([ -n "$ls9" ] && [ -f "$lp" ] && echo 0 || echo 1) "the lateok flow has no detail page ('${ls9:-no slug}')"
    check $([ "$(grep -c 'AFTER LAST TRANSFER' "$lp" 2>/dev/null)" = 0 ] && echo 0 || echo 1) "the lateok page carries an AFTER LAST TRANSFER banner"
    check $([ "$(grep -c "Last OK transfer" "$lp" 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "the lateok page has no Last OK transfer section"
fi
n=$(awk -F'\t' '$4 != "" && ($24 == "" || $24 < $4 " " $5) { n++ } END { print n+0 }' "$F" 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "_files.tsv has $n dated File(s) with an empty end (col 24) or an end before the start"

# the ENVIRONMENT SWITCH (2026-09-12, user request): the sample checkout keeps
# its single "Sample" brand link — no Acceptance / Production pair anywhere —
# while the shipped runtime (topbar-data.js, report.js) carries the switch
# function with the four site URLs, so a runtime checkout renders the pair
tbd="docs/assets/topbar-data.js"
check $([ "$(grep -c 'envkey:"sample"' "$tbd" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js does not carry envkey:\"sample\""
check $([ "$(grep -c 'window.AXWAY_ENVLINKS=function' "$tbd" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js does not define the AXWAY_ENVLINKS switch function"
# from the file system only the current environment shows (2026-09-14): the switch function carries the file: branch
check $([ "$(grep -c 'location.protocol==="file:"' "$tbd" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js: AXWAY_ENVLINKS lacks the file-system branch (only the current environment from file://)"
for u in 'http://localhost/runtime-acceptance/' 'http://localhost/runtime-production/' 'https://probable-adventure-l6y6k83.pages.github.io/' 'https://expert-adventure-9myme9m.pages.github.io/'; do
    check $([ "$(grep -c "$u" "$tbd" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js lacks the site URL $u"
done
check $([ "$(grep -c 'data-envto' docs/assets/report.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "report.js does not render the Acceptance / Production pair (data-envto)"
check $([ "$(grep -c '<a class="brand" href="../index.html">Sample</a>' docs/help/index.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "the help page bar does not lead with the single Sample brand link"
check $([ "$(grep -rl 'data-envto' docs --include=*.html 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && echo 0 || echo 1) "a sample page bakes the Acceptance / Production pair (data-envto)"

# the home page's Duration group ends on p99 (2026-09-13, user request):
# p50 · p75 · p90 · p95 · p99, five cells per day and in the Total row
hdr=$(grep -o '<th class="num"[^>]*>p[0-9]*</th>' docs/index.html 2>/dev/null | sed 's/<[^>]*>//g' | tr '\n' '|')
check $([ "$hdr" = "p50|p75|p90|p95|p99|" ] && echo 0 || echo 1) "the home Duration group headers are '$hdr', expected p50|p75|p90|p95|p99|"
check $([ "$(grep -c '<th class="gband" colspan="5" data-href="transfer/duration.html?axway_date=all">Duration</th>' docs/index.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "the home Duration banner does not span 5 columns or does not link the Duration report"
# every cell of the Duration group opens transfer/duration.html at the full
# date range (2026-09-14, user request): the five p-headers and the Total with
# ?axway_date=all, five cells per day row with ?axway_row=<that row's date>;
# report.js binds them and outranks the row link
nrows=$(awk '/<table class="index fit dayrows/ { p = 1 } p && /<tr>/ && /<td/ { n++ } p && /<\/table>/ { exit } END { print n + 0 }' docs/index.html 2>/dev/null)
ncells=$(grep -o '<td class="num[^"]*" data-href="transfer/duration.html?axway_\(row=[0-9-]*\|date=all\)">' docs/index.html 2>/dev/null | wc -l | tr -d ' ')
nth=$(grep -o '<th class="num" data-href="transfer/duration.html?axway_date=all">p[0-9]*</th>' docs/index.html 2>/dev/null | wc -l | tr -d ' ')
check $([ "${nth:-0}" = 5 ] && [ "${nrows:-0}" -gt 0 ] && [ "${ncells:-0}" -ge $((${nrows:-0} * 5)) ] && echo 0 || echo 1) "the home Duration group links: $nth p-headers, $ncells day cells for $nrows rows (expected 5 and >= 5 per row)"
bad=$(awk '/<table class="index fit dayrows/ { p = 1 } p && /<\/table>/ { exit } p && /<tr>/ && /<td/ { if (!match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) next; d = substr($0, RSTART, RLENGTH); c = $0; if (gsub("axway_row=" d "\"", "", c) != 5) bad++ } END { print bad + 0 }' docs/index.html 2>/dev/null)
check $([ "${bad:-1}" = 0 ] && echo 0 || echo 1) "${bad:-?} home day row(s) whose five Duration cells do not open their own date (?axway_row=<date>)"
check $([ "$(grep -c 'axway_date=all' docs/assets/report.js 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "report.js does not accept ?axway_date=all"
check $([ "$(grep -c 'function setupCellLinks' docs/assets/report.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "report.js does not define setupCellLinks"

# the Activity over Time tables carry ONE Files column — the delivered
# count — and no Error / OK pair (2026-09-13, user request): no green/red
# cells on the four activity pages, the Per day Files total = the OK count
# of the caches, and the dashboards still get their per-day series from the
# day.rpt META day lines (files + failed, gap days included)
for h in $(awk -F'\t' '$1 == "HEAD" { print $0 }' data/transfer/reports/activity.rpt 2>/dev/null | grep -c $'\tOK\t\|\tOK$'); do
    check $([ "$h" = 0 ] && echo 0 || echo 1) "activity.rpt still has $h table header(s) with an OK column"
done
h=$(awk -F'\t' '$1 == "TABLE" && $2 == "Per day" { p = 1 } p && $1 == "HEAD" { print; exit }' data/transfer/reports/activity.rpt 2>/dev/null)
check $([ "$h" = $'HEAD\tDate\tFiles\tVolume\tFirst Time\tLast Time' ] && echo 0 || echo 1) "activity.rpt Per day HEAD is '$h'"
n=$(grep -c 'class="num failed"\|class="num processed"\|numfailed\|numprocessed' docs/transfer/activity-per-day.html docs/transfer/activity-per-week.html docs/transfer/activity-per-hour.html docs/transfer/activity-per-weekday.html 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n green/red (OK/Error) cells left on the four Activity over Time pages"
want=$(awk -F'\t' '$4 != "" && $2 != "Failed" && $2 != "Expired" { n++ } END { print n + 0 }' "$F" 2>/dev/null)
got=$(awk -F'\t' '$1 == "TABLE" && $2 == "Per day" { p = 1 } p && $1 == "TOTAL" { v = $3; sub(/^@\{[^}]*\}/, "", v); print v + 0; exit }' data/transfer/reports/activity.rpt 2>/dev/null)
check $([ "${got:-x}" = "${want:-y}" ] && echo 0 || echo 1) "activity Per day Files total is '${got:-absent}', the caches hold ${want:-?} OK Files"
m=$(awk -F'\t' '$1 == "META" && $2 == "day" { n++; if ($4 + 0 < $5 + 0) bad++ } END { print n + 0, bad + 0 }' data/transfer/reports/day.rpt 2>/dev/null)
check $([ "${m%% *}" -gt 0 ] && [ "${m##* }" = 0 ] && echo 0 || echo 1) "day.rpt META day lines: ${m:-none} (count, rows with failed > files)"
check $([ "$(grep -c '\$1=="META" && \$2=="day"' bin/dashboards/lib.sh 2>/dev/null)" = 2 ] && echo 0 || echo 1) "dashboards/lib.sh does not read the per-day series from the META day lines"

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
got=$(awk -F'\t' '$1 == "TOTAL" && $2 == "@{colspan=2}Files" { v = $3; sub(/^@\{[^}]*\}/, "", v); print v + 0; exit }' data/transfer/reports/file-journey.rpt 2>/dev/null)
check $([ "${got:-x}" = "${want:-y}" ] && echo 0 || echo 1) "file-journey Arrived / Left Files total is '${got:-absent}', the caches hold ${want:-?} OK Files"

# the Protocol & Security group tables carry ONE Transfers column — the OK
# legs — and no Error / OK pair (2026-09-13, user request): no green/red
# cells on the protocol / security-params pages and their per-value pages,
# the By protocol Transfers total = the caches' Processed legs
n=$(awk -F'\t' '$1 == "HEAD" && (/\tOK\t|\tOK$|\tError\t|\tError$/) { n++ } END { print n + 0 }' data/transfer/reports/protocol.rpt data/transfer/reports/security-params.rpt data/transfer/reports/secparams/*.rpt 2>/dev/null)
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "protocol / security-params rpts still have $n table header(s) with an OK / Error column"
n=$(grep -c 'class="num failed"\|class="num processed"' docs/transfer/protocol-*.html docs/transfer/security-params-*.html docs/transfer/secparams/*.html 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')
check $([ "${n:-1}" = 0 ] && echo 0 || echo 1) "$n green/red (OK/Error) cells left on the Protocol & Security group pages"
want=$(awk -F'\t' '{ s = $3; sub(/ Subtransmission$/, "", s); if (s == "Processed") n++ } END { print n + 0 }' "$T" 2>/dev/null)
got=$(awk -F'\t' '$1 == "TABLE" && $2 == "By protocol" { p = 1 } p && $1 == "TOTAL" { v = $3; sub(/^@\{[^}]*\}/, "", v); print v + 0; exit }' data/transfer/reports/protocol.rpt 2>/dev/null)
check $([ "${got:-x}" = "${want:-y}" ] && echo 0 || echo 1) "protocol By protocol Transfers total is '${got:-absent}', the caches hold ${want:-?} Processed legs"

# the Duration report holds BOTH per-day tables side by side (2026-09-13,
# user request): percentiles first (the home page reads it by title), then
# min / avg / median / max; the Min/Avg/Max sibling pages are gone and the
# button row keeps only the OK / All pair — for both scopes
for p in duration duration-all; do
    n=$(grep -c '<table' "docs/transfer/$p.html" 2>/dev/null)
    check $([ "${n:-0}" = 2 ] && echo 0 || echo 1) "transfer/$p.html has ${n:-0} table(s), expected the two side-by-side per-day tables"
    check $([ "$(grep -c '<h2[^>]*>Duration per day — percentiles' "docs/transfer/$p.html" 2>/dev/null)" = 1 ] && [ "$(grep -c '<h2[^>]*>Duration per day — min / avg / median / max' "docs/transfer/$p.html" 2>/dev/null)" = 1 ] && echo 0 || echo 1) "transfer/$p.html lacks one of the two per-day table headings"
    check $([ "$(grep -c 'class="sxs"' "docs/transfer/$p.html" 2>/dev/null)" -ge 1 ] && echo 0 || echo 1) "transfer/$p.html does not lay its tables out side by side (.sxs)"
    n=$(grep -o 'class="tab[^"]*"[^>]*>[^<]*<' "docs/transfer/$p.html" 2>/dev/null | grep -c 'OK transfers\|All transfers')
    check $([ "${n:-0}" = 2 ] && [ "$(grep -c 'Min/Avg/Max\|>Percentage<' "docs/transfer/$p.html" 2>/dev/null)" = 0 ] && echo 0 || echo 1) "transfer/$p.html button row: ${n:-0} scope buttons, and the Percentage / Min/Avg/Max pair must be gone"
done
check $([ ! -e docs/transfer/duration-minmax.html ] && [ ! -e docs/transfer/duration-all-minmax.html ] && [ ! -e data/transfer/reports/duration-minmax.rpt ] && echo 0 || echo 1) "the Min/Avg/Max sibling pages or .rpts still exist"
dr=$(awk '/<table class="index fit dayrows/ { p = 1 } p && /<tr>/ && /<td/ { print; exit }' docs/index.html 2>/dev/null | grep -o 'data-href="transfer/duration.html?axway_row=[0-9-]*">[^<][^<]*<' | wc -l | tr -d ' ')
check $([ "${dr:-0}" -ge 5 ] && echo 0 || echo 1) "the home page's newest day carries ${dr:-0} filled Duration cells (the extractor must still find the percentiles table)"

# the DATA PERIOD in the top bar (2026-09-13, user request): "yyyy-mm-dd /
# yyyy-mm-dd", the transfer data's first and last day (day.rpt META
# first/last), second after the environment — in the runtime bar data and
# on the baked bar of the help pages
per=$(awk -F'\t' '$1 == "META" && ($2 == "first" || $2 == "last") { v[$2] = substr($3, 1, 10) } END { print v["first"] " / " v["last"] }' data/transfer/reports/day.rpt 2>/dev/null)
check $([ "$per" != " / " ] && [ "$(grep -c "period:\"$per\"" docs/assets/topbar-data.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "topbar-data.js does not carry period:\"$per\""
check $([ "$(grep -c "<span class=\"period\"[^>]*>$per</span><span class=\"entgroup\">" docs/help/index.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "the baked top bar does not show the period '$per' between the brand and Entities"
check $([ "$(grep -c '<a class="brand" href="../index.html">Sample</a><span class="period"' docs/help/index.html 2>/dev/null)" = 1 ] && echo 0 || echo 1) "the baked top bar does not place the period right after the brand"

# the fixed duration axis of the Overview / day-page Duration heroes
# (2026-09-12, user request): the shipped slotchart.js carries the 19-tick
# scale verbatim, 1 s .. >= 48 h
check $([ "$(grep -c '"1 s", "2 s", "3 s", "5 s", "7 s", "10 s", "15 s", "20 s", "25 s", "30 s", "45 s", "1 m", "5 m", "30 m", "1 h", "5 h", "10 h", "24 h", ">= 48 h"' docs/assets/slotchart.js 2>/dev/null)" = 1 ] && echo 0 || echo 1) "slotchart.js does not carry the 19-tick duration scale"

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

# the EventQueue report (2026-09-14, user request): the server-log lines starting "[Pesit Default] Unable to
# submit event AgentEvent" (the sample plants bursts) — the cache, the per-day table and the 30-minute sidecar
# agree, and the main dashboard and the day pages carry the EventQueue chart view
R="data/server/reports/event-queue.rpt"; EQ="data/server/reports/event-queue-slots.tsv"
wn=$(awk -F'\t' 'index($5, "[Pesit Default] Unable to submit event AgentEvent") == 1 { n++ } END { print n + 0 }' data/server/cache/_parse.tsv 2>/dev/null)
dn=$(awk -F'\t' '/^TABLE\t/ { t++ } t == 1 && $1 == "ROW" { n += $3 } END { print n + 0 }' "$R" 2>/dev/null)
sn=$(awk -F'\t' '{ n += $3 } END { print n + 0 }' "$EQ" 2>/dev/null)
check $([ "${wn:-0}" -gt 0 ] && [ "$dn" = "$wn" ] && [ "$sn" = "$wn" ] && echo 0 || echo 1) "event-queue: cache ${wn:-?} line(s), per-day table ${dn:-?}, sidecar ${sn:-?}"
check $([ -f docs/server/event-queue.html ] && [ -f docs/help/server-event-queue.html ] && echo 0 || echo 1) "docs/server/event-queue.html or its help page is missing"
check $(grep -q $'^CARDALT\tEventQueue\t' data/dashboards/reports/overview.rpt 2>/dev/null && echo 0 || echo 1) "the overview dashboard carries no EventQueue chart view"
d=$(awk -F'\t' '{ print $1; exit }' "$EQ" 2>/dev/null)
check $(grep -q $'^CARDALT\tEventQueue\t' "data/day/reports/${d:-none}.rpt" 2>/dev/null && echo 0 || echo 1) "day page ${d:-?} carries no EventQueue chart view"

# its two twins on the shared body bin/server/arlist.sh (2026-09-12, user
# request): "Publish to account failed" (the ARPA0001 lines of the planted
# UC1_ODV_PUBLISH_PIEDPIPER, reason=publishfail) and "Post client action
# error" (the ARRC0009 lines of the planted UC3_CD_NOTARY_BLUTH, pcaerr tag,
# listed per ACCOUNT — the first bracket before the @). Same caps and order.
arlist_checks() {   # $1 basename  $2 entity column  $3 expected entity value (or "")  $4 "File" when the table has a File column
    local R="data/server/reports/$1.rpt" n h want
    n=$(rpt_rows "$R")
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "$1.rpt has 0 rows"
    h=$(awk -F'\t' '$1 == "HEAD" { print; exit }' "$R" 2>/dev/null)
    want=$'HEAD\tDate & time\t'"$2"; [ -n "$4" ] && want="$want"$'\t'"$4"
    check $([ "$h" = "$want" ] && echo 0 || echo 1) "$1.rpt HEAD is '$h', expected '$want'"
    if [ -n "$3" ]; then
        n=$(awk -F'\t' -v E="$3" '$1 == "ROW" { s = $3; sub(/^@\{[^}]*\}/, "", s); if (s == E) n++ } END { print n + 0 }' "$R" 2>/dev/null)
        check $([ "${n:-0}" -gt 0 ] && [ "${n:-0}" -le 10 ] && echo 0 || echo 1) "$1.rpt has ${n:-0} row(s) for the planted $3, expected 1-10"
    fi
    n=$(awk -F'\t' '$1 == "ROW" { s = $3; sub(/^@\{[^}]*\}/, "", s); if (++c[s] > 10) over++ } END { print over + 0 }' "$R" 2>/dev/null)
    check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "$1.rpt: ${n:-?} row(s) beyond the 10-per-entity cap"
    n=$(rpt_rows "$R")
    check $([ "$n" -le 1000 ] && echo 0 || echo 1) "$1.rpt has $n rows, beyond the 1000 cap"
    n=$(awk -F'\t' '$1 == "ROW" { if (p != "" && $2 > p) bad++; p = $2 } END { print bad + 0 }' "$R" 2>/dev/null)
    check $([ "${n:-1}" -eq 0 ] && echo 0 || echo 1) "$1.rpt is not newest-first (${n:-?} row(s) out of order)"
    check $([ -f "docs/server/$1.html" ] && echo 0 || echo 1) "docs/server/$1.html is missing"
}
arlist_checks publish-failed Subscription UC1_ODV_PUBLISH_PIEDPIPER File
if [ "$(exp pcaerr)" -gt 0 ]; then
    # the planted flow's ACCOUNT, as the configuration spells it
    a=$(awk -F'\t' '$1 == "UC3_CD_NOTARY_BLUTH" { print $2; exit }' data/flow-manager/xref/_subscriptions-accounts.tsv 2>/dev/null)
    check $([ -n "$a" ] && echo 0 || echo 1) "UC3_CD_NOTARY_BLUTH has no account in _subscriptions-accounts.tsv"
    arlist_checks post-client-action Account "$a" ""
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
# 2026-09-15 (user request): no row for a reason with nothing counted
z=$(awk -F'\t' '$1 == "ROW" && $3 == "" { n++ } END { print n + 0 }' data/analyses/reports/failing-reasons.rpt 2>/dev/null)
check $([ "${z:-1}" = 0 ] && echo 0 || echo 1) "failing-reasons main table still lists ${z:-?} reason(s) with no count"
dn=$(cat data/analyses/reports/failing-reasons-*.rpt 2>/dev/null | grep -c $'^ROW\t' || true)
check $([ "${dn:-0}" = "${en:-y}" ] && echo 0 || echo 1) "failing-reasons drill pages hold ${dn:-0} row(s), expected every one of the ${en:-?} Files in error"
n=$(ls docs/analyses 2>/dev/null | awk '/^failing-reasons-(history|errors)/ { n++ } END { print n + 0 }')
check $([ "$n" = 0 ] && echo 0 || echo 1) "$n retired Error reasons view page(s) still published"
n=$(grep -c 'tabs undertabs' docs/analyses/failing-reasons.html 2>/dev/null || true)
check $([ "${n:-0}" = 0 ] && [ -f docs/analyses/failing-reasons.html ] && echo 0 || echo 1) "analyses/failing-reasons.html missing or still carries a selector row"
DR=$(ls data/analyses/reports/failing-reasons-*.rpt 2>/dev/null | head -1)
h=$(awk -F'\t' '$1 == "HEAD" { print; exit }' "$DR" 2>/dev/null)
check $([ "$h" = $'HEAD\tSubscription\tDate/time\tCoreId\tFilename' ] && echo 0 || echo 1) "Error reason drill ${DR##*/} HEAD is '$h'"
n=$(grep -c '@data:res=' "$DR" 2>/dev/null || true)
check $([ "${n:-0}" -gt 0 ] && grep -q 'restint' "$DR" 2>/dev/null && echo 0 || echo 1) "Error reason drill ${DR##*/} has no tinted rows"
dp="docs/analyses/$(basename "$DR" .rpt).html"
check $([ "$(grep -c '<meta name="report-dates" content="[0-9]' "$dp" 2>/dev/null || true)" -gt 0 ] && echo 0 || echo 1) "${dp} carries no date list (no From/To fields)"

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
check $([ -f docs/transfer/uc4-to-uc2.html ] && [ -f docs/help/uc4-to-uc2.html ] && echo 0 || echo 1) "docs/transfer/uc4-to-uc2.html or its help page is missing"
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

# the Goodies menu (2026-09-15, user request): Error reasons replaced Failed Subscriptions
g=$(grep -oE 'goodies:"([^"\\]|\\.)*"' docs/assets/topbar-data.js 2>/dev/null)
check $([ -n "$g" ] && printf '%s' "$g" | grep -q 'failing-reasons.html\\">Error reasons' && ! printf '%s' "$g" | grep -q 'Failed Subscriptions' && echo 0 || echo 1) "Goodies menu does not link Error reasons, or still links Failed Subscriptions"

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

if [ "$fails" -eq 0 ]; then
    echo "verify: OK — the sample estate exercises every planted scenario." >&2
else
    echo "verify: $fails assertion(s) FAILED." >&2
    exit 1
fi
