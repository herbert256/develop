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
# (table, value) into data/transfer/reports/secparams/<slug>.rpt, rendered
# to docs/transfer/secparams/<slug>.html by bin/transfer/publish.sh.
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
    { bk = ($5 == "-") ? "" : $5
      lk = ($1 in sl) ? "@{href=secparams/" sl[$1] ".html}" : ""
      # TRANSFERS = the OK legs ($4) — one column, no Error / OK pair, no
      # green/red cells, no drills (2026-09-13, user request); headed "OK
      # transfers" since 2026-09-30
      printf "ROW\t%s\t%s%s\t%s\t@data:buckets=%s\n", lbl, lk, $1, $4, bk }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
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

# ONE pass over the shared parse cache (6=site, 10=protocol, 19=secparams raw)
# for BOTH security reports (2026-09-30, the lean round — security-outreach.sh
# re-read _files + _transfers with the same attribute split): the
# SecurityParameters string is split into Key/Value chunks ONCE per leg and
# feeds this report's value counts and the outreach lists
# (bin/transfer/reports/security-outreach.sh, called below as the writer).
# Emits (stdout):  PROTO|protocol|count...   and   ATTR|key|value|count...
# Emits (subfile): the per-subscription rows above.
# Emits (oaggf):   the outreach lines D1 / D2 / D3 / T (see security-outreach.sh)
SPX="$CONFIG_XREF/_subscriptions-partners.tsv"   # subscription -> partner (the outreach UNION attribution)
oaggf="$REPORTS_DIR/.secparams-outreach.$$"
: > "$oaggf"
trap 'rm -f "$subfile" "$pairfile" "$oaggf"' EXIT
agg=$(awk -F'\t' -v subout="$subfile" -v spx="$SPX" -v oagg="$oaggf" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function label(a) { return (a == "Protocol") ? "TLS version" : a }
    BEGIN {
        # the outreach: the two DEPRECATED values, tracked with the other
        # values of their attribute (the old -> new pairs)
        dep["Public Key" SUBSEP "ssh-rsa"] = 1
        dep["Protocol" SUBSEP "TLSv1.2"]   = 1
        want["Public Key"] = 1; want["Protocol"] = 1
        while ((getline _l < spx) > 0) { split(_l, _a, "\t")
            if (_a[1] != "" && _a[2] != "") { _k = toupper(_a[1]); spm[_k] = (spm[_k] == "" ? _a[2] : spm[_k] SUBSEP _a[2]) } }   # case-folded like sp_union (2026-09-29 audit)
        close(spx)
    }
    # file 1 = $FILES: the per-CoreId host-resolved partner (col 20, filled at
    # parse time via _hosts-partners.tsv, else the account org; empty when the
    # parse abstained) — the OTHER half of the site-wide PARTNER UNION
    FNR == NR { if ($20 != "") { hpv = $20; gsub(/[|\t]/, " ", hpv); hp[$1] = hpv } next }
    { if ($14 + 0 > maxj) { maxj = $14 + 0; maxdate = $11 } }   # the outreach window end (every leg)
    {
        st = $3; sub(/ Subtransmission$/, "", st); f = (st != "Processed")
        proto = $10; if (proto == "") proto = "UNKNOWN"
        d = $11
        site = $6; gsub(/[|\t]/, " ", site)
        # the Unknown subscription (and a siteless leg) is no subscription: its
        # legs stay in the SUMMARY (the protocol counts below) but out of the
        # value counts, which must equal the Total of the per-value page each
        # value cell opens (2026-09-30 audit T-01: TLSv1.3 6840 vs 6735)
        unk = (site == "" || site == "Unknown")
        h = ($1 in hp) ? hp[$1] : ""   # this leg CoreId host-resolved partner
        # protocol counts feed only the page TOTAL/SUMMARY (every leg counted
        # once); the Protocol distribution TABLE lives in the protocol report
        pc[proto]++; if (f) pf[proto]++; else pp[proto]++

        spv = $19
        if (spv == "" || spv == "UNKNOWN") next
        doP = !unk; doO = ($11 != "")      # this report / the outreach (every dated leg, Unknown included)
        if (!doP && !doO) next
        if (doO) {
            # (NOT the shared sp_union of bin/pda-union.sh: this union is per
            # LEG — the leg own subscription, _transfers col 6, not the File
            # col 12 — keyed on the EXACT spelling, and "(none)" books the
            # unattributed) the outreach partner UNION for this leg: the
            # subscription configured partners plus the CoreId host-resolved
            # one, deduped
            pl = (toupper($6) in spm) ? spm[toupper($6)] : ""
            if (h != "") { inp = 0; np = split(pl, pa, SUBSEP)
                for (j = 1; j <= np; j++) if (pa[j] == h) { inp = 1; break }
                if (!inp) pl = (pl == "" ? h : pl SUBSEP h) }
            if (pl == "") pl = "(none)"
            np = split(pl, pa, SUBSEP)
        }
        gsub(/\.$/, "", spv)
        # Insert a marker before each known attribute key so both the ssh format
        # ("Cipher: x, MAC: y, ...") and the TLS format ("Protocol: TLSv1.3
        # Cipher suite: z") split into Key/Value chunks.
        gsub(/(Cipher suite|Public Key|Key Exchange|Cipher|MAC|Protocol): /, SUBSEP "&", spv)
        m = split(spv, pairs, SUBSEP)
        for (pi = 1; pi <= m; pi++) {
            seg = trim(pairs[pi]); gsub(/,$/, "", seg)
            ci = index(seg, ": ")
            if (ci <= 0) continue
            key = trim(substr(seg, 1, ci - 1))
            val = trim(substr(seg, ci + 2)); gsub(/,$/, "", val)
            gsub(/[|\t]/, " ", key); gsub(/[|\t]/, " ", val)
            if (key == "" || val == "") continue
            if (doP) {
                cnt[key SUBSEP val]++; if (f) cf[key SUBSEP val]++; else cp[key SUBSEP val]++
                if (d != "") { cd2[key SUBSEP val SUBSEP d]++; if (f) cfd[key SUBSEP val SUBSEP d]++; else cpd[key SUBSEP val SUBSEP d]++ }
                sk4 = key SUBSEP val SUBSEP site SUBSEP h; asc[sk4]++; if (f) asf[sk4]++; else asp[sk4]++
            }
            if (doO && (key in want)) {
                for (j = 1; j <= np; j++) { pt = pa[j]
                    k = pt SUBSEP key SUBSEP val
                    if (C[k] == "") {                              # EMPTINESS, not membership (mawk LHS trap)
                        pak = pt SUBSEP key
                        if (PAV[pak] == "") PAL[++npa] = pak
                        PAV[pak] = (PAV[pak] == "" ? val : PAV[pak] SUBSEP val)
                        FD[k] = $11; LD[k] = $11; LJ[k] = $14 + 0
                    }
                    C[k]++
                    if ($11 < FD[k]) FD[k] = $11
                    if ($11 > LD[k]) { LD[k] = $11; LJ[k] = $14 + 0 }
                }
            }
        }
    }
    END {
        for (k in cd2) { split(k, a, SUBSEP); kk = a[1] SUBSEP a[2]; abk[kk] = abk[kk] (abk[kk] ? "," : "") a[3] ":" cd2[k] ":" (cfd[k]+0) ":" (cpd[k]+0) }
        for (k in pc) printf "PROTO|%s|%d|%d|%d\n", k, pc[k], pf[k]+0, pp[k]+0
        # (the two drill lists per value went 2026-09-30: no drill since 2026-09-13)
        for (kv in cnt) { split(kv, a, SUBSEP); printf "ATTR|%s|%s|%d|%d|%d|%s\n", a[1], a[2], cnt[kv], cf[kv]+0, cp[kv]+0, (abk[kv]==""?"-":abk[kv]) }
        # per-(subscription, host-partner) rows -> the sidecar
        for (k in asc) { split(k, a, SUBSEP); printf "%s|%s|%s|%s|%d|%d|%d\n", a[1], a[2], a[3], a[4], asc[k], asf[k]+0, asp[k]+0 > subout }
        # ---- the OUTREACH lines (security-outreach.sh writes the page) ----
        #   D1|legs|partner|param|first|last              still using (last 7 days)
        #   D2|partner|param_old|new_val|oldlast|newfirst|cut   cut = date | mixed
        #   D3|param|nstill|npartners|legs|newest         one per deprecated value
        #   T|maxdate|cutoffdate
        cutoff = maxj - 6                                     # "still using" = seen in the last 7 days
        for (i = 1; i <= npa; i++) {
            split(PAL[i], q, SUBSEP); pt = q[1]; oa = q[2]
            nv = split(PAV[PAL[i]], vs, SUBSEP)
            for (vi = 1; vi <= nv; vi++) {
                v = vs[vi]
                if (!((oa SUBSEP v) in dep)) continue
                k = pt SUBSEP oa SUBSEP v
                dk = oa SUBSEP v
                d3n[dk]++; d3l[dk] += C[k]
                if (LD[k] > d3d[dk]) d3d[dk] = LD[k]
                if (LJ[k] >= cutoff) { d3s[dk]++
                    printf "D1|%d|%s|%s: %s|%s|%s\n", C[k], pt, label(oa), v, FD[k], LD[k] > oagg }
                # the old -> new pairs: every OTHER value of the same attribute
                for (wi = 1; wi <= nv; wi++) {
                    if (wi == vi) continue
                    w = vs[wi]
                    if ((oa SUBSEP w) in dep) continue
                    k2 = pt SUBSEP oa SUBSEP w
                    cut = (FD[k2] >= LD[k]) ? FD[k2] : "mixed"
                    printf "D2|%s|%s: %s|%s|%s|%s|%s\n", pt, label(oa), v, w, LD[k], FD[k2], cut > oagg
                }
            }
        }
        n3 = split("Public Key" SUBSEP "ssh-rsa" SUBSEP "Protocol" SUBSEP "TLSv1.2", t3, SUBSEP)
        for (i = 1; i <= n3; i += 2) { dk = t3[i] SUBSEP t3[i+1]
            printf "D3|%s: %s|%d|%d|%d|%s\n", label(t3[i]), t3[i+1], d3s[dk]+0, d3n[dk]+0, d3l[dk]+0, (d3d[dk] == "" ? "-" : d3d[dk]) > oagg }
        printf "T|%s|%s\n", maxdate, (cutoff > 0 ? "last 7 days" : "-") > oagg
        close(oagg)
    }
' "$FILES" "$PARSED")

# the outreach page (security-outreach.sh is its WRITER since 2026-09-30 —
# written before the empty-estate exit below: it always renders its tables)
"$SCRIPT_DIR/security-outreach.sh" "$oaggf"

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
# docs/transfer/secparams/<slug>.html.
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
LC_ALL=C sort "$subfile" | awk -F'|' -v pairs="$pairfile" -v spx="$SPX" -v smap="$smap" "$AWKLIB"'
    # slug = lowercase, runs of non-alnum -> "-", trimmed: slugof() of bin/fmt.awk (the site-wide slugify)
    # roll one subscription row up under a partner of page pi (first sighting
    # remembers the partner, so the emit order below never depends on hash order)
    # NOTE the increments are their own statements: `x SUBSEP ++A[i]` parses as
    # `x (SUBSEP++) A[i]`, which quietly renumbers SUBSEP itself.
    function addp(pi, pname, ac, af, ap, st,   kk) {
        kk = pi SUBSEP pname
        if (!(kk in PC)) { PC[kk] = 0; PS[kk] = 0; PF[kk] = 0; PP[kk] = 0; PN[pi]++; PL[pi SUBSEP PN[pi]] = pname }
        # a subscription counts ONCE per partner — one per host row double
        # counted a subscription seen on two hosts (2026-09-28 fix)
        if (!((kk SUBSEP st) in PSS)) { PSS[kk SUBSEP st] = 1; PS[kk]++ }
        PC[kk] += ac; PF[kk] += af; PP[kk] += ap
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
        while ((getline ln < spx) > 0) { m = split(ln, a, "\t"); if (m >= 2 && a[1] != "" && a[2] != "") { k9 = toupper(a[1]); part[k9] = (part[k9] == "" ? a[2] : part[k9] SUBSEP a[2]) } }   # case-folded like every other partner-union consumer
        close(spx)
    }
    { k = $1 SUBSEP $2; if (!(k in IDX)) next
      i = IDX[k]; RN[i]++; RW[i SUBSEP RN[i]] = $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }
    END {
        for (i = 1; i <= NK; i++) {
            d = KD[i]; v = KV[i]
            if (d == "Protocol") { label = "TLS version"; pfx = "tls-version" }
            else                 { label = d;             pfx = slugof(d) }
            base = pfx "-" slugof(v); if (base == pfx "-") base = pfx "-x"
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
                # (NOT the shared sp_union of bin/pda-union.sh: the key is the
                # per-LEG site of the group, the configured partners come FIRST
                # — the Partner display cell order — and "(none)" books the
                # unattributed legs)
                pl = (toupper(site) in part) ? part[toupper(site)] : ""
                if (h != "") {
                    inpl = 0; np = split(pl, pa, SUBSEP)
                    for (j = 1; j <= np; j++) if (pa[j] == h) { inpl = 1; break }
                    if (!inpl) pl = (pl == "" ? h : pl SUBSEP h)
                }
                if (pl == "") addp(i, "(none)", c, ff, ok, site)
                else { np = split(pl, pa, SUBSEP); for (j = 1; j <= np; j++) addp(i, pa[j], c, ff, ok, site) }
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
  | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k7,7nr \
  | awk -F'\t' -v secdir="$secdir" '
    # close the Subscription table and open the Partners one: the partners on this
    # page (a subscription with >1 partner counts under each; subscriptions with
    # no configured partner -> "(none)")
    function subtotal() {
        printf "TOTAL\tTotal (%d subscription(s))\t\t@{class=num}%d\n", sn, sp > out
        printf "TABLE\tPartners\n" > out
        printf "HEAD\tPartner\tSubscriptions\tOK transfers\n" > out
        printf "KIND\tptn\tnum\tnum\n" > out
        ptbl = 1
    }
    function closepage() {
        if (!ptbl) subtotal()
        printf "TOTAL\tTotal (%d partner(s))\t@{class=num}%d\t@{class=num}%d\n", pn, ps, pp > out
        printf "NOTE\tCounts individual OK transfers (legs) — security parameters are negotiated per leg. Full period (this page is not date-filtered). Click a subscription or partner to open its detail page. Partners use the site-wide UNION attribution: a leg counts under every partner of its subscription AND under the partner its remote host resolves to, so a subscription with more than one partner is counted under each in the Partners table.\n" > out
        printf "FOOT\n" > out
        close(out)
    }
    $2 == 0 {
        if (out != "") closepage()
        out = secdir "/" $3 ".rpt"
        sn = sc = sf = sp = 0; pn = ps = pc = pf = pp = 0; ptbl = 0
        printf "TITLE\tSubscriptions using %s %s\n", $4, $5 > out
        printf "INTRO\tEvery subscription (and its partner) that used **%s: %s** on at least one transfer leg. Counts are OK transfers (legs), full period.\n", $4, $5 > out
        printf "TABLE\t\n" > out                 # empty heading — the h1 names the page
        printf "HEAD\tSubscription\tPartner\tOK transfers\n" > out
        printf "KIND\tsite\tptn\tnum\n" > out
        next
    }
    $2 == 1 { printf "ROW\t%s\t%s\t%s\n", $3, $4, $7 > out
              sn++; sc += $5; sf += $6; sp += $7; next }
    { if (!ptbl) subtotal()
      printf "ROW\t%s\t%s\t%s\n", $3, $4, $7 > out
      pn++; ps += $4; pc += $5; pf += $6; pp += $7 }
    END { if (out != "") closepage() }
'

echo "Wrote $(find "$secdir" -name '*.rpt' | wc -l | tr -d ' ') security-param value page(s) to $secdir." >&2

# ONE table (2026-09-29: the six one-attribute tabs of two or three rows each
# went): Attribute | Value | Transfers, the attributes in a fixed order, each
# attribute's values busiest first. A leg counts once per attribute, so the
# Transfers column does not add across attributes (noagg — a search on one
# attribute re-totals it).
emit_attr_rows() {   # $1 = attribute key
    local key=$1 label=$1
    # The "Protocol" attribute is the TLS version (TLSv1.2/1.3), distinct from the
    # transfer-protocol report — label it so the two aren't both "Protocol".
    [ "$key" = "Protocol" ] && label="TLS version"
    # TRANSFERS = the OK legs (2026-09-13, user request: one Transfers column,
    # no Error / OK pair, no green/red cells, no drills); the bucket payload
    # keeps its metrics, so the token reads metric 2 (ok); rows sort by it
    printf '%s\n' "$agg" | awk -F'|' -v k="$key" '$1=="ATTR" && $2==k { print $3"\t"$4"\t"$5"\t"$6"\t"$7 }' \
        | LC_ALL=C sort -t$'\t' -k4,4nr | awk -F'\t' -v smap="$smap" -v d="$key" -v lbl="$label" "$SECROW_AWK"
}

{
    printf 'TITLE\tSecurity Parameters\n'   # = its Reports menu label (2026-09-29)
    printf 'DESC\tEvery attribute parsed from the SecurityParameters column — TLS version, cipher, cipher suite, MAC, key exchange, public key — in one table.\n'
    printf 'TABLE\t\tnoagg=2\n'
    printf 'HEAD\tAttribute\tValue\tOK transfers\n'
    printf 'KIND\ttext\ttext\tnum\n'
    printf 'RECALC\t-\t-\ts2\n'
    for pk in "Protocol" "Cipher" "Cipher suite" "MAC" "Key Exchange" "Public Key"; do
        emit_attr_rows "$pk"
    done
    printf 'TOTAL\t@{colspan=2}Total\t\n'
    printf 'SUMMARY\tTotal transfers: %s  |  Error: %s  |  OK: %s\n' "$tot_legs" "$tot_failed" "$tot_processed"
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT." >&2
