#!/usr/bin/env bash
#
# went-kaput.sh — "Went kaput": subscriptions whose LAST transfer SUCCEEDED but
# that then logged an Error/Warning in the SERVER log after that transfer, for
# the subscription itself OR a connected login/account. A "something went wrong
# after we last succeeded" signal per subscription.
#
# Sources (no _parse.tsv scan of its own — it reads the caches the parse built):
#   - $TRANSFER_CACHE/_files.tsv (transfer, cross-area): the LAST transfer per
#     subscription (max sortkey; col 12 dest_site is the clean subscription name,
#     the same string the server per-name caches are keyed by) and its outcome
#     (last outcome not Failed/Expired = OK; Waiting counts as OK, Expired as Error — 2026-07 policy).
#   - the server per-name Error/Warn caches
#     $CACHE_DIR/{subscriptions,accounts,logins}/<name>_err_warn.tsv
#     (bin/server/parse.sh; the "Skipping the next scheduled occurrence of this
#     task." poll-backlog warnings are already excluded from those rings).
#   - $CONFIG_BASE/_subscriptions.tsv: the RESULT COLOUR per subscription
#     (bin/build/result.sh's third column) — only the greens are listed.
#   - $CONFIG_XREF/_subscriptions-{accounts,logins,hosts}.tsv: the connected
#     account(s)/login(s)/host(s) for each subscription (usually one each).
#     The HOST ring joins only when the subscription has exactly ONE configured
#     host (2026-08); the endpoint's forward addresses (input/<env>/ip/
#     ip-hosts.tsv) carry rings of their own and count the same way. NOTE this
#     page is an EARLY WARNING and deliberately looser than the colour step:
#     bin/build/result.sh's after-last-transfer RED FLIP counts only the
#     connected-ring lines _build_ringattr pins on THIS flow, while this page
#     joins the 1-to-1 connected rings wholesale — the Source column says which
#     entity logged each line, and the reader judges.
#
# A subscription is listed when its last transfer was OK AND at least one
# Error/Warn line — its own or a connected login's/account's/host's — is dated AFTER
# that transfer AND the flow is STILL GREEN (2026-08). That last condition is
# what keeps the page an EARLY WARNING: this same evidence is what
# bin/build/result.sh's after-last-transfer rule reds a flow on, so a
# subscription the evidence already reddened is not "trouble after success"
# any more, it is simply failing — and the HOME page lists every red flow with
# its reason. What is left here is the useful half: flows that still count as
# healthy but have started logging errors.
#
# The evidence for the RED ones is not thrown away, it just leaves by another
# door: $REPORTS_DIR/_kaput-evidence.tsv carries one line per subscription with
# post-transfer errors, green or not (name, latest issue, source, message,
# newest E-level message), and
# bin/analyses/publish-insights.sh reads it to name the fault behind a red flow
# in the home page's Reason column. Since 2026-08-22 the same evidence FLIPS
# the flow red (bin/build/result.sh _build_kaputflip — the loose connected-
# ring join promoted to the colour, deploy-classified flows excluded, the UC3
# clean-poll keep applied), so a trouble-after-success flow normally arrives
# on the home "Failing subscriptions in Server log" table RED and leaves this
# page through the still-green filter; what stays here is the deploy-
# classified and poll-cleared remainder. bin/build/publish.sh's green-row
# path remains as a safety net for any green candidate the flip did not take. NOTE a connected account serves other flows too, so an account
# Error/Warn need not be about THIS subscription; the Source column says which
# entity logged it, and the click-to-expand drill shows the lines.
#
# Usage:
#   ./went-kaput.sh   # writes data/went-kaput.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SERVER lib, not the analyses one: this is a server-DATA report (it reads the
# server parse cache and writes data/<env>/server/reports/). It lives HERE
# because its page sits in the ANALYSES menu, in the Subscriptions group — the
# same arrangement as cross-reference.sh. bin/server/reports.sh still runs it.
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/went-kaput.rpt"

FILES="$TRANSFER_CACHE/_files.tsv"
SA="$CONFIG_XREF/_subscriptions-accounts.tsv"
SL="$CONFIG_XREF/_subscriptions-logins.tsv"
SH="$CONFIG_XREF/_subscriptions-hosts.tsv"
SUBRES="$CONFIG_BASE/_subscriptions.tsv"
EVID="$REPORTS_DIR/_kaput-evidence.tsv"
IPH="$ROOT/input/$AXWAY_ENV/ip/ip-hosts.tsv"
# the DERIVED use case map: a production hybrid flow carries no UC prefix, so
# "is this a UC3" must ask the config, not the name (2026-08-31 audit)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ] || [ ! -s "$FILES" ]; then
    echo "No server input / no transfer cache for this env — page not published." >&2
    rm -f "$OUT"   # env-split legitimate state: nothing to report
    exit 0
fi
ensure_config
# Rebuild when the transfer cache, the server err/warn rings (the server
# _subscriptions.tsv mention cache is a representative — rewritten in the same
# parse pass as the per-name dirs), the connection maps, or this script change.
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FILES" "$CACHE_DIR/_subscriptions.tsv" "$SA" "$SL" "$SH" "$SUBRES"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# 1) the LAST transfer per subscription (max sortkey), keeping only those whose
#    last transfer was OK (Processed). -> "subscription <TAB> date time", name-
#    sorted (C collation) so step 2 emits its ROW lines deterministically.
lastokf="$REPORTS_DIR/.sublogfail.lastok.$$"
rowfile="$REPORTS_DIR/.sublogfail.$$"; : > "$rowfile"
pollf="$REPORTS_DIR/.uc3polls.$$"
trap 'rm -f "$rowfile" "$lastokf" "$pollf"' EXIT

# THE UC3 CLEAN-POLL CLEAR (2026-08-22): a UC3 whose newest SUCCESSFUL poll
# ("Applying the search pattern … N file(s) …") is no older than its newest
# E-level evidence has VERIFIED itself working since the error — the same
# evidence bin/build/result.sh trusts to keep a would-be-red UC3 green — so it
# is not "trouble after success" any more and is skipped: off this page AND
# off the evidence sidecar (the home early-warning table reads that), counted
# in the INTRO like the red ones. Newest poll stamp per UC3, from the per-name
# MENTION caches (the same scan result.sh's POLLCAND uses; the _err_warn ring
# is the ERROR ring, not the mention cache).
{
    # UC3-named OR derived-UC3 flows (see UCDF)
    if [ -d "$CACHE_DIR/subscriptions" ]; then
        { awk -F'\t' '$1 ~ /^UC3/ { print $1 }' "$SUBRES"
          awk -F'\t' '$2 == "UC3" { print $1 }' "$UCDF"
          :; } 2>/dev/null | LC_ALL=C sort -u | while IFS= read -r _n; do
            _pf="$CACHE_DIR/subscriptions/$_n.tsv"
            [ -f "$_pf" ] || continue
            awk -F'\t' -v n="$(basename "$_pf" .tsv)" '
                $5 ~ /Applying the search pattern/ && $5 ~ /for transfer site/ && $5 ~ /file\(s\)/ { t = $1 " " $2; if (t > p) p = t }
                END { if (p != "") printf "%s\t%s\n", n, p }
            ' "$_pf"
        done
    fi
} > "$pollf"
awk -F'\t' '
    $12 != "" { if (!($12 in mk) || $6 > mk[$12]) { mk[$12]=$6; dt[$12]=$4" "$5; oc[$12]=$2 } }
    END { for (s in mk) if (oc[s] != "Failed" && oc[s] != "Expired") print s "\t" dt[s] }
' "$FILES" | LC_ALL=C sort > "$lastokf"

# 2) ONE awk pass collects, per subscription, the Error/Warn lines (its own +
#    connected login/account caches) dated AFTER its last transfer. It used to
#    be a bash loop forking two awk|sort map lookups plus a per-sub awk over
#    its candidate rings (~5 forks x ~200 subscriptions); now a single awk
#    reads, in ARGV order: the last-OK cut file, the two connection maps
#    (keeping account->subscription(s) / login->subscription(s) only for
#    subscriptions in the cut file, pairs deduped like the old `sort -u`),
#    then EVERY per-name Error/Warn ring — subscriptions first, then accounts,
#    then logins, names C-sorted within a type, which reproduces the old
#    per-sub candidate order, so the first occurrence still wins the line
#    dedup and the latest-issue tie. Emits the ROW lines (with the \x1f-joined
#    last-10 drill) to $rowfile plus one TOTALS line on stdout for bash.
rings=()
add_rings() {   # $1 = the per-name cache subdir
    local d="$CACHE_DIR/$1" n
    [ -d "$d" ] || return 0
    while IFS= read -r n; do
        if [ -n "$n" ]; then rings+=("$d/${n}_err_warn.tsv"); fi
    done < <(shopt -s nullglob; cd "$d" && printf '%s\n' *_err_warn.tsv | sed 's/_err_warn\.tsv$//' | LC_ALL=C sort)
}
add_rings subscriptions
add_rings accounts
add_rings logins
add_rings hosts

mapargs=()
[ -f "$SUBRES" ] && mapargs+=("$SUBRES")
mapargs+=("$pollf")
mapargs+=("$lastokf")
[ -f "$SA" ] && mapargs+=("$SA")
[ -f "$SL" ] && mapargs+=("$SL")
[ -f "$SH" ] && mapargs+=("$SH")
[ -f "$IPH" ] && mapargs+=("$IPH")

totals=$(awk -F'\t' -v lastokf="$lastokf" -v saf="$SA" -v slf="$SL" -v shf="$SH" -v iphf="$IPH" -v rowfile="$rowfile" -v subres="$SUBRES" -v pollf="$pollf" -v evid="$EVID.tmp" -v ucdf="$UCDF" "$LOGLINES_AWK"'
    BEGIN { while ((getline l9 < ucdf) > 0) { n9 = split(l9, a9, "\t"); if (n9 >= 2 && a9[2] == "UC3") ucd3[toupper(a9[1])] = 1 } close(ucdf) }
    function srcof(f) { return (f ~ /\/subscriptions\//) ? "Subscription" : (f ~ /\/accounts\//) ? "Account" : (f ~ /\/hosts\//) ? "Host" : "Login" }
    # the subscriptions this host ring speaks for: every single-host flow whose
    # host is this endpoint, or an endpoint this ADDRESS forwards to (hmap is
    # built once, on the first host ring, since the maps are all read by then)
    function hostsubs(h,   i, s, k, n) {
        if (!hmapdone) { hmapdone = 1
            for (s in nhost) if (nhost[s] == 1) hm[vhost[s]] = hm[vhost[s]] "\t" s
            for (k in fwd) { n = split(substr(fwd[k], 2), F, "\t")
                for (i = 1; i <= n; i++) if (F[i] != "" && (k in hm)) hm[tolower(F[i])] = hm[tolower(F[i])] hm[k] } }
        return (h in hm) ? split(substr(hm[h], 2), tgt, "\t") : 0 }
    # the result colour: only a GREEN flow is listed (see the header)
    FILENAME == subres { if ($1 != "" && NF >= 3) col[toupper($1)] = $3; next }
    # the UC3 clean-poll stamps (see the builder above)
    FILENAME == pollf { if ($1 != "") pol[toupper($1)] = $2; next }
    FILENAME == lastokf { cut[$1] = $2; order[++nsub] = $1; next }
    FILENAME == saf { if (($1 in cut) && $2 != "" && !pa[$1,$2]++) amap[$2] = (amap[$2] != "" ? amap[$2] "\t" : "") $1; next }
    FILENAME == slf { if (($1 in cut) && $2 != "" && !pl[$1,$2]++) lmap[$2] = (lmap[$2] != "" ? lmap[$2] "\t" : "") $1; next }
    # subscription -> host, kept only while the subscription has exactly ONE
    # (result.sh reds on the same restriction: with two hosts configured, a
    # ring cannot be attributed to this flow)
    FILENAME == shf { if (($1 in cut) && $2 != "" && !ph[$1,$2]++) { nhost[$1]++; vhost[$1] = tolower($2) }; next }
    # endpoint -> its forward addresses: those rings are the same evidence
    FILENAME == iphf { if ($1 != "" && $2 != "") fwd[tolower($2)] = fwd[tolower($2)] "\t" $1; next }
    {
        if (FILENAME != curf) {                       # a new ring file: which subscription(s) own it?
            curf = FILENAME; csrc = srcof(curf)
            nm = curf; sub(/^.*\//, "", nm); sub(/_err_warn\.tsv$/, "", nm)
            if (csrc == "Subscription") { ntgt = 0; if (nm in cut) { ntgt = 1; tgt[1] = nm } }
            else if (csrc == "Account") ntgt = (nm in amap) ? split(amap[nm], tgt, "\t") : 0
            else if (csrc == "Host")    ntgt = hostsubs(tolower(nm))
            else                        ntgt = (nm in lmap) ? split(lmap[nm], tgt, "\t") : 0
        }
        if (ntgt == 0) next
        dt = $1 " " $2
        for (i = 1; i <= ntgt; i++) {
            s = tgt[i]
            if (dt <= cut[s]) continue                # only lines AFTER the last OK transfer count
            if (seen[s, $1, $2, $3, $4, $5]++) continue   # a line named under two caches counts once
            # TWO evidence sets since 2026-08. The PAGE is ERROR-only — a
            # warning is not "trouble" (the W-only shape was the benign
            # "Transfer site ID is not present in environment", which has its
            # own report now) — so the row columns, the Source list, the
            # Latest issue and the drill all read the E-level facts. The
            # EVIDENCE SIDECAR keeps BOTH levels: the home Reason walks it
            # (newest E line preferred), and a warnings-only candidate must
            # stay nameable even though a Warning no longer flips a flow red
            # (bin/build/result.sh, errors-only since 2026-08).
            has[s, csrc] = 1
            if (dt > ldt[s]) { ldt[s] = dt; lm[s] = $5 }  # strictly greater: first occurrence wins ties
            if ($3 == "E") {
                ne[s]++
                hasE[s, csrc] = 1
                if (dt > ldtE[s]) { ldtE[s] = dt; lmE[s] = $5 }
                addline(s, dt, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
            } else nw[s]++
        }
    }
    END {
        # deterministic source order (no hash-iteration dependence)
        split("Subscription Account Login Host", ord, " ")
        for (i = 1; i <= nsub; i++) {
            s = order[i]
            if (ne[s] + nw[s] == 0) continue          # nothing after the last transfer: no candidate
            # the UC3 CLEAN-POLL CLEAR, greens only and BEFORE the evidence
            # line, so the home early-warning table (fed by the sidecar) skips
            # the flow too: a successful poll no older than the newest error
            # means the flow has verified itself working since — the same
            # >= comparison result.sh trusts to keep a would-be-red UC3 green.
            # Red flows keep their evidence unconditionally (the home Reason).
            if (ne[s] > 0 && col[toupper(s)] == "green" && (toupper(s) ~ /^UC3/ || (toupper(s) in ucd3)) \
                && (toupper(s) in pol) && pol[toupper(s)] >= ldtE[s]) { npoll++; continue }
            ss = ""
            for (j = 1; j <= 4; j++) if (has[s, ord[j]]) ss = ss (ss == "" ? "" : ", ") ord[j]
            # the evidence sidecar carries EVERY candidate, whatever its colour
            # or LEVEL: the home page names the fault behind a red flow from it.
            # Column 5 is the newest E-LEVEL message ("" when only warnings
            # followed): the Reason prefers a real error over a benign warning
            # that merely happens to be newer.
            printf "%s\t%s\t%s\t%s\t%s\n", s, ldt[s], ss, substr(lm[s], 1, 200), substr(lmE[s], 1, 200) > evid
            if (ne[s] == 0) continue                  # warnings only: not an error signal, no row
            if (col[toupper(s)] != "green") { nred++; continue }   # already red: not a warning any more
            ssE = ""
            for (j = 1; j <= 4; j++) if (hasE[s, ord[j]]) ssE = ssE (ssE == "" ? "" : ", ") ord[j]
            # ROW: Subscription | Last OK transfer | Errors after | Latest error | Source | Latest message  (+ drill)
            printf "ROW\t%s\t%s\t%d\t%s\t%s\t%s\t@data:loglines=%s\n",
                s, cut[s], ne[s]+0, ldtE[s], ssE, substr(lmE[s], 1, 200), lastlines(s) >> rowfile
            nrows++; terr += ne[s]
        }
        close(evid)
        printf "TOTALS\t%d\t%d\t%d\t%d\n", nrows+0, terr+0, nred+0, npoll+0
    }
' "${mapargs[@]}" ${rings[@]+"${rings[@]}"})
IFS=$'\t' read -r _tag nrows terr nred npoll <<< "$totals"
# the evidence sidecar is cmp-guarded: an unchanged one keeps its mtime, so the
# analyses publish that reads it does not rebuild for nothing
if [ -f "$EVID.tmp" ]; then
    LC_ALL=C sort -o "$EVID.tmp" "$EVID.tmp"
    if cmp -s "$EVID.tmp" "$EVID" 2>/dev/null; then rm -f "$EVID.tmp"; else mv "$EVID.tmp" "$EVID"; fi
else
    : > "$EVID.tmp" && mv "$EVID.tmp" "$EVID"
fi

# 3) write the .rpt (sorted by Latest error, newest first — ROW field 5)
{
    printf 'TITLE\tTrouble after Success\n'
    printf 'DESC\tStill-GREEN subscriptions whose last transfer succeeded but which then logged a server-log ERROR — for the subscription or a connected login, account or remote host. Warnings do not count.\n'
    printf 'KEYWORDS\tsubscription,error,warning,after last transfer,post-transfer,server log,failing,login,account,kaput,went kaput\n'
    printf 'INTRO\tSubscriptions whose **last transfer was OK** but which then logged an **Error** in the server log **after** that transfer — either the subscription itself or a connected login, account or remote host. A recent problem on a flow that last looked healthy. **Errors only** (2026-08): a Warning does not put a flow on this page — the warnings-only shape was the benign "Transfer site ID is not present in environment", which has its own report in this group.\n'
    printf 'INTRO\t**Still green only.** The same evidence is what turns a flow RED site-wide, so a subscription this page would name that has already gone red is not an early warning any more — it is simply failing, and the **home page** lists every red flow with its reason. What is left here is the useful half: flows that still count as healthy and have started logging errors.%s%s\n' \
        "$( [ "${nred:-0}" -gt 0 ] && printf ' **%s** subscription(s) were left out this run for being red already.' "$nred" || printf '' )" \
        "$( [ "${npoll:-0}" -gt 0 ] && printf ' **%s** UC3 subscription(s) were cleared by a successful poll no older than their newest error — "0 file(s) were found" is the flow verifying itself working, the same evidence that keeps a UC3 green site-wide.' "$npoll" || printf '' )"
    if [ "$nrows" -eq 0 ]; then
        printf 'TABLE\tSubscriptions failing after last successful transfer\tnosort\tnofilter\n'
        printf 'HEAD\tSubscription\tLast OK transfer\tErrors after\tLatest error\tSource\tLatest message\n'
        printf 'KIND\tsite\ttext\tnumfailed\ttext\ttext\ttext\n'
        printf 'ROW\t(none)\t\t\t\t\t\n'
    else
        printf 'TABLE\tSubscriptions failing after last successful transfer\twide\tnofilter\n'
        printf 'HEAD\tSubscription\tLast OK transfer\tErrors after\tLatest error\tSource\tLatest message\n'
        printf 'KIND\tsite\ttext\tnumfailed\ttext\ttext\ttext\n'
        LC_ALL=C sort -t"$(printf '\t')" -k5,5r "$rowfile"
        printf 'TOTAL\tTotal (%d subscription(s))\t\t%d\t\t\t\n' "$nrows" "$terr"
    fi
    printf 'NOTE\tSource: the server per-name Error/Warn caches for the subscription and its connected login(s), account(s) and remote host — the host only where the flow has exactly ONE configured, the same restriction the result colours use. Only **E-level** lines count and are shown; warnings are ignored. A connected account or host serves other flows too, so its Error need not concern this subscription — the Source column names the entity that logged it. Poll-backlog warnings ("Skipping the next scheduled occurrence of this task.") are excluded. Click a row to expand its 10 most recent Error/Warning lines.\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Wrote $OUT ($nrows subscription(s), $terr error(s) after last OK transfer; warnings do not list)." >&2
