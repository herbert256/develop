#!/usr/bin/env bash
#
# auth-activity.sh — the successful inbound SSH authentications per account, a
# PAGELESS producer since 2026-09-30 (user request: "Remove the 10 Logons &
# connections reports (and the builds for it)" — its By account / By source IP
# tables were the Logons › By account / By source IP tabs). What stays is what
# bin/analyses/reports/entity-coverage.sh reads — its In-side logon proof:
#
#   auth-activity.rpt   ONE table: ROW account (the @endpoint suffix stripped)
#                       <TAB> successful logons — entity-coverage takes ROW
#                       fields 2 / 3 of the FIRST table
#   auth-logins.tsv     account <TAB> login <TAB> successful logons (the
#                       multi-FE accounts: the proof composed per login,
#                       2026-08-31) — sorted, never awk hash order
#
# Every "[Ssh Default] User with login name \"…\", associated with account
# \"…\", successfully authenticated over SSH …" line of the parse cache
# (data/server/cache/_parse.tsv, field 5 = the message) counts once.
#
# Usage:
#   ./auth-activity.sh    # writes data/server/reports/auth-activity.rpt + auth-logins.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/auth-activity.rpt"
AUTHL_OUT="$REPORTS_DIR/auth-logins.tsv"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT" "$AUTHL_OUT"   # no data for this ENV (entity-coverage falls back to no logon proof)
    exit 0
fi

# One pass. Emits AC <TAB> account <TAB> logons, AL <TAB> account <TAB> login
# <TAB> logons, TOT <TAB> logons.
agg=$(awk -F'\t' '
    index($5, "successfully authenticated over SSH") {
        m = $5
        acct = ""; if (match(m, /account "[^"]*"/)) acct = substr(m, RSTART + 9, RLENGTH - 10)
        sub(/@.*$/, "", acct)                      # drop the @FE… endpoint suffix
        if (acct == "") acct = "(blank)"
        lgn = ""; if (match(m, /login name "[^"]*"/)) lgn = substr(m, RSTART + 12, RLENGTH - 13)
        if (lgn != "") al9[acct SUBSEP lgn]++
        tot++; ac[acct]++
    }
    END {
        for (x in ac) printf "AC\t%s\t%d\n", x, ac[x]
        for (x in al9) { split(x, a9, SUBSEP); printf "AL\t%s\t%s\t%d\n", a9[1], a9[2], al9[x] }   # hash order — sorted below
        printf "TOT\t%d\n", tot + 0
    }
' "$PARSED")

printf '%s\n' "$agg" | { grep $'^AL\t' || true; } | cut -f2- | LC_ALL=C sort > "$AUTHL_OUT.tmp" && mv "$AUTHL_OUT.tmp" "$AUTHL_OUT"

IFS=$'\t' read -r _ tot <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${tot:-0}" -eq 0 ]; then
    echo "No successful SSH authentication records found." >&2
    rm -f "$OUT"
    exit 0
fi

{
    printf 'TITLE\tAuthentication Activity\n'
    printf 'TABLE\tBy account\n'
    printf 'HEAD\tAccount\tLogins\n'
    # most logons first, then the name (never awk hash order)
    printf '%s\n' "$agg" | { grep $'^AC\t' || true; } | LC_ALL=C sort -t$'\t' -k3,3nr -k2,2 | awk -F'\t' '{ printf "ROW\t%s\t%s\n", $2, $3 }'
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT + auth-logins.tsv ($tot successful SSH logon(s))." >&2
