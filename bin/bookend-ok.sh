#!/usr/bin/env bash
#
# bookend-ok.sh — the "settled by bookend" build step (stage 1, right after
# bin/expire-files.sh; before bin/build/seen-in-server-log.sh / bin/build/
# result.sh): flip a FAILED file (_files.tsv outcome col 2) to "Processed"
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
#               "direction":"Outbound" names the File's CoreId ("coreId")
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
# the same way next run. The rewrite is cmp-guarded. The expensive part —
# the server cache scan — is cached in _bookends.tsv (the ok bookends) and
# _reasonlines.tsv (the classifying E/W lines with their session + ids),
# both re-extracted only when the server cache or this script is newer.
#
# Usage:  bin/bookend-ok.sh      (env from $AXWAY_ENV, default production)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT/bin/fastawk.sh"   # route unqualified `awk` to mawk when installed
source "$ROOT/bin/env.sh"       # resolve $AXWAY_ENV (acceptance|production, default production)

DATA="$ROOT/data/$AXWAY_ENV"
FILES="$DATA/transfer/cache/_files.tsv"
TRANSFERS="$DATA/transfer/cache/_transfers.tsv"
SRV="$DATA/server/cache/_parse.tsv"
BK="$DATA/transfer/cache/_bookends.tsv"      # ok Outbound bookends: coreid \t transferid \t date \t time
RL="$DATA/transfer/cache/_reasonlines.tsv"   # classifying E/W lines: date \t time \t session \t uuids \t reason
OKF="$DATA/transfer/cache/_bookendok.tsv"    # the settled rows: coreid \t transferid \t stamp (transparency)
CLS="$ROOT/bin/flip-reason.awk"

if [ ! -s "$FILES" ] || [ ! -s "$TRANSFERS" ]; then
    echo "bookend-ok: no transfer cache ($FILES) — nothing to settle." >&2
    exit 0
fi
if [ ! -s "$SRV" ]; then
    echo "bookend-ok: no server cache ($SRV) — cannot see the transfer bookends; leaving Failed as-is." >&2
    exit 0
fi

# ---- 1. the two extracts (cached: the server cache scan is the slow part) --
# -f, not -s: an EMPTY extract is a valid cached answer (an env whose server
# log holds no bookend), like expire-files' deletion list.
if [ ! -f "$BK" ] || [ ! -f "$RL" ] || [ "$SRV" -nt "$BK" ] || [ "${BASH_SOURCE[0]}" -nt "$BK" ] || [ "$CLS" -nt "$RL" ]; then
    btmp="$BK.tmp.$$"; rtmp="$RL.tmp.$$"
    awk -F'\t' -v BOUT="$btmp" -v ROUT="$rtmp" "$(cat "$CLS")"'
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
        index($5, "{\"message\":\"Transfer end logged.\"") == 1 {
            if (jval($5, "status") == "ok" && jval($5, "direction") == "Outbound") {
                c = jval($5, "coreId"); if (c != "") printf "%s\t%s\t%s\t%s\n", c, jval($5, "transferId"), $1, $2 > BOUT
            }
            next
        }
        ($3 == "E" || $3 == "W") {
            r = flip_reason($5); if (r == "") next
            ids = ""; s = $5
            while (match(s, UUID)) { ids = ids (ids == "" ? "" : " ") substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
            printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $6, ids, r > ROUT
        }
    ' "$SRV"
    : >> "$btmp"; : >> "$rtmp"
    LC_ALL=C sort -u -o "$btmp" "$btmp"; LC_ALL=C sort -u -o "$rtmp" "$rtmp"
    if cmp -s "$btmp" "$BK" 2>/dev/null; then rm -f "$btmp"; else mv "$btmp" "$BK"; fi   # keep the mtime when unchanged
    if cmp -s "$rtmp" "$RL" 2>/dev/null; then rm -f "$rtmp"; else mv "$rtmp" "$RL"; fi
    echo "bookend-ok: extracted $(wc -l < "$BK" | tr -d ' ') ok bookend(s) and $(wc -l < "$RL" | tr -d ' ') classifying error/warning line(s) from the server cache." >&2
fi

# ---- 2. settle the Failed rows (and re-check the settled ones) -------------
ftmp="$FILES.tmp.$$"; otmp="$OKF.tmp.$$"
awk -F'\t' -v OFS='\t' -v OKOUT="$otmp" '
    FILENAME ~ /_bookends\.tsv$/ { if (!($1 in bk) || ($3 " " $4) > bkstamp[$1]) { bk[$1] = $2; bkstamp[$1] = $3 " " $4 } ; next }
    FILENAME ~ /_reasonlines\.tsv$/ {
        if ($3 != "") rsess[$3] = 1
        n = split($4, U, " "); for (i = 1; i <= n; i++) rid[U[i]] = 1
        next
    }
    FILENAME ~ /_transfers\.tsv$/ {
        # the legs of every CoreId: its sessions and transfer ids (only the
        # CoreIds a bookend names matter — the rest cannot flip)
        if (!($1 in bk)) next
        if ($24 != "") { if ($24 in rsess) reason[$1] = 1 }
        if ($23 != "" && ($23 in rid)) reason[$1] = 1
        if ($1 in rid) reason[$1] = 1
        next
    }
    {
        if (NF < 22) $22 = ""
        if (NF < 23) $23 = ""
        settled = ($23 != "")
        if ($2 == "Failed" || settled) {
            if (($1 in bk) && !($1 in reason)) {
                if ($2 != "Processed" || $23 != bkstamp[$1]) chg++
                $2 = "Processed"; $23 = bkstamp[$1]; nset++
                printf "%s\t%s\t%s\n", $1, bk[$1], bkstamp[$1] > OKOUT
            } else if (settled) {
                chg++; $2 = "Failed"; $23 = ""; nrev++       # the evidence no longer holds
            }
        }
        print
    }
    END { printf "bookend-ok: %d file(s) settled Processed by an ok bookend, %d reverted (%d row(s) changed).\n", nset+0, nrev+0, chg+0 > "/dev/stderr" }
' "$BK" "$RL" "$TRANSFERS" "$FILES" > "$ftmp"
: >> "$otmp"; LC_ALL=C sort -o "$otmp" "$otmp"
if cmp -s "$otmp" "$OKF" 2>/dev/null; then rm -f "$otmp"; else mv "$otmp" "$OKF"; fi

if cmp -s "$ftmp" "$FILES"; then
    rm -f "$ftmp"
    echo "bookend-ok: _files.tsv already up to date." >&2
else
    mv "$ftmp" "$FILES"
    echo "bookend-ok: rewrote $FILES." >&2
fi
