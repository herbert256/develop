# bin/fmt.awk — the shared cell formatters, ONE copy each (2026-09-30, the lean
# round). Function-only; injected as "$AWKLIB" (bin/awklib.sh). Each is a
# NAMED variant — a caller picks the exact output it always had; a program
# that injects the lib must not define these names itself.

# bytes, the report.js humanBytes twin: "123 B", then two decimals KB … PB
function hbytes2(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
    while (v >= 1024 && i < 6) { v /= 1024; i++ }
    return (i == 1) ? sprintf("%d %s", v, u[i]) : sprintf("%.2f %s", v, u[i]) }
# bytes in WHOLE units (the Entities views, report.js humanBytesInt)
function hbytes0(b,   u, i, v) { split("B KB MB GB TB PB", u, " "); i = 1; v = b + 0
    while (v >= 1024 && i < 6) { v /= 1024; i++ }
    return sprintf("%.0f %s", v, u[i]) }
# bytes with ONE decimal, B … GB
function hbytes1(b) { if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824)
    if (b >= 1048576) return sprintf("%.1f MB", b / 1048576)
    if (b >= 1024) return sprintf("%.1f KB", b / 1024)
    return b " B" }

# a RAW value that can begin with "@" (a file name) stays literal behind the
# empty attribute block (the 2026-09-29 audit F07 rule for .rpt writers)
function lit(s) { return (substr(s, 1, 1) == "@") ? "@{}" s : s }

# HTML text / attribute escaping (& < > ")
function html_esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }

# a slug: lowercase, every non-[a-z0-9] run one "-", no leading / trailing
# "-" (the awk twin of publish_lib's bash slugify; "" stays "")
function slugof(s,   t) { t = tolower(s); gsub(/[^a-z0-9]+/, "-", t); sub(/^-+/, "", t); sub(/-+$/, "", t); return t }

# a duration in ms: "N ms", then two decimals s, one decimal min, two decimals h
function hdurms(ms) { if (ms < 1000) return sprintf("%d ms", ms)
    if (ms < 60000) return sprintf("%.2f s", ms / 1000)
    if (ms < 3600000) return sprintf("%.1f min", ms / 60000)
    return sprintf("%.2f h", ms / 3600000) }
# a gap in SECONDS: "N s" below 90 s, then whole min, one decimal h (below 2 d), one decimal d
function hdsecs(s) { if (s < 90) return sprintf("%d s", s)
    if (s < 5400) return sprintf("%.0f min", s / 60)
    if (s < 172800) return sprintf("%.1f h", s / 3600)
    return sprintf("%.1f d", s / 86400) }

# qsortn(A, lo, hi): A[lo..hi] ascending, numerically (an in-place quicksort,
# the smaller half recursed — bounded stack)
function qsortn(A, lo, hi,   i, j, p, t) {
    while (lo < hi) {
        i = lo; j = hi; p = A[int((lo + hi) / 2)]
        while (i <= j) { while (A[i] < p) i++; while (A[j] > p) j--; if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- } }
        if (j - lo < hi - i) { if (lo < j) qsortn(A, lo, j); lo = i } else { if (i < hi) qsortn(A, i, hi); hi = j }
    }
}
