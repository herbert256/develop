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
# raw cache data/_transfers0.tsv (what the incremental merge maintains); a final
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
#
# Values are emitted unescaped except that TAB/CR/LF are scrubbed to a space so
# they can never break the TAB line protocol (none occur in the current data).
#
# INCREMENTAL: a manifest (data/_transfers.files: basename + byte size per input
# already in the cache) lets a run tokenize only NEW input files and merge them
# into the sorted cache, instead of re-tokenizing everything. A changed/removed
# manifested file (or `touch input/*.csv`) forces a full reparse; the merge is
# order-safe, so an incremental result is byte-identical to a full one.
#
# Usage:
#   ./parse.sh            # build/extend data/_transfers.tsv (+ _transfers.txt) from input/*.csv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"   # INPUT_DIR, CACHE_DIR, IP_DIR, CONFIG_DIR, PARSED (= $CACHE_DIR/_transfers.tsv), FILES
source "$ROOT/bin/blacklist.sh"   # BLACKLIST_FILE + BLACKLIST_AWK (bl_load/bl_blank) — input/blacklist.txt
source "$ROOT/bin/renames.sh"    # RENAMES_FILE + RENAMES_AWK (rn_load/rn_canon) — input/<env>/renames/
source "$ROOT/bin/skiplist.sh"    # SKIPLIST_FILE + SKIPLIST_AWK (sl_load/sl_hit) — input/skip.txt
PARSED0="$CACHE_DIR/_transfers0.tsv"   # raw (blacklisted, UNpropagated) cache — the incremental merge base
SESSMAP="$CACHE_DIR/_sessionsites.tsv" # session -> subscription, learned from the server log (bin/session-sites.sh)
LEGEND="$CACHE_DIR/_transfers.txt"
# SKIP LIST (input/skip.txt, shared across envs): a record whose ATTRIBUTED
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
# the CONFIG FALLBACK section below). ensure_config refreshes them from the
# config exports; if any is missing (no export in input/flow-manager/) the
# fallback is skipped rather than failing the parse.
ensure_config
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
CFG_APTN="$CONFIG_XREF/_accounts-partners.tsv"       # account <TAB> partner organisation
CFG_HPTN="$CONFIG_XREF/_hosts-partners.tsv"          # configured host <TAB> partner organisation
CFG_FLOW="$CONFIG_XREF/_subscriptions-flowdir.tsv"   # subscription <TAB> out|in|relay (file-movement direction)
mkdir -p "$CACHE_DIR"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
# (zero files is a legitimate state — handled below, after parser_sig)

# ---------------------------------------------------------------------------
# Incremental parsing. data/_transfers.files records every input CSV already in
# the cache (basename + byte size). A run then only tokenizes files NOT in the
# manifest and MERGES their rows into the sorted cache — adding a new export
# costs one small parse, not a re-tokenize of everything. A changed or removed
# manifest file (or `touch input/*.csv`) forces a full reparse; a cache without
# a manifest that is newer than every input is adopted as-is (manifest written,
# nothing reparsed). Editing parse.sh also forces a full reparse: a checksum of
# the parser is stored in data/_transfers.parser and a mismatch triggers a rebuild.
# ---------------------------------------------------------------------------
MANIFEST="$CACHE_DIR/_transfers.files"
manifest_entry() { printf '%s\t%s\n' "$(basename "$1")" "$(wc -c < "$1" | tr -d ' ')"; }
in_manifest()    { cut -f1 "$MANIFEST" | grep -qxF "$(basename "$1")"; }

# Parser-version guard: record a checksum of THIS script alongside the cache. A
# changed parser (or a cache with no recorded version) forces a full reparse, so
# editing parse.sh actually re-tokenizes instead of reusing a stale cache.
PSIG="$CACHE_DIR/_transfers.parser"
# The parser SIGNATURE covers input/blacklist.txt and the RENAME MAP as well as
# this script: the blacklist decides what gets blanked and the map decides which
# logged subscription name folds to which current one, so changing either
# changes the cache just as
# surely as changing the code, and must force the same full reparse.
parser_sig=$(cat "${BASH_SOURCE[0]}" "$BLACKLIST_FILE" "$RENAMES_FILE" "$RENAMES_PROF" 2>/dev/null | cksum | awk '{print $1"_"$2}')

# CONFIG-ONLY ESTATE (2026-08): an env with the flow-manager exports but not a
# single log CSV is a legitimate state — a fresh clone carries only the JSONs
# (the *.csv exports are gitignored). Write the complete cache set EMPTY
# instead of failing: every downstream consumer then renders "configured,
# never seen" (all orange) rather than aborting the build. Idempotent: a
# re-run with the empty caches in place and no watched config newer than the
# cache exits without touching an mtime, so a warm build stays a no-op.
if [ ${#files[@]} -eq 0 ]; then
    if [ "$parser_sig" = "$(cat "$PSIG" 2>/dev/null)" ] \
       && [ -f "$MANIFEST" ] && [ ! -s "$MANIFEST" ] \
       && [ -f "$PARSED0" ] && [ ! -s "$PARSED0" ] \
       && [ -f "$PARSED" ] && [ -f "$FILES" ] \
       && [ -f "$SKIPOUT" ] && [ -f "$SKIPCSV" ] \
       && [ -z "$(find "$CONFIG_XREF" -name '_*.tsv' -newer "$PARSED" 2>/dev/null)" ]; then
        echo "No *.csv in $INPUT_DIR — config-only estate; the empty caches are up to date." >&2
        exit 0
    fi
    echo "No *.csv in $INPUT_DIR — writing EMPTY caches (config-only estate)." >&2
    : > "$PARSED0"; : > "$PARSED"; : > "$FILES"
    : > "$MANIFEST"; : > "$SKIPOUT"; : > "$SKIPCSV"
    printf '%s\n' "$parser_sig" > "$PSIG"
    exit 0
fi

mode=full
do_tokenize=1
new_files=()
if [ "$parser_sig" != "$(cat "$PSIG" 2>/dev/null)" ]; then
    [ -e "$PSIG" ] && echo "parse.sh changed since the cache was built — full reparse." >&2
elif [ -f "$PARSED0" ] && [ -f "$MANIFEST" ]; then
    mode=incremental
    while IFS=$'\t' read -r name size; do
        [ -n "$name" ] || continue
        f="$INPUT_DIR/$name"
        if [ ! -e "$f" ]; then
            echo "Input $name was removed since the cache was built — full reparse." >&2
            mode=full; break
        fi
        if [ "$(wc -c < "$f" | tr -d ' ')" != "$size" ] || [ "$f" -nt "$MANIFEST" ]; then
            echo "Input $name changed since the cache was built — full reparse." >&2
            mode=full; break
        fi
    done < "$MANIFEST"
    if [ "$mode" = incremental ]; then
        for f in "${files[@]}"; do
            in_manifest "$f" || new_files+=("$f")
        done
        if [ ${#new_files[@]} -eq 0 ]; then
            # The raw cache covers every input. Exit only if the DERIVED caches
            # (_transfers.tsv and the two collapses) are present and up to date —
            # i.e. no config cache this parse consumes (the fallback inputs AND
            # the PDA caches behind _files.tsv cols 16-19) is newer; otherwise
            # fall through to rebuild just the derivations.
            cfg_newer=0
            # every XREF cache the DERIVE reads must be here (CFG_FLOW feeds
            # _files.tsv col 17). CFG_SUBS (base/_subscriptions.tsv) is read
            # too but deliberately NOT watched: bin/build/result.sh and
            # bin/build/seen-in-server-log.sh recolor its result column AFTER the
            # parse (never the names the derive reads), and a real config
            # change rewrites these xref caches as well (bin/flow-manager.sh
            # writes both trees) — same rule as lib.sh's ensure_parsed.
            for cf in "$CFG_AS" "$CFG_SP" "$CFG_PAT" "$CFG_AL" "$CFG_AH" "$CFG_AAPP" "$CFG_ADOM" "$CFG_APTN" "$CFG_HPTN" "$CFG_FLOW"; do
                if [ -f "$cf" ] && [ "$cf" -nt "$PARSED" ]; then cfg_newer=1; break; fi
            done
            # a changed skip.txt, or a missing skip sidecar, must re-derive too
            if { [ -f "$SKIPFILE" ] && [ "$SKIPFILE" -nt "$PARSED" ]; } || [ ! -f "$SKIPOUT" ] || [ ! -f "$SKIPCSV" ]; then cfg_newer=1; fi
            # a grown session map (bin/session-sites.sh learned a flow from
            # the server log) must re-derive too — the SESSION JOIN pass reads it
            if [ -f "$SESSMAP" ] && [ "$SESSMAP" -nt "$PARSED" ]; then cfg_newer=1; fi
            # the derived caches must also be INTACT: at least as new as the
            # row cache (an interrupted run leaves them older) and _files.tsv
            # fully joined (20 columns — the interrupt window between its two
            # mv's leaves the 15-column intermediate). A failed check falls
            # through to the derive-only rebuild below, which heals both.
            if [ -f "$PARSED" ] && [ -f "$CACHE_DIR/_files.tsv" ] \
               && ! [ "$PARSED0" -nt "$PARSED" ] && [ "$cfg_newer" = 0 ] \
               && ! [ "$PARSED" -nt "$CACHE_DIR/_files.tsv" ] \
               && [ -s "$CACHE_DIR/_files.tsv" ] \
               && head -1 "$CACHE_DIR/_files.tsv" | LC_ALL=C awk -F'\t' '{exit !(NF>=20)}'; then
                echo "$PARSED already covers all ${#files[@]} input file(s); nothing to parse." >&2
                exit 0
            fi
            echo "$PARSED0 already covers all ${#files[@]} input file(s); rebuilding the derived caches only." >&2
            do_tokenize=0
        fi
    fi
elif [ -f "$PARSED0" ] && [ -f "$PARSED" ] && [ -z "$(find "$INPUT_DIR" -name '*.csv' -newer "$PARSED0" 2>/dev/null)" ]; then
    for f in "${files[@]}"; do manifest_entry "$f"; done > "$MANIFEST"
    echo "Adopted existing $PARSED0 as covering all ${#files[@]} input file(s) (manifest written)." >&2
    exit 0
fi

tmp="$PARSED.tmp.$$"

if [ "$do_tokenize" = 1 ]; then

if [ "$mode" = incremental ]; then
    src_files=("${new_files[@]}")
    echo "Incremental: parsing ${#src_files[@]} new file(s) and merging into $PARSED0 ..." >&2
else
    src_files=("${files[@]}")
    echo "Parsing ${#src_files[@]} file(s) into $PARSED0 ..." >&2
fi
awk -v BLF="$BLACKLIST_FILE" -v RNF="$RENAMES_FILE" -v RNP="$RENAMES_PROF" "$BLACKLIST_AWK$RENAMES_AWK"'
    BEGIN { bl_load(BLF); rn_load(RNF, RNP) }
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
        n = split_csv($0)

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
        # A filled subscription MUST start with "UC" (every real subscription
        # follows the UCn naming convention): any other value — P14303_CFT01,
        # "none", "Clone - ..." config artifacts — is ignored (blanked, row
        # kept), so it never reaches _files.tsv or a report. The propagation /
        # config fallbacks below may then recover the real subscription.
        if (bl_blank("site", site)) site = ""
        # Subscriptions are logged as <name>_SCP_<tail> (or _SSCP_ / _CCP_);
        # the tail is truncated to varying lengths across exports, so keep only the
        # stable part BEFORE the _SCP_ / _SSCP_ / _CCP_ marker (the clean configured
        # subscription name — matches the config export). Centralized here so every
        # report, cache and detail page sees the canonical name.
        else if ((scp = index(site, "_SSCP_")) > 0 || (scp = index(site, "_SCP_")) > 0 || (scp = index(site, "_CCP_")) > 0) site = substr(site, 1, scp - 1)
        # RENAMES (2026-08): a log line keeps the name that was current when it
        # was written, so an export that renames a subscription would otherwise
        # split its history in two — the configured half joining nothing and
        # going orange, the logged half arriving as an unknown entity. Fold the
        # logged name to the CURRENT one here, at the same single point the
        # _SCP_ tail is stripped, so every report, cache and detail page sees
        # one name per flow. The map is input/<env>/renames/subscriptions.tsv
        # (bin/renames.sh, machine-maintained by the config step); it is part of
        # parser_sig, so recording a rename re-tokenizes the whole cache.
        if (site != "") site = rn_canon(site)
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
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            sv(field[34]), sv(field[8]), sv(field[1]), sv(account), sv(login), sv(site), \
            sv(field[9]), sv(field[15]), size, sv(field[20]), date_iso, sv(t), sortkey, jd, \
            dur, sv(field[26]), bucket(field[17]), sv(field[24]), sv(field[38]), sv(field[22]), \
            sv(prof), sv(field[35]), sv(field[29]), sv(field[30])
    }
    END {
        if (dups > 0)
            printf "NOTE: dropped %d exact-duplicate record line(s) (kept the first occurrence of each).\n", dups > "/dev/stderr"
    }
' "${src_files[@]}" > "$tmp.raw"

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
    $16 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        ip = $16; a = toupper($4); s = toupper($6)
        if ((a in ah) || !(a in al)) {                                     # OUT: we dial the endpoint
            out[ip] = 1
            # WHO knows the endpoint. Entity propagation runs AFTER this pass,
            # so plenty of rows still carry a blank account — the SUBSCRIPTION
            # stands in for it there, naming the same configured endpoint of the
            # same flow. The account is asked first (more specific); only when
            # the row has none does the subscription vote. A row identified by
            # neither casts no vote at all — counting it as "no host" would make
            # every IP look ambiguous.
            if (a != "" && (a in ahost))      vote(ip, ahost[a])
            else if (s != "" && (s in shost)) vote(ip, shost[s])
        } else in_[ip] = 1
    }
    END {
        for (ip in in_) if (!(ip in out)) print "IN\t" ip
        for (ip in out) print "OUT\t" ip "\t" (((ip in cand) && cand[ip] != "\001") ? cand[ip] : "")
    }' "$al_f" "$ah_f" "$sh_f" "$tmp.raw" | LC_ALL=C sort > "$sides_f"

# ---- OUTGOING: record the configured host for any address not yet mapped ----
# No DNS here: WE dial these endpoints, so the configuration already knows the
# name. Rows are emitted only where the map does not already carry that pair, so
# a settled map is not rewritten and keeps its mtime (ip_put is cmp-guarded too).
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
    # THE ACCOUNT'S OWN ENDPOINT WINS. Several configured endpoints can share one
    # address — sftp.deployteq.net, sftp.myclang.com and sftp.nl2.myclang.com all
    # answer on 52.28.68.191 here — and the address alone cannot say which of them
    # a transfer used; only the row's account can. The sides pass above already
    # resolved that vote per address, so it is the primary map and ip-hosts.tsv
    # only fills the addresses it left undecided. Picking from ip-hosts.tsv alone
    # attributed 189 files to the wrong partner.
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
awk -F'\t' -v OFS='\t' -v BLF="$BLACKLIST_FILE" "$BLACKLIST_AWK"'
    BEGIN { bl_load(BLF) }
    FILENAME == ARGV[1] { if ($1 != "") al[toupper($1)] = 1; next }   # account -> has logins (In side)
    FILENAME == ARGV[2] { if ($1 != "") ah[toupper($1)] = 1; next }   # account -> has hosts  (Out side; wins, like the _files join)
    FILENAME == ARGV[3] { map[$1] = $2; next }
    {
        # ENDPOINTS ARE CANONICALLY LOWERCASE (site-wide rule): the logged
        # value and the substituted endpoint name alike.
        $16 = tolower($16)
        # host blacklist: internal cluster nodes are blanked (row kept). Applied
        # here, AFTER the cache fill, so the blacklisted IPs keep their
        # transfer/hostnames/ entries (unknown-hosts uses them as known transfer IPs).
        if (bl_blank("host", $16)) $16 = ""
        else if ($16 in map) {
            a = toupper($4)
            if ((a in ah) || !(a in al)) $16 = tolower(map[$16])
        }
        print
    }' "$al_f" "$ah_f" "$hmap" "$tmp.raw" > "$tmp.mapped"

# Sort AFTER the mapping (the keys — coreid, direction — are untouched by it),
# so an incremental chunk merged with `sort -m` lands byte-identical to a full
# reparse: both orders are the same total order over the final row text.
if [ "$mode" = incremental ]; then
    LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 "$tmp.mapped" > "$tmp.chunk"
    LC_ALL=C sort -m -t"$(printf '\t')" -k1,1 -k2,2 "$PARSED0" "$tmp.chunk" > "$tmp.merged"
    # Cross-run overlap: the in-tokenizer drop (seen[$0] on the RAW record) only
    # sees the new files, so a new export overlapping the cache still yields
    # duplicate rows — which sit adjacent after the merge. Drop them here too
    # (keep the first). NOTE the key here is the whole TOKENIZED row, not the raw
    # record (the cache holds only tokenized rows at merge time). This matches a
    # full reparse for all practical purposes — the tokenized row carries every
    # captured field incl. Transfer ID (col 25, ~unique per row) — the only
    # divergence would be two distinct raw records that differ SOLELY in a CSV
    # field parse.sh discards yet share an identical Transfer ID, which does not
    # occur. Report how many were dropped.
    mdups=$(awk -v out="$tmp.dedup" 'BEGIN { printf "" > out } prev == $0 { d++; next } { prev = $0; print > out } END { print d+0 }' "$tmp.merged")   # BEGIN creates $out even for an empty merge, so the mv below never fails under set -e
    if [ "$mdups" -gt 0 ]; then
        echo "NOTE: dropped $mdups merged row(s) that duplicate rows already in the cache (overlapping export)." >&2
    fi
    mv "$tmp.dedup" "$PARSED0"
    rm -f "$tmp.chunk" "$tmp.merged"
    for f in "${src_files[@]}"; do manifest_entry "$f"; done >> "$MANIFEST"
else
    LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 "$tmp.mapped" > "$tmp.sorted"
    mv "$tmp.sorted" "$PARSED0"
    for f in "${files[@]}"; do manifest_entry "$f"; done > "$MANIFEST"
fi
rm -f "$tmp.raw" "$tmp.mapped" "$hmap"

fi   # do_tokenize

# ---------------------------------------------------------------------------
# CoreId-group entity propagation: _transfers0.tsv (the raw, blacklisted cache the
# incremental merge maintains) -> _transfers.tsv (what every report reads). The
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
# Outbound). Kept as a derived file so the incremental merge + adjacent-row
# dedup keep operating on the unpropagated stream (byte-identical guarantee).
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
            FILENAME ~ /_accounts-subscriptions\.tsv$/ { if (!($2 in acct)) acct[$2] = $1; next }
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
awk -F'\t' -v OFS='\t' '
    # Resolve a profile to its subscription, breaking a multi-claim tie on the
    # direction of the group pesit leg. Returns "" when it cannot be decided.
    function resolve_site(p, in_, out_,   i, want, hits, cand) {
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
        if (gl == "") { gl = xref_fill("L", ga, "", gs, gh, gp); if (gl != "") xgain["login"]++ }
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
                if ($4 == "" && ($6 in cacct) && cacct[$6] != "") $4 = cacct[$6]
                if (($21 == "" || $21 == "UNKNOWN") && ($6 in cprof) && cprof[$6] != "") $21 = cprof[$6]
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
        if ($1 == "S") { cacct[$2] = $3; cprof[$2] = $4 }
        else if ($1 == "P") { i = ++pn[$2]; psub[$2, i] = $3; pdir[$2, i] = $4 }
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
' "$smap" "$PARSED0" > "$tmp.prop"
mv "$tmp.prop" "$PARSED"
rm -f "$smap"

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
awk -F'\t' '{ seen[$1] = 1; if ($6 != "") has[$1] = 1; if ($10 == "http") ht[$1] = 1 }
    END { for (c in seen) if (!(c in has) || (c in ht)) print c }' "$PARSED" > "$tmp.nosub"
if [ -s "$tmp.nosub" ]; then
    awk -F'\t' -v listfile="$tmp.nosub" '
        BEGIN { while ((getline l < listfile) > 0) drop[l] = 1; close(listfile) }
        !($1 in drop)' "$PARSED" > "$tmp.nosubkept"
    mv "$tmp.nosubkept" "$PARSED"
    # PREFILTER before tokenizing. This rescans the whole input — 359 MB today —
    # only to copy out the raw lines of a handful of CoreIds (10 on the current
    # dataset), and running the per-character CSV tokenizer on every line of it
    # cost 22 s of a 73 s parse, 44% of the run, for ten lines of output.
    # A CoreId is a UUID, so one regex alternation rejects virtually every line
    # before the character loop starts; the survivors are still tokenized, so a
    # UUID that happens to appear in some OTHER field is still rejected exactly
    # as before. Measured on the real input, same output: 21.5 s -> 0.37 s.
    awk -v listfile="$tmp.nosub" '
        BEGIN { while ((getline l < listfile) > 0) { drop[l] = 1; cidre = cidre (cidre ? "|" : "") l }
                close(listfile) }
        cidre == "" || $0 !~ cidre { next }
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
    ' "${files[@]}" > "$tmp.nosubraw"
    mv "$tmp.nosubraw" "$SKIPCSV"
else
    : > "$SKIPCSV"
fi
echo "No-subscription/http skip: dropped $(wc -l < "$tmp.nosub" | tr -d ' ') CoreId(s); raw line(s) -> $SKIPCSV." >&2
rm -f "$tmp.nosub"

# SKIP LIST: partition _transfers.tsv into kept (rewrite $PARSED) and skipped
# (set aside in $SKIPOUT). A record is skipped when its attributed account
# (col 4) or subscription/site (col 6) name contains a skip token (case-
# insensitive substring). Zero tokens -> nothing skipped, empty sidecar.
mkdir -p "$(dirname "$SKIPOUT")"
: > "$tmp.skip"
# The rules come from input/skip.txt via bin/skiplist.sh — the ONE reader, so
# the transfer parse, the server parse, flow-manager and the Skipped report all
# agree what a rule means. LOGIN (col 5) is tested alongside account (4) and
# site (6): a field-specific "login" rule can target it, and an "any" rule
# covers all three.
awk -F'\t' -v SLF="$SKIPLIST_FILE" -v sc="$tmp.skip" "$SKIPLIST_AWK"'
    BEGIN { sl_load(SLF) }
    { if (SL_N > 0 && (sl_hit("account", $4) || sl_hit("login", $5) || sl_hit("site", $6))) print >> sc; else print }
' "$PARSED" > "$tmp.kept"
mv "$tmp.kept" "$PARSED"
mv "$tmp.skip" "$SKIPOUT"
echo "Skip list: set aside $(wc -l < "$SKIPOUT" | tr -d ' ') transfer record(s) -> $SKIPOUT." >&2

# Companion legend: the column names of _transfers.tsv (kept in sync with the emit
# order above). Rewritten each build; content only changes if the columns do.
cat > "$LEGEND" <<'LEGEND_EOF'
_transfers.tsv — one row per transfer-log record, TAB-separated, sorted by coreid
then direction (a transfer's Inbound + Outbound rows are adjacent, Inbound first).

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
The raw, unpropagated rows live in _transfers0.tsv (the incremental merge base; same
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

This cache never contains fabricated rows: bin/build/seen-in-server-log.sh (the
build step after both parses) marks server-log-only entities BLUE in the
base result column (data/flow-manager/base/*.tsv) and injects nothing here.
LEGEND_EOF

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
LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k13,13 "$PARSED" | awk -F'\t' '
    function hms_ms(t,   a) { if (t == "") return 0; split(t, a, "[:.]"); return ((a[1]*3600) + (a[2]*60) + a[3]) * 1000 + a[4] }
    function flush(   t1, t2, arr_end, pick_start, oc, wait, mv) {
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
        #   Waiting   >= 3 legs, ending on the staging leg (Inbound routing):
        #             a UC2 file staged for pickup, not collected yet (a later
        #             export with the collect leg re-flips it).
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
        if (rows >= 3 && last_dir == "Inbound" && last_proto == "routing") oc = "Waiting"
        else if (rows >= 2 && last_dir == "Outbound" && last_st == "Processed") {
            if (mv == "out" && (last_proto == "ssh" || last_proto == "ftp" || last_proto == "ftps")) oc = "Processed"
            else if (mv == "in" && last_proto == "pesit") oc = "Processed"
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            prev, oc, f_acct, f_date, f_time, \
            f_sortkey, f_jdn, maxsize, durtot, rows, f_file, last_site, gprof, f_login, f_host, wait
    }
    FILENAME ~ /_subscriptions-flowdir\.tsv$/ { if ($2 == "in" || $2 == "out") fd[toupper($1)] = $2; next }
    {
        if ($1 != prev) {
            flush()
            prev=$1; f_acct=""; f_date=""; f_time=""; f_sortkey=""; f_jdn=""; f_file=$8
            maxsize=0; durtot=0; rows=0; gprof=""; last_site=""; f_login=""; f_host=""
            l_jdn=""; l_time=""; l_dur=0
            arr_jdn=""; arr_time=""; arr_dur=0; pick_jdn=""; pick_time=""; pick_sum=0
        }
        rows++
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
        if ($6 != "") last_site = $6                   # destination = last non-blank site
        if (gprof == "" && $21 != "" && $21 != "UNKNOWN") gprof = $21   # the naming row wins (rows never disagree)
        if (f_login == "" && $5  != "") f_login = $5
        if (f_host  == "" && $16 != "") f_host  = $16
    }
    END { flush() }
' "$flowmap" - > "$ttmp"
mv "$ttmp" "$FILES"

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
# in, movement out; UC3: connection out, movement in); app/domain = the
# account name's segments (the xref caches), partner = the file's remote host
# (col 15) resolved through _hosts-partners.tsv to its partner ORGANISATION —
# an In file's host is the partner's connecting address, never a configured
# endpoint, so it falls back to the account's partner org (kept only when
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
for cf in "$CFG_AL" "$CFG_AH" "$CFG_AAPP" "$CFG_ADOM" "$CFG_SAPP" "$CFG_SDOM" "$CFG_APTN" "$CFG_HPTN" "$CFG_FLOW" "$CFG_SUBS"; do
    [ -f "$cf" ] && pda_caches+=("$cf")
done
ttmp="$FILES.tmp.$$"
if [ ${#pda_caches[@]} -eq 0 ]; then
    awk -F'\t' 'BEGIN{OFS="\t"} { w=$16; NF=15; print $0, "", "", "", "", "", w, "" }' "$FILES" > "$ttmp"
else
    awk -F'\t' 'BEGIN{OFS="\t"; AMB=sprintf("%c",1)}
        FILENAME ~ /_accounts-logins\.tsv$/        { al[toupper($1)]=1; next }
        FILENAME ~ /_accounts-hosts\.tsv$/         { ah[toupper($1)]=1; next }
        FILENAME ~ /_accounts-apps\.tsv$/          { aa[toupper($1)]=$2; next }
        FILENAME ~ /_accounts-domains\.tsv$/       { ad[toupper($1)]=$2; next }
        # the SUBSCRIPTION app/domain maps (2026-08-29 audit fix): a one-part
        # account derives no app/domain, but its subscription name can (the
        # flow-manager fallback) — cols 18/19 join these when the account map
        # has nothing, so coverage and the detail pages agree on those files.
        # A subscription naming two apps/domains is ambiguous -> no fill.
        FILENAME ~ /_subscriptions-apps\.tsv$/     { k=toupper($1); if(!(k in sa)) sa[k]=$2; else if(sa[k]!=$2) sa[k]=AMB; next }
        FILENAME ~ /_subscriptions-domains\.tsv$/  { k=toupper($1); if(!(k in sdo)) sdo[k]=$2; else if(sdo[k]!=$2) sdo[k]=AMB; next }
        FILENAME ~ /_accounts-partners\.tsv$/      { k=toupper($1); if(!(k in ap)) ap[k]=$2; else if(ap[k]!=$2) ap[k]=AMB; next }
        FILENAME ~ /_hosts-partners\.tsv$/         { hp[tolower($1)]=$2; next }
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
            if(h!="" && (h in hp)) p=hp[h]
            else if((a in ap) && ap[a]!=AMB) p=ap[a]
            w=$16; NF=15
            a18=(a in aa)?aa[a]:""; if(a18=="" && s!="" && (s in sa) && sa[s]!=AMB) a18=sa[s]
            d19=(a in ad)?ad[a]:""; if(d19=="" && s!="" && (s in sdo) && sdo[s]!=AMB) d19=sdo[s]
            print $0, d, m, a18, d19, p, w, ""
        }
    ' "${pda_caches[@]}" "$FILES" > "$ttmp"
fi
mv "$ttmp" "$FILES"

cat > "$TLEGEND" <<'TLEGEND_EOF'
_files.tsv — one row per LOGICAL TRANSFER (CoreId), collapsed from _transfers.tsv
(the PROPAGATED cache: blanks already filled from sibling rows where possible).
A transfer is the Inbound row + Outbound row + any retries sharing one CoreId.

col  name       rule
  1  coreid     the logical-transfer key
  2  outcome    the LAST-LEG RULES (2026-07): the last chronological leg must
                be the file's REAL delivery.
                Waiting   = >= 3 legs ending on the staging leg (Inbound
                            "routing"): a UC2 file staged for pickup, not
                            collected yet (a later export with the collect
                            leg re-flips it on the next re-collapse).
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
 18  app        the application segment of the account name (token 2 of
                <domain>-<application>-<partner>); when the account name
                yields none, the file's SUBSCRIPTION name can (the flow-manager
                fallback map, unambiguous only); "" when neither does
 19  domain     the domain segment (token 1), with the same subscription-name
                fallback; "" when neither name has one
 20  partner    the partner ORGANISATION (as named in data/flow-manager/base/
                _partners.tsv): the file's host resolved via the configured
                endpoints, else the account's unambiguous partner org; "" else
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

This cache never contains fabricated rows: server-log-only entities are
marked BLUE in the base result column; the enriched tuples live only in the
standalone audit file data/<env>/seen-in-server-log.tsv (never appended here).
TLEGEND_EOF

# (the session cache _sessions.tsv was REMOVED 2026-07 — no consumers remain)

printf '%s\n' "$parser_sig" > "$PSIG"   # record the parser version that built this cache
echo "Wrote $PARSED ($(wc -l < "$PARSED" | tr -d ' ') record(s)), $FILES ($(wc -l < "$FILES" | tr -d ' ') transfer(s)), $LEGEND, $TLEGEND." >&2

# SESSION JOIN learn/apply: scan the finished server cache for flows it names
# on the sessions of still-UCx groups; when the map learned something,
# bin/session-sites.sh re-invokes this script with AXWAY_SKIP_SESSIONS=1 (a
# derive-only re-run — one bounded extra derive, never a loop) so the rescue
# lands immediately. AXWAY_SKIP_SESSIONS=1 (bin/build.sh, and the re-run
# itself): the build runs this parse CONCURRENTLY with bin/server/parse.sh,
# so the server cache may be mid-rewrite here — the build runs the step after
# the parse barrier instead, exactly like the expire re-mark below.
if [ "${AXWAY_SKIP_SESSIONS:-0}" != 1 ]; then
    "$ROOT/bin/session-sites.sh"
fi

# Re-mark the Expired files IMMEDIATELY: the collapse above reset every such
# row to Waiting, and leaving the re-mark to bin/build.sh's expire step would
# let any ensure_parsed-triggered reparse (a standalone report run, or a
# result.sh recolor bumping the config-cache mtimes) publish Waiting-only
# data until the next full build. Idempotent + cmp-guarded; a missing server
# cache just leaves Waiting as-is (bin/expire-files.sh exits 0 with a note).
# AXWAY_SKIP_EXPIRE=1 (bin/build.sh only): the build runs this parse
# CONCURRENTLY with bin/server/parse.sh, so the server cache may be
# mid-rewrite here — the build's own expire step follows right after the
# parse barrier and does the re-mark on the finished cache instead.
if [ "${AXWAY_SKIP_EXPIRE:-0}" != 1 ]; then
    "$ROOT/bin/expire-files.sh"
fi
