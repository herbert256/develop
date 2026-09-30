# rpt-tint.awk — give the named TABLEs of a finished .rpt the ENTITY's result
# colour as their row tint (2026-09-30 audit A2-03, the site rule "every row
# tints by the ENTITY's result colour"): the TABLE line gains `restint`, every
# ROW of it whose entity cell names a configured entity gains
# `@data:res=<colour>` (base cache col 3); a row that already carries a
# @data:res, names no configured entity or no colour stays as it is.
#
# Run (a writer, on its own $OUT.tmp before the mv):
#   awk -F'\t' -v TABLES="<table name>[|<table name>…]" -v BASE=<base/_<entity>.tsv> \
#       -v COL=<ROW field of the entity name, 2 = the first cell> \
#       -f bin/rpt-tint.awk in.rpt > out.rpt
# Names match case-insensitively after the cell's leading @{…} blocks are
# stripped (a lit()-guarded @{} included).
function strip(c) { while (index(c, "@{") == 1) sub(/^@\{[^}]*\}/, "", c); return c }
BEGIN {
    OFS = "\t"
    n = split(TABLES, T, "|"); for (i = 1; i <= n; i++) WANT[T[i]] = 1
    while ((getline l < BASE) > 0) { split(l, a, "\t"); if (a[1] != "" && a[3] != "") RES[toupper(a[1])] = a[3] }
    close(BASE)
    if (COL + 0 < 2) COL = 2
}
$1 == "TABLE" { on = ($2 in WANT); if (on && $0 !~ /\trestint(\t|$)/) $0 = $0 "\trestint"; print; next }
on && $1 == "ROW" && $0 !~ /\t@data:res=/ {
    k = toupper(strip($(COL + 0)))
    if (k in RES) $0 = $0 "\t@data:res=" RES[k]
}
{ print }
