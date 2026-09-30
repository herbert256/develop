# bin/cadence.awk — the PICKUP-PATTERN vocabulary, ONE copy (2026-09-30, the
# lean round) for bin/analyses/reports/uc2-status.sh (Pickup information) and
# bin/logons.sh (the detail pages' Logons pattern) — the two speak one
# vocabulary. Injected as "$CADENCE_AWK" (bin/awklib.sh; needs $AWKLIB's
# qsortn in the same program). Function-only.

# the label of a median gap in MINUTES (never an em dash, 2026-09-03)
function patron(m,   n) {
    if (m <= 0)   return "Rarely"
    if (m <= 2)   return "Continuous"
    if (m < 58)   { n = int((m + 2.5) / 5) * 5; if (n < 5) n = 5; return "Every " n " minutes" }
    if (m <= 75)  return "Hourly"
    if (m < 1320) { n = int((m + 30) / 60); return (n <= 1) ? "Hourly" : "Every " n " hours" }
    n = int((m + 720) / 1440)
    if (n <= 1)   return "Daily"
    if (n >= 6 && n <= 8) return "Weekly"
    if (n <= 15)  return "Every " n " days"
    return "Rarely"
}
# a REGULAR spread: at least 60 % of the gaps within half / double the median
function regspread(A, ng, med,   g9, w9) {
    w9 = 0; for (g9 in A) if (g9 + 0 >= med / 2 && g9 + 0 <= med * 2) w9 += A[g9]
    return (ng > 0 && w9 * 10 >= ng * 6) }
# the pattern label: the median's label, "Irregular" when the spread is not
function label(med, A, ng,   l9) {
    l9 = patron(med); if (l9 != "Rarely" && !regspread(A, ng, med)) return "Irregular"
    return l9 }
