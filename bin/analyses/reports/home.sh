#!/usr/bin/env bash
#
# home.sh — the ONE figure the home page's status tables cannot derive
# themselves: the SEEN count per entity group.
#
#   -> data/<env>/analyses/reports/home.rpt
#
# One line per member, TAB-separated:
#
#   SEEN<TAB><member><TAB><count>
#
# for the seven members of the two status tables — the four Flow manager
# entities (subscriptions, accounts, hosts, logins) and the three derived PDA
# ones (partners, domains, applications).
#
# WHY ONLY THIS. bin/build/publish.sh's _status_table computes every other figure
# straight from data/<env>/flow-manager/base/<member>.tsv (Total = rows,
# Server = result==blue, Error/Warning/Ok = red/orange/green) and derives the
# rest (Transfer = Seen - Server, Not seen = Total - Seen). Seen is the
# exception: it counts the configured names that actually appear in the logs,
# which only the coverage data knows. This script REPLACES entities.sh and
# partners-domains-applications.sh (2026-07), which produced 12- and
# 16-figure rows for the analyses Entities page — that page and its coverage
# cell tree are gone, and both consumers only ever read the Seen field
# (entities.rpt field 7 / pda.rpt field 8).
#
# Consumers: bin/build/publish.sh (both status tables) and
# bin/analyses/reports/seen-in-server-log.sh (the PDA half of its audit
# rollup, which is why THAT report still runs after this one).
#
# The classic four lift the number from their Show Seen member report — the
# canonical config-coverage count, so the home and Show Seen can never
# disagree. The PDA three re-run the both-ways MERGE over their coverage TSV:
# an organisation configured in both directions is ONE row, so its seen count
# cannot be summed from the per-direction rows.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
OUT="$REPORTS_DIR/home.rpt"

# Materialize the three derived PDA coverage TSVs. Kept here (it used to sit
# in partners-domains-applications.sh) because entity-search.sh reads them —
# see the ordering note in bin/analyses/reports.sh.
ensure_pda_tsvs

# Inputs: the four classic members' Show Seen INTRO counts and the three PDA
# coverage TSVs ensure_pda_tsvs just re-derived (cov_put keeps their mtime when
# nothing changed, so this guard is not defeated by the call above).
deps=()
for m in subscriptions accounts hosts logins; do
    [ -f "$DATA/transfer/reports/showseen-$m.rpt" ] && deps+=("$DATA/transfer/reports/showseen-$m.rpt")
done
for m in partners domains applications; do
    [ -f "$COVSRC/$m.tsv" ] && deps+=("$COVSRC/$m.tsv")
done
# the union rule reads the three PDA entity reports too (pda_seen_total)
for m in partner domain application; do
    [ -f "$DATA/transfer/reports/$m.rpt" ] && deps+=("$DATA/transfer/reports/$m.rpt")
done
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" ${deps[@]+"${deps[@]}"}

# The MERGED seen total of a PDA member: the same universe pda_split_figures
# counted, reduced to its one "seen, Total" figure.
#   partners      an Out row whose col 8 names an In partner folds onto that
#                 partner's row (one organisation working both ways), so the
#                 pair is seen when EITHER side is.
#   domains/apps  the same name in both directions is one row.
# $3 = the member's BASE cache: a slot is only counted when the name behind it
# is a real entity there (2026-08). The coverage TSV carries one row per
# CONNECTION, and an Out row is keyed by the HOST that identifies the far side;
# where that host maps to no configured partner and folds onto no In row, the
# fold used to open a slot of its own — a figure the Entities view can never
# show, since the view lists the base cache. That inflated Seen above the
# view's row count the moment such a host existed (an address discovered in the
# transfer log, bin/build/result.sh stage 0). Guarding it makes SEEN count the
# same universe as Total and as the page. Domains/applications are unaffected
# (every coverage name is already an entity) — the guard is applied to all
# three so the rule is one rule.
# THE UNION RULE (2026-08, replacing the coverage-membership rule): the figure
# must equal the row count of the Entities Seen view it links, and that view
# lists (a) every name the entity REPORT attributes at least one File to —
# the site-wide PARTNER/APP UNION attribution — plus (b) every base-cache name
# that is not never-seen per the coverage TSV (the blue and "ghost" rows:
# seen through a sibling group, a shared endpoint, or the server log). The
# old rule counted coverage membership only, and on the production load test
# (real config, two active accounts) said Seen 2 while the page listed 94.
# Computed here INDEPENDENTLY from the report + base + coverage sources —
# never lifted from the page — so check_status_consistency keeps its teeth.
# Never-seen mirrors the view exactly: a coverage name with no seen row and
# no Summary row (partners skip the per-endpoint hosts/ alias rows).
pda_seen_total() {   # $1 = member  $2 = its coverage TSV  $3 = its base cache  $4 = its entity .rpt
    local basef=${3:-/dev/null}; [ -f "$basef" ] || basef=/dev/null
    local rptf=${4:-/dev/null};  [ -f "$rptf" ] || rptf=/dev/null
    awk -F'\t' -v mem="$1" '
        FILENAME == ARGV[1] {                      # the entity report: Summary-table ROW names
            if ($1 == "TABLE") tb++
            if (tb == 1 && $1 == "ROW") { nm = $2; sub(/^@\{[^}]*\}/, "", nm); if (nm != "") S[toupper(nm)] = 1 }
            next
        }
        FILENAME == ARGV[2] { if ($1 != "") { k = toupper($1); if (!(k in B)) { B[k] = 1; ord[++nb] = k } }; next }
        {                                          # the coverage TSV: the never-seen determination
            if (mem == "partners" && $4 ~ /^hosts\//) next
            k = toupper($1)
            if (!(k in cov)) cov[k] = 0
            if ($3 == "1") cov[k] = 1
        }
        END {
            for (k in S) seen[k] = 1               # union-attributed names (logged, configured or not)
            for (i = 1; i <= nb; i++) { k = ord[i]
                if (k in seen) continue
                # never-seen = a coverage row says 0 and nothing else vouches;
                # a base name ABSENT from the coverage TSV is a ghost -> seen
                if ((k in cov) && cov[k] == 0) continue
                seen[k] = 1
            }
            s = 0; for (k in seen) s++
            print s + 0
        }' "$rptf" "$basef" "$2"
}

{
    # the four Flow manager entities: "Configured: N | Seen: X | Not seen: Y"
    # in the member's Show Seen INTRO ("Not seen" is lowercase-s, so /Seen: /
    # anchors the middle field only)
    for m in subscriptions accounts hosts logins; do
        rpt="$DATA/transfer/reports/showseen-$m.rpt"
        [ -f "$rpt" ] || continue
        seen=$(awk -F'\t' '$1 == "INTRO" && $2 ~ /^Configured: / {
            s = $2; sub(/.*Seen: /, "", s); sub(/[^0-9].*/, "", s); print s; exit }' "$rpt")
        [ -n "$seen" ] && printf 'SEEN\t%s\t%s\n' "$m" "$seen"
    done
    # the three derived PDA members
    for m in partners domains applications; do
        tsv="$COVSRC/$m.tsv"
        [ -f "$tsv" ] || continue
        case $m in partners) bc=_partners; er=partner ;; domains) bc=_domains; er=domain ;; *) bc=_apps; er=application ;; esac
        printf 'SEEN\t%s\t%s\n' "$m" "$(pda_seen_total "$m" "$tsv" "$DATA/flow-manager/base/$bc.tsv" "$DATA/transfer/reports/$er.rpt")"
    done
} | cov_put "$OUT"     # content-compared: home.rpt carries no FOOT timestamp, and
                       # seen-in-server-log.sh watches its mtime — an identical
                       # rewrite must not drag that report along.
echo "Wrote $OUT ($(grep -c . "$OUT") member(s))." >&2
