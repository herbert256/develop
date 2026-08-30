#!/usr/bin/env bash
#
# security-params.sh
# Analyses the connection security of transfers: one table per attribute parsed
# from the free-text "SecurityParameters" column (field 38), e.g. "Cipher:
# aes128-ctr, MAC: hmac-sha2-256, Key Exchange: ..., Public Key: ...". ALWAYS
# exactly the six known attribute tables in a fixed order (an attribute absent
# from the data emits an empty table): report_tabs splits the page into one tab
# per table, and the tab count must match in every env. The former Protocol
# distribution table was dropped 2026-08 — the protocol report in the same
# group owns that table.
#
# Every first-column VALUE (a protocol, or an attribute value like a cipher)
# links to a per-value page listing the SUBSCRIPTIONS that used it: one .rpt per
# (table, value) into data/<env>/transfer/reports/secparams/<slug>.rpt, rendered
# to docs/<env>/transfer/secparams/<slug>.html by bin/transfer/publish.sh.
#
# Usage:
#   ./security-params.sh   # reads input/*.csv, writes data/security-params.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/security-params.rpt"

# Renders one main-table ROW: the value cell links to its per-value page (the
# slugmap is loaded ONCE per table into sl[], for the discriminator `d`), and the
# "-" sentinels that keep the aggregate's TAB fields aligned become empty cells.
# Inject it the COREIDS_AWK way, with -v smap= and -v d=.
SECROW_AWK='
    BEGIN { while ((getline _l < smap) > 0) { split(_l, _a, "\t"); if (_a[1] == d) sl[_a[2]] = _a[3] } close(smap) }
    { bk = ($5 == "-") ? "" : $5; cf = ($6 == "-") ? "" : $6; cp = ($7 == "-") ? "" : $7
      lk = ($1 in sl) ? "@{href=secparams/" sl[$1] ".html}" : ""
      printf "ROW\t%s%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s\n", \
          lk, $1, $2, $3, $4, bk, cf, cp }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# The per-(table,value,subscription,host-partner) counts go to this sidecar
# (one line per group per value), kept out of the main $agg so it stays small:
#   <disc>|<value>|<site>|<host-partner>|<count>|<failed>|<processed>
# disc = the attribute key. host-partner = the leg CoreId's _files.tsv col 20
# (the host-resolved side of the site-wide PARTNER UNION attribution; empty
# when the parse abstained) — the planner below unions it with the
# subscription's configured partners per group.
subfile="$REPORTS_DIR/.secparams-subs.$$"
pairfile="$REPORTS_DIR/.secparams-pairs.$$"
: > "$subfile"
trap 'rm -f "$subfile" "$pairfile"' EXIT

# Read the shared parse cache (6=site, 10=protocol, 21=secparams raw).
# Emits (stdout):  PROTO|protocol|count...   and   ATTR|key|value|count...
# Emits (subfile): the per-subscription rows above.
agg=$(awk -F'\t' -v subout="$subfile" "$COREIDS_AWK"'
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    # file 1 = $FILES: the per-CoreId host-resolved partner (col 20, filled at
    # parse time via _hosts-partners.tsv, else the account org; empty when the
    # parse abstained) — the OTHER half of the site-wide PARTNER UNION
    FNR == NR { if ($20 != "") { hpv = $20; gsub(/[|\t]/, " ", hpv); hp[$1] = hpv } next }
    {
        st = $3; sub(/ Subtransmission$/, "", st); f = (st != "Processed"); oc = f ? "F" : "P"
        sk = $13; disp = $11 " " $12; tid = $23
        proto = $10; if (proto == "") proto = "UNKNOWN"
        d = $11
        site = $6; gsub(/[|\t]/, " ", site)
        h = ($1 in hp) ? hp[$1] : ""   # this leg CoreId host-resolved partner
        # protocol counts feed only the page TOTAL/SUMMARY (every leg counted
        # once); the Protocol distribution TABLE lives in the protocol report
        pc[proto]++; if (f) pf[proto]++; else pp[proto]++

        sp = $19
        if (sp == "" || sp == "UNKNOWN") next
        gsub(/\.$/, "", sp)
        # Insert a marker before each known attribute key so both the ssh format
        # ("Cipher: x, MAC: y, ...") and the TLS format ("Protocol: TLSv1.3
        # Cipher suite: z") split into Key/Value chunks.
        gsub(/(Cipher suite|Public Key|Key Exchange|Cipher|MAC|Protocol): /, SUBSEP "&", sp)
        m = split(sp, pairs, SUBSEP)
        for (pi = 1; pi <= m; pi++) {
            seg = trim(pairs[pi]); gsub(/,$/, "", seg)
            ci = index(seg, ": ")
            if (ci <= 0) continue
            key = trim(substr(seg, 1, ci - 1))
            val = trim(substr(seg, ci + 2)); gsub(/,$/, "", val)
            gsub(/[|\t]/, " ", key); gsub(/[|\t]/, " ", val)
            if (key == "" || val == "") continue
            cnt[key SUBSEP val]++; if (f) cf[key SUBSEP val]++; else cp[key SUBSEP val]++
            if (d != "") { cd2[key SUBSEP val SUBSEP d]++; if (f) cfd[key SUBSEP val SUBSEP d]++; else cpd[key SUBSEP val SUBSEP d]++ }
            if (site != "") { sk4 = key SUBSEP val SUBSEP site SUBSEP h; asc[sk4]++; if (f) asf[sk4]++; else asp[sk4]++ }
            addtop("A" SUBSEP key SUBSEP val SUBSEP oc, sk, disp, tid)   # drill: 10 most recent rows per attribute-value + outcome
        }
    }
    END {
        for (k in cd2) { split(k, a, SUBSEP); kk = a[1] SUBSEP a[2]; abk[kk] = abk[kk] (abk[kk] ? "," : "") a[3] ":" cd2[k] ":" (cfd[k]+0) ":" (cpd[k]+0) }
        for (k in pc) printf "PROTO|%s|%d|%d|%d\n", k, pc[k], pf[k]+0, pp[k]+0
        for (kv in cnt) { split(kv, a, SUBSEP); printf "ATTR|%s|%s|%d|%d|%d|%s|%s|%s\n", a[1], a[2], cnt[kv], cf[kv]+0, cp[kv]+0, (abk[kv]==""?"-":abk[kv]), orlist(top["A" SUBSEP a[1] SUBSEP a[2] SUBSEP "F"]), orlist(top["A" SUBSEP a[1] SUBSEP a[2] SUBSEP "P"]) }
        # per-(subscription, host-partner) rows -> the sidecar
        for (k in asc) { split(k, a, SUBSEP); printf "%s|%s|%s|%s|%d|%d|%d\n", a[1], a[2], a[3], a[4], asc[k], asf[k]+0, asp[k]+0 > subout }
    }
' "$FILES" "$PARSED")

if [ -z "$agg" ]; then
    echo "No usable records found." >&2
    exit 0   # empty estate (config-only clone): placeholder page, not a failed build
fi

# Overall totals (every leg is counted once in the protocol counts).
IFS='|' read -r tot_legs tot_failed tot_processed <<< "$(printf '%s\n' "$agg" \
    | awk -F'|' '$1=="PROTO" { c += $3; f += $4; p += $5 } END { printf "%d|%d|%d", c+0, f+0, p+0 }')"

# ---------------------------------------------------------------------------
# Per-value pages: one .rpt per (table, value) listing the SUBSCRIPTIONS that
# used it (site KIND -> its detail page; counts are transfers/legs). Iterated in
# a deterministic sorted order so the collision-bumped slugs are stable. The
# _slugmap.tsv (disc<TAB>value<TAB>slug) is read back when emitting the main
# tables' first-column links. bin/transfer/publish.sh renders these to
# docs/<env>/transfer/secparams/<slug>.html.
#
# Three processes for ALL the pages, not thirteen per page: the planner awk reads
# the sidecar ONCE and streams every page's rows behind a <page index>/<kind>
# prefix, ONE sort puts each page's rows in the order its table wants them, and
# the writer awk opens each .rpt in turn. The prefix fields are constant within a
# page, so the -k5,5nr key and its whole-line tie-break decide exactly what the
# per-page `sort -k3,3nr` used to.
# ---------------------------------------------------------------------------
secdir="$REPORTS_DIR/secparams"
rm -rf "$secdir"; mkdir -p "$secdir"
smap="$secdir/_slugmap.tsv"; : > "$smap"
SPX="$CONFIG_XREF/_subscriptions-partners.tsv"   # subscription -> partner (org/group); usually one
awk -F'|' '{ print $1"|"$2 }' "$subfile" | LC_ALL=C sort -u > "$pairfile"

# The sidecar is written in awk hash order — C-sort it so the row iteration
# below (partner-union first sightings, the Partner display cells) is
# deterministic across awks and runs.
LC_ALL=C sort "$subfile" | awk -F'|' -v pairs="$pairfile" -v spx="$SPX" -v smap="$smap" '
    # slug = lowercase, runs of non-alnum -> "-", trimmed (the site-wide slugify)
    function slugify(s,   t) {
        t = tolower(s)
        gsub(/[^a-z0-9]+/, "-", t)
        sub(/^-+/, "", t); sub(/-+$/, "", t)
        return t
    }
    # roll one subscription row up under a partner of page pi (first sighting
    # remembers the partner, so the emit order below never depends on hash order)
    # NOTE the increments are their own statements: `x SUBSEP ++A[i]` parses as
    # `x (SUBSEP++) A[i]`, which quietly renumbers SUBSEP itself.
    function addp(pi, pname, ac, af, ap,   kk) {
        kk = pi SUBSEP pname
        if (!(kk in PC)) { PC[kk] = 0; PS[kk] = 0; PF[kk] = 0; PP[kk] = 0; PN[pi]++; PL[pi SUBSEP PN[pi]] = pname }
        PS[kk]++; PC[kk] += ac; PF[kk] += af; PP[kk] += ap
    }
    BEGIN {
        # the (disc,value) pairs in their C-sorted order — index i IS the page
        # index, and the collision bump walks them in exactly that order
        while ((getline ln < pairs) > 0) {
            p = index(ln, "|")
            if (p == 0) { d = ln; v = "" } else { d = substr(ln, 1, p - 1); v = substr(ln, p + 1) }
            if (d == "") continue
            NK++; KD[NK] = d; KV[NK] = v; IDX[d SUBSEP v] = NK
        }
        close(pairs)
        while ((getline ln < spx) > 0) { m = split(ln, a, "\t"); if (m >= 2 && a[1] != "" && a[2] != "") part[a[1]] = (part[a[1]] == "" ? a[2] : part[a[1]] SUBSEP a[2]) }
        close(spx)
    }
    { k = $1 SUBSEP $2; if (!(k in IDX)) next
      i = IDX[k]; RN[i]++; RW[i SUBSEP RN[i]] = $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }
    END {
        for (i = 1; i <= NK; i++) {
            d = KD[i]; v = KV[i]
            if (d == "Protocol") { label = "TLS version"; pfx = "tls-version" }
            else                 { label = d;             pfx = slugify(d) }
            base = pfx "-" slugify(v); if (base == pfx "-") base = pfx "-x"
            slug = base; nn = 1
            while (slug in used) { nn++; slug = base "-" nn }
            used[slug] = 1
            printf "%s\t%s\t%s\n", d, v, slug > smap
            printf "%d\t0\t%s\t%s\t%s\n", i, slug, label, v      # page header
            # Rows arrive per (site, host-partner) GROUP: merge them back to one
            # row per SUBSCRIPTION for the first table, and roll the Partners
            # table up over the site-wide UNION attribution — the subscription
            # configured partners (SPX) plus the group host-resolved partner
            # (_files.tsv col 20), deduped per group so a leg never counts
            # twice under one partner.
            m = RN[i] + 0
            split("", SC); split("", SFF); split("", SOK); split("", SHP); split("", SSEEN); split("", SL2); split("", HPSEEN); ns = 0
            for (r = 1; r <= m; r++) {
                split(RW[i SUBSEP r], F, "\t")
                site = F[1]; h = F[2]; c = F[3] + 0; ff = F[4] + 0; ok = F[5] + 0
                if (!(site in SSEEN)) { SSEEN[site] = 1; SL2[++ns] = site }
                SC[site] += c; SFF[site] += ff; SOK[site] += ok
                pl = (site in part) ? part[site] : ""
                if (h != "") {
                    inpl = 0; np = split(pl, pa, SUBSEP)
                    for (j = 1; j <= np; j++) if (pa[j] == h) { inpl = 1; break }
                    if (!inpl) pl = (pl == "" ? h : pl SUBSEP h)
                }
                if (pl == "") addp(i, "(none)", c, ff, ok)
                else { np = split(pl, pa, SUBSEP); for (j = 1; j <= np; j++) addp(i, pa[j], c, ff, ok) }
                # the site row Partner display cell: the union across the site groups
                np = split(pl, pa, SUBSEP)
                for (j = 1; j <= np; j++) { k2 = site SUBSEP pa[j]
                    if (!(k2 in HPSEEN)) { HPSEEN[k2] = 1; SHP[site] = (SHP[site] == "" ? pa[j] : SHP[site] SUBSEP pa[j]) } }
            }
            for (r = 1; r <= ns; r++) {
                site = SL2[r]
                disp = SHP[site]; gsub(SUBSEP, ", ", disp)   # multi-partner -> "A, B" (renders unlinked)
                printf "%d\t1\t%s\t%s\t%d\t%d\t%d\n", i, site, disp, SC[site], SFF[site], SOK[site]
            }
            for (j = 1; j <= PN[i]; j++) { pname = PL[i SUBSEP j]; kk = i SUBSEP pname
                printf "%d\t2\t%s\t%d\t%d\t%d\t%d\n", i, pname, PS[kk], PC[kk], PF[kk], PP[kk] }
        }
        close(smap)
    }
' \
  | sort -t$'\t' -k1,1n -k2,2n -k5,5nr \
  | awk -F'\t' -v secdir="$secdir" -v gen="$(date '+%Y-%m-%d %H:%M:%S')" '
    # close the Subscription table and open the Partners one: the partners on this
    # page (a subscription with >1 partner counts under each; subscriptions with
    # no configured partner -> "(none)")
    function subtotal() {
        printf "TOTAL\tTotal (%d subscription(s))\t\t@{class=num}%d\t@{class=num failed}%d\t@{class=num processed}%d\n", sn, sc, sf, sp > out
        printf "TABLE\tPartners\n" > out
        printf "HEAD\tPartner\tSubscriptions\tTransfers\tError\tOK\n" > out
        printf "KIND\tptn\tnum\tnum\tnumfailed\tnumprocessed\n" > out
        ptbl = 1
    }
    function closepage() {
        if (!ptbl) subtotal()
        printf "TOTAL\tTotal (%d partner(s))\t@{class=num}%d\t@{class=num}%d\t@{class=num failed}%d\t@{class=num processed}%d\n", pn, ps, pc, pf, pp > out
        printf "NOTE\tCounts individual transfers (legs) — security parameters are negotiated per leg. Full period (this page is not date-filtered). Click a subscription or partner to open its detail page. Partners use the site-wide UNION attribution: a leg counts under every partner of its subscription AND under the partner its remote host resolves to, so a subscription with more than one partner is counted under each in the Partners table.\n" > out
        printf "FOOT\tGenerated on %s\n", gen > out
        close(out)
    }
    $2 == 0 {
        if (out != "") closepage()
        out = secdir "/" $3 ".rpt"
        sn = sc = sf = sp = 0; pn = ps = pc = pf = pp = 0; ptbl = 0
        printf "TITLE\tSubscriptions using %s %s\n", $4, $5 > out
        printf "DESC\tSubscriptions that used %s \"%s\" on at least one transfer.\n", $4, $5 > out
        printf "INTRO\tEvery subscription (and its partner) that used **%s: %s** on at least one transfer leg. Counts are transfers (legs), full period.\n", $4, $5 > out
        printf "TABLE\t\n" > out                 # empty heading — the h1 names the page
        printf "HEAD\tSubscription\tPartner\tTransfers\tError\tOK\n" > out
        printf "KIND\tsite\tptn\tnum\tnumfailed\tnumprocessed\n" > out
        next
    }
    $2 == 1 { printf "ROW\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $5, $6, $7 > out
              sn++; sc += $5; sf += $6; sp += $7; next }
    { if (!ptbl) subtotal()
      printf "ROW\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $5, $6, $7 > out
      pn++; ps += $4; pc += $5; pf += $6; pp += $7 }
    END { if (out != "") closepage() }
'

echo "Wrote $(find "$secdir" -name '*.rpt' | wc -l | tr -d ' ') security-param value page(s) to $secdir." >&2

emit_attr() {   # $1 = attribute key
    local key=$1 label=$1
    # The "Protocol" attribute is the TLS version (TLSv1.2/1.3), distinct from the
    # transfer-protocol table above — label it so the two aren't both "Protocol".
    [ "$key" = "Protocol" ] && label="TLS version"
    printf 'TABLE\t\tdrill=transfer\n'          # no title — the first column header names the table
    printf 'HEAD\t%s\tTransfers\tError\tOK\n' "$label"
    printf 'KIND\ttext\tnum\tnumfailed\tnumprocessed\n'
    printf 'RECALC\t-\ts0\ts1\ts2\n'
    printf '%s\n' "$agg" | awk -F'|' -v k="$key" '$1=="ATTR" && $2==k { print $3"\t"$4"\t"$5"\t"$6"\t"$7"\t"$8"\t"$9 }' \
        | sort -t$'\t' -k2,2nr | awk -F'\t' -v smap="$smap" -v d="$key" "$SECROW_AWK"
    # Per-table total: the sum of this attribute's rows (attributes cover only
    # the legs whose SecurityParameters name them, so each table totals its own).
    printf '%s\n' "$agg" | awk -F'|' -v k="$key" '$1=="ATTR" && $2==k { c += $4; f += $5; p += $6 }
        END { printf "TOTAL\tTotal\t@{class=num}%d\t@{class=num failed}%d\t@{class=num processed}%d\n", c+0, f+0, p+0 }'
}

{
    printf 'TITLE\tTransfer Security Parameters\n'
    printf 'DESC\tEvery attribute parsed from the SecurityParameters column, one view per attribute.\n'
    printf 'INTRO\tConnection security by SecurityParameters attribute (TLS version, Cipher, MAC, Key Exchange, Public Key, ...), one view per attribute. Click a value in the first column for the subscriptions that use it.\n'

    # ALWAYS all six attribute tables, in this fixed order — the tab labels in
    # report_tabs are positional, so an attribute with no data still emits its
    # (empty) table to keep the count identical in every env.
    for pk in "Protocol" "Cipher" "Cipher suite" "MAC" "Key Exchange" "Public Key"; do
        emit_attr "$pk"
    done

    printf 'NOTE\tCounts individual transfers (legs), not Files: security parameters are negotiated per leg (the Inbound and Outbound rows use different ciphers/protocols). Error/OK split those transfers by status; click an Error or OK count for that outcome'\''s 10 most recent transfers. Click a value in the first column for the subscriptions that use it.\n'
    printf 'SUMMARY\tTotal transfers: %s  |  Error: %s  |  OK: %s\n' "$tot_legs" "$tot_failed" "$tot_processed"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT." >&2
