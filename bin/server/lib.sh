# lib.sh — shared helper for the server report scripts. Also the single source
# of truth for every path, so reports just `source ../lib.sh` and use the vars
# below (they no longer hardcode INPUT_DIR/DATA_DIR themselves); parse.sh sources
# it too. Provides:
# One repo = one environment (2026-09-11): the trees are flat (input/, data/,
# docs/) — no environment segment anywhere; input/ip/ maps the addresses of
# THIS checkout's configured hosts.
#   INPUT_DIR       raw log exports        (input/server/*.csv, gitignored)
#   IP_DIR          the address<->endpoint map dir (input/ip/)
#   IP_HOSTS_FILE   the address -> endpoint map (ip<TAB>host): forward DNS over
#                   the configured hosts. See bin/ip.sh (there is no reverse DNS).
#   FM_INPUT_DIR    FlowManager config exports (input/flow-manager/*.json)
#   CACHE_DIR       tokenized *.tsv cache  (data/server/cache/, gitignored)
#   REPORTS_DIR     generated *.rpt files  (data/server/reports/)
#   TRANSFER_CACHE / TRANSFER_REPORTS   the transfer area's cache/reports (cross-area reads)
#   CONFIG_DIR      bin/flow-manager.sh's configured-entity caches (data/flow-manager/{base,xref}/_*.tsv)
#   UNKNOWN_DIR     the unknown-* sidecar seed lists (data/unknown/)
#   PARSED          path to the tokenized cache (data/server/cache/_parse.tsv)
#
# The cache is the shared, pre-tokenized form of input/server/*.csv produced by
# parse.sh — see parse.sh / _parse.txt for the column layout (date, time,
# level, component, message, session); its rows are in chronological order. Reports read it with a plain `awk -F'\t'` instead of
# re-running the CSV tokenizer over the multi-GB input each time. bin/build.sh
# builds it (and the data/flow-manager config caches) before any report runs;
# a report never parses on its own.

# All paths resolve from THIS file's location (not the caller's SCRIPT_DIR), so
# the report .rpt writes work from either directory. lib.sh + parse.sh sit in <area>/bin/; the report scripts that
# source this sit one level down in <area>/bin/reports/. data/ and input/ are
# the two gitignored roots at the repo top.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # <area>/bin
ROOT="$(cd "$LIB_DIR/../.." && pwd)"                          # repo root
# RENAMES_FILE + RENAMES_AWK (rn_load/rn_canon/rn_canon_pfx): a server report
# that pulls a SUBSCRIPTION NAME out of message text must fold it to the name
# the config uses now — the log keeps whatever was current when it was written.
source "$ROOT/bin/renames.sh"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed (see bin/fastawk.sh)
AREA="$(basename "$LIB_DIR")"                    # transfer | server (the tool-set dir, bin/<area>)
DATA="$ROOT/data"
INPUT_DIR="$ROOT/input/$AREA"
IP_DIR="$ROOT/input/ip"
source "$ROOT/bin/ip.sh"         # IP_HOSTS_FILE (input/ip/ip-hosts.tsv) + ip_put
FM_INPUT_DIR="$ROOT/input/flow-manager"
# When bin/flow-manager.sh has written SKIP-filtered copies (input/skip.txt),
# every raw-JSON reader prefers them so the skipped accounts/subscriptions are
# excluded everywhere, not just from the base/xref caches.
[ -f "$DATA/flow-manager/filtered/partners.json" ] && FM_INPUT_DIR="$DATA/flow-manager/filtered"
CACHE_DIR="$DATA/$AREA/cache"
REPORTS_DIR="$DATA/$AREA/reports"
TRANSFER_CACHE="$DATA/transfer/cache"; TRANSFER_REPORTS="$DATA/transfer/reports"   # cross-area (unknown-*, TDATA consumers)
CONFIG_DIR="$DATA/flow-manager"          # bin/flow-manager.sh's caches of the config exports
CONFIG_BASE="$CONFIG_DIR/base"          # the entity lists (_<entity>.tsv), each "name<TAB>direction<TAB>result" (direction in/both/out, empty = unclassifiable; result green/red/orange, bin/build/result.sh)
CONFIG_XREF="$CONFIG_DIR/xref"          # every cross-reference pair BOTH ways (_<a>-<b>.tsv + _<b>-<a>.tsv) + the patterns map
UNKNOWN_DIR="$DATA/unknown"             # the unknown-* reports' sidecar seed lists
mkdir -p "$CACHE_DIR" "$REPORTS_DIR"

PARSED="$CACHE_DIR/_parse.tsv"

# LOGLINES_AWK — shared awk helpers for the click-to-expand "last 10 log lines"
# drill-down (the server twin of transfer lib.sh's COREIDS_AWK). Inject in
# front of a report's awk program:
#     awk -F'\t' "$LOGLINES_AWK"' … main … ' "$PARSED"
# addline(key, sk, msg) keeps, per key, the 10 most-recent messages by the sort
# key sk ("date time" — a bounded insert by the key, never arrival order: the
# cache is chronological, but a report may feed a subset or several inputs).
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
    # addline keeps the 10 greatest keys (sk SUBSEP msg) of p, newest first;
    # a key equal to one kept goes after it. A 10-slot ring per p: element
    # i of the list is slot (_LLh[p] + i - 1) % 10 (2026-09-27: the cache is
    # chronological, so nearly every call puts a new FIRST element — O(1)
    # here, where the former joined string was split, shifted and re-joined
    # on every call; the rare middle insert still does exactly that)
    function addline(p, sk, msg,   key, n, h, a2, i, pos, m) { key = sk SUBSEP msg
        n = _LLn[p] + 0
        if (n == 0) { _LLn[p] = 1; _LLh[p] = 0; _LLr[p, 0] = key; _LLf[p] = key; _LLl[p] = key; return }
        h = _LLh[p]
        if (key > _LLf[p]) {                                  # a new first element
            h = (h + 9) % 10; _LLh[p] = h; _LLr[p, h] = key; _LLf[p] = key
            if (n < 10) _LLn[p] = n + 1
            else _LLl[p] = _LLr[p, (h + 9) % 10]
            return
        }
        if (!(key > _LLl[p])) {                               # at or below the last
            if (n == 10) return
            _LLr[p, (h + n) % 10] = key; _LLn[p] = n + 1; _LLl[p] = key
            return
        }
        for (i = 1; i <= n; i++) a2[i] = _LLr[p, (h + i - 1) % 10]
        pos = n + 1
        for (i = 1; i <= n; i++) if (key > a2[i]) { pos = i; break }
        for (i = (n < 10 ? n : 9); i >= pos; i--) a2[i+1] = a2[i]
        a2[pos] = key; m = (n < 10) ? n + 1 : 10
        for (i = 1; i <= m; i++) _LLr[p, i - 1] = a2[i]
        _LLh[p] = 0; _LLn[p] = m; _LLf[p] = a2[1]; _LLl[p] = a2[m] }
    # the kept keys of p, first to last, _US-joined ("" when none)
    function loglist(p,   n, h, i, out) { n = _LLn[p] + 0; h = _LLh[p] + 0
        out = ""; for (i = 1; i <= n; i++) out = out (i > 1 ? _US : "") _LLr[p, (h + i - 1) % 10]
        return out }
    function lastlines(p,   n, a3, i, f, s) { n = (p in _LLn) ? split(loglist(p), a3, _US) : 0
        s = ""; for (i = 1; i <= n; i++) { split(a3[i], f, SUBSEP); s = s (s == "" ? "" : _US) f[1] "  " f[2] }
        return s }
'

# srv_subset NAME — the path a server-cache CONSUMER reads: its subset of the
# cache (bin/server/subsets.sh — only the lines carrying one of its marker
# strings, in cache order) when the subset set is complete, else the whole
# cache.
srv_subset() {
    local d="$CACHE_DIR/subsets"
    if [ -f "$d/$1.tsv" ] && [ -f "$d/.done" ]; then
        printf '%s' "$d/$1.tsv"
    else
        printf '%s' "$PARSED"
    fi
}
