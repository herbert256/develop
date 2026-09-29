#!/usr/bin/env bash
#
# expire-files.sh — the EXPIRED marking build step (stage 1, right after the
# two parses; before bin/build/result.sh): flip every Waiting
# file (UC2 staged for pickup, never collected — _files.tsv outcome col 2)
# whose staged copy the server's nightly File Maintenance retention sweep
# (~11 days) DELETED to the 4th outcome state "Expired", and set col 22
# ("expired") to the deletion timestamp.
#
# Why: the deletion leaves NO trace in the transfer log — the file's CoreId
# group keeps ending on the Inbound routing staging leg, so without this step
# the file looks Waiting forever although the partner can never collect it.
# The evidence lives only in the server log:
#   ... [I/T] File Maintenance for account [ACCT@endpoint] finished.
#       Deleted files [/path/a.zip, /path/b.xml].
#
# Join rule (validated 2026-07: 2803 of 3394 Waiting files matched, ALL at
# 10-12 days after staging; the unmatched rest were all younger than the
# retention window): account (@endpoint-stripped, case aside) + file basename,
# EARLIEST deletion dated at/after the file's staging start. Only Waiting
# (or previously Expired) rows are touched — a deleted file whose transfer
# was Processed/Failed is ordinary retention cleanup, not an expiry.
#
# Idempotent: Waiting and Expired rows are RECOMPUTED from the deletion list
# every run (the parse writes col 2 Waiting and col 22 empty; this step
# marks). The server parse cache scan writes _expired.tsv (the extracted
# deletion list).
#
# OUTCOME POLICY (2026-07): Expired counts as ERROR on every report (Waiting
# stays OK) — consumers compare Error = ("Failed" || "Expired"). Two COLOURS
# follow from it, and they differ: the FILE colour (_files.tsv col 25) of an
# Expired File is RED (this step sets it; a Waiting one orange), while the
# SUBSCRIPTION result colour (bin/build/result.sh) of a flow whose LAST File
# Expired is ORANGE — a pickup problem, not a failed delivery (2026-08); it
# is red only when server-log evidence after its last transfer says so. A
# Waiting last File keeps the flow green. Either way a dead pickup flow never
# hides in green.
#
# Usage:  bin/expire-files.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed
source "$ROOT/bin/ranges.sh"    # rng_feed / rng_off: the byte-range split of the parallel extraction (2026-09-27)

DATA="$ROOT/data"
FILES="$DATA/transfer/cache/_files.tsv"
SRV="$DATA/server/cache/_parse.tsv"
DEL="$DATA/transfer/cache/_expired.tsv"   # extracted deletions: acct \t file \t date \t time

if [ ! -s "$FILES" ]; then
    echo "expire-files: no transfer cache ($FILES) — nothing to mark." >&2
    exit 0
fi
if [ ! -s "$SRV" ]; then
    echo "expire-files: no server cache ($SRV) — cannot see File Maintenance deletions; leaving Waiting as-is." >&2
    exit 0
fi

# ---- 1. the deletion list (an EMPTY one is valid: this env's server log may
# hold no File Maintenance deletions) -----------------------------------------
{
    dtmp="$DEL.tmp.$$"
    # TM info lines: "File Maintenance for account [X] finished. Deleted files [a, b]."
    # One output row per deleted file: account (@endpoint stripped), basename.
    # The line filter runs IN PARALLEL (2026-09-27): one job per core over its
    # own byte range of the server cache (the jobs compute the same line
    # offsets, so the ranges partition the lines) — the one grep over the 3 GB
    # production cache took ~8 s; the rows are a sort -u set, so order is free
    ENJ=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
    case $ENJ in ""|*[!0-9]*) ENJ=2 ;; esac
    ESZ=$(wc -c < "$SRV" | tr -d ' ')
    ex_part() {   # $1 = part index: its range of line starts is [lo, hi)
        local lo=$(( ($1 - 1) * ESZ / ENJ )) hi
        if [ "$1" -eq "$ENJ" ]; then hi=$((ESZ + 1)); else hi=$(( $1 * ESZ / ENJ )); fi
        rng_feed "$SRV" "$lo" | LC_ALL=C awk -v RLO="$lo" -v RHI="$hi" -v ROFF="$(rng_off "$lo")" '
            { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
            index($0, "File Maintenance for account") > 0' /dev/stdin > "$dtmp.p$1"
    }
    epids=(); eparts=()
    for ((pi = 1; pi <= ENJ; pi++)); do ex_part "$pi" & epids+=("$!"); eparts+=("$dtmp.p$pi"); done
    for p in "${epids[@]}"; do wait "$p"; done
    cat "${eparts[@]}" | awk -F'\t' '
        $5 !~ /finished\. Deleted files \[/ { next }
        {
            acct = $5; sub(/^.*for account \[/, "", acct); sub(/\].*/, "", acct); sub(/@.*/, "", acct)
            fl = $5;   sub(/^.*Deleted files \[/, "", fl); sub(/\]\.?$/, "", fl)
            n = split(fl, a, ", ")
            for (i = 1; i <= n; i++) {
                f = a[i]; sub(/^.*\//, "", f)
                if (f != "") printf "%s\t%s\t%s\t%s\n", acct, f, $1, $2
            }
        }
    ' | LC_ALL=C sort -u > "$dtmp"
    rm -f "${eparts[@]}"
    mv "$dtmp" "$DEL"
    echo "expire-files: extracted $(wc -l < "$DEL" | tr -d ' ') deletion entrie(s) from the server cache." >&2
}

# ---- 2. re-mark the Waiting/Expired rows ------------------------------------
ftmp="$FILES.tmp.$$"
awk -F'\t' -v OFS='\t' '
    FILENAME ~ /_expired\.tsv$/ {
        k = toupper($1) SUBSEP $2
        dd[k] = dd[k] "\037" $3 " " $4          # datetime list per (ACCT,file)
        next
    }
    {   # (parse.sh cfg_join writes all 27 columns, col 22 empty — no row needs padding;
        # col 25 = the File colour: an Expired File is red, a Waiting one orange;
        # cols 26/27 — the failed-leg / resubmitted-leg flags — pass through unchanged)
        if ($2 == "Waiting" || $2 == "Expired") {
            k = toupper($3) SUBSEP $11; hit = ""
            if (k in dd) {
                n = split(dd[k], a, "\037"); staged = $4 " " $5
                for (i = 2; i <= n; i++)         # a[1] is the empty lead-in
                    if (a[i] >= staged && (hit == "" || a[i] < hit)) hit = a[i]
            }
            if (hit != "") { if ($2 != "Expired" || $22 != hit) chg++; $2 = "Expired"; $22 = hit; $25 = "red";    ne++ }
            else           { if ($2 != "Waiting" || $22 != "")  chg++; $2 = "Waiting"; $22 = "";  $25 = "orange"; nw++ }
        }
        print
    }
    END { printf "expire-files: %d Expired, %d still Waiting (%d row(s) changed).\n", ne+0, nw+0, chg+0 > "/dev/stderr" }
' "$DEL" "$FILES" > "$ftmp"

mv "$ftmp" "$FILES"
echo "expire-files: rewrote $FILES." >&2
