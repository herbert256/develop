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
              "File Tracking entry missing" "Remote file unavailable" "Post-action failed"; do
    n=$(grep -l -- "$reason" data/acceptance/transfer/reports/failed*.rpt data/acceptance/transfer/reports/errors/*.rpt 2>/dev/null | wc -l | tr -d ' ')
    check $([ "$n" -gt 0 ] && echo 0 || echo 1) "[acceptance] reason \"$reason\" appears in no failed/error report"
done

if [ "$fails" -eq 0 ]; then
    echo "verify: OK — the sample estate exercises every planted scenario." >&2
else
    echo "verify: $fails assertion(s) FAILED." >&2
    exit 1
fi
