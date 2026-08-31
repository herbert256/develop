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
# "name<TAB>direction"; see the PDA section below), derived from the LOGICAL
# flow names (part 1 = domain, part 2 = application, part 3 = partner token;
# partners merged by shared host / whitelist IP / whitelisted host IP /
# curated alias) and their cross references against the other entities, all
# composed through the FlowID: accounts/subscriptions/profiles/logins/hosts x
# partners/apps/domains, partners-apps/partners-domains/apps-domains, and the
# *-white joins.
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
# the three PART-REPLACEMENT maps for the Logical-based PDA derivation
# (input/logical_{domains,apps,partners}.txt — FROM<ws>TO per line): part
# 1/2/3 of a three-part Logical name equal to FROM becomes TO before it
# turns into the domain / application / partner-merge token. The Logical
# entity name itself is untouched. Freshness deps like the others.
LOGDOMF="$ROOT/input/logical_domains.txt"
LOGAPPF="$ROOT/input/logical_apps.txt"
LOGPTNF="$ROOT/input/logical_partners.txt"
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
ENTITY_CACHES="accounts logins hosts white subscriptions profiles logicals partners apps domains bl"
ITEMS="accounts subscriptions profiles logins hosts logicals partners apps domains bl white"
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
PAIR_CACHES="$(printf '%s ' $CANON_PAIRS $MIRROR_PAIRS)subscriptions-patterns subscriptions-flowdir subscriptions-ucderived logical-rules"

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
       || { [ -f "$LOGICALF" ] && [ "$LOGICALF" -nt "$out" ]; } \
       || { [ -f "$LOGDOMF" ] && [ "$LOGDOMF" -nt "$out" ]; } \
       || { [ -f "$LOGAPPF" ] && [ "$LOGAPPF" -nt "$out" ]; } \
       || { [ -f "$LOGPTNF" ] && [ "$LOGPTNF" -nt "$out" ]; }; then fresh=0; break; fi
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

# ---- LOGICAL flow groups (2026-08-30 acc-vs-prod; FULL entity 2026-08-31) ----
# One env's FlowIDs (base/_profiles.tsv = the customAttribute_FlowIdentifier
# values) condensed into logical flow groups, one name per group, always 3
# parts. Three passes:
# 1) GROUP — FIRST rule for 4-part FlowIDs (2026-08-30, user request): when
#    the 3rd part is the 3rd part of TWO OR MORE 4-part FlowIDs, the 4th
#    part drops (SI_GOUDMIJN_INSHARED_{HEMA,HEMAPOLIS,INSHARED,POLIS} ->
#    one SI_GOUDMIJN_INSHARED) — UNLESS the 4TH part is itself a known 3rd
#    part of a 3-part FlowID (2026-08-31, user rule): then the FlowID is a
#    full D_A1_A2_P shape, no grouping, and the reshape keeps first and
#    last and combines parts 2+3 (DPL_AXINI-AO_IMPRESS stays itself). Then: 4-part FlowIDs sharing their first 3
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
# the entity->logical pair caches, composed from the profiles pairs.
# Placed BEFORE the PDA section: the PDA derivation now STARTS from this
# map (the Logical is the base — part 1 = domain, part 2 = application,
# part 3 = partner token). The _logicals-{partners,apps,domains} pairs are
# emitted by the PDA pass itself. Every composed file is ALWAYS written —
# possibly empty — for the mirror and freshness loops (set -e).
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
    # INTAKE NORMALIZATION (2026-08-30; hardened 2026-08-31, user request:
    # "before splitting a FlowID into parts, replace - with _"): the estate
    # mixes "-" and "_" spellings of one name (the family matches
    # everything sepfolded), but this derivation splits on "_" alone — a
    # dash-spelled sibling parsed into different part counts and every
    # grouping rule missed it. Group on the "_"-folded form, with DOUBLED
    # separators collapsed and edge separators trimmed — a raw "-_" run or
    # a trailing "-" otherwise splits into an EMPTY part, which the
    # reshape then joins into a dangling-dash artifact ("PEGAWBA-"). A
    # FIXED mapping matches the RAW spelling first, then the folded one.
    # The reshape re-adds dashes for its joins.
    $1 != "" { raw = $1; nn++
        raws[nn] = raw
        nm0 = raw; gsub(/-/, "_", nm0); gsub(/_+/, "_", nm0)
        sub(/^_/, "", nm0); sub(/_$/, "", nm0)
        if (nm0 != raw) IR[nn] = "separators normalized"
        if (raw in FIX)      { finalfix[nn] = FIX[raw]; PINR[nn] = "pinned in input/logical.txt"; next }
        else if (nm0 in FIX) { finalfix[nn] = FIX[nm0]; PINR[nn] = "pinned in input/logical.txt (folded spelling)"; next }
        name[nn] = nm0; exists[nm0] = 1 }
    END {
        # pass 1a: count the reductions — per DISTINCT folded name (2026-08-31:
        # the "-" and "_" spellings of ONE FlowID fold to the same name and
        # counted as a 2-member family, so the variant-drop rules fired on a
        # family of one: DPL_AXINI-AO_IMPRESS + DPL_AXINI_AO_IMPRESS made
        # cnt3rd[AO] 2 and dropped IMPRESS)
        for (i = 1; i <= nn; i++) {
            if (i in finalfix) continue
            if (cdup[name[i]]++) continue
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
                if (pre in exists) { lg = pre; R1[i] = "4 parts: the bare 3-part name exists - 4th part dropped" }
                # a REAL variant family — the same first 3 parts with 2+
                # DISTINCT 4th parts — groups even when a 4th part happens
                # to be a known 3rd part (2026-08-31: the keep-gate below
                # split SI_GOUDMIJN_INSHARED-{POLIS,INSHARED} and the
                # DIRIGENT/SPOTLER label families before this outranked it)
                else if (cnt1[pre] >= 2) { lg = pre; R1[i] = "4 parts: first 3 parts shared by 2+ FlowIDs - 4th part dropped" }
                # the 4TH part being itself a known 3rd part of a 3-part
                # FlowID — with NO variant family on this prefix — means a
                # full D_A1_A2_P shape (2026-08-31, user rule): no drop, the
                # reshape keeps first and last and combines parts 2+3
                # (DPL_AXINI-AO_IMPRESS stays DPL_AXINI-AO_IMPRESS)
                else if (P[4] in third3) { }
                # then: a 3rd part that is the 3rd part of 2+ 4-part
                # FlowIDs — or of any 3-PART FlowID (the restated rule)
                else if (cnt3rd[P[3]] >= 2 || (P[3] in third3)) { lg = pre; R1[i] = "4 parts: 3rd part is a known 3rd part - 4th part dropped" }
                else for (j = 1; j <= n; j++) if (P[j] ~ /^[0-9]+$/) {
                    c = rejoin(P, n, j)
                    if (cnt3[c] >= 2 || (c in exists)) { lg = c; R1[i] = "4 parts: numeric part " j " dropped"; break } }
            } else if (n == 3)
                for (j = 1; j <= n; j++) { s = digitstrip(P[j])
                    if (s != P[j] && s != "") { c = replaced(P, n, j, s)
                        if (cnt2[c] >= 2 || (c in exists)) { lg = c; R1[i] = "digit tail stripped from part " j; break } } }
            else if (n == 1) { s = digitstrip(P[1])
                if (s != P[1] && s != "" && (cnt2[s] >= 2 || (s in exists))) { lg = s; R1[i] = "single part: digit tail stripped" } }
            else if (n >= 5)
                # fold onto the LONGEST part-prefix (3+ parts) that
                # exists as a FlowID of its own
                for (k = n - 1; k >= 3; k--) {
                    pre = P[1]
                    for (m = 2; m <= k; m++) pre = pre "_" P[m]
                    if (pre in exists) { lg = pre; R1[i] = "5+ parts: folded onto the longest existing prefix"; break }
                }
            # a fixed mapping for the GROUP a fold landed on wins too
            if (lg in FIX) { finalfix[i] = FIX[lg]
                PINR[i] = (R1[i] != "" ? R1[i] "; " : "") "group name pinned in input/logical.txt"; continue }
            grpof[i] = lg; lset[lg] = 1
        }
        # pass 2: reshape to 3 parts by position
        for (l in lset) { n = split(l, P, "_"); if (n == 3) { k2[P[2]] = 1; k3[P[3]] = 1 } }
        for (l in lset) {
            n = split(l, P, "_"); nl = l
            if (n == 2) { nl = P[1] "_" P[1] "_" P[2]; M2R[l] = "2 parts: first part doubled (domain = application)" }
            else if (n == 4 && (P[4] in k3)) { nl = P[1] "_" P[2] "-" P[3] "_" P[4]; M2R[l] = "4 parts: parts 2+3 combined (4th is a known 3rd part)" }
            else if (n == 4 && (P[2] in k2)) { nl = P[1] "_" P[2] "_" P[3] "-" P[4]; M2R[l] = "4 parts: parts 3+4 combined (2nd is a known 2nd part)" }
            else if (n == 5 && (P[5] in k3)) { nl = P[1] "_" P[2] "-" P[3] "-" P[4] "_" P[5]; M2R[l] = "5 parts: middle parts combined (5th is a known 3rd part)" }
            map2[l] = nl; lset2[nl] = 1
        }
        # pass 3: force what is left to 3 parts
        split("", k2); split("", k3)
        for (l in lset2) { n = split(l, P, "_"); if (n == 3) { k2[P[2]] = 1; k3[P[3]] = 1 } }
        for (l in lset2) {
            n = split(l, P, "_"); nl = l
            if (n > 3) {
                done = 0
                for (j = 2; j <= n && !done; j++) if (P[j] in k3) { nl = P[1] "_" joindash(P, n, j, 2) "_" P[j]; M3R[l] = "forced: part " j " is a known 3rd part, the rest combined as the 2nd"; done = 1 }
                for (j = 2; j <= n && !done; j++) if (P[j] in k2) { nl = P[1] "_" P[j] "_" joindash(P, n, j, 2); M3R[l] = "forced: part " j " is a known 2nd part, the rest combined as the 3rd"; done = 1 }
                if (!done) { nl = P[1] "_" joindash(P, n - 1, 0, 2) "_" P[n]; M3R[l] = "forced: first and last kept, the middle combined" }
            }
            map3[l] = nl
        }
        # the map: every configured FlowID -> its final Logical, third
        # column = the rule trail that produced it ("; "-joined, the
        # Logical-detection analyses page renders it — 2026-08-31)
        for (i = 1; i <= nn; i++) {
            if (i in finalfix) { fin = finalfix[i]; rt = PINR[i] }
            else {
                l = grpof[i]; fin = map3[map2[l]]
                rt = ""
                if (R1[i] != "") rt = R1[i]
                if (M2R[l] != "") rt = rt (rt == "" ? "" : "; ") M2R[l]
                if (M3R[map2[l]] != "") rt = rt (rt == "" ? "" : "; ") M3R[map2[l]]
                if (rt == "") rt = "3 parts - kept as-is"
            }
            if (IR[i] != "") rt = IR[i] "; " rt
            print raws[i] "\t" fin "\t" rt
        }
    }' "$BASE/_profiles.tsv" | LC_ALL=C sort -u > "$XREF/_logical-rules.tsv"
cut -f1,2 "$XREF/_logical-rules.tsv" > "$XREF/_profiles-logicals.tsv"
cut -f2 "$XREF/_profiles-logicals.tsv" | LC_ALL=C sort -u > "$BASE/_logicals.tsv"
# xcompose MAPFILE PAIRFILE PCOL SIDE OUT — join a profile-keyed pair cache
# with a profile->value map (multi-valued safe; the join is RAW — every
# consumer file carries the same jq-extracted FlowID spellings); the mapped
# value lands LEFT or RIGHT of the pair file's other column. The output is
# ALWAYS written (possibly empty).
xcompose() {
    {   if [ -f "$1" ] && [ -f "$XREF/$2" ]; then
            awk -F'\t' -v pc="$3" -v side="$4" '
                FILENAME == ARGV[1] { if ($1 != "" && $2 != "") MP[$1] = MP[$1] "\037" $2; next }
                { p = (pc == 1) ? $1 : $2; o = (pc == 1) ? $2 : $1
                  if (p in MP) { n = split(substr(MP[p], 2), V, "\037")
                      for (i = 1; i <= n; i++) if (side == "LEFT") print V[i] "\t" o
                                               else                print o "\t" V[i] } }
            ' "$1" "$XREF/$2"
        fi
    } | LC_ALL=C sort -u > "$XREF/_$5.tsv"
}
xcompose "$XREF/_profiles-logicals.tsv" _accounts-profiles.tsv      2 RIGHT accounts-logicals
xcompose "$XREF/_profiles-logicals.tsv" _subscriptions-profiles.tsv 2 RIGHT subscriptions-logicals
xcompose "$XREF/_profiles-logicals.tsv" _profiles-logins.tsv        1 RIGHT logins-logicals
xcompose "$XREF/_profiles-logicals.tsv" _profiles-hosts.tsv         1 RIGHT hosts-logicals
xcompose "$XREF/_profiles-logicals.tsv" _profiles-white.tsv         1 LEFT  logicals-white

# ------------------------------------------- partners / apps / domains (PDA)
# The three PDA entities behind the home page's "Logical, Partners, Domains &
# Applications" table, derived HERE so the caches are the single source
# (bin/build/publish.sh consumes them and only adds the Seen/Result
# enrichment). Each base file is "name<TAB>direction" with direction in /
# both / out ("" when none of the member flows has a login or host side).
#
# THE BASE IS THE LOGICAL ENTITY (2026-08-30, user request — replacing the
# account-NAME derivation: the pda_split machinery, the subscription-name
# fallback, the transitive sjoin pairs and the subscription-less-partner
# prune are all RETIRED). An unpinned Logical name has exactly three
# "_"-parts D_A_P:
#   part 1 = the DOMAIN, part 2 = the APPLICATION, part 3 = the PARTNER token.
# A pinned Logical with any other part count (input/logical.txt — the
# monitor's INFRA-MONITOR-UC) contributes NOTHING. Domains and applications
# are done there; PARTNER TOKENS then MERGE (union-find; combined name = the
# sorted member tokens joined with "_") when
#   (1) their logical flows connect to the same configured host,
#   (2) their logical flows whitelist the same IP,
#   (3) one partner's host resolves to an IP another partner whitelists,
#   (4) a hand-curated alias pair names them one organisation
#       (input/partner-aliases.tsv — which also still supplies the CANONICAL
#       group name via the alias star, so a merged group can be called
#       GLOBEX instead of GLOBEX_GLOBEXX).
# Every partner/app/domain pair cache is COMPOSED through the FlowID (the
# entity->profile pairs joined with the _profiles-{partners,apps,domains}
# maps this pass emits), so the whole estate joins through one spine:
# profile -> logical -> D/A/P. There is NO PRUNE any more — every partner
# descends from a subscription's FlowID by construction, so a
# subscription-less partner cannot exist.
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

awk -F'\t' -v BP="$BASE/.pda.partners.tmp" -v BA="$BASE/.pda.apps.tmp" -v BD="$BASE/.pda.domains.tmp" \
    -v FP="$OUT/.pda.fp.tmp" -v FA="$OUT/.pda.fa.tmp" -v FD="$OUT/.pda.fd.tmp" \
    -v LGP="$OUT/.pda.lp.tmp" -v LGA="$OUT/.pda.la.tmp" -v LGD="$OUT/.pda.ld.tmp" \
    -v PAP="$OUT/.pda.pap.tmp" -v PDM="$OUT/.pda.pdm.tmp" -v ADM="$OUT/.pda.adm.tmp" \
    -v WHYF="$XREF/.pda.why.tmp" -v GRPF="$XREF/.pda.groups.tmp" -v GAF="$XREF/.pda.gacct.tmp" \
    -v ALIASF="$ALIASF" -v LDF="$LOGDOMF" -v LAF="$LOGAPPF" -v LPF="$LOGPTNF" '
    # ---- group-merge EVIDENCE (why two partner tokens are combined) ----
    # Each rule firing that links two DIFFERENT tokens records one edge; the
    # group is resolved at END (find()). Deduped by signature.
    function recordev(rule, ta, tb, txt,   sig){ if(ta==""||tb==""||ta==tb) return
        sig=rule SUBSEP ta SUBSEP tb SUBSEP txt; if(sig in seenev) return; seenev[sig]=1
        EVN++; EVA[EVN]=ta; EVB[EVN]=tb; EVR[EVN]=rule; EVT[EVN]=txt }
    function find(x){ if(!(x in par)) par[x]=x; while(par[x]!=x){par[x]=par[par[x]]; x=par[x]} return x }
    function uni(a,b,  ra,rb){ if(a==""||b=="") return; ra=find(a); rb=find(b); if(ra!=rb){par[ra]=rb; nmerge++} }
    # I/O letter soup -> the base direction word ("" = no side known)
    function dirw(s,  i2,o2){ i2=(index(s,"I")>0); o2=(index(s,"O")>0)
        return (i2&&o2)?"both":(i2?"in":(o2?"out":"")) }
    # a hand-curated FROM<ws>TO replacement map (missing file = no-op)
    function loadrep(f, M,   l9, n9, a9){ while((getline l9 < f) > 0){
            if(l9 ~ /^[ \t]*#/ || l9 ~ /^[ \t]*$/) continue
            n9=split(l9, a9, /[ \t]+/); if(n9>=2 && a9[1]!="" && a9[2]!="") M[a9[1]]=a9[2] }
        close(f) }
    BEGIN { US=sprintf("%c",31)
        loadrep(LDF, DREP); loadrep(LAF, AREP); loadrep(LPF, PREP)
        # the hand-curated alias pairs (input/partner-aliases.tsv; "#" =
        # comment). A SINGLE-token line used to declare a real organisation
        # for the retired name-split helper lists — tolerated and INERT now.
        nal=0
        while ((getline l4 < ALIASF) > 0) { if (l4 ~ /^#/ || l4 == "") continue
            n4=split(l4,a4x,"\t"); if(n4>=2 && a4x[1]!="" && a4x[2]!=""){ ++nal; AL1[nal]=toupper(a4x[1]); AL2[nal]=toupper(a4x[2]); AL2SET[AL2[nal]]=1 } }
        close(ALIASF) }
    FILENAME ~ /_profiles-logicals\.tsv$/ { if($1==""||$2=="") next
        if(!($2 in lseen)){ lseen[$2]=1; lg[++nl]=$2 }
        fl[$2]=fl[$2] US $1; next }
    FILENAME ~ /_profiles-logins\.tsv$/   { pin[$1]=1; next }
    FILENAME ~ /_profiles-hosts\.tsv$/    { ph[$1]=ph[$1] US $2; next }
    FILENAME ~ /_profiles-white\.tsv$/    { pwl[$1]=pwl[$1] US $2; next }
    FILENAME ~ /_accounts-profiles\.tsv$/ { pacc[$2]=pacc[$2] US $1; next }
    { cand[$1]=cand[$1] US $2 }   # PDAIP: endpoint-lower -> candidate IP(s)
    END {
        # per LOGICAL (map-file order — sorted, so deterministic): its FlowID
        # set, side (in = any FlowID with a login, out = any with a host),
        # host set and whitelist set, unioned over the FlowIDs
        for(i=1;i<=nl;i++){ l=lg[i]
            nf=split(substr(fl[l],2),FF,US)
            for(j=1;j<=nf;j++){ f=FF[j]
                if(f in pin) lI[l]=1
                if(f in ph){ lO[l]=1; nh=split(substr(ph[f],2),HH,US)
                    for(h=1;h<=nh;h++) if(!((l SUBSEP HH[h]) in hs)){ hs[l SUBSEP HH[h]]=1; lh[l]=lh[l] US HH[h] } }
                if(f in pwl){ nw=split(substr(pwl[f],2),WW,US)
                    for(w=1;w<=nw;w++) if(!((l SUBSEP WW[w]) in ws)){ ws[l SUBSEP WW[w]]=1; lw[l]=lw[l] US WW[w] } } }
            # THE 3-PART GATE: only a D_A_P name contributes — a pinned
            # short (or long) name has no domain/application/partner slots
            if(split(l,S,"_")!=3) continue
            # the hand-curated PART replacements (input/logical_*.txt): the
            # replaced value is what becomes the entity / the merge token —
            # the Logical name itself is untouched
            if(S[1] in DREP) S[1]=DREP[S[1]]
            if(S[2] in AREP) S[2]=AREP[S[2]]
            if(S[3] in PREP) S[3]=PREP[S[3]]
            dom[l]=S[1]; app[l]=S[2]; tok[l]=S[3]; find(S[3])
            side=((l in lI)?"I":"")((l in lO)?"O":"")
            domd[S[1]]=domd[S[1]] side; appd[S[2]]=appd[S[2]] side
            nh=split(substr(lh[l],2),HH,US); for(h=1;h<=nh;h++) hidx[HH[h]]=hidx[HH[h]] US S[3] "|" l
            nw=split(substr(lw[l],2),WW,US); for(w=1;w<=nw;w++) widx[WW[w]]=widx[WW[w]] US S[3] "|" l }
        # Rule 4 FIRST — the HAND-CURATED ALIAS MAP: two tokens naming ONE
        # organisation merge, the file cited as evidence. Only tokens the
        # estate actually DERIVED merge (an alias to an absent token no-ops).
        # NO fixpoint loop anywhere: no rule reads group state, and
        # union-find keeps every merge transitive.
        for (ai=1; ai<=nal; ai++) { a4=AL1[ai]; b4=AL2[ai]
            if ((a4 in par) && (b4 in par)) {
                recordev(4, a4, b4, "Curated alias: " a4 " and " b4 " name the same organisation (input/partner-aliases.tsv)")
                uni(a4, b4) } }
        # Rule 1 — two partners'"'"' logical flows connect to the same configured host
        for(hh in hidx){ n=split(substr(hidx[hh],2),AA,US)
            for(k=2;k<=n;k++) for(m=1;m<k;m++){ split(AA[m],X,"|"); split(AA[k],Y,"|")
                if(X[1]==Y[1]) continue
                recordev(1, Y[1], X[1], "Logical flows " X[2] " (partner " X[1] ") and " Y[2] " (partner " Y[1] ") both connect to configured host " hh)
                uni(X[1],Y[1]) } }
        # Rule 2 — two partners'"'"' logical flows whitelist the same IP
        for(ww in widx){ n=split(substr(widx[ww],2),AA,US)
            for(k=2;k<=n;k++) for(m=1;m<k;m++){ split(AA[m],X,"|"); split(AA[k],Y,"|")
                if(X[1]==Y[1]) continue
                recordev(2, Y[1], X[1], "Logical flows " X[2] " (partner " X[1] ") and " Y[2] " (partner " Y[1] ") both whitelist IP " ww)
                uni(X[1],Y[1]) } }
        # Rule 3 — a partner'"'"'s host resolves to an IP another partner whitelists
        # (a raw-IP endpoint is its own address; named hosts resolve via the
        # forward-DNS map built above)
        for(i=1;i<=nl;i++){ l=lg[i]; if(!(l in tok)) continue
            nh=split(substr(lh[l],2),HH,US)
            for(h=1;h<=nh;h++){ hh=HH[h]
                if(hh ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ipl=US hh; else ipl=(hh in cand)?cand[hh]:""
                ni=split(substr(ipl,2),IPS,US)
                for(p=1;p<=ni;p++){ ip=IPS[p]; if(!(ip in widx)) continue
                    n=split(substr(widx[ip],2),AA,US)
                    for(k=1;k<=n;k++){ split(AA[k],Y,"|"); if(Y[1]==tok[l]) continue
                        recordev(3, tok[l], Y[1], "Logical flow " l " (partner " tok[l] ") connects to " hh " (IP " ip "), which logical flow " Y[2] " (partner " Y[1] ") whitelists")
                        uni(tok[l],Y[1]) } } } }
        # groups: members + direction = the union of the member LOGICALS'"'"' sides
        for(i=1;i<=nl;i++){ l=lg[i]; if(!(l in tok)) continue
            r=find(tok[l]); if(index(US memb[r] US, US tok[l] US)==0) memb[r]=memb[r] US tok[l]
            if(l in lI) gI[r]=1; if(l in lO) gO[r]=1 }
        # group name = sorted-unique member tokens joined by _ ; the
        # hand-curated alias STAR can override it with ONE canonical token
        for(r in memb){ delete seen; m=split(substr(memb[r],2),TT,US); c=0
            for(k=1;k<=m;k++) if(!(TT[k] in seen)){ seen[TT[k]]=1; ARR[++c]=TT[k] }
            for(x=2;x<=c;x++){ v=ARR[x]; y=x-1; while(y>=1 && ARR[y]>v){ARR[y+1]=ARR[y];y--} ARR[y+1]=v }
            gn=ARR[1]; for(x=2;x<=c;x++) gn=gn "_" ARR[x]
            # CANONICAL GROUP NAME (2026-08-29): when EVERY member has a direct
            # alias pair (input/partner-aliases.tsv) with ONE token — a member
            # itself (the SchubergPhilis star) or a pure NAME the estate never
            # derives (the RABOBANK_PEKO case) — the group takes that token as
            # its name instead of the joined list. Candidates = the members
            # plus every token paired with one, scanned in sorted order so a
            # tie is deterministic.
            if(c>1){
                delete CAND
                for(x=1;x<=c;x++){ CAND[ARR[x]]=1
                    for(ai2=1;ai2<=nal;ai2++){ if(AL1[ai2]==ARR[x]) CAND[AL2[ai2]]=1; if(AL2[ai2]==ARR[x]) CAND[AL1[ai2]]=1 } }
                nc2=0; for(cn in CAND) CARR[++nc2]=cn
                for(x=2;x<=nc2;x++){ v2=CARR[x]; y=x-1; while(y>=1 && CARR[y]>v2){CARR[y+1]=CARR[y];y--} CARR[y+1]=v2 }
                # the alias file convention is variant<TAB>CANONICAL: a
                # candidate appearing on the RIGHT side of a pair outranks
                # the rest (WONKA beats its variant WNK — with two members
                # both qualify, and bare sorted order picked the variant);
                # sorted order breaks the remaining ties
                fnd=0
                for(p2s=1;p2s<=2 && !fnd;p2s++)
                for(x=1;x<=nc2 && !fnd;x++){ cn=CARR[x]
                    if(p2s==1 && !(cn in AL2SET)) continue
                    if(p2s==2 &&  (cn in AL2SET)) continue
                    ok2=1
                    for(y=1;y<=c && ok2;y++){ if(ARR[y]==cn) continue
                        ok2=0
                        for(ai2=1;ai2<=nal;ai2++) if((AL1[ai2]==cn && AL2[ai2]==ARR[y]) || (AL2[ai2]==cn && AL1[ai2]==ARR[y])){ ok2=1; break } }
                    if(ok2){ gn=cn; fnd=1 } } }
            gname[r]=gn
            # a GROUP = more than one member token; record it (name / members / direction)
            if(c>1){ mm=ARR[1]; for(x=2;x<=c;x++) mm=mm "," ARR[x]
                MULTI[r]=1
                print gn "\t" mm "\t" dirw(((gI[r])?"I":"") ((gO[r])?"O":"")) > GRPF } }
        # the partner base rows (group -> direction)
        for(r in memb) print gname[r] "\t" dirw(((gI[r])?"I":"") ((gO[r])?"O":"")) > BP
        # the apps / domains base rows (part 2 / part 1 -> direction)
        for(k in appd) print k "\t" dirw(appd[k]) > BA
        for(k in domd) print k "\t" dirw(domd[k]) > BD
        # the maps and within-logical pairs: FlowID -> group/app/domain,
        # Logical -> group/app/domain, partners-apps / partners-domains /
        # apps-domains (co-members of one logical), and the group-page
        # Member table rows (group / token / account — the accounts behind
        # the token'"'"'s logical flows; multi-member groups only)
        for(i=1;i<=nl;i++){ l=lg[i]; if(!(l in tok)) continue
            g=gname[find(tok[l])]
            print l "\t" g > LGP; print l "\t" app[l] > LGA; print l "\t" dom[l] > LGD
            print g "\t" app[l] > PAP; print g "\t" dom[l] > PDM; print app[l] "\t" dom[l] > ADM
            nf=split(substr(fl[l],2),FF,US)
            for(j=1;j<=nf;j++){ f=FF[j]
                print f "\t" g > FP; print f "\t" app[l] > FA; print f "\t" dom[l] > FD }
            if(find(tok[l]) in MULTI){
                for(j=1;j<=nf;j++){ na2=split(substr(pacc[FF[j]],2),PA,US)
                    for(m=1;m<=na2;m++) print g "\t" tok[l] "\t" PA[m] > GAF } } }
        # resolve each merge-evidence edge to its final group name (why
        # combined): group / token pair (A<=B) / rule / human evidence line
        for(e=1;e<=EVN;e++){ ra=find(EVA[e]); if(ra!=find(EVB[e])) continue
            ta=EVA[e]; tb=EVB[e]; if(ta>tb){ tt=ta; ta=tb; tb=tt }
            print gname[ra] "\t" ta "\t" tb "\t" EVR[e] "\t" EVT[e] > WHYF }
    }
' "$XREF/_profiles-logicals.tsv" "$XREF/_profiles-logins.tsv" "$XREF/_profiles-hosts.tsv" \
  "$XREF/_profiles-white.tsv" "$XREF/_accounts-profiles.tsv" "$PDAIP"
LC_ALL=C sort -u "$BASE/.pda.partners.tmp" 2>/dev/null > "$BASE/_partners.tsv" || : > "$BASE/_partners.tsv"
LC_ALL=C sort -u "$BASE/.pda.apps.tmp"     2>/dev/null > "$BASE/_apps.tsv"     || : > "$BASE/_apps.tsv"
LC_ALL=C sort -u "$BASE/.pda.domains.tmp"  2>/dev/null > "$BASE/_domains.tsv"  || : > "$BASE/_domains.tsv"
# the partner GROUPS (multi-member) and the per-group merge evidence (why combined)
LC_ALL=C sort -u "$XREF/.pda.groups.tmp" 2>/dev/null > "$XREF/_partner-groups.tsv" || : > "$XREF/_partner-groups.tsv"
LC_ALL=C sort -u "$XREF/.pda.why.tmp"    2>/dev/null > "$XREF/_partner-group-why.tsv" || : > "$XREF/_partner-group-why.tsv"
LC_ALL=C sort -u "$XREF/.pda.gacct.tmp"  2>/dev/null > "$XREF/_partner-group-accounts.tsv" || : > "$XREF/_partner-group-accounts.tsv"
# the FlowID -> P/A/D maps (the composition spine), the Logical pairs and
# the within-logical pairs
LC_ALL=C sort -u "$OUT/.pda.fp.tmp"  2>/dev/null > "$XREF/_profiles-partners.tsv" || : > "$XREF/_profiles-partners.tsv"
LC_ALL=C sort -u "$OUT/.pda.fa.tmp"  2>/dev/null > "$XREF/_profiles-apps.tsv"     || : > "$XREF/_profiles-apps.tsv"
LC_ALL=C sort -u "$OUT/.pda.fd.tmp"  2>/dev/null > "$XREF/_profiles-domains.tsv"  || : > "$XREF/_profiles-domains.tsv"
LC_ALL=C sort -u "$OUT/.pda.lp.tmp"  2>/dev/null > "$XREF/_logicals-partners.tsv" || : > "$XREF/_logicals-partners.tsv"
LC_ALL=C sort -u "$OUT/.pda.la.tmp"  2>/dev/null > "$XREF/_logicals-apps.tsv"     || : > "$XREF/_logicals-apps.tsv"
LC_ALL=C sort -u "$OUT/.pda.ld.tmp"  2>/dev/null > "$XREF/_logicals-domains.tsv"  || : > "$XREF/_logicals-domains.tsv"
LC_ALL=C sort -u "$OUT/.pda.pap.tmp" 2>/dev/null > "$XREF/_partners-apps.tsv"     || : > "$XREF/_partners-apps.tsv"
LC_ALL=C sort -u "$OUT/.pda.pdm.tmp" 2>/dev/null > "$XREF/_partners-domains.tsv"  || : > "$XREF/_partners-domains.tsv"
LC_ALL=C sort -u "$OUT/.pda.adm.tmp" 2>/dev/null > "$XREF/_apps-domains.tsv"      || : > "$XREF/_apps-domains.tsv"
rm -f "$BASE/.pda.partners.tmp" "$BASE/.pda.apps.tmp" "$BASE/.pda.domains.tmp" \
      "$OUT"/.pda.fp.tmp "$OUT"/.pda.fa.tmp "$OUT"/.pda.fd.tmp \
      "$OUT"/.pda.lp.tmp "$OUT"/.pda.la.tmp "$OUT"/.pda.ld.tmp \
      "$OUT"/.pda.pap.tmp "$OUT"/.pda.pdm.tmp "$OUT"/.pda.adm.tmp \
      "$XREF/.pda.groups.tmp" "$XREF/.pda.why.tmp" "$XREF/.pda.gacct.tmp" "$PDAIP"

# every remaining partner/app/domain pair cache is COMPOSED through the
# FlowID: the entity->profile pairs joined with the _profiles-<X> maps
# (replaces the retired ajoin/sjoin/fallback machinery — the transitive
# pairs are now exact by construction, everything joins through the FlowID)
for _e in partners apps domains; do
    _m="$XREF/_profiles-$_e.tsv"
    xcompose "$_m" _accounts-profiles.tsv      2 RIGHT "accounts-$_e"
    xcompose "$_m" _subscriptions-profiles.tsv 2 RIGHT "subscriptions-$_e"
    xcompose "$_m" _profiles-logins.tsv        1 RIGHT "logins-$_e"
    xcompose "$_m" _profiles-hosts.tsv         1 RIGHT "hosts-$_e"
    xcompose "$_m" _profiles-white.tsv         1 LEFT  "$_e-white"
done
unset _e _m

# ------------------------------------------- BL (the business-line tag)
# The subscriptions.json tags[] entry starting with "BL" as a FULL entity
# (2026-08-31, user request), LAST in the Logical/Partners/Domains/
# Applications group. The spine is the SUBSCRIPTION: a subscription carries
# its BL tag(s) verbatim (BL_FIN — never stripped; several tags = several
# rows), and every other bl pair cache is composed from the subscription
# pairs. Placed AFTER the PDA section (its _subscriptions-{partners,apps,
# domains} inputs must exist) and BEFORE the mirror loop.
{   if command -v jq >/dev/null 2>&1 && [ -f "$SKIPDIR/subscriptions.json" ]; then
        jq -r '.[] | .name as $n | (.tags // [])[] | select(startswith("BL")) | [$n, .] | @tsv' \
            "$SKIPDIR/subscriptions.json" 2>/dev/null || true
    fi
} | LC_ALL=C sort -u > "$XREF/_subscriptions-bl.tsv"
cut -f2 "$XREF/_subscriptions-bl.tsv" | LC_ALL=C sort -u > "$BASE/_bl.tsv"
xcompose "$XREF/_subscriptions-bl.tsv" _accounts-subscriptions.tsv      2 RIGHT accounts-bl
xcompose "$XREF/_subscriptions-bl.tsv" _subscriptions-logins.tsv        1 RIGHT logins-bl
xcompose "$XREF/_subscriptions-bl.tsv" _subscriptions-hosts.tsv         1 RIGHT hosts-bl
xcompose "$XREF/_subscriptions-bl.tsv" _subscriptions-profiles.tsv      1 RIGHT profiles-bl
xcompose "$XREF/_subscriptions-bl.tsv" _subscriptions-logicals.tsv      1 RIGHT logicals-bl
xcompose "$XREF/_subscriptions-bl.tsv" _subscriptions-partners.tsv      1 RIGHT partners-bl
xcompose "$XREF/_subscriptions-bl.tsv" _subscriptions-apps.tsv          1 RIGHT apps-bl
xcompose "$XREF/_subscriptions-bl.tsv" _subscriptions-domains.tsv       1 RIGHT domains-bl
xcompose "$XREF/_subscriptions-bl.tsv" _subscriptions-white.tsv         1 LEFT  bl-white

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
adddir bl            "$XREF/_bl-logins.tsv"            "$XREF/_bl-hosts.tsv"
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

echo "flow-manager.sh: wrote 11 entity caches to data/flow-manager/base/ + 110 pair caches (every pair both ways) + the patterns and templates maps to data/flow-manager/xref/" >&2
