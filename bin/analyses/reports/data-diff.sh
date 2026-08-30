#!/usr/bin/env bash
#
# data-diff.sh — "Since yesterday": what changed in the DATA on the newest
# day (whats-new.html tracks the report CATALOG; this page tracks the logs).
#
# D = the newest calendar day across the two parse caches (transfer
# _files.tsv + server _parse.tsv). Because the exports arrive in batches — a
# flip late yesterday may only be visible in today's export — everything is
# judged against D OR D-1 (the grace day). Five tables:
#
#   New red flips    red subscriptions whose server-log evidence stamp
#                    (blue/_redflip.tsv) or newest FAILING File is on D/D-1
#   Newly quiet      flows whose last File is exactly 8 days before the
#                    transfer window end — the day went-quiet's >7-day rule
#                    first bites (they crossed the threshold within the last
#                    data day)
#   Recovered        green flows whose FIRST OK File after their last failure
#                    is on D/D-1 — broken before, working since yesterday
#   First seen       configured entities whose first-ever File is on D/D-1,
#                    read from the first-seen ledger (data/<env>/first-seen/
#                    <type>-<day>.rpt, written by first-seen.sh)
#   New unknown/blue names   names in the data/<env>/unknown/*.tsv sidecars
#                    (server-log mentions with no transfer) whose mention
#                    timestamp is on D/D-1
#
# Sites are attributed to their configured subscription by the longest
# uppercase prefix match (log-only tails, e.g. _SCP_), like triage.sh.
#
# Reads data/<env>/transfer/cache/_files.tsv, data/<env>/server/cache/
# _parse.tsv (dates only), data/<env>/flow-manager/base/_subscriptions.tsv,
# data/<env>/blue/_redflip.tsv, data/<env>/first-seen/*.rpt and
# data/<env>/unknown/{accounts,logins,sites,hosts,white}.tsv.
# Writes data/<env>/analyses/reports/data-diff.rpt.
#
# Usage:
#   ./data-diff.sh   # reads the caches, writes data/<env>/analyses/reports/data-diff.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

TF="$DATA/transfer/cache/_files.tsv"
SP="$DATA/server/cache/_parse.tsv"
BASE_SUBS="$DATA/flow-manager/base/_subscriptions.tsv"
RFLIP="$DATA/blue/_redflip.tsv"
UNK="$DATA/unknown"
OUT="$REPORTS_DIR/data-diff.rpt"

if [ ! -f "$TF" ] || [ ! -f "$BASE_SUBS" ]; then
    echo "data-diff: transfer cache or config cache missing; skipping." >&2
    exit 0
fi
[ -f "$RFLIP" ] || RFLIP=/dev/null
deps=("$TF" "$BASE_SUBS" "$RFLIP")
[ -f "$SP" ] && deps+=("$SP")
[ -d "$UNK" ] && deps+=("$UNK")
[ -d "$FSRPT_DIR" ] && deps+=("$FSRPT_DIR")
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "${deps[@]}"

# ---- D (newest data day across both caches), G = D-1, transfer window end ----
read -r endj endd <<< "$(awk -F'\t' '$7 + 0 > j { j = $7 + 0; d = $4 } END { print j + 0, d }' "$TF")"
dS=""
# The newest SERVER day: reading it from the 18M-row parse cache cost ~33 s
# of sequential wall time (2026-08-15 build-time regression). The errors-day
# component .rpt carries one ROW per day and the build sequences the server
# reports before analyses, so its max date IS the cache's max date — read
# that instead; the full scan stays as the fallback for a standalone run
# before the server reports exist.
EDRPT="$DATA/server/reports/errors-day.rpt"
if [ -f "$EDRPT" ]; then
    dS=$(awk -F'\t' '$1 == "ROW" && $2 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 > m { m = $2 } END { print m }' "$EDRPT")
fi
[ -z "$dS" ] && [ -f "$SP" ] && dS=$(awk -F'\t' '$1 > m { m = $1 } END { print m }' "$SP")
D="$endd"
[ -n "$dS" ] && [ "$dS" \> "$D" ] && D="$dS"
G=$(awk -v d="$D" 'function jdn(y, m, dd,   a) { a = int((14 - m) / 12); y = y + 4800 - a; m = m + 12 * a - 3
        return dd + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045 }
    BEGIN { split(d, p, "-"); j = jdn(p[1] + 0, p[2] + 0, p[3] + 0) - 1
        a = j + 32044; b = int((4 * a + 3) / 146097); c = a - int(146097 * b / 4)
        e = int((4 * c + 3) / 1461); f = c - int(1461 * e / 4); g = int((5 * f + 2) / 153)
        dd = f - int((153 * g + 2) / 5) + 1; mm = g + 3 - 12 * int(g / 10); yy = 100 * b + e - 4800 + int(g / 10)
        printf "%04d-%02d-%02d", yy, mm, dd }')

# ---- pass 1+2: per-subscription aggregates (the triage.sh attribution) -------
# K <TAB> key <TAB> n <TAB> ok <TAB> err <TAB> lastdate <TAB> lastj <TAB>
# lastfail <TAB> runstart <TAB> runlen <TAB> lastfailts <TAB> lastokts <TAB>
# firstokafter <TAB> okafter
agg=$(awk -F'\t' -v OFS='\t' '
    FILENAME ~ /_subscriptions\.tsv$/ { nc++; CFG[nc] = toupper($1); next }
    $12 == "" || $4 == "" || $7 == "" { next }
    {
        u = toupper($12)
        if (!(u in MAP)) {
            best = ""
            for (i = 1; i <= nc; i++)
                if (length(CFG[i]) > length(best) && index(u, CFG[i]) == 1) best = CFG[i]
            MAP[u] = (best != "") ? best : u
        }
        print MAP[u], $6, $7 + 0, $4, $5, $2
    }
' "$BASE_SUBS" "$TF" \
| LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 \
| awk -F'\t' -v OFS='\t' '
    function flush() {
        if (key == "") return
        print "K", key, n, ok, err, lastdate, lastj, lastfail, runstart, runlen, lastfailts, lastokts, firstokafter, okafter
    }
    $1 != key {
        flush()
        key = $1; n = 0; ok = 0; err = 0; lastdate = ""; lastj = 0; lastfail = 0
        runstart = ""; runlen = 0; lastfailts = ""; lastokts = ""
        firstokafter = ""; okafter = 0
    }
    {
        n++; lastdate = $4; lastj = $3; ts = $4 " " substr($5, 1, 8)
        if ($6 == "Failed" || $6 == "Expired") {
            err++; lastfail = 1; lastfailts = ts
            if (runlen == 0) runstart = ts
            runlen++
            firstokafter = ""; okafter = 0
        } else {
            ok++; lastfail = 0; lastokts = ts; runlen = 0; runstart = ""
            if (lastfailts != "") { if (firstokafter == "") firstokafter = ts; okafter++ }
        }
    }
    END { flush() }
')

# ---- pass 3: the three flow tables -------------------------------------------
#   T1 <TAB> when <TAB> key <TAB> since <TAB> runlen <TAB> n <TAB> ev
#   T2 <TAB> key <TAB> lastdate <TAB> ago <TAB> n <TAB> ev
#   T3 <TAB> when <TAB> key <TAB> failedto <TAB> okafter <TAB> ev
tables=$(printf '%s\n' "$agg" | awk -F'\t' -v OFS='\t' \
    -v D="$D" -v G="$G" -v endj="$endj" '
    FILENAME ~ /_subscriptions\.tsv$/ {
        u = toupper($1); DISP[u] = $1; RES[u] = $3
        if ($3 == "red") { nr++; REDK[nr] = u }
        next
    }
    FILENAME ~ /_redflip\.tsv$/ { FLIP[toupper($1)] = $2; next }
    $1 != "K" { next }
    {
        key = $2; n = $3 + 0; ok = $4 + 0; err = $5 + 0; lastdate = $6; lastj = $7 + 0
        lastfail = $8 + 0; runstart = $9; runlen = $10 + 0; lastfailts = $11
        lastokts = $12; firstokafter = $13; okafter = $14 + 0
        seenk[key] = 1
        res = (key in RES) ? RES[key] : ""
        disp = (key in DISP) ? DISP[key] : key
        # T1 — new red flips
        if (res == "red") {
            stampd = (key in FLIP) ? substr(FLIP[key], 1, 10) : ""
            faild = (lastfailts != "") ? substr(lastfailts, 1, 10) : ""
            if (stampd == D || stampd == G || faild == D || faild == G) {
                when = (stampd == D || stampd == G) ? FLIP[key] : lastfailts
                if (ok == 0)          ev = "never delivered — " err " Error in " n " File(s)"
                else if (runlen > 0)  ev = runlen " consecutive failure(s); last OK " lastokts
                else                  ev = "last File OK (" lastokts ") — server-log evidence after it"
                print "T1", when, disp, (runstart != "" ? runstart : "-"), runlen, n, ev
            }
        }
        # T2 — newly quiet (crossed the >7-day went-quiet rule on the last data day)
        if (endj - lastj == 8)
            print "T2", disp, lastdate, endj - lastj, n, "no traffic since " lastdate " after " n " File(s) — now past the 7-day threshold"
        # T3 — recovered
        if (res == "green" && !lastfail && firstokafter != "") {
            fd = substr(firstokafter, 1, 10)
            if (fd == D || fd == G)
                print "T3", firstokafter, disp, lastfailts, okafter, "failed until " lastfailts ", " okafter " OK File(s) since — " err " Error in the flow'"'"'s history"
        }
    }
    END {
        # a red subscription with no attributed Files: a fresh evidence stamp
        # alone still makes it a new flip
        for (i = 1; i <= nr; i++) {
            u = REDK[i]
            if (u in seenk || !(u in FLIP)) continue
            sd = substr(FLIP[u], 1, 10)
            if (sd == D || sd == G)
                print "T1", FLIP[u], DISP[u], "-", 0, 0, "no Files in the window — server-log evidence only"
        }
    }
' "$BASE_SUBS" "$RFLIP" -)

# ---- T4: first seen, from the first-seen ledger ------------------------------
#   name <TAB> link <TAB> first_ts <TAB> typelabel   (ledger ROW: name dir seen link ts)
t4=$(for typ in partners subscriptions accounts logins hosts; do
    # balanced (pattern) form: a bare `pattern)` inside $(...) trips bash 3.2's parser
    case $typ in
        (partners) lbl="Partner" ;; (subscriptions) lbl="Subscription" ;;
        (accounts) lbl="Account" ;; (logins) lbl="Login" ;; (hosts) lbl="Remote host" ;;
    esac
    for day in "$D" "$G"; do
        f="$FSRPT_DIR/$typ-$day.rpt"
        [ -f "$f" ] || continue
        # "-" placeholder for a missing link: tab counts as IFS WHITESPACE, so
        # bash read would collapse an empty field away and shift the rest
        awk -F'\t' -v OFS='\t' -v lbl="$lbl" '$1 == "ROW" { print $2, ($5 == "" ? "-" : $5), $6, lbl }' "$f"
    done
done || true)

# ---- T5: new unknown/blue names, from the sidecars ---------------------------
#   typelabel <TAB> alinksub <TAB> name <TAB> ts <TAB> message(trimmed)
unk_files=()
for u in accounts logins sites hosts white; do
    [ -f "$UNK/$u.tsv" ] && unk_files+=("$UNK/$u.tsv")
done
t5=""
if [ ${#unk_files[@]} -gt 0 ]; then
    t5=$(awk -F'\t' -v OFS='\t' -v D="$D" -v G="$G" '
        FILENAME ~ /accounts\.tsv$/ { tl = "Account";        as = "accounts" }
        FILENAME ~ /logins\.tsv$/   { tl = "Login";          as = "logins" }
        FILENAME ~ /sites\.tsv$/    { tl = "Subscription";   as = "subscriptions" }
        FILENAME ~ /hosts\.tsv$/    { tl = "Remote host";    as = "hosts" }
        FILENAME ~ /white\.tsv$/    { tl = "Whitelisted IP"; as = "" }
        {
            d = substr($2, 1, 10)
            if (d != D && d != G) next
            msg = $3; gsub(/\r/, "", msg)
            if (length(msg) > 160) msg = substr(msg, 1, 157) "..."
            # "-" placeholder for the linkless types (see the T4 note on IFS)
            print tl, (as == "" ? "-" : as), $1, $2, msg
        }
    ' "${unk_files[@]}")
fi

# ---- assemble the report -----------------------------------------------------
# Row counts up front (the STAT boxes print before the tables); the loops
# below only accumulate the numeric sums. `grep -c` still prints 0 on no
# match — the `|| true` only swallows its exit status under pipefail.
n1=$(printf '%s\n' "$tables" | grep -c $'^T1\t' || true)
n2=$(printf '%s\n' "$tables" | grep -c $'^T2\t' || true)
n3=$(printf '%s\n' "$tables" | grep -c $'^T3\t' || true)
n4=$(printf '%s\n' "$t4" | grep -c . || true)
n5=$(printf '%s\n' "$t5" | grep -c . || true)
s1_run=0; s1_n=0
s2_n=0
s3_ok=0
{
    printf 'TITLE\tSince yesterday\n'
    printf 'DESC\tThe data diff: what changed on the newest data day — fresh red flips, flows that just went quiet, recoveries, first-ever sightings and new unknown names.\n'
    printf 'KEYWORDS\tsince yesterday, diff, changed, new, today, fresh, flips, recovered, first seen, unknown, delta, daily\n'
    printf 'INTRO\tThe newest data day is **%s** (the latest date across the transfer and server parse caches); everything below is judged against **%s or %s** — the exports arrive in batches, so a change late on %s may only surface in the next export. This page diffs the **DATA**; the report catalog'\''s changes live on **What'\''s new**.\n' \
        "$D" "$D" "$G" "$G"

    printf 'STAT\twhite\t%s\tNewest data day\n' "$D"
    printf 'STAT\tred\t%s\tnew red flips\n' "$n1"
    printf 'STAT\torange\t%s\tnewly quiet\n' "$n2"
    printf 'STAT\tgreen\t%s\trecovered\n' "$n3"
    printf 'STAT\twhite\t%s\tfirst seen\n' "$n4"
    printf 'STAT\tblue\t%s\tnew unknown names\n' "$n5"

    # ---- T1 ----
    printf 'TABLE\tNew red flips\twide\tnofilter\tkeephead\n'
    printf 'HEAD\tSubscription\tWhen\tFailing since\tConsecutive failures\tFiles\tEvidence\n'
    printf 'KIND\tsite\ttext\ttext\tnum\tnum\ttext\n'
    while IFS=$'\t' read -r _ when key since runlen n ev; do
        [ -z "$key" ] && continue
        s1_run=$((s1_run + runlen)); s1_n=$((s1_n + n))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$when" "$since" "$runlen" "$n" "$ev"
    done <<< "$(printf '%s\n' "$tables" | grep $'^T1\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2r -k3,3 || true)"
    if [ "$n1" -eq 0 ]; then
        printf 'ROW\t@{colspan=6}Nothing new — no subscription flipped red on %s or %s.\n' "$D" "$G"
    fi
    printf 'TOTAL\tTotal (%s rows)\t\t\t@{class=num}%s\t@{class=num}%s\t\n' "$n1" "$s1_run" "$s1_n"
    printf 'NOTE\tRed subscriptions whose server-log evidence stamp (blue/_redflip.tsv) or newest FAILING File is on **%s** or **%s** — the freshest breakage. A chronically failing flow fails again every day and so stays listed; its old **Failing since** date gives it away. **From green to red** tells each flip'\''s full story.\n' "$D" "$G"

    # ---- T2 ----
    printf 'TABLE\tNewly quiet\tnofilter\n'
    printf 'HEAD\tSubscription\tLast File\tDays ago\tFiles carried\tEvidence\n'
    printf 'KIND\tsite\ttext\tnum\tnum\ttext\n'
    while IFS=$'\t' read -r _ key lastd ago n ev; do
        [ -z "$key" ] && continue
        s2_n=$((s2_n + n))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\n' "$key" "$lastd" "$ago" "$n" "$ev"
    done <<< "$(printf '%s\n' "$tables" | grep $'^T2\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2 || true)"
    if [ "$n2" -eq 0 ]; then
        printf 'ROW\t@{colspan=5}Nothing new — no flow crossed the went-quiet threshold within the last data day.\n'
    fi
    printf 'TOTAL\tTotal (%s rows)\t\t\t@{class=num}%s\t\n' "$n2" "$s2_n"
    printf 'NOTE\tFlows whose last File is exactly **8 days** before the transfer window end (**%s**): **Went quiet** flags a flow once its silence exceeds 7 days, so these crossed that line within the last data day — the freshest silences, before they fade into old news.\n' "$endd"

    # ---- T3 ----
    printf 'TABLE\tRecovered\tnofilter\n'
    printf 'HEAD\tSubscription\tRecovered\tFailed until\tOK since recovery\tEvidence\n'
    printf 'KIND\tsite\ttext\ttext\tnum\ttext\n'
    while IFS=$'\t' read -r _ when key failedto okafter ev; do
        [ -z "$key" ] && continue
        s3_ok=$((s3_ok + okafter))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\n' "$key" "$when" "$failedto" "$okafter" "$ev"
    done <<< "$(printf '%s\n' "$tables" | grep $'^T3\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2r -k3,3 || true)"
    if [ "$n3" -eq 0 ]; then
        printf 'ROW\t@{colspan=5}Nothing new — no broken flow came back on %s or %s.\n' "$D" "$G"
    fi
    printf 'TOTAL\tTotal (%s rows)\t\t\t@{class=num}%s\t\n' "$n3" "$s3_ok"
    printf 'NOTE\tGreen flows whose FIRST OK File after their last failure is on **%s** or **%s**: they were failing, and started working again since yesterday. Waiting counts as OK, Expired as Error — the site-wide outcome policy.\n' "$D" "$G"

    # ---- T4 ----
    printf 'TABLE\tFirst seen\tnofilter\n'
    printf 'HEAD\tType\tName\tDate\tEvidence\n'
    printf 'KIND\ttext\ttext\ttext\ttext\n'
    while IFS=$'\t' read -r name link ts lbl; do
        [ -z "$name" ] && continue
        if [ "$link" != "-" ]; then
            printf 'ROW\t%s\t@{link=%s}%s\t%s\tfirst-ever File at %s\n' "$lbl" "$link" "$name" "${ts%% *}" "$ts"
        else
            printf 'ROW\t%s\t%s\t%s\tfirst-ever File at %s\n' "$lbl" "$name" "${ts%% *}" "$ts"
        fi
    done <<< "$(printf '%s\n' "$t4" | grep . | LC_ALL=C sort -t"$(printf '\t')" -k3,3r -k4,4 -k1,1 || true)"
    if [ "$n4" -eq 0 ]; then
        printf 'ROW\t@{colspan=4}Nothing new — no configured entity carried its first-ever File on %s or %s.\n' "$D" "$G"
    fi
    printf 'TOTAL\tTotal (%s rows)\t\t\t\n' "$n4"
    printf 'NOTE\tConfigured partners, subscriptions, accounts, logins and remote hosts whose FIRST-EVER File is on **%s** or **%s**, read from the first-seen ledger (the same per-day cells behind the **First seen** analysis). A name'\''s first sighting is a one-off event — it appears here once and then only lives on that page.\n' "$D" "$G"

    # ---- T5 ----
    printf 'TABLE\tNew unknown/blue names\twide\tnofilter\n'
    printf 'HEAD\tType\tName\tMentioned\tEvidence\n'
    printf 'KIND\ttext\ttext\ttext\ttext\n'
    while IFS=$'\t' read -r lbl asub name ts msg; do
        [ -z "$name" ] && continue
        if [ "$asub" != "-" ]; then
            printf 'ROW\t%s\t@{alink=%s/%s}%s\t%s\t%s\n' "$lbl" "$asub" "$name" "$name" "$ts" "$msg"
        else
            printf 'ROW\t%s\t%s\t%s\t%s\n' "$lbl" "$name" "$ts" "$msg"
        fi
    done <<< "$(printf '%s\n' "$t5" | grep . | LC_ALL=C sort -t"$(printf '\t')" -k4,4r -k3,3 || true)"
    if [ "$n5" -eq 0 ]; then
        printf 'ROW\t@{colspan=4}Nothing new — no server-log-only name surfaced on %s or %s.\n' "$D" "$G"
    fi
    printf 'TOTAL\tTotal (%s rows)\t\t\t\n' "$n5"
    printf 'NOTE\tNames the server log mentions with NO transfer of their own (the data/unknown sidecars — the same set that seeds the blue result colour) whose newest mention is on **%s** or **%s**. A configured name here is blue (server-seen, never transferred); an unconfigured one is a stranger knocking — **Seen in server log** has the full lists.\n' "$D" "$G"

    printf 'SUMMARY\tSince yesterday (%s/%s): %s red flip(s), %s newly quiet, %s recovered, %s first seen, %s new unknown name(s)\n' \
        "$D" "$G" "$n1" "$n2" "$n3" "$n4" "$n5"
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (D=$D: $n1 flip(s), $n2 quiet, $n3 recovered, $n4 first-seen, $n5 unknown)." >&2
