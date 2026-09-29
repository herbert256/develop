#!/usr/bin/env bash
#
# parse.sh — tokenize Axway server logEntry*.csv exports into a single cache,
# mirroring transfer/parse.sh. One pass over input/*.csv writes:
#
#   data/_parse.tsv   one TAB-separated row per log record, 6 columns:
#                     Date, Time, Level, Component, Message, Session ID

#   data/_parse.count the cache's row count (one number, written right after
#                     _parse.tsv — bin/build.sh reads it for the build report
#                     instead of re-counting the multi-GB cache)
#   data/_parse.txt   the column legend (names + descriptions + code tables)
#   data/_subscriptions.tsv  "<date time> <TAB> <name>" for every configured
#                            subscription (data/flow-manager/base/_subscriptions.tsv)
#                            mentioned in a RUNTIME record — the one FLAT mention
#                            list (cleanup-backlog.sh reads it); the accounts /
#                            logins / hosts flats went (no reader: logins/hosts
#                            2026-07, accounts 2026-09-29) — the per-name DIRS
#                            below cover all four types
#   data/{accounts,subscriptions,logins,hosts}/<name>.tsv
#                            per configured name, its 25 most-recent runtime
#                            log rows (newest first), each a full _parse.tsv
#                            row (same 6-column layout as _parse.txt)
#   data/{accounts,...}/<name>_err_warn.tsv
#                            the same, but only the 10 most-recent Errors AND
#                            the 10 most-recent Warnings for that name (one
#                            ring per level, merged newest first),
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
#   they order records chronologically, and the cache IS in that order: the
#   merge sorts on a date+time key (the exports themselves are newest-first
#   within a file; the per-name rings, the parallel range scans and addline
#   rely on the sorted cache)
# - Level and Component are shortened to one letter (see _parse.txt tables)
#
# Usage:
#   ./parse.sh                         # every *.csv in input/ -> data/_parse.tsv(+.txt) + the mention caches
#   AXWAY_SKIP_MENTIONS=1 ./parse.sh   # the cache only
#   AXWAY_MENTIONS_ONLY=1 ./parse.sh   # the mention caches only, over the existing cache
#
set -euo pipefail

# Resolve all paths from this script's location (bin/server/) so it works from
# any working directory; input/ and data/ sit one level up, at server/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"   # INPUT_DIR, CACHE_DIR, IP_DIR, CONFIG_DIR, PARSED (= $CACHE_DIR/_parse.tsv)
source "$ROOT/bin/skiplist.sh"   # SKIPLIST_FILE + SKIPLIST_AWK (sl_load/sl_hit) — input/skip.txt
source "$ROOT/bin/ranges.sh"     # rng_feed / rng_off: the byte-range split of the parallel rescan (2026-09-27)
source "$ROOT/bin/renames.sh"    # RENAMES_FILE + RENAMES_AWK (rn_load/rn_canon) — input/renames/
# PHASE TIMINGS (2026-09-27): "TIME Ns  server parse: <phase>" laps on stderr
_sl0=$(date +%s)
_slap() { local _t1; _t1=$(date +%s); printf 'TIME %5ds  server parse: %s\n' "$((_t1 - _sl0))" "$1" >&2; _sl0=$_t1; }
OUT="$CACHE_DIR/_parse.tsv"
COUNTF="$CACHE_DIR/_parse.count"   # its row count (see the merge) — nothing else rewrites _parse.tsv
LEGEND="$CACHE_DIR/_parse.txt"
# SKIP LIST (input/skip.txt, per environment): a server-log record whose
# MESSAGE (col 5) contains a skip token (case-insensitive substring) is dropped
# from _parse.tsv (so no server report counts it) and set aside in _skipped.tsv
# for the "Skipped" analyses report; the sidecar is rebuilt on every parse.
# See bin/flow-manager.sh.
SKIPFILE="$ROOT/input/skip.txt"
SKIPOUT="$DATA/server/_skipped.tsv"     # skipped _parse.tsv rows (verbatim)
# awk splits stdin into kept rows (stdout) and skipped rows (>> the file passed
# as -v sc=…). A skip.txt-less run keeps everything.
# The server cache has no account/login/site columns — only the message text —
# so a rule reaches it through the "message" field, which an "any" rule also
# satisfies. That keeps the legacy flat-token behaviour (scrub any line
# mentioning the token) while a field-specific transfer rule stays out of here.
# The filter runs over MERGED CHUNK lines, "<sort key> TAB <cache row>": it
# drops the key itself (exactly `cut -f2-`: the key holds no TAB) and tests
# the message, the row's col 5 = the line's field 6
# — and counts the rows it keeps into the file cf (the cache line count, so
# the 3 GB cache is not re-read by wc(1) twice after the merge)
MERGE_SKIP_PROG="$SKIPLIST_AWK"'
    BEGIN { sl_load(skipfile) }
    { r = substr($0, index($0, "\t") + 1)
      if (SL_N > 0 && sl_hit("message", $6)) print r >> sc; else { print r; kept++ } }
    END { print kept + 0 > cf }
'

# Collect input files: every *.csv in the input/ directory.
shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob

# (zero files is a legitimate state — handled below, after build_entity_tsvs
# is defined: the config-only-estate path still builds the per-entity caches)

mkdir -p "$CACHE_DIR"

# ---------------------------------------------------------------------------
# ALWAYS A FULL PARSE (2026-09-28: every build is fresh — the manifest, the
# parser signature and the incremental append are gone). Exact-duplicate RAW
# records are dropped so overlapping exports cannot double-count (deduping on
# the raw record, not the 6-column projection, keeps same-millisecond
# same-message events from different threads). Three modes, one per
# bin/build.sh step:
#   (default)              tokenize + merge the cache, then the mention caches
#   AXWAY_SKIP_MENTIONS=1  tokenize + merge only — the build starts it BESIDE
#                          the config step: the tokenize reads no config
#   AXWAY_MENTIONS_ONLY=1  the per-entity mention caches over the EXISTING
#                          cache — the build's second step, and the
#                          appended-names rescan after bin/build/result.sh
# ---------------------------------------------------------------------------

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
NJOBS=${AXWAY_NJOBS:-$(detect_njobs)}   # AXWAY_NJOBS: an optional override of the pool size (nothing sets it; default = the core count)
case $NJOBS in ''|*[!0-9]*) NJOBS=$(detect_njobs) ;; esac

# sort(1) speed flags, feature-detected: -S (buffer size) and --parallel are
# not POSIX but exist on GNU and BSD/macOS sort; each is used only when this
# box's sort accepts it. Every value is a single token (-S256M), so the
# UNQUOTED $SORT_*_FLAGS expansions word-split safely (empty = no flags).
# Chunk sorts and the grouped merges run NJOBS at a time, so they get a
# modest buffer each. (The single-merge SORT_MERGE_FLAGS and its --parallel
# probe went 2026-09-29: the merge is per date-hour group now and uses these.)
sort_flag_ok() { printf 'a\n' | sort "$1" >/dev/null 2>&1; }
SORT_CHUNK_FLAGS=""
if sort_flag_ok -S1M; then SORT_CHUNK_FLAGS="-S256M"; fi

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
# sent, the internal session counter, the Sentinel notification-command
# trace, the PESITD daemon's tagged copies of the same, the placeholder
# UNKNOWN lines and the ar- worker stop notices. Dropped here, at tokenize
# time, so they never reach the cache, the per-entity mention rings, the
# drill-downs or the failed-file error pages.
# The JSON transfer BOOKENDS ("Transfer start logged." / "Transfer end
# logged.") were on this list until 2026-09-09 (user request): the "end"
# record carries the platform's OWN verdict on a transfer ("status":"ok" /
# "error" per transferId), and the platform can end one transfer twice — ok
# on the client's fresh connection, error on the one it tore down — with the
# transfer log keeping the error. bin/bookend-ok.sh settles such Files on
# the ok record, and the drill pages show the bookends through their id
# join. They stay OUT of the per-entity mention rings (the scanner skips
# them), so the detail pages keep their descriptive lines.
#
# This is deliberately NOT input/skip.txt: a skip-list rule sets its records
# aside in the skipped file for the Skipped report, and archiving 8M lines of
# boilerplate would cost the disk and time this filter exists to save. The skip
# list stays what it is — traffic that is real but unwanted in the statistics.
#
# Every parse applies the lists as they stand. Four server reports
# were built on these lines and went with them (concurrency, event-feed,
# transfer-outcomes, file-freshness — 2026-08).
BEGIN {
    NOISE[++NOISE_N] = "Created session information with "
    NOISE[++NOISE_N] = "Removed session information with"
    NOISE[++NOISE_N] = "Universal Agent successfully sent a message of type "
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
    # them, 2026-08. Nothing else counts them: no unknown-* sighting and no
    # entity mention cache rests on these three, so the result colours are
    # untouched.
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
    # lines. No unknown-* sighting and no report reads them
    # (verified 2026-08; the red flip is E-only anyway).
    NOISE_HAS[++NOISE_HAS_N] = "No SMTP server is configured"
    for (i = 1; i <= NOISE_N; i++) { NOISE_L[i] = length(NOISE[i]); c = substr(NOISE[i], 1, 1); NB[c, ++NB_N[c]] = i }
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
function is_noise(m,   i, t, p, c, k) {
    t = m
    if (substr(t, 1, 1) == "[") {
        p = index(t, "] ")
        if (p > 9 && substr(t, p - 8, 8) == " Default") t = substr(t, p + 2)
    }
    # (2026-09-27: only the prefixes opening with the first character are
    # compared, each over its own length — index() scanned the whole message
    # sixteen times per record; same verdicts)
    c = substr(t, 1, 1)
    if (c in NB_N) for (k = 1; k <= NB_N[c]; k++) { i = NB[c, k]; if (substr(t, 1, NOISE_L[i]) == NOISE[i]) return 1 }
    for (i = 1; i <= NOISE_HAS_N; i++) if (index(t, NOISE_HAS[i]) > 0) return 1
    return 0
}

# Count double-quotes in a string (a complete CSV record has an even count).
function count_quotes(s,   n) { n = gsub(/"/, "\"", s); return n }

# quoted_split(rec, nq): split an all-quoted record (it starts and ends with a
# quote; nq = its quote count) on "," into the GLOBAL f[1..np], outer quotes
# dropped and escaped quotes ("") unescaped; 1 when that IS the CSV parse, 0
# when the caller must walk the record instead (f is then garbage — the walk
# clears it). The quotes of the record are its two ends, two per separator
# and the ones INSIDE the pieces, so:
#  - nq == 2*np: no piece holds a quote — the split is exact (an EMPTY field
#    "" is two separator quotes side by side and splits to "", as parsed);
#  - otherwise every piece holding a quote must hold only PAIRS of them (runs
#    of even length): a raw field value doubles each of its quotes, and a
#    "," INSIDE a value (the one way a split can cut a field) leaves an ODD
#    run at the edge of the piece before the cut — so a clean piece set is
#    the exact parse, and the pairs unescape to one quote each.
# (2026-09-27, speed round 8: the SSH logon lines — a fifth of the kept
# production cache — quote their login and account names, and walked.)
function quoted_split(rec, nq,   i, t) {
    np = split(rec, f, /","/)
    f[1] = substr(f[1], 2); f[np] = substr(f[np], 1, length(f[np]) - 1)
    if (2 * np == nq) return 1
    for (i = 1; i <= np; i++) {
        if (!index(f[i], "\"")) continue
        t = f[i]; gsub(/""/, "", t)
        if (index(t, "\"")) return 0
        gsub(/""/, "\"", f[i])
    }
    return 1
}

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
    # (the quote count runs over the NEW line only while buffering — 2026-09-28,
    # speed round 18: recounting the whole growing record per continuation
    # line was quadratic in a multi-line record, e.g. a stack trace; a newline
    # holds no quote, so the running sum is the same count)
    if (buffering) { rec = rec "\n" $0; nq += count_quotes($0); ml = 1 }
    else           { rec = $0; nq = count_quotes(rec); ml = 0 }

    # Unbalanced quotes => a quoted field spans onto the next physical line.
    if (nq % 2 == 1) { buffering = 1; next }
    buffering = 0
    # THE PATH COUNTERS (2026-09-28): how many records, and bytes, take the
    # fast split, the walk and the per-character fallback, span lines, or are
    # dropped as ADMIN/AUDIT or noise — aggregate numbers for the console
    # summary (tokenize_batch), so the tokenizer is profiled from a runtime
    # console like every other step. No record content leaves.
    PS_REC++; PS_B += length(rec); if (ml) { PS_ML++; PS_MLB += length(rec) }

    # THE ALL-QUOTED FAST PATH (2026-09-27): the exports quote EVERY field, so
    # a record that starts and ends with a quote is split on "," in C
    # (quoted_split) instead of the two-leg walk below (over half of the
    # tokenize). Anything it cannot prove exact (an unquoted field, a quote
    # pairing it cannot vouch for) takes the walk, which stays the single
    # source of semantics for those.
    if (substr(rec, 1, 1) == "\"" && substr(rec, length(rec)) == "\"" && quoted_split(rec, nq)) {
        PS_FAST++; PS_FB += length(rec)
        if (f[3] == "ADMIN" || f[3] == "AUDIT") { PS_ADM++; next }
        if (is_noise(f[5])) { PS_NOI++; next }
    } else {
    PS_WALK++; PS_WB += length(rec)
    # leg 1: fields 1..5, enough to decide whether the record is kept at all
    fastok = parse_head_fast(rec, f, 1, 5)
    if (!fastok) { PS_SLOW++; parse_head(rec, f) }
    # ADMIN and AUDIT (config/deploy/API-trail) records are excluded from the
    # cache entirely — only the runtime components (TM, PESITD, SSHD, …) are
    # kept, so no report, mention cache or drill ever sees them.
    if (f[3] == "ADMIN" || f[3] == "AUDIT") { PS_ADM++; next }
    if (is_noise(f[5])) { PS_NOI++; next }                  # the boilerplate shapes above
    # leg 2, only for the records that survive: fields 6..18 for the Session ID
    if (fastok && !parse_head_fast(_rest, f, 6, 18)) { PS_SLOW2++; parse_head(rec, f) }
    }
    # (`total` counts EMITTED records only, so the duplicate-drop arithmetic
    # below the parse stays about duplicates — noise never enters it)
    # Sort key (field 1, dropped by `cut -f2-`): the CHRONOLOGICAL ccyy-mm-dd+time
    # FOLLOWED by the raw record. Sorting orders the cache truly chronologically —
    # across a year boundary too (the raw MM/DD/YYYY head alone sorted 01/…2027
    # before 12/…2026), which is what the per-name "newest 25" ring relies on. The
    # raw record still trails, so `sort -u` dedups exact-duplicate lines exactly as
    # before (byte-identical within a single year, where both keys agree).
    od = isodate(f[1]); ot = timeofday(f[1])
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", od " " ot " " sv(rec), od, ot, lvl(f[2]), comp(f[3]), sv(f[5]), sid(f[18])
    total++
}

# The per-file record count feeds the batch total (and the raw-vs-deduped
# drop note); cntfile is passed with -v by tok_one().
END { printf "%d\n", total+0 > cntfile
      if (pstatfile != "") printf "%d %d %d %d %d %d %d %d %d %d %d %d\n", PS_REC, PS_B, PS_ML, PS_MLB, PS_FAST, PS_FB, PS_WALK, PS_WB, PS_SLOW, PS_SLOW2, PS_ADM, PS_NOI > pstatfile
      if (tfile != "") { "date +%s" | getline te; print te > tfile } }   # when this awk finished (the part timings, tokenize_batch)
AWK_EOF
)

# The entity-mention scanner, one awk program run per cache line chunk (see
# build_entity_tsvs). Identical matching to the former sequential pass; the
# only difference is HOW results leave the process: mention lines go to
# per-chunk files (concatenated in chunk order afterwards — byte-identical to
# the sequential append order), and each name's newest-10 ring is emitted as
# "type TAB name TAB record" lines for the ring merge below.
ENT_PROG=$(cat <<'AWK_EOF'
BEGIN { rn_load(RNF)
        # the SUBSCRIPTION mention lines (the one flat list with a reader —
        # the account / login / host lines went 2026-09-29) go through cat
        # (2026-09-28, speed round 25): awk writes a regular file in 4 KB
        # chunks, ten parts at once ~300 MB on production; closed (and
        # waited for) at the top of END
        outc["S"] = "cat >> \"" subout "\""
        # THE PREFIX GATE (2026-09-27): a token can resolve to a subscription only
        # when its first 3 characters open a configured name (exact case) or an
        # old name of the rename map (upper-cased) — the tail strip, the SERVER
        # fold and the rename lookup all keep the token prefix. The resolution
        # below is half of this scan, run on every word of every message; the
        # gate is exact, and off when any name is shorter than 3 characters
        for (rk in RN_S) { RP3[substr(rk, 1, 3)] = 1; if (length(rk) < 3) SP_OFF = 1 }
        # the LENGTH GATES of name_hit: the shortest account/login name (NMIN),
        # subscription or old name (SMIN), and the smaller of the two (WMIN)
        NMIN = SMIN = 1e9
        for (rk in RN_S) if (length(rk) < SMIN) SMIN = length(rk)
        WMIN = SMIN }
function minlen(v, m) { return (length(v) < m) ? length(v) : m }
# BYTE-RANGE MODE (ent_range, 2026-09-27): the job scans only the lines of the
# cache RANGEF that START at an offset in [RLO, RHI) and stops after them —
# every job computes the same offsets, so the jobs partition the cache in
# order, exactly like the line chunks a split copy used to write
RANGEF != "" && FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
# One matched (type, name) per record: append the mention line and keep
# the newest 25 full records per name in a ring ($0 is the 6-col record),
# plus the newest 10 ERROR/WARN records ($3 == "E" || "W") in a second ring.
# The scheduler-overrun warning "… Skipping the next scheduled occurrence of
# this task." is EXCLUDED from the err/warn ring — a poll running longer than
# its interval is routine backlog noise, not a failure to flag (it would
# otherwise dominate the after-last-transfer banner/merge); it still rides
# along in the all-level ring as ordinary recent log. Same treatment
# (2026-09-12, user rule) for an Error/Warning on a TRANSFER-ENDED session —
# one whose log also holds the platform's own {"message":"Transfer end
# logged." bookend (_sessions-ended.tsv, built from the whole cache right
# before this scan): the transfer log has the last word on that session, so
# the line is not a server-log error and never raises the after-last-transfer
# banner, red flip or server-failing verdict; it stays in the all-level ring.
function hit(ty, w,   k) {
    k = ty SUBSEP w
    if (seen[k] == NR) return
    seen[k] = NR
    if (ty == "S") print t "\t" w | outc[ty]
    ring[k, cnt[k] % 25] = $0
    cnt[k]++
    # the Error/Warn ring keeps its 10 newest Errors AND its 10 newest
    # Warnings (2026-09-28 fix: one shared 10-slot ring let a burst of
    # Warnings push the flow newest Error out — and the red flip, went-kaput
    # and failed.sh judge on Errors only)
    if (($3 == "E" || $3 == "W") && !($6 in ended) && $5 !~ /Skipping the next scheduled occurrence of this task/) { ewring[k, $3, ewc[k, $3] % 10] = $0; ewc[k, $3]++; ewk[k] = 1 }
}
FILENAME ~ /_sessions-ended\.tsv$/ { if ($1 != "") ended[$1] = 1;         next }   # the transfer-ended sessions (col 1 = session id)
FILENAME ~ /_accounts\.tsv$/      { if ($1 != "") { acc[$1] = 1; NMIN = minlen($1, NMIN); WMIN = minlen($1, WMIN) }; next }   # base files: col 1 = name, col 2 = direction
FILENAME ~ /_subscriptions\.tsv$/ { if ($1 != "") { sub_[$1] = 1; SP3[substr($1, 1, 3)] = 1; if (length($1) < 3) SP_OFF = 1; SMIN = minlen($1, SMIN); WMIN = minlen($1, WMIN) }; next }
FILENAME ~ /_logins\.tsv$/        { if ($1 != "") { lgn[$1] = 1; NMIN = minlen($1, NMIN); WMIN = minlen($1, WMIN) }; next }
FILENAME ~ /_hosts\.tsv$/         { if ($1 != "") hstU[toupper($1)] = $1; next }   # DNS names: match case-insensitively, attribute under the config spelling
# the JSON transfer bookends (in the cache since 2026-09-09 for bookend-ok.sh
# and the drill pages) name the account and the file of every leg — kept OUT
# of the mention rings, which would otherwise fill up with them
index($5, "{\"message\":") == 1 { next }
{
    t = $1 (($2 != "") ? " " $2 : "")
    k = split($5, tok, /[^A-Za-z0-9._-]+/)   # dots kept: hostnames/IPs stay one token
    # (2026-09-27: the regex trims/tests run only on a token that holds a dot,
    # the SERVER/CLIENT match only on one holding the marker, and the rename
    # lookup inlines rn_canon — the scan runs twice per build over every
    # record; same hits, same order)
    # (round 6, 2026-09-27: a DOTLESS word — most of them — goes straight to
    # name_hit, without the one-element sub2 array the old loop built for it,
    # and a word shorter than the shortest name that could match it skips
    # every lookup: same hits, same order)
    for (i = 1; i <= k; i++) {
        w = tok[i]
        if (w == "") continue
        if (index(w, ".") > 0) {
            gsub(/^\.+|\.+$/, "", w); if (w == "") continue   # trim sentence dots
            if (index(w, ".") > 0) {   # dotted: only a host can match (every configured host is dotted)
                if (toupper(w) in hstU) hit("H", hstU[toupper(w)])
                n2 = split(w, sub2, /\.+/)
                for (i2 = 1; i2 <= n2; i2++) if (length(sub2[i2]) >= WMIN) name_hit(sub2[i2])
                continue
            }
        }
        if (length(w) >= WMIN) name_hit(w)
    }
}
# the account / login / subscription tests of one word (never empty). The
# LENGTH GATES are exact: a hit needs the word itself (accounts, logins) — or
# a prefix of it, the tail-stripped or folded candidate (subscriptions, old
# names of the rename map) — to BE one of those names, so a word shorter than
# the shortest of them cannot hit (NMIN, SMIN; WMIN the smaller of the two).
function name_hit(w2,   pf, p, cand, c2) {
            if (length(w2) >= NMIN) {
                if (w2 in acc) hit("A", w2)
                if (w2 in lgn) hit("L", w2)
            }
            if (length(w2) < SMIN) return
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
            pf = substr(w2, 1, 3)
            if (!SP_OFF && !(pf in SP3) && !(toupper(pf) in RP3)) return   # the prefix gate (BEGIN)
            if (!(w2 in sub_)) {
                p = index(w2, "_SSCP_"); if (p == 0) p = index(w2, "_SCP_"); if (p == 0) p = index(w2, "_CCP_")
                cand = (p > 1) ? substr(w2, 1, p - 1) : w2
                # ... and the EXTENDED site shape "<subscription>_<PROTO>_SERVER_<partner>"
                # (production, 2026-09-05 — the transfer parser folds it too,
                # site_extfold): the part before the _<PROTO>_SERVER_/_CLIENT_
                # marker, accepted only when it IS a configured name
                if (!(cand in sub_) && (index(cand, "_SERVER_") > 0 || index(cand, "_CLIENT_") > 0) && match(cand, /_[A-Za-z0-9]+_(SERVER|CLIENT)_/)) cand = substr(cand, 1, RSTART - 1)
                if (cand in sub_) w2 = cand
                else if (cand != "") { c2 = toupper(cand); if ((c2 in RN_S) && (RN_S[c2] in sub_)) w2 = RN_S[c2] }
            }
            if (w2 in sub_) hit("S", w2)
}
# Emit this chunk's rings, newest first (the chunk is a contiguous slice of
# the ascending-by-date+time cache, so the ring holds ITS newest 10).
END {
    for (ty9 in outc) close(outc[ty9])   # the mention-line pipes (BEGIN)
    for (k in cnt) {
        split(k, a, SUBSEP)
        m = (cnt[k] < 25) ? cnt[k] : 25
        for (j = 0; j < m; j++)
            print a[1] "\t" a[2] "\t" ring[k, (cnt[k] - 1 - j) % 25] >> ringout
    }
    # the two levels, each newest first, merged newest first on date+time
    for (k in ewk) {
        split(k, a, SUBSEP)
        me = (ewc[k, "E"] < 10) ? ewc[k, "E"] + 0 : 10; mw = (ewc[k, "W"] < 10) ? ewc[k, "W"] + 0 : 10
        je = 0; jw = 0
        while (je < me || jw < mw) {
            if (je < me) { re = ewring[k, "E", (ewc[k, "E"] - 1 - je) % 10]; split(re, b1, "\t"); te = b1[1] " " b1[2] }
            if (jw < mw) { rw = ewring[k, "W", (ewc[k, "W"] - 1 - jw) % 10]; split(rw, b2, "\t"); tw = b2[1] " " b2[2] }
            if (jw >= mw || (je < me && te >= tw)) { print a[1] "\t" a[2] "\t" re >> ewout; je++ }
            else { print a[1] "\t" a[2] "\t" rw >> ewout; jw++ }
        }
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
    # lvlcap=1 (the Error/Warn rings): the cap is PER LEVEL — col 5 is the
    # record level — so the file keeps up to cap Errors AND cap Warnings
    if (lvlcap) { kl = k SUBSEP $5; if (hv[kl] >= cap) next; hv[kl]++ }
    else if (have[k] >= cap) next
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
        -v subout="$ENT_CHUNK_DIR/S.$2" \
        -v ringout="$ENT_CHUNK_DIR/rings.$2" \
        -v ewout="$ENT_CHUNK_DIR/ewrings.$2" \
        -v RNF="$RENAMES_FILE" \
        "$RENAMES_AWK$ENT_PROG" ${ENT_CFG_SRCS[@]+"${ENT_CFG_SRCS[@]}"} "$1"
}
ent_range() {   # $1 = the cache, $2/$3 = the byte range [lo, hi) of line starts, $4 = 4-digit part index
    rng_feed "$1" "$2" | awk -F'\t' \
        -v subout="$ENT_CHUNK_DIR/S.$4" \
        -v ringout="$ENT_CHUNK_DIR/rings.$4" \
        -v ewout="$ENT_CHUNK_DIR/ewrings.$4" \
        -v RNF="$RENAMES_FILE" -v RANGEF=/dev/stdin -v RLO="$2" -v RHI="$3" -v ROFF="$(rng_off "$2")" \
        "$RENAMES_AWK$ENT_PROG" ${ENT_CFG_SRCS[@]+"${ENT_CFG_SRCS[@]}"} /dev/stdin
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
# ONE flat mention TSV: subscriptions (cleanup-backlog.sh) — the logins/hosts
# flats had NO reader and were dropped 2026-07, the accounts one 2026-09-29
# (its details.sh mention-count KPI was long gone); the per-name DIRS (the
# last-25 / err-warn rings) remain for all four types.
ACCOUNTS_DIR="$CACHE_DIR/accounts"
SUBS_TSV="$CACHE_DIR/_subscriptions.tsv";     SUBS_DIR="$CACHE_DIR/subscriptions"
ENDED_TSV="$CACHE_DIR/_sessions-ended.tsv"    # the sessions that logged a transfer end (one session id per line; the status column went 2026-09-29 — no reader) — their E/W lines stay out of the err/warn rings (2026-09-12)
LOGINS_DIR="$CACHE_DIR/logins"
HOSTS_DIR="$CACHE_DIR/hosts"
# Configured name lists: bin/flow-manager.sh's caches (one name per line), built
# by the config step before the mention scan runs. A missing cache file (no
# export anywhere) leaves that type's known set — and its outputs — empty.
CFG_ACCOUNTS="$CONFIG_BASE/_accounts.tsv"
CFG_SUBS="$CONFIG_BASE/_subscriptions.tsv"
CFG_LOGINS="$CONFIG_BASE/_logins.tsv"
CFG_HOSTS="$CONFIG_BASE/_hosts.tsv"

# THE NAME SET of the last mention scan (2026-09-28, speed round 26): type ⇥
# name (A/S/L/H), sorted — what the scan matched against (column 1 of the four
# base rosters). The appended-names RESCAN (the .rescan-mentions marker,
# result.sh) re-reads the whole cache (~10 s on production) for a handful of
# names — and a name can only ADD hits on a line that contains it: a token
# resolves to a subscription as itself, its tail-stripped / folded prefix or a
# rename alias of it, and to a host case-insensitively as the whole token, so
# the other names resolve exactly as before unless such a line exists (a new
# prefix or a lower length gate only lets through tokens that can reach the
# new name). mention_rescan_needed answers "no" only when no name was removed,
# every new name is a subscription or host, and no cache line holds one of
# them or a rename alias that folds to one, case-insensitively — then the scan
# over the new name set would write exactly the caches on disk.
MENTION_NAMES="$CACHE_DIR/.mention-names"
mention_names() {
    { [ -f "$CFG_ACCOUNTS" ] && awk -F'\t' '$1 != "" { print "A\t" $1 }' "$CFG_ACCOUNTS"
      [ -f "$CFG_SUBS" ]     && awk -F'\t' '$1 != "" { print "S\t" $1 }' "$CFG_SUBS"
      [ -f "$CFG_LOGINS" ]   && awk -F'\t' '$1 != "" { print "L\t" $1 }' "$CFG_LOGINS"
      [ -f "$CFG_HOSTS" ]    && awk -F'\t' '$1 != "" { print "H\t" $1 }' "$CFG_HOSTS"
      true; } | LC_ALL=C sort -u
}
mention_rescan_needed() {   # 0 = rescan, 1 = the caches on disk stand
    [ -f "$MENTION_NAMES" ] || return 0
    local cur="$CACHE_DIR/.mention-names.cur.$$" pat="$CACHE_DIR/.mention-pat.$$" hit="$CACHE_DIR/.mention-hit.$$" rc=1
    mention_names > "$cur"
    if [ -n "$(LC_ALL=C comm -23 "$MENTION_NAMES" "$cur")" ] \
       || LC_ALL=C comm -13 "$MENTION_NAMES" "$cur" | awk -F'\t' '$1 == "A" || $1 == "L" { f = 1 } END { exit !f }'; then   # (reads it all: no early exit to SIGPIPE comm under pipefail)
        rm -f "$cur"; return 0
    fi
    LC_ALL=C comm -13 "$MENTION_NAMES" "$cur" | cut -f2- > "$pat"
    if [ -s "$pat" ]; then
        # + every rename alias whose current name is a new one (renames.sh: old ⇥ current)
        [ -f "$RENAMES_FILE" ] && awk -F'\t' 'NR == FNR { N[$0] = 1; next }
            { sub(/\r$/, "") } /^[ \t]*#/ || NF < 2 || $1 == "" || $2 == "" { next } ($2 in N) { print $1 }' "$pat" "$RENAMES_FILE" >> "$pat"
        mention_hits() { LC_ALL=C awk -v PF="$pat" 'BEGIN { while ((getline l < PF) > 0) if (l != "") P[++n] = tolower(l); close(PF) }
            !h { s = tolower($0); for (i = 1; i <= n; i++) if (index(s, P[i])) { h = 1; break } }
            END { if (h) print "hit" }'; }
        line_par "$OUT" "$hit" "$NJOBS" mention_hits
        [ -s "$hit" ] && rc=0
    fi
    [ "$rc" = 1 ] && echo "  $(wc -l < "$pat" | tr -d ' ') appended name(s) or alias(es): no server-log line holds one — the mention caches stand." >&2
    rm -f "$cur" "$pat" "$hit"
    return "$rc"
}

build_entity_tsvs() {
    [ -f "$OUT" ] || return 0
    # AXWAY_SKIP_MENTIONS=1 (bin/build.sh, 2026-09-27 speed round 4): the
    # build runs the mention scan as its OWN background step right after this
    # parse, beside the server-log -> transfer joins that need only the cache
    if [ "${AXWAY_SKIP_MENTIONS:-}" = 1 ]; then return 0; fi
    local cfg
    # THE APPENDED-NAMES RESCAN (2026-08-15): bin/build/result.sh APPENDS
    # transfer-discovered names to the base rosters AFTER the first scan ran,
    # so those entities' mention rings would be missing (their detail pages
    # lose the server-log table). result.sh drops the .rescan-mentions marker
    # when it appended; bin/build.sh re-runs the mention build right after,
    # and mention_rescan_needed decides whether the new names can change
    # anything (2026-09-28 — see MENTION_NAMES).
    local rescan=0
    rm -f "$CACHE_DIR/.rescanned"
    if [ -f "$CACHE_DIR/.rescan-mentions" ] && [ -f "$MENTION_NAMES" ]; then
        if ! mention_rescan_needed; then
            rm -f "$CACHE_DIR/.rescan-mentions"
            mention_names > "$MENTION_NAMES"
            return 0
        fi
        rescan=1
    fi
    mention_names > "$MENTION_NAMES.new"   # the names this scan reads (installed at its end)
    ENT_CFG_SRCS=()   # global: ent_one's background jobs read it
    for cfg in "$CFG_ACCOUNTS" "$CFG_SUBS" "$CFG_LOGINS" "$CFG_HOSTS"; do
        if [ -f "$cfg" ]; then ENT_CFG_SRCS+=("$cfg")
        else echo "WARNING: $cfg not found — its server entity cache will be empty." >&2; fi
    done
    # The TRANSFER-ENDED sessions (2026-09-12, user rule): every session whose
    # log holds the platform's own {"message":"Transfer end logged." bookend,
    # any status and direction — an Error/Warning line on such a session is
    # NOT a server-log error (ENT_PROG keeps it out of the err/warn rings, the
    # one input of the after-last-transfer judgement everywhere: the detail
    # page banner, result.sh's red flip, went-kaput, failed.sh's server-failing
    # set). One line per session: the session id. Recomputed from the
    # WHOLE cache on every rescan, so a bookend arriving in a later export
    # retro-mutes the earlier lines of its session. The shared
    # PERSISTENT-SESSION pseudo-session (hex prefix of that literal) is never
    # listed — one bookend on it would mute thousands of unrelated lines.
    # grep -F first (2026-09-27): the bookends are a sliver of the cache, and
    # this pass ran awk over ALL of it single-threaded; grep keeps the line
    # order, and the awk still applies the exact test, so the output is the same
    # COMPUTED ONCE PER CACHE (2026-09-27, speed round 6): the list is a
    # function of the cache alone, so the appended-names rescan reuses the one
    # the first scan wrote; a tokenize removes it with the old cache.
    if [ -f "$ENDED_TSV" ]; then :
    else
    # (line_par, 2026-09-28, speed round 19: the grep runs over line-aligned
    # slices in parallel — 8 s single-threaded on production — and the slices
    # join in file order, so the awk below sees the same lines in the same order)
    ended_grep() { LC_ALL=C grep -F '{"message":"Transfer end logged.' || [ $? -eq 1 ]; }
    line_par "$OUT" "$ENDED_TSV.grep" "$NJOBS" ended_grep
    awk -F'\t' '
        index($5, "{\"message\":\"Transfer end logged.") == 1 && $6 != "" && index($6, "50455253495354454e542d53455353494f4e2d") != 1 {
            if ($6 in s) next
            s[$6] = 1
            print $6 }' "$ENDED_TSV.grep" > "$ENDED_TSV.tmp" && mv "$ENDED_TSV.tmp" "$ENDED_TSV"
    rm -f "$ENDED_TSV.grep"
    fi
    _slap "mentions: transfer-ended sessions"
    ENT_CFG_SRCS+=("$ENDED_TSV")
    echo "  transfer-ended sessions: $(wc -l < "$ENDED_TSV" | tr -d ' ') (their Error/Warning lines stay out of the err/warn rings)." >&2
    : > "$SUBS_TSV"
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
        # BYTE RANGES, NOT A SPLIT COPY (2026-09-27): the jobs read the cache
        # in place, each its own contiguous range of lines — the split wrote
        # the whole cache again first (~20 s of disk writes on 3 GB, the
        # larger half of the rescan the build runs after the colour step)
        lines=$(wc -c < "$OUT" | tr -d ' ')
        if [ "$lines" -gt 0 ]; then
            nparts=$NJOBS
            i=1
            while [ "$i" -le "$nparts" ]; do
                if [ "$i" -eq "$nparts" ]; then per=$((lines + 1)); else per=$(( i * lines / nparts )); fi
                pool_run ent_range "$OUT" "$(( (i - 1) * lines / nparts ))" "$per" "$(printf '%04d' "$i")"
                i=$((i + 1))
            done
            pool_wait
        fi
    fi
    _slap "mentions: scan ($nparts parts)"
    for spec in "S:$SUBS_TSV"; do
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
    # (the two merges write disjoint files — <name>.tsv / <name>_err_warn.tsv —
    # so they run side by side, 2026-09-27)
    local rpid="" epid=""
    if [ "${#ringparts[@]}" -gt 0 ]; then
        awk -F'\t' -v accdir="$ACCOUNTS_DIR" -v subdir="$SUBS_DIR" -v logdir="$LOGINS_DIR" \
                   -v hstdir="$HOSTS_DIR" -v cap=25 -v suffix="" \
            "$RING_PROG" "${ringparts[@]}" &
        rpid=$!
    fi
    if [ "${#ewringparts[@]}" -gt 0 ]; then
        awk -F'\t' -v accdir="$ACCOUNTS_DIR" -v subdir="$SUBS_DIR" -v logdir="$LOGINS_DIR" \
                   -v hstdir="$HOSTS_DIR" -v cap=10 -v lvlcap=1 -v suffix="_err_warn" \
            "$RING_PROG" "${ewringparts[@]}" &
        epid=$!
    fi
    if [ -n "$rpid" ]; then wait "$rpid"; fi
    if [ -n "$epid" ]; then wait "$epid"; fi
    _slap "mentions: lists + rings"
    rm -rf "$ENT_CHUNK_DIR"
    echo "Wrote the per-entity server caches:" >&2
    local i tsvs dirsx
    tsvs=("" "$SUBS_TSV" "" "")
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
    rm -f "$CACHE_DIR/.rescan-mentions"   # the appended-names marker is served
    mv "$MENTION_NAMES.new" "$MENTION_NAMES"
    # a RESCAN that ran tells bin/build.sh to colour again: result.sh coloured
    # the appended names before their mention rings existed (2026-09-28 fix)
    if [ "$rescan" = 1 ]; then : > "$CACHE_DIR/.rescanned"; fi   # the name set this scan matched (mention_rescan_needed)
}

# (The server-log hostname forward-resolution was REMOVED 2026-07. It scanned
# messages for "remote host <FQDN>", resolved each and recorded ip -> name so
# those addresses carried the hostname the partner actually uses. With reverse
# DNS gone there is nothing left for it to override, and the address<->endpoint
# map is sourced from the CONFIGURATION alone — see bin/ip.sh. The server parse
# no longer writes to input/ at all.)

# MENTIONS ONLY (AXWAY_MENTIONS_ONLY=1): the cache is there — scan it.
if [ "${AXWAY_MENTIONS_ONLY:-}" = 1 ]; then
    [ -f "$OUT" ] || { echo "parse.sh: AXWAY_MENTIONS_ONLY=1 but no $OUT — run the parse first." >&2; exit 1; }
    build_entity_tsvs
    _slap "per-entity mention caches"
    exit 0
fi

# the derived lists of the OLD cache go with it (the mention build computes
# them from the cache this run writes) — the transfer-ended sessions, the
# rescan marker + the scanned name set (a leftover pair made the next
# mentions-only run skip its scan), the logon summary
rm -f "$ENDED_TSV" "$CACHE_DIR/.rescan-mentions" "$CACHE_DIR/.rescanned" "$MENTION_NAMES" \
      "$CACHE_DIR/_logons.tsv" "$CACHE_DIR/_logons-hosts.tsv"
rm -rf "$CACHE_DIR/subsets"   # the per-consumer subsets of the old cache (srv_subset trusts .done)

# CONFIG-ONLY ESTATE (2026-08): no server CSVs at all — the transfer twin's
# rule (see bin/transfer/parse.sh): write the cache set EMPTY instead of
# failing, and still run build_entity_tsvs so the per-entity caches (the
# flat TSV + the four per-name dirs) exist, empty, for every consumer that
# expects them.
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — writing an EMPTY cache (config-only estate)." >&2
    : > "$OUT"; : > "$SKIPOUT"; printf '0\n' > "$COUNTF"
    build_entity_tsvs
    exit 0
fi

echo "Parsing ${#files[@]} file(s) into $OUT ..." >&2

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
# THE PART SPLITTER (perl since 2026-09-28, build-speed round 16): the sorted
# chunk -> chunk.<idx>.d<date>_<hour> parts. The part name is the key up to
# its first space (the iso date; a character outside [0-9-] clamped to "_" —
# a malformed date in a corrupt export must not leak odd characters into the
# FILENAME) plus "_" and the two characters after the space (the hour of a
# valid time) so the merge can split a heavy day (PER DATE-HOUR PARTS,
# 2026-09-27, build-speed round 3). The part NAMES stay in key order under
# LC_ALL=C: a non-digit becomes "!" when it sorts below "0", "~" above "9".
# A key with no date (it starts with the space) goes to the bare
# "chunk.<idx>.d" part — the awk this replaces never opened that part and
# died on the empty file name. Written in 1 MB syswrites: awk writes a
# regular file in 4 KB chunks, and ten tokenize jobs doing that at once spent
# 5x the kernel time of the whole rest of the chunk pipeline (the same parts
# byte for byte).
PART_SPLIT_PL='
my $pfx = $ARGV[0]; my ($cur, $fh, $buf) = (undef, undef, "");
sub fl { my $o = 0; my $n = length $buf;
    while ($o < $n) { my $w = syswrite($fh, $buf, $n - $o, $o); die "$pfx: write: $!\n" unless defined $w; $o += $w }
    $buf = "" }
while (my $l = <STDIN>) {
    my $r = $l; chomp $r;
    my $p = index($r, " "); my $d = $p > 0 ? substr($r, 0, $p) : "";
    $d =~ tr/0-9\-/_/c;
    if ($d ne "") {
        my $c1 = $p + 1 < length $r ? substr($r, $p + 1, 1) : "";
        my $c2 = $p + 2 < length $r ? substr($r, $p + 2, 1) : "";
        $d .= "_" . (($c1 ge "0" && $c1 le "9") ? $c1 . (($c2 ge "0" && $c2 le "9") ? $c2 : ($c2 lt "0" ? "!" : "~"))
                                                : ($c1 lt "0" ? "!" : "~"));
    }
    if (!defined $cur || $d ne $cur) {
        if (defined $fh) { fl(); close($fh) or die "$pfx: close: $!\n" }
        $cur = $d; open($fh, ">", $pfx . $d) or die "$pfx$d: $!\n"; binmode $fh;
    }
    $buf .= $l; fl() if length $buf >= 1048576;
}
if (defined $fh) { fl(); close($fh) or die "$pfx: close: $!\n" }'
tok_run() {   # $1 = chunk id; stdin = the CSV (its first line the header)
    # The sorted chunk is SPLIT INTO PER-DATE PARTS (chunk.<idx>.d<isodate>):
    # the sort key starts with the iso date, so a sorted chunk is
    # date-contiguous and each part inherits sortedness. The full-mode merge
    # then runs PER DATE in the job pool (see below) — concatenating the
    # per-date merges in date order equals one global `sort -m -u`, because
    # every key in date d sorts before every key in date d+1. A record with
    # no parseable date lands in the bare "chunk.<idx>.d" part, whose key
    # starts with a space and sorts before any date — LC_ALL=C sorted part
    # names reproduce exactly that order.
    local _k0; _k0=$(date +%s)   # the part timings (the summary in tokenize_batch)
    awk -v cntfile="$CHUNK_DIR/count.$1" -v tfile="$CHUNK_DIR/tend.$1" -v pstatfile="$CHUNK_DIR/pstat.$1" "$TOK_PROG" \
        | LC_ALL=C sort $SORT_CHUNK_FLAGS -u \
        | perl -e "$PART_SPLIT_PL" "$CHUNK_DIR/chunk.$1.d"
    printf '%s %s %s\n' "$_k0" "$(cat "$CHUNK_DIR/tend.$1" 2>/dev/null || echo "$_k0")" "$(date +%s)" > "$CHUNK_DIR/ttime.$1"
}
tok_one() {   # $1 = input csv, $2 = 4-digit chunk index
    tok_run "$2" < "$1"
}
# THE BIG-FILE SPLIT (2026-09-27, build-speed round 3): one job per file let
# the biggest export (3.2 GB of 20 GB in production) set the whole tokenize
# alone while the other cores idled. A file bigger than its fair share is cut
# into parts AT RECORD BOUNDARIES and each part is its own chunk — every
# chunk is sorted + deduped and the per-date merge below takes them all, so
# more chunks from one file merge to the same cache.
# A record boundary: TOK_PROG closes a record when the quotes collected since
# its start are EVEN, and it skips line 1 (the header) whatever it holds — so
# a newline is a boundary exactly when the quotes from the start of line 2 up
# to it are even. csv_cuts FILE K prints the K-1 cut offsets: from each
# target k*size/K the first newline with that parity, the byte after it.
# (perl: a byte-exact seek and a C-speed quote count; tr ran at ~50 MB/s.)
csv_cuts() {
    perl -e '
        my ($f, $k) = @ARGV; my $size = -s $f;
        open(my $h, "<", $f) or die "$f: $!"; binmode $h;
        my $first = <$h>; my $start = defined $first ? length($first) : 0;
        my ($pos, $q, @cuts) = ($start, 0);
        for my $t (grep { $_ > $start } map { int($_ * $size / $k) } 1 .. $k - 1) {
            seek($h, $pos, 0);
            while ($pos < $t) { my $w = $t - $pos; $w = 16777216 if $w > 16777216;
                my $n = read($h, my $b, $w); last unless $n; $q += ($b =~ tr/"//); $pos += $n }
            my ($p, $off, $cut) = ($q % 2, $pos, undef);
            seek($h, $pos, 0);
            SCAN: while (1) { my $n = read($h, my $b, 1048576); last unless $n; my $s = 0;
                while ((my $nl = index($b, "\n", $s)) >= 0) {
                    $p = ($p + (substr($b, $s, $nl - $s) =~ tr/"//)) % 2;
                    if ($p == 0) { $cut = $off + $nl + 1; last SCAN } $s = $nl + 1 }
                $p = ($p + (substr($b, $s) =~ tr/"//)) % 2; $off += $n }
            push @cuts, $cut if defined $cut && $cut < $size && (!@cuts || $cut > $cuts[-1]);
        }
        print "$_\n" for @cuts;' "$1" "$2"
}
# the bytes [LO, HI) of a file, byte-exact (dd seeks by block only)
byte_range() {
    perl -e 'my ($f, $lo, $hi) = @ARGV; open(my $h, "<", $f) or die "$f: $!"; binmode $h; binmode STDOUT;
        seek($h, $lo, 0); my $left = $hi - $lo;
        while ($left > 0) { my $n = read($h, my $b, $left < 4194304 ? $left : 4194304); last unless $n; print $b; $left -= $n }' "$1" "$2" "$3"
}
tok_part() {   # $1 = input csv, $2 = lo, $3 = hi, $4 = chunk id
    # a part after the first gets a stand-in header line for TOK_PROG to skip
    { if [ "$2" -gt 0 ]; then printf 'x\n'; fi; byte_range "$1" "$2" "$3"; } | tok_run "$4"
}
tokenize_batch() {   # tokenize every argument file into its own chunk
    local f prev=$TOK_TOTAL base=$CHUNK_N idx sz tot=0 thr k lo j c cid
    mkdir -p "$CHUNK_DIR"
    # the fair share: a file above total/NJOBS (never below 64 MB) is split —
    # AXWAY_TOK_SPLIT (bytes) overrides the share, for testing the split path
    for f in "$@"; do sz=$(wc -c < "$f" | tr -d ' '); tot=$((tot + sz)); done
    thr=$(( tot / NJOBS )); [ "$thr" -lt 67108864 ] && thr=67108864
    [ -n "${AXWAY_TOK_SPLIT:-}" ] && thr=$AXWAY_TOK_SPLIT
    # biggest file first (see lpt_order); the index follows argument order
    while IFS=$'\t' read -r idx f; do
        cid=$(printf '%04d' "$((base + idx))")
        sz=$(wc -c < "$f" | tr -d ' ')
        if [ "$sz" -gt "$thr" ]; then
            k=$(( (sz + thr - 1) / thr )); lo=0; j=0
            for c in $(csv_cuts "$f" "$k") "$sz"; do
                j=$((j + 1)); pool_run tok_part "$f" "$lo" "$c" "$cid.$j"; lo=$c
            done
        else
            pool_run tok_one "$f" "$cid"
        fi
    done < <(lpt_order "$@")
    CHUNK_N=$((base + $#))
    pool_wait
    # THE PART TIMINGS (2026-09-27, speed round 8): start, tokenizer-awk end
    # and part end per part — is the tokenize one slow part, the awk or the
    # sort + split behind it? (a runtime build is profiled from its console)
    cat "$CHUNK_DIR"/ttime.* 2>/dev/null | awk '{ n++; a = $2 - $1; t = $3 - $1; sa += a; st += t; if (t > mt) { mt = t; ma = a } }
        END { if (n) printf "TIME %5ds  server parse: tokenize, slowest of %d parts (its awk %ds; all parts: awk %ds + sort/split %ds)\n", mt, n, ma, sa, st - sa }' >&2
    # the PATH COUNTERS (see TOK_PROG): records and MB per tokenizer path — a
    # TIME line (0s) because a background step replays only those at its wait
    cat "$CHUNK_DIR"/pstat.* 2>/dev/null | awk '{ for (i = 1; i <= 12; i++) s[i] += $i }
        END { if (NR) printf "TIME %5ds  server parse: tokenizer paths — %d records (%.0f MB): fast split %d (%.0f MB), walk %d (%.0f MB; per-character %d + %d), multi-line %d (%.0f MB); dropped ADMIN/AUDIT %d, noise %d\n", 0, s[1], s[2] / 1048576, s[5], s[6] / 1048576, s[7], s[8] / 1048576, s[9], s[10], s[3], s[4] / 1048576, s[11], s[12] }' >&2
    rm -f "$CHUNK_DIR"/pstat.*
    rm -f "$CHUNK_DIR"/ttime.* "$CHUNK_DIR"/tend.*
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
# survivors, byte-identical cache. The sort key leads with the ISO date +
# time, so the cache comes out CHRONOLOGICAL (see the tokenizer's sort key).
{
    tokenize_batch "${files[@]}"
    _slap "tokenize (per file)"
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
    # GROUPED DATE-HOUR MERGE (2026-09-27, build-speed round 3): the parts are
    # per date-HOUR now (tok_run), and consecutive keys are packed into ~3
    # groups per core by size. A group merges its keys one after another into
    # ONE stream (the skip filter is a stateless per-row test), so its output
    # is still a contiguous run of cache rows in key order. Per date, the
    # heaviest production day (3 GB of one export) was one merge job alone.
    # NO cut(1) (2026-09-27, build-speed round 6): the skip filter strips the
    # sort key itself (MERGE_SKIP_PROG) — macOS cut runs at ~150 MB/s, and
    # every cache byte went through it twice over (key + columns, ~6 GB in
    # production): 7.9 CPU-s against 1.1 per 800 MB, same bytes out.
    # (| cat: awk writes a regular file in 4 KB chunks — the parallel groups
    # spent more kernel time on that than the merge itself; 2026-09-28)
    merge_group() {   # $1 = 4-digit group index; its keys, in key order, in .grp.$1
        : > "$PART_DIR/out.$1"; : > "$PART_DIR/skip.$1"
        { while IFS= read -r k; do
              LC_ALL=C sort -m -u $SORT_CHUNK_FLAGS "$CHUNK_DIR"/chunk.*.d"$k"
          done < "$CHUNK_DIR/.grp.$1"; } \
            | awk -F'\t' -v skipfile="$SKIPFILE" -v sc="$PART_DIR/skip.$1" -v cf="$PART_DIR/n.$1" "$MERGE_SKIP_PROG" | cat > "$PART_DIR/out.$1"
    }
    # key <TAB> bytes, in key order (LC_ALL=C — the order the keys sort in the
    # cache; "" = the no-date part, first), then the greedy grouping. The
    # group INDEX follows key order: `cat out.*` below is what puts the cache
    # in order, and the reason this merge is byte-identical to one global
    # merge. Only the DISPATCH order is biggest-first.
    : > "$CHUNK_DIR/.lpt"   # no records at all = no groups (the dispatch below reads nothing)
    find "$CHUNK_DIR" -maxdepth 1 -name 'chunk.*' -exec wc -c {} + \
        | awk '$2 != "total" { k = $2; sub(/^.*\/chunk\.[0-9.]*\.d/, "", k); s[k] += $1 }
               END { for (k in s) printf "%s\t%d\n", k, s[k] }' \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1 \
        | awk -F'\t' -v nj="$NJOBS" -v dir="$CHUNK_DIR" '
            { K[++n] = $1; B[n] = $2; tot += $2 }
            END { tgt = tot / (nj * 3); g = 0; cum = 0
                for (i = 1; i <= n; i++) {
                    if (g == 0 || (cum > 0 && cum + B[i] > tgt)) { g++; cum = 0 }
                    cum += B[i]; gs[g] += B[i]
                    printf "%s\n", K[i] > (dir "/.grp." sprintf("%04d", g)) }
                for (i = 1; i <= g; i++) printf "%d\t%04d\n", gs[i], i > (dir "/.lpt") }'
    while IFS=$'\t' read -r _ gi; do
        pool_run merge_group "$gi"
    done < <(LC_ALL=C sort -k1,1rn -k2,2n "$CHUNK_DIR/.lpt")
    pool_wait
    rm -f "$CHUNK_DIR/.lpt" "$CHUNK_DIR"/.grp.*
    cat "$PART_DIR"/out.*  > "$OUT"
    cat "$PART_DIR"/skip.* > "$SKIPOUT"
    ENT_PARTS=("$PART_DIR"/out.*)   # build_entity_tsvs consumes these in place
    skipped_n=$(wc -l < "$SKIPOUT" | tr -d ' ')
    n_out=$(cat "$PART_DIR"/n.* 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')   # the groups' kept-row counts
    # the ROW COUNT beside the cache (2026-09-29): written AFTER it, so its
    # mtime is never older — bin/build.sh reads it for the build report instead
    # of re-counting the multi-GB cache (and falls back to counting when the
    # cache is newer). The merge counted the kept rows; no second pass.
    printf '%s\n' "$n_out" > "$COUNTF"
    dropped=$(( n_raw - n_out - skipped_n ))
    [ "$dropped" -gt 0 ] && echo "NOTE: dropped $dropped exact-duplicate raw record(s) (kept one of each)." >&2
    [ "$skipped_n" -gt 0 ] && echo "Skip list: set aside $skipped_n server record(s) -> $SKIPOUT." >&2
}
_slap "merge (per date)"

# Companion legend: the column names of _parse.tsv (kept in sync with the emit
# order above). Rewritten each run; content only changes if the columns do.
cat > "$LEGEND" <<'LEGEND_EOF'
_parse.tsv — one row per Axway server-log record, TAB-separated, in
CHRONOLOGICAL order (sorted on date + time; the exports themselves are
newest-first within a file). _parse.count holds the row count.

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

echo "Wrote $OUT ($n_out record(s)) and $LEGEND." >&2

build_entity_tsvs         # derive _subscriptions.tsv + the per-name rings from the fresh cache
_slap "per-entity mention caches"
# the merge parts served as the entity-scan chunks
rm -rf "$CHUNK_DIR"
