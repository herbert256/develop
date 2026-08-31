# lib.sh — shared helper for the transfer report scripts. Also the single source
# of truth for every path, so reports just `source ../lib.sh` and use the vars
# below (they no longer hardcode INPUT_DIR/DATA_DIR themselves); parse.sh sources
# it too. Provides:
# Every path below carries the ACTIVE ENVIRONMENT segment ($AXWAY_ENV from
# bin/env.sh — acceptance|production, default acceptance), input/<env>/ip/
# included: the two estates share no partners or endpoints, and a host name in
# that map is the one CONFIGURED FOR THAT ENV.
#   INPUT_DIR       raw log exports        (input/<env>/transfer/*.csv, gitignored)
#   IP_DIR          the env's address<->endpoint map dir (input/<env>/ip/)
#   IP_HOSTS_FILE   the address -> endpoint map (ip<TAB>host): forward DNS over
#                   the configured hosts. See bin/ip.sh (there is no reverse DNS).
#   FM_INPUT_DIR    FlowManager config exports (input/<env>/flow-manager/*.json)
#   CACHE_DIR       tokenized *.tsv caches (data/<env>/transfer/cache/, gitignored)
#   REPORTS_DIR     generated *.rpt files  (data/<env>/transfer/reports/)
#   SERVER_CACHE / SERVER_REPORTS   the server area's cache/reports (cross-area reads)
#   CONFIG_DIR      bin/flow-manager.sh's configured-entity caches (data/<env>/flow-manager/{base,xref}/_*.tsv)
#   UNKNOWN_DIR / BLUE_TSV / ANALYSES_REPORTS   the env's data/ side-outputs
#   PARSED/FILES                 the two transfer caches (in CACHE_DIR)
#   ensure_parsed   (re)build the caches with parse.sh when they are stale
#   ensure_config   (re)build the data/flow-manager caches with bin/flow-manager.sh when stale
#
# The caches are the shared, pre-tokenized form of input/transfer/*.csv produced
# by parse.sh — see parse.sh for the column layout. Reports read them with a
# plain `awk -F'\t'` instead of re-running the CSV tokenizer over 170 MB each.
#
# ensure_parsed rebuilds when a cache is missing, when any input CSV — or any
# data/flow-manager XREF cache (the parse config-fallback inputs) — is newer than
# it, or when parse.sh itself is newer (so editing the parser invalidates the
# cache). Deliberately xref/ only, NOT base/: bin/build/result.sh and
# bin/build/seen-in-server-log.sh rewrite base/*.tsv AFTER the parse (build steps —
# they only recolor the result column, which the parse never reads), and
# watching base/ made the first report after them re-derive the whole cache
# for nothing (the fresh-build double derive). A REAL config change re-derives
# via bin/flow-manager.sh, which rewrites the xref tree too — so xref mtimes
# still catch every genuine config change.
# A missing cache always rebuilds, so the check is fail-safe. It refreshes the
# config caches first (ensure_config), so an updated config export flows
# export -> data/flow-manager -> reparse in one call.

# All paths resolve from THIS file's location (not the caller's SCRIPT_DIR), so
# ensure_parsed/skip_if_fresh and the report .rpt writes work from either
# directory. lib.sh + parse.sh sit in <area>/bin/; the report scripts that
# source this sit one level down in <area>/bin/reports/. data/ and input/ are
# the two gitignored roots at the repo top.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # <area>/bin
ROOT="$(cd "$LIB_DIR/../.." && pwd)"                          # repo root
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
SERVER_CACHE="$DATA/server/cache"; SERVER_REPORTS="$DATA/server/reports"   # cross-area (entity-search/showseen/details)
CONFIG_DIR="$DATA/flow-manager"          # bin/flow-manager.sh's caches of the config exports
CONFIG_BASE="$CONFIG_DIR/base"          # the 9 entity lists, each "name<TAB>direction" (in/both/out; empty = unclassifiable)
CONFIG_XREF="$CONFIG_DIR/xref"          # every cross-reference pair BOTH ways (_<a>-<b>.tsv + _<b>-<a>.tsv) + the patterns map
UNKNOWN_DIR="$DATA/unknown"             # the server unknown-* sidecars (blue seed lists)
BLUE_TSV="$DATA/seen-in-server-log.tsv"            # bin/build/seen-in-server-log.sh's audit intermediate
ANALYSES_REPORTS="$DATA/analyses/reports"   # the analyses .rpt files (seen-in-server-log reads pda.rpt)
mkdir -p "$CACHE_DIR" "$REPORTS_DIR"

PARSED="$CACHE_DIR/_transfers.tsv"
FILES="$CACHE_DIR/_files.tsv"   # one row per logical transfer (CoreId); built by parse.sh alongside PARSED

# COREIDS_AWK — shared awk helpers for the click-to-expand Failed/Processed
# drill-down. Inject in front of a report's awk program:
#     awk -F'\t' "$COREIDS_AWK"' … main … ' "$file"
# addtop(key, sortkey, disp, coreid) keeps, per key, the 10 most-recent records
# (by sortkey) as "sortkey<US>disp<US>coreid" joined by <US>=\x1f. buildlist(s)
# renders one key's stored value to "disp  coreid,disp  coreid,…" (newest first)
# for a @data:coreids-* cell. Key the accumulation by <ns> SUBSEP <rowkey> SUBSEP
# "P"/"F" so a report's several tables don't collide. Single-quoted so the awk
# string literals (" , ") survive; it references no shell variables.
COREIDS_AWK='
    BEGIN { _US = sprintf("%c", 31) }
    # The cheap REJECT (2026-08): the ring is a \x1f-joined string, so every
    # call used to split and rejoin it — 1.3M times over a full details run,
    # each up to `bnd` elements. A key that cannot enter a FULL ring (not
    # greater than its smallest kept member, tracked in _topn/_topmin) is now
    # dropped before the split. Same ring contents, a fraction of the work:
    # for a busy entity the ring fills early and almost every later file is
    # rejected here.
    function addtop(p, sk, disp, cid,   key,n,a2,i,pos,m,out){ key=sk SUBSEP disp SUBSEP cid
        if ((p in _topn) && _topn[p] >= 10 && key <= _topmin[p]) return
        n=(p in top)?split(top[p],a2,_US):0; pos=n+1
        for(i=1;i<=n;i++) if(key>a2[i]){pos=i;break}
        if(pos>10) return
        for(i=(n<10?n:9);i>=pos;i--) a2[i+1]=a2[i]
        a2[pos]=key; m=(n<10)?n+1:10; out=a2[1]; for(i=2;i<=m;i++) out=out _US a2[i]; top[p]=out
        _topn[p]=m; _topmin[p]=a2[m] }
    function buildlist(s,   cc,m,i,a3,f){ cc=""; m=(s=="")?0:split(s,a3,_US)
        for(i=1;i<=m;i++){split(a3[i],f,SUBSEP); cc=cc (cc?",":"") f[2] "  " f[3]} return cc }
    function orlist(s){ s=buildlist(s); return (s=="")?"-":s }   # "-" sentinel keeps TAB-delimited fields aligned (details.sh writer)
'

# The RENAME MAPS are a staleness input like the xref caches: appending a pair
# changes which logged name a row is attributed to, and parse.sh's parser_sig
# covers them — but only once parse.sh actually RUNS, which is what this test
# decides. A hand-added pair would otherwise sit unapplied until something else
# forced a reparse (2026-08).
ensure_parsed() {
    ensure_config
    local stale=0 manifest="$CACHE_DIR/_transfers.files"
    if [ ! -f "$PARSED" ] \
       || [ ! -f "$FILES" ] \
       || [ "$LIB_DIR/parse.sh" -nt "$PARSED" ] \
       || [ -n "$(find "$CONFIG_XREF" -name '_*.tsv' -newer "$PARSED" 2>/dev/null)" ] \
       || [ -n "$(find "$ROOT/input/$AXWAY_ENV/renames" -name '*.tsv' -newer "$PARSED" 2>/dev/null)" ] \
       || { [ -f "$CACHE_DIR/_sessionsites.tsv" ] && [ "$CACHE_DIR/_sessionsites.tsv" -nt "$PARSED" ]; } \
       || [ -n "$(find "$INPUT_DIR" -name '*.csv' -newer "$PARSED" 2>/dev/null)" ]; then
        stale=1
    elif [ -f "$manifest" ] \
       && [ "$(find "$INPUT_DIR" -maxdepth 1 -name '*.csv' -exec basename {} \; 2>/dev/null | LC_ALL=C sort)" \
            != "$(cut -f1 "$manifest" | LC_ALL=C sort)" ]; then
        # the mtime checks above miss an input restored with an OLDER timestamp
        # (cp -p / rsync -a / tar) or one removed since the last parse — the
        # input basename set no longer matches parse.sh's manifest, so reparse.
        stale=1
    fi
    # NB: an `if`, not `[ "$stale" = 1 ] && parse.sh` — the latter is the LAST
    # command, so when the cache is fresh (stale=0) it returns 1, and this
    # function called bare under `set -e` would abort every caller (reports,
    # reports.sh, build.sh) on an up-to-date cache. Keep parse.sh failures
    # propagating (they fall through the if), but return 0 when nothing to do.
    if [ "$stale" = 1 ]; then "$LIB_DIR/parse.sh"; fi
}

# ensure_config — (re)build the data/flow-manager/_*.tsv caches with bin/flow-manager.sh.
# flow-manager.sh early-exits when every cache is newer than the exports and itself,
# so calling this every time is a cheap no-op. Everything downstream (the parse
# config fallback, the reports needing configured name lists) reads these
# caches, never the JSON exports. flow-manager.sh needs both exports in input/flow-manager/
# (gitignored, like the log CSVs); with either one absent this keeps whatever
# caches exist instead of failing the caller — a missing cache file reads as an
# empty configured list.
ensure_config() {
    [ -f "$FM_INPUT_DIR/partners.json" ]      || return 0
    [ -f "$FM_INPUT_DIR/subscriptions.json" ] || return 0
    "$ROOT/bin/flow-manager.sh"
}

# skip_if_fresh OUT SCRIPT [DEP...] — exit the calling report early (status 0)
# when its data file OUT is already up to date, i.e. OUT exists and is newer
# than the report SCRIPT, lib.sh, parse.sh, the parse cache and every extra
# DEP file. Regenerates otherwise.
# A DEP that is a DIRECTORY counts as one dep covering the whole tree below it
# (a report reading a whole .rpt/slugmap dir names the dir, not 300 files).
# FILES only — a directory own mtime is noise here: every cmp-guarded writer
# creates and removes a .tmp beside its output, bumping the dir on a run that
# changed nothing.
# Call it right after ensure_parsed so an unchanged report does no awk work.
skip_if_fresh() {
    local out=$1 script=$2; shift 2
    [ -f "$out" ] || return 0                                  # missing -> build
    if [ "$script" -nt "$out" ] \
       || [ "$LIB_DIR/lib.sh" -nt "$out" ] \
       || [ "$LIB_DIR/parse.sh" -nt "$out" ] \
       || { [ -f "$PARSED" ] && [ "$PARSED" -nt "$out" ]; } \
       || { [ -f "$FILES" ] && [ "$FILES" -nt "$out" ]; }; then  # bin/build/seen-in-server-log.sh can rewrite $FILES/$PARSED together or $FILES alone
        return 0                                               # stale -> build
    fi
    local dep
    for dep in "$@"; do
        if [ -d "$dep" ]; then                                 # a whole TREE as one dep
            if [ -n "$(find "$dep" -type f -newer "$out" -print -quit 2>/dev/null)" ]; then
                return 0                                       # something in it is newer -> build
            fi
        elif [ -f "$dep" ] && [ "$dep" -nt "$out" ]; then
            return 0                                           # newer input -> build
        fi
    done
    echo "  $(basename "$out") is up to date; skipping." >&2
    exit 0
}

# activity_stream — a normalized one-record-per-line stream feeding the
# Activity-over-Time reports (day/weekly/hourly/weekday), one line per File
# (a logical transfer per CoreId from _files.tsv, delivered outcome):
#   1 date_iso   2 jdn   3 time (HH:MM:SS.mmm)   4 proc (1 processed / 0 failed)
#   5 size   6 sortkey (YYYYMMDD+time)   7 id (coreid)
# Records with no valid date are dropped.
activity_stream() {
    awk -F'\t' 'BEGIN{OFS="\t"} $4!="" { print $4, $7, $5, ($2!="Failed" && $2!="Expired"?1:0), $8, $6, $1 }' "$FILES"   # proc: Waiting counts as OK, Expired as Error (2026-07 policy)
}
