#!/usr/bin/env bash
#
# bookend-ok.sh — the "settled by bookend" build step (stage 1, right after
# bin/expire-files.sh; before bin/build/result.sh): flip a FAILED file (_files.tsv outcome col 2) to "Processed"
# when the SERVER log's own verdict on its transfer is OK and nothing in the
# server log gives the failure a reason. (2026-09-09, user request.)
#
# Why: SecureTransport can end ONE transfer twice. A partner's SFTP client
# downloads a staged file, tears its connection down instead of closing it,
# reconnects a second later and finishes; the platform then writes a
# "Transfer end logged." JSON record with status "ok" AND one with status
# "error" for the SAME transferId, and the transfer-log export keeps the
# error. The file was delivered (the partner deleted it right after), yet
# the File read Failed. The JSON bookends are the platform's own verdict,
# so they settle it:
#
#   FLIP when   outcome == Failed
#          AND  a "Transfer end logged." JSON line with "status":"ok" and
#               "direction":"Outbound" names the transfer id of the File's
#               LAST leg ("transferId") — the transfer the outcome rests on;
#               an ok bookend of an earlier, successful leg of the same File
#               does not count. The JSON's own "coreId" is NOT required to
#               match: it can differ from the transfer log's CoreId for the
#               same transfer (seen on the runtime), the transfer id is the
#               unambiguous key
#          AND  the LAST leg's own transfer-log status is a FAILURE — the
#               "ended twice" case this step exists for (2026-09-28 fix: a
#               File Failed for a STRUCTURAL reason — its last leg succeeded,
#               but the movement or the leg count says it was not delivered —
#               carries an ok bookend on that successful leg too, and flipped)
#          AND  no reason is found: no Error/Warning line of the File's
#               connections (the legs' session ids, _transfers.tsv col 24)
#               nor one mentioning the CoreId or a leg's transfer id
#               classifies to a reason (bin/flip-reason.awk — the SAME
#               classifier the Failed lists and the home Reason use).
#
# The bookends reach the server cache since 2026-09-09 (they were noise-
# filtered before); the mention scanner still skips them.
#
# Col 23 ("settled") records the ok bookend's stamp on a flipped row and is
# empty otherwise. Idempotent + self-healing like expire-files.sh: every
# run re-evaluates the Failed rows AND the previously settled ones (col 23
# non-empty) from scratch, so a reason line arriving later, or a transfer
# parse rebuild (which resets col 2 to Failed and col 23 to empty), settles
# the same way next run. The server cache scan writes _bookends.tsv (the ok
# bookends) and _reasonlines.tsv (the classifying E/W lines with their
# session + ids).
#
# Usage:  bin/bookend-ok.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed
source "$ROOT/bin/ranges.sh"    # rng_feed / rng_off: the byte-range split of the parallel extraction (2026-09-27)

DATA="$ROOT/data"
FILES="$DATA/transfer/cache/_files.tsv"
TRANSFERS="$DATA/transfer/cache/_transfers.tsv"
SRV="$DATA/server/cache/_parse.tsv"
BK="$DATA/transfer/cache/_bookends.tsv"      # ok Outbound bookends: coreid \t transferid \t date \t time
RL="$DATA/transfer/cache/_reasonlines.tsv"   # classifying E/W lines: date \t time \t session \t uuids \t reason
# (the _bookendok.tsv list of the settled rows went 2026-09-29 — only verify.sh
# read it; the settled stamp is _files.tsv col 23)
CLS="$ROOT/bin/flip-reason.awk"

if [ ! -s "$FILES" ] || [ ! -s "$TRANSFERS" ]; then
    echo "bookend-ok: no transfer cache ($FILES) — nothing to settle." >&2
    exit 0
fi
if [ ! -s "$SRV" ]; then
    echo "bookend-ok: no server cache ($SRV) — cannot see the transfer bookends; leaving Failed as-is." >&2
    exit 0
fi

# ---- 1. the two extracts (an EMPTY one is valid: an env whose server log
# holds no bookend) -----------------------------------------------------------
{
    btmp="$BK.tmp.$$"; rtmp="$RL.tmp.$$"
    # IN PARALLEL (2026-09-27): one job per core over its own byte range of the
    # server cache (the jobs compute the same line offsets, so the ranges
    # partition the lines); both extracts are sort -u sets, so the parts
    # concatenate into the same files (the one pass was ~15 s on production).
    NJ=$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 2 )
    case $NJ in ""|*[!0-9]*) NJ=2 ;; esac
    SRVSZ=$(wc -c < "$SRV" | tr -d " ")
    bk_part() {   # $1 = part index: its range of line starts is [lo, hi)
    local lo=$(( ($1 - 1) * SRVSZ / NJ )) hi
    if [ "$1" -eq "$NJ" ]; then hi=$((SRVSZ + 1)); else hi=$(( $1 * SRVSZ / NJ )); fi
    : > "$btmp.p$1"; : > "$rtmp.p$1"
    rng_feed "$SRV" "$lo" | awk -F'\t' -v BOUT="$btmp.p$1" -v ROUT="$rtmp.p$1" -v RANGEF=/dev/stdin -v RLO="$lo" -v RHI="$hi" -v ROFF="$(rng_off "$lo")" "$(cat "$CLS")"'
        BEGIN { H4 = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"; UUID = H4 H4 "-" H4 "-" H4 "-" H4 "-" H4 H4 H4 }
        # the JSON value of key k in message m ("" when absent); the tokenizer
        # flattened the multi-line record to one line and unquoted the CSV
        # doubling, so the field reads "k":"v" with optional blanks around
        function jval(m, k,   p, s) {
            p = index(m, "\"" k "\""); if (p == 0) return ""
            s = substr(m, p + length(k) + 2); sub(/^[ \t]*:[ \t]*"/, "", s)
            if (substr(s, 1, 1) == "\"" ) return ""      # not a string value
            sub(/".*$/, "", s); return s
        }
        FILENAME == RANGEF { if (!_rs) { _rs = 1; _off = ROFF + 0 } _lo = _off; _off += length($0) + 1; if (_lo < RLO + 0) next; if (_lo >= RHI + 0) exit }
        index($5, "{\"message\":\"Transfer end logged.\"") == 1 {
            if (jval($5, "status") == "ok" && jval($5, "direction") == "Outbound") {
                t = jval($5, "transferId"); if (t != "") printf "%s\t%s\t%s\t%s\n", jval($5, "coreId"), t, $1, $2 > BOUT
            }
            next
        }
        ($3 == "E" || $3 == "W") {
            r = flip_reason($5); if (r == "") next
            ids = ""; s = $5
            while (match(s, UUID)) { ids = ids (ids == "" ? "" : " ") substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
            printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $6, ids, r > ROUT
        }
    ' /dev/stdin
    }
    pids=()
    for ((pi = 1; pi <= NJ; pi++)); do bk_part "$pi" & pids+=("$!"); done
    for p in "${pids[@]}"; do wait "$p"; done
    cat "$btmp".p* > "$btmp"; cat "$rtmp".p* > "$rtmp"; rm -f "$btmp".p* "$rtmp".p*
    LC_ALL=C sort -u -o "$btmp" "$btmp"; LC_ALL=C sort -u -o "$rtmp" "$rtmp"
    mv "$btmp" "$BK"; mv "$rtmp" "$RL"
    echo "bookend-ok: extracted $(wc -l < "$BK" | tr -d ' ') ok bookend(s) and $(wc -l < "$RL" | tr -d ' ') classifying error/warning line(s) from the server cache." >&2
}

# ---- 2. settle the Failed rows (and re-check the settled ones) -------------
ftmp="$FILES.tmp.$$"
awk -F'\t' -v OFS='\t' '
    # the ok bookends, keyed by TRANSFER ID: the ok must belong to THE
    # transfer the outcome rests on — the LAST leg of the CoreId — not to an
    # earlier, successful leg of the same File (one acceptance File had ok
    # bookends on two earlier legs and a later "Failed Subtransmission" leg
    # with none: that one stays Failed). The transfer id alone is the key:
    # the coreId the JSON carries can DIFFER from the CoreId the transfer log
    # gives the same transfer (seen on the runtime — a torn-down collect the
    # bookend booked under another CoreId), and the transfer id is the finer,
    # unambiguous one.
    FILENAME ~ /_bookends\.tsv$/ { if ($2 != "" && (!($2 in bkt) || ($3 " " $4) > bkt[$2])) bkt[$2] = $3 " " $4; next }
    FILENAME ~ /_reasonlines\.tsv$/ {
        if ($3 != "") rsess[$3] = 1
        n = split($4, U, " "); for (i = 1; i <= n; i++) rid[U[i]] = 1
        next
    }
    FILENAME ~ /_transfers\.tsv$/ {
        # per CoreId: whether any leg is one an ok bookend names (cand — a
        # superset of the ones that can flip, since the LAST leg must be that
        # leg), the reason test over its sessions and transfer ids, and its
        # LAST leg by sort key (col 13). Kept for every CoreId in one pass —
        # a few arrays over the CoreId count, cheaper than a second read of
        # the biggest cache.
        if ($23 != "" && ($23 in bkt)) cand[$1] = 1
        if (!($1 in lastsk) || $13 >= lastsk[$1]) { lastsk[$1] = $13; lasttid[$1] = $23; lastst[$1] = $3 }
        if ($24 != "" && ($24 in rsess)) reason[$1] = 1
        if ($23 != "" && ($23 in rid)) reason[$1] = 1
        if ($1 in rid) reason[$1] = 1
        next
    }
    {
        if (NF < 22) $22 = ""
        if (NF < 23) $23 = ""
        settled = ($23 != "")
        if ($2 == "Failed" || settled) {
            t = lasttid[$1]
            if (($1 in cand) && t != "" && (t in bkt) && !($1 in reason) && lastst[$1] ~ /^Failed/ && $10 + 0 >= 2) {   # >= 2 legs: a lone leg is Failed for its LEG COUNT (parse forces its status Failed) — never settled (2026-09-29)
                if ($2 != "Processed" || $23 != bkt[t]) chg++
                $2 = "Processed"; $23 = bkt[t]; $25 = "orange"; nset++   # col 25: OK after a failed leg (the colour rule); col 26 stays "1" — it HAD a failed leg (a Recovered File, Automatic unless col 27)
            } else if (settled) {
                chg++; $2 = "Failed"; $23 = ""; $25 = "red"; nrev++       # the evidence no longer holds
            }
        }
        print
    }
    END { printf "bookend-ok: %d file(s) settled Processed by an ok bookend, %d reverted (%d row(s) changed).\n", nset+0, nrev+0, chg+0 > "/dev/stderr" }
' "$BK" "$RL" "$TRANSFERS" "$FILES" > "$ftmp"
mv "$ftmp" "$FILES"
echo "bookend-ok: rewrote $FILES." >&2
