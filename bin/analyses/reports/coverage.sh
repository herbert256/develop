#!/usr/bin/env bash
#
# coverage.sh — the coverage cell lists: one .rpt per NONZERO cell of the
# Entities and Partners, Domains & Applications tables, holding exactly the
# items that cell counts.
#
#   -> data/coverage/<member>-configured.rpt   (logicals / partners / applications / domains / bl)
#
# Source: showseen.sh's per-member coverage TSVs (data/transfer/reports/
# coverage/<member>.tsv — name, dir I/O, seen, detail link, last-transaction
# timestamp, last outcome F/P; whitelist.tsv the same with IPs and no link)
# plus the four derived TSVs this script materializes via ensure_pda_tsvs.
# Each .rpt carries TITLE / MEMBER / KEY / LTCOL / DIRCOL directives and the
# filtered, sorted ROW lines (the raw coverage-TSV fields); the publish
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
# RESTORED 2026-07, restricted: only the Logical + three PDA members and only
# the CONFIGURED (All) cell — the home page's four Total links in that group
# are the doors, and nothing else links a coverage cell any more.
for member in logicals partners applications domains bl; do
    tsv="$COVSRC/$member.tsv"
    [ -f "$tsv" ] || continue
    mlabel="$(printf '%s' "${member:0:1}" | tr '[:lower:]' '[:upper:]')${member:1}"
    [ "$member" = logicals ] && mlabel="Logical flows"
    [ "$member" = bl ] && mlabel="BL"
    [ "$member" = partners ] && mlabel="External Partners"
    [ "$member" = applications ] && mlabel="Internal Applications"
    [ "$member" = domains ] && mlabel="Internal Domains"
    for key in configured; do
        # The -inonly/-both/-outonly variants are PDA-only, skipped for
        # non-PDA below. (result-*-failed keys were REMOVED 2026-07: the
        # Result pair cells link only their -processed half.)
        # mdirf: the direction-SPLIT keys (the PDA partition table) filter the
        # MERGED rows by their partitioned direction (I = in only, B = both,
        # O = out only) — only the three pda members have them.
        mdirf=""
        case $key in
            *-inonly|*-inonly-*)   mdirf=I ;;
            *-both|*-both-*)       mdirf=B ;;
            *-outonly|*-outonly-*) mdirf=O ;;
        esac
        if [ -n "$mdirf" ]; then
            case $member in partners|applications|domains) : ;; *) continue ;; esac
        fi
        # The Status tables' RESULT cells are gone (2026-07): the home + analyses
        # Status tables send Error / Warning / Ok into the Transfer > Entities
        # views (<entity>-{error,warning,ok}.html), which list the same entities
        # from the same base result column. That now holds for EVERY member —
        # the PDA three followed the classic four once Partners/Domains/
        # Applications' figures were pointed at their own Entities views — so
        # nothing links these cell pages any more and they are not built.
        case $key in status-error|status-warning|status-ok) continue ;; esac
        # the pda members' per-side cells (the PDA page's In & Out table)
        # filter the MERGED rows by SIDE — In = flowing in at all (I or B),
        # Out = flowing out at all (O or B) — so a both-ways item appears
        # on both side pages; the entity members keep the raw-row filter.
        case $member in partners|applications|domains)
            case $key in
                configured-in|notseen-in|seen-in|result-in-*)     mdirf=IB ;;
                configured-out|notseen-out|seen-out|result-out-*) mdirf=OB ;;
            esac ;;
        esac
        case $key in
            configured)           dirf=""; seenf=""; outf="" ;;
            configured-in)        dirf=I;  seenf=""; outf="" ;;
            configured-out)       dirf=O;  seenf=""; outf="" ;;
            notseen)              dirf=""; seenf=0;  outf="" ;;
            notseen-in)           dirf=I;  seenf=0;  outf="" ;;
            notseen-out)          dirf=O;  seenf=0;  outf="" ;;
            seen)                 dirf=""; seenf=1;  outf="" ;;
            seen-in)              dirf=I;  seenf=1;  outf="" ;;
            seen-out)             dirf=O;  seenf=1;  outf="" ;;
            result-processed)     dirf=""; seenf=1;  outf=P ;;
            result-in-processed)  dirf=I;  seenf=1;  outf=P ;;
            result-out-processed) dirf=O;  seenf=1;  outf=P ;;
            configured-*only|configured-both)  dirf=""; seenf=""; outf="" ;;
            notseen-*only|notseen-both)        dirf=""; seenf=0;  outf="" ;;
            seen-*only|seen-both)              dirf=""; seenf=1;  outf="" ;;
            result-*-processed)                dirf=""; seenf=1;  outf=P ;;
        esac
        # a merged-row direction filter always takes the merged path
        [ -n "$mdirf" ] && dirf=""
        # Applications/domains live in ONE name space, so their
        # direction-less cells (Configured/Seen/Result Total) count UNIQUE
        # names: merge the In and Out rows per name first (direction shows
        # "In + Out", Seen = either side, Result = the latest transaction
        # of both sides, members concatenated), THEN apply the seen/outcome
        # filter. Directed cells and every partners cell keep the raw rows.
        if [ -z "$dirf" ] && [ "$member" = partners ]; then
            # partners Total cells: an Out endpoint IP-linked to an In
            # partner (col 8) folds into that partner's row — direction
            # "In + Out", its account|covlink|endpoint members join the
            # In member list, Seen = either side, Result = the latest
            # transaction of both. Unlinked rows pass through; then the
            # seen/outcome filter applies.
            rows=$(awk -F'\t' -v s="$seenf" -v o="$outf" -v dm="$mdirf" '
                BEGIN{ US = sprintf("%c", 31) }
                $2 == "I" { idx[$1] = ++n; nm[n] = $1; dr[n] = "I"; sn[n] = $3; lk[n] = $4; ts[n] = $5; oc[n] = $6; mem[n] = $7; ips[n] = $8; next }
                { if ($8 != "" && ($8 in idx)) { i = idx[$8]
                      dr[i] = "B"
                      if ($3 == 1) sn[i] = 1
                      if ($5 != "" && $5 > ts[i]) { ts[i] = $5; oc[i] = $6 }
                      ent = ($7 != "") ? $7 : $1 "|" $4 "|" $1
                      # fold per account NAME: a partner whose In and Out side
                      # are the SAME account (the monitor) must list it ONCE —
                      # the endpoint-carrying variant wins over the plain one
                      na = split(ent, AD, US)
                      for (j = 1; j <= na; j++) {
                          split(AD[j], tp, "|"); dup = 0
                          nb = (mem[i] == "") ? 0 : split(mem[i], BD, US)
                          for (k = 1; k <= nb; k++) {
                              split(BD[k], tq, "|")
                              if (tq[1] == tp[1]) { dup = 1
                                  if (split(AD[j], t3, "|") >= 3 && split(BD[k], t4, "|") < 3) {
                                      BD[k] = AD[j]
                                      mem[i] = BD[1]; for (m = 2; m <= nb; m++) mem[i] = mem[i] US BD[m]
                                  }
                                  break } }
                          if (!dup) mem[i] = (mem[i] == "" ? AD[j] : mem[i] US AD[j])
                      } }
                  else { # a SELF-NAMED ENDPOINT row (link -> hosts/…): its account
                         # derives no partner org (a one-part name like EUROPORT or
                         # P2P — PDA rule 1 skips it), so it is a HOST, not a
                         # partner — covered on hosts-configured, and home.sh
                         # already excludes it from the partner figures with this
                         # same test. Listing it here made the page total 172
                         # against the home card 125 (2026-08-29).
                         if ($4 ~ /^hosts\//) next
                         ++n; nm[n] = $1; dr[n] = "O"; sn[n] = $3; lk[n] = $4; ts[n] = $5; oc[n] = $6; mem[n] = $7; ips[n] = "" } }
                END{ for (i = 1; i <= n; i++)
                    if ((dm == "" || index(dm, dr[i]) > 0) && (s == "" || sn[i] == s) && (o == "" || oc[i] == o))
                        printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", nm[i], dr[i], sn[i], lk[i], ts[i], oc[i], mem[i], ips[i] }' "$tsv")
        elif [ -z "$dirf" ] && { [ "$member" = applications ] || [ "$member" = domains ] || [ "$member" = logicals ] || [ "$member" = bl ]; }; then
            rows=$(awk -F'\t' -v s="$seenf" -v o="$outf" -v dm="$mdirf" '
                BEGIN{ US = sprintf("%c", 31) }
                { if ($1 in idx) { i = idx[$1]
                      # an EMPTY side (a direction-less member) adds no direction
                      if ($2 != "" && dr[i] != $2) dr[i] = (dr[i] == "") ? $2 : "B"
                      if ($3 == 1) sn[i] = 1
                      if ($5 != "" && $5 > ts[i]) { ts[i] = $5; oc[i] = $6 }
                      if ($7 != "") mem[i] = (mem[i] == "" ? $7 : mem[i] US $7) }
                  else { idx[$1] = ++n; nm[n] = $1; dr[n] = $2; sn[n] = $3; lk[n] = $4; ts[n] = $5; oc[n] = $6; mem[n] = $7 } }
                END{ for (i = 1; i <= n; i++)
                    if ((dm == "" || index(dm, dr[i]) > 0) && (s == "" || sn[i] == s) && (o == "" || oc[i] == o))
                        printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t\n", nm[i], dr[i], sn[i], lk[i], ts[i], oc[i], mem[i] }' "$tsv")
        else
            rows=$(awk -F'\t' -v d="$dirf" -v s="$seenf" -v o="$outf" \
                '(d=="" || $2==d) && (s=="" || $3==s) && (o=="" || $6==o)' "$tsv")
        fi
        [ -n "$rows" ] || continue
        if [ "$member" = partners ]; then
            # every External Partners page sorts on the partner name — the
            # merged stream would otherwise list the In partners first and
            # the unlinked Out partners after them, restarting the
            # alphabet. -f: endpoint-named partners are lowercase hostnames.
            rows=$(printf '%s\n' "$rows" | LC_ALL=C sort -t$'\t' -f -k1,1)
        else
            # result pages list the most recent transactions first
            case $key in result-*) rows=$(printf '%s\n' "$rows" | LC_ALL=C sort -t$'\t' -k5,5r) ;; esac
        fi
        n=$(printf '%s\n' "$rows" | grep -c .)
        title="$mlabel: $(cov_label "$key") ($n)"
        # per-variation columns: the Not Seen pages drop Last transfer +
        # Result (always blank there) and keep Seen instead — everywhere
        # else Last transfer already tells seen-ness, so the Seen column
        # is dropped; Direction shows only on the Configured (All) pages.
        # LTCOL 2 = NO trailing column at all: the partners Configured page
        # (2026-08) — the row tint already carries seen-ness there.
        ltcol=1 dircol=0
        [ "$seenf" = "0" ] && ltcol=0
        [ "$key" = configured ] && ltcol=2   # the five unified pages carry no trailing column (2026-08-31, user request)
        case $key in configured*|status-*) dircol=1 ;; esac
        {
            printf 'TITLE\t%s\n'  "$title"
            printf 'MEMBER\t%s\n' "$member"
            printf 'KEY\t%s\n'    "$key"
            printf 'LTCOL\t%s\n'  "$ltcol"
            printf 'DIRCOL\t%s\n' "$dircol"
            printf '%s\n' "$rows" | awk '{ print "ROW\t" $0 }'
        } > "$COVRPT_DIR/$member-$key.rpt.tmp" && mv "$COVRPT_DIR/$member-$key.rpt.tmp" "$COVRPT_DIR/$member-$key.rpt"
        npages=$((npages + 1))
    done
done
echo "Wrote $npages coverage cell .rpt file(s) to $COVRPT_DIR/." >&2
