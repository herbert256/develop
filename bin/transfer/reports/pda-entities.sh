#!/usr/bin/env bash
#
# pda-entities.sh — the Logical + three PDA entities + BL as entity DATA, one
# .rpt per dimension from the logical-transfer cache (each File carries its
# partner / application / domain attribution, _files.tsv cols 20 / 18 / 19;
# the Logical resolves the profile column 13 through the FlowID map,
# xref/_profiles-logicals.tsv):
#   logical.rpt  partner.rpt  application.rpt  domain.rpt
# (+ bl.rpt). Each is the exact account.sh record — ONE table, one ROW per
# name (Files, Error, OK; trimmed 2026-09-29 to what its readers use — the
# newest Error / OK File columns of the classic four are read by showseen.sh
# for account / subscription / login / remote-host only) — so entity-search.sh (the counts) and
# home.sh (the names) read them exactly like the classic four. NO PAGE of
# their own: the Entities pages render from entities.sh's grouped
# entities/<dim>.rpt. (The per-day "Detail per <name> / Date" table went
# 2026-09-29: no reader.)
#
# Usage:
#   ./pda-entities.sh    # reads input/*.csv (via the caches), writes data/transfer/reports/{logical,partner,application,domain,bl}.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$ROOT/bin/pda-union.sh"   # SP_AWK: the File attribution UNION (sp_union / ap_union / lg_union / bl_union)


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
mkdir -p "$REPORTS_DIR"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# (THE LEG FLAGS pre-pass over _transfers.tsv — 2026-09-28, speed round 15
# — went 2026-09-29: the record no longer carries Retry / Resubmit, and the
# parse stores the two leg flags in _files.tsv cols 26 / 27 anyway.)

# THE FIVE DIMENSIONS IN PARALLEL (same round): each writes its own .rpt from
# the same read-only inputs, one job each instead of one after another.
pda_dim() {   # $1 = logical|partner|application|domain|bl
    local dim=$1 col title chead attr OUT agg
    local summary_rows
    case $dim in
        logical)     col=13; title="Logical";      chead="Logical"
                     attr="the file's logical flow group (its FlowID condensed to a 3-part group name — data/flow-manager/base/_logicals.tsv)" ;;
        partner)     col=20; title="Partners";     chead="Partner"
                     attr="the file's partner organisation (part 3 of its logical flow name, merged into organisations — data/flow-manager/base/_partners.tsv)" ;;
        application) col=18; title="Applications"; chead="Application"
                     attr="part 2 of the file's logical flow name (data/flow-manager/base/_apps.tsv)" ;;
        domain)      col=19; title="Domains";      chead="Domain"
                     attr="part 1 of the file's logical flow name (data/flow-manager/base/_domains.tsv)" ;;
        bl)          col=12; title="BL";           chead="BL"
                     attr="the subscription's BL tag from subscriptions.json (data/flow-manager/base/_bl.tsv)" ;;
    esac
    OUT="$REPORTS_DIR/$dim.rpt"

    # One pass over _files.tsv (1=coreid, 2=outcome, 4=date_iso, 5=time,
    # 6=sortkey, col=the dimension's direct column) — account.sh's
    # aggregation (and record) with the account column swapped for the PDA
    # attribution. Files without the attribution or a valid date are skipped.
    # UNION attribution (the shared sets of bin/pda-union.sh): a File counts
    # for EVERY name its config maps to, UNIONED with the parse-time
    # attribution — deduped per (name, CoreId), so these Files can sum to
    # more than the distinct total.
    #   partner:     col 12 (subscription) joined on _subscriptions-partners
    #                — a UC5 relay / both-partner file belongs to BOTH
    #                organisations, and the both-partner case carries an
    #                EMPTY col 20 (the parse abstains on a two-group account)
    #   application: col 12 (subscription) joined on _subscriptions-apps —
    #                the FlowID spine (2026-08-31; the former ACCOUNT union
    #                credited every File of a shared hybrid production
    #                account to every application the account touches)
    #   logical:     col 13 through the FlowID map ∪ its subscription's
    #                logicals; bl: its subscription's tag(s)
    # Domains stay single-valued (part 1 of the name — never doubles).
    agg=$(awk -F'\t' -v DIM="$dim" "${SP_AWK_V[@]}" "$SP_AWK"'
        $4 == "" { next }
        {
            if (DIM == "partner") u = sp_union($20, $12)
            else if (DIM == "application") u = ap_union($18, $12)
            else if (DIM == "logical") u = lg_union($13, $12)
            else if (DIM == "bl") u = bl_union($12)
            else u = $19
            if (u == "") next
            delete P
            n2 = split(u, z, "\037"); for (i2 = 1; i2 <= n2; i2++) P[z[i2]] = 1
            f = ($2 == "Failed" || $2 == "Expired")
            for (a in P) { sc[a]++; if (f) sfl[a]++; else spr[a]++ }
        }
        END { for (a in sc) printf "S|%s|%d|%d|%d\n", a, sc[a], sfl[a]+0, spr[a]+0 }
    ' "$FILES")

    # The rows, busiest first (by File count).
    summary_rows=$({ printf '%s\n' "$agg" | grep '^S|' || true; } | sort -t'|' -k3,3nr | awk -F'|' '
        $2 == "" { next }
        { printf "ROW\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5 }')

    {
        printf 'TITLE\t%s\n' "$title"
        printf 'TABLE\tSummary per %s\n' "$chead"
        printf 'HEAD\t%s\tFiles\tError\tOK\n' "$chead"
        [ -n "$summary_rows" ] && printf '%s\n' "$summary_rows"
        printf 'FOOT\n'
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    echo "Data written to $OUT ($(printf '%s\n' "$summary_rows" | grep -c '^ROW' || true) $dim(s))." >&2
}
_ppids=()
for dim in logical partner application domain bl; do pda_dim "$dim" & _ppids+=("$!"); done
_prc=0
for _pp in "${_ppids[@]}"; do wait "$_pp" || _prc=$?; done
[ "$_prc" -eq 0 ] || { echo "pda-entities: a dimension failed (exit $_prc)." >&2; exit "$_prc"; }
