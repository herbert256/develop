# lib.sh — shared helper for the transfer report scripts. Also the single source
# of truth for every path, so reports just `source ../lib.sh` and use the vars
# below (they no longer hardcode INPUT_DIR/DATA_DIR themselves); parse.sh sources
# it too. Provides:
# One repo = one environment (2026-09-11): the trees are flat (input/, data/,
# docs/) — no environment segment anywhere; input/ip/ maps the addresses of
# THIS checkout's configured hosts.
#   INPUT_DIR       raw log exports        (input/transfer/*.csv, gitignored)
#   IP_DIR          the address<->endpoint map dir (input/ip/)
#   IP_HOSTS_FILE   the address -> endpoint map (ip<TAB>host): forward DNS over
#                   the configured hosts. See bin/ip.sh (there is no reverse DNS).
#   FM_INPUT_DIR    FlowManager config exports (input/flow-manager/*.json)
#   CACHE_DIR       tokenized *.tsv caches (data/transfer/cache/, gitignored)
#   REPORTS_DIR     generated *.rpt files  (data/transfer/reports/)
#   SERVER_CACHE / SERVER_REPORTS   the server area's cache/reports (cross-area reads)
#   CONFIG_DIR      bin/flow-manager.sh's configured-entity caches (data/flow-manager/{base,xref}/_*.tsv)
#   UNKNOWN_DIR / ANALYSES_REPORTS   the env's data/ side-outputs
#   PARSED/FILES                 the two transfer caches (in CACHE_DIR)
#
# The caches are the shared, pre-tokenized form of input/transfer/*.csv produced
# by parse.sh — see parse.sh for the column layout. Reports read them with a
# plain `awk -F'\t'` instead of re-running the CSV tokenizer over 170 MB each.
# bin/build.sh builds them (and the data/flow-manager config caches) before any
# report runs; a report never parses on its own.
#
# All paths resolve from THIS file's location (not the caller's SCRIPT_DIR), so
# the report .rpt writes work from either directory. lib.sh + parse.sh sit in <area>/bin/; the report scripts that
# source this sit one level down in <area>/bin/reports/. data/ and input/ are
# the two gitignored roots at the repo top.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # <area>/bin
ROOT="$(cd "$LIB_DIR/../.." && pwd)"                          # repo root
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
SERVER_CACHE="$DATA/server/cache"; SERVER_REPORTS="$DATA/server/reports"   # cross-area (entity-search/showseen/details)
CONFIG_DIR="$DATA/flow-manager"          # bin/flow-manager.sh's caches of the config exports
CONFIG_BASE="$CONFIG_DIR/base"          # the 9 entity lists, each "name<TAB>direction" (in/both/out; empty = unclassifiable)
CONFIG_XREF="$CONFIG_DIR/xref"          # every cross-reference pair BOTH ways (_<a>-<b>.tsv + _<b>-<a>.tsv) + the patterns map
UNKNOWN_DIR="$DATA/unknown"             # the server unknown-* sidecars (the server-log sighting lists)
ANALYSES_REPORTS="$DATA/analyses/reports"   # the analyses .rpt files
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
    # (2026-09-28) An OLDER sortkey than the smallest kept one is rejected
    # before the key is even built: the key STARTS with sk, and every sk
    # character sorts above SUBSEP, so sk < that sortkey means key < the
    # smallest key — the same verdict as the full test below, which still
    # decides a tie on the sortkey.
    function addtop(p, sk, disp, cid,   key,n,a2,i,pos,m,out){
        if ((p in _topn) && _topn[p] >= 10 && (sk "") < _topmsk[p]) return
        key=sk SUBSEP disp SUBSEP cid
        if ((p in _topn) && _topn[p] >= 10 && key <= _topmin[p]) return
        n=(p in top)?split(top[p],a2,_US):0; pos=n+1
        for(i=1;i<=n;i++) if(key>a2[i]){pos=i;break}
        if(pos>10) return
        for(i=(n<10?n:9);i>=pos;i--) a2[i+1]=a2[i]
        a2[pos]=key; m=(n<10)?n+1:10; out=a2[1]; for(i=2;i<=m;i++) out=out _US a2[i]; top[p]=out
        _topn[p]=m; _topmin[p]=a2[m]; _topmsk[p]=substr(a2[m], 1, index(a2[m], SUBSEP) - 1) }
    function buildlist(s,   cc,m,i,a3,f){ cc=""; m=(s=="")?0:split(s,a3,_US)
        for(i=1;i<=m;i++){split(a3[i],f,SUBSEP); cc=cc (cc?",":"") f[2] "  " f[3]} return cc }
    function orlist(s){ s=buildlist(s); return (s=="")?"-":s }   # "-" sentinel keeps TAB-delimited fields aligned (details.sh writer)
'

# activity_stream — a normalized one-record-per-line stream feeding the
# Activity-over-Time reports (day/weekly/hourly/weekday), one line per File
# (a logical transfer per CoreId from _files.tsv, delivered outcome):
#   1 date_iso   2 jdn   3 time (HH:MM:SS.mmm)   4 proc (1 processed / 0 failed)
#   5 size   6 sortkey (YYYYMMDD+time)   7 id (coreid)
# Records with no valid date are dropped.
activity_stream() {
    awk -F'\t' 'BEGIN{OFS="\t"} $4!="" { print $4, $7, $5, ($2!="Failed" && $2!="Expired"?1:0), $8, $6, $1 }' "$FILES"   # proc: Waiting counts as OK, Expired as Error (2026-07 policy)
}
