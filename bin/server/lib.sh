# lib.sh — shared helper for the server report scripts. Also the single source
# of truth for every path, so reports just `source ../lib.sh` and use the vars
# below (they no longer hardcode INPUT_DIR/DATA_DIR themselves); parse.sh sources
# it too. Provides:
# Every path below carries the ACTIVE ENVIRONMENT segment ($AXWAY_ENV from
# bin/env.sh — acceptance|production, default acceptance), input/<env>/ip/
# included: the two estates share no partners or endpoints, and a host name in
# that map is the one CONFIGURED FOR THAT ENV.
#   INPUT_DIR       raw log exports        (input/<env>/server/*.csv, gitignored)
#   IP_DIR          the env's address<->endpoint map dir (input/<env>/ip/)
#   IP_HOSTS_FILE   the address -> endpoint map (ip<TAB>host): forward DNS over
#                   the configured hosts. See bin/ip.sh (there is no reverse DNS).
#   FM_INPUT_DIR    FlowManager config exports (input/<env>/flow-manager/*.json)
#   CACHE_DIR       tokenized *.tsv cache  (data/<env>/server/cache/, gitignored)
#   REPORTS_DIR     generated *.rpt files  (data/<env>/server/reports/)
#   TRANSFER_CACHE / TRANSFER_REPORTS   the transfer area's cache/reports (cross-area reads)
#   CONFIG_DIR      bin/flow-manager.sh's configured-entity caches (data/<env>/flow-manager/{base,xref}/_*.tsv)
#   UNKNOWN_DIR     the unknown-* sidecar seed lists (data/<env>/unknown/)
#   PARSED          path to the tokenized cache (data/<env>/server/cache/_parse.tsv)
#   ensure_parsed   (re)build the cache with parse.sh when it is stale
#   ensure_config   (re)build the data/flow-manager caches with bin/flow-manager.sh when stale
#   skip_if_fresh   exit a report early when its .rpt is already up to date
#
# The cache is the shared, pre-tokenized form of input/server/*.csv produced by
# parse.sh — see parse.sh / _parse.txt for the column layout (time, level,
# component, message). Reports read it with a plain `awk -F'\t'` instead of
# re-running the CSV tokenizer over the multi-GB input each time.
#
# ensure_parsed rebuilds when the cache is missing, when any input CSV is newer
# than it, or when parse.sh itself is newer (so editing the parser invalidates
# the cache). A missing cache always rebuilds, so the check is fail-safe.

# All paths resolve from THIS file's location (not the caller's SCRIPT_DIR), so
# ensure_parsed/skip_if_fresh and the report .rpt writes work from either
# directory. lib.sh + parse.sh sit in <area>/bin/; the report scripts that
# source this sit one level down in <area>/bin/reports/. data/ and input/ are
# the two gitignored roots at the repo top.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # <area>/bin
ROOT="$(cd "$LIB_DIR/../.." && pwd)"                          # repo root
# RENAMES_FILE + RENAMES_AWK (rn_load/rn_canon/rn_canon_pfx): a server report
# that pulls a SUBSCRIPTION NAME out of message text must fold it to the name
# the config uses now — the log keeps whatever was current when it was written.
source "$ROOT/bin/renames.sh"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed (see bin/fastawk.sh)
source "$ROOT/bin/env.sh"       # resolve $AXWAY_ENV (acceptance|production, default acceptance)
AREA="$(basename "$LIB_DIR")"                    # transfer | server (the tool-set dir, bin/<area>)
DATA="$ROOT/data/$AXWAY_ENV"                                  # the env's data root
INPUT_DIR="$ROOT/input/$AXWAY_ENV/$AREA"
IP_DIR="$ROOT/input/$AXWAY_ENV/ip"                            # PER ENV (the two estates share no endpoints)
source "$ROOT/bin/ip.sh"         # IP_HOSTS_FILE (input/<env>/ip/ip-hosts.tsv) + ip_put
FM_INPUT_DIR="$ROOT/input/$AXWAY_ENV/flow-manager"            # the env's FlowManager config exports
# When bin/flow-manager.sh has written SKIP-filtered copies (input/<env>/skip.txt),
# every raw-JSON reader prefers them so the skipped accounts/subscriptions are
# excluded everywhere, not just from the base/xref caches.
[ -f "$DATA/flow-manager/filtered/partners.json" ] && FM_INPUT_DIR="$DATA/flow-manager/filtered"
CACHE_DIR="$DATA/$AREA/cache"
REPORTS_DIR="$DATA/$AREA/reports"
TRANSFER_CACHE="$DATA/transfer/cache"; TRANSFER_REPORTS="$DATA/transfer/reports"   # cross-area (unknown-*, TDATA consumers)
CONFIG_DIR="$DATA/flow-manager"          # bin/flow-manager.sh's caches of the config exports
CONFIG_BASE="$CONFIG_DIR/base"          # the 9 entity lists, each "name<TAB>direction" (in/both/out; empty = unclassifiable)
CONFIG_XREF="$CONFIG_DIR/xref"          # every cross-reference pair BOTH ways (_<a>-<b>.tsv + _<b>-<a>.tsv) + the patterns map
UNKNOWN_DIR="$DATA/unknown"             # the unknown-* reports' sidecar seed lists
mkdir -p "$CACHE_DIR" "$REPORTS_DIR"

PARSED="$CACHE_DIR/_parse.tsv"

# LOGLINES_AWK — shared awk helpers for the click-to-expand "last 10 log lines"
# drill-down (the server twin of transfer lib.sh's COREIDS_AWK). Inject in
# front of a report's awk program:
#     awk -F'\t' "$LOGLINES_AWK"' … main … ' "$PARSED"
# addline(key, sk, msg) keeps, per key, the 10 most-recent messages by the sort
# key sk ("date time" — a bounded insert, NOT arrival order: the exports are
# newest-first within a file, so cache order is not chronological).
# lastlines(key) renders them newest-first as "date time  <msg>" joined with
# <US>=\x1f for a ROW's @data:loglines cell; report.js splits on \x1f (log
# messages contain commas, so the coreid list separator won't do). Call sites
# build msg as lvlname($3) " " compname($4) "  " substr($5, 1, 200) so every
# entry reads "date time  Level Component  message" with the LONG level and
# component names (the cache stores one-letter codes).
LOGLINES_AWK='
    BEGIN { _US = sprintf("%c", 31) }
    function lvlname(x) {
        if (x == "I") return "Info"
        if (x == "W") return "Warning"
        if (x == "E") return "Error"
        return x }
    function compname(x) {
        if (x == "T") return "TM"
        if (x == "P") return "PESITD"
        if (x == "S") return "SSHD"
        return x }
    function addline(p, sk, msg,   key, n, a2, i, pos, m, out) { key = sk SUBSEP msg
        n = (p in ltop) ? split(ltop[p], a2, _US) : 0; pos = n + 1
        for (i = 1; i <= n; i++) if (key > a2[i]) { pos = i; break }
        if (pos > 10) return
        for (i = (n < 10 ? n : 9); i >= pos; i--) a2[i+1] = a2[i]
        a2[pos] = key; m = (n < 10) ? n + 1 : 10
        out = a2[1]; for (i = 2; i <= m; i++) out = out _US a2[i]; ltop[p] = out }
    function lastlines(p,   n, a3, i, f, s) { n = (p in ltop) ? split(ltop[p], a3, _US) : 0
        s = ""; for (i = 1; i <= n; i++) { split(a3[i], f, SUBSEP); s = s (s == "" ? "" : _US) f[1] "  " f[2] }
        return s }
'

ensure_parsed() {
    local manifest="$CACHE_DIR/_parse.files"
    if [ ! -f "$PARSED" ] \
       || [ "$LIB_DIR/parse.sh" -nt "$PARSED" ] \
       || [ -n "$(find "$INPUT_DIR" -name '*.csv' -newer "$PARSED" 2>/dev/null)" ]; then
        "$LIB_DIR/parse.sh"
    elif [ -f "$manifest" ] \
       && [ "$(find "$INPUT_DIR" -maxdepth 1 -name '*.csv' -exec basename {} \; 2>/dev/null | LC_ALL=C sort)" \
            != "$(cut -f1 "$manifest" | LC_ALL=C sort)" ]; then
        # the mtime check above misses an input restored with an OLDER
        # timestamp (cp -p / rsync -a / tar) or one removed since the last
        # parse — the input basename set no longer matches parse.sh's
        # manifest, so reparse (the transfer lib has the same guard)
        "$LIB_DIR/parse.sh"
    fi
}

# ensure_config — (re)build the data/flow-manager/_*.tsv caches with bin/flow-manager.sh
# (the transfer lib.sh twin). flow-manager.sh early-exits when every cache is newer
# than the exports and itself, so calling this every time is a cheap no-op;
# with either export absent from input/flow-manager/ (gitignored, like the log CSVs)
# it keeps whatever caches exist instead of failing the caller (a missing
# cache file reads as an empty list).
ensure_config() {
    [ -f "$FM_INPUT_DIR/partners.json" ]      || return 0
    [ -f "$FM_INPUT_DIR/subscriptions.json" ] || return 0
    "$ROOT/bin/flow-manager.sh"
}

# skip_if_fresh OUT SCRIPT [DEP...] — exit the calling report early (status 0)
# when its data file OUT is already up to date, i.e. OUT exists and is newer
# than the report SCRIPT, lib.sh, parse.sh, the parse cache and every extra DEP
# file (the unknown-* reports pass their transfer-side known-list source here,
# so refreshed transfer data regenerates them too). Regenerates otherwise.
# A DEP that is a DIRECTORY counts as one dep covering the whole tree below it.
# Call it right after ensure_parsed so an unchanged report does no awk work.
skip_if_fresh() {
    local out=$1 script=$2; shift 2
    [ -f "$out" ] || return 0                                  # missing -> build
    if [ "$script" -nt "$out" ] \
       || [ "$LIB_DIR/lib.sh" -nt "$out" ] \
       || [ "$LIB_DIR/parse.sh" -nt "$out" ] \
       || { [ -f "$PARSED" ] && [ "$PARSED" -nt "$out" ]; }; then
        return 0                                               # stale -> build
    fi
    local dep
    for dep in "$@"; do
        if [ -d "$dep" ]; then                                 # a whole TREE as one dep
            if [ -n "$(find "$dep" -type f -newer "$out" -print -quit 2>/dev/null)" ]; then
                return 0
            fi
        elif [ -f "$dep" ] && [ "$dep" -nt "$out" ]; then
            return 0                                           # newer input -> build
        fi
    done
    echo "  $(basename "$out") is up to date; skipping." >&2
    exit 0
}
