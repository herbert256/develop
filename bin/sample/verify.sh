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
    # the MULTI-FE account (2026-08-31, user report): CD-PARCEL-BLUTH carries
    # TWO logins; its quiet second flow (its own login, never used) must read
    # Nothing — never "No files": the other login's logons are no pickup
    # evidence for it (uc2-status login scoping)
    if [ "$env" = production ]; then
        n=$(awk -F'\t' '$1=="CD-PARCEL-BLUTH"' "data/$env/flow-manager/xref/_accounts-logins.tsv" 2>/dev/null | wc -l | tr -d ' ')
        check $([ "${n:-0}" -eq 2 ] && echo 0 || echo 1) "[$env] CD-PARCEL-BLUTH has $n login(s), expected 2 (the multi-FE account)"
        st=$(awk -F'\t' '$1=="ROW" && index($0, "UC2_CD_PARCELX_BLUTH") { s=$2; sub(/^@\{[^}]*\}/, "", s); print s; exit }' "data/$env/server/reports/uc2-status.rpt" 2>/dev/null)
        check $([ "$st" = "Nothing" ] && echo 0 || echo 1) "[$env] UC2_CD_PARCELX_BLUTH uc2-status is '${st:-absent}', expected Nothing (multi-FE login scoping)"
        # ... and entity-coverage: the quiet flow's own application PARCELX
        # must be NOT covered (red) — login A's logons are no In-side proof
        # for login B's flow — while PARCEL (flow A) is covered
        st=$(awk -F'\t' '$1=="ROW" && $2=="PARCELX" { print ($0 ~ /@data:res=red/) ? "red" : "notred"; exit }' "data/$env/transfer/reports/entity-coverage.rpt" 2>/dev/null)
        check $([ "$st" = "red" ] && echo 0 || echo 1) "[$env] entity-coverage PARCELX is '${st:-absent}', expected red / not covered (multi-FE logon-proof scoping)"
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
    for pf in blacklist.txt skip.txt rename.txt logical.txt logical_domains.txt logical_apps.txt logical_partners.txt BL.txt partner-aliases.tsv; do
        check $([ -f "input/$env/$pf" ] && echo 0 || echo 1) "[$env] input/$env/$pf missing"
        check $([ ! -e "input/$pf" ] && echo 0 || echo 1) "input/$pf still at the input root (per-environment since 2026-08-31)"
    done
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

# the failing-reasons catalogue: every planted category non-empty (acceptance)
FR="data/acceptance/transfer/reports/failed-sub-all.rpt"
for reason in "Connection failures" "Wrong server fingerprint" "No Dir" "Listing failed" \
              "Login errors (out)" "Route stopped" "Transfer site missing" "Receive File As not set" \
              "PeSIT transfer aborted" "PeSIT delivery refused" "Staged file missing" \
              "File Tracking entry missing" "Remote file unavailable" "Post-action failed" \
              "Pull via FTPS failed"; do
    n=$(grep -l -- "$reason" data/acceptance/transfer/reports/failed*.rpt data/acceptance/transfer/reports/errors/*.rpt 2>/dev/null | wc -l | tr -d ' ')
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[acceptance] reason \"$reason\" appears in no failed/error report"
done

if [ "$fails" -eq 0 ]; then
    echo "verify: OK — the sample estate exercises every planted scenario." >&2
else
    echo "verify: $fails assertion(s) FAILED." >&2
    exit 1
fi
