# rpt-rollup.awk — an ENTITY view of a one-table .rpt: its rows regrouped per
# Account or Partner (2026-09-30, user request: Partners in / Partners Out get
# the view row "Endpoint · Accounts · Partners" — "Accounts & Partners must
# give the same reports, but now with the Entities Accounts & Partners").
# The source .rpt is the ENDPOINT view (one row per login / host); this pass
# reads it back, so every figure is the Endpoint view's own, summed per entity.
#
# Run (partners-in.sh / partners-out.sh):
#   awk -F'\t' -v MAP=<xref pair file: endpoint TAB entity>
#       -v BASE=<base/_<entity>.tsv, col 3 = the result colour>
#       -v KIND=acct|ptn -v HEADL=Account -v TNAME=Accounts -v NOUN=accounts
#       -v ACTIVE=Accounts -v RULES="<one rule per ROW field from field 3>"
#       -v ORDER="<ROW fields, numeric descending, before the name>"
#       -v DCAP=<drill-cell-* entries kept> -v LCAP=<loglines entries kept>
#       -f bin/rpt-rollup.awk SOURCE.rpt > VIEW.rpt
#
# ATTRIBUTION: an endpoint counts for EVERY entity the configuration pairs it
# with (the site's union rule, like Partner) — a login serving two accounts
# counts for both, so a view's column sum can exceed the Endpoint view's.
# An endpoint the map does not name (a raw address, an old-gateway-only or
# unconfigured login) is in no entity view. `Unknown` is no entity.
#
# RULES (space-separated, one per data cell, the source's ROW field 3 on):
#   sum      the numeric sum; empty when every source cell was empty
#   max/min  the greatest / smallest value that starts with a digit (a
#            stamp); a placeholder ("—", "Never") only when there is no stamp
#   age      the cell with the largest @{sortval=N}, kept whole
#   uc       the union of "/"-joined use cases: UC1..UC4 in order, the rest sorted
#   list     the union of ", "-joined names, sorted, the first cell's @{…} kept
#   stamp    the cell of the source row with the NEWEST drill line (each drill
#            entry leads with its "date time" stamp)
#   best:N   the cell of the source row with the largest ROW field N
#   -        empty
# Drills: every @data:<name>= payload (except res) is the union of the source
# rows' entries (\037-separated, newest first), deduplicated, the newest DCAP
# (drill-cell-*) or LCAP (the rest) kept. Row tint = the entity's result
# colour. TOTAL = the sum columns over the mapped endpoint rows, each counted
# ONCE (the distinct total, like the Entities BL / Partner totals — the rows
# can sum to more), the largest age cell's text; the source TOTAL's cell
# prefixes (@{class=…}, the label's colspan) kept.
function strip(c) { while (index(c, "@{") == 1) sub(/^@\{[^}]*\}/, "", c); return c }
function pfx(c,   p) { p = ""; while (index(c, "@{") == 1 && match(c, /^@\{[^}]*\}/)) { p = p substr(c, 1, RLENGTH); c = substr(c, RLENGTH + 1) } return p }
function stampy(v) { return v ~ /^[0-9]/ }
function num(v) { return sprintf("%.0f", v) }
# a SUBSEP-led set -> sorted, joined with sep
function joined(s, sep,   n, A, i, j, v, o) {
    if (s == "") return ""
    n = split(substr(s, 2), A, SUBSEP)
    for (i = 2; i <= n; i++) { v = A[i]; j = i - 1; while (j >= 1 && A[j] > v) { A[j + 1] = A[j]; j-- } A[j + 1] = v }
    o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? sep : "") A[i]
    return o
}
function addset(key, v) { if (!((key SUBSEP v) in SEEN)) { SEEN[key SUBSEP v] = 1; SET[key] = SET[key] SUBSEP v } }
# entity a before entity b: the ORDER sums descending, then the name
function before(a, b,   i, j, va, vb) {
    for (i = 1; i <= no; i++) { j = OF[i] - 2; va = SUM[a, j] + 0; vb = SUM[b, j] + 0; if (va != vb) return va > vb }
    return ENAME[a] < ENAME[b]
}
BEGIN {
    OFS = "\t"
    nrule = split(RULES, R, " ")
    no = split(ORDER, OF, " ")
    while ((getline l < MAP) > 0) { split(l, a, "\t"); if (a[1] == "" || a[2] == "" || a[2] == "Unknown") continue
        k = toupper(a[1]); if ((k SUBSEP a[2]) in MS) continue
        MS[k SUBSEP a[2]] = 1; M[k] = M[k] SUBSEP a[2] }
    close(MAP)
    while ((getline l < BASE) > 0) { split(l, a, "\t"); if (a[1] != "" && a[3] != "") RES[a[1]] = a[3] }
    close(BASE)
    SPAN = 1
}
$1 == "NAV" {
    for (i = 2; i <= NF; i++) { if ($i == "@sep") continue
        n = split($i, P, "|"); if (n < 3) continue
        st = P[1]; if (P[2] == ACTIVE) st = 1; else if (st == 1) st = 0
        $i = st "|" P[2] "|" P[3] }
    print; next
}
$1 == "TABLE" { $2 = TNAME; print; next }
$1 == "HEAD"  { $2 = HEADL; print; next }
$1 == "KIND"  { $2 = KIND; print; next }
$1 == "FOOT"  { next }
$1 == "TOTAL" {
    LBP = pfx($2); if (match(LBP, /colspan=[0-9]+/)) SPAN = substr(LBP, RSTART + 8, RLENGTH - 8) + 0
    for (i = 3; i <= NF; i++) TP[i + SPAN - 1] = pfx($i)
    next
}
$1 != "ROW" { print; next }
{
    k = toupper(strip($2))
    if (!(k in M)) { dropped++; next }
    # the row's drills and its newest drill stamp
    newest = ""; na = 0
    for (i = 3 + nrule; i <= NF; i++) { if (index($i, "@data:") != 1) continue
        p = index($i, "="); if (p == 0) continue
        an = substr($i, 7, p - 7); if (an == "res") continue
        v = substr($i, p + 1); if (v == "") continue
        na++; AN9[na] = an; AV9[na] = v
        m = split(v, E9, "\037"); for (j = 1; j <= m; j++) if (E9[j] != "" && substr(E9[j], 1, 23) > newest) newest = substr(E9[j], 1, 23) }
    # the TOTAL counts every mapped endpoint row ONCE (the distinct total)
    for (j = 1; j <= nrule; j++) if (R[j] == "sum") { s = strip($(j + 2)); if (s != "") { TS[j] += s; THAS[j] = 1 } }
    ns = split(substr(M[k], 2), EN, SUBSEP)
    for (e = 1; e <= ns; e++) {
        if (!(EN[e] in EI)) { EI[EN[e]] = ++ne; ENAME[ne] = EN[e] }
        x = EI[EN[e]]
        for (j = 1; j <= nrule; j++) { v = $(j + 2); s = strip(v); r = R[j]
            if (r == "sum") { if (s != "") { SUM[x, j] += s; HAS[x, j] = 1 } }
            else if (r == "max" || r == "min") { if (s == "") continue
                cur = V[x, j]
                if (cur == "" || (stampy(s) && (!stampy(cur) || (r == "max" ? s > cur : s < cur)))) V[x, j] = s }
            else if (r == "age") { if (s == "") continue
                g = -1; if (match(v, /sortval=[0-9]+/)) g = substr(v, RSTART + 8, RLENGTH - 8) + 0
                if (!((x, j) in AGE) || g > AGE[x, j]) { AGE[x, j] = g; V[x, j] = v } }
            else if (r == "uc") { if (s == "") continue
                m = split(s, U9, "/"); for (i = 1; i <= m; i++) if (U9[i] != "") addset(x SUBSEP j, U9[i]) }
            else if (r == "list") { if (s == "") continue
                if (!((x, j) in LP)) LP[x, j] = pfx(v)
                m = split(s, U9, ", "); for (i = 1; i <= m; i++) if (U9[i] != "") addset(x SUBSEP j, U9[i]) }
            else if (r == "stamp") { if (s == "" && newest == "") continue
                if (!((x, j) in BS) || newest > BS[x, j] || (newest == BS[x, j] && s > strip(V[x, j]))) { BS[x, j] = newest; V[x, j] = v } }
            else if (substr(r, 1, 5) == "best:") { f = substr(r, 6) + 0; bv = strip($f) + 0
                if (!((x, j) in BK) || bv > BK[x, j]) { BK[x, j] = bv; V[x, j] = v } }
        }
        for (i = 1; i <= na; i++) { an = AN9[i]
            if (!((x SUBSEP an) in AHAS)) { AHAS[x SUBSEP an] = 1; ALIST[x] = ALIST[x] SUBSEP an }
            m = split(AV9[i], E9, "\037")
            for (j = 1; j <= m; j++) if (E9[j] != "" && !((x SUBSEP an SUBSEP E9[j]) in DSEEN)) {
                DSEEN[x SUBSEP an SUBSEP E9[j]] = 1; DN[x, an]++; DE[x, an, DN[x, an]] = E9[j] } }
    }
}
END {
    for (i = 1; i <= ne; i++) ORD[i] = i
    for (i = 2; i <= ne; i++) { v = ORD[i]; j = i - 1; while (j >= 1 && before(v, ORD[j])) { ORD[j + 1] = ORD[j]; j-- } ORD[j + 1] = v }
    for (o = 1; o <= ne; o++) { x = ORD[o]; nm = ENAME[x]
        line = "ROW\t" (substr(nm, 1, 1) == "@" ? "@{}" nm : nm)
        for (j = 1; j <= nrule; j++) { r = R[j]; c = ""
            if (r == "sum") { if ((x, j) in HAS) c = num(SUM[x, j]) }
            else if (r == "uc") {
                s = SET[x SUBSEP j]
                for (u = 1; u <= 4; u++) if ((x SUBSEP j SUBSEP "UC" u) in SEEN) c = c (c == "" ? "" : "/") "UC" u
                X9 = ""; if (s != "") { m = split(substr(s, 2), U9, SUBSEP); for (i = 1; i <= m; i++) if (U9[i] !~ /^UC[1-4]$/) X9 = X9 SUBSEP U9[i] }
                if (X9 != "") c = c (c == "" ? "" : "/") joined(X9, "/") }
            else if (r == "list") { s = joined(SET[x SUBSEP j], ", "); if (s != "") c = LP[x, j] s }
            else if (r != "-") c = V[x, j]
            if (r == "age" && ((x, j) in AGE) && (!(j in TAGE) || AGE[x, j] > TAGE[j])) { TAGE[j] = AGE[x, j]; TAGV[j] = strip(V[x, j]) }
            line = line "\t" c }
        if (nm in RES) line = line "\t@data:res=" RES[nm]
        na = split(substr(ALIST[x], 2), A9, SUBSEP)
        for (i = 1; i <= na; i++) { an = A9[i]; m = DN[x, an]
            for (j = 1; j <= m; j++) T9[j] = DE[x, an, j]
            for (j = 2; j <= m; j++) { v = T9[j]; k2 = j - 1; while (k2 >= 1 && T9[k2] < v) { T9[k2 + 1] = T9[k2]; k2-- } T9[k2 + 1] = v }
            cap = (an ~ /^drill-cell-/) ? DCAP + 0 : LCAP + 0
            d = ""; for (j = 1; j <= m && j <= cap; j++) d = d (j > 1 ? "\037" : "") T9[j]
            line = line "\t@data:" an "=" d }
        print line }
    line = "TOTAL\t" LBP "Total (" ne " " NOUN ")"
    for (j = SPAN; j <= nrule; j++) { r = R[j]; c = ""
        if (r == "sum" && (j in THAS)) c = num(TS[j])
        else if (r == "age" && (j in TAGV)) c = TAGV[j]
        line = line "\t" TP[j + 2] c }
    print line
    print "FOOT"
    printf "%d\t%d\n", ne, dropped + 0 > "/dev/stderr"
}
