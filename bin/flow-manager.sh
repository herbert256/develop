#!/usr/bin/env bash
#
# flow-manager.sh — the PRE-PARSE step. Extracts the configured entity lists from the
# two FlowManager config exports into the data/flow-manager/base/ caches — EVERY
# base file is "name<TAB>direction" (in / both / out; empty = unclassifiable;
# see the direction section at the bottom) — so parse.sh and the reports can
# read a flat list instead of re-parsing JSON each time:
#
#   input/flow-manager/partners.json      -> data/flow-manager/base/_accounts.tsv   (partner names)
#                                      data/flow-manager/base/_logins.tsv     (comm-profile login)
#                                      data/flow-manager/base/_hosts.tsv      (comm-profile hosts[] values)
#                                      data/flow-manager/base/_white.tsv      (customAttributes AllowIP1-10 — the IP whitelist)
#   input/flow-manager/subscriptions.json -> data/flow-manager/base/_subscriptions.tsv (subscription names)
#                                      data/flow-manager/base/_profiles.tsv   (customAttribute_FlowIdentifier)
#
# ... plus the CROSS-REFERENCE caches under data/flow-manager/xref/: EVERY pair of
# the nine items, BOTH WAYS — data/flow-manager/xref/_<a>-<b>.tsv AND _<b>-<a>.tsv
# (two TAB-separated columns, column 1 = the item the file is named-first
# for; the mirror is the column-swapped twin). A pair not actually
# configured is an empty file, so e.g.
# _subscriptions-hosts.tsv holds only OUTBOUND subscriptions (only a SERVER
# comm profile — ST connecting out to the partner — carries hosts[]), and
# _subscriptions-logins.tsv only inbound ones (a CLIENT/LOGIN profile — the
# partner authenticating into ST — carries a login). Derivations:
#
#   within one partner object (partners.json):
#     _accounts-logins.tsv   partner name x its comm-profile logins
#     _accounts-hosts.tsv    partner name x its SERVER comm-profile hosts[]
#     _accounts-white.tsv    partner name x its expanded AllowIP whitelist
#     _logins-hosts.tsv      same-partner login x host
#     _logins-white.tsv      same-partner login x whitelist IP
#     _hosts-white.tsv       same-partner host x whitelist IP
#   within one subscription (subscriptions.json; the participant comProfileId
#   is resolved against the partner comm profiles — every ref that resolves
#   belongs to the participant's own partner, validated 570/570):
#     _accounts-subscriptions.tsv  non-APPLICATION participant x subscription
#     _subscriptions-profiles.tsv  subscription x customAttribute_FlowIdentifier
#     _subscriptions-logins.tsv    subscription x comm-profile login   (inbound)
#     _subscriptions-hosts.tsv     subscription x comm-profile hosts   (outbound)
#     _accounts-profiles.tsv       participant x FlowIdentifier
#     _profiles-logins.tsv         FlowIdentifier x comm-profile login
#     _profiles-hosts.tsv          FlowIdentifier x comm-profile hosts
#   joined on the account (subscription -> partner -> whitelist):
#     _subscriptions-white.tsv     subscription x its partner's whitelist
#     _profiles-white.tsv          FlowIdentifier x its partner's whitelist
#
# ... plus three ATTRIBUTE maps (not cross references):
#     _subscriptions-patterns.tsv  subscription x its patternName — the raw
#                                  pattern id string; bin/transfer/parse.sh's
#                                  reverse config fallback derives the pesit
#                                  direction (IN/OUT) from it.
#     _subscriptions-flowdir.tsv   subscription x its FILE-MOVEMENT direction:
#                                  "out" (parameters.source_folder_monitoring_
#                                  scan_dir set — the file leaves us), "in"
#                                  (target_working_dir set — it enters us),
#                                  else "relay". Feeds _files.tsv col 17
#                                  (movement), details.sh's Latest-100
#                                  Direction column and last-file's Movement.
#     _templates.tsv               the flow-template catalog (from the OPTIONAL
#                                  input/flow-manager/templates.json): name, UC
#                                  token, status, flowPatternName (= the
#                                  subscriptions' patternName), FlowManager
#                                  href, last-modified date. Read by the
#                                  Use-cases analyses pages.
#
# ... plus the three PDA entities (base/_partners, _apps, _domains.tsv — each
# "name<TAB>direction" with direction in/both/out; see the PDA section below)
# and their cross references against the other entities, all joined via the
# account: accounts/subscriptions/profiles/logins/hosts x partners/apps/
# domains, partners-apps/partners-domains/apps-domains, and the *-white joins.
#
# The whole set is rebuilt in one go, and the run EARLY-EXITS when every output
# is newer than both exports and this script — bin/build.sh calls flow-manager.sh
# unconditionally each run (and every report's ensure_config leans on it), and
# the parse stage watches these cache mtimes, so a no-change run must not
# rewrite them.
#
# Each output is distinct sorted lines. The JSON exports are parsed with jq (by
# PATH, not by indentation): the entity lists, the FlowManager deep links and the
# cross-reference pair stream. Downstream, the whitelist IP-pattern expansion and
# the PDA derivation stay bash + awk (they read the extracted caches, not JSON).
#
# Usage:  bin/flow-manager.sh    (run before bin/transfer/parse.sh + bin/server/parse.sh)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed (see bin/fastawk.sh)
source "$ROOT/bin/env.sh"       # resolve $AXWAY_ENV (acceptance|production, default acceptance)
IP_DIR="$ROOT/input/$AXWAY_ENV/ip"                 # PER ENV (the two estates share no endpoints)
source "$ROOT/bin/ip.sh"        # IP_HOSTS_FILE (input/<env>/ip/ip-hosts.tsv) + ip_put
source "$ROOT/bin/renames.sh"  # RENAMES_FILE (input/<env>/renames/) + fm_snapshot_renames
OUT="$ROOT/data/$AXWAY_ENV/flow-manager"
# The two FlowManager config exports. Like the log CSVs they live under the
# gitignored input/ root and are NOT in git — a fresh clone needs them dropped
# into input/<env>/flow-manager/ before the configured lists (and the parse
# fallback) exist.
PARTNERS="$ROOT/input/$AXWAY_ENV/flow-manager/partners.json"
SUBS="$ROOT/input/$AXWAY_ENV/flow-manager/subscriptions.json"
# The flow-template catalog export is OPTIONAL — without it xref/_templates.tsv
# is written empty and the Use-cases analyses degrade (no template table, no
# zero-subscription UC rows).
TEMPLATES="$ROOT/input/$AXWAY_ENV/flow-manager/templates.json"

[ -f "$PARTNERS" ] || { echo "flow-manager.sh: input/flow-manager/partners.json not found" >&2; exit 1; }
[ -f "$SUBS" ]     || { echo "flow-manager.sh: input/flow-manager/subscriptions.json not found" >&2; exit 1; }
BASE="$OUT/base"   # the 6 entity lists
XREF="$OUT/xref"   # the 16 pair/attribute caches
mkdir -p "$BASE" "$XREF"

# ---- SKIP LIST (input/skip.txt) --------------------------------------------
# input/skip.txt is a SHARED (env-independent) list of tokens (CRG, SWIFT, …).
# Any configured account or subscription whose NAME contains a token (case-
# insensitive SUBSTRING) is IGNORED — removed from the config here (so every
# base/xref/PDA derivation excludes it) AND from both log parses. To keep every
# raw-JSON reader (this script's extraction, the accounts /
# cronjobs insight page, details.sh) consistent, we write
# FILTERED copies of the exports to data/<env>/flow-manager/filtered/ and every
# reader prefers them (publish_lib.sh's FM_CONFIG_DIR, the two lib.sh
# FM_INPUT_DIR). The skipped config names are recorded in _skipped.tsv for the
# "Skipped" analyses report. cmp-guarded writes keep mtimes stable so the
# downstream freshness checks don't re-fire on a no-change run.
SKIPFILE="$ROOT/input/skip.txt"
# the HAND-CURATED partner alias map (input/partner-aliases.tsv, COMMITTED):
# token<TAB>token pairs naming ONE organisation — pass-2 merge rule 4 and the
# subscription-name fallback's resolution retry. See the file's header.
ALIASF="$ROOT/input/partner-aliases.tsv"
# the FIXED FlowID -> Logical transforms (input/logical.txt, COMMITTED, shared
# by both envs) — consumed by the LOGICAL derivation block below; a pin edit
# re-derives the caches (and, through them, everything downstream).
LOGICALF="$ROOT/input/logical.txt"
source "$ROOT/bin/skiplist.sh"   # skip_values() — the ONE reader for input/skip.txt
SKIPDIR="$OUT/filtered"                 # the filtered partners/subscriptions/templates.json
# The skipped-config sidecar lives INSIDE filtered/ (NOT directly in $OUT) so
# the legacy "rm -f $OUT/_*.tsv" cleanup below never deletes it — putting it in
# $OUT made every run see it missing and needlessly re-derive.
SKIP_SIDE="$SKIPDIR/_skipped.tsv"       # type<TAB>name of every skipped account/subscription
rm -f "$OUT"/_*.tsv   # legacy flat layout (pre base/xref split) — regenerable, so just drop

# The full output list (display order for the report at the bottom). The
# cross references exist BOTH WAYS: for every unordered pair of the nine
# items a canonical _a-b.tsv (left = the item earlier in ITEMS order — what
# the builders below write) PLUS its column-swapped mirror _b-a.tsv, so a
# consumer can always pick the file keyed on the item it joins from.
# PROFILES are PARSE-INTERNAL ONLY (2026-07). The transfer profile stopped
# being an application entity — no detail pages, no cross-reference tables, no
# Entities/coverage/search rows, no result colour, no acc-vs-prod type — but
# bin/transfer/parse.sh still needs it to attribute a subscription: the REVERSE
# config fallback keys on the FlowIdentifier, and the profile is one of the five
# XREF single-value voters. Dropping it from the parse costs 4,883 Files (4.1%)
# that would lose their subscription and be skipped, so _profiles.tsv and the
# _*-profiles / _profiles-* pair caches stay. They feed the parse — and, since
# 2026-08-31, the LOGICAL derivation below (the FlowIDs condensed into logical
# flow groups, a FULL entity) — nothing else; do not surface a raw profile in
# a report or a page.
ENTITY_CACHES="accounts logins hosts white subscriptions profiles logicals partners apps domains"
ITEMS="accounts subscriptions profiles logins hosts logicals partners apps domains white"
CANON_PAIRS=$(
    seen=""
    for a in $ITEMS; do
        for b in $ITEMS; do
            [ "$a" = "$b" ] && continue
            # leading "(" keeps bash 3.2 from ending the $() at the pattern's ")"
            case " $seen " in (*" $b "*) continue ;; esac
            printf '%s-%s\n' "$a" "$b"
        done
        seen="$seen $a"
    done
)
MIRROR_PAIRS=$(printf '%s\n' $CANON_PAIRS | awk -F'-' '{ print $2 "-" $1 }')
PAIR_CACHES="$(printf '%s ' $CANON_PAIRS $MIRROR_PAIRS)subscriptions-patterns subscriptions-flowdir subscriptions-ucderived"

# The PDA both-ways links read the address<->endpoint map, and their output
# depends only on its content — which is now EXACTLY the configured endpoints'
# addresses and nothing else, so the whole file IS the fingerprint. (It used to
# have to filter a shared reverse cache down to endpoint-relevant rows, because
# the parses kept adding entries for non-endpoint IPs that must not re-trigger a
# config rebuild — that would re-derive the parse caches and every report on each
# pipeline run, since the parses run AFTER flow-manager.sh.)
#
# ip_put is cmp-guarded, so a re-resolution returning the same records leaves
# both files byte-identical and this cksum unchanged.
pda_dns_fingerprint() {
    { if [ -f "$IP_HOSTS_FILE" ]; then cat "$IP_HOSTS_FILE"; fi; } | cksum
}

# Early-exit when everything is already fresh (see the header).
fresh=1
for f in $ENTITY_CACHES $PAIR_CACHES; do
    case " $ENTITY_CACHES " in *" $f "*) out="$BASE/_$f.tsv" ;; *) out="$XREF/_$f.tsv" ;; esac
    if [ ! -f "$out" ] || [ "$PARTNERS" -nt "$out" ] || [ "$SUBS" -nt "$out" ] \
       || [ "${BASH_SOURCE[0]}" -nt "$out" ] \
       || { [ -f "$SKIPFILE" ] && [ "$SKIPFILE" -nt "$out" ]; } \
       || { [ -f "$ALIASF" ] && [ "$ALIASF" -nt "$out" ]; } \
       || { [ -f "$LOGICALF" ] && [ "$LOGICALF" -nt "$out" ]; }; then fresh=0; break; fi
done
# The filtered exports + the skipped-config sidecar must exist (a changed
# skip.txt is caught above; a manually removed filtered/ dir heals here).
if [ "$fresh" = 1 ] && { [ ! -f "$SKIPDIR/partners.json" ] || [ ! -f "$SKIPDIR/subscriptions.json" ] || [ ! -f "$SKIP_SIDE" ]; }; then
    fresh=0
fi
if [ "$fresh" = 1 ] && [ "$(pda_dns_fingerprint)" != "$(cat "$OUT/.pda-dns.cksum" 2>/dev/null)" ]; then
    fresh=0
fi
# The templates cache has its own (optional) export: a missing cache, or an
# export newer than it, re-derives; script edits are caught by the loop above.
if [ "$fresh" = 1 ]; then
    tout="$XREF/_templates.tsv"
    if [ ! -f "$tout" ] || { [ -f "$TEMPLATES" ] && [ "$TEMPLATES" -nt "$tout" ]; }; then fresh=0; fi
fi
# RENAME DETECTION runs BEFORE the early exit and on EVERY run: it compares the
# export against the previous run's flowId->name snapshot, and a rename must be
# recorded the first time the new export is seen, whether or not the derived
# caches happen to be fresh. Appending to input/<env>/renames/subscriptions.tsv
# changes the transfer parser signature, so the next parse re-tokenizes and the
# logged names fold to the new ones (bin/renames.sh).
fm_snapshot_renames "$SUBS"
if [ "$fresh" = 1 ]; then
    echo "flow-manager.sh: data/flow-manager caches are up to date; skipping." >&2
    exit 0
fi

# ---- apply the skip list ----------------------------------------------------
# Build FILTERED copies of the exports (skipped accounts/subscriptions removed)
# and record the skipped names, THEN repoint PARTNERS/SUBS/TEMPLATES at the
# filtered files so every extraction below — and every other config reader that
# prefers data/<env>/flow-manager/filtered/ — excludes them. A cmp-guarded
# write keeps the mtimes stable on a no-change run.
mkdir -p "$SKIPDIR"
# The configured objects this filters are ACCOUNTS and SUBSCRIPTIONS, so it
# takes the values of the rules that apply to those fields (plus the "any"
# ones) from bin/skiplist.sh — no second parse of the file format here.
SKIP_JSON=$({ skip_values account; skip_values site; } 2>/dev/null | LC_ALL=C sort -u \
    | jq -R -s 'split("\n") | map(select(length>0) | ascii_upcase)' 2>/dev/null || echo '[]')
[ -n "$SKIP_JSON" ] || SKIP_JSON='[]'
fm_commit() {   # $1 tmp path  $2 final path — keep mtime when unchanged; PID-unique tmp
    if cmp -s "$1" "$2" 2>/dev/null; then rm -f "$1"; else mv "$1" "$2"; fi
}
# keep only the array elements whose .name has NO skip token as a substring
jq --argjson sk "$SKIP_JSON" \
   '[ .[] | select( ((.name // "") | ascii_upcase) as $u | ($sk | any(. as $t | $u | contains($t))) | not ) ]' \
   "$PARTNERS" > "$SKIPDIR/partners.json.$$.tmp" && fm_commit "$SKIPDIR/partners.json.$$.tmp" "$SKIPDIR/partners.json"
jq --argjson sk "$SKIP_JSON" \
   '[ .[] | select( ((.name // "") | ascii_upcase) as $u | ($sk | any(. as $t | $u | contains($t))) | not ) ]' \
   "$SUBS" > "$SKIPDIR/subscriptions.json.$$.tmp" && fm_commit "$SKIPDIR/subscriptions.json.$$.tmp" "$SKIPDIR/subscriptions.json"
if [ -f "$TEMPLATES" ]; then
    jq --argjson sk "$SKIP_JSON" \
       '[ .[] | select( ((.name // "") | ascii_upcase) as $u | ($sk | any(. as $t | $u | contains($t))) | not ) ]' \
       "$TEMPLATES" > "$SKIPDIR/templates.json.$$.tmp" && fm_commit "$SKIPDIR/templates.json.$$.tmp" "$SKIPDIR/templates.json"
else
    rm -f "$SKIPDIR/templates.json"
fi
# the skipped config names, for the "Skipped" analyses report: type<TAB>name
{
    jq -r --argjson sk "$SKIP_JSON" \
       '.[] | (.name // "") | select(. != "") | . as $n | (ascii_upcase) as $u | select($sk | any(. as $t | $u | contains($t))) | "Account\t\($n)"' "$PARTNERS"
    jq -r --argjson sk "$SKIP_JSON" \
       '.[] | (.name // "") | select(. != "") | . as $n | (ascii_upcase) as $u | select($sk | any(. as $t | $u | contains($t))) | "Subscription\t\($n)"' "$SUBS"
} | LC_ALL=C sort -u > "$SKIP_SIDE.$$.tmp" && fm_commit "$SKIP_SIDE.$$.tmp" "$SKIP_SIDE"
# every extraction below reads the filtered exports
PARTNERS="$SKIPDIR/partners.json"
SUBS="$SKIPDIR/subscriptions.json"
[ -f "$SKIPDIR/templates.json" ] && TEMPLATES="$SKIPDIR/templates.json"

# ---------------------------------------------------------------- entity lists

# accounts = partner names, subscriptions = subscription names (top-level .name).
jq -r '.[].name | select(. != null and . != "")' "$PARTNERS" | LC_ALL=C sort -u > "$BASE/_accounts.tsv"
jq -r '.[].name | select(. != null and . != "")' "$SUBS"     | LC_ALL=C sort -u > "$BASE/_subscriptions.tsv"

# FlowManager deep links: each top-level element's meta.href paired with its
# .name -> xref/_{accounts,subscriptions}-fmlink.tsv (name<TAB>url). The detail
# pages render them as a link icon next to the entity name (render_rpt.awk); an
# element without a meta.href simply gets no link.
fm_links() { jq -r '.[] | select(.meta.href != null and .name != null and .name != "") | "\(.name)\t\(.meta.href)"' "$1" | LC_ALL=C sort -u; }
fm_links "$PARTNERS" > "$XREF/_accounts-fmlink.tsv"
fm_links "$SUBS"     > "$XREF/_subscriptions-fmlink.tsv"

# The flow-template catalog (templates.json, optional): one row per template ->
# xref/_templates.tsv "name<TAB>uc<TAB>status<TAB>flowPatternName<TAB>href<TAB>modified".
# uc = the leading UC<n> token ("" when the name carries none — e.g. pentest);
# flowPatternName equals the subscriptions' patternName (validated: every
# _subscriptions-patterns.tsv value is a template's pattern), so per-template
# subscription counts join on it; modified = meta.modifiedTimestamp as a date.
# The Use-cases analyses read it for the template table and for the UCs that
# have a published template but no subscriptions yet (today UC6/UC7).
if [ -f "$TEMPLATES" ]; then
    jq -r '.[] | select(.name != null and .name != "") |
        [ .name,
          (.name | if test("^UC[0-9]+") then (match("^UC[0-9]+").string) else "" end),
          (.status.code // ""),
          (.flowPatternName // ""),
          (.meta.href // ""),
          (((.meta.modifiedTimestamp // 0) / 1000 | floor) | strftime("%Y-%m-%d")) ] | @tsv' \
        "$TEMPLATES" | LC_ALL=C sort -u > "$XREF/_templates.tsv"
else
    : > "$XREF/_templates.tsv"
fi

# profiles = each subscription's parameters.customAttribute_FlowIdentifier
jq -r '.[].parameters.customAttribute_FlowIdentifier | select(. != null and . != "")' "$SUBS" \
  | LC_ALL=C sort -u > "$BASE/_profiles.tsv"

# logins = the comm-profile login name — the .login field ONLY. NOT loginName (a
# descriptive alias that can diverge from the runtime FE-code login — the app
# keys on .login, which is what the SSH/transfer logs carry), NOT loginId, and NOT
# the credentials[].login the old file-wide grep leaked (scoped to
# communicationProfiles here).
jq -r '.[].communicationProfiles[]?.login | select(. != null and . != "")' "$PARTNERS" \
  | LC_ALL=C sort -u > "$BASE/_logins.tsv"

# hosts = the values inside each comm-profile "hosts": [ ... ] array (FQDNs and
# the few IP-valued hosts). ENDPOINTS ARE CANONICALLY LOWERCASE (site-wide rule):
# DNS names are case-insensitive, so every host value is lowercased at this
# source — a case-twin config entry (one endpoint configured twice) folds into
# ONE host, and nothing downstream needs case folding.
jq -r '.[].communicationProfiles[]?.hosts[]? | select(. != null and . != "") | ascii_downcase' "$PARTNERS" \
  | LC_ALL=C sort -u > "$BASE/_hosts.tsv"

# ------------------------------------------------------------ cross references
#
# Two jq passes emit tagged pair lines "TAG<TAB>left<TAB>right" into a temp
# stream; each tag is then split off, expanded (the *W whitelist tags) and
# sorted into its _<item>-<item>.tsv.

RAW="$OUT/.cross.pairs.tmp"

# Pass 1 — partners.json: per partner collect its comm-profile logins (Ls) and
# hosts (Hs), plus the raw AllowIP values (Ws: ";"-split, whitespace-stripped,
# still unexpanded); emit the within-partner cross products AL/AH/AW/LH/LW/HW.
jq -rn --slurpfile P "$PARTNERS" '
  $P[0][] | .name as $p | select($p != null and $p != "") |
  ([.communicationProfiles[]? | .login | select(. != null and . != "")] | unique)                                     as $Ls |
  ([.communicationProfiles[]? | .hosts[]? | select(. != null and . != "") | ascii_downcase] | unique)                  as $Hs |
  ([.customAttributes // {} | to_entries[] | select(.key | test("^AllowIP[0-9]+$")) | .value | select(. != null)
     | split(";")[] | gsub("[[:space:]]"; "") | select(. != "")] | unique)                                            as $Ws |
  ( ($Ls[] | "AL\t\($p)\t\(.)"),
    ($Hs[] | "AH\t\($p)\t\(.)"),
    ($Ws[] | "AW\t\($p)\t\(.)"),
    ($Ls[] as $l | $Hs[] as $h | "LH\t\($l)\t\($h)"),
    ($Ls[] as $l | $Ws[] as $w | "LW\t\($l)\t\($w)"),
    ($Hs[] as $h | $Ws[] as $w | "HW\t\($h)\t\($w)") )
' > "$RAW"

# Pass 2 — subscriptions.json: per subscription collect its accounts (every
# participant EXCEPT the internal application g2c_hub — the only participant
# name that is not a configured partner), its patternName (pat) and its
# parameters.customAttribute_FlowIdentifier (prof). The comm-profile map
# (businessId -> login + hosts), built inline from partners.json, resolves each
# participant comProfileId to its login/hosts side (SLs/SHs). Emit
# AS/SN/SP/SL/SH/AP/PL/PH.
jq -rn --slurpfile P "$PARTNERS" --slurpfile S "$SUBS" '
  ($P[0] | [ .[] | .name as $p | .communicationProfiles[]? | select(.businessId != null)
      | {key: .businessId, value: {login: (.login // ""),
                                   hosts: ([.hosts[]? | select(. != null and . != "") | ascii_downcase])}} ]
   | from_entries) as $cp |
  $S[0][] | .name as $sn | select($sn != null and $sn != "") |
  (.parameters.customAttribute_FlowIdentifier // "")                                                          as $prof |
  (.patternName // "")                                                                                        as $pat |
  (if   (.parameters.source_folder_monitoring_scan_dir // "") != "" then "out"
   elif (.parameters.target_working_dir // "")                != "" then "in"
   # the HYBRID pattern generation (production 2026-08) carries neither
   # folder key — the participant keys say which side the file crosses:
   # target_hybrid_participant = the partner is the TARGET (file moves OUT,
   # APP_CFT_PESIT_PUSH_ST_HYBRID_PULL_PARTNER), source_ = it enters (in).
   # Without this every hybrid flow read "relay", the outcome movement match
   # could never fire, and ALL 116k production Files went Failed.
   elif (.parameters.target_hybrid_participant // "")         != "" then "out"
   elif (.parameters.source_hybrid_participant // "")         != "" then "in"
   else "relay" end)                                                                                          as $fdir |
  ([.participants[]? | select(.name != "g2c_hub")])                                                           as $pt |
  ([$pt[].name | select(. != null and . != "")] | unique)                                                     as $As |
  ([$pt[].comProfileId | select(. != null) | $cp[.]? | select(. != null) | .login | select(. != "")] | unique) as $SLs |
  ([$pt[].comProfileId | select(. != null) | $cp[.]? | select(. != null) | .hosts[]] | unique)                as $SHs |
  ( ($As[] | "AS\t\(.)\t\($sn)"),
    "SD\t\($sn)\t\($fdir)",
    (if $pat  != "" then "SN\t\($sn)\t\($pat)"  else empty end),
    (if $prof != "" then "SP\t\($sn)\t\($prof)" else empty end),
    ($SLs[] | "SL\t\($sn)\t\(.)"),
    ($SHs[] | "SH\t\($sn)\t\(.)"),
    (if $prof != "" then ($As[]  | "AP\t\(.)\t\($prof)") else empty end),
    (if $prof != "" then ($SLs[] | "PL\t\($prof)\t\(.)") else empty end),
    (if $prof != "" then ($SHs[] | "PH\t\($prof)\t\(.)") else empty end) )
' >> "$RAW"

# The whitelist EXPANSION (shared by every *-white pair, and _white.tsv). The
# AllowIP values hold exact IPs plus patterns: `?` = one digit, `*` = a run of
# digits (glob), `a.b.c.d/N` = CIDR. Each is expanded into every valid dotted
# quad it covers (octets 0-255); the bare `*` (allow-any) and any out-of-range
# octet are dropped. A REGEX-style value (escaped dots) whose first three
# octets are literal digits and whose PATTERN sits only on the LAST octet
# (e.g. `212\.123\.225\.(17[6-9]|18[0-9]|19[0-1])`) is EXPANDED like the glob
# case — every 0-255 value matching the pattern, after normalizing `(?:` to
# `(` and `\d` to `[0-9]` (POSIX ERE knows neither) — bounded at 256 IPs like
# a glob. A regex a last-octet enumeration cannot cover (a pattern in an
# earlier octet — `198\.36\.[0-3]\.[0-9]{1,3}` — or characters outside the
# safe set) is kept as ONE de-escaped literal entry, so a partner whose only
# AllowIP is such a regex still has a whitelist, and a broad range can never
# false-merge the whitelist union-find.
# Input "left<TAB>raw", output "left<TAB>ip" per covered IP.
EXPAND_WHITE='
  BEGIN { FS="\t" }
  function valid(ip,   a,i,n){ n=split(ip,a,"."); if(n!=4)return 0; for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/||a[i]+0>255) return 0; return 1 }
  function rexp(v,   a,n,i,pat,r,cnt){ n=split(v,a,/\\\./)   # split on the ESCAPED dots — they delimit the octets unambiguously
      if(n==4 && a[1]~/^[0-9]+$/ && a[2]~/^[0-9]+$/ && a[3]~/^[0-9]+$/ && a[1]+0<=255 && a[2]+0<=255 && a[3]+0<=255){
          pat=a[4]; gsub(/\(\?:/,"(",pat); gsub(/\\d/,"[0-9]",pat)
          if(pat ~ /^[][()|0-9.*+?-]+$/){
              r="^" pat "$"; cnt=0
              for(i=0;i<=255;i++) if((i"")~r){ print pre a[1]"."a[2]"."a[3]"."i; cnt++ }
              if(cnt) return
          }
      }
      gsub(/\\/,"",v); print pre v }   # unexpandable: keep ONE de-escaped literal (never expanded)
  # a FULL-IP glob/trailing-dot value ("104.46.52.22.*", "62.72.117.11.") is
  # the ST regex family: the dot-star tail matches the literal IP itself plus
  # any valid octet whose decimal string EXTENDS the 4th ("22" -> 22,220-229).
  # These used to expand to NOTHING (silently dropping 29 configured values
  # and leaving one partner with an empty whitelist).
  function base_ext(o1,o2,o3,o4,   i){
      for(i=0;i<=255;i++) if(index(i"",o4)==1) print pre o1"."o2"."o3"."i }
  function wild(ip,   a,i,pat,rgx,n){ n=split(ip,a,".")
      if(n==5 && a[5]=="*"){
          for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/||a[i]+0>255) return
          base_ext(a[1],a[2],a[3],a[4]); return }
      if(n!=4)return
      for(i=1;i<=3;i++) if(a[i]!~/^[0-9]+$/||a[i]+0>255) return          # octets 1-3 plain & valid
      if(a[4]!~/[*?]/) return
      pat=a[4]; gsub(/\*/,".*",pat); gsub(/\?/,".",pat); rgx="^" pat "$"   # glob -> regex on the last octet
      for(i=0;i<=255;i++) if((i"")~rgx) print pre a[1]"."a[2]"."a[3]"."i }
  function tdot(ip,   a,n,i){ sub(/\.$/,"",ip); n=split(ip,a,".")
      if(n!=4)return
      for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/||a[i]+0>255) return
      base_ext(a[1],a[2],a[3],a[4]) }
  function cidr(ip,   a,b,bits,base,host,cnt,i,ipn,o1,o2,o3,o4){ split(ip,a,"/"); bits=a[2]+0
      if(!valid(a[1])||bits<0||bits>32||(32-bits)>16) return             # guard against huge blocks
      split(a[1],b,"."); base=((b[1]*256+b[2])*256+b[3])*256+b[4]
      host=2^(32-bits); base=base-(base%host); cnt=host
      for(i=0;i<cnt;i++){ ipn=base+i; o4=ipn%256; o3=int(ipn/256)%256; o2=int(ipn/65536)%256; o1=int(ipn/16777216)%256; print pre o1"."o2"."o3"."o4 } }
  { pre=$1 "\t"; v=$2
    if(v==""||v=="*") next
    if(v ~ /\\\./)                            { rexp(v); next }   # regex-style AllowIP (escaped dots): last-octet patterns expand to their IPs, anything wider stays ONE de-escaped literal — see the header
    if(v ~ /\//)                              { cidr(v); next }
    if(v ~ /[*?]/)                            { wild(v); next }
    if(v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.$/){ tdot(v); next }   # trailing-dot regex literal ("62.72.117.11.")
    if(v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){ if(valid(v)) print pre v } }
'

# ONE pass splits every tag out of the pair stream into its own temp file —
# pair()/wpair() each used to read the WHOLE of $RAW again (15 calls, 15 full
# reads). The tags are the fixed two-letter codes the two jq passes above
# emit, so they are safe as filenames; the regex keeps it that way.
SPLIT="$OUT/.cross.split.tmp"
rm -rf "$SPLIT"; mkdir -p "$SPLIT"
awk -F'\t' -v d="$SPLIT/" '$1 ~ /^[A-Z][A-Z]$/ { print $2 "\t" $3 > (d $1) }' "$RAW"

# Split a tag out of the pair stream into its cross-reference file. A tag with
# no rows leaves no temp file and must still write an EMPTY cache (the
# redirect on the `if` does that), exactly as the empty awk|sort pipe did.
pair()  { if [ -f "$SPLIT/$1" ]; then LC_ALL=C sort -u "$SPLIT/$1"; fi > "$XREF/_$2.tsv"; }
wpair() { if [ -f "$SPLIT/$1" ]; then awk "$EXPAND_WHITE" "$SPLIT/$1" | LC_ALL=C sort -u; fi > "$XREF/_$2.tsv"; }

pair  AL accounts-logins
pair  AH accounts-hosts
wpair AW accounts-white
pair  LH logins-hosts
wpair LW logins-white
wpair HW hosts-white
pair  AS accounts-subscriptions
pair  SN subscriptions-patterns
pair  SD subscriptions-flowdir
pair  SP subscriptions-profiles
pair  SL subscriptions-logins
pair  SH subscriptions-hosts
pair  AP accounts-profiles
pair  PL profiles-logins
pair  PH profiles-hosts

# white = the whole whitelist, one IP per line — the second column of
# _accounts-white.tsv (every AllowIP sits on a named partner), octet-sorted.
cut -f2 "$XREF/_accounts-white.tsv" | LC_ALL=C sort -u -t. -k1,1n -k2,2n -k3,3n -k4,4n > "$BASE/_white.tsv"

# The account-joined whitelist pairs: subscription/profile -> its partner's
# whitelist (an account maps to its subscriptions/profiles via the pair files
# just written, and to its IPs via _accounts-white.tsv).
joinwhite() { # $1 = pair file keyed on account in col 1, $2 = output name
  awk -F'\t' '
    FNR==NR { w[$1]=w[$1] "\037" $2; next }
    ($1 in w) { n=split(substr(w[$1],2),ips,"\037"); for (i=1;i<=n;i++) print $2 "\t" ips[i] }
  ' "$XREF/_accounts-white.tsv" "$XREF/$1" | LC_ALL=C sort -u > "$XREF/_$2.tsv"
}
joinwhite _accounts-subscriptions.tsv subscriptions-white
joinwhite _accounts-profiles.tsv      profiles-white

# ------------------------------------------- the DERIVED use case
# Subscriptions whose NAME carries no UC prefix (the production hybrid flows):
# derive UC1-4 from the movement (_subscriptions-flowdir) crossed with the
# connecting side, read from the configured pattern's ONE partner verb
# (PULL_PARTNER / PUSH_PARTNER) — out+pull = UC2, out+push = UC1, in+push =
# UC4, in+pull = UC3. A pattern with both or neither verb (a relay, an
# unknown shape) gets no row — never a guess. Consumers: the detail pages'
# Features "Use case" row (details.sh) and the UC2/UC4 status selection
# (uc2-status.sh / uc4-status.sh — the Pickup information table on a derived
# UC2 flow's detail page rests on that selection).
awk -F'\t' '
    NR == FNR { fd[$1] = $2; next }
    $1 ~ /^UC[0-9]/ { next }
    {
        pull = ($2 ~ /PULL_PARTNER/) ? 1 : 0; push = ($2 ~ /PUSH_PARTNER/) ? 1 : 0
        if (pull + push != 1) next
        d = ($1 in fd) ? fd[$1] : ""; uc = ""
        if (d == "out") uc = pull ? "UC2" : "UC1"
        else if (d == "in") uc = push ? "UC4" : "UC3"
        if (uc != "") print $1 "\t" uc
    }
' "$XREF/_subscriptions-flowdir.tsv" "$XREF/_subscriptions-patterns.tsv" > "$XREF/_subscriptions-ucderived.tsv"

# ------------------------------------------- partners / apps / domains (PDA)
# The three PDA entities behind the home page's "Partners, Domains &
# Applications" table, derived HERE so the caches are the single source
# (bin/build/publish.sh consumes them and only adds the Seen/Result enrichment).
# Each base file is "name<TAB>direction" with direction in / both / out.
#
#   _partners.tsv  one row per partner GROUP, name-derived then merged (see the
#                  partner-derivation block below). Pass 1: the partner is the
#                  3rd part of the upper-cased account name, split on _ (primary),
#                  an internal - kept inside the part verbatim; a _/- twin borrows
#                  its _-spelled sibling to split; when the _ split gives 2 parts
#                  but - gives 3, - is the structural separator (use it); leading
#                  digits stripped; a UC5-UC8 relay links two partners, so its
#                  part-2 token is a 2nd partner). Pass 2 merges partner tokens to a
#                  fixpoint when (1) an Out account's host IP is whitelisted for an
#                  In account, (2) In accounts share a whitelist IP, or (3) an Out
#                  account's host second-level domain equals a partner group.
#                  Group name = the member tokens joined with '_', sorted;
#                  direction = the union of the member accounts' sides.
#   _apps.tsv      the MIDDLE segment of <domain>-<application>-<partner>
#                  account names (token 2 after the qualifier walk; two-token
#                  names carry no app). _domains.tsv — the FIRST token.
#                  Direction = the union of the name's accounts' configured
#                  sides (login = in, hosts = out; only classified accounts
#                  contribute, matching the home page).
#
# Endpoint addresses come from the endpoint itself (raw IPs) and from
# input/<env>/ip/ip-hosts.tsv — the forward-DNS answers this pass writes, plus
# whatever bin/transfer/parse.sh's rule (b) learned from real outgoing traffic.
# The map is machine-maintained; nothing here is hand-written. The early-exit
# above watches its content, so a changed address re-derives the partner links.
# Forward-resolve every configured endpoint and publish the address<->endpoint
# map (bin/ip.sh). This runs ONLY when flow-manager.sh actually rebuilds — it
# early-exits when its caches are newer than the exports — so it is not a
# per-build DNS cost. It replaces the former fwd/<name>.txt tree, which was only
# ever written when ABSENT, so a changed A record was never picked up.
#
# ip_put UNIONS with what is already there, so an address bin/transfer/parse.sh
# learned from real traffic (rule b) survives a re-resolution that no longer
# returns it — the log rows naming that address still need it. base/_hosts.tsv is
# passed as the KEEP list, which prunes endpoints that have left the config and
# is what keeps the union bounded.
EPS="$OUT/.eps.tmp"
# _hosts.tsv is canonically lowercase already (the jq extraction ascii_downcase's
# it) and is still SINGLE-COLUMN here — the direction column is appended much
# later — so this is a defensive fold, done once instead of per endpoint.
awk -F'\t' '{ print tolower($1) }' "$BASE/_hosts.tsv" > "$EPS"
IPSEED="$OUT/.ipseed.tmp"; : > "$IPSEED"
while IFS= read -r epl; do
    [ -n "$epl" ] || continue
    case $epl in [0-9]*.[0-9]*.[0-9]*.[0-9]*) continue ;; esac   # a raw-IP endpoint names nothing
    if command -v host >/dev/null 2>&1; then
        host -W 2 "$epl" 2>/dev/null | awk -v h="$epl" '/has address/ { print $NF "\t" h }' >> "$IPSEED" || true
    fi
done < "$EPS"
rm -f "$EPS"
ip_put "$BASE/_hosts.tsv" < "$IPSEED"
rm -f "$IPSEED"

# The PDA both-ways linking needs endpoint -> its address(es): ip-hosts.tsv with
# the columns swapped. (It used to be built from the reverse cache, whose
# non-endpoint rows could never match an endpoint and were pure noise.)
PDAIP="$OUT/.pda.ipmap.tmp"
: > "$PDAIP"
[ -f "$IP_HOSTS_FILE" ] && awk -F'\t' '$1 != "" && $2 != "" { print $2 "\t" $1 }' "$IP_HOSTS_FILE" > "$PDAIP"

# Remember the DNS content this build derived from — the early-exit compares
# against it (see pda_dns_fingerprint above). Written AFTER ip_put so freshly
# resolved endpoints are included.
pda_dns_fingerprint > "$OUT/.pda-dns.cksum"

# Name-first partner grouping. pda_split() splits each account name into parts on
# the UNDERSCORE (primary) separator (an internal - stays inside a part verbatim;
# a _/- twin borrows its _-spelled sibling; a 2-part _ split that is a 3-part -
# split uses -), then runs the shared PDA cleanup sequence: a one-part name IS
# its partner (2026-08-29; a lone helper token stays skipped);
# strip a part's trailing digits unless it ends 42; drop a numeric part and a
# bared trailing separator; while >3 parts drop PWD/DEST/SRC/CCP/P2P then
# SA/IR/OTHER/DWH/RRE/PUO; 4 parts -> drop the 4th, UNLESS it is a known partner
# (pda_known: IPSOS/DSM/FRISS/ROTAFORM/IMPRESS) — then keep it and drop the 3rd.
# partner = part 3 (2 parts both
# >5 chars -> BOTH partners; 3 parts whose 3rd is a qualifier -> part 2 is app +
# partner). A UC5-UC8 RELAY links two partners, so its part-2 token becomes a
# SECOND partner and the account gets no application. Pass 2 merges partner groups until
# a fixpoint via three rules: (1) an Out account whose host IP is whitelisted
# for an In account; (2) In accounts sharing a whitelist IP; (3) an Out account
# whose host second-level domain equals a partner group. Group name = the
# member tokens joined with '_', sorted. Emits the partner base file
# (name<TAB>direction) plus the two DIRECT pair caches (account -> group;
# configured host spelling -> group); the account-joined caches below derive
# everything else from them.
awk -F'\t' -v BP="$BASE/.pda.partners.tmp" -v XAP="$OUT/.pda.ap.tmp" -v XHP="$OUT/.pda.hp.tmp" \
    -v WHYF="$XREF/.pda.why.tmp" -v GRPF="$XREF/.pda.groups.tmp" -v GAF="$XREF/.pda.gacct.tmp" \
    -v ALIASF="$ALIASF" '
    function strip(s){ sub(/^[0-9]+/,"",s); return s }
    # ---- group-merge EVIDENCE (why two partner tokens are combined) ----
    # Each rule firing that links two DIFFERENT tokens records one edge; the
    # group is resolved at END (find()) after the fixpoint. Deduped by signature.
    function recordev(rule, ta, tb, txt,   sig){ if(ta==""||tb==""||ta==tb) return
        sig=rule SUBSEP ta SUBSEP tb SUBSEP txt; if(sig in seenev) return; seenev[sig]=1
        EVN++; EVA[EVN]=ta; EVB[EVN]=tb; EVR[EVN]=rule; EVT[EVN]=txt }
    # underscore-primary: _ is the structural separator whenever the name has one,
    # so an internal - stays inside a part; "" when the name has neither
    function primsep(nm,  t,a){ t=nm; a=gsub(/_/,"_",t)
        if(a>0) return "_"; if(nm ~ /-/) return "-"; return "" }
    # split into top-level parts on the primary (underscore) separator, the minority
    # - staying inside a segment. But when the _ split yields only 2 parts while the
    # - split yields 3, the - is the real structural separator (an internal _ sat
    # inside a segment, e.g. AIM-FIN_TREASURY-SCHUBERGPHILLIS) -> use it, to reach 3
    # parts. Drop trailing pure-number parts; fill PARTS[]; return count.
    function parts(nm,  sep,n,cu,ch,t){ sub(/@.*/,"",nm); nm=toupper(nm); sep=primsep(nm)
        if(sep==""){ PARTS[1]=nm; return 1 }
        if(sep=="_"){ t=nm; cu=gsub(/_/,"_",t); t=nm; ch=gsub(/-/,"-",t)
            if(cu==1 && ch==2) sep="-" }
        n=split(nm,PARTS,(sep=="_")?"_":"-"); while(n>=2 && PARTS[n] ~ /^[0-9]+$/) n--; return n }
    # ---- the extra PDA cleanup sequence, applied to the split parts ----
    # qualifier tokens dropped ONLY when there are more than 3 parts; the first
    # five ALSO trigger the 3-part "part 2 is application & partner" rule.
    function pda_isq3(b){ return !(b in REALORG) && (b=="PWD"||b=="DEST"||b=="SRC"||b=="CCP"||b=="P2P") }   # a DECLARED real org (partner-aliases.tsv single-token line) is never a qualifier
    # known partners that appear ONLY as the 4th (last) part of a
    # domain·app·subcategory·partner name — keep the 4th, drop the 3rd (not detectable
    # from config structure, so hardcoded; see the 4-parts rule below).
    function pda_known(b){ return (b=="IPSOS"||b=="DSM"||b=="FRISS"||b=="ROTAFORM"||b=="IMPRESS") }
    # helper tokens that must never stand ALONE as a partner (they are flow
    # qualifiers, not organisations) — the union of the two pda_rmq lists
    function pda_ishelper(b){ return pda_isq3(b) || (!(b in REALORG) && (b=="SA"||b=="IR"||b=="OTHER"||b=="DWH"||b=="RRE"||b=="PUO")) }
    function pda_onepartner(j){ if(j=="SUCCESS_FACTORS") return "SUCCESS_FACTORS"
        if(j=="RABOBANK_INSURANCE" || j=="RABOBANK_INTEGRATION") return "RABOBANK"
        return "" }
    function pda_rmq(tok,  i,j){ if(PDN<=3 || (tok in REALORG)) return
        for(i=1;i<=PDN;i++) if(PDP[i]==tok){ for(j=i;j<PDN;j++) PDP[j]=PDP[j+1]; PDN--; return } }
    # pda_split(name): split on the primary separator, then the sequence — strip
    # trailing digits (unless the part ends 42), drop a fully-numeric part, trim a
    # bared trailing separator, drop the qualifiers while >3 parts, drop the 4th of
    # 4. Fills PDP[1..PDN]; sets PD_SKIP / PD_BOTHP / PD_APPPART. Readers take
    # domain=PDP[1], application=PDP[2], partner=PDP[3] (see the two callers).
    # A ONE-PART name IS its partner (2026-08-29, production estate: 41 real
    # accounts are named after the org directly — EUROPORT, QUION, STATER;
    # formerly rule 1 skipped them and they had no partner at all) — unless
    # the lone token is a helper (P2P etc.), which stays skipped.
    function pda_split(name,  n,i,j,p,q){
        PD_SKIP=0; PD_BOTHP=0; PD_APPPART=0; PDN=0; split("", PDP)   # CLEAR the array — a stale higher entry from the previous account must never survive (the 2026-08-29 audit phantom-partner fix)
        n=parts(name)
        j=0
        for(i=1;i<=n;i++){ p=PARTS[i]
            if(p !~ /42$/ && p ~ /[0-9]$/){ q=p; sub(/[0-9]+$/,"",q); if(length(q)>=2) p=q }   # strip trailing digits (keep ...42; keep a short code like P5 whole — stripping must leave 2+ chars)
            if(p ~ /^[0-9]+$/) continue                      # drop a fully-numeric part
            sub(/[_-]+$/,"",p); if(p=="") continue           # trim a bared trailing separator
            PDP[++j]=p }
        PDN=j; if(PDN==0){ PD_SKIP=1; return }
        pda_rmq("PWD"); pda_rmq("DEST"); pda_rmq("SRC"); pda_rmq("CCP"); pda_rmq("P2P")
        pda_rmq("SA"); pda_rmq("IR"); pda_rmq("OTHER"); pda_rmq("DWH"); pda_rmq("RRE"); pda_rmq("PUO")
        if(PDN==4){ if(pda_known(PDP[4])) PDP[3]=PDP[4]; PDN=3 }   # 4 parts: 4th a known partner -> keep it (drop 3rd), else drop the 4th
        if(PDN==1 && pda_ishelper(PDP[1])){ PD_SKIP=1; return }    # a lone helper token is no partner
        if(PDN==2 && pda_onepartner(PDP[1] "_" PDP[2]) != ""){ PDP[1]=pda_onepartner(PDP[1] "_" PDP[2]); PDN=1 }   # a KNOWN single-org 2-part name is ONE partner (2026-08-29: SUCCESS_FACTORS; RABOBANK_* keep RABOBANK)
        if(PDN==2 && length(PDP[1])>5 && length(PDP[2])>5) PD_BOTHP=1
        if(PDN==3 && pda_isq3(PDP[3])) PD_APPPART=1 }
    # the partner PART is the token verbatim, an internal - kept (strip leading digits)
    function resolve(p){ return strip(p) }
    function ingroup(p,  m,S,i){ if(p in groupset) return 1
        m=split(p,S,/[_-]/); for(i=1;i<=m;i++) if(S[i] in groupset) return 1; return 0 }
    function find(x){ if(!(x in par)) par[x]=x; while(par[x]!=x){par[x]=par[par[x]]; x=par[x]} return x }
    function uni(a,b,  ra,rb){ if(a==""||b=="") return; ra=find(a); rb=find(b); if(ra!=rb){par[ra]=rb; nmerge++} }
    # second-level domain of a host (label before the final TLD label), UPPERCASE
    function sldof(h,  n,L){ if(h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return ""
        n=split(toupper(h),L,"."); if(n<2) return ""; return L[n-1] }
    BEGIN { US=sprintf("%c",31)
        # the hand-curated alias pairs (input/partner-aliases.tsv; "#" = comment)
        nal=0
        while ((getline l4 < ALIASF) > 0) { if (l4 ~ /^#/ || l4 == "") continue
            n4=split(l4,a4x,"\t"); if(n4>=2 && a4x[1]!="" && a4x[2]!=""){ ++nal; AL1[nal]=toupper(a4x[1]); AL2[nal]=toupper(a4x[2]) }
            else if(n4==1 && a4x[1]!="") REALORG[toupper(a4x[1])]=1 }   # a SINGLE-token line DECLARES a real organisation: the token leaves the helper/qualifier lists (P2P)
        close(ALIASF) }
    FILENAME ~ /_accounts-logins\.tsv$/        { inacc[$1]=1; next }
    FILENAME ~ /_accounts-hosts\.tsv$/         { outacc[$1]=1; ah[$1]=ah[$1] US $2; next }
    FILENAME ~ /_accounts-white\.tsv$/         { wlall[$2]=1; ipacc[$2]=ipacc[$2] US $1; next }
    FILENAME ~ /_accounts-subscriptions\.tsv$/ { if($2~/^UC[5678]_/)rly[$1]=1; next }
    FILENAME ~ /_accounts\.tsv$/               { acc[++na]=$1; next }
    { cand[$1]=cand[$1] US $2 }   # PDAIP: endpoint-lower -> candidate IP(s)
    END {
        # underscore-primary source: a _/- twin uses its _-spelled sibling to split
        # for BOTH members, so the internal - is preserved on the hyphen twin too
        for(i=1;i<=na;i++){ a=acc[i]; fk=toupper(a); gsub(/_/,"-",fk); if(a ~ /_/ && !(fk in usrc)) usrc[fk]=a }
        for(i=1;i<=na;i++){ a=acc[i]; fk=toupper(a); gsub(/_/,"-",fk); srcof[a]=(fk in usrc)?usrc[fk]:a }
        # partner token(s) per account via the extra PDA sequence: the
        # both-partner rule and the UC5-UC8 RELAYS add a SECOND token (a relay
        # links two partners, so its part-2 token is a partner, not an app).
        for(i=1;i<=na;i++){ a=acc[i]
            pda_split(srcof[a]); if(PD_SKIP || PDN<1) continue
            pt=(PDN==1)?PDP[1]:((PDN>=3 && !PD_APPPART)?PDP[3]:PDP[2])
            prim[a]=pt; tl=pt
            if(PD_BOTHP && PDP[1]!="" && PDP[1]!=pt) tl=tl US PDP[1]              # both partner
            if((a in rly) && PDN>=2 && PDP[2]!="" && PDP[2]!=pt && index(US tl US, US PDP[2] US)==0) tl=tl US PDP[2]   # PDN>=2: a one-part relay account has no second token (belt to the split(\"\",PDP) braces)
            ptoks[a]=tl; m=split(tl,TL,US); for(j=1;j<=m;j++) find(TL[j]) }
        # Rule 4 (2026-08-29) — the HAND-CURATED ALIAS MAP: two tokens naming
        # ONE organisation merge, the file cited as evidence. Only tokens the
        # estate actually DERIVED merge (an alias to an absent token no-ops);
        # applied once before the fixpoint — union-find keeps it transitive.
        for (ai=1; ai<=nal; ai++) { a4=AL1[ai]; b4=AL2[ai]
            if ((a4 in par) && (b4 in par)) {
                recordev(4, a4, b4, "Curated alias: " a4 " and " b4 " name the same organisation (input/partner-aliases.tsv)")
                uni(a4, b4) } }
        # pass 2 — merge groups; repeat until nothing more combines
        do { nmerge=0
            for(ip in ipacc){ n=split(substr(ipacc[ip],2),AA,US); first=""; firstacct=""     # Rule 2
                for(k=1;k<=n;k++){ a=AA[k]; if((a in inacc) && (a in prim)){
                    if(first==""){ first=prim[a]; firstacct=a }
                    else { recordev(2, prim[a], first, "Inbound accounts " a " (partner " prim[a] ") and " firstacct " (partner " first ") both whitelist IP " ip)
                           uni(prim[a],first) } } } }
            for(i=1;i<=na;i++){ a=acc[i]; if(!(a in outacc) || !(a in ah) || !(a in prim)) continue   # Rule 1
                nh=split(substr(ah[a],2),HH,US)
                for(h=1;h<=nh;h++){ host=HH[h]; hl=tolower(host)
                    if(host ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ipl=host; else ipl=(hl in cand)?substr(cand[hl],2):""
                    if(ipl=="") continue
                    ni=split(ipl,IPS,US)
                    for(pp=1;pp<=ni;pp++){ ip=IPS[pp]; if(!(ip in wlall)) continue
                        n=split(substr(ipacc[ip],2),AA,US)
                        for(k=1;k<=n;k++){ ina=AA[k]; if((ina in inacc) && (ina in prim)){
                            recordev(1, prim[a], prim[ina], "Outbound account " a " (partner " prim[a] ") connects to " host " (IP " ip "), whitelisted by inbound account " ina " (partner " prim[ina] ")")
                            uni(prim[a],prim[ina]) } } } } }
            for(i=1;i<=na;i++){ a=acc[i]; if(!(a in outacc) || !(a in ah) || !(a in prim)) continue   # Rule 3
                nh=split(substr(ah[a],2),HH,US)
                for(h=1;h<=nh;h++){ sld=sldof(HH[h]); if(sld=="" || !(sld in par)) continue
                    if(find(sld)!=find(prim[a])){
                        recordev(3, prim[a], sld, "Outbound account " a " (partner " prim[a] ") connects to host " HH[h] ", whose domain " sld " matches partner " sld)
                        uni(prim[a],sld) } } }
        } while(nmerge>0 && ++pass<100)
        # group name = sorted-unique member tokens joined by - ; direction = union
        for(i=1;i<=na;i++){ a=acc[i]; if(!(a in ptoks)) continue
            m=split(ptoks[a],TL,US); for(j=1;j<=m;j++){ r=find(TL[j]); memb[r]=memb[r] US TL[j]
                if(a in inacc) gI[r]=1; if(a in outacc) gO[r]=1 } }
        for(r in memb){ delete seen; m=split(substr(memb[r],2),TT,US); c=0
            for(k=1;k<=m;k++) if(!(TT[k] in seen)){ seen[TT[k]]=1; ARR[++c]=TT[k] }
            for(x=2;x<=c;x++){ v=ARR[x]; y=x-1; while(y>=1 && ARR[y]>v){ARR[y+1]=ARR[y];y--} ARR[y+1]=v }
            gn=ARR[1]; for(x=2;x<=c;x++) gn=gn "_" ARR[x]
            # CANONICAL GROUP NAME (2026-08-29): when EVERY member has a direct
            # alias pair (input/partner-aliases.tsv) with ONE token — a member
            # itself (the SchubergPhilis star: the variants all alias
            # SCHUBERGPHILIS) or a pure NAME the estate never derives (the
            # RABOBANK_PEKO case: every member of both envs Peko groups
            # aliases RABOBANK_PEKO, which exists only in the alias file) —
            # the group takes that token as its name instead of the joined
            # list. A member equal to the token needs no pair; a group with
            # any member outside the alias set (CLANG in
            # CLANG_DEPLOYTEQ_EVILLAGE) keeps the joined name. Candidates =
            # the members plus every token paired with one, scanned in sorted
            # order so a tie is deterministic.
            if(c>1){
                delete CAND
                for(x=1;x<=c;x++){ CAND[ARR[x]]=1
                    for(ai2=1;ai2<=nal;ai2++){ if(AL1[ai2]==ARR[x]) CAND[AL2[ai2]]=1; if(AL2[ai2]==ARR[x]) CAND[AL1[ai2]]=1 } }
                nc2=0; for(cn in CAND) CARR[++nc2]=cn
                for(x=2;x<=nc2;x++){ v2=CARR[x]; y=x-1; while(y>=1 && CARR[y]>v2){CARR[y+1]=CARR[y];y--} CARR[y+1]=v2 }
                for(x=1;x<=nc2;x++){ cn=CARR[x]; ok2=1
                    for(y=1;y<=c && ok2;y++){ if(ARR[y]==cn) continue
                        ok2=0
                        for(ai2=1;ai2<=nal;ai2++) if((AL1[ai2]==cn && AL2[ai2]==ARR[y]) || (AL2[ai2]==cn && AL1[ai2]==ARR[y])){ ok2=1; break } }
                    if(ok2){ gn=cn; break } } }
            gname[r]=gn
            # a GROUP = more than one member token; record it (name / members / direction)
            if(c>1){ mm=ARR[1]; for(x=2;x<=c;x++) mm=mm "," ARR[x]
                MULTI[r]=1
                print gn "\t" mm "\t" ((gI[r]&&gO[r])?"both":(gI[r]?"in":"out")) > GRPF } }
        # emit the partner base rows (group -> direction)
        for(r in memb) print gname[r] "\t" ((gI[r]&&gO[r])?"both":(gI[r]?"in":"out")) > BP
        # account -> group (a UC5-UC8 relay emits BOTH its groups)
        for(i=1;i<=na;i++){ a=acc[i]; if(!(a in ptoks)) continue
            m=split(ptoks[a],TL,US); delete gseen
            for(j=1;j<=m;j++){ g=gname[find(TL[j])]; if(!(g in gseen)){ gseen[g]=1; print a "\t" g > XAP } } }
        # configured host spelling -> group (of the owning Out account)
        for(i=1;i<=na;i++){ a=acc[i]; if(!(a in outacc) || !(a in ah) || !(a in prim)) continue
            g=gname[find(prim[a])]; nh=split(substr(ah[a],2),HH,US)
            for(h=1;h<=nh;h++) print HH[h] "\t" g > XHP }
        # partner token -> the account NAME it derives from (the group-page
        # Member table Account column: which part of the account name = the code);
        # multi-member groups only. group / token / account
        for(i=1;i<=na;i++){ a=acc[i]; if(!(a in ptoks)) continue
            m=split(ptoks[a],TL,US)
            for(j=1;j<=m;j++){ t=TL[j]; r=find(t); if(r in MULTI) print gname[r] "\t" t "\t" a > GAF } }
        # resolve each merge-evidence edge to its final group name (why combined):
        # group / token pair (A<=B) / rule / human evidence line
        for(e=1;e<=EVN;e++){ ra=find(EVA[e]); if(ra!=find(EVB[e])) continue
            ta=EVA[e]; tb=EVB[e]; if(ta>tb){ tt=ta; ta=tb; tb=tt }
            print gname[ra] "\t" ta "\t" tb "\t" EVR[e] "\t" EVT[e] > WHYF }
    }
' "$XREF/_accounts-logins.tsv" "$XREF/_accounts-hosts.tsv" "$XREF/_accounts-white.tsv" \
  "$XREF/_accounts-subscriptions.tsv" "$BASE/_accounts.tsv" "$PDAIP"
LC_ALL=C sort -u "$BASE/.pda.partners.tmp" 2>/dev/null > "$BASE/_partners.tsv" || : > "$BASE/_partners.tsv"
LC_ALL=C sort -u "$OUT/.pda.ap.tmp" 2>/dev/null > "$XREF/_accounts-partners.tsv" || : > "$XREF/_accounts-partners.tsv"
LC_ALL=C sort -u "$OUT/.pda.hp.tmp" 2>/dev/null > "$XREF/_hosts-partners.tsv" || : > "$XREF/_hosts-partners.tsv"
# the partner GROUPS (multi-member) and the per-group merge evidence (why combined)
LC_ALL=C sort -u "$XREF/.pda.groups.tmp" 2>/dev/null > "$XREF/_partner-groups.tsv" || : > "$XREF/_partner-groups.tsv"
LC_ALL=C sort -u "$XREF/.pda.why.tmp"    2>/dev/null > "$XREF/_partner-group-why.tsv" || : > "$XREF/_partner-group-why.tsv"
LC_ALL=C sort -u "$XREF/.pda.gacct.tmp"  2>/dev/null > "$XREF/_partner-group-accounts.tsv" || : > "$XREF/_partner-group-accounts.tsv"
rm -f "$BASE/.pda.partners.tmp" "$OUT/.pda.ap.tmp" "$OUT/.pda.hp.tmp" "$PDAIP" "$XREF/.pda.groups.tmp" "$XREF/.pda.why.tmp" "$XREF/.pda.gacct.tmp"

# apps + domains: name-derived from the CLASSIFIED configured accounts (an
# account with no comm profile has no direction and, matching the home page,
# contributes nothing). Emits the two base files + the account pair caches.
awk -F'\t' -v BA="$BASE/.pda.apps.tmp" -v BD="$BASE/.pda.domains.tmp" \
           -v XA="$OUT/.pda.aa.tmp" -v XD="$OUT/.pda.ad.tmp" -v ALIASF="$ALIASF" '
    # only the REAL-ORG declarations are needed here (the pair rows drive the
    # partner pass); loaded so the shared pda_* trio behaves identically
    BEGIN { while ((getline l4 < ALIASF) > 0) { if (l4 ~ /^#/ || l4 == "") continue
            n4=split(l4,a4x,"\t"); if(n4==1 && a4x[1]!="") REALORG[toupper(a4x[1])]=1 }
        close(ALIASF) }
    function strip(s){ sub(/^[0-9]+/,"",s); return s }
    function primsep(nm,  t,a){ t=nm; a=gsub(/_/,"_",t)
        if(a>0) return "_"; if(nm ~ /-/) return "-"; return "" }
    function parts(nm,  sep,n,cu,ch,t){ sub(/@.*/,"",nm); nm=toupper(nm); sep=primsep(nm)
        if(sep==""){ PARTS[1]=nm; return 1 }
        if(sep=="_"){ t=nm; cu=gsub(/_/,"_",t); t=nm; ch=gsub(/-/,"-",t)
            if(cu==1 && ch==2) sep="-" }
        n=split(nm,PARTS,(sep=="_")?"_":"-"); while(n>=2 && PARTS[n] ~ /^[0-9]+$/) n--; return n }
    # same PDA cleanup sequence as the partner block above (kept in sync)
    function pda_isq3(b){ return !(b in REALORG) && (b=="PWD"||b=="DEST"||b=="SRC"||b=="CCP"||b=="P2P") }   # a DECLARED real org (partner-aliases.tsv single-token line) is never a qualifier
    # known partners that appear ONLY as the 4th (last) part of a
    # domain·app·subcategory·partner name — keep the 4th, drop the 3rd (not detectable
    # from config structure, so hardcoded; see the 4-parts rule below).
    function pda_known(b){ return (b=="IPSOS"||b=="DSM"||b=="FRISS"||b=="ROTAFORM"||b=="IMPRESS") }
    function pda_ishelper(b){ return pda_isq3(b) || (!(b in REALORG) && (b=="SA"||b=="IR"||b=="OTHER"||b=="DWH"||b=="RRE"||b=="PUO")) }
    function pda_onepartner(j){ if(j=="SUCCESS_FACTORS") return "SUCCESS_FACTORS"
        if(j=="RABOBANK_INSURANCE" || j=="RABOBANK_INTEGRATION") return "RABOBANK"
        return "" }
    function pda_rmq(tok,  i,j){ if(PDN<=3 || (tok in REALORG)) return
        for(i=1;i<=PDN;i++) if(PDP[i]==tok){ for(j=i;j<PDN;j++) PDP[j]=PDP[j+1]; PDN--; return } }
    function pda_split(name,  n,i,j,p,q){
        PD_SKIP=0; PD_BOTHP=0; PD_APPPART=0; PDN=0; split("", PDP)   # CLEAR the array — a stale higher entry from the previous account must never survive (the 2026-08-29 audit phantom-partner fix)
        n=parts(name)
        j=0
        for(i=1;i<=n;i++){ p=PARTS[i]
            if(p !~ /42$/ && p ~ /[0-9]$/){ q=p; sub(/[0-9]+$/,"",q); if(length(q)>=2) p=q }   # keep ...42 and short codes like P5 (see copy 1)
            if(p ~ /^[0-9]+$/) continue
            sub(/[_-]+$/,"",p); if(p=="") continue
            PDP[++j]=p }
        PDN=j; if(PDN==0){ PD_SKIP=1; return }
        pda_rmq("PWD"); pda_rmq("DEST"); pda_rmq("SRC"); pda_rmq("CCP"); pda_rmq("P2P")
        pda_rmq("SA"); pda_rmq("IR"); pda_rmq("OTHER"); pda_rmq("DWH"); pda_rmq("RRE"); pda_rmq("PUO")
        if(PDN==4){ if(pda_known(PDP[4])) PDP[3]=PDP[4]; PDN=3 }
        if(PDN==1 && pda_ishelper(PDP[1])){ PD_SKIP=1; return }   # one-part names ARE partners since 2026-08-29 — but never a lone helper token
        if(PDN==2 && pda_onepartner(PDP[1] "_" PDP[2]) != ""){ PDP[1]=pda_onepartner(PDP[1] "_" PDP[2]); PDN=1 }   # a KNOWN single-org 2-part name is ONE partner (2026-08-29: SUCCESS_FACTORS; RABOBANK_* keep RABOBANK)
        if(PDN==2 && length(PDP[1])>5 && length(PDP[2])>5) PD_BOTHP=1
        if(PDN==3 && pda_isq3(PDP[3])) PD_APPPART=1 }
    # UC5-UC8 are direct relays (two same-kind endpoints, no CFT) and every one
    # of them links TWO PARTNERS — not the application/partner pair UC1-UC4 use.
    # So for a relay the part-2 token is a partner (see the partner pass) and
    # the account contributes NO application; only its domain (part 1) is taken.
    FILENAME ~ /_accounts-subscriptions\.tsv$/ { if($2~/^UC[5678]_/)rly[$1]=1; next }
    FILENAME ~ /_accounts-logins\.tsv$/ { inacc[$1]=1; next }
    FILENAME ~ /_accounts-hosts\.tsv$/  { outacc[$1]=1; next }
    {
        a=$1; d=((a in outacc)?"O":"")((a in inacc)?"I":""); if(d=="") next   # BOTH letters when the account has hosts AND logins (2026-08-29 audit: out-only starved the both side)
        pda_split(a); if(PD_SKIP || PD_BOTHP) next          # both-partner names have no domain/app
        if(PDN>=2){ domd[PDP[1]]=domd[PDP[1]] d; print a "\t" PDP[1] > XD }             # domain = part 1
        if(PDN>=3 && !(a in rly)){ appd[PDP[2]]=appd[PDP[2]] d; print a "\t" PDP[2] > XA }   # app = part 2 (a UC5-UC8 relay has no application: part 2 is its second partner)
    }
    END {
        for(k in appd) print k "\t" ((index(appd[k],"I") && index(appd[k],"O"))?"both":(index(appd[k],"I")?"in":"out")) > BA
        for(k in domd) print k "\t" ((index(domd[k],"I") && index(domd[k],"O"))?"both":(index(domd[k],"I")?"in":"out")) > BD
    }
' "$XREF/_accounts-subscriptions.tsv" "$XREF/_accounts-logins.tsv" "$XREF/_accounts-hosts.tsv" "$BASE/_accounts.tsv"
LC_ALL=C sort -u "$BASE/.pda.apps.tmp"    2>/dev/null > "$BASE/_apps.tsv"    || : > "$BASE/_apps.tsv"
LC_ALL=C sort -u "$BASE/.pda.domains.tmp" 2>/dev/null > "$BASE/_domains.tsv" || : > "$BASE/_domains.tsv"
LC_ALL=C sort -u "$OUT/.pda.aa.tmp" 2>/dev/null > "$XREF/_accounts-apps.tsv"    || : > "$XREF/_accounts-apps.tsv"
LC_ALL=C sort -u "$OUT/.pda.ad.tmp" 2>/dev/null > "$XREF/_accounts-domains.tsv" || : > "$XREF/_accounts-domains.tsv"
rm -f "$BASE/.pda.apps.tmp" "$BASE/.pda.domains.tmp" "$OUT/.pda.aa.tmp" "$OUT/.pda.ad.tmp"

# The account-joined pair caches: everything else follows from the account
# maps just written. ajoin LEFTFILE RIGHTFILE OUT — both files are
# account<TAB>value pairs; emits "leftvalue<TAB>rightvalue" for every account
# they share (the fixed entity order picks which side is LEFT).
ajoin() {   # $1 acct->left pairs  $2 acct->right pairs  $3 output name
  awk -F'\t' '
    FNR==NR { r[$1]=r[$1] "\037" $2; next }
    ($1 in r) { n=split(substr(r[$1],2),R,"\037"); for (i=1;i<=n;i++) print $2 "\t" R[i] }
  ' "$XREF/$2" "$XREF/$1" | LC_ALL=C sort -u > "$XREF/_$3.tsv"
}
ajoin _accounts-subscriptions.tsv _accounts-partners.tsv subscriptions-partners
ajoin _accounts-subscriptions.tsv _accounts-apps.tsv     subscriptions-apps
ajoin _accounts-subscriptions.tsv _accounts-domains.tsv  subscriptions-domains
ajoin _accounts-profiles.tsv      _accounts-partners.tsv profiles-partners
ajoin _accounts-profiles.tsv      _accounts-apps.tsv     profiles-apps
ajoin _accounts-profiles.tsv      _accounts-domains.tsv  profiles-domains
ajoin _accounts-logins.tsv        _accounts-partners.tsv logins-partners
ajoin _accounts-logins.tsv        _accounts-apps.tsv     logins-apps
ajoin _accounts-logins.tsv        _accounts-domains.tsv  logins-domains
ajoin _accounts-hosts.tsv         _accounts-apps.tsv     hosts-apps
ajoin _accounts-hosts.tsv         _accounts-domains.tsv  hosts-domains
ajoin _accounts-partners.tsv      _accounts-apps.tsv     partners-apps
ajoin _accounts-partners.tsv      _accounts-domains.tsv  partners-domains
ajoin _accounts-apps.tsv          _accounts-domains.tsv  apps-domains
ajoin _accounts-partners.tsv      _accounts-white.tsv    partners-white
ajoin _accounts-apps.tsv          _accounts-white.tsv    apps-white
ajoin _accounts-domains.tsv       _accounts-white.tsv    domains-white

# ---- SUBSCRIPTION-NAME FALLBACK (2026-08-29) --------------------------------
# A subscription whose ACCOUNT name yields no domain/application/partner (the
# one-part accounts: EUROPORT, QUION, …) still carries the full triple in its
# OWN name — UCx_<domain>_<application>_<partner> (production: 605 of 611 have
# >=3 parts after the UC prefix). For every base subscription MISSING one of
# the three links, derive it from the UC-stripped name with the SAME pda
# cleanup: domain = part 1 (2+ parts), application = part 2 (3+ parts, never
# for a UC5-8 relay, whose part 2 is a second partner), partner = the pda
# partner token — connected ONLY when it resolves to an EXISTING partner (an
# exact base name, or a member token of a merged group): the fallback fills
# links, it never invents organisations. NEW domain/application names ARE
# appended to their base lists (that namespace is name-derived by design),
# direction = the union of the contributing subscriptions' comm-profile
# sides. Runs BEFORE the mirror loop, so every _X-subscriptions twin picks
# the added pairs up.
awk -F'\t' -v OFS='\t' \
    -v SPADD="$XREF/.pda.spadd.tmp" -v SDADD="$XREF/.pda.sdadd.tmp" -v SAADD="$XREF/.pda.saadd.tmp" \
    -v BAADD="$BASE/.pda.appadd.tmp" -v BDADD="$BASE/.pda.domadd.tmp" -v ALIASF="$ALIASF" '
    function strip(s){ sub(/^[0-9]+/,"",s); return s }
    function primsep(nm,  t,a){ t=nm; a=gsub(/_/,"_",t)
        if(a>0) return "_"; if(nm ~ /-/) return "-"; return "" }
    function parts(nm,  sep,n,cu,ch,t){ sub(/@.*/,"",nm); nm=toupper(nm); sep=primsep(nm)
        if(sep==""){ PARTS[1]=nm; return 1 }
        if(sep=="_"){ t=nm; cu=gsub(/_/,"_",t); t=nm; ch=gsub(/-/,"-",t)
            if(cu==1 && ch==2) sep="-" }
        n=split(nm,PARTS,(sep=="_")?"_":"-"); while(n>=2 && PARTS[n] ~ /^[0-9]+$/) n--; return n }
    # the shared PDA cleanup sequence (kept in sync with the two blocks above)
    function pda_isq3(b){ return !(b in REALORG) && (b=="PWD"||b=="DEST"||b=="SRC"||b=="CCP"||b=="P2P") }   # a DECLARED real org (partner-aliases.tsv single-token line) is never a qualifier
    function pda_known(b){ return (b=="IPSOS"||b=="DSM"||b=="FRISS"||b=="ROTAFORM"||b=="IMPRESS") }
    function pda_ishelper(b){ return pda_isq3(b) || (!(b in REALORG) && (b=="SA"||b=="IR"||b=="OTHER"||b=="DWH"||b=="RRE"||b=="PUO")) }
    function pda_onepartner(j){ if(j=="SUCCESS_FACTORS") return "SUCCESS_FACTORS"
        if(j=="RABOBANK_INSURANCE" || j=="RABOBANK_INTEGRATION") return "RABOBANK"
        return "" }
    function pda_rmq(tok,  i,j){ if(PDN<=3 || (tok in REALORG)) return
        for(i=1;i<=PDN;i++) if(PDP[i]==tok){ for(j=i;j<PDN;j++) PDP[j]=PDP[j+1]; PDN--; return } }
    function pda_split(name,  n,i,j,p,q){
        PD_SKIP=0; PD_BOTHP=0; PD_APPPART=0; PDN=0; split("", PDP)   # CLEAR the array — a stale higher entry from the previous account must never survive (the 2026-08-29 audit phantom-partner fix)
        n=parts(name)
        j=0
        for(i=1;i<=n;i++){ p=PARTS[i]
            if(p !~ /42$/ && p ~ /[0-9]$/){ q=p; sub(/[0-9]+$/,"",q); if(length(q)>=2) p=q }   # keep ...42 and short codes like P5 (see copy 1)
            if(p ~ /^[0-9]+$/) continue
            sub(/[_-]+$/,"",p); if(p=="") continue
            PDP[++j]=p }
        PDN=j; if(PDN==0){ PD_SKIP=1; return }
        pda_rmq("PWD"); pda_rmq("DEST"); pda_rmq("SRC"); pda_rmq("CCP"); pda_rmq("P2P")
        pda_rmq("SA"); pda_rmq("IR"); pda_rmq("OTHER"); pda_rmq("DWH"); pda_rmq("RRE"); pda_rmq("PUO")
        if(PDN==4){ if(pda_known(PDP[4])) PDP[3]=PDP[4]; PDN=3 }
        if(PDN==1 && pda_ishelper(PDP[1])){ PD_SKIP=1; return }
        if(PDN==2 && pda_onepartner(PDP[1] "_" PDP[2]) != ""){ PDP[1]=pda_onepartner(PDP[1] "_" PDP[2]); PDN=1 }   # a KNOWN single-org 2-part name is ONE partner (2026-08-29: SUCCESS_FACTORS; RABOBANK_* keep RABOBANK)
        if(PDN==2 && length(PDP[1])>5 && length(PDP[2])>5) PD_BOTHP=1
        if(PDN==3 && pda_isq3(PDP[3])) PD_APPPART=1 }
    function dirword(f){ return (index(f,"I") && index(f,"O")) ? "both" : (index(f,"I") ? "in" : (index(f,"O") ? "out" : "")) }
    # resolve a partner TOKEN to an existing partner: exact base name, else a
    # merged group member token, else the same two lookups through the token
    # ALIASES (input/partner-aliases.tsv — EVILLAGE resolves to DEPLOYTEQ)
    function ptn_resolve(tk,   r7, ai7, o7) {
        if (tk == "") return ""
        if (tk in pset) return tk
        if (tk in tok2grp) return tok2grp[tk]
        for (ai7=1; ai7<=nal; ai7++) { o7 = ""
            if (AL1[ai7] == tk) o7 = AL2[ai7]; else if (AL2[ai7] == tk) o7 = AL1[ai7]
            if (o7 == "") continue
            if (o7 in pset) return o7
            if (o7 in tok2grp) return tok2grp[o7] }
        return "" }
    BEGIN { nal=0
        while ((getline l4 < ALIASF) > 0) { if (l4 ~ /^#/ || l4 == "") continue
            n4=split(l4,a4x,"\t"); if(n4>=2 && a4x[1]!="" && a4x[2]!=""){ ++nal; AL1[nal]=toupper(a4x[1]); AL2[nal]=toupper(a4x[2]) }
            else if(n4==1 && a4x[1]!="") REALORG[toupper(a4x[1])]=1 }   # a SINGLE-token line DECLARES a real organisation: the token leaves the helper/qualifier lists (P2P)
        close(ALIASF) }
    FILENAME ~ /_subscriptions-partners\.tsv$/ { hasp[$1]=1; next }
    FILENAME ~ /_subscriptions-domains\.tsv$/  { hasd[$1]=1; next }
    FILENAME ~ /_subscriptions-apps\.tsv$/     { hasa[$1]=1; next }
    FILENAME ~ /_partners\.tsv$/               { pset[$1]=1; next }               # base: name / direction
    FILENAME ~ /_partner-groups\.tsv$/         { n2=split($2,MM,","); for(i2=1;i2<=n2;i2++) tok2grp[MM[i2]]=$1; next }
    FILENAME ~ /_subscriptions-logins\.tsv$/   { insub[$1]=1; next }
    FILENAME ~ /_subscriptions-hosts\.tsv$/    { outsub[$1]=1; next }
    {   # base _subscriptions.tsv: one name per line (direction appended later)
        s=$1; if(s=="") next
        if((s in hasp) && (s in hasd) && (s in hasa)) next
        nm=s; sub(/^UC[0-9Xx]+[_-]/, "", nm)
        if(nm==s || nm=="") next            # only a UC-named subscription carries the triple
        pda_split(nm); if(PD_SKIP) next
        dch=((s in insub)?"I":"")((s in outsub)?"O":"")
        dom=""; app2=""; pt=""; pt2=""
        if(PD_BOTHP){ pt=PDP[2]; pt2=PDP[1] }
        else {
            if(PDN>=2) dom=PDP[1]
            # PD_APPPART (3rd token a qualifier): part 2 is application AND
            # partner — the app fill applies to it too (2026-08-29 fix; only
            # a UC5-8 relay has no application, its part 2 a second partner)
            if(PDN>=3 && s !~ /^UC[5678]/) app2=PDP[2]
            pt=(PDN==1)?PDP[1]:((PDN>=3 && !PD_APPPART)?PDP[3]:PDP[2]) }
        if(!(s in hasd) && dom!=""){ print s, dom > SDADD; domd2[dom]=domd2[dom] dch }
        if(!(s in hasa) && app2!=""){ print s, app2 > SAADD; appd2[app2]=appd2[app2] dch }
        if(!(s in hasp)){
            rp=ptn_resolve(pt)
            if(rp!="") print s, rp > SPADD
            if(pt2!=""){ rp2=ptn_resolve(pt2)
                if(rp2!="" && rp2!=rp) print s, rp2 > SPADD } }
    }
    END {
        for(k in appd2) print k, dirword(appd2[k]) > BAADD
        for(k in domd2) print k, dirword(domd2[k]) > BDADD
    }
' "$XREF/_subscriptions-partners.tsv" "$XREF/_subscriptions-domains.tsv" "$XREF/_subscriptions-apps.tsv" \
  "$BASE/_partners.tsv" "$XREF/_partner-groups.tsv" \
  "$XREF/_subscriptions-logins.tsv" "$XREF/_subscriptions-hosts.tsv" "$BASE/_subscriptions.tsv"
# merge the additions (sort -u dedups a re-run); a base append adds only NEW names
for _sf in spadd:subscriptions-partners sdadd:subscriptions-domains saadd:subscriptions-apps; do
    _add="$XREF/.pda.${_sf%%:*}.tmp"; _dst="$XREF/_${_sf#*:}.tsv"
    [ -f "$_add" ] || continue
    cat "$_add" "$_dst" 2>/dev/null | LC_ALL=C sort -u > "$_dst.tmp" && mv "$_dst.tmp" "$_dst"
    rm -f "$_add"
done
for _sf in appadd:apps domadd:domains; do
    _add="$BASE/.pda.${_sf%%:*}.tmp"; _dst="$BASE/_${_sf#*:}.tsv"
    [ -f "$_add" ] || continue
    # a base append adds NEW names AND widens an existing one to "both" when
    # the fallback saw the other side (2026-08-29 audit: add-only left e.g.
    # domain IPO one-sided forever)
    awk -F'\t' 'BEGIN{OFS="\t"}
        FNR==NR { ad2[$1]=$2; next }
        { if(($1 in ad2) && ad2[$1]!="" && $2!="" && $2!=ad2[$1]) $2="both"
          seen[$1]=1; print; next }
        END { for(k in ad2) if(!(k in seen)) print k, ad2[k] }' "$_add" "$_dst" \
        | LC_ALL=C sort -u > "$_dst.tmp" && mv "$_dst.tmp" "$_dst"
    rm -f "$_add"
done

# TRANSITIVE PAIRS THROUGH THE SUBSCRIPTION (2026-08-29): the X-Y pair caches
# above join through the ACCOUNT maps, so a one-part account's flows — whose
# domain/application exist only via the subscription-name fallback — left its
# partner/login/host unconnected to them (the EUROPORT partner page showed
# no Domains and no Applications despite 7 subscriptions carrying both).
# Join the same pairs through the SUBSCRIPTION maps as well and UNION them
# into the canonical caches; the mirror loop below then carries the twins.
# The ACCOUNT maps stay untouched: _accounts-apps/domains feed the parse's
# per-file attribution (cols 18/19) and must keep their name-derived meaning
# (since 2026-08-29 the parse ALSO falls back to _subscriptions-apps/domains
# for a file whose account derives nothing — the audit's AUTOMODUS_RIJCOACH
# contradiction: coverage counted its Files, the detail page said never seen).
sjoin() {   # $1 subs->left pairs  $2 subs->right pairs  $3 canonical output pair name
  awk -F'\t' '
    FNR==NR { r[$1]=r[$1] "\037" $2; next }
    ($1 in r) { n=split(substr(r[$1],2),R,"\037"); for (i=1;i<=n;i++) print $2 "\t" R[i] }
  ' "$XREF/$2" "$XREF/$1" | cat - "$XREF/_$3.tsv" 2>/dev/null | LC_ALL=C sort -u > "$XREF/_$3.tsv.tmp" \
      && mv "$XREF/_$3.tsv.tmp" "$XREF/_$3.tsv"
}
sjoin _subscriptions-partners.tsv _subscriptions-apps.tsv    partners-apps
sjoin _subscriptions-partners.tsv _subscriptions-domains.tsv partners-domains
sjoin _subscriptions-apps.tsv     _subscriptions-domains.tsv apps-domains
sjoin _subscriptions-logins.tsv   _subscriptions-apps.tsv    logins-apps
sjoin _subscriptions-logins.tsv   _subscriptions-domains.tsv logins-domains
sjoin _subscriptions-hosts.tsv    _subscriptions-apps.tsv    hosts-apps
sjoin _subscriptions-hosts.tsv    _subscriptions-domains.tsv hosts-domains

# ---- PRUNE SUBSCRIPTION-LESS PARTNERS (2026-08-29, user decision) -----------
# A partner whose accounts carry NO subscription moves no files and never
# will — config residue (an account with no flows: INFRA, TT, INDEPENDER,
# REASULT). Drop it from the base list, every canonical pair cache and the
# group evidence BEFORE the mirror loop, so the estate forgets it
# consistently. Keep-list = _subscriptions-partners.tsv (the account join
# UNION the subscription-name fallback): a partner with ANY flow stays. An
# EMPTY keep-list (no subscriptions at all — never a real config) prunes
# nothing rather than everything.
PKEEP="$XREF/.pda.pkeep.tmp"
cut -f2 "$XREF/_subscriptions-partners.tsv" 2>/dev/null | LC_ALL=C sort -u > "$PKEEP" || : > "$PKEEP"
if [ -s "$PKEEP" ]; then
    prune_ptn() {   # $1 file  $2 partner column (1|2)
        [ -f "$1" ] || return 0
        awk -F'\t' -v c="$2" 'FNR==NR { k[$1]=1; next } ($c in k)' "$PKEEP" "$1" > "$1.tmp" \
            && mv "$1.tmp" "$1"
    }
    prune_ptn "$BASE/_partners.tsv" 1
    prune_ptn "$XREF/_accounts-partners.tsv" 2
    prune_ptn "$XREF/_hosts-partners.tsv" 2
    prune_ptn "$XREF/_profiles-partners.tsv" 2
    prune_ptn "$XREF/_logins-partners.tsv" 2
    prune_ptn "$XREF/_partners-apps.tsv" 1
    prune_ptn "$XREF/_partners-domains.tsv" 1
    prune_ptn "$XREF/_partners-white.tsv" 1
    prune_ptn "$XREF/_partner-groups.tsv" 1
    prune_ptn "$XREF/_partner-group-why.tsv" 1
    prune_ptn "$XREF/_partner-group-accounts.tsv" 1
fi
rm -f "$PKEEP"

# ---- LOGICAL flow groups (2026-08-30 acc-vs-prod; FULL entity 2026-08-31) ----
# One env's FlowIDs (base/_profiles.tsv = the customAttribute_FlowIdentifier
# values) condensed into logical flow groups, one name per group, always 3
# parts. Three passes:
# 1) GROUP — FIRST rule for 4-part FlowIDs (2026-08-30, user request): when
#    the 3rd part is the 3rd part of TWO OR MORE 4-part FlowIDs, the 4th
#    part drops (SI_GOUDMIJN_INSHARED_{HEMA,HEMAPOLIS,INSHARED,POLIS} ->
#    one SI_GOUDMIJN_INSHARED). Then: 4-part FlowIDs sharing their first 3
#    parts (the bare 3-part name joins when it exists) fold onto those 3
#    parts; a 3-part FlowID whose digit-tailed part, stripped (a trailing
#    "-" trimmed with the digits), duplicates another stripped name or an
#    existing FlowID folds onto the stripped form; a 4-part FlowID whose
#    numeric-only part, removed, duplicates another folds onto the removed
#    form. A SINGLE-part FlowID (all dashes — the monitor's
#    INFRA-MONITOR-UC1..4) gets the same digit-tail rule on the whole name
#    (2026-08-30): the four fold onto INFRA-MONITOR-UC. A FlowID of FIVE OR
#    MORE parts (2026-08-30, user request — the AB_NAS_FIS_BSM_BU_A_AH
#    family) folds onto its LONGEST part-prefix (3+ parts) that EXISTS as a
#    FlowID: the eight long AB_NAS_FIS_BSM_* names join the bare
#    AB_NAS_FIS_BSM, and the reshape renders the group AB_NAS_FIS-BSM. A
#    fixed input/logical.txt mapping is also honoured for the GROUP name a
#    fold lands on, so one line can pin a whole family's final form.
# 2) RESHAPE to 3 parts by position, informed by the 3-part logicals'
#    vocabulary (their 2nd/3rd parts): AAA_BBB -> AAA_AAA_BBB; 4 parts whose
#    4th is a known 3rd -> AAA_BBB-CCC_DDD; 4 parts whose 2nd is a known
#    2nd -> AAA_BBB_CCC-DDD; 5 parts whose 5th is a known 3rd ->
#    AAA_BBB-CCC-DDD_EEE.
# 3) FORCE the rest to 3 parts (vocabulary refreshed): the first part 2..n
#    that is a known 3rd part becomes the 3rd, everything else after part 1
#    joining as the 2nd; else a known 2nd part becomes the 2nd, the rest
#    joining as the 3rd; else first and last kept, the middle joined. Joins
#    use "-" — which is why Logical names render UNFOLDED everywhere (the
#    hyphen is semantic, marking combined parts).
# input/logical.txt: FIXED FlowID -> Logical transforms, two whitespace-
# separated columns (# comments, blank lines ignored), shared by both
# environments. A listed FlowID takes its given Logical VERBATIM — no
# grouping, no 3-part reshape — and only the rest go through the derivation.
# A missing file is a no-op.
#
# Output: xref/_profiles-logicals.tsv — the FlowID -> Logical MAP, one row
# per configured FlowID (the canonical profiles/logicals pair; every report
# that attributes a File's profile column resolves through it) — plus
# base/_logicals.tsv (direction/result appended below like every base) and
# the 8 other canonical logicals pair caches, composed from the profiles
# pairs. Placed AFTER the partner prune (the composed _logicals-partners
# must not resurrect pruned partners) and BEFORE the mirror loop (every
# canonical file must exist — possibly empty — for the mirrors).
awk -F'\t' -v LF="$LOGICALF" '
    BEGIN {
        while ((getline fl < LF) > 0) {
            if (fl ~ /^[ \t]*#/ || fl ~ /^[ \t]*$/) continue
            nf2 = split(fl, fa, /[ \t]+/)
            if (nf2 >= 2 && fa[1] != "" && fa[2] != "") FIX[fa[1]] = fa[2]
        }
        close(LF)
    }
    function joindash(P, n, skip, from,   r, m) { r = ""
        for (m = from; m <= n; m++) { if (m == skip) continue; r = (r == "" ? P[m] : r "-" P[m]) }
        return r }
    function rejoin(P, n, skip,   r, m) { r = ""
        for (m = 1; m <= n; m++) { if (m == skip) continue; r = (r == "" ? P[m] : r "_" P[m]) }
        return r }
    function replaced(P, n, at, s,   r, m, t) { r = ""
        for (m = 1; m <= n; m++) { t = (m == at ? s : P[m]); r = (r == "" ? t : r "_" t) }
        return r }
    function digitstrip(p,   s) { s = p; if (sub(/[0-9]+$/, "", s)) sub(/-+$/, "", s); return s }
    # INTAKE NORMALIZATION (2026-08-30): the estate mixes "-" and "_"
    # spellings of one name (the family matches everything sepfolded),
    # but this derivation splits on "_" alone — a dash-spelled sibling
    # parsed into different part counts and every grouping rule missed
    # it. Group on the "_"-folded form; a FIXED mapping still matches
    # the RAW spelling too. The reshape re-adds dashes for its joins.
    $1 != "" { raw = $1; nn++
        raws[nn] = raw
        if (raw in FIX) { finalfix[nn] = FIX[raw]; next }
        nm0 = raw; gsub(/-/, "_", nm0)
        name[nn] = nm0; exists[nm0] = 1 }
    END {
        # pass 1a: count the reductions
        for (i = 1; i <= nn; i++) {
            if (i in finalfix) continue
            n = split(name[i], P, "_")
            if (n == 4) {
                cnt1[P[1] "_" P[2] "_" P[3]]++
                cnt3rd[P[3]]++                    # 3rd parts across the 4-part FlowIDs
                for (j = 1; j <= n; j++) if (P[j] ~ /^[0-9]+$/) cnt3[rejoin(P, n, j)]++
            } else if (n == 3) third3[P[3]] = 1   # 3rd parts of the 3-part FlowIDs
            if (n == 3)
                for (j = 1; j <= n; j++) { s = digitstrip(P[j])
                    if (s != P[j] && s != "") cnt2[replaced(P, n, j, s)]++ }
            else if (n == 1) { s = digitstrip(P[1])
                if (s != P[1] && s != "") cnt2[s]++ }
        }
        # pass 1b: assign each FlowID its group name — a FIXED mapping
        # (input/logical.txt) wins outright and skips the reshape passes
        for (i = 1; i <= nn; i++) {
            if (i in finalfix) continue
            nm = name[i]
            n = split(nm, P, "_"); lg = nm
            if (n == 4) {
                pre = P[1] "_" P[2] "_" P[3]
                # the FIRST 4-part rule (2026-08-30, user precedence):
                # dropping the 4th part gives an EXISTING 3-part FlowID
                # -> that 3-part name is the logical (the
                # AB_SNOWFLAKE_HYPOPORT_{MORTG,PIPE,SPREAD} family joins
                # its bare AB_SNOWFLAKE_HYPOPORT)
                if (pre in exists) lg = pre
                # then: a 3rd part that is the 3rd part of 2+ 4-part
                # FlowIDs — or of any 3-PART FlowID (the restated rule)
                else if (cnt3rd[P[3]] >= 2 || (P[3] in third3)) lg = pre
                else if (cnt1[pre] >= 2) lg = pre
                else for (j = 1; j <= n; j++) if (P[j] ~ /^[0-9]+$/) {
                    c = rejoin(P, n, j)
                    if (cnt3[c] >= 2 || (c in exists)) { lg = c; break } }
            } else if (n == 3)
                for (j = 1; j <= n; j++) { s = digitstrip(P[j])
                    if (s != P[j] && s != "") { c = replaced(P, n, j, s)
                        if (cnt2[c] >= 2 || (c in exists)) { lg = c; break } } }
            else if (n == 1) { s = digitstrip(P[1])
                if (s != P[1] && s != "" && (cnt2[s] >= 2 || (s in exists))) lg = s }
            else if (n >= 5)
                # fold onto the LONGEST part-prefix (3+ parts) that
                # exists as a FlowID of its own
                for (k = n - 1; k >= 3; k--) {
                    pre = P[1]
                    for (m = 2; m <= k; m++) pre = pre "_" P[m]
                    if (pre in exists) { lg = pre; break }
                }
            # a fixed mapping for the GROUP a fold landed on wins too
            if (lg in FIX) { finalfix[i] = FIX[lg]; continue }
            grpof[i] = lg; lset[lg] = 1
        }
        # pass 2: reshape to 3 parts by position
        for (l in lset) { n = split(l, P, "_"); if (n == 3) { k2[P[2]] = 1; k3[P[3]] = 1 } }
        for (l in lset) {
            n = split(l, P, "_"); nl = l
            if (n == 2) nl = P[1] "_" P[1] "_" P[2]
            else if (n == 4 && (P[4] in k3)) nl = P[1] "_" P[2] "-" P[3] "_" P[4]
            else if (n == 4 && (P[2] in k2)) nl = P[1] "_" P[2] "_" P[3] "-" P[4]
            else if (n == 5 && (P[5] in k3)) nl = P[1] "_" P[2] "-" P[3] "-" P[4] "_" P[5]
            map2[l] = nl; lset2[nl] = 1
        }
        # pass 3: force what is left to 3 parts
        split("", k2); split("", k3)
        for (l in lset2) { n = split(l, P, "_"); if (n == 3) { k2[P[2]] = 1; k3[P[3]] = 1 } }
        for (l in lset2) {
            n = split(l, P, "_"); nl = l
            if (n > 3) {
                done = 0
                for (j = 2; j <= n && !done; j++) if (P[j] in k3) { nl = P[1] "_" joindash(P, n, j, 2) "_" P[j]; done = 1 }
                for (j = 2; j <= n && !done; j++) if (P[j] in k2) { nl = P[1] "_" P[j] "_" joindash(P, n, j, 2); done = 1 }
                if (!done) nl = P[1] "_" joindash(P, n - 1, 0, 2) "_" P[n]
            }
            map3[l] = nl
        }
        # the map: every configured FlowID -> its final Logical
        for (i = 1; i <= nn; i++)
            print raws[i] "\t" ((i in finalfix) ? finalfix[i] : map3[map2[grpof[i]]])
    }' "$BASE/_profiles.tsv" | LC_ALL=C sort -u > "$XREF/_profiles-logicals.tsv"
cut -f2 "$XREF/_profiles-logicals.tsv" | LC_ALL=C sort -u > "$BASE/_logicals.tsv"
# the other 8 canonical logicals pairs: the profiles pairs composed with the
# map (a pair row whose FlowID maps joins that FlowID's Logical; the file is
# ALWAYS written — possibly empty — for the mirror loop)
lmap() {   # $1 input pair cache  $2 profile column (1|2)  $3 LEFT|RIGHT (where the logical lands)  $4 output pair name
    {   if [ -f "$XREF/$1" ]; then
            awk -F'\t' -v pc="$2" -v side="$3" '
                FILENAME == ARGV[1] { if ($1 != "" && $2 != "") LG[toupper($1)] = $2; next }
                { p = (pc == 1) ? $1 : $2; o = (pc == 1) ? $2 : $1
                  if (toupper(p) in LG) { l = LG[toupper(p)]
                      if (side == "LEFT") print l "\t" o; else print o "\t" l } }
            ' "$XREF/_profiles-logicals.tsv" "$XREF/$1"
        fi
    } | LC_ALL=C sort -u > "$XREF/_$4.tsv"
}
lmap _accounts-profiles.tsv      2 RIGHT accounts-logicals
lmap _subscriptions-profiles.tsv 2 RIGHT subscriptions-logicals
lmap _profiles-logins.tsv        1 RIGHT logins-logicals
lmap _profiles-hosts.tsv         1 RIGHT hosts-logicals
lmap _profiles-partners.tsv      1 LEFT  logicals-partners
lmap _profiles-apps.tsv          1 LEFT  logicals-apps
lmap _profiles-domains.tsv       1 LEFT  logicals-domains
lmap _profiles-white.tsv         1 LEFT  logicals-white

# ----------------------------- mirrors: every cross reference exists both ways
# Each canonical _a-b.tsv gets its column-swapped twin _b-a.tsv (sorted on
# the new left column), so joins never need to know the fixed item order.
for p in $CANON_PAIRS; do
    a=${p%%-*}; b=${p#*-}
    awk -F'\t' '{ print $2 "\t" $1 }' "$XREF/_$p.tsv" | LC_ALL=C sort -u > "$XREF/_$b-$a.tsv"
done

# ------------------------------------- direction column for every base file
# EVERY base file shares the schema "name<TAB>direction" (in / both / out;
# empty = unclassifiable). logins and the whitelist are inbound and hosts
# outbound BY DEFINITION; accounts, subscriptions and profiles derive from
# their login-side/host-side pair caches (an account's comm profiles are a
# login (in) or hosts (out) — never both; a profile takes the union of its
# subscriptions' sides). Appended LAST so every step above reads the plain
# single-column lists it just wrote; external consumers read column 1.
adddir() {   # $1 base name  $2 in-side pair cache  $3 out-side pair cache (col 1 = the entity)
    awk -F'\t' '
        FILENAME == ARGV[1] { i[$1]=1; next }
        FILENAME == ARGV[2] { o[$1]=1; next }
        { d = ($1 in i) ? (($1 in o) ? "both" : "in") : (($1 in o) ? "out" : "")
          print $1 "\t" d }
    ' "$2" "$3" "$BASE/_$1.tsv" > "$BASE/_$1.tsv.tmp" && mv "$BASE/_$1.tsv.tmp" "$BASE/_$1.tsv"
}
adddir accounts      "$XREF/_accounts-logins.tsv"      "$XREF/_accounts-hosts.tsv"
adddir subscriptions "$XREF/_subscriptions-logins.tsv" "$XREF/_subscriptions-hosts.tsv"
adddir profiles      "$XREF/_profiles-logins.tsv"      "$XREF/_profiles-hosts.tsv"
adddir logicals      "$XREF/_logicals-logins.tsv"      "$XREF/_logicals-hosts.tsv"
awk -F'\t' '{ print $1 "\tin"  }' "$BASE/_logins.tsv" > "$BASE/_logins.tsv.tmp" && mv "$BASE/_logins.tsv.tmp" "$BASE/_logins.tsv"
awk -F'\t' '{ print $1 "\tout" }' "$BASE/_hosts.tsv"  > "$BASE/_hosts.tsv.tmp"  && mv "$BASE/_hosts.tsv.tmp"  "$BASE/_hosts.tsv"
awk -F'\t' '{ print $1 "\tin"  }' "$BASE/_white.tsv"  > "$BASE/_white.tsv.tmp"  && mv "$BASE/_white.tsv.tmp"  "$BASE/_white.tsv"

# ------------------------------------- result column for every base file
# Third field `result` on EVERY base file (schema is now
# "name<TAB>direction<TAB>result"): initialized "unknown" here; the build's
# RESULT step (bin/build/result.sh, right after the transfer parse) computes the
# real value — subscriptions from their last transfer's outcome (green /
# red / orange), every other entity rolled up from its connected
# subscriptions via the xref pair caches. Consumers keep reading col 1/2.
for f in $ENTITY_CACHES; do
    awk -F'\t' '{ print $0 "\tunknown" }' "$BASE/_$f.tsv" > "$BASE/_$f.tsv.tmp" \
        && mv "$BASE/_$f.tsv.tmp" "$BASE/_$f.tsv"
done

rm -f "$RAW"
rm -rf "$SPLIT"

# ---------------------------------------------------------------------- report

# ONE awk counts every cache; the loops below only print (read + printf are
# builtins, so they fork nothing). A per-file `$(wc -l < f | tr -d ' ')` cost
# ~170 forks for a summary line. awk never fires FILENAME on an EMPTY file, so
# the counts are walked from ARGV with a 0 default — _logins-hosts.tsv is
# legitimately empty and must still report 0.
fm_files=""
for f in $ENTITY_CACHES; do fm_files="$fm_files $BASE/_$f.tsv"; done
for f in $PAIR_CACHES;   do fm_files="$fm_files $XREF/_$f.tsv"; done
fm_files="$fm_files $XREF/_templates.tsv"
fm_counts=$(awk '{ c[FILENAME]++ }
                 END { for (i = 1; i < ARGC; i++) print (ARGV[i] in c ? c[ARGV[i]] + 0 : 0) }' $fm_files)
{
    for f in $ENTITY_CACHES; do
        IFS= read -r n
        printf '  data/flow-manager/base/_%s.tsv: %s entr(y/ies)\n' "$f" "$n"
    done
    for f in $PAIR_CACHES; do
        IFS= read -r n
        printf '  data/flow-manager/xref/_%s.tsv: %s pair(s)\n' "$f" "$n"
    done
    IFS= read -r n
    printf '  data/flow-manager/xref/_templates.tsv: %s template(s)\n' "$n"
} <<< "$fm_counts" >&2
# The CONFIGURED-NAME snapshot (2026-08): base/.configured.tsv, "<list>\t<name>"
# for every entity the EXPORT defines, taken here where the base lists are still
# exactly the config — the two build steps that follow APPEND discovered
# entities to them (bin/build/seen-in-server-log.sh its server-log blues,
# bin/build/result.sh its transfer discoveries). Without this snapshot nothing
# downstream can tell a configured flow from an appended one, so a discovery
# whose evidence is later withdrawn stays in the estate for ever as a phantom
# "configured but never seen" row — which is how the caches once grew to 696
# rows for 568 configured flows. bin/build/result.sh prunes against it.
: > "$BASE/.configured.tsv.tmp"
for _cf in "$BASE"/_*.tsv; do
    [ -f "$_cf" ] || continue
    _cn=$(basename "$_cf" .tsv)
    cut -f1 "$_cf" | awk -v L="$_cn" 'NF { print L "\t" $0 }' >> "$BASE/.configured.tsv.tmp"
done
LC_ALL=C sort -o "$BASE/.configured.tsv.tmp" "$BASE/.configured.tsv.tmp"
if cmp -s "$BASE/.configured.tsv.tmp" "$BASE/.configured.tsv" 2>/dev/null
then rm -f "$BASE/.configured.tsv.tmp"; else mv "$BASE/.configured.tsv.tmp" "$BASE/.configured.tsv"; fi

echo "flow-manager.sh: wrote 10 entity caches to data/flow-manager/base/ + 90 pair caches (every pair both ways) + the patterns and templates maps to data/flow-manager/xref/" >&2
