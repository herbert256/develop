#!/usr/bin/env bash
#
# sources-and-targets.sh — "Sources and Targets" (an ANALYSES report published
# with the transfer pages, like entity-coverage.sh / seen-in-server-log.sh):
# the From/To folder paths of every subscription, formatted "path @ host" for
# remote-partner endpoints EXACTLY like the Search page, in THREE tables:
#   1. values used as BOTH a Source and a Target  (internal hand-offs / relays)
#   2. Sources used by MORE THAN ONE subscription
#   3. Targets used by MORE THAN ONE subscription
#
# The Source/Target values and the "@ host" for the remote side come from the
# SAME inputs the Search page uses (the subscription detail .rpt From/To rows +
# xref/_subscriptions-{hosts,flowdir}.tsv — the remote side is From on a pull,
# To otherwise). Per-subscription Error/OK are lifted from subscription.rpt, and
# each row is tinted by its subscription RESULT (base/_subscriptions.tsv col 3).
# No date filter — a configuration analysis (render_report clears CUR_DATES).
#
# Reads:  data/<env>/transfer/reports/details/subscriptions/*.rpt,
#         data/<env>/transfer/reports/subscription.rpt,
#         base/_subscriptions.tsv, xref/_subscriptions-{hosts,flowdir}.tsv.
# Writes: data/<env>/transfer/reports/sources-and-targets.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../transfer/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/sources-and-targets.rpt"
DETAILS_DIR="$REPORTS_DIR/details"

shopt -s nullglob
dfiles=("$DETAILS_DIR/subscriptions"/*.rpt)
shopt -u nullglob
if [ ${#dfiles[@]} -eq 0 ]; then
    echo "No subscription detail reports — skipping Sources and Targets." >&2
    rm -f "$OUT"
    exit 0
fi

HF="$CONFIG_XREF/_subscriptions-hosts.tsv"
FF="$CONFIG_XREF/_subscriptions-flowdir.tsv"
CF="$REPORTS_DIR/subscription.rpt"
RF="$CONFIG_BASE/_subscriptions.tsv"
for v in HF FF CF RF; do eval "[ -f \"\$$v\" ] || $v=/dev/null"; done

# The From/To values come from the subscription DETAIL reports, so the whole
# details/subscriptions dir is an input (details.sh rewrites them as a set).
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$HF" "$FF" "$CF" "$RF" "${dfiles[@]}"

# ---- (A) per subscription -> its Source and Target value (Search-style) ------
# emit  <SRC|TGT> \t <value @ host> \t <subname> \t <slug> \t <err> \t <ok> \t <res>
inter=$(awk -F'\t' -v HF="$HF" -v FF="$FF" -v CF="$CF" -v RF="$RF" '
    BEGIN {
        # subscription -> configured remote host(s), joined ", " (explicit if,
        # not a ?: one-liner — mawk/BSD awk differ on ternary+concat precedence)
        while ((getline ln < HF) > 0) {
            n = split(ln, a, "\t")
            if (n >= 2 && a[2] != "") { k = toupper(a[1]); if (k in host) host[k] = host[k] ", " a[2]; else host[k] = a[2] }
        }
        while ((getline ln < FF) > 0) { n = split(ln, a, "\t"); if (n >= 2) fdir[toupper(a[1])] = a[2] }
        # subscription -> Error / OK from subscription.rpt Summary (first table):
        # ROW = name, Files, Error, OK, ...
        t = 0
        while ((getline ln < CF) > 0) {
            n = split(ln, a, "\t")
            if (a[1] == "TABLE") { t++; continue }
            if (t == 1 && a[1] == "ROW") { sn = a[2]; sub(/^@\{[^}]*\}/, "", sn); err[toupper(sn)] = a[4]; ok[toupper(sn)] = a[5] }
        }
        # subscription -> RESULT colour (green/red/orange/blue), base col 3
        while ((getline ln < RF) > 0) { n = split(ln, a, "\t"); if (n >= 1) res[toupper(a[1])] = a[3] }
    }
    # "@{mask=<sep+mask>}<dir>" -> "<dir><sep+mask>" (full path as displayed); else verbatim
    function fullpath(cell,   p, x, y) {
        if (substr(cell, 1, 7) == "@{mask=") { p = index(cell, "}"); x = substr(cell, 8, p - 8); y = substr(cell, p + 1); return y x }
        return cell
    }
    function flush(   K, h, fd, sv, tv, e, o, r) {
        if (slug == "" || nm == "") return
        K = toupper(nm); h = host[K]; fd = fdir[K]
        sv = frm; tv = to                       # From -> Source, To -> Target
        if (h != "") { if (fd == "in") { if (sv != "") sv = sv " @ " h } else { if (tv != "") tv = tv " @ " h } }
        e = err[K]; o = ok[K]; r = res[K]
        if (sv != "") print "SRC\t" sv "\t" nm "\t" slug "\t" e "\t" o "\t" r
        if (tv != "") print "TGT\t" tv "\t" nm "\t" slug "\t" e "\t" o "\t" r
    }
    FNR == 1 { flush(); slug = FILENAME; sub(/.*\//, "", slug); sub(/\.rpt$/, "", slug); frm = ""; to = ""; nm = ""; infeat = 0 }
    $1 == "TITLE" { nm = $2; sub(/^[A-Z?]+\/[A-Z?]+: /, "", nm); sub(/^[^:]*: /, "", nm) }
    $1 == "TABLE" { infeat = ($2 == "Features") }
    # a "-" value is the details.sh placeholder for a side with no configured
    # directory (From/To are always both present there); skip it, not a path.
    infeat && $1 == "ROW" && $2 == "From" { frm = ($3 == "-" ? "" : fullpath($3)) }
    infeat && $1 == "ROW" && $2 == "To"   { to  = ($3 == "-" ? "" : fullpath($3)) }
    END { flush() }
' "${dfiles[@]}")

# ---- (B) table builders ------------------------------------------------------
# A member record is subname \034 slug \034 err \034 ok \034 res (SUBSEP-joined,
# re-split in the awk); rows link the subscription to its detail page and carry
# @data:res (its result colour) for the row tint.
#
# tbl_multi KIND — Sources (SRC) or Targets (TGT) used by >1 subscription:
# one grouped block per value (>=2 members), value on every row (report.js
# blanks the repeat), members subname-sorted.
tbl_multi() {
    printf '%s\n' "$inter" | awk -F'\t' -v K="$1" '$1==K' \
      | LC_ALL=C sort -t$'\t' -k2,2 -k3,3 -f \
      | awk -F'\t' '
          function flush(   i, m, rr) {
              if (cur == "" || n < 2) { n = 0; return }
              for (i = 1; i <= n; i++) {
                  split(buf[i], m, SUBSEP)
                  rr = (m[5] != "") ? "\t@data:res=" m[5] : ""
                  printf "ROW\t%s\t@{link=subscriptions/%s}%s\t%s\t%s%s\n", cur, m[2], m[1], m[3], m[4], rr
                  rown++; te += (m[3] == "" ? 0 : m[3]); to += (m[4] == "" ? 0 : m[4])
              }
              n = 0
          }
          { if ($2 != cur) { flush(); cur = $2 } n++; buf[n] = $3 SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7 }
          END { flush(); printf "TOTAL\tTotal (%d rows)\t\t@{class=num failed}%d\t@{class=num processed}%d\n", rown+0, te+0, to+0 }'
}

# Values that are used as BOTH a Source and a Target (>=1 each): per value emit
# its Source members then its Target members, Role column telling them apart.
tbl_both() {
    printf '%s\n' "$inter" \
      | LC_ALL=C sort -t$'\t' -k2,2 -k1,1 -k3,3 -f \
      | awk -F'\t' '
          function emit(role, list, cnt,   i, m, rr) {
              for (i = 1; i <= cnt; i++) {
                  split(list[i], m, SUBSEP)
                  rr = (m[5] != "") ? "\t@data:res=" m[5] : ""
                  printf "ROW\t%s\t%s\t@{link=subscriptions/%s}%s\t%s\t%s%s\n", cur, role, m[2], m[1], m[3], m[4], rr
                  rown++; te += (m[3] == "" ? 0 : m[3]); to += (m[4] == "" ? 0 : m[4])
              }
          }
          function flush() {
              if (cur != "" && ns > 0 && nt > 0) { emit("Source", sbuf, ns); emit("Target", tbuf, nt) }
              ns = 0; nt = 0
          }
          { if ($2 != cur) { flush(); cur = $2 }
            if ($1 == "SRC") { ns++; sbuf[ns] = $3 SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7 }
            else             { nt++; tbuf[nt] = $3 SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7 } }
          END { flush(); printf "TOTAL\tTotal (%d rows)\t\t\t@{class=num failed}%d\t@{class=num processed}%d\n", rown+0, te+0, to+0 }'
}

# ---- (C) write the .rpt ------------------------------------------------------
{
    printf 'TITLE\tSources and Targets\n'
    printf 'DESC\tThe From/To folder paths of every subscription (shown "path @ host" for remote-partner endpoints, like the Search page): values used as both a source and a target, and sources/targets shared by more than one subscription.\n'
    printf 'INTRO\tEvery subscription reads from a **source** folder and writes to a **target** folder; a remote-partner endpoint shows its host after an **@** (exactly as on the Search page). Three tables: paths that serve as **both** a source and a target (internal hand-offs), **sources** used by more than one subscription, and **targets** used by more than one subscription. Each row links to the subscription and is tinted by its status.\n'
    printf 'KEYWORDS\tsource,target,from,to,folder,path,directory,relay,handoff,shared,remote,endpoint,host\n'

    printf 'TABLE\tValues used as both a Source and a Target\twide\tgroup\tkeephead\n'
    printf 'HEAD\tValue\tRole\tSubscription\tError\tOK\n'
    printf 'KIND\ttext\ttext\ttext\tnumfailed\tnumprocessed\n'
    tbl_both

    printf 'TABLE\tSources used by multiple subscriptions\twide\tgroup\n'
    printf 'HEAD\tSource\tSubscription\tError\tOK\n'
    printf 'KIND\ttext\ttext\tnumfailed\tnumprocessed\n'
    tbl_multi SRC

    printf 'TABLE\tTargets used by multiple subscriptions\twide\tgroup\n'
    printf 'HEAD\tTarget\tSubscription\tError\tOK\n'
    printf 'KIND\ttext\ttext\tnumfailed\tnumprocessed\n'
    tbl_multi TGT

    printf 'NOTE\tA **remote** source/target (an endpoint we dial) carries its partner host after **@**; a local SecureTransport path has none. A value in the first table is written by one subscription and read by another — an internal hand-off. Error/OK are each subscription'"'"'s own transfer outcome.\n'
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT." >&2
