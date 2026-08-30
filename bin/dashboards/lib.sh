#!/usr/bin/env bash
#
# bin/dashboards/lib.sh — shared paths + aggregate helpers for the DASHBOARDS
# tool set: the graphical dashboards derived from the transfer caches and the
# already-computed transfer/server .rpt files (no multi-GB rescan). Sourced by
# the report scripts (and reports.sh); the publish script sources
# bin/publish_lib.sh + bin/dashboards/charts_lib.sh instead. Paths derive from
# this file's own location and the lib cd's to the repo root, so the data/…
# relative paths below resolve from any working directory.
#
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LIB_DIR/../.." && pwd)"
cd "$ROOT"
source "$ROOT/bin/env.sh"        # resolve $AXWAY_ENV (acceptance|production, default acceptance)
source "$ROOT/bin/fastawk.sh"    # route unqualified `awk` to mawk when installed (4-9x faster)
DATA="data/$AXWAY_ENV"           # the env's data root (this lib cd's to the repo root)
REPORTS_DIR="$DATA/dashboards/reports"     # one .rpt (page spec) per dashboard page
mkdir -p "$REPORTS_DIR"

# the sources every aggregate reads
TR="$DATA/transfer/cache/_files.tsv"; RW="$DATA/transfer/cache/_transfers.tsv"
SV="$DATA/server/reports/topview.rpt"; SER="$DATA/server/reports/error-reasons.rpt"

# skip_if_fresh OUT SCRIPT [DEP...] — the dashboards counterpart of the same
# helper in the transfer/server/analyses libs: exit the calling report early
# (status 0) when OUT exists and is newer than the report SCRIPT, this lib and
# every input. The four sources above are watched automatically; a DEP that is
# a DIRECTORY covers the whole tree below it.
skip_if_fresh() {
    local out=$1 script=$2; shift 2
    [ -f "$out" ] || return 0                                  # missing -> build
    if [ "$script" -nt "$out" ] || [ "$LIB_DIR/lib.sh" -nt "$out" ]; then
        return 0                                               # stale -> build
    fi
    local dep
    for dep in "$TR" "$RW" "$SV" "$SER" "$@"; do
        if [ -d "$dep" ]; then
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

humanbytes(){ awk -v b="${1:-0}" 'BEGIN{ s="B KB MB GB TB PB"; n=split(s,u," "); i=1; v=b+0; while(v>=1024&&i<n){v/=1024;i++} printf (i==1)?"%d %s":"%.2f %s", v, u[i] }'; }   # %.2f like every report table
pipejoin(){ awk 'BEGIN{ORS=""}{print (NR>1?"|":"") $0}'; }   # stdin lines -> a|b|c
onlynum(){ grep -oE "$1" "$2" 2>/dev/null | grep -oE '[0-9]+' | head -1; }

# big-number abbreviations — three exact variants (kept apart so the display
# stays byte-identical to the original dashboards)
knum(){       awk -v n="${1:-0}" 'BEGIN{printf (n>=1e3)?"%.1fk":"%d",(n>=1e3)?n/1e3:n}'; }
knum_files(){ awk -v n="${1:-0}" 'BEGIN{printf (n>=1e6)?"%.2fM":(n>=1e3)?"%.1fk":"%d", (n>=1e6)?n/1e6:(n>=1e3)?n/1e3:n}'; }
knum_recs(){  awk -v n="${1:-0}" 'BEGIN{printf (n>=1e6)?"%.1fM":(n>=1e3)?"%.0fk":"%d",(n>=1e6)?n/1e6:(n>=1e3)?n/1e3:n}'; }

# TRANSFER basics (the logical-transfer cache): T_FILES/T_FAIL/T_VOL/T_FPCT/
# T_PROC. Returns 1 (script exits/skips) when the cache is missing.
transfer_basics(){
    [ -f "$TR" ] || return 1
    read -r T_FILES T_FAIL T_VOL < <(awk -F'\t' '{n++; if($2=="Failed"||$2=="Expired")f++; v+=$8} END{print n+0, f+0, v+0}' "$TR")   # Waiting = OK, Expired = Error (2026-07 policy)
    T_FPCT=$(awk -v f="$T_FAIL" -v t="$T_FILES" 'BEGIN{printf "%.1f", t? f*100/t : 0}')
    T_PROC=$(( T_FILES - T_FAIL ))
}

# SERVER basics (the topview report): S_REC/S_INFO/S_WARN/S_ERR/S_EPCT.
server_basics(){
    [ -f "$SV" ] || return 1
    read -r S_REC S_INFO S_WARN S_ERR < <(awk -F'\t' '$1=="ROW"{r+=$3;i+=$5;w+=$6;e+=$7} END{print r+0,i+0,w+0,e+0}' "$SV")
    S_EPCT=$(awk -v e="$S_ERR" -v r="$S_REC" 'BEGIN{printf "%.1f", r? e*100/r : 0}')
}

# per-day Files + Failed series (chronological, from day.rpt) -> tday_lab/tday_fl
tday_series(){
    tday_lab=$(awk -F'\t' '$1=="ROW"{d=$2; sub(/ \(.*/,"",d); print d ":" $3}' "$DATA/transfer/reports/day.rpt" | pipejoin)
    tday_fl=$(awk -F'\t' '$1=="ROW"{d=$2; sub(/ \(.*/,"",d); print d ":" $4}' "$DATA/transfer/reports/day.rpt" | pipejoin)
}

# per-day server records + errors series -> sday_rec/sday_err
sday_series(){
    sday_rec=$(awk -F'\t' '$1=="ROW"{d=$2; sub(/^@\{[^}]*\}/,"",d); print d ":" $3}' "$SV" | pipejoin)
    sday_err=$(awk -F'\t' '$1=="ROW"{d=$2; sub(/^@\{[^}]*\}/,"",d); print d ":" $7}' "$SV" | pipejoin)
}

# top 8 accounts by volume -> tacct (transfer + volume dashboards)
tacct_series(){
    tacct=$(awk -F'\t' '$3!=""{v[$3]+=$8} END{for(a in v)print v[a]"\t"a}' "$TR" | sort -t"$(printf '\t')" -k1,1nr | awk -F'\t' 'NR<=8{print $2":"$1}' | pipejoin)
}
