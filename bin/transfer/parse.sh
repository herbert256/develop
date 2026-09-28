#!/usr/bin/env bash
#
# parse.sh — the single tokenizing pass shared by every transfer report.
#
# Reads input/*.csv ONCE with the hand-rolled CSV tokenizer and writes a
# normalized TAB-separated cache (data/_transfers.tsv, gitignored) that the report
# scripts then consume with a plain `awk -F'\t'` — no more re-tokenizing 170 MB
# once per report. Its column names are also written to data/_transfers.txt. Also
# DROPS any exact record line that repeats across the inputs (keeping the first
# occurrence) and notes how many, so a repeated or overlapping export cannot
# double-count records.
#
# TWO-STAGE CACHE. The tokenizer + blacklist + hostname mapping produce the
# raw cache data/_transfers0.tsv; a final
# CoreId-group PROPAGATION pass derives data/_transfers.tsv from it: within each
# CoreId group, an entity value (account, login, site, host, profile) present
# on some row fills the rows where it is blank — blacklist first, then
# propagate. Reports read only _transfers.tsv.
#
# _transfers.tsv columns (1-based). A "logical transfer" is TWO records in Axway ST
# (an Inbound and an Outbound row) sharing one CoreId, so CoreId is column 1 and
# the file is SORTED by CoreId then Direction — the pair of rows for a transfer
# are adjacent, Inbound before Outbound. Direction is column 2 and Status is 3.
#   1 coreid          CoreId (field 34) — the logical-transfer key
#   2 direction       Direction (field 8), raw (reports default empty->UNKNOWN)
#   3 status          raw Status (field 1); reports apply their own fold
#   4 account         Account (field 2) with @... stripped; blacklist blanked
#   5 login           Login (field 3); blacklist blanked; if then blank and Account
#                     has an @suffix, the part after @ (the FE endpoint) is used
#   6 site            Transfer Site (field 7); a LOGGED value MUST start with "UC"
#                     (every real subscription does) — anything else (P14303_CFT01,
#                     "none", "Clone - ..." artifacts) is blanked; kept only up to
#                     _SCP_ / _SSCP_ / _CCP_ (the clean subscription name, tail dropped).
#                     A group no pass could attribute — not even the SESSION
#                     JOIN (the server log naming the flow of the connection,
#                     joined on col 24; bin/session-sites.sh) — keeps the
#                     SYNTHETIC name "UCx_<account>" (see the FAKE SUBSCRIPTION
#                     step) — the UC shape with an unknowable UC number.
#                     When the rule blanked it on EVERY row of a CoreId group,
#                     recovered from the config via the profile (see CONFIG FALLBACK)
#   7 action_by       Action By (field 9)
#   8 file            Local Filename (field 15) — the real file basename, populated
#                     on every row (field 10 "File" holds the account name on the
#                     outbound rows, so it is not used)
#   9 size            Size (field 19), integer, 0 if non-numeric
#  10 protocol        Protocol (field 20)
#  11 date_iso        Start Time date as ccyy-mm-dd, "" if not MM/DD/YYYY
#  12 time            Start Time time part (HH:MM:SS.mmm), "" if absent
#  13 sortkey         YYYYMMDD+time when the date is valid, else ""
#  14 jdn             Julian day number of the start date, else ""
#  15 duration        Duration (field 25) in milliseconds (integer), -1 if none
#  16 remote_host     Remote Host (field 26), LOWERCASED (endpoints are
#                     canonically lowercase, site-wide); an IPv4 value is
#                     replaced by its endpoint name from input/<env>/ip/,
#                     which the AUTOMATIC rule below fills: the configured host
#                     of the account for an outgoing address; an incoming
#                     name (or the IP itself, when there is no PTR) for an
#                     incoming one. Never hand-written.
#  17 av_bucket       ICAP Details (field 17) classified: Allowed/Blocked/
#                     Not performed/Error/Unknown/Other
#  18 end_time        End Time (field 24) RAW
#  19 secparams       SecurityParameters (field 38) RAW
#  20 mode            Mode (field 22): BINARY / ASCII / unknown
#  21 profile         Transfer Profile (field 12) — the configured flow name,
#                     "UNKNOWN" when the row carries none
#  22 resubmitted     Resubmitted (field 35): true / false
#  23 transfer_id     Transfer ID (field 29) — a per-row identifier (~unique per
#                     row; a CoreId spans many)
#  24 session_id      Session ID (field 30) RAW — the TECHNICAL connection the
#                     leg travelled in (one SSH/PESIT connection = one id; an
#                     SFTP client commonly opens a fresh connection per
#                     operation). Re-added 2026-08 for the same-connection
#                     UC2/UC4 shared-drop proof in uc2-status.sh; Session
#                     Start Time (field 31) stays out (no reader).
#  25 application     Application (field 6) RAW — the export's own attribute,
#                     NOT the derived application entity. "none" on the empty
#                     outbound ssh probes the parse-time skip drops
#                     (2026-09-08, user request).
#
# Values are emitted unescaped except that TAB/CR/LF are scrubbed to a space so
# they can never break the TAB line protocol (none occur in the current data).
#
# ALWAYS A FULL PARSE (2026-09-28: every build is fresh — the manifest, the
# parser signature and the incremental merge are gone). AXWAY_DERIVE_ONLY=1
# skips the tokenize and rebuilds only the DERIVED caches from the existing
# raw cache — bin/session-sites.sh's re-derive, after it learned flows from
# the server log.
#
# Usage:
#   ./parse.sh                       # build data/_transfers.tsv (+ _transfers.txt) from input/*.csv
#   AXWAY_DERIVE_ONLY=1 ./parse.sh   # rebuild the derived caches from _transfers0.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"   # INPUT_DIR, CACHE_DIR, IP_DIR, CONFIG_DIR, PARSED (= $CACHE_DIR/_transfers.tsv), FILES
source "$ROOT/bin/blacklist.sh"   # BLACKLIST_FILE + BLACKLIST_AWK (bl_load/bl_blank) — input/<env>/blacklist.txt
source "$ROOT/bin/renames.sh"    # RENAMES_FILE + RENAMES_AWK (rn_load/rn_canon) — input/<env>/renames/
source "$ROOT/bin/skiplist.sh"    # SKIPLIST_FILE + SKIPLIST_AWK (sl_load/sl_hit) — input/<env>/skip.txt
source "$ROOT/bin/ranges.sh"      # grp_par: the key-aligned parallel slices of the derive passes (2026-09-28)
_pj=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
case $_pj in ""|*[!0-9]*) _pj=2 ;; esac
PARSED0="$CACHE_DIR/_transfers0.tsv"   # raw (blacklisted, UNpropagated) cache — the derive's input
SESSMAP="$CACHE_DIR/_sessionsites.tsv" # session -> subscription, learned from the server log (bin/session-sites.sh)
# read ONCE and dropped from the environment, so nothing started from inside
# this one inherits it
_derive_only=${AXWAY_DERIVE_ONLY:-}; unset AXWAY_DERIVE_ONLY
LEGEND="$CACHE_DIR/_transfers.txt"
# SKIP LIST (input/<env>/skip.txt, per environment): a record whose ATTRIBUTED
# account (col 4) or subscription/site (col 6) name contains a skip token
# (case-insensitive substring) is dropped from _transfers.tsv (so no report,
# _files.tsv counts it) and set aside in _skipped.tsv for the
# "Skipped" analyses report. Applied in the DERIVE step below (after the
# propagation/config fallback fills the attribution), which runs every parse —
# so the sidecar always reflects the full cache. See bin/flow-manager.sh.
SKIPFILE="$ROOT/input/skip.txt"
SKIPOUT="$DATA/transfer/_skipped.tsv"   # skipped _transfers.tsv rows (verbatim)
# NO-SUBSCRIPTION / HTTP SKIP (narrowed 2026-08): additionally, a CoreId whose
# EVERY row still has no site (col 6) after all attribution passes — or with an
# http leg on ANY row (col 10; web-UI hand traffic, never flow traffic) — is
# dropped from _transfers.tsv / _files.tsv; its RAW input CSV lines go to
# _skipped.csv (verbatim, no formatting). Since the FAKE SUBSCRIPTION step, a
# group WITH an account always has a site, so the no-site arm only catches
# groups with no account either (blacklist-blanked platform traffic). See the
# DERIVE step below.
SKIPCSV="$DATA/transfer/_skipped.csv"   # raw input lines of no-subscription/http CoreIds
# Config-fallback sources: bin/flow-manager.sh's caches of subscriptions.json (see
# the CONFIG FALLBACK section below), built by the config step before this
# parse; if any is missing (no export in input/flow-manager/) the fallback is
# skipped rather than failing the parse.
CFG_SUBS="$CONFIG_BASE/_subscriptions.tsv"           # every configured subscription name
CFG_AS="$CONFIG_XREF/_accounts-subscriptions.tsv"    # account <TAB> subscription
CFG_SP="$CONFIG_XREF/_subscriptions-profiles.tsv"    # subscription <TAB> FlowIdentifier profile
CFG_PAT="$CONFIG_XREF/_subscriptions-patterns.tsv"   # subscription <TAB> patternName (pesit direction)
CFG_FD="$CONFIG_XREF/_subscriptions-flowdir.tsv"     # subscription <TAB> out|in|relay (the FLOWDIR fallback)
# ... and the PDA caches feeding _files.tsv's direction/app/domain/partner
# columns (16-19); a missing cache just leaves its column(s) empty.
CFG_AL="$CONFIG_XREF/_accounts-logins.tsv"           # account <TAB> login  (the account's In side)
CFG_AH="$CONFIG_XREF/_accounts-hosts.tsv"            # account <TAB> host   (the account's Out side)
CFG_SH="$CONFIG_XREF/_subscriptions-hosts.tsv"       # subscription <TAB> host (stands in for a not-yet-propagated account)
CFG_AAPP="$CONFIG_XREF/_accounts-apps.tsv"           # account <TAB> application (name-derived)
CFG_ADOM="$CONFIG_XREF/_accounts-domains.tsv"        # account <TAB> domain
CFG_SAPP="$CONFIG_XREF/_subscriptions-apps.tsv"      # subscription <TAB> application (incl. the subscription-name fallback)
CFG_SDOM="$CONFIG_XREF/_subscriptions-domains.tsv"   # subscription <TAB> domain     (cols 18/19 fall back to these when the account derives none)
CFG_SPTN="$CONFIG_XREF/_subscriptions-partners.tsv"  # subscription <TAB> partner organisation (the precise key; col 20 first)
CFG_APTN="$CONFIG_XREF/_accounts-partners.tsv"       # account <TAB> partner organisation
CFG_HPTN="$CONFIG_XREF/_hosts-partners.tsv"          # configured host <TAB> partner organisation
CFG_FLOW="$CONFIG_XREF/_subscriptions-flowdir.tsv"   # subscription <TAB> out|in|relay (file-movement direction)
mkdir -p "$CACHE_DIR"

# PHASE TIMINGS (2026-09-27): one "TIME Ns  parse: <phase>" lap per phase on
# stderr (name + duration only) — the build profiles a runtime parse from them
_pl0=$(date +%s)
_plap() { local _t1; _t1=$(date +%s); printf 'TIME %5ds  parse: %s\n' "$((_t1 - _pl0))" "$1" >&2; _pl0=$_t1; }

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob

# The configured subscription names the tokenizer keeps a logged site for,
# from the pre-discovery snapshot — never base/_subscriptions.tsv, whose
# result column is recoloured every build and whose discovered rows are logged
# values, not configuration.
CFG_CONF="$CONFIG_BASE/.configured.tsv"   # <list> <TAB> <name>: the config lists BEFORE either colour step appends

# CONFIG-ONLY ESTATE (2026-08): an env with the flow-manager exports but not a
# single log CSV is a legitimate state — a fresh clone carries only the JSONs
# (the *.csv exports are gitignored). Write the complete cache set EMPTY
# instead of failing: every downstream consumer then renders "configured,
# never seen" (all orange) rather than aborting the build.
if [ ${#files[@]} -eq 0 ] && [ "$_derive_only" != 1 ]; then
    echo "No *.csv in $INPUT_DIR — writing EMPTY caches (config-only estate)." >&2
    : > "$PARSED0"; : > "$PARSED"; : > "$FILES"
    : > "$SKIPOUT"; : > "$SKIPCSV"
    exit 0
fi

do_tokenize=1
if [ "$_derive_only" = 1 ]; then
    [ -f "$PARSED0" ] || { echo "parse.sh: AXWAY_DERIVE_ONLY=1 but no $PARSED0 — run the full parse first." >&2; exit 1; }
    echo "Rebuilding the derived caches from $PARSED0 ..." >&2
    do_tokenize=0
fi

tmp="$PARSED.tmp.$$"

_plap "setup"
if [ "$do_tokenize" = 1 ]; then

src_files=("${files[@]}")
echo "Parsing ${#src_files[@]} file(s) into $PARSED0 ..." >&2
# the tokenizer over the argument files -> stdout (a function since
# 2026-09-27: the parse runs it on several file groups in parallel)
tok_files() {
awk -v BLF="$BLACKLIST_FILE" -v RNF="$RENAMES_FILE" -v RNP="$RENAMES_PROF" -v CFGC="$CFG_CONF" "$BLACKLIST_AWK$RENAMES_AWK"'
    BEGIN { bl_load(BLF); rn_load(RNF, RNP)
            # the configured subscription names, case-folded -> the configured
            # SPELLING: a logged site naming one is kept whatever its shape
            # (see the site rule below), and site_extfold folds an EXTENDED
            # one back onto it
            while ((getline cl < CFGC) > 0) { split(cl, ca, "\t")
                if (ca[1] == "_subscriptions" && ca[2] != "" && !(toupper(ca[2]) in cfgsub)) {
                    cfgsub[toupper(ca[2])] = ca[2]; CFGN[++ncfg] = toupper(ca[2]) } }
            close(CFGC) }
    # site_extfold — fold an EXTENDED transfer-site token back onto the
    # subscription it names (2026-09-01, user report). ST logs some flows as
    # "<subscription>_<PROTO>_SERVER_<partner>": that value is not a
    # configured name, so the flow was attributed to nothing, its
    # _files.tsv movement (col 17) stayed EMPTY, and the outcome rule — which
    # needs the movement to match the protocol of the last leg — could not say
    # Processed. Every one of those files read FAILED although both legs
    # processed cleanly (production: 418 files over 13 flows; the server
    # reports fold the same shape).
    # The LONGEST configured name the value extends at a name-part boundary
    # wins, and the remainder must be that server/client comm-profile shape —
    # so a genuinely different flow whose name merely starts with a configured
    # one is never swallowed (it stays a logged-but-unconfigured subscription,
    # exactly as before). Memoised per distinct value: the scan is O(names).
    function site_extfold(v,   u, i, best, rest) {
        u = toupper(v)
        if (u in cfgsub) return v
        if (u in EXTM) return EXTM[u]
        best = ""
        for (i = 1; i <= ncfg; i++) {
            if (index(u, CFGN[i]) != 1) continue
            if (substr(u, length(CFGN[i]) + 1, 1) != "_") continue
            if (length(CFGN[i]) > length(best)) best = CFGN[i]
        }
        if (best != "") {
            rest = substr(u, length(best) + 1)
            if (rest ~ /^_[A-Z0-9]+_(SERVER|CLIENT)_/) return EXTM[u] = cfgsub[best]
        }
        return EXTM[u] = v
    }
    function split_csv(line,    n, i, c, inquotes, cur) {
        delete field                     # clear stale cells from a prior (short) row
        n = 0; cur = ""; inquotes = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (inquotes) {
                if (c == "\"") { if (substr(line, i+1, 1) == "\"") { cur = cur "\""; i++ } else inquotes = 0 }
                else cur = cur c
            } else {
                if (c == "\"") inquotes = 1
                else if (c == ",") { n++; field[n] = cur; cur = "" }
                else cur = cur c
            }
        }
        n++; field[n] = cur
        return n
    }
    # split_csv_fast (2026-09-27): the same fields at C speed — split on ","
    # and re-join the pieces of a quoted field an inner comma cut, a regular
    # field (plain without quotes, or quoted with only "" escapes inside)
    # decoded in place; anything irregular (a quote inside a plain field,
    # text after a closing quote, an unterminated quote) goes to split_csv,
    # which stays the single source of semantics. The per-character walk was
    # most of the tokenize (6x on the sample exports; output identical).
    function split_csv_fast(line,   np, i, j, s, L, v, t, q) {
        if ((np = split(line, CSVP, ",")) == 0) { delete field; field[1] = ""; return 1 }
        delete field
        j = 0
        for (i = 1; i <= np; i++) {
            s = CSVP[i]
            if (substr(s, 1, 1) != "\"") {
                if (index(s, "\"") > 0) return split_csv(line)
                field[++j] = s
                continue
            }
            L = length(s)
            if (L >= 2 && substr(s, L, 1) == "\"") {
                v = substr(s, 2, L - 2)
                if (index(v, "\"") == 0) { field[++j] = v; continue }
            }
            t = s; q = gsub(/"/, "", t)
            while (q % 2) {
                if (++i > np) return split_csv(line)
                s = s "," CSVP[i]; t = CSVP[i]; q += gsub(/"/, "", t)
            }
            L = length(s)
            if (substr(s, L, 1) != "\"") return split_csv(line)
            v = substr(s, 2, L - 2); t = v
            gsub(/""/, "", t)
            if (index(t, "\"") > 0) return split_csv(line)
            gsub(/""/, "\"", v)
            field[++j] = v
        }
        return j
    }
    function jdn(y,m,d,   a) { a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function bucket(s) {
        if (s == "" || s == "UNKNOWN")           return "Unknown"
        if (s ~ /Scanning was not performed/)    return "Not performed"
        if (s ~ /Result of Scanning: ALLOW/ || s ~ /^ALLOWED/) return "Allowed"
        if (s ~ /BLOCK/)                          return "Blocked"
        if (s ~ /[Ee][Rr][Rr][Oo][Rr]/)          return "Error"
        return "Other"
    }
    function sv(s) { gsub(/[\t\r\n]/, " ", s); return s }
    # Duration -> milliseconds. Mixed and COMPOUND units: "574 ms", "1.314 s",
    # "1 min 0.550 s", even "19 h 36 min 22.939 s". Sum every h/min/s component
    # (ms is always standalone). Returns -1 when nothing parses.
    function dur_ms(s,   total, val) {
        if (s ~ /ms/) { if (s ~ /^[0-9]+ ms$/) { sub(/ ms$/, "", s); return s + 0 } return -1 }
        total = -1
        if (match(s, /[0-9]+([.][0-9]+)? h/))   { val = substr(s, RSTART, RLENGTH); sub(/ h/, "", val);   total = (total < 0 ? 0 : total) + val * 3600000 }
        if (match(s, /[0-9]+([.][0-9]+)? min/)) { val = substr(s, RSTART, RLENGTH); sub(/ min/, "", val); total = (total < 0 ? 0 : total) + val * 60000 }
        if (match(s, /[0-9]+([.][0-9]+)? s/))   { val = substr(s, RSTART, RLENGTH); sub(/ s/, "", val);   total = (total < 0 ? 0 : total) + val * 1000 }
        return total
    }
    { sub(/\r$/, "") }
    FNR == 1 { next }
    length($0) == 0 { next }
    {
        if (seen[$0]++) { dups++; next } # drop exact-duplicate record line (keep the first)
        n = split_csv_fast($0)
        # a line with NO CoreId is no transfer record — a broken or partial
        # CSV line (an embedded newline, a truncated tail): dropped and counted
        # (2026-09-28 fix: it stayed a leg with garbage values and a fake UCx_
        # site, while the File collapse dropped it — legs and Files disagreed)
        if (field[34] == "" || field[34] ~ /^[ \t]*$/) { nocid++; next }
        # the CoreId NAMES FILES (files/<CoreId>.html, the per-File .rpt
        # descriptors): anything but [A-Za-z0-9._-] after an alphanumeric
        # first character could be a path ("../x") and is refused, counted
        # apart from the missing ones (2026-09-28 audit F02)
        if (field[34] !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) { badcid++; next }

        # Blacklist, applied at the source: platform-internal pseudo-values are
        # BLANKED (the row itself is kept — only the entity attribution goes),
        # so no report or detail page ever counts them. This is the ONLY
        # transfer-side blanking: report.js has no client-side blacklist net
        # and must not gain one (CLAUDE.md) — a config-side leak is filtered
        # in bin/flow-manager.sh instead. The HOST blacklist is applied in the
        # endpoint-mapping pass below.
        account = field[2]; sub(/@.*/, "", account)
        if (bl_blank("account", account)) account = ""
        login = field[3]
        if (bl_blank("login", login)) login = ""
        # login blank after the blacklist but the account carries an @suffix
        # (e.g. "ACME@FE000593") -> use the part after the @ (the FlowManager
        # endpoint) as the login, so the row keeps a login attribution. The
        # blacklist OUTRANKS the fallback: a dropped value is never
        # resurrected from the account suffix (an account named
        # "X@P14303_CFT01" — or the example-env "X@SVC_..." — would
        # otherwise refill the very login the blacklist just blanked).
        if (login == "" && field[2] ~ /@/) {
            login = field[2]; sub(/^[^@]*@/, "", login)
            if (bl_blank("login", login)) login = ""
        }
        site = field[7]
        # Subscriptions are logged as <name>_SCP_<tail> (or _SSCP_ / _CCP_);
        # the tail is truncated to varying lengths across exports, so keep only the
        # stable part BEFORE the _SCP_ / _SSCP_ / _CCP_ marker (the clean configured
        # subscription name — matches the config export). Centralized here so every
        # report, cache and detail page sees the canonical name.
        # RENAMES (2026-08): a log line keeps the name that was current when it
        # was written, so an export that renames a subscription would otherwise
        # split its history in two — the configured half joining nothing and
        # going orange, the logged half arriving as an unknown entity. Fold the
        # logged name to the CURRENT one here, at the same single point the
        # _SCP_ tail is stripped, so every report, cache and detail page sees
        # one name per flow. The map is input/<env>/renames/subscriptions.tsv
        # (bin/renames.sh, machine-maintained by the config step).
        cs = site
        if ((scp = index(cs, "_SSCP_")) > 0 || (scp = index(cs, "_SCP_")) > 0 || (scp = index(cs, "_CCP_")) > 0) cs = substr(cs, 1, scp - 1)
        if (cs != "") cs = rn_canon(cs)
        if (cs != "") cs = site_extfold(cs)   # <subscription>_<PROTO>_SERVER_<partner> -> the subscription
        # an OLD (renamed) name WITH that extension: strip it first, then fold
        # (2026-09-28 fix — rn_canon found nothing for the extended value and
        # site_extfold knows current names only, so the File landed on a
        # phantom name, with no movement, and read Failed)
        if (cs != "" && !(toupper(cs) in cfgsub) && match(cs, /_[A-Za-z0-9]+_(SERVER|CLIENT)_/)) {
            ext9 = rn_canon(substr(cs, 1, RSTART - 1))
            if (toupper(ext9) in cfgsub) cs = cfgsub[toupper(ext9)]
        }
        # THE CONFIGURATION OUTRANKS THE SHAPE TEST (2026-08-31 audit): a clean
        # name that IS a configured subscription is kept whatever it looks
        # like. The blacklist keep rule (^UC — every acceptance flow follows
        # the UCn naming convention) is a SHAPE test for values the config
        # does not know: P14303_CFT01, "none", "Clone - ..." artifacts and
        # profile echoes are blanked (row kept) so they never reach _files.tsv
        # or a report, and the propagation / config fallbacks may then recover
        # the real subscription. Applied to the RAW value BEFORE the config
        # test, it blanked the correctly logged subscription of every
        # production hybrid flow (no UC prefix) on every row — the ground
        # truth thrown away, the flow then INFERRED, and a bad profile fold
        # decided it unopposed.
        if (cs != "" && (toupper(cs) in cfgsub)) site = cs
        else if (bl_blank("site", site)) site = ""
        else site = cs
        size = field[19]; if (size !~ /^[0-9]+$/) size = 0
        dur = dur_ms(field[25]); dur = (dur < 0) ? -1 : int(dur + 0.5)     # ms (integer), -1 if none

        ts = field[23]; split(ts, p, " "); d = p[1]; t = p[2]
        date_iso = ""; sortkey = ""; jd = ""
        if (d ~ /^[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9]$/) {
            split(d, dp, "/")
            date_iso = dp[3] "-" dp[1] "-" dp[2]
            sortkey  = dp[3] dp[1] dp[2] t
            jd       = jdn(dp[3]+0, dp[1]+0, dp[2]+0)
        }

        # The PROFILE is folded through its own rename map for the same reason
        # as the subscription: the 2026-08 export renamed 218 profiles, and the
        # profile is what the REVERSE config fallback attributes a leg by — an
        # unmatched profile cost 7,743 CoreIds their subscription and the
        # no-subscription skip then dropped them.
        prof = field[12]
        if (prof != "" && prof != "UNKNOWN") prof = rnp_canon(prof)
        # col 25 (2026-09-08): the Application field of the export itself (6),
        # RAW — "none" on the empty outbound ssh probes the skip below drops
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            sv(field[34]), sv(field[8]), sv(field[1]), sv(account), sv(login), sv(site), \
            sv(field[9]), sv(field[15]), size, sv(field[20]), date_iso, sv(t), sortkey, jd, \
            dur, sv(field[26]), bucket(field[17]), sv(field[24]), sv(field[38]), sv(field[22]), \
            sv(prof), sv(field[35]), sv(field[29]), sv(field[30]), sv(field[6])
    }
    END {
        if (nocid > 0)
            printf "WARNING: dropped %d record line(s) with no CoreId (a broken or partial CSV line).\n", nocid > "/dev/stderr"
        if (badcid > 0)
            printf "WARNING: dropped %d record line(s) whose CoreId is not a plain identifier (only letters, digits, . _ - are accepted).\n", badcid > "/dev/stderr"
        if (dups > 0)
            printf "NOTE: dropped %d exact-duplicate record line(s) (kept the first occurrence of each).\n", dups > "/dev/stderr"
    }
' "$@"
}
# PARALLEL TOKENIZE (2026-09-27): the file list splits into size-balanced
# groups (the largest file first, each onto the lightest group), one
# tokenizer per group — it ran on ONE core over every export (~90 s on
# production). Half the cores: the server parse runs beside this one. The
# group outputs are concatenated in any order (the sort below orders them);
# a raw line repeated ACROSS groups — the tokenizer drops a repeat only within
# its own group now — leaves two identical tokenized rows, which the sort
# makes adjacent and the pass below drops (TOK_PAR=1): one row per identical
# tokenized row.
TOKJ=$(( $( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 ) / 2 ))
[ "$TOKJ" -ge 1 ] 2>/dev/null || TOKJ=1
[ ${#src_files[@]} -lt "$TOKJ" ] && TOKJ=${#src_files[@]}
TOK_PAR=0
if [ "$TOKJ" -le 1 ]; then
    tok_files "${src_files[@]}" | cat > "$tmp.raw"
else
    TOK_PAR=1
    # LPT: "group<TAB>file" per file, the largest first onto the lightest group
    for f in "${src_files[@]}"; do printf '%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"; done \
      | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr \
      | awk -F'\t' -v J="$TOKJ" '{ g = 1; for (i = 2; i <= J; i++) if (L[i] < L[g]) g = i; L[g] += $1; print g "\t" $2 }' > "$tmp.groups"
    tok_pids=()
    for ((g = 1; g <= TOKJ; g++)); do
        grp=()
        while IFS=$'\t' read -r gi gf; do [ "$gi" = "$g" ] && grp+=("$gf"); done < "$tmp.groups"
        if [ ${#grp[@]} -eq 0 ]; then : > "$tmp.raw.$g"; continue; fi
        tok_files "${grp[@]}" | cat > "$tmp.raw.$g" &
        tok_pids+=("$!")
    done
    tok_rc=0
    for p in "${tok_pids[@]}"; do wait "$p" || tok_rc=$?; done
    if [ "$tok_rc" != 0 ]; then echo "parse.sh: a tokenizer group failed (exit $tok_rc)." >&2; exit "$tok_rc"; fi
    cat "$tmp.raw".[0-9]* > "$tmp.raw"
    rm -f "$tmp.raw".[0-9]* "$tmp.groups"
fi

# ---------------------------------------------------------------------------
# Address -> endpoint map — FULLY AUTOMATIC. Nothing here is hand-written: every
# row is derived, and any value a human puts in is overwritten by the next parse.
#
# THERE IS NO REVERSE DNS (dropped 2026-07). The pipeline used to resolve a PTR
# for every incoming and every whitelisted address; measured before removing it,
# two thirds of those addresses had no PTR at all, and of the names that did come
# back most encoded the address itself (134-146-0-12.shell.com) or named the
# partner's ISP rather than the endpoint. In this cache's own terms: of the 46
# host names in _transfers.tsv col 16, 44 were configured endpoints named by
# FORWARD DNS and only 2 came from a PTR, on 5 rows out of 199,371.
#
# ONE rule remains, keyed on the IPs this tokenize actually produced (column 16
# of $tmp.raw):
#
#   every unique IPv4 on an OUTGOING row — WE dial a configured endpoint, so the
#   configuration already knows the right name:
#     absent from input/<env>/ip/ip-hosts.tsv
#                             -> record it under the host configured for the
#                                account, or, on a row whose account is not known
#                                yet (propagation runs later), for its SUBSCRIPTION
#   This is what makes the map self-healing: when a partner's endpoint answers
#   from a new address (an Azure container instance rotating its public IP, say),
#   the very next parse labels that address with the configured host name instead
#   of stranding the traffic under a bare IP.
#
# An outgoing IP whose accounts do not agree on exactly ONE configured host (an
# account with two endpoints, or two accounts naming different ones) gets no row:
# guessing which of two names belongs to the address would be worse than leaving
# the raw address visible. Nor does an endpoint configured AS a raw IP — mapping
# an address to itself names nothing.
#
# An INCOMING address is deliberately left alone. The partner dials in, so the
# address is theirs; it stays raw in col 16, which is exactly what the whitelist
# allows and what the Incoming-connections tables show.
#
# The map is input/<env>/ip/ip-hosts.tsv — gitignored, but OUTSIDE the
# disposable data/ dir, because a DNS answer cannot be regenerated from anything
# in the repo. See bin/ip.sh.
#
# NOTE: like editing parse.sh, a change here does not by itself invalidate
# _transfers.tsv — the rule runs inside the tokenize, so touch input/*.csv or
# delete the cache to re-apply it to rows already in _transfers0.tsv.
# ---------------------------------------------------------------------------
mkdir -p "$IP_DIR"

# Classify every IPv4 in the tokenized rows by the side its account connects on
# — the SAME test the substitution below uses, so the two can never disagree:
# an account with configured hosts is Out, one known only by its logins is In,
# an unknown account counts as Out. Emits one line per unique IP:
#   IN  <TAB> ip
#   OUT <TAB> ip <TAB> the single configured host, or "" when it is not unique
# An IP on both sides is emitted OUT only — rule (b) owns it.
sides_f="$tmp.sides"
al_f="$CFG_AL"; [ -f "$al_f" ] || al_f=/dev/null
ah_f="$CFG_AH"; [ -f "$ah_f" ] || ah_f=/dev/null
sh_f="$CFG_SH"; [ -f "$sh_f" ] || sh_f=/dev/null
sb_f="$CFG_SUBS"; [ -f "$sb_f" ] || sb_f=/dev/null
awk -F'\t' '
    function vote(ip, h) {                                                 # one endpoint candidate for ip
        if (h == "" ) return
        if (h == "\001") { cand[ip] = "\001"; return }                     # the voter itself is ambiguous
        if (!(ip in cand)) cand[ip] = h
        else if (cand[ip] != h) cand[ip] = "\001"                          # voters disagree
    }
    FILENAME == ARGV[1] { if ($1 != "") al[toupper($1)] = 1; next }        # account -> has logins (In)
    FILENAME == ARGV[2] {                                                  # account -> its configured host(s) (Out)
        if ($1 == "") next
        a = toupper($1); ah[a] = 1
        if (!(a in ahost)) ahost[a] = $2; else if (ahost[a] != $2) ahost[a] = "\001"   # \001 = ambiguous
        next
    }
    FILENAME == ARGV[3] {                                                  # subscription -> its configured host(s)
        if ($1 == "") next
        s = toupper($1)
        if (!(s in shost)) shost[s] = $2; else if (shost[s] != $2) shost[s] = "\001"
        next
    }
    FILENAME == ARGV[4] { if ($1 != "" && ($2 == "in" || $2 == "out")) sside[toupper($1)] = $2; next }   # subscription -> its comm-profile side
    $16 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        ip = $16; a = toupper($4); s = toupper($6)
        # THE SUBSCRIPTION SIDE FIRST (2026-08-31 audit), the account rule only
        # for a row without one (or a both-ways subscription): a hybrid
        # production account carries hosts AND logins, so by the account
        # rule every one of its rows — the partner-delivered ones included —
        # counted as Out, and the partner INCOMING address was recorded under
        # the account configured endpoint in input/<env>/ip/, permanently.
        sd9 = (s != "" && (s in sside)) ? sside[s] : (((a in ah) || !(a in al)) ? "out" : "in")
        if (sd9 == "out") {                                                # OUT: we dial the endpoint
            out[ip] = 1
            # WHO knows the endpoint. The SUBSCRIPTION is asked first
            # (2026-08-31, user question — an account can now carry SEVERAL
            # configured hosts): a flow has ONE endpoint, so its subscription
            # names it precisely, while a multi-host account is \001-ambiguous
            # and, asked first, POISONED the address for every flow of that
            # account — the endpoint was then never recorded in
            # input/<env>/ip/, and the logged raw IP stayed raw in col 15,
            # inventing an address-shaped "host" entity. The account still
            # votes for the rows the propagation has not yet given a site
            # (this pass runs BEFORE it). A row identified by neither casts no
            # vote at all — counting it as "no host" would make every IP look
            # ambiguous.
            if (s != "" && (s in shost))      vote(ip, shost[s])
            else if (a != "" && (a in ahost)) vote(ip, ahost[a])
        } else in_[ip] = 1
    }
    END {
        for (ip in in_) if (!(ip in out)) print "IN\t" ip
        for (ip in out) print "OUT\t" ip "\t" (((ip in cand) && cand[ip] != "\001") ? cand[ip] : "")
    }' "$al_f" "$ah_f" "$sh_f" "$sb_f" "$tmp.raw" | LC_ALL=C sort > "$sides_f"

# ---- OUTGOING: record the configured host for any address not yet mapped ----
# No DNS here: WE dial these endpoints, so the configuration already knows the
# name. Rows are emitted only where the map does not already carry that pair, so
# a settled map (under input/, kept across builds) is not rewritten.
# INCOMING addresses get no row at all — the partner owns them and they stay raw.
ip_in="$IP_HOSTS_FILE"; [ -f "$ip_in" ] || ip_in=/dev/null
b_rows="$tmp.b_rows"
awk -F'\t' -v MAP="$ip_in" '
    FILENAME == MAP && MAP != "/dev/null" { if ($1 != "") have[$1 SUBSEP tolower($2)] = 1; next }
    $1 == "OUT" && $3 != "" && $3 != $2 && !(($2 SUBSEP tolower($3)) in have) { print $2 "\t" $3 }
' "$ip_in" "$sides_f" > "$b_rows"
b_wrote=$(wc -l < "$b_rows" | tr -d ' ')
b_keep=$(awk -F'\t' -v w="$b_wrote" '$1 == "OUT" && $3 != "" && $3 != $2 { n++ } END { print n - w }' "$sides_f")
ip_put < "$b_rows"
rm -f "$b_rows"
echo "Endpoint addresses: $b_wrote new outgoing address(es) recorded from the configured host, $b_keep already mapped." >&2

# Apply the map: one awk pass holds it in memory (map[ip]) while rewriting
# column 16 across all rows — no per-row file reads. The sentinel line keeps the
# map file non-empty (an empty first file would make awk apply the NR==FNR rule
# to the data). An address with several endpoints keeps the FIRST in address
# order, which is deterministic because ip-hosts.tsv is sorted.
hmap="$tmp.hosts"
{
    printf '#\t#\n'
    # THE FLOW'S OWN ENDPOINT WINS. Several configured endpoints can share one
    # address — sftp.deployteq.net, sftp.myclang.com and sftp.nl2.myclang.com all
    # answer on 52.28.68.191 here — and the address alone cannot say which of them
    # a transfer used; only the row's own flow can (its SUBSCRIPTION, else its
    # account — see the sides pass above, which resolved that vote per address).
    # So it is the primary map and ip-hosts.tsv only fills the addresses it left
    # undecided. Picking from ip-hosts.tsv alone attributed 189 files to the
    # wrong partner.
    awk -F'\t' -v MAP="$ip_in" '
        FILENAME == MAP && MAP != "/dev/null" { if ($1 != "" && $2 != "" && !($1 in m)) m[$1] = $2; next }
        $1 == "OUT" && $3 != "" && $3 != $2 { s[$2] = $3 }
        END { for (ip in s) print ip "\t" s[ip]
              for (ip in m) if (!(ip in s)) print ip "\t" m[ip] }
    ' "$ip_in" "$sides_f" | LC_ALL=C sort
} > "$hmap"
rm -f "$sides_f"
# The substitution is SIDE-AWARE: a row whose account is configured INBOUND
# (the partner connects in to us — the account carries comm-profile logins,
# no hosts) keeps the RAW SOURCE IP: naming the partner's egress address
# after a generic PTR record hid the address the whitelist actually allows.
# Only rows whose account connects OUT (we dial a configured endpoint —
# where the seeded name is meaningful), or whose side is unknown, take the
# name. The DNS cache above still fills for EVERY IP (unknown-hosts and the
# PDA both-ways linking read the .txt files regardless).
al_f="$CFG_AL"; [ -f "$al_f" ] || al_f=/dev/null
ah_f="$CFG_AH"; [ -f "$ah_f" ] || ah_f=/dev/null
sb_f="$CFG_SUBS"; [ -f "$sb_f" ] || sb_f=/dev/null
awk -F'\t' -v OFS='\t' -v BLF="$BLACKLIST_FILE" "$BLACKLIST_AWK"'
    BEGIN { bl_load(BLF) }
    FILENAME == ARGV[1] { if ($1 != "") al[toupper($1)] = 1; next }   # account -> has logins (In side)
    FILENAME == ARGV[2] { if ($1 != "") ah[toupper($1)] = 1; next }   # account -> has hosts  (Out side; wins, like the _files join)
    FILENAME == ARGV[3] { map[$1] = $2; next }
    FILENAME == ARGV[4] { if ($1 != "" && ($2 == "in" || $2 == "out")) sside[toupper($1)] = $2; next }   # subscription -> its comm-profile side (base _subscriptions.tsv col 2)
    {
        # ENDPOINTS ARE CANONICALLY LOWERCASE (site-wide rule): the logged
        # value and the substituted endpoint name alike.
        $16 = tolower($16)
        # host blacklist: internal cluster nodes are blanked (row kept). Applied
        # here, AFTER the cache fill, so the blacklisted IPs keep their
        # transfer/hostnames/ entries (unknown-hosts uses them as known transfer IPs).
        # The literal UNKNOWN is the platform placeholder for "no remote host
        # logged" (2026-08-31 audit: it was 35 % of the production Files and
        # had become a discovered, green host ENTITY) — blank, like the
        # UNKNOWN profile.
        if ($16 == "unknown" || bl_blank("host", $16)) $16 = ""
        else if ($16 in map) {
            # the SUBSCRIPTION side first (2026-08-31 audit): a hybrid
            # production account carries hosts AND logins, so the account
            # rule alone called every one of its rows Out and renamed the
            # INCOMING partner address to a configured endpoint
            s = toupper($6); a = toupper($4)
            sd9 = (s != "" && (s in sside)) ? sside[s] : (((a in ah) || !(a in al)) ? "out" : "in")
            if (sd9 == "out") $16 = tolower(map[$16])
        }
        print
    }' "$al_f" "$ah_f" "$hmap" "$sb_f" "$tmp.raw" | cat > "$tmp.mapped"

# Sort AFTER the mapping (the keys — coreid, direction — are untouched by it).
LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 "$tmp.mapped" | cat > "$tmp.sorted"
# a PARALLEL tokenize (TOK_PAR, above) leaves a raw line repeated across
# groups as two identical rows — adjacent after the sort (its last-resort
# key is the whole line); keep the first, like the tokenizer did
if [ "$TOK_PAR" = 1 ]; then
    xdups=$(awk -v out="$tmp.sorted2" 'BEGIN { printf "" > out; close(out); cmd = "cat > \"" out "\"" } NR > 1 && $0 == prev { d++; next } { prev = $0; print | cmd } END { close(cmd); print d + 0 }' "$tmp.sorted")
    [ "$xdups" -gt 0 ] && echo "NOTE: dropped $xdups exact-duplicate record(s) repeated across tokenizer groups (kept the first)." >&2
    mv "$tmp.sorted2" "$tmp.sorted"
fi
mv "$tmp.sorted" "$PARSED0"
rm -f "$tmp.raw" "$tmp.mapped" "$hmap"

fi   # do_tokenize
_plap "tokenize (+ address map)"

# ---------------------------------------------------------------------------
# CoreId-group entity propagation: _transfers0.tsv (the raw, blacklisted cache)
# -> _transfers.tsv (what every report reads). The
# blacklist has already blanked the platform-internal pseudo-values — that
# stays the first action. Then, within each CoreId group (the rows of one
# logical transfer), an entity value present on SOME row fills the rows where
# it is blank: the Inbound leg knows the partner host that the internal
# Outbound leg lost to the blacklist, the Outbound leg carries the Transfer
# Profile the Inbound leg never had, a leg with the real Transfer Site donates
# it to the legs logged without one, and so on for all five entities
# (account, login, site, host, profile — profile's blank value is "UNKNOWN").
# Only blanks are filled; a row that carries its own value keeps it; the donor
# is the group's first non-blank value in cache order (Inbound before
# Outbound). Kept as a derived file: the raw stream stays in _transfers0.tsv,
# the input of the derive-only re-run (AXWAY_DERIVE_ONLY=1).
#
# CONFIG FALLBACK (the data/flow-manager caches of subscriptions.json — see
# bin/flow-manager.sh), applied in BOTH directions. The map file carries one record
# per direction, tagged in column 1:
#
#   S<TAB>subscription<TAB>account<TAB>profile   subscription -> account / profile
#   P<TAB>profile<TAB>subscription<TAB>pesitdir  profile      -> subscription
#
# FORWARD (S): a row that still has no account or profile after the group
# propagation, but DOES have a subscription (site), takes them from the
# subscription's configuration — the account is the non-APPLICATION
# participant's name, the profile the FlowIdentifier custom attribute. Both
# extraction rules are validated against the log ground truth (every known
# (site,account) and (site,profile) pair in the logs matches the config).
#
# REVERSE (P): a CoreId group whose EVERY row lost its site to the blacklist
# (the partner-push-via-internal-CFT flows: the log only ever carries
# P14303_CFT01 or "none" there, never the subscription name) but that DOES
# carry a profile takes its subscription from the config the other way round,
# keyed on the FlowIdentifier. This is a GROUP-level decision, so the whole
# logical transfer lands on one subscription.
#
# The FlowIdentifier is NOT unique — a flow is commonly configured as two
# subscriptions, one per direction (UC2/UC4, UC1/UC3), so 62 identifiers are
# claimed twice. They are told apart by the DIRECTION OF THE PESIT LEG, which
# the pattern name spells out: ..._PESIT_PUSH_ST_... means the app pushes into
# ST (pesit Inbound), ..._ST_CFT_PESIT_PUSH_APP means ST pushes to the app
# (pesit Outbound). So a group with a pesit Inbound leg resolves to the "IN"
# subscription, one with a pesit Outbound leg to the "OUT" one. Validated: on
# the 17,625 CoreIds that DO carry a site the rule reproduces the logged
# subscription's prefix with zero counter-examples, and on the 20,422 resolved
# groups the chosen subscription's configured comProfile login matches the
# login the group actually logged, again with zero counter-examples.
#
# A group is left without a subscription when it has no profile, when the
# profile is absent from the config, or when the tie cannot be broken (no pesit
# leg, both directions present, or no unique direction match) — never guessed.
# Missing config caches just skip the fallback.
#
# The map is assembled from bin/flow-manager.sh's caches: _subscriptions.tsv is the
# base list, _accounts-subscriptions.tsv / _subscriptions-profiles.tsv fill the
# S records, and the P direction derives from _subscriptions-patterns.tsv's raw
# patternName. A two-account subscription (the UC5/UC8 partner-to-partner
# SRC->DEST flows) keeps the sorted-first account — the config is genuinely
# ambiguous there, and those sites never reach the fallback (their rows always
# carry an account).
smap="$tmp.submap"
{
    printf '#\n'   # sentinel: keeps the map file non-empty so awk file routing stays safe
    if [ -f "$CFG_SUBS" ] && [ -f "$CFG_AS" ] && [ -f "$CFG_SP" ] && [ -f "$CFG_PAT" ]; then
        awk -F'\t' '
            # a two-account subscription (the relays) fills NO account: the
            # config is ambiguous there and a silent first-wins pick sent the
            # partner-push-via-CFT groups of one partner to the other
            FILENAME ~ /_accounts-subscriptions\.tsv$/ { if (!($2 in acct)) acct[$2] = $1; else if (acct[$2] != $1) acct[$2] = ""; next }
            FILENAME ~ /_subscriptions-profiles\.tsv$/ { prof[$1] = $2; next }
            FILENAME ~ /_subscriptions-patterns\.tsv$/ { pat[$1] = $2; next }
            {   # _subscriptions.tsv: one configured subscription per line (col 1 = name, col 2 = direction)
                cur = $1; fid = ((cur in prof) ? prof[cur] : "")
                printf "S\t%s\t%s\t%s\n", cur, ((cur in acct) ? acct[cur] : ""), fid
                if (fid != "") {
                    p = ((cur in pat) ? pat[cur] : "")
                    d = (p ~ /PESIT_PUSH_ST/) ? "IN" : ((p ~ /ST_CFT_PESIT_PUSH_APP/) ? "OUT" : "?")
                    printf "P\t%s\t%s\t%s\n", fid, cur, d
                }
            }
        ' "$CFG_AS" "$CFG_SP" "$CFG_PAT" "$CFG_SUBS"
    fi
    # FLOWDIR fallback sources (F records): account, flow direction, subscription
    # — the account's subscriptions bucketed by their configured file-movement
    # side (out|in|relay). Lets a still-siteless group whose LEGS give a
    # unanimous movement side pick the account's single subscription on that
    # side. Validated like the other fallbacks: on the 181,297 attributed
    # groups where the rule can fire, it reproduces the logged subscription
    # with zero counter-examples (2026-08).
    if [ -f "$CFG_AS" ] && [ -f "$CFG_FD" ]; then
        awk -F'\t' -v OFS='\t' '
            NR == FNR { fd[$1] = $2; next }
            $1 != "" && ($2 in fd) { print "F", toupper($1), fd[$2], $2 }
        ' "$CFG_FD" "$CFG_AS"
    fi
    # XREF single-value fallback sources (X records): src-kind, dst-kind,
    # value, target — the pair caches among the five entity items. The
    # fallback FILLS site, account, login and profile; host is never filled
    # (zero recoverable groups, and raw-IP vs configured-DNS spellings make
    # its ground truth ambiguous) but still VOTES as a source, so the four
    # H:* source caches are loaded and the *-hosts target caches are not.
    for _xs in \
        "A:S:_accounts-subscriptions" "L:S:_logins-subscriptions" "H:S:_hosts-subscriptions" "P:S:_profiles-subscriptions" \
        "L:A:_logins-accounts" "S:A:_subscriptions-accounts" "H:A:_hosts-accounts" "P:A:_profiles-accounts" \
        "A:L:_accounts-logins" "S:L:_subscriptions-logins" "H:L:_hosts-logins" "P:L:_profiles-logins" \
        "A:P:_accounts-profiles" "S:P:_subscriptions-profiles" "L:P:_logins-profiles" "H:P:_hosts-profiles"; do
        _sk=${_xs%%:*}; _rest=${_xs#*:}; _dk=${_rest%%:*}; _xf="$CONFIG_XREF/${_rest#*:}.tsv"
        if [ -f "$_xf" ]; then
            awk -F'\t' -v sk="$_sk" -v dk="$_dk" -v OFS='\t' '$1 != "" && $2 != "" { print "X", sk, dk, $1, $2 }' "$_xf"
        fi
    done
    # SESSION JOIN sources (Z records): session/connection id -> the ONE
    # configured subscription the SERVER log names for that session, learned
    # by bin/session-sites.sh (route-init and ARRC/AR route-bracket lines of
    # _parse.tsv, joined on the id _transfers.tsv col 24 carries too). Missing
    # map = the pass never fires.
    if [ -f "$SESSMAP" ]; then
        awk -F'\t' -v OFS='\t' '$1 != "" && $2 != "" { print "Z", $1, $2 }' "$SESSMAP"
    fi
} > "$smap"
# IN PARALLEL (2026-09-28, speed round 16): the pass is a per-CoreId-group
# transform over the CoreId-sorted _transfers0.tsv (the maps load first, one
# group is buffered at a time), so it runs once per key-aligned slice
# (grp_par, bin/ranges.sh) and the slices' outputs concatenate in order; the
# only other state, the fill counters of the NOTE below, is summed after.
export GRP_GAIN="$tmp.gain"
grp_par "$PARSED0" "$tmp.prop" "$_pj" awk -F'\t' -v OFS='\t' '
    # Resolve a profile to its subscription, breaking a multi-claim tie on the
    # direction of the group pesit leg. Returns "" when it cannot be decided.
    function resolve_site(p, in_, out_,   i, want, hits, cand) {
        p = toupper(p)   # the P records are keyed case-folded, like every other map in this program
        if (p == "" || !(p in pn)) return ""
        if (pn[p] == 1) return psub[p, 1]
        want = (in_ && !out_) ? "IN" : ((out_ && !in_) ? "OUT" : "")
        if (want == "") return ""
        hits = 0
        for (i = 1; i <= pn[p]; i++) if (pdir[p, i] == want) { hits++; cand = psub[p, i] }
        return (hits == 1) ? cand : ""
    }
    # xone1(srckind, dstkind, value): the single dst value the src value maps
    # to in its xref cache — "" when the value is blank, unknown, or
    # ambiguous (maps to more than one dst value).
    function xone1(sk, dk, val,   kk) {
        if (val == "" || val == "UNKNOWN") return ""
        kk = sk SUBSEP dk SUBSEP toupper(val)
        return (xn[kk] == 1) ? xone[kk] : ""
    }
    # XREF single-value fallback: fill a group entity still missing after the
    # propagation + config fallbacks through the cross-reference caches. Each
    # populated OTHER field (account, login, site, host, profile) that maps
    # to exactly ONE dst value casts a vote; ambiguous or unknown fields
    # abstain. All voters must agree — a conflict returns "" rather than
    # guessing. Validated against the groups that DO log each field: account
    # 47,111 matches / 0 mismatches, login 22,005 / 0, profile 47,122 / 0,
    # site 44,132 / 0 real ones (8 "Clone - ..." artifacts where the vote
    # names the real subscription behind the clone). Host is NOT a fill
    # target: raw-IP vs configured-DNS spellings gave 2,941 spelling
    # conflicts and zero recoverable groups.
    function xref_fill(dk, a, l, s, h, p,   c, v) {
        c = xone1("A", dk, a)
        v = xone1("L", dk, l); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
        v = xone1("S", dk, s); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
        v = xone1("H", dk, h); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
        v = xone1("P", dk, p); if (v != "") { if (c == "") c = v; else if (toupper(c) != toupper(v)) return "" }
        return c
    }
    function flush(   i) {
        # reverse fallback: no row in the group carried a subscription
        if (gs == "") gs = resolve_site(gp, gpin, gpout)
        # xref single-value fallback: fill every still-missing entity from
        # the cross-reference vote — site first (the hub), then account,
        # login, profile, each vote seeing the values filled so far. The
        # own field never votes for itself (passed as "").
        if (gs == "") { gs = xref_fill("S", ga, gl, "", gh, gp); if (gs != "") xgain["site"]++ }
        if (ga == "") { ga = xref_fill("A", "", gl, gs, gh, gp); if (ga != "") xgain["account"]++ }
        # LOGIN: never for a flow the config gives NO login (2026-08-31 audit).
        # A hybrid production account has one comm-profile login (its one
        # inbound flow) beside several login-less flows; the S voter abstains
        # on those (no S:L row is abstention, not conflict) and the A voter
        # then credited every one of them to a login that never authenticated
        # for them. The subscription being known and login-less is decisive.
        if (gl == "" && !(gs != "" && !(("S" SUBSEP "L" SUBSEP toupper(gs)) in xn))) { gl = xref_fill("L", ga, "", gs, gh, gp); if (gl != "") xgain["login"]++ }
        if (gp == "") { gp = xref_fill("P", ga, gl, gs, gh, ""); if (gp != "") xgain["profile"]++ }
        # FLOWDIR fallback (2026-08): still no subscription, but the group has
        # an account and its legs agree on a movement side — if the account has
        # exactly ONE configured subscription on that side, it is the flow ST
        # itself would have routed by. Zero counter-examples on the 181,297
        # attributed groups (see the F-record builder above).
        if (gs == "" && ga != "" && (gmv == "in" || gmv == "out")) {
            kk = toupper(ga) SUBSEP gmv
            if ((kk in fdn) && fdn[kk] == 1) { gs = fdsub[kk]; xgain["flowdir"]++ }
        }
        # SESSION JOIN (2026-08): still no subscription, but the SERVER log
        # names the flow of the CONNECTION a leg ran over: _transfers.tsv col
        # 24 and _parse.tsv col 6 carry the same session id, and the route
        # lines of that session ("Initializing route: {...}", the ARRC/AR
        # "[account] [route]" brackets) say which subscription ST itself
        # executed — the platform OWN attribution, not a guess. The map
        # (bin/session-sites.sh -> the Z records above) already folds renames
        # and keeps only sessions naming exactly ONE configured subscription;
        # on top of that the mapped sessions of the group must be unanimous
        # (gss; "-" = conflict) and the flow must be one the ACCOUNT of the
        # group is configured for when that account has a configured list at
        # all (the A:S xref rows) — a line a shared session logs about the
        # flow of ANOTHER account must not misattribute.
        if (gs == "" && gss != "" && gss != "-") {
            kk = "A" SUBSEP "S" SUBSEP toupper(ga)
            if (ga == "" || !(kk in xn) || ((kk, toupper(gss)) in xseen)) { gs = gss; xgain["session"]++ }
        }
        # INBOUND-LEG TIE-BREAK (2026-08): the FLOWDIR fallback abstained
        # because the movement vote CONFLICTED — and the conflict is purely
        # partner-protocol legs (no pesit vote: gpin/gpout clear), i.e. the
        # validated echo shape: the partner DELIVERS a file (Inbound ssh) and
        # the same connection carries a response/echo leg back (Outbound ssh).
        # The Inbound leg then outvotes the echo: the file MOVED IN, so the
        # group takes the account single configured movement-in subscription
        # (abstaining when it has two — the rule picks a flow, never a UC).
        # Validated on acceptance: of every group with both an Inbound and an
        # Outbound ssh leg, 39 attributed groups were ALL movement-in (UC4),
        # zero genuinely movement-out — the 3 nominal UC2 ones logged no site
        # at all and resolve EARLIER via the xref single-value fallback (their
        # account has only that one flow), so this pass never sees them. The
        # SESSION JOIN above outranks this: it is the platform naming the
        # flow, this is an inference — on the 7 session-rescued groups the
        # two agree 7-for-7.
        if (gs == "" && ga != "" && gmv == "x" && gppin && !gpin && !gpout) {
            kk = toupper(ga) SUBSEP "in"
            if ((kk in fdn) && fdn[kk] == 1) { gs = fdsub[kk]; xgain["inleg"]++ }
        }
        # FAKE SUBSCRIPTION (2026-08): a group with an account but no
        # subscription ANY pass could find keeps its rows under the synthetic
        # name "UCx_<account>" instead of being dropped by the no-subscription
        # skip — the transfers are real and must count. "UCx" = the UC naming
        # shape with an unknowable UC number (the digit-anchored /^UC[0-9]+/
        # extractors all miss it, so it classifies to no use case). The name is
        # never configured; downstream it behaves like any logged-but-unconfigured
        # subscription (result.sh discover_logged appends it to the base
        # cache, so the Entities/home figures stay consistent) EXCEPT that
        # first-seen.sh excludes it by the UCx_ prefix — nothing was
        # configured, so no first sighting can be dated. It surfaces on
        # not-in-flow-manager and in the per-subscription breakdowns.
        if (gs == "" && ga != "") { gs = "UCx_" ga; xgain["fake"]++ }
        for (i = 1; i <= nb; i++) {
            $0 = buf[i]
            if ($4  == "") $4  = ga
            if ($5  == "") $5  = gl
            if ($6  == "") $6  = gs
            if ($16 == "") $16 = gh
            if (($21 == "" || $21 == "UNKNOWN") && gp != "") $21 = gp
            # forward fallback: subscription -> owning account / flow profile
            if ($6 != "") {
                u6 = toupper($6)
                if ($4 == "" && (u6 in cacct) && cacct[u6] != "") $4 = cacct[u6]
                if (($21 == "" || $21 == "UNKNOWN") && (u6 in cprof) && cprof[u6] != "") $21 = cprof[u6]
            }
            # A lone leg is an incomplete transfer: a CoreId must carry both an
            # Inbound and an Outbound leg, so a group of ONE row never actually
            # delivered — force its status (col 3) to Failed regardless of what
            # the single leg logged. _files.tsv derives its outcome from col 3,
            # so the transfer outcome follows automatically.
            if (nb == 1) $3 = "Failed"
            print
        }
        nb = 0; ga = ""; gl = ""; gs = ""; gh = ""; gp = ""; gpin = 0; gpout = 0; gmv = ""; gss = ""; gppin = 0
    }
    NR == FNR {
        # keyed CASE-FOLDED like the X records and every downstream map
        # (2026-08-31 audit: these two were the only exact-case joins in the
        # chain — an export spelling a name differently from the log missed
        # silently and the group fell through to a weaker fallback)
        if ($1 == "S") { cacct[toupper($2)] = $3; cprof[toupper($2)] = $4 }
        else if ($1 == "P") { pk = toupper($2); i = ++pn[pk]; psub[pk, i] = $3; pdir[pk, i] = $4 }
        else if ($1 == "F") { kk = $2 SUBSEP $3; fdn[kk]++; fdsub[kk] = $4 }
        else if ($1 == "Z") { zsite[$2] = $3 }
        else if ($1 == "X") {
            kk = $2 SUBSEP $3 SUBSEP toupper($4)
            if (!((kk, toupper($5)) in xseen)) { xseen[kk, toupper($5)] = 1; xn[kk]++; xone[kk] = $5 }
        }
        next
    }
    {
        # capture every field BEFORE flush() — it reassigns $0 while emitting the
        # previous group, which clobbers the fields of the record being read
        line = $0; k = $1; a = $4; l = $5; s = $6; h = $16; p = $21; dir = $2; proto = $10; z24 = $24
        # a blank CoreId is not a group key — each such row stands alone, so it
        # never cross-fills entity values between unrelated undated transfers.
        if (k != cur || k == "") { flush(); cur = k }
        buf[++nb] = line
        if (ga == "" && a != "") ga = a
        if (gl == "" && l != "") gl = l
        if (gs == "" && s != "") gs = s
        if (gh == "" && h != "") gh = h
        if (gp == "" && p != "" && p != "UNKNOWN") gp = p
        if (proto == "pesit") { if (dir == "Inbound") gpin = 1; else if (dir == "Outbound") gpout = 1 }
        # the group MOVEMENT vote (the FLOWDIR fallback): each leg names the
        # file-movement side its protocol+direction implies — a partner
        # protocol moves the file the way the connection points (ssh Inbound =
        # a partner delivering IN), the app-side pesit leg the opposite (pesit
        # Inbound = the app handing us a file to move OUT). http/routing legs
        # abstain. "x" = the legs disagree; the fallback then stays out.
        mvv = ""
        if (proto == "ssh" || proto == "sftp" || proto == "ftp" || proto == "ftps") {
            mvv = (dir == "Inbound") ? "in" : ((dir == "Outbound") ? "out" : "")
            if (mvv == "in") gppin = 1   # a partner DELIVERED a file (the INBOUND-LEG TIE-BREAK evidence)
        }
        else if (proto == "pesit")
            mvv = (dir == "Inbound") ? "out" : ((dir == "Outbound") ? "in" : "")
        if (mvv != "") { if (gmv == "") gmv = mvv; else if (gmv != mvv) gmv = "x" }
        # the group SESSION vote (the SESSION JOIN fallback): a leg whose
        # connection (col 24) the server log attributes to exactly ONE flow
        # (the Z records) names it; legs with an unmapped or missing session
        # abstain. "-" = the mapped sessions disagree; the fallback then
        # stays out (no site starts with "-").
        if (z24 != "" && (z24 in zsite)) {
            if (gss == "") gss = zsite[z24]
            else if (gss != zsite[z24]) gss = "-"
        }
    }
    END {
        flush()
        if (ENVIRON["GRP_PART"] != "") {   # a grp_par slice: its counters go to the summing below
            for (g in xgain) printf "%s\t%d\n", g, xgain[g] > (ENVIRON["GRP_GAIN"] "." ENVIRON["GRP_PART"])
            exit
        }
        msg = ""
        if (xgain["site"] > 0)    msg = msg " site=" xgain["site"]
        if (xgain["account"] > 0) msg = msg " account=" xgain["account"]
        if (xgain["login"] > 0)   msg = msg " login=" xgain["login"]
        if (xgain["profile"] > 0) msg = msg " profile=" xgain["profile"]
        if (xgain["flowdir"] > 0) msg = msg " site-by-flowdir=" xgain["flowdir"]
        if (xgain["session"] > 0) msg = msg " site-by-session=" xgain["session"]
        if (xgain["inleg"] > 0)   msg = msg " site-by-inbound-leg=" xgain["inleg"]
        if (xgain["fake"] > 0)    msg = msg " fake-site=" xgain["fake"]
        if (msg != "") print "NOTE: xref single-value fallback filled CoreId-group entities:" msg | "cat 1>&2"
    }
' "$smap" -
{ cat "$tmp.gain".* 2>/dev/null || true; } | awk -F'\t' '{ xgain[$1] += $2 }
    END { msg = ""
        if (xgain["site"] > 0)    msg = msg " site=" xgain["site"]
        if (xgain["account"] > 0) msg = msg " account=" xgain["account"]
        if (xgain["login"] > 0)   msg = msg " login=" xgain["login"]
        if (xgain["profile"] > 0) msg = msg " profile=" xgain["profile"]
        if (xgain["flowdir"] > 0) msg = msg " site-by-flowdir=" xgain["flowdir"]
        if (xgain["session"] > 0) msg = msg " site-by-session=" xgain["session"]
        if (xgain["inleg"] > 0)   msg = msg " site-by-inbound-leg=" xgain["inleg"]
        if (xgain["fake"] > 0)    msg = msg " fake-site=" xgain["fake"]
        if (msg != "") print "NOTE: xref single-value fallback filled CoreId-group entities:" msg }' >&2
rm -f "$tmp.gain".*; unset GRP_GAIN
mv "$tmp.prop" "$PARSED"
rm -f "$smap"
_plap "derive: propagation + fallbacks"

# NO-SUBSCRIPTION / HTTP SKIP (narrowed 2026-08): a CoreId whose EVERY row
# still has no site (col 6) after the propagation + config/xref/flowdir
# fallbacks AND the fake-subscription fill — i.e. one with no account either —
# or with an http leg on ANY row (col 10) — is dropped from _transfers.tsv
# entirely (so _files.tsv never counts it). Its RAW input lines — verbatim, no
# formatting — are set aside in _skipped.csv: the input CSVs are rescanned and
# every data line whose CoreId (CSV field 34) is in the drop set is copied out.
# Recomputed each derive from the whole cache, so a later export adding a leg
# WITH a subscription brings a no-sub CoreId back automatically
# (_transfers0.tsv, the merge base, keeps all rows).
# + THE EMPTY OUTBOUND SSH PROBE (2026-09-08, user request): a CoreId whose
# ONE and only record is Outbound + ssh + size 0 + the export's Application
# field "none" (col 25; an empty field counts the same) is no file at all —
# it must not become a (Failed, one-legged) File. Dropped the same way, its
# raw line set aside with the others (the Skipped report labels the reason);
# a later export adding a second leg brings the CoreId back, like the
# no-sub case.
#
# ONE PASS, key-aligned slices in parallel (grp_par, 2026-09-28): the drop
# decision is per CoreId GROUP (the cache is CoreId-sorted), the SKIP LIST
# below is per ROW and the newest leg start the still-under-way filter needs is
# a MAX over the rows both leave standing — so each slice decides, drops, skips
# and maxes its own groups, and the slices join in order into exactly what the
# three whole-cache passes wrote (the drop list is a set: its consumers look it
# up and count it). A blank CoreId is one group like any other key.
# SKIP LIST: partition _transfers.tsv into kept (rewrite $PARSED) and skipped
# (set aside in $SKIPOUT). A record is skipped when its attributed account
# (col 4) or subscription/site (col 6) name contains a skip token (case-
# insensitive substring). Zero tokens -> nothing skipped, empty sidecar.
# The rules come from input/<env>/skip.txt via bin/skiplist.sh — the ONE reader, so
# the transfer parse, the server parse, flow-manager and the Skipped report all
# agree what a rule means. LOGIN (col 5) is tested alongside account (4) and
# site (6): a field-specific "login" rule can target it, and an "any" rule
# covers all three. A dropped CoreId never reaches the skip rules.
mkdir -p "$(dirname "$SKIPOUT")"
export GRP_SIDE="$tmp.side"
grp_par "$PARSED" "$tmp.kept" "$_pj" awk -F'\t' -v SLF="$SKIPLIST_FILE" "$SKIPLIST_AWK"'
    function hms_ms(t,   a) { if (t == "") return 0; split(t, a, "[:.]"); return ((a[1]*3600) + (a[2]*60) + a[3]) * 1000 + a[4] }
    function flush(   i, m) {
        if (n == 0) return
        if (!has || ht || (n == 1 && psh)) { print cur > NSF; if (n == 1 && psh && has && !ht) np++ }
        else for (i = 1; i <= n; i++) {
            if (hit[i]) { print row[i] > SCF; continue }
            print row[i]
            if (r14[i] != "") { m = r14[i] * 86400000 + hms_ms(r12[i]); if (m > mx) mx = m }
        }
        n = 0; has = 0; ht = 0; psh = 0
    }
    BEGIN { sl_load(SLF); P = ENVIRON["GRP_SIDE"] "." ENVIRON["GRP_PART"]; NSF = P ".nosub"; SCF = P ".skip"
            printf "" > NSF; printf "" > SCF }
    ($1 "") != cur { flush(); cur = $1 }
    { n++; row[n] = $0; r14[n] = $14; r12[n] = $12
      if ($6 != "") has = 1; if ($10 == "http") ht = 1
      app = tolower($25); if ($2 == "Outbound" && $10 == "ssh" && ($9 + 0) == 0 && (app == "none" || app == "")) psh = 1
      hit[n] = (SL_N > 0 && (sl_hit("account", $4) || sl_hit("login", $5) || sl_hit("site", $6))) }
    END { flush(); printf "%d\n", np + 0 > (P ".np"); printf "%.0f\n", mx + 0 > (P ".mx") }
' -
: > "$tmp.nosub"; : > "$tmp.skip"; nprobe=0; newest_ms=0
for ((i = 1; i <= GRP_N; i++)); do
    cat "$GRP_SIDE.$i.nosub" >> "$tmp.nosub"; cat "$GRP_SIDE.$i.skip" >> "$tmp.skip"
    nprobe=$((nprobe + $(cat "$GRP_SIDE.$i.np")))
    _mx=$(cat "$GRP_SIDE.$i.mx"); [ "$_mx" -gt "$newest_ms" ] && newest_ms=$_mx
    rm -f "$GRP_SIDE.$i.nosub" "$GRP_SIDE.$i.skip" "$GRP_SIDE.$i.np" "$GRP_SIDE.$i.mx"
done
unset GRP_SIDE
if [ -s "$tmp.nosub" ]; then
    # PREFILTER before tokenizing. This rescans the whole input — 359 MB today —
    # only to copy out the raw lines of a handful of CoreIds (10 on the current
    # dataset), and running the per-character CSV tokenizer on every line of it
    # cost 22 s of a 73 s parse, 44% of the run, for ten lines of output.
    # A CoreId is a UUID, so one regex alternation rejects virtually every line
    # before the character loop starts; the survivors are still tokenized, so a
    # UUID that happens to appear in some OTHER field is still rejected exactly
    # as before. Measured on the real input, same output: 21.5 s -> 0.37 s.
    # ONE JOB PER INPUT FILE (2026-09-27): each file's matches come out in its
    # own line order and the parts join in file order, so the sidecar is the
    # one the single pass over "${files[@]}" wrote
    nosub_raw() { awk -v listfile="$tmp.nosub" '
        BEGIN { U = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
                uu = 1
                while ((getline l < listfile) > 0) { drop[l] = 1; cidre = cidre (cidre ? "|" : "") l; if (l !~ ("^" U "$")) uu = 0 }
                close(listfile) }
        # THE UUID SCAN (2026-09-27): the alternation above costs one regex
        # branch per listed CoreId at every character of every line (121 ids
        # over the production exports: ~18 s, twice per build). When every
        # listed id is a lowercase UUID, visiting each UUID-shaped substring of
        # the line and looking it up finds exactly the lines the alternation
        # matches (every start position is visited); otherwise the alternation
        uu && cidre != "" { s = $0; hit = 0
            while (match(s, U)) { if (substr(s, RSTART, 36) in drop) { hit = 1; break }; s = substr(s, RSTART + 1) }
            if (!hit) next }
        !uu && (cidre == "" || $0 !~ cidre) { next }
        function csv_field(line, want,    n, i, c, inquotes, cur) {
            n = 0; cur = ""; inquotes = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (inquotes) {
                    if (c == "\"") { if (substr(line, i+1, 1) == "\"") { cur = cur "\""; i++ } else inquotes = 0 }
                    else cur = cur c
                } else {
                    if (c == "\"") inquotes = 1
                    else if (c == ",") { n++; if (n == want) return cur; cur = "" }
                    else cur = cur c
                }
            }
            n++
            return (n == want) ? cur : ""
        }
        { cid = csv_field($0, 34); sub(/\r$/, "", cid)
          if (cid in drop) print }
    ' "$1"; }
    _nrj=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
    case $_nrj in ""|*[!0-9]*) _nrj=2 ;; esac
    _nrp=(); _nri=0
    for f in "${files[@]}"; do
        _nri=$((_nri + 1))
        nosub_raw "$f" > "$tmp.nosubraw.$_nri" &
        _nrp+=("$!")
        if [ "${#_nrp[@]}" -ge "$_nrj" ]; then wait "${_nrp[0]}"; _nrp=("${_nrp[@]:1}"); fi
    done
    for p in ${_nrp[@]+"${_nrp[@]}"}; do wait "$p"; done
    for ((i = 1; i <= _nri; i++)); do cat "$tmp.nosubraw.$i"; done > "$tmp.nosubraw"
    for ((i = 1; i <= _nri; i++)); do rm -f "$tmp.nosubraw.$i"; done
    mv "$tmp.nosubraw" "$SKIPCSV"
else
    : > "$SKIPCSV"
fi
echo "No-subscription/http/probe skip: dropped $(wc -l < "$tmp.nosub" | tr -d ' ') CoreId(s) ($nprobe empty outbound ssh probe(s)); raw line(s) -> $SKIPCSV." >&2
rm -f "$tmp.nosub"
mv "$tmp.kept" "$PARSED"
mv "$tmp.skip" "$SKIPOUT"
echo "Skip list: set aside $(wc -l < "$SKIPOUT" | tr -d ' ') transfer record(s) -> $SKIPOUT." >&2

# Companion legend: the column names of _transfers.tsv (kept in sync with the emit
# order above). Rewritten each build; content only changes if the columns do.
cat > "$LEGEND" <<'LEGEND_EOF'
_transfers.tsv — one row per transfer-log record, TAB-separated, sorted by coreid
then direction (a transfer's Inbound + Outbound rows are adjacent, Inbound first).
The legs of a File that started less than 10 minutes before the newest leg start
are left out (still under way); _transfers0.tsv keeps them for the next parse.

ENTITY PROPAGATION: after the blacklist blanks platform-internal pseudo-values,
a CoreId-group pass fills each still-blank entity value (account, login, site,
remote_host; profile's blank is "UNKNOWN") from the first row in the same
CoreId group that carries one — so a leg logged without the site/profile/host
inherits it from its sibling leg. Then a CONFIG FALLBACK against the
subscription configuration (the data/flow-manager caches of subscriptions.json,
built by bin/flow-manager.sh), both ways round:
  forward  a row with a site but no account/profile takes them from that
           subscription's config (account = the non-APPLICATION participant,
           profile = the FlowIdentifier attribute).
  reverse  a CoreId group whose every row lost its site to the blacklist takes
           its subscription from the config keyed on the profile
           (FlowIdentifier). A FlowIdentifier can name two subscriptions, one
           per direction; they are told apart by the direction of the group's
           pesit leg (Inbound = app pushes into ST, Outbound = ST pushes to the
           app), which the subscription's pattern name spells out. A group with
           no profile, no pesit leg, or no unique match is left without a
           subscription rather than guessed.
  xref     an entity STILL missing after both (site, then account, login and
           profile — host is never filled) takes its value from the
           data/flow-manager/xref cross-reference caches: each populated other
           field that maps to exactly ONE configured value casts a vote, and
           a unanimous vote fills the entity (ambiguous fields abstain; a
           conflict leaves it empty). Votes cascade: a newly filled site
           votes in the account/login/profile decisions.
The raw, unpropagated rows live in _transfers0.tsv (the derive's input; same
columns).

FLOWDIR + SESSION JOIN + FAKE SUBSCRIPTION (2026-08): a group still siteless
after the passes above takes the account's single configured subscription on
the movement side its legs unanimously imply (partner protocols move the file
the way the connection points, pesit the opposite); failing that, the SESSION
JOIN asks the SERVER log which flow the leg's own connection executed
(_transfers.tsv col 24 = _parse.tsv col 6; the route lines name the
subscription — bin/session-sites.sh builds the map, this derive validates it
against the account's configured flows); failing that, the INBOUND-LEG
TIE-BREAK resolves the delivered-file-plus-echo shape (Inbound ssh + Outbound
ssh, a purely partner-protocol movement conflict): the Inbound leg outvotes
the echo and the group takes the account's single configured movement-in
subscription; when even that fails, the group keeps
the SYNTHETIC site "UCx_<account>" — counted like any logged-but-unconfigured
subscription, except that First seen excludes it by the UCx_ prefix.

NO-SUBSCRIPTION / HTTP SKIP: a CoreId with neither site nor account on every
row after all the passes above — or with an http leg on ANY row (col 10)
— is NOT in this cache (nor in _files.tsv): its raw input CSV lines are set
aside verbatim in data/<env>/transfer/_skipped.csv. Recomputed each derive,
so a later export adding a leg with a subscription brings a skipped CoreId
back.

col  name           description
  1  coreid         CoreId — the logical-transfer key (both rows share it)
  2  direction      Direction (Inbound / Outbound)
  3  status         Status, raw (reports fold "Failed Subtransmission" -> "Failed");
                    a lone leg (a CoreId group of one row — no Inbound+Outbound
                    pair) is forced to "Failed": an incomplete transfer never delivered
  4  account        Account, with "@..." stripped; blacklist blanked (SECURETRANSPORT)
  5  login          Login; blacklist blanked (SECURETRANSPORT, P14303_CFT01, *nobody,
                    UNKNOWN); if then blank and Account has an @suffix, the part after
                    @ (the FE endpoint) is used as the login — unless that value is
                    itself blacklisted (the blacklist outranks the fallback)
  6  site           Transfer Site; a LOGGED value must start with "UC" — anything
                    else (P14303_CFT01, none, "Clone - ..." artifacts) is blanked; kept
                    only up to _SCP_ / _SSCP_ / _CCP_ (clean name, truncated tail dropped).
                    "UCx_<account>" = the synthetic no-subscription name (see
                    above; only after even the SESSION JOIN found nothing)
  7  action_by      Action By
  8  file           Local Filename — the real file basename, populated on every row
                    (field 10 "File" holds the account name on outbound rows)
  9  size           Size in bytes (0 if non-numeric)
 10  protocol       Protocol
 11  date_iso       Start Time date as ccyy-mm-dd ("" if not MM/DD/YYYY)
 12  time           Start Time time as HH:MM:SS.mmm
 13  sortkey        YYYYMMDD + time (chronological sort key)
 14  jdn            Julian day number of the start date
 15  duration       Duration in milliseconds (integer; -1 if none)
 16  remote_host    Remote Host; an IPv4 is replaced by its name in
                    input/<env>/ip/ip-hosts.tsv, filled automatically from the
                    account's configured host for an outgoing address; an
                    incoming address is left raw (it is the partner's)
 17  av_bucket      ICAP scan outcome: Allowed / Blocked / Not performed / Error / Unknown / Other
 18  end_time       End Time, raw
 19  secparams      SecurityParameters, raw
 20  mode           Mode (BINARY / ASCII / unknown)
 21  profile        Transfer Profile — the configured flow name ("UNKNOWN" if none)
 22  resubmitted    Resubmitted flag (true / false)
 23  transfer_id    Transfer ID — a per-row identifier (~unique per row; a CoreId
                    spans many); the row id of the click-to-expand drills.
 24  session_id     Session ID, raw — the TECHNICAL connection the leg travelled
                    in (one SSH/PESIT connection = one id; an SFTP client
                    commonly opens a fresh connection per operation). Two legs
                    sharing this id provably used one and the same connection —
                    the same-connection proof behind the UC2/UC4 shared-drop
                    signal.
 25  application    The export's own Application field (CSV field 6), raw —
                    "none" on the empty outbound ssh probes the parse-time
                    skip drops (2026-09-08). NOT the derived application
                    entity (_files.tsv col 18 comes from the configuration).

This cache never contains fabricated rows: bin/build/result.sh (the build step
after both parses) fills the base result column (data/flow-manager/base/*.tsv)
and injects nothing here.
LEGEND_EOF

_plap "derive: no-subscription / http / probe skip + skip list"
# ---------------------------------------------------------------------------
# Logical-transfer cache: one row per CoreId. A logical transfer is several
# records (Inbound row, Outbound row, retries); collapse each CoreId group to a
# single transfer so reports can count transfers, not physical rows. Read the
# per-record cache re-sorted by CoreId then Start Time so the first row of a
# group is the earliest (Inbound) row and the last is the final row.
FILES="$CACHE_DIR/_files.tsv"
TLEGEND="$CACHE_DIR/_files.txt"
ttmp="$FILES.tmp.$$"
# The outcome rules need the file MOVEMENT direction (which way the file
# travels — the subscription's flowdir), so the collapse preloads the
# _subscriptions-flowdir.tsv xref cache (the same map the config-column join
# below uses for col 17). Missing cache -> empty map -> movement unknown.
flowmap="$CFG_FLOW"; [ -f "$flowmap" ] || flowmap=/dev/null
# (the program is RUN further down, in one pipeline with the config join and
# the still-under-way filter — see "ONE PIPELINE PER SLICE" there)
COLLAPSE_AWK='
    function hms_ms(t,   a) { if (t == "") return 0; split(t, a, "[:.]"); return ((a[1]*3600) + (a[2]*60) + a[3]) * 1000 + a[4] }
    function fromjdn(j,   a,b,c,dd,e2,mm,day2,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e2=c-int(1461*dd/4); mm=int((5*e2+2)/153); day2=e2-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day2) }
    # an epoch-ms value (jdn * 86400000 + ms of day) -> "ccyy-mm-dd hh:mm:ss.mmm", the col 4/5 format
    function stamp_ms(ms,   j, r, h, m, s) { j = int(ms / 86400000); r = ms - j * 86400000; h = int(r / 3600000); r -= h * 3600000; m = int(r / 60000); r -= m * 60000; s = int(r / 1000); return fromjdn(j) " " sprintf("%02d:%02d:%02d.%03d", h, m, s, r - s * 1000) }
    function flush(   t1, t2, arr_end, pick_start, oc, wait, mv, endst) {
        if (prev == "")  return
        # Duration = the WALL-CLOCK SPAN of the logical transfer: from the first
        # (earliest) row start to the last (latest) row END (its own start + its
        # own duration) - NOT the sum of the rows durations. So it includes the
        # gap ST leaves between the inbound leg finishing and the outbound leg
        # starting (store-and-forward routing), and the idle time between retries.
        # Rows are start-time sorted, so f_* is the first dated row and l_* the
        # last; a single-row group yields exactly that row own duration. jdn folds
        # the day in, so a transfer crossing midnight still spans correctly.
        durtot = 0; wait = ""
        if (f_jdn != "" && l_jdn != "") {
            t1 = f_jdn * 86400000 + hms_ms(f_time)
            t2 = l_jdn * 86400000 + hms_ms(l_time) + l_dur
            durtot = (t2 > t1) ? t2 - t1 : 0
        }
        # UC2 pickup split: a UC2 file arrives in 3 legs (pesit in, routing out,
        # routing in) and sits STAGED until the partner dials in and collects it
        # (ssh out — possibly repeatedly). The time the file waits for the
        # partner is not transfer work, so when a staging (Inbound routing) leg
        # is followed by collect leg(s): Duration = the arrival span (first row
        # start -> staging leg end) + the SUM of the collect leg durations
        # (idle BETWEEN repeat collects is pickup wait too). The excluded
        # initial wait (staging end -> first collect start) is emitted as its
        # own field (the config join below lands it in col 21).
        if (arr_jdn != "" && pick_jdn != "" && f_jdn != "") {
            arr_end = arr_jdn * 86400000 + hms_ms(arr_time) + arr_dur
            pick_start = pick_jdn * 86400000 + hms_ms(pick_time)
            durtot = ((arr_end > t1) ? arr_end - t1 : 0) + pick_sum
            wait = sprintf("%d", (pick_start > arr_end) ? pick_start - arr_end : 0)
        }
        # Outcome — the LAST-LEG RULES (2026-07, replacing the plain delivered
        # rule): the last chronological leg must be the REAL delivery.
        #   Waiting   >= 3 legs, ending on the staging leg (Inbound routing)
        #             that SUCCEEDED: a UC2 file staged for pickup, not
        #             collected yet (a later export with the collect leg
        #             re-flips it). A FAILED staging leg staged nothing — Failed
        #             (2026-09-28 fix: it read Waiting, i.e. OK, and could never
        #             turn Expired either).
        #   Processed >= 2 legs, last leg Outbound + status Processed, AND that
        #             leg is the delivery the file movement calls for:
        #             movement out -> ssh/ftp/ftps (handed to the partner;
        #             ftps is the ftp family — no ftps in acceptance today),
        #             movement in  -> pesit   (handed to CFT).
        #             A file with no movement direction (no/unmapped
        #             subscription) can never pass.
        #   Failed    everything else (incl. a lone leg).
        # Deliberately NO bytes condition: a 0-byte file delivered end-to-end
        # stays Processed (empty at origin — the size-dist zero-byte table
        # keeps it visible), and a trailing 0-byte re-collect half a second
        # after a full-content collect must not fail a delivered file.
        oc = "Failed"
        mv = (last_site != "" && (toupper(last_site) in fd)) ? fd[toupper(last_site)] : ""
        if (rows >= 3 && last_dir == "Inbound" && last_proto == "routing" && last_st == "Processed") oc = "Waiting"
        else if (rows >= 2 && last_dir == "Outbound" && last_st == "Processed") {
            if (mv == "out" && (last_proto == "ssh" || last_proto == "ftp" || last_proto == "ftps")) oc = "Processed"
            else if (mv == "in" && last_proto == "pesit") oc = "Processed"
            # a RELAY (partner -> ST -> partner, no folder or hybrid side)
            # delivers on whichever protocol the last leg used — it has no
            # movement side to match (2026-08-31 audit: it could never be
            # Processed, so the first relay to carry traffic would have read
            # 100 % Error)
            else if (mv == "relay" && (last_proto == "ssh" || last_proto == "ftp" || last_proto == "ftps" || last_proto == "pesit")) oc = "Processed"
        }
        # the profile of the row that DONATED the subscription (col 13 from
        # the same leg as col 12), the group first profile only when that row
        # carries none: a relay CoreId legitimately has legs on two flows, and
        # last-row site beside first-row profile named two flows on one row
        pf9 = (sprof != "") ? sprof : gprof
        # the transfer END (2026-09-12, user rule): the LATEST leg end over the
        # dated rows — each row start + its own duration, so a long retry burst
        # whose late leg delivers ends the File when THAT leg ends. The config
        # join lands it in col 24; "" when no row is dated. The after-last-
        # transfer rule (result.sh, went-kaput, the detail banner) compares a
        # server Error against this, not the start: a File that FINISHED OK
        # after the error is a transfer that ended OK after it.
        endst = (maxend > 0) ? stamp_ms(maxend) : ""
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            prev, oc, f_acct, f_date, f_time, \
            f_sortkey, f_jdn, maxsize, durtot, rows, f_file, last_site, pf9, f_login, f_host, wait, endst
    }
    FILENAME ~ /_subscriptions-flowdir\.tsv$/ { if ($2 == "in" || $2 == "out" || $2 == "relay") fd[toupper($1)] = $2; next }
    {
        if ($1 != prev) {
            flush()
            prev=$1; f_acct=""; f_date=""; f_time=""; f_sortkey=""; f_jdn=""; f_file=$8
            maxsize=0; durtot=0; rows=0; gprof=""; sprof=""; last_site=""; f_login=""; f_host=""
            l_jdn=""; l_time=""; l_dur=0; maxend=0
            arr_jdn=""; arr_time=""; arr_dur=0; pick_jdn=""; pick_time=""; pick_sum=0
        }
        rows++
        # the latest leg END over the dated rows (col 24, see flush)
        if ($14 != "") { e9 = $14 * 86400000 + hms_ms($12) + ($15 + 0 > 0 ? $15 + 0 : 0); if (e9 > maxend) maxend = e9 }
        # Date/time from the first row that HAS a valid date. Rows are sorted by
        # sortkey (col 13), and an undated row has an empty sortkey that sorts
        # FIRST under LC_ALL=C — so taking the first row blindly would blank the
        # transfer date whenever any of its rows is undated.
        if (f_date == "" && $11 != "") { f_date=$11; f_time=$12; f_sortkey=$13; f_jdn=$14 }
        if ($9 + 0 > maxsize) maxsize = $9 + 0        # file size, counted once (max row)
        # last dated row (rows are start-time sorted): its start + own duration
        # ends the wall-clock span computed in flush(). -1 (no duration) -> 0.
        if ($14 != "") { l_jdn=$14; l_time=$12; l_dur=($15 + 0 > 0 ? $15 + 0 : 0) }
        last_st=$3; last_dir=$2; last_proto=$10       # final row -> outcome (incl. the Waiting rule)
        # UC2 staging leg (Inbound routing, dated): anchor the arrival-phase
        # end; every LATER dated leg is a collect leg (the first one starts the
        # pickup, all their own durations sum). A later staging leg re-anchors.
        if ($2 == "Inbound" && $10 == "routing" && $14 != "") {
            arr_jdn=$14; arr_time=$12; arr_dur=($15 + 0 > 0 ? $15 + 0 : 0)
            pick_jdn=""; pick_time=""; pick_sum=0
        } else if (arr_jdn != "" && $14 != "") {
            if (pick_jdn == "") { pick_jdn=$14; pick_time=$12 }
            pick_sum += ($15 + 0 > 0 ? $15 + 0 : 0)
        }
        # blacklisted values arrive blanked, so take the FIRST row that still
        # has an account (recovers the real account when the first row ran as
        # the blanked service account) and the LAST row with a real site.
        if (f_acct == "" && $4 != "") f_acct = $4
        if ($6 != "") { last_site = $6; sprof = ($21 != "" && $21 != "UNKNOWN") ? $21 : "" }   # destination = last non-blank site, and ITS profile
        if (gprof == "" && $21 != "" && $21 != "UNKNOWN") gprof = $21   # the first naming row, the fallback
        if (f_login == "" && $5  != "") f_login = $5
        if (f_host  == "" && $16 != "") f_host  = $16
    }
    END { flush() }
'

# Config columns 16-20 (connection / movement / app / domain / partner),
# joined from the bin/flow-manager.sh caches (case-insensitively like
# showseen): connection = the CONNECTION side vs the partner — the file's
# SUBSCRIPTION comm-profile side (base _subscriptions.tsv col 2) when known,
# else the account's side (hosts -> out, else login -> in; an account
# configured BOTH ways needs the per-subscription rule to split its flows;
# blank when nothing is configured); movement = the FILE-MOVEMENT
# direction of the file's subscription (col 12) from _subscriptions-flowdir
# ("out" = the file leaves us, "in" = it enters us; a relay or unmapped
# subscription stays blank) — the two diverge on pull flows (UC2: connection
# in, movement out; UC3: connection out, movement in); app/domain = parts
# 2/1 of the logical flow name (the xref caches, joined via the FlowID),
# partner = the file's SUBSCRIPTION resolved through _subscriptions-partners.tsv
# (the precise key — a both-partner subscription is ambiguous and abstains;
# 2026-08-31 audit), else its remote host
# (col 15) resolved through _hosts-partners.tsv to its partner ORGANISATION —
# an In file's host is the partner's connecting address, never a configured
# endpoint — else the account's partner org (kept only when
# unambiguous: an account spanning several endpoint orgs stays blank when
# the host decides nothing). Missing caches leave their column(s) empty, so
# the cache always carries 22 columns. The collapse above emits the UC2
# pickup wait as its 16th field; both branches here move it BEHIND the five
# config columns so it lands as col 21 and cols 16-20 keep their positions.
# Col 22 ("expired") is emitted EMPTY here — bin/expire-files.sh (the build
# step after both parses) flips never-collected Waiting files whose staged
# copy the server-log File Maintenance sweep deleted to outcome Expired and
# fills col 22 with the deletion timestamp.
pda_caches=()
for cf in "$CFG_AL" "$CFG_AH" "$CFG_AAPP" "$CFG_ADOM" "$CFG_SAPP" "$CFG_SDOM" "$CFG_SPTN" "$CFG_APTN" "$CFG_HPTN" "$CFG_FLOW" "$CFG_SUBS"; do
    [ -f "$cf" ] && pda_caches+=("$cf")
done
ttmp="$FILES.tmp.$$"
# (a FILTER — stdin to stdout, one stage of the per-slice pipeline below)
cfg_join() {
if [ ${#pda_caches[@]} -eq 0 ]; then
    awk -F'\t' 'BEGIN{OFS="\t"} { w=$16; e=$17; NF=15; print $0, "", "", "", "", "", w, "", "", e }'   # cols 22/23 empty (expire-files / bookend-ok), 24 = the end stamp
else
    awk -F'\t' 'BEGIN{OFS="\t"; AMB=sprintf("%c",1)}
        FILENAME ~ /_accounts-logins\.tsv$/        { al[toupper($1)]=1; next }
        FILENAME ~ /_accounts-hosts\.tsv$/         { ah[toupper($1)]=1; next }
        # the ACCOUNT app/domain maps are a FALLBACK only (2026-08-31): a hybrid
        # production account serves MANY flows, so the account application
        # is ambiguous there — AMB, no fill — and the SUBSCRIPTION maps below
        # (subscription -> FlowID -> Logical -> app/domain, 1:1) come first
        FILENAME ~ /_accounts-apps\.tsv$/          { k=toupper($1); if(!(k in aa)) aa[k]=$2; else if(aa[k]!=$2) aa[k]=AMB; next }
        FILENAME ~ /_accounts-domains\.tsv$/       { k=toupper($1); if(!(k in ad)) ad[k]=$2; else if(ad[k]!=$2) ad[k]=AMB; next }
        # the SUBSCRIPTION app/domain maps (2026-08-29 audit fix): a one-part
        # account derives no app/domain, but its subscription name can (the
        # flow-manager fallback) — cols 18/19 join these when the account map
        # has nothing, so coverage and the detail pages agree on those files.
        # A subscription naming two apps/domains is ambiguous -> no fill.
        FILENAME ~ /_subscriptions-apps\.tsv$/     { k=toupper($1); if(!(k in sa)) sa[k]=$2; else if(sa[k]!=$2) sa[k]=AMB; next }
        FILENAME ~ /_subscriptions-domains\.tsv$/  { k=toupper($1); if(!(k in sdo)) sdo[k]=$2; else if(sdo[k]!=$2) sdo[k]=AMB; next }
        # partner: the SUBSCRIPTION first (2026-08-31 audit — the precise key,
        # like cols 18/19; a both-partner subscription is AMB and abstains),
        # then the host, then the account; every map AMB-guarded — hp was the
        # one bare last-row-wins map in this program
        FILENAME ~ /_subscriptions-partners\.tsv$/ { k=toupper($1); if(!(k in sp)) sp[k]=$2; else if(sp[k]!=$2) sp[k]=AMB; next }
        FILENAME ~ /_accounts-partners\.tsv$/      { k=toupper($1); if(!(k in ap)) ap[k]=$2; else if(ap[k]!=$2) ap[k]=AMB; next }
        FILENAME ~ /_hosts-partners\.tsv$/         { k=tolower($1); if(!(k in hp)) hp[k]=$2; else if(hp[k]!=$2) hp[k]=AMB; next }
        # RELAY is carried too (col 17 = in|out|relay|""): the Latest-100
        # Direction column on the detail pages renders it as "Relay", and it
        # used to get that by re-deriving this same xref cache itself. An empty
        # col 17 now means only "no or unmapped subscription".
        # (No apostrophes in here — the program rides in a single-quoted shell
        # string, so one would end it.)
        FILENAME ~ /_subscriptions-flowdir\.tsv$/  { if($2=="in"||$2=="out"||$2=="relay") fd[toupper($1)]=$2; next }
        FILENAME ~ /_subscriptions\.tsv$/          { if($2=="in"||$2=="out") sd[toupper($1)]=$2; next }
        {
            a=toupper($3); h=tolower($15); s=toupper($12)
            # connection: the file SUBSCRIPTION comm-profile side decides when
            # known (an account configured BOTH ways carries in- and out-subs;
            # the per-account rule below cannot split those) — else the
            # account rule: configured hosts -> out, else login -> in
            d=(s!="" && (s in sd))?sd[s]:((a in ah)?"out":((a in al)?"in":""))
            m=(s!="" && (s in fd))?fd[s]:""
            p=""
            if(s!="" && (s in sp) && sp[s]!=AMB) p=sp[s]
            else if(h!="" && (h in hp) && hp[h]!=AMB) p=hp[h]
            else if((a in ap) && ap[a]!=AMB) p=ap[a]
            w=$16; e=$17; NF=15
            a18=""; if(s!="" && (s in sa) && sa[s]!=AMB) a18=sa[s]; if(a18=="" && (a in aa) && aa[a]!=AMB) a18=aa[a]
            d19=""; if(s!="" && (s in sdo) && sdo[s]!=AMB) d19=sdo[s]; if(d19=="" && (a in ad) && ad[a]!=AMB) d19=ad[a]
            print $0, d, m, a18, d19, p, w, "", "", e   # cols 22/23 empty (expire-files / bookend-ok), 24 = the end stamp
        }
    ' "${pda_caches[@]}" -
fi
}
# STILL UNDER WAY (2026-09-15, user rule): a File that STARTED less than
# INPROG_MS before the newest leg start in _transfers.tsv may not have logged
# all its legs yet — a lone first leg would read Failed, a retry burst would
# be cut short. Such Files are removed from _files.tsv AFTER the collapse, and
# their legs from _transfers.tsv with them. _transfers0.tsv (the merge base)
# keeps every row, so the next parse re-derives them against a newer newest
# start and they come back complete. An undated File stays.
# (newest_ms — the newest leg start over the rows the skip pass kept — comes
# from that pass; nothing rewrites $PARSED in between)
INPROG_MS=600000
inprog_filter() { awk -F'\t' -v NEWEST="$newest_ms" -v WIN="$INPROG_MS" '
    function hms_ms(t,   a) { if (t == "") return 0; split(t, a, "[:.]"); return ((a[1]*3600) + (a[2]*60) + a[3]) * 1000 + a[4] }
    BEGIN { DROP = ENVIRON["GRP_SIDE"] "." ENVIRON["GRP_PART"] ".inprog"; printf "" > DROP }
    $7 != "" && NEWEST + 0 > 0 && $7 * 86400000 + hms_ms($5) >= NEWEST - WIN { print $1 > DROP; next }
    { print }'; }
# ONE PIPELINE PER SLICE (2026-09-28): $PARSED is CoreId-sorted, so each
# key-aligned slice (grp_par) re-sorts its own groups by start — every key of
# a slice sorts before the next slice's, so the per-slice sorts concatenate
# into the one global sort — collapses them (COLLAPSE_AWK), joins the config
# columns (cfg_join) and applies the still-under-way filter (inprog_filter).
# _files.tsv is therefore written ONCE, joined and filtered: the 17-column
# intermediate never lands as the cache any more.
collapse_slice() { LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k13,13 | awk -F'\t' "$COLLAPSE_AWK" "$flowmap" - | cfg_join | inprog_filter; }
export GRP_SIDE="$tmp.side"
grp_par "$PARSED" "$ttmp" "$_pj" collapse_slice
: > "$tmp.inprog"
for ((i = 1; i <= GRP_N; i++)); do cat "$GRP_SIDE.$i.inprog" >> "$tmp.inprog"; rm -f "$GRP_SIDE.$i.inprog"; done
unset GRP_SIDE
mv "$ttmp" "$FILES"
_plap "collapse to Files + config join"
if [ -s "$tmp.inprog" ]; then
    grp_par "$PARSED" "$tmp.inprogkept" "$_pj" awk -F'\t' 'NR == FNR { d[$1] = 1; next } !($1 in d)' "$tmp.inprog" -
    mv "$tmp.inprogkept" "$PARSED"
fi
echo "Still under way: removed $(wc -l < "$tmp.inprog" | tr -d ' ') File(s) started within $((INPROG_MS / 60000)) minutes of the newest transfer, and their legs." >&2
rm -f "$tmp.inprog"

cat > "$TLEGEND" <<'TLEGEND_EOF'
_files.tsv — one row per LOGICAL TRANSFER (CoreId), collapsed from _transfers.tsv
(the PROPAGATED cache: blanks already filled from sibling rows where possible).
A transfer is the Inbound row + Outbound row + any retries sharing one CoreId.
A File that started less than 10 minutes before the newest leg start is still
under way and left out (with its _transfers.tsv legs) until a later parse.

col  name       rule
  1  coreid     the logical-transfer key
  2  outcome    the LAST-LEG RULES (2026-07): the last chronological leg must
                be the file's REAL delivery.
                Waiting   = >= 3 legs ending on the staging leg (Inbound
                            "routing") with status Processed: a UC2 file
                            staged for pickup, not collected yet (a later
                            export with the collect leg re-flips it on the
                            next re-collapse). A failed staging leg is Failed.
                Processed = >= 2 legs, last leg Outbound with status
                            Processed, AND that leg matches the file MOVEMENT
                            (col 17): out -> protocol ssh/ftp/ftps (handed to
                            the partner), in -> pesit (handed to CFT). A file
                            without a movement direction never passes.
                Failed    = everything else (incl. a lone one-row CoreId).
                There is deliberately NO bytes condition: a 0-byte file
                delivered end-to-end stays Processed (empty at ORIGIN — see
                size-dist's zero-byte table), and a trailing 0-byte
                re-collect does not fail an already-delivered file.
                PLUS: Expired (set by bin/expire-files.sh, the build step
                after both parses — never by this parser) when a Waiting
                file's staged copy was deleted by the server-log File
                Maintenance retention sweep (~11 days) before any pickup —
                the deletion timestamp is col 22. A parse rebuild resets
                those rows to Waiting; the next expire step re-marks them
  3  account    the first row that carries an account (blacklisted values are blank)
  4  date_iso   first row's date (ccyy-mm-dd)
  5  time       first row's time
  6  sortkey    first row's YYYYMMDD+time
  7  jdn        first row's Julian day number
  8  size       the file size, counted once (max row size, ignoring 0-byte failed rows)
  9  dur_ms     WALL-CLOCK span of the transfer, in ms: (last row's start + its own
                duration) - first row's start (NOT the sum of the row durations) — so
                it includes the store-and-forward gap between the inbound leg ending
                and the outbound leg starting, and the idle time between retries.
                UC2 EXCEPTION: when a staging (Inbound routing) leg is followed
                by collect leg(s), the partner-wait is excluded: dur = (staging
                leg end - first row start) + the SUM of the collect legs' own
                durations (idle between repeat collects is pickup wait too).
                The excluded initial wait is col 21. A Waiting file (no collect
                leg yet) spans first row start -> staging leg end as usual
 10  rows       number of technical rows in the transfer
 11  file       first row's file name (col 8 = Local Filename, the real basename)
 12  dest_site  the last row that carries a Transfer Site (blacklisted values are blank)
 13  profile    the Transfer Profile named on one of the rows ("" if none)
 14  login      the first row that carries a Login (blacklisted values are blank)
 15  host       the first row that carries a Remote Host (blacklisted values are blank)
 16  connection the CONNECTION side — the account's configured flow side vs the
                partner: "in" (the partner connects in to us; the account
                carries a comm-profile login), "out" (we connect out to the
                partner; the account carries hosts), or "" (account unknown/
                unclassified). From the data/flow-manager caches.
 17  movement   the FILE-MOVEMENT direction — which way the FILE travels, from
                the file's subscription (col 12) via _subscriptions-flowdir
                (config source_folder_monitoring_scan_dir -> "out": the file
                leaves us; target_working_dir -> "in": it enters us): "in",
                "out", or "" (relay subscription, or no/unmapped subscription).
                Diverges from connection on pull flows (UC2 in/out, UC3 out/in).
 18  app        the file's APPLICATION — part 2 of its logical flow name
                (domain_application_partner), joined via the account's
                FlowIDs; when the account map yields none, the SUBSCRIPTION
                map can (unambiguous only); "" when neither does
 19  domain     the DOMAIN — part 1 of the logical flow name, with the same
                subscription fallback; "" when neither map has one
 20  partner    the partner ORGANISATION (part 3 of the logical flow name,
                merged — as named in data/flow-manager/base/_partners.tsv):
                the file's subscription when it names ONE partner, else the
                file's host resolved via the configured endpoints, else
                the account's unambiguous partner org; "" else
 21  wait_ms    UC2 pickup wait, in ms: the gap between the staging leg ending
                (the last Inbound routing row's start + duration) and the FIRST
                collect leg starting — the time the file sat staged waiting for
                the partner, EXCLUDED from col 9. "" when the group has no
                staging->collect split (non-UC2 files, and Waiting files that
                have no collect leg yet)
 22  expired    "ccyy-mm-dd hh:mm:ss.mmm" — when the File Maintenance retention
                sweep deleted this never-collected staged file (outcome col 2 =
                Expired; from the server log, joined by bin/expire-files.sh on
                account + file basename, earliest deletion at/after staging).
                "" everywhere else — this parser always writes it empty
 23  settled    "ccyy-mm-dd hh:mm:ss.mmm" — the server log's own ok "Transfer
                end logged." bookend that settled a Failed File as Processed
                (bin/bookend-ok.sh, 2026-09-09: no classifying error line about
                the transfer, the platform ended it ok on the client's fresh
                connection). "" everywhere else — written by that step only
 24  end        "ccyy-mm-dd hh:mm:ss.mmm" — when the transfer ENDED: the latest
                leg end over its dated rows (each row's start + its own
                duration), so a retry burst whose late leg delivers ends when
                that leg ends (2026-09-12, user rule). "" when no row is dated.
                The after-last-transfer rule (result.sh, went-kaput, the detail
                page banner) compares a server Error against the newest OK
                File's END — a File that finished OK after the error is a
                transfer that ended OK after it, so the error is not "after
                the last transfer". Cols 4/5 stay the START.

This cache never contains fabricated rows: nothing downstream appends to it.
TLEGEND_EOF

# (the session cache _sessions.tsv was REMOVED 2026-07 — no consumers remain)

_plap "still-under-way filter"
echo "Wrote $PARSED ($(wc -l < "$PARSED" | tr -d ' ') record(s)), $FILES ($(wc -l < "$FILES" | tr -d ' ') transfer(s)), $LEGEND, $TLEGEND." >&2
