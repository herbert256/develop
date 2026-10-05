#!/usr/bin/env bash
#
# coverage.sh — the coverage cell lists: one .rpt per member of the home
# page's Achmea entities table — the page its
# ENTITY label links, holding exactly the items its Total counts.
#
#   -> data/coverage/<member>-configured.rpt   (logicals / partners / applications / domains / bl)
#
# Source: showseen.sh's per-member coverage TSVs (data/transfer/reports/
# coverage/<member>.tsv — name, dir I/O, seen, detail link, last-transaction
# timestamp, last outcome F/P) plus the derived TSVs this script
# materializes via ensure_pda_tsvs (logicals / partners / applications /
# domains / bl — the five members read here).
# Each .rpt carries TITLE / MEMBER / KEY / LTCOL / DIRCOL directives and the
# merged, sorted ROW lines (the raw coverage-TSV fields); the publish
# script (bin/analyses/publish.sh) renders each into docs/coverage/. A zero
# cell (no matching rows) writes no .rpt, so the coverage tables leave that
# cell unlinked. Rebuilt from scratch on every run.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

[ -d "$COVSRC" ] || exit 0
ensure_pda_tsvs

rm -f "$COVRPT_DIR"/*.rpt

npages=0
# (the whitelist member was REMOVED 2026-07: the Whitelist row is gone from
# the entities page and the home, so its cell pages had nothing linking them)
# RESTORED 2026-07, restricted: only the Logical + three PDA members + BL and
# only the CONFIGURED (All) cell — the home page's Total links in that group
# are the doors, and nothing else links a coverage cell any more. (The seen /
# not-seen / result / status cells and the per-direction and In only / Both /
# Out only variants — their key tables and filters — went with their links;
# bin/analyses/lib.sh cov_label still spells every former key.)
key=configured
for member in logicals partners applications domains bl; do
    tsv="$COVSRC/$member.tsv"
    [ -f "$tsv" ] || continue
    # the page label = the home Entity label that opens it (2026-09-30 audit
    # L-08: "Logical flows" / "External Partners" / "Internal Applications" /
    # "Internal Domains" before)
    mlabel="$(printf '%s' "${member:0:1}" | tr '[:lower:]' '[:upper:]')${member:1}"
    [ "$member" = logicals ] && mlabel="Logical"
    [ "$member" = bl ] && mlabel="BL"
    # Every member lives in ONE name space, so the Configured cell counts
    # UNIQUE names: the In and Out rows merge per name (direction "In + Out"
    # = B, Seen = either side, Result = the latest transaction of both sides).
    # Field 7 (the member list) stays EMPTY since 2026-09-29: the page builds
    # its lists from the xref caches, nothing read it (two thirds of the bytes).
    if [ "$member" = partners ]; then
        # partners: an Out endpoint IP-linked to an In partner (col 8) folds
        # into that partner's row — direction "In + Out", Seen = either side,
        # Result = the latest transaction of both. Unlinked rows pass through.
        rows=$(awk -F'\t' '
            $2 == "I" { idx[$1] = ++n; nm[n] = $1; dr[n] = "I"; sn[n] = $3; lk[n] = $4; ts[n] = $5; oc[n] = $6; ips[n] = $8; next }
            { if ($8 != "" && ($8 in idx)) { i = idx[$8]
                  dr[i] = "B"
                  if ($3 == 1) sn[i] = 1
                  if ($5 != "" && $5 > ts[i]) { ts[i] = $5; oc[i] = $6 } }
              else { # a SELF-NAMED ENDPOINT row (link -> hosts/…): its account
                     # derives no partner org (a one-part name like EUROPORT or
                     # P2P — PDA rule 1 skips it), so it is a HOST, not a
                     # partner, and home.sh already excludes it from the
                     # partner figures with this same test. Listing it here
                     # made the page total 172 against the home card 125
                     # (2026-08-29).
                     if ($4 ~ /^hosts\//) next
                     ++n; nm[n] = $1; dr[n] = "O"; sn[n] = $3; lk[n] = $4; ts[n] = $5; oc[n] = $6; ips[n] = "" } }
            END{ for (i = 1; i <= n; i++)
                    printf "%s\t%s\t%d\t%s\t%s\t%s\t\t%s\n", nm[i], dr[i], sn[i], lk[i], ts[i], oc[i], ips[i] }' "$tsv")
    else
        rows=$(awk -F'\t' '
            { if ($1 in idx) { i = idx[$1]
                  # an EMPTY side (a direction-less member) adds no direction
                  if ($2 != "" && dr[i] != $2) dr[i] = (dr[i] == "") ? $2 : "B"
                  if ($3 == 1) sn[i] = 1
                  if ($5 != "" && $5 > ts[i]) { ts[i] = $5; oc[i] = $6 } }
              else { idx[$1] = ++n; nm[n] = $1; dr[n] = $2; sn[n] = $3; lk[n] = $4; ts[n] = $5; oc[n] = $6 } }
            END{ for (i = 1; i <= n; i++)
                    printf "%s\t%s\t%d\t%s\t%s\t%s\t\t\n", nm[i], dr[i], sn[i], lk[i], ts[i], oc[i] }' "$tsv")
    fi
    [ -n "$rows" ] || continue
    # the External Partners page sorts on the partner name — the merged
    # stream would otherwise list the In partners first and the unlinked Out
    # partners after them, restarting the alphabet. -f: endpoint-named
    # partners are lowercase hostnames.
    [ "$member" = partners ] && rows=$(printf '%s\n' "$rows" | LC_ALL=C sort -t$'\t' -f -k1,1)
    n=$(printf '%s\n' "$rows" | grep -c .)
    title="$mlabel: $(cov_label "$key") ($n)"
    # LTCOL 2 = NO trailing column (the five unified Configured pages,
    # 2026-08-31, user request — the row tint carries seen-ness); DIRCOL 1 =
    # the Direction column (a Configured page shows it)
    {
        printf 'TITLE\t%s\n'  "$title"
        printf 'MEMBER\t%s\n' "$member"
        printf 'KEY\t%s\n'    "$key"
        printf 'LTCOL\t2\n'
        printf 'DIRCOL\t1\n'
        printf '%s\n' "$rows" | awk '{ print "ROW\t" $0 }'
    } > "$COVRPT_DIR/$member-$key.rpt.tmp" && mv "$COVRPT_DIR/$member-$key.rpt.tmp" "$COVRPT_DIR/$member-$key.rpt"
    npages=$((npages + 1))
done
echo "Wrote $npages coverage cell .rpt file(s) to $COVRPT_DIR/." >&2
