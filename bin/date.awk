# bin/date.awk — the calendar helpers, ONE copy (2026-09-30, the lean round:
# jdn / fromjdn were pasted into ~30 awk programs). Function-only; injected
# as "$AWKLIB" (bin/awklib.sh) in front of a program's text — a program that
# injects it must not define these names itself (mawk rejects a function
# defined twice).

# the Julian day number of a calendar date (Fliegel & Van Flandern)
function jdn(y, m, d,   a) { a = int((14 - m) / 12); y = y + 4800 - a; m = m + 12 * a - 3
    return d + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045 }

# the ISO date ("ccyy-mm-dd") of a Julian day number
function fromjdn(j,   a, b, c, dd, e, mm, day, mon, yr) { a = j + 32044; b = int((4 * a + 3) / 146097)
    c = a - int(146097 * b / 4); dd = int((4 * c + 3) / 1461); e = c - int(1461 * dd / 4)
    mm = int((5 * e + 2) / 153); day = e - int((153 * mm + 2) / 5) + 1; mon = mm + 3 - 12 * int(mm / 10)
    yr = 100 * b + dd - 4800 + int(mm / 10); return sprintf("%04d-%02d-%02d", yr, mon, day) }

# the minute number of an ISO date + "hh:mm…" time (day number × 1440 + minutes)
# (a ONE-ENTRY cache of the last date's day number, 2026-09-30: the callers
# walk chronological data, so the jdn() arithmetic runs once per DATE, not per
# line — exact, the same integer either way; _MOFS marks the cache as set, and
# the comparison is forced to a STRING one: an empty date on the first call
# would otherwise equal the uninitialised cache and skip the jdn())
function minof(d, t) { if (!_MOFS || (d "") != _MOFD) { _MOFS = 1; _MOFD = d ""; _MOFJ = jdn(substr(d, 1, 4) + 0, substr(d, 6, 2) + 0, substr(d, 9, 2) + 0) * 1440 }
    return _MOFJ + substr(t, 1, 2) * 60 + substr(t, 4, 2) + 0 }
