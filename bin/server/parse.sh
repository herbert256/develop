#!/usr/bin/env bash
#
# parse.sh — tokenize Axway server logEntry*.csv exports into a single cache,
# mirroring transfer/parse.sh. One pass over input/*.csv writes:
#
#   data/_parse.tsv   one TAB-separated row per log record, 6 columns:
#                     Date, Time, Level, Component, Message, Session ID

#   data/_parse.txt   the column legend (names + descriptions + code tables)
#   data/_accounts.tsv       "<date time> <TAB> <name>" for every configured
#                            account (data/flow-manager/base/_accounts.tsv — bin/flow-manager.sh's
#                            cache of partners.json) mentioned in a RUNTIME
#                            record (a transfer actually running)
#   data/_subscriptions.tsv  the same, for every configured subscription
#                            (the logins/hosts FLAT tsvs were dropped
#                            2026-07 — no reader; the per-name DIRS below cover
#                            all five types, logins/hosts matched like before)
#   data/{accounts,subscriptions,logins,hosts}/<name>.tsv
#                            per configured name, its 25 most-recent runtime
#                            log rows (newest first), each a full _parse.tsv
#                            row (same 6-column layout as _parse.txt)
#   data/{accounts,...}/<name>_err_warn.tsv
#                            the same, but only the 10 most-recent Error/Warn
#                            (level E or W) rows for that name (newest first),
#                            EXCLUDING the "… Skipping the next scheduled
#                            occurrence of this task." poll-backlog warnings
#
# - Handles quoted fields containing commas (Message, Stack Trace, ...)
# - Handles quoted fields containing embedded newlines (multi-line records) by
#   buffering physical lines until the double-quote count is even
# - PARALLEL: input files are tokenized concurrently (one job per file, capped
#   at the core count), each into its own sorted+deduped chunk; a single
#   `sort -m -u` merge then dedups across chunks — byte-identical to the former
#   sequential tokenize + one giant `sort -u`, at a fraction of the wall clock.
#   The per-entity mention scan is chunked over the cores the same way.
# - Accepts DOS (CRLF) or Unix (LF) input; TAB/CR/LF are scrubbed from every
#   value so each record stays on one TAB-separated output line
# - Date is ccyy-mm-dd (sortable report key); Time is HH:MM:SS.mmm — together
#   they order records chronologically (the exports themselves are newest-first
#   within a file, so cache order is NOT chronological)
# - Level and Component are shortened to one letter (see _parse.txt tables)
#
# Usage:
#   ./parse.sh    # processes every *.csv in input/, writes data/_parse.tsv(+.txt)
#
set -euo pipefail

# Resolve all paths from this script's location (bin/server/) so it works from
# any working directory; input/ and data/ sit one level up, at server/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"   # INPUT_DIR, CACHE_DIR, IP_DIR, CONFIG_DIR, PARSED (= $CACHE_DIR/_parse.tsv)
source "$ROOT/bin/skiplist.sh"   # SKIPLIST_FILE + SKIPLIST_AWK (sl_load/sl_hit) — input/<env>/skip.txt
source "$ROOT/bin/renames.sh"    # RENAMES_FILE + RENAMES_AWK (rn_load/rn_canon) — input/<env>/renames/
OUT="$CACHE_DIR/_parse.tsv"
LEGEND="$CACHE_DIR/_parse.txt"
# SKIP LIST (input/<env>/skip.txt, per environment): a server-log record whose
# MESSAGE (col 5) contains a skip token (case-insensitive substring) is dropped
# from _parse.tsv (so no server report counts it) and set aside in _skipped.tsv
# for the "Skipped" analyses report. skip.txt is folded into the parser
# signature below, so a changed skip list forces a full reparse — the sidecar is
# then rebuilt from scratch (a full parse truncates it; an incremental appends).
# See bin/flow-manager.sh.
SKIPFILE="$ROOT/input/$AXWAY_ENV/skip.txt"   # per environment since 2026-08-31
SKIPOUT="$DATA/server/_skipped.tsv"     # skipped _parse.tsv rows (verbatim)
# awk splits stdin into kept rows (stdout) and skipped rows (>> the file passed
# as -v sc=…). A skip.txt-less run keeps everything.
# The server cache has no account/login/site columns — only the message text —
# so a rule reaches it through the "message" field, which an "any" rule also
# satisfies. That keeps the legacy flat-token behaviour (scrub any line
# mentioning the token) while a field-specific transfer rule stays out of here.
SKIP_PROG="$SKIPLIST_AWK"'
    BEGIN { sl_load(skipfile) }
    { if (SL_N > 0 && sl_hit("message", $5)) print >> sc; else print }
'

# Collect input files: every *.csv in the input/ directory.
shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob

# (zero files is a legitimate state — handled below, after build_entity_tsvs
# is defined: the config-only-estate path still builds the per-entity caches)

mkdir -p "$CACHE_DIR"

# ---------------------------------------------------------------------------
# Incremental parsing (mirrors bin/transfer/parse.sh). data/_parse.files
# records every input CSV already in the cache (basename + byte size); a run
# only tokenizes files NOT in the manifest and APPENDS their rows (cache order
# is documented as non-chronological, so append is safe). A changed or removed
# manifest file (or `touch input/*.csv`) forces a full reparse; a cache without
# a manifest that is newer than every input is adopted as-is. Editing parse.sh
# also forces a full reparse (its checksum is stored in data/_parse.parser).
# Exact-duplicate RAW records are dropped so overlapping exports cannot
# double-count (deduping on the raw record, not the 6-column projection, keeps
# same-millisecond same-message events from different threads).
# ---------------------------------------------------------------------------
MANIFEST="$CACHE_DIR/_parse.files"
manifest_entry() { printf '%s\t%s\n' "$(basename "$1")" "$(wc -c < "$1" | tr -d ' ')"; }
in_manifest()    { cut -f1 "$MANIFEST" | grep -qxF "$(basename "$1")"; }

# Parser-version guard: record a checksum of THIS script (and input/<env>/skip.txt,
# so a changed skip list forces a full reparse — the skipped rows are removed at
# cache-assembly time, so the sidecar must be rebuilt end to end) alongside the
# cache. A changed parser (or a cache with no recorded version) forces a full
# reparse, so editing parse.sh actually re-tokenizes instead of reusing a stale cache.
PSIG="$CACHE_DIR/_parse.parser"
# The RENAME MAP is part of the signature: it decides which logged subscription
# name a mention is attributed to, so recording a rename must rebuild the
# per-entity caches (bin/renames.sh).
parser_sig=$(cat "${BASH_SOURCE[0]}" "$SKIPFILE" "$RENAMES_FILE" 2>/dev/null | cksum | awk '{print $1"_"$2}')

# ---------------------------------------------------------------------------
# Parallel machinery. The 5+ GB of input is embarrassingly parallel two ways:
# tokenizing is per input FILE, and the entity-mention scan is per cache line
# RANGE — so both fan out over a small job pool (plain `&` + `wait`, portable
# to Git Bash; no wait -n, which needs bash 4.3). NJOBS = the core count.
# ---------------------------------------------------------------------------
detect_njobs() {
    local n=""
    if command -v nproc >/dev/null 2>&1; then n=$(nproc 2>/dev/null || true)
    elif command -v sysctl >/dev/null 2>&1; then n=$(sysctl -n hw.ncpu 2>/dev/null || true)
    fi
    [ -n "$n" ] || n=${NUMBER_OF_PROCESSORS:-4}   # Git Bash fallback
    case $n in ''|*[!0-9]*) n=4 ;; esac
    [ "$n" -ge 1 ] || n=1
    printf '%s\n' "$n"
}
NJOBS=${AXWAY_NJOBS:-$(detect_njobs)}   # AXWAY_NJOBS: bin/build.sh caps the parallel production chain
case $NJOBS in ''|*[!0-9]*) NJOBS=$(detect_njobs) ;; esac

# sort(1) speed flags, feature-detected: -S (buffer size) and --parallel are
# not POSIX but exist on GNU and BSD/macOS sort; each is used only when this
# box's sort accepts it. Every value is a single token (-S256M), so the
# UNQUOTED $SORT_*_FLAGS expansions word-split safely (empty = no flags).
# Chunk sorts run NJOBS at a time, so they get a modest buffer each; the
# single merge pass gets a big one.
sort_flag_ok() { printf 'a\n' | sort "$1" >/dev/null 2>&1; }
SORT_CHUNK_FLAGS=""; SORT_MERGE_FLAGS=""
if sort_flag_ok -S1M; then SORT_CHUNK_FLAGS="-S256M"; SORT_MERGE_FLAGS="-S1G"; fi
if sort_flag_ok --parallel=2; then SORT_MERGE_FLAGS="$SORT_MERGE_FLAGS --parallel=$NJOBS"; fi

POOL_PIDS=()
pool_run() {   # run "$@" as a background job, at most NJOBS at once
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$NJOBS" ]; do sleep 0.1; done
    "$@" &
    POOL_PIDS+=("$!")
}
# LONGEST-PROCESSING-TIME-FIRST dispatch. Every phase here partitions work by a
# naturally SKEWED key and used to dispatch in canonical order, so the biggest
# unit tended to start last and drain alone while the other cores idled. Profiled
# on a 9.2 GB / 32-file estate: peak pool CPU is 900-970% (the pools do saturate
# the box) but each phase spent its last third at 200-500%, because the input
# CSVs run 1315 MB against a 216 MB median (6.1x) and the biggest three were
# dispatched #14, #30 and #31 of 32.
#
# lpt_order emits "<canonical index><TAB><path>" sorted by DESCENDING size. The
# INDEX IS NOT THE DISPATCH ORDER, and must not be: the merge concatenates
# out.<idx> in index order to build the cache, and the entity scan walks
# rings.<idx> newest-first. Only the START order changes.
lpt_order() {   # args = paths in canonical index order
    local i=0 f
    for f in "$@"; do
        i=$((i + 1))
        printf '%s\t%s\t%s\n' "$(wc -c < "$f" 2>/dev/null || echo 0)" "$i" "$f"
    done | LC_ALL=C sort -k1,1rn -k2,2n | cut -f2-
}
pool_wait() {  # reap every pooled job; abort the parse if any failed
    local p st rc=0
    [ "${#POOL_PIDS[@]}" -eq 0 ] && return 0
    for p in "${POOL_PIDS[@]}"; do
        st=0
        wait "$p" || st=$?
        [ "$st" -ne 0 ] && rc=$st
    done
    POOL_PIDS=()
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: a parallel parse job failed (exit $rc) — aborting." >&2
        exit "$rc"
    fi
    return 0
}

# Both scratch dirs live in CACHE_DIR (same filesystem as the outputs) and are
# removed on ANY exit; $$ keeps two concurrent runs from colliding.
CHUNK_DIR="$CACHE_DIR/_parse.chunks.$$"
ENT_CHUNK_DIR="$CACHE_DIR/_parse.entchunks.$$"
trap 'rm -rf "$CHUNK_DIR" "$ENT_CHUNK_DIR"' EXIT

# The CSV tokenizer, one awk program run per input file (see tok_one below).
# Emits one line per record: the SCRUBBED RAW RECORD as field 1 followed by
# the 6 projected cache columns — the raw prefix exists only for the dedup
# and is cut away before the rows reach the cache.
TOK_PROG=$(cat <<'AWK_EOF'
# ---- the NOISE filter (2026-08) ---------------------------------------------
# The message shapes the platform emits for every session and every transfer
# leg, as message PREFIXES. None of them carries a fact worth keeping: a
# session id that col 6 already holds, an acknowledgement that a message was
# sent, the start/end bookends of a transfer the TRANSFER log records properly,
# the internal session counter, the Sentinel notification-command trace, the
# PESITD daemon's tagged copies of the same, the placeholder UNKNOWN lines and
# the ar- worker stop notices. Dropped here, at tokenize time, so they never
# reach the cache, the per-entity mention rings, the drill-downs or the
# failed-file error pages.
#
# This is deliberately NOT input/<env>/skip.txt: a skip-list rule sets its records
# aside in the skipped file for the Skipped report, and archiving 8M lines of
# boilerplate would cost the disk and time this filter exists to save. The skip
# list stays what it is — traffic that is real but unwanted in the statistics.
#
# Editing either list changes parser_sig (parse.sh is cksummed), so the next
# run reparses in full and the cache matches the lists. Four server reports
# were built on these lines and went with them (concurrency, event-feed,
# transfer-outcomes, file-freshness — 2026-08).
BEGIN {
    NOISE[++NOISE_N] = "Created session information with "
    NOISE[++NOISE_N] = "Removed session information with"
    NOISE[++NOISE_N] = "Universal Agent successfully sent a message of type "
    NOISE[++NOISE_N] = "{\"message\":\"Transfer end logged.\""
    NOISE[++NOISE_N] = "{\"message\":\"Transfer start logged.\""
    NOISE[++NOISE_N] = "Initializing Push As helper."
    NOISE[++NOISE_N] = "Initializing Pull AS helper."
    NOISE[++NOISE_N] = "Adding SubtransmissionStatus entry to Database "
    NOISE[++NOISE_N] = "Current ST internal session count"
    NOISE[++NOISE_N] = "Reporting event"
    NOISE[++NOISE_N] = "UNKNOWN"
    NOISE[++NOISE_N] = "Stopped ar-"
    NOISE[++NOISE_N] = "Shutdown ar-"
    # A MANUAL TEST connection from the admin UI, not a flow: "Error during
    # test connection. <reason>". It is an E-level line on the remote host, so
    # it landed in that host err/warn ring and counted as evidence against
    # every flow configured for the host — a test somebody ran by hand
    # reddening real subscriptions. Nothing in the log ties it to a transfer
    # (2026-08).
    NOISE[++NOISE_N] = "Error during test connection"
    # The Advanced Routing route-execution bookkeeping: a sandbox created and
    # purged, a route start and a route finish for EVERY route run — 1.12M of
    # the 6.38M acceptance records, 18% of the cache, all Info level. The one report built on them
    # (advanced-routing, whose Executions column WAS the AR0076 count) went with
    # them, 2026-08. Nothing else counts them: no blue evidence line, no
    # unknown-* seed and no entity mention cache rests on these three, so
    # seen-in-server-log and the result colours are untouched.
    NOISE[++NOISE_N] = "AR0011:"
    NOISE[++NOISE_N] = "AR0032:"
    NOISE[++NOISE_N] = "AR0076:"
    NOISE[++NOISE_N] = "AR0077:"
    # CONTAINS rules — the one deliberate exception to prefix-only matching.
    # "No SMTP server is configured": the notification mailer complaining the
    # platform has no SMTP endpoint, stamped per route run under TWO different
    # prefixes ("AR0046: [SECURETRANSPORT] [<sub>]  No SMTP…" and the odd
    # ": [<account>@FExxx] [<sub>]  No SMTP…"), so no prefix covers it. All
    # W-level; 38 acceptance entities' err/warn rings were NOTHING but these
    # lines. No blue evidence, no unknown-* seed and no report reads them
    # (verified 2026-08; the red flip is E-only anyway).
    NOISE_HAS[++NOISE_HAS_N] = "No SMTP server is configured"
}
# 1 when the message STARTS with one of the prefixes: index(t, p) == 1, not a
# substring test, so a line QUOTING one of these shapes inside a larger message
# is not the boilerplate and stays. The NOISE_HAS list is the deliberate
# exception — a shape logged under several prefixes (see its entry) matches
# anywhere in the message. ("Reporting event" replaced a CONTAINS rule
# on the Sentinel class path in 2026-08 — the notification-command lines all
# open with it, and a prefix cannot catch an unrelated line that merely quotes
# the path.)
#
# The DAEMON TAG is stripped first. Each daemon stamps its name in front of the
# message — "[Ssh Default] ", "[Pesit Default] ", "[Ftp Default] ",
# "[Http Default] " — and 4.4M of the 9.4M records carry one, so an anchored
# rule that did not account for it would match the bare form and miss the
# tagged twin of the very same line. The tag is framing, not message: strip it
# and every rule above covers both forms at once (this is what replaced the
# four hand-written "[Pesit Default] …" entries). Only a "<Word> Default" tag
# is stripped, so the odd "[server #173 @45f13f1d] …" lines keep their text.
function is_noise(m,   i, t, p) {
    t = m
    if (substr(t, 1, 1) == "[") {
        p = index(t, "] ")
        if (p > 9 && substr(t, p - 8, 8) == " Default") t = substr(t, p + 2)
    }
    for (i = 1; i <= NOISE_N; i++) if (index(t, NOISE[i]) == 1) return 1
    for (i = 1; i <= NOISE_HAS_N; i++) if (index(t, NOISE_HAS[i]) > 0) return 1
    return 0
}

# Count double-quotes in a string (a complete CSV record has an even count).
function count_quotes(s,   n) { n = gsub(/"/, "\"", s); return n }

# FAST head parser. Every field these exports emit is either individually
# quoted or plain without embedded commas, so the leading fields can be
# lifted with C-speed match()/index() instead of the per-character loop
# below (~2x the whole tokenize). We walk through field 18 (Session ID) — the
# deepest field the cache keeps. It was dropped in 2026-07 to stop each record
# 13 fields early, and is back (2026-08) because the SESSION is the only thing
# that ties a server line to the transfer legs of one connection: the error
# pages list a failed file's whole session, and the transfer cache carries the
# same id in col 24. Fields 6..17 are walked but not kept. Returns 1 on
# success; 0 = something irregular (e.g. text after a closing quote) — the
# caller then re-parses the record with the general parse_head, which stays
# the single source of semantics for anything malformed.
# TWO-STAGE (2026-08): fields 1..5 first, so the caller can drop an ADMIN/AUDIT
# record or one of the NOISE shapes — 69% of the export — BEFORE the remaining
# 13 fields are walked for the session id. `_rest` carries the unconsumed tail
# between the two calls; `from`/`to` bound the range, and the array is cleared
# only on the first leg.
function parse_head_fast(str, arr, from, to,   i, p, f) {
    if (from == 1) split("", arr)
    for (i = from; i <= to; i++) {
        if (str == "") { _rest = ""; return 1 }   # short record: the rest stays unset
        if (substr(str, 1, 1) == "\"") {
            if (!match(str, /^"([^"]|"")*"/)) return 0
            f = substr(str, 2, RLENGTH - 2)
            if (f ~ /""/) gsub(/""/, "\"", f)
            arr[i] = f
            str = substr(str, RLENGTH + 1)
            if (substr(str, 1, 1) == ",") str = substr(str, 2)
            else if (i < to && str != "") return 0
        } else {
            p = index(str, ",")
            if (p == 0) { arr[i] = str; str = "" }
            else { arr[i] = substr(str, 1, p - 1); str = substr(str, p + 1) }
        }
    }
    _rest = str
    return 1
}

# General parser (fallback): recover the leading fields into arr[1..18]
# (1=Time, 2=Level, 3=Component, 4=Thread, 5=Message, 18=Session ID).
# Handles "" as an escaped quote. arr is cleared first so a short record
# cannot inherit trailing fields left over from the previous record.
function parse_head(str, arr,   i, c, len, field, inq, n) {
    split("", arr)
    n = 0; field = ""; inq = 0; len = length(str)
    for (i = 1; i <= len; i++) {
        c = substr(str, i, 1)
        if (inq) {
            if (c == "\"") {
                if (substr(str, i+1, 1) == "\"") { field = field "\""; i++ }
                else inq = 0
            } else field = field c
        } else {
            if (c == "\"") inq = 1
            else if (c == ",") { arr[++n] = field; field = ""; if (n >= 18) return n }
            else field = field c
        }
    }
    arr[++n] = field
    return n
}

# Scrub TAB/CR/LF from a value so it stays inside one TAB-separated column.
function sv(s) { gsub(/[\t\r\n]/, " ", s); return s }

# Session ID (CSV field 18) as the cache keeps it: the export writes the
# literal UNKNOWN (and "unknown" for the start time) where the record belongs
# to no session — a placeholder, not an id, so it is stored as EMPTY. Every
# consumer then tests the value itself instead of knowing the magic word, and
# a join can never match two unrelated records on "UNKNOWN".
function sid(s) {
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return (s == "UNKNOWN" || s == "unknown") ? "" : sv(s)
}

# "MM/DD/YYYY HH:MM:SS.mmm" -> "ccyy-mm-dd" (date part, sorts chronologically —
# handy as a report key).
function isodate(s) {
    if (s ~ /^[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9]/)
        return substr(s,7,4) "-" substr(s,1,2) "-" substr(s,4,2)
    return s
}

# "MM/DD/YYYY HH:MM:SS.mmm" -> "HH:MM:SS.mmm" ("" when there is no time part).
function timeofday(s) {
    if (s ~ /^[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9] /)
        return substr(s, 12)
    return ""
}

# One-letter Level: I=Info, W=Warning, E=Error (fallback: first letter).
function lvl(x) {
    if (x == "INFO")  return "I"
    if (x == "WARN" || x == "WARNING") return "W"
    if (x == "ERROR") return "E"
    return substr(toupper(x), 1, 1)
}

# One-letter Component: T=TM, P=PESITD, S=SSHD (unmapped components pass
# through unchanged so anomalies stay visible). ADMIN and AUDIT records are
# dropped at tokenize time — see the record block below.
function comp(x) {
    if (x == "TM")     return "T"
    if (x == "PESITD") return "P"
    if (x == "SSHD")   return "S"
    return x
}

# Tolerate DOS (CRLF) input: drop a trailing carriage return from every physical
# line so it never leaks into a field value.
{ sub(/\r$/, "") }

# First line of every input file is the header; skip it.
FNR == 1 { rec = ""; buffering = 0; next }

{
    if (buffering) rec = rec "\n" $0
    else           rec = $0

    # Unbalanced quotes => a quoted field spans onto the next physical line.
    if (count_quotes(rec) % 2 == 1) { buffering = 1; next }
    buffering = 0

    # leg 1: fields 1..5, enough to decide whether the record is kept at all
    fastok = parse_head_fast(rec, f, 1, 5)
    if (!fastok) parse_head(rec, f)
    # ADMIN and AUDIT (config/deploy/API-trail) records are excluded from the
    # cache entirely — only the runtime components (TM, PESITD, SSHD, …) are
    # kept, so no report, mention cache or drill ever sees them.
    if (f[3] == "ADMIN" || f[3] == "AUDIT") next
    if (is_noise(f[5])) next                  # the boilerplate shapes above
    # leg 2, only for the records that survive: fields 6..18 for the Session ID
    if (fastok && !parse_head_fast(_rest, f, 6, 18)) parse_head(rec, f)
    # (`total` counts EMITTED records only, so the duplicate-drop arithmetic
    # below the parse stays about duplicates — noise never enters it)
    # Sort key (field 1, dropped by `cut -f2-`): the CHRONOLOGICAL ccyy-mm-dd+time
    # FOLLOWED by the raw record. Sorting orders the cache truly chronologically —
    # across a year boundary too (the raw MM/DD/YYYY head alone sorted 01/…2027
    # before 12/…2026), which is what the per-name "newest 25" ring relies on. The
    # raw record still trails, so `sort -u` dedups exact-duplicate lines exactly as
    # before (byte-identical within a single year, where both keys agree).
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", isodate(f[1]) " " timeofday(f[1]) " " sv(rec), isodate(f[1]), timeofday(f[1]), lvl(f[2]), comp(f[3]), sv(f[5]), sid(f[18])
    total++
}

# The per-file record count feeds the batch total (and the raw-vs-deduped
# drop note); cntfile is passed with -v by tok_one().
END { printf "%d\n", total+0 > cntfile }
AWK_EOF
)

# The entity-mention scanner, one awk program run per cache line chunk (see
# build_entity_tsvs). Identical matching to the former sequential pass; the
# only difference is HOW results leave the process: mention lines go to
# per-chunk files (concatenated in chunk order afterwards — byte-identical to
# the sequential append order), and each name's newest-10 ring is emitted as
# "type TAB name TAB record" lines for the ring merge below.
ENT_PROG=$(cat <<'AWK_EOF'
BEGIN { outf["A"]=accout; outf["S"]=subout; outf["L"]=logout; outf["H"]=hstout; rn_load(RNF) }
# One matched (type, name) per record: append the mention line and keep
# the newest 25 full records per name in a ring ($0 is the 6-col record),
# plus the newest 10 ERROR/WARN records ($3 == "E" || "W") in a second ring.
# The scheduler-overrun warning "… Skipping the next scheduled occurrence of
# this task." is EXCLUDED from the err/warn ring — a poll running longer than
# its interval is routine backlog noise, not a failure to flag (it would
# otherwise dominate the after-last-transfer banner/merge); it still rides
# along in the all-level ring as ordinary recent log.
function hit(ty, w,   k) {
    k = ty SUBSEP w
    if (seen[k] == NR) return
    seen[k] = NR
    print t "\t" w >> outf[ty]
    ring[k, cnt[k] % 25] = $0
    cnt[k]++
    if (($3 == "E" || $3 == "W") && $5 !~ /Skipping the next scheduled occurrence of this task/) { ewring[k, ewcnt[k] % 10] = $0; ewcnt[k]++ }
}
FILENAME ~ /_accounts\.tsv$/      { if ($1 != "") acc[$1] = 1;            next }   # base files: col 1 = name, col 2 = direction
FILENAME ~ /_subscriptions\.tsv$/ { if ($1 != "") sub_[$1] = 1;           next }
FILENAME ~ /_logins\.tsv$/        { if ($1 != "") lgn[$1] = 1;            next }
FILENAME ~ /_hosts\.tsv$/         { if ($1 != "") hstU[toupper($1)] = $1; next }   # DNS names: match case-insensitively, attribute under the config spelling
{
    t = $1 (($2 != "") ? " " $2 : "")
    k = split($5, tok, /[^A-Za-z0-9._-]+/)   # dots kept: hostnames/IPs stay one token
    for (i = 1; i <= k; i++) {
        w = tok[i]; gsub(/^\.+|\.+$/, "", w); if (w == "") continue   # trim sentence dots
        if (w ~ /\./) {   # dotted: only a host can match (every configured host is dotted)
            if (toupper(w) in hstU) hit("H", hstU[toupper(w)])
            n2 = split(w, sub2, /\.+/)
        } else { n2 = 1; sub2[1] = w }
        for (i2 = 1; i2 <= n2; i2++) {
            w2 = sub2[i2]; if (w2 == "") continue
            if (w2 in acc) hit("A", w2)
            if (w2 in lgn) hit("L", w2)
            # A runtime site token is usually the FULL subscription name: the
            # clean subscription name plus a log-only _SCP_..._PWD|KEY (or
            # _SSCP_... / _CCP_...) tail (subscriptions.json holds the clean names,
            # and "_" is inside the token class, so the tailed form is ONE token
            # that never matches exactly). Strip the tail and retry, attributing
            # under the clean name so those records land in the right <name>.tsv.
            # RENAMES (2026-08): a log line keeps the name that was current
            # when it was written, so after an export renames a subscription
            # the token matches nothing and the flow loses its mentions. Try,
            # in order: the token as logged, the _SCP_-stripped form, and each
            # of those folded through the rename map to its CURRENT name — the
            # same fold bin/transfer/parse.sh applies to col 6, so both sides
            # attribute a renamed flow to one name.
            if (!(w2 in sub_)) {
                p = index(w2, "_SSCP_"); if (p == 0) p = index(w2, "_SCP_"); if (p == 0) p = index(w2, "_CCP_")
                cand = (p > 1) ? substr(w2, 1, p - 1) : w2
                if (cand in sub_) w2 = cand
                else { c2 = rn_canon(cand); if (c2 in sub_) w2 = c2 }
            }
            if (w2 in sub_) hit("S", w2)
        }
    }
}
# Emit this chunk's rings, newest first (the chunk is a contiguous slice of
# the ascending-by-date+time cache, so the ring holds ITS newest 10).
END {
    for (k in cnt) {
        split(k, a, SUBSEP)
        m = (cnt[k] < 25) ? cnt[k] : 25
        for (j = 0; j < m; j++)
            print a[1] "\t" a[2] "\t" ring[k, (cnt[k] - 1 - j) % 25] >> ringout
    }
    for (k in ewcnt) {
        split(k, a, SUBSEP)
        m = (ewcnt[k] < 10) ? ewcnt[k] : 10
        for (j = 0; j < m; j++)
            print a[1] "\t" a[2] "\t" ewring[k, (ewcnt[k] - 1 - j) % 10] >> ewout
    }
}
AWK_EOF
)

# Ring merge: reads the per-chunk ring files NEWEST CHUNK FIRST (each already
# newest-first within itself), so per (type, name) the first `cap` lines seen
# ARE the global newest-`cap` — then writes each name's <name><suffix>.tsv
# exactly like the former sequential END block. Run twice: cap=25 suffix=""
# for the all-level rings, cap=10 suffix="_err_warn" for the Error/Warn rings.
# One file open at a time (close after).
RING_PROG=$(cat <<'AWK_EOF'
BEGIN { dirs["A"]=accdir; dirs["S"]=subdir; dirs["L"]=logdir; dirs["H"]=hstdir; if (cap + 0 <= 0) cap = 25 }
{
    k = $1 SUBSEP $2
    if (have[k] >= cap) next
    keep[k, have[k]++] = substr($0, length($1) + length($2) + 3)   # the record after "type TAB name TAB"
}
END {
    for (k in have) {
        split(k, a, SUBSEP)
        f = dirs[a[1]] "/" a[2] suffix ".tsv"
        for (j = 0; j < have[k]; j++) print keep[k, j] > f
        close(f)
    }
}
AWK_EOF
)

ent_one() {   # $1 = cache line chunk, $2 = 4-digit part index
    awk -F'\t' \
        -v accout="$ENT_CHUNK_DIR/A.$2" -v subout="$ENT_CHUNK_DIR/S.$2" \
        -v logout="$ENT_CHUNK_DIR/L.$2" -v hstout="$ENT_CHUNK_DIR/H.$2" \
        -v ringout="$ENT_CHUNK_DIR/rings.$2" \
        -v ewout="$ENT_CHUNK_DIR/ewrings.$2" \
        -v RNF="$RENAMES_FILE" \
        "$RENAMES_AWK$ENT_PROG" ${ENT_CFG_SRCS[@]+"${ENT_CFG_SRCS[@]}"} "$1"
}

# ---------------------------------------------------------------------------
# Companion entity files derived from the cache, one per entity TYPE — for
# every RUNTIME log record, each name-like token in the message that EXACTLY
# matches a configured name from bin/flow-manager.sh's caches emits
# "<date time> <TAB> <name>" to that type's file — deduped per record:
#   data/_accounts.tsv       <- data/flow-manager/base/_accounts.tsv      (partner names)
#   data/_subscriptions.tsv  <- data/flow-manager/base/_subscriptions.tsv
#   data/_logins.tsv         <- data/flow-manager/base/_logins.tsv        (comm-profile logins)
#   data/_hosts.tsv          <- data/flow-manager/base/_hosts.tsv         (comm-profile hosts[])
# Tokens are maximal [A-Za-z0-9._-] runs (dots INSIDE the token so hostnames
# and IPs survive whole; stray sentence dots are trimmed); a dotted token is
# checked against the configured hosts CASE-INSENSITIVELY (DNS names — the log
# says achftpacc.pondres.eu for the configured ACHFTPACC.PONDRES.EU) and then
# dot-split into plain sub-tokens for the other four types, which reproduces
# the old [A-Za-z0-9_-] tokenization exactly (it naturally splits off an
# @endpoint suffix or a URL name= value). Only names present in the config
# caches are ever emitted; the cache holds runtime records only (ADMIN and
# AUDIT are dropped at tokenize time), so these files count real activity.
# Rebuilt whenever the cache, the flow-manager XREF caches, or this script is
# newer than an output (a fresh cache refreshes them). Deliberately xref/ only,
# NOT the base/ lists the scan reads: bin/build/seen-in-server-log.sh and
# bin/build/result.sh recolor base/*.tsv's result column AFTER the parse — the scan
# reads only the name column — so watching base/ made the NEXT build redo the
# full mention scan over the whole cache for nothing (the transfer-side
# fresh-build double derive, same fix). A real config change rewrites the xref
# tree too, so nothing is missed.
#
# The SAME pass also keeps, per configured name, its 25 most-recent runtime log
# rows (newest first) in data/{accounts,subscriptions,logins,hosts}/
# <name>.tsv — each line a full _parse.tsv record (the _parse.txt 6-column
# layout). The cache is sorted ascending by date+time, so a 25-slot ring per
# name holds the last (newest) 25 and END walks it backwards for newest-first.
# A second 10-slot ring keeps only the Error/Warn (level E or W) rows, written
# to <name>_err_warn.tsv — so a name whose newest 25 are all Info still carries
# a visible trail of its last problems (the detail pages merge the two, and the
# banner comparing the last error/warn against the last transfer reads this one).
# ---------------------------------------------------------------------------
# Flat mention TSVs exist only for accounts (details.sh's mention-count KPI)
# and subscriptions (went-kaput.sh's skip_if_fresh dep) — the logins/hosts
# flats had NO reader and were dropped 2026-07; their per-name DIRS
# (the last-25 / err-warn rings) remain for all four types.
ACCOUNTS_TSV="$CACHE_DIR/_accounts.tsv";      ACCOUNTS_DIR="$CACHE_DIR/accounts"
SUBS_TSV="$CACHE_DIR/_subscriptions.tsv";     SUBS_DIR="$CACHE_DIR/subscriptions"
LOGINS_DIR="$CACHE_DIR/logins"
HOSTS_DIR="$CACHE_DIR/hosts"
# Configured name lists: bin/flow-manager.sh's caches (one name per line), refreshed
# from the config exports by ensure_config (lib.sh). A missing cache file (no
# export anywhere) leaves that type's known set — and its outputs — empty.
ensure_config
CFG_ACCOUNTS="$CONFIG_BASE/_accounts.tsv"
CFG_SUBS="$CONFIG_BASE/_subscriptions.tsv"
CFG_LOGINS="$CONFIG_BASE/_logins.tsv"
CFG_HOSTS="$CONFIG_BASE/_hosts.tsv"

build_entity_tsvs() {
    [ -f "$OUT" ] || return 0
    local out cfg fresh=1
    for out in "$ACCOUNTS_TSV" "$SUBS_TSV"; do
        if [ ! -f "$out" ] || [ "$OUT" -nt "$out" ] || [ "${BASH_SOURCE[0]}" -nt "$out" ] \
           || [ -n "$(find "$CONFIG_XREF" -name '_*.tsv' -newer "$out" 2>/dev/null)" ]; then fresh=0; fi
    done
    # The per-name detail dirs share the same derivation; if any is missing, rebuild.
    { [ -d "$ACCOUNTS_DIR" ] && [ -d "$SUBS_DIR" ] && [ -d "$LOGINS_DIR" ] && [ -d "$HOSTS_DIR" ]; } || fresh=0
    # The rescan marker (2026-08-15 fresh-build fix): bin/build/seen-in-server-log.sh
    # APPENDS SSH-logon-discovered names to the base rosters AFTER this scan
    # ran, so on a from-scratch build those entities' mention rings are one
    # build behind (their detail pages lose the server-log table). The blue
    # step drops this marker when it appended; bin/build.sh re-runs this parse
    # right after, and the marker forces exactly one rescan.
    [ -f "$CACHE_DIR/.rescan-mentions" ] && fresh=0
    [ "$fresh" = 1 ] && { echo "  the per-entity server caches are up to date; skipping." >&2; return 0; }
    ENT_CFG_SRCS=()   # global: ent_one's background jobs read it
    for cfg in "$CFG_ACCOUNTS" "$CFG_SUBS" "$CFG_LOGINS" "$CFG_HOSTS"; do
        if [ -f "$cfg" ]; then ENT_CFG_SRCS+=("$cfg")
        else echo "WARNING: $cfg not found — its server entity cache will be empty." >&2; fi
    done
    : > "$ACCOUNTS_TSV"; : > "$SUBS_TSV"
    # Rebuild the per-name detail dirs from scratch so a name that dropped out of
    # the config (or the logs) leaves no stale <name>.tsv behind.
    rm -rf "$ACCOUNTS_DIR" "$SUBS_DIR" "$LOGINS_DIR" "$HOSTS_DIR"
    mkdir -p "$ACCOUNTS_DIR" "$SUBS_DIR" "$LOGINS_DIR" "$HOSTS_DIR"
    # The heavy scan runs in parallel: the cache is split into NJOBS contiguous
    # line chunks and ENT_PROG (defined up top) runs on each against the same
    # config lists. Because the chunks are contiguous and processed in cache
    # order, concatenating the per-chunk mention files in chunk order
    # reproduces the former sequential append order byte for byte, and the
    # ring merge (RING_PROG, newest chunk first) re-derives each name's global
    # newest-10.
    local lines per cf nparts i part spec ty dest ringparts
    rm -rf "$ENT_CHUNK_DIR"; mkdir -p "$ENT_CHUNK_DIR"
    nparts=0
    if [ -n "${ENT_PARTS+set}" ] && [ "${#ENT_PARTS[@]}" -gt 0 ]; then
        # a full parse just ran: its per-date merge outputs ARE the final
        # cache rows in cache order — scan them in place, no `split` copy
        # index = position in cache order (the rings below are walked newest-index
        # first); dispatch biggest-first
        nparts=${#ENT_PARTS[@]}
        while IFS=$'\t' read -r i cf; do
            pool_run ent_one "$cf" "$(printf '%04d' "$i")"
        done < <(lpt_order "${ENT_PARTS[@]}")
        pool_wait
    else
        lines=$(wc -l < "$OUT" | tr -d ' ')
        if [ "$lines" -gt 0 ]; then
            per=$(( (lines + NJOBS - 1) / NJOBS ))
            split -l "$per" "$OUT" "$ENT_CHUNK_DIR/in."
            local inparts=("$ENT_CHUNK_DIR"/in.*)
            nparts=${#inparts[@]}
            while IFS=$'\t' read -r i cf; do
                pool_run ent_one "$cf" "$(printf '%04d' "$i")"
            done < <(lpt_order "${inparts[@]}")
            pool_wait
        fi
    fi
    for spec in "A:$ACCOUNTS_TSV" "S:$SUBS_TSV"; do
        ty=${spec%%:*}; dest=${spec#*:}
        i=1
        while [ "$i" -le "$nparts" ]; do
            part="$ENT_CHUNK_DIR/$ty.$(printf '%04d' "$i")"
            if [ -f "$part" ]; then cat "$part" >> "$dest"; fi
            i=$((i + 1))
        done
    done
    # The all-level rings (cap 25 -> <name>.tsv) and, alongside them, the
    # Error/Warn rings (cap 10 -> <name>_err_warn.tsv). Both are collected
    # newest-chunk-first and merged by the SAME RING_PROG (cap + suffix vary).
    local ewringparts=()
    ringparts=()
    i=$nparts
    while [ "$i" -ge 1 ]; do
        part="$ENT_CHUNK_DIR/rings.$(printf '%04d' "$i")"
        if [ -f "$part" ]; then ringparts+=("$part"); fi
        part="$ENT_CHUNK_DIR/ewrings.$(printf '%04d' "$i")"
        if [ -f "$part" ]; then ewringparts+=("$part"); fi
        i=$((i - 1))
    done
    if [ "${#ringparts[@]}" -gt 0 ]; then
        awk -F'\t' -v accdir="$ACCOUNTS_DIR" -v subdir="$SUBS_DIR" -v logdir="$LOGINS_DIR" \
                   -v hstdir="$HOSTS_DIR" -v cap=25 -v suffix="" \
            "$RING_PROG" "${ringparts[@]}"
    fi
    if [ "${#ewringparts[@]}" -gt 0 ]; then
        awk -F'\t' -v accdir="$ACCOUNTS_DIR" -v subdir="$SUBS_DIR" -v logdir="$LOGINS_DIR" \
                   -v hstdir="$HOSTS_DIR" -v cap=10 -v suffix="_err_warn" \
            "$RING_PROG" "${ewringparts[@]}"
    fi
    rm -rf "$ENT_CHUNK_DIR"
    echo "Wrote the per-entity server caches:" >&2
    local i tsvs dirsx
    tsvs=("$ACCOUNTS_TSV" "$SUBS_TSV" "" "")
    dirsx=("$ACCOUNTS_DIR" "$SUBS_DIR" "$LOGINS_DIR" "$HOSTS_DIR")
    for i in 0 1 2 3; do
        if [ -n "${tsvs[$i]}" ]; then
            printf '  %s: %s row(s), %s per-name detail file(s) (+ %s err/warn)\n' "$(basename "${tsvs[$i]}")" \
                "$(wc -l < "${tsvs[$i]}" | tr -d ' ')" \
                "$(find "${dirsx[$i]}" -name '*.tsv' ! -name '*_err_warn.tsv' | wc -l | tr -d ' ')" \
                "$(find "${dirsx[$i]}" -name '*_err_warn.tsv' | wc -l | tr -d ' ')" >&2
        else
            printf '  %s/: %s per-name detail file(s) (+ %s err/warn)\n' "$(basename "${dirsx[$i]}")" \
                "$(find "${dirsx[$i]}" -name '*.tsv' ! -name '*_err_warn.tsv' | wc -l | tr -d ' ')" \
                "$(find "${dirsx[$i]}" -name '*_err_warn.tsv' | wc -l | tr -d ' ')" >&2
        fi
    done
    rm -f "$CACHE_DIR/.rescan-mentions"   # the appended-names marker is served (see the freshness check)
}

# (The server-log hostname forward-resolution was REMOVED 2026-07. It scanned
# messages for "remote host <FQDN>", resolved each and recorded ip -> name so
# those addresses carried the hostname the partner actually uses. With reverse
# DNS gone there is nothing left for it to override, and the address<->endpoint
# map is sourced from the CONFIGURATION alone — see bin/ip.sh. The server parse
# no longer writes to input/ at all.)

# CONFIG-ONLY ESTATE (2026-08): no server CSVs at all — the transfer twin's
# rule (see bin/transfer/parse.sh): write the cache set EMPTY instead of
# failing, idempotently, and still run build_entity_tsvs so the per-entity
# caches (the two flat TSVs + the four per-name dirs) exist, empty, for every
# consumer that expects them.
if [ ${#files[@]} -eq 0 ]; then
    if [ "$parser_sig" = "$(cat "$PSIG" 2>/dev/null)" ] \
       && [ -f "$OUT" ] && [ ! -s "$OUT" ] \
       && [ -f "$MANIFEST" ] && [ ! -s "$MANIFEST" ] && [ -f "$SKIPOUT" ]; then
        echo "No *.csv in $INPUT_DIR — config-only estate; the empty cache is up to date." >&2
        build_entity_tsvs
        exit 0
    fi
    echo "No *.csv in $INPUT_DIR — writing an EMPTY cache (config-only estate)." >&2
    : > "$OUT"; : > "$MANIFEST"; : > "$SKIPOUT"
    printf '%s\n' "$parser_sig" > "$PSIG"
    build_entity_tsvs
    exit 0
fi

mode=full
new_files=()
if [ "$parser_sig" != "$(cat "$PSIG" 2>/dev/null)" ]; then
    [ -e "$PSIG" ] && echo "parse.sh changed since the cache was built — full reparse." >&2
elif [ -f "$OUT" ] && [ -f "$MANIFEST" ]; then
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
            echo "$OUT already covers all ${#files[@]} input file(s); nothing to parse." >&2
            build_entity_tsvs   # cache unchanged, but refresh the entity files if stale/missing
            exit 0
        fi
    fi
elif [ -f "$OUT" ] && [ -z "$(find "$INPUT_DIR" -name '*.csv' -newer "$OUT" 2>/dev/null)" ]; then
    for f in "${files[@]}"; do manifest_entry "$f"; done > "$MANIFEST"
    echo "Adopted existing $OUT as covering all ${#files[@]} input file(s) (manifest written)." >&2
    build_entity_tsvs
    exit 0
fi

if [ "$mode" = incremental ]; then
    echo "Incremental: parsing ${#new_files[@]} new file(s) and appending to $OUT ..." >&2
else
    echo "Parsing ${#files[@]} file(s) into $OUT ..." >&2
fi

# Tokenize + per-chunk dedup, in parallel. tok_one pipes TOK_PROG's output —
# one line per record: the SCRUBBED RAW RECORD as field 1 followed by the 6
# projected cache columns; the raw prefix exists only for the dedup step
# (identical raw = a true duplicate; two same-millisecond events differing
# only in a discarded field like Thread must BOTH survive) and is cut away
# before the rows reach the cache — straight into that chunk's
# `LC_ALL=C sort -u`. tokenize_batch fans a file list out over the pool and
# tracks the cumulative raw-record count for the drop notes.
TOK_TOTAL=0
CHUNK_N=0
tok_one() {   # $1 = input csv, $2 = 4-digit chunk index
    # The sorted chunk is SPLIT INTO PER-DATE PARTS (chunk.<idx>.d<isodate>):
    # the sort key starts with the iso date, so a sorted chunk is
    # date-contiguous and each part inherits sortedness. The full-mode merge
    # then runs PER DATE in the job pool (see below) — concatenating the
    # per-date merges in date order equals one global `sort -m -u`, because
    # every key in date d sorts before every key in date d+1. A record with
    # no parseable date lands in the bare "chunk.<idx>.d" part, whose key
    # starts with a space and sorts before any date — LC_ALL=C sorted part
    # names reproduce exactly that order.
    awk -v cntfile="$CHUNK_DIR/count.$2" "$TOK_PROG" "$1" \
        | LC_ALL=C sort $SORT_CHUNK_FLAGS -u \
        | awk -v pfx="$CHUNK_DIR/chunk.$2.d" '
            { d = substr($0, 1, index($0, " ") - 1); gsub(/[^0-9-]/, "_", d) }   # clamp: a malformed date in a corrupt export must not leak odd chars into the part FILENAME
            d != cur { if (out != "") close(out); cur = d; out = pfx d }
            { print > out }'
}
tokenize_batch() {   # tokenize every argument file into its own chunk
    local f prev=$TOK_TOTAL base=$CHUNK_N idx
    mkdir -p "$CHUNK_DIR"
    # biggest file first (see lpt_order); the index still follows argument order,
    # which is what keeps an incremental batch's chunks numbered after the last.
    while IFS=$'\t' read -r idx f; do
        pool_run tok_one "$f" "$(printf '%04d' "$((base + idx))")"
    done < <(lpt_order "$@")
    CHUNK_N=$((base + $#))
    pool_wait
    TOK_TOTAL=$(awk '{ s += $1 } END { print s + 0 }' "$CHUNK_DIR"/count.*)
    echo "records: $((TOK_TOTAL - prev))" >&2
}

# RAW-record dedupe (mirrors bin/transfer/parse.sh's seen[$0]): drop rows whose
# ENTIRE raw record is identical, so overlapping exports cannot double-count —
# but two real events in the same millisecond with the same level/component/
# message (per-thread bursts differ only in the discarded Thread field) BOTH
# survive; deduping the 6-column projection destroyed ~85k such records. The
# raw record rides along as field 1 of every chunk and `cut -f2-` strips it
# after the merge (identical raw => identical whole line). Each chunk is
# already sorted+deduped, so `sort -m -u` over the chunks equals the former
# single `sort -u` over their concatenation — same total order, same
# survivors, byte-identical cache. Cache order is documented
# non-chronological, so sort order is irrelevant and stays memory-bounded.
# Incremental: the cache keeps no raws, so cross-cache raw dedup is impossible —
# but a duplicate needs the same date, so appending is safe whenever the new
# chunk's dates don't overlap the cache; when they DO overlap, fall back to a
# full reparse (raw-deduped end to end) — the new files' chunks are reused,
# only the already-manifested files still need tokenizing.
if [ "$mode" = incremental ]; then
    tokenize_batch "${new_files[@]}"
    n_new=$TOK_TOTAL
    tmp_p="$CHUNK_DIR/new.tsv"
    LC_ALL=C sort -m -u $SORT_MERGE_FLAGS "$CHUNK_DIR"/chunk.* | cut -f2- > "$tmp_p"
    new_dates=$(cut -f1 "$tmp_p" | LC_ALL=C sort -u)
    cached_dates=$(cut -f1 "$OUT" | LC_ALL=C sort -u)
    overlap=$(LC_ALL=C comm -12 <(printf '%s\n' "$new_dates") <(printf '%s\n' "$cached_dates"))
    # BACKFILL guard: a new export whose OLDEST date precedes the cache's
    # NEWEST would append old rows AFTER newer ones — the per-name "last 25"
    # ring extraction reads cache order as recency, so a dropped-in older
    # logEntry_ file must go through the full per-date-merged reparse even
    # when its dates don't overlap the cache. (Both lists are sorted; the
    # first/last non-empty entries are the min/max.)
    new_min=$(printf '%s\n' "$new_dates" | awk 'NF { print; exit }')
    cache_max=$(printf '%s\n' "$cached_dates" | awk 'NF { m = $0 } END { print m }')
    backfill=0
    if [ -n "$new_min" ] && [ -n "$cache_max" ] && [ "$new_min" \< "$cache_max" ]; then backfill=1; fi
    if [ -n "$overlap" ] || [ "$backfill" = 1 ]; then
        if [ -n "$overlap" ]; then
            echo "NOTE: new export overlaps cached date(s) ($(printf '%s' "$overlap" | tr '\n' ' ')) — raw-level dedup needs the originals; full reparse." >&2
        else
            echo "NOTE: new export backfills older date(s) ($new_min < cached max $cache_max) — cache order must stay per-date merged; full reparse." >&2
        fi
        rm -f "$tmp_p"
        mode=full
        old_files=()
        for f in "${files[@]}"; do
            in_manifest "$f" && old_files+=("$f")
        done
        if [ "${#old_files[@]}" -gt 0 ]; then tokenize_batch "${old_files[@]}"; fi
    else
        appended=$(wc -l < "$tmp_p" | tr -d ' ')
        # SKIP LIST: append the kept rows to the cache and the skipped rows
        # (message matches a skip token) to the sidecar (which accumulates
        # across incrementals — a skip.txt change forces a full reparse instead).
        mkdir -p "$(dirname "$SKIPOUT")"
        skip_before=$([ -f "$SKIPOUT" ] && wc -l < "$SKIPOUT" | tr -d ' ' || echo 0)
        awk -F'\t' -v skipfile="$SKIPFILE" -v sc="$SKIPOUT" "$SKIP_PROG" "$tmp_p" >> "$OUT"
        rm -rf "$CHUNK_DIR"
        dropped=$(( n_new - appended ))
        [ "$dropped" -gt 0 ] && echo "NOTE: dropped $dropped exact-duplicate raw record(s) within the new file(s)." >&2
        skip_now=$([ -f "$SKIPOUT" ] && wc -l < "$SKIPOUT" | tr -d ' ' || echo 0)
        [ "$skip_now" -gt "$skip_before" ] && echo "Skip list: set aside $(( skip_now - skip_before )) new server record(s) -> $SKIPOUT." >&2
        for f in "${new_files[@]}"; do manifest_entry "$f"; done >> "$MANIFEST"
    fi
fi
if [ "$mode" = full ]; then
    if [ "$CHUNK_N" -eq 0 ]; then tokenize_batch "${files[@]}"; fi
    n_raw=$TOK_TOTAL
    # SKIP LIST: split the deduped cache into kept ($OUT) and skipped ($SKIPOUT,
    # rebuilt from scratch on a full parse). dropped = the raw duplicates
    # sort -u removed = n_raw - (kept + skipped).
    #
    # PARALLEL MERGE (2026-07): one `sort -m -u | cut | skip-awk` job PER DATE
    # over the job pool, instead of one single-threaded global merge (which
    # alone took ~100 s of the ~180 s parse). The chunk parts are per-date
    # (tok_one) and every key in date d sorts before every key in d+1, so the
    # per-date merge outputs concatenated in LC_ALL=C date order are
    # byte-identical to the former global merge — cache, sidecar and dedup
    # alike (duplicates share their date, so within-date -u = global -u).
    # The kept part outputs double as the entity-scan chunks (they are the
    # final cache rows, contiguous in cache order), so build_entity_tsvs can
    # skip its 2.7 GB `split` copy — CHUNK_DIR is removed after that.
    mkdir -p "$(dirname "$SKIPOUT")"; : > "$SKIPOUT"
    PART_DIR="$CHUNK_DIR/parts"; mkdir -p "$PART_DIR"
    merge_part() {   # $1 = iso date ("" = the no-date part)  $2 = 4-digit index
        : > "$PART_DIR/out.$2"; : > "$PART_DIR/skip.$2"
        LC_ALL=C sort -m -u $SORT_CHUNK_FLAGS "$CHUNK_DIR"/chunk.*.d"$1" | cut -f2- \
            | awk -F'\t' -v skipfile="$SKIPFILE" -v sc="$PART_DIR/skip.$2" "$SKIP_PROG" > "$PART_DIR/out.$2"
    }
    pdates=$(ls "$CHUNK_DIR" | sed -n 's/^chunk\.[0-9]*\.d//p' | LC_ALL=C sort -u)
    # The INDEX must stay in DATE order — `cat out.*` below is what puts the cache
    # in date order, and that is the whole reason the per-date merge is
    # byte-identical to the former global one. Only the DISPATCH order changes:
    # dates are 6.1x skewed too (1.8M rows against a 295K median), so the heaviest
    # date starts first instead of last.
    pi=0
    : > "$CHUNK_DIR/.lpt"
    while IFS= read -r pd; do
        ls "$CHUNK_DIR"/chunk.*.d"$pd" >/dev/null 2>&1 || continue   # zero-record degenerate case
        pi=$((pi + 1))
        printf '%s\t%s\t%s\n' \
            "$(wc -c "$CHUNK_DIR"/chunk.*.d"$pd" 2>/dev/null | awk 'END { print $1 + 0 }')" "$pi" "$pd" \
            >> "$CHUNK_DIR/.lpt"
    done <<< "$pdates"
    while IFS=$'\t' read -r pi pd; do
        pool_run merge_part "$pd" "$(printf '%04d' "$pi")"
    done < <(LC_ALL=C sort -k1,1rn -k2,2n "$CHUNK_DIR/.lpt" | cut -f2-)
    rm -f "$CHUNK_DIR/.lpt"
    pool_wait
    cat "$PART_DIR"/out.*  > "$OUT"
    cat "$PART_DIR"/skip.* > "$SKIPOUT"
    ENT_PARTS=("$PART_DIR"/out.*)   # build_entity_tsvs consumes these in place
    skipped_n=$(wc -l < "$SKIPOUT" | tr -d ' ')
    dropped=$(( n_raw - $(wc -l < "$OUT" | tr -d ' ') - skipped_n ))
    [ "$dropped" -gt 0 ] && echo "NOTE: dropped $dropped exact-duplicate raw record(s) (kept one of each)." >&2
    [ "$skipped_n" -gt 0 ] && echo "Skip list: set aside $skipped_n server record(s) -> $SKIPOUT." >&2
    for f in "${files[@]}"; do manifest_entry "$f"; done > "$MANIFEST"
fi
printf '%s\n' "$parser_sig" > "$PSIG"   # record the parser version that built this cache

# Companion legend: the column names of _parse.tsv (kept in sync with the emit
# order above). Rewritten each run; content only changes if the columns do.
cat > "$LEGEND" <<'LEGEND_EOF'
_parse.tsv — one row per Axway server-log record, TAB-separated. NOTE: the
exports are newest-first within a file, so cache row order is NOT
chronological — sort or compare on date + time.

col  name        description
  1  date        Record date as ccyy-mm-dd
  2  time        Record time as HH:MM:SS.mmm ("" if absent)
  3  level       Level, one letter (see table)
  4  component   Component, one letter (see table)
  5  message     Message (TAB/CR/LF scrubbed to spaces)
  6  session     Session ID — the connection this record belongs to, the SAME
                 id the transfer cache carries in col 24, so a file's legs and
                 the server lines of their connection join on it. "" where the
                 export wrote UNKNOWN (no session: scheduler, cluster and most
                 PESITD records).

Level codes        Component codes
  I  Info            T  TM
  W  Warning         P  PESITD
  E  Error           S  SSHD

(ADMIN and AUDIT records are dropped at parse time — the cache holds the
runtime components only.)
LEGEND_EOF

echo "Wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') record(s)) and $LEGEND." >&2

build_entity_tsvs         # derive _accounts.tsv / _subscriptions.tsv from the fresh cache
# full-mode merge parts served as the entity-scan chunks. The if-form, NOT a
# bare [ -d ] && rm: on the incremental path the dir does not exist, the test
# fails as the LAST command, and the whole parse exits 1 — which aborted the
# first incremental build after a fresh one (2026-08-24).
if [ -d "$CHUNK_DIR" ]; then rm -rf "$CHUNK_DIR"; fi
