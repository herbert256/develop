#!/usr/bin/env bash
#
# config-defects.sh — the SERVER-LOG side of Config hygiene (2026-08 study E3):
# three recurring single-cause defect families extracted from the parse cache
# into a small TSV sidecar the config-hygiene PAGE renders (compute here,
# presentation in bin/analyses/publish-insights.sh — the site-wide split).
#
#   PROFILE <TAB> name <TAB> count <TAB> first <TAB> last
#       E "Transfer profile 'X' is used for incoming transfer, but
#          'Receive File As' field not set" — a one-field config gap that
#       errors on every incoming transfer of that profile.
#       (Transfer profiles are PARSE-INTERNAL: the page must render them as
#       plain text — no link, no entity KIND. CLAUDE.md, transfer-profile.)
#   DNSDEAD <TAB> host <TAB> count <TAB> first <TAB> last
#       "Unknown site host:X(: Name or service not known)" — a configured
#       endpoint DNS cannot resolve.
#   TUNING <TAB> token <TAB> count <TAB> first <TAB> last
#       W "Value of 'Server.ProtocolCommands.batchSize' is too low..." — the
#       recurring server-tuning warning.
#
# Not a .rpt — no page of its own; data/<env>/server/reports/config-defects.tsv.
#
# Usage:
#   ./config-defects.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/config-defects.tsv"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — the page skips its server-log tables
    exit 0
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Extracting the config-defect families from the server cache..." >&2

awk -F'\t' '
    function note(k, v, d,   key) {
        if (v == "") return
        key = k SUBSEP v
        n[key]++
        if (first[key] == "" || d < first[key]) first[key] = d
        if (last[key] == "" || d > last[key]) last[key] = d
    }
    {
        m = $5; d = substr($1, 1, 10)
        if ($3 == "E" && m ~ /Transfer profile .* is used for incoming transfer, but .Receive File As. field not set/) {
            p = m; sub(/^.*Transfer profile ./, "", p); sub(/[\x27"].*$/, "", p)
            note("PROFILE", p, d)
        } else if (m ~ /Unknown site host:/) {   # both forms: with and without the ": Name or service not known" tail
            h = m; sub(/^.*Unknown site host:/, "", h); sub(/\(.*$/, "", h); sub(/:.*$/, "", h)
            note("DNSDEAD", tolower(h), d)
        } else if ($3 == "W" && m ~ /Value of .Server\.ProtocolCommands\.batchSize. is too low/) {
            note("TUNING", "Server.ProtocolCommands.batchSize", d)
        }
    }
    END {
        # deterministic order: kind, then count desc, then name (no hash order)
        for (key in n) {
            split(key, a, SUBSEP)
            printf "%s\t%s\t%d\t%s\t%s\n", a[1], a[2], n[key], first[key], last[key]
        }
    }
' "$PARSED" | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k3,3nr -k2,2 > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($(wc -l < "$OUT" | tr -d ' ') defect row(s))." >&2
