#!/usr/bin/env bash
#
# expire-files.sh — the EXPIRED marking build step (stage 1, right after the
# two parses; before bin/build/seen-in-server-log.sh / bin/build/result.sh): flip every Waiting
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
# Idempotent + self-healing: Waiting and Expired rows are RECOMPUTED from the
# deletion list every run (a transfer parse rebuild resets col 2 to Waiting
# and col 22 to empty; the next run re-marks). The rewrite is cmp-guarded so
# a no-change build does not touch _files.tsv's mtime (which would force every
# transfer report to rebuild). The expensive part — scanning the server parse
# cache — is cached in _expired.tsv (the extracted deletion list) and only
# re-runs when the server cache or this script is newer.
#
# OUTCOME POLICY (2026-07): Expired counts as ERROR on every report (Waiting
# stays OK) — consumers compare Error = ("Failed" || "Expired") — and the
# entity RESULT color matches: bin/build/result.sh colors a subscription red when
# its LAST outcome is Failed OR Expired (a Waiting last file stays green),
# so a dead pickup flow never hides in green.
#
# Usage:  bin/expire-files.sh      (env from $AXWAY_ENV, default production)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed
source "$ROOT/bin/env.sh"       # resolve $AXWAY_ENV (acceptance|production, default production)

DATA="$ROOT/data/$AXWAY_ENV"
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

# ---- 1. the deletion list (cached: the server cache scan is the slow part) --
# -f, not -s: an EMPTY extraction is a valid cached answer ("this env's server
# log holds no File Maintenance deletions"), exactly like the empty reverse-DNS
# cache files. Testing -s made production — whose example data has none — redo
# the scan and re-stamp this file on every build, which dragged the analyses
# publish (it watches the transfer cache) along with it.
if [ ! -f "$DEL" ] || [ "$SRV" -nt "$DEL" ] || [ "${BASH_SOURCE[0]}" -nt "$DEL" ]; then
    dtmp="$DEL.tmp.$$"
    # TM info lines: "File Maintenance for account [X] finished. Deleted files [a, b]."
    # One output row per deleted file: account (@endpoint stripped), basename.
    { LC_ALL=C grep 'File Maintenance for account' "$SRV" || true; } | awk -F'\t' '
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
    if cmp -s "$dtmp" "$DEL" 2>/dev/null; then rm -f "$dtmp"; else mv "$dtmp" "$DEL"; fi   # keep the mtime when unchanged
    echo "expire-files: extracted $(wc -l < "$DEL" | tr -d ' ') deletion entrie(s) from the server cache." >&2
fi

# ---- 2. re-mark the Waiting/Expired rows ------------------------------------
ftmp="$FILES.tmp.$$"
awk -F'\t' -v OFS='\t' '
    FILENAME ~ /_expired\.tsv$/ {
        k = toupper($1) SUBSEP $2
        dd[k] = dd[k] "\037" $3 " " $4          # datetime list per (ACCT,file)
        next
    }
    {
        if (NF < 22) $22 = ""                    # normalize a fresh 21-col parse
        if ($2 == "Waiting" || $2 == "Expired") {
            k = toupper($3) SUBSEP $11; hit = ""
            if (k in dd) {
                n = split(dd[k], a, "\037"); staged = $4 " " $5
                for (i = 2; i <= n; i++)         # a[1] is the empty lead-in
                    if (a[i] >= staged && (hit == "" || a[i] < hit)) hit = a[i]
            }
            if (hit != "") { if ($2 != "Expired" || $22 != hit) chg++; $2 = "Expired"; $22 = hit; ne++ }
            else           { if ($2 != "Waiting" || $22 != "")  chg++; $2 = "Waiting"; $22 = "";  nw++ }
        }
        print
    }
    END { printf "expire-files: %d Expired, %d still Waiting (%d row(s) changed).\n", ne+0, nw+0, chg+0 > "/dev/stderr" }
' "$DEL" "$FILES" > "$ftmp"

if cmp -s "$ftmp" "$FILES"; then
    rm -f "$ftmp"
    echo "expire-files: _files.tsv already up to date." >&2
else
    mv "$ftmp" "$FILES"
    echo "expire-files: rewrote $FILES." >&2
fi
