# bin/sample/prelude.awk — shared helpers for the sample-data generator.
# Included FIRST on every generator awk command line:
#     awk -f bin/sample/prelude.awk -f bin/sample/<stage>.awk ...
#
# DETERMINISM: the generator never calls awk's own srand()/rand() — their
# stream is implementation-defined and this repo deliberately swaps awks
# (bin/fastawk.sh routes to mawk when installed, BSD awk otherwise). Instead
# a hand-rolled MINSTD Lehmer PRNG (Schrage's method, all-integer below 2^31,
# exact in every awk's doubles) gives one identical stream everywhere, and
# every entity re-seeds its own stream from a string hash of its stable key —
# adding a flow or scenario never shifts an unrelated flow's output, so a
# regeneration diff stays reviewable.

# ---- PRNG -------------------------------------------------------------------
# srnd WARMS UP the stream: MINSTD's first draw from seed s is (16807*s)/M,
# so two ADJACENT seeds (a per-day hash differs by 1 in its last character)
# would give first draws ~8e-6 apart — every first-draw decision came out
# flow-constant across days until the warm-up decorrelated them.
function srnd(s,   i) {
    s = int(s); s = s % 2147483646; if (s < 0) s += 2147483646; RSEED = s + 1
    for (i = 0; i < 5; i++) rnd()
}
function rnd(   hi, lo) {
    hi = int(RSEED / 127773); lo = RSEED % 127773
    RSEED = 16807 * lo - 2836 * hi
    if (RSEED <= 0) RSEED += 2147483647
    return RSEED / 2147483647
}
function rint(n) { return int(rnd() * n) }                  # 0 .. n-1
function rexp(mean) { return -mean * log(1 - rnd()) }       # exponential noise
function rpick(s,   a, n) { n = split(s, a, " "); return a[1 + rint(n)] }

# djb2 over an explicit char->code table (awk has no ord()); the table is the
# character's position in CSET, which is stable by construction. The global
# SEED (awk -v SEED=..., default 42 via generate.sh) is folded into every
# hash, so one knob re-rolls the whole estate.
function hash(s,   i, h, c) {
    s = SEED "|" s
    h = 5381
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        h = (h * 33 + (c in CODE ? CODE[c] : 7)) % 2147483647
    }
    return h
}

# ---- calendar ---------------------------------------------------------------
function jdn(y, m, d,   a) { a = int((14-m)/12); y = y+4800-a; m = m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
function iso2jdn(d) { return jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) }
# absolute ms since jdn 0 midnight -> "MM/DD/YYYY HH:MM:SS.mmm". The abs value
# is ~2e14; NEVER printf %d it whole on a 32-bit-int awk — split day/ms first.
function fmt_ts(abs,   j, ms, d) {
    j = int(abs / 86400000); ms = abs - j * 86400000
    d = fromjdn(j)
    return sprintf("%s/%s/%s %02d:%02d:%02d.%03d", substr(d,6,2), substr(d,9,2), substr(d,1,4), int(ms/3600000), int(ms/60000)%60, int(ms/1000)%60, ms%1000)
}
function abs_iso(abs) { return fromjdn(int(abs / 86400000)) }
function abs_mmdd(abs,   d) { d = abs_iso(abs); return substr(d,6,2) "-" substr(d,9,2) }
# duration ms -> the export's humanized form. Must round-trip parse.sh
# dur_ms(): a string containing "ms" must be EXACTLY "^[0-9]+ ms$", so the
# compound forms never mention ms.
function humandur(ms,   h, m) {
    ms = int(ms); if (ms < 0) ms = 0
    if (ms < 1000)    return ms " ms"
    if (ms < 60000)   return sprintf("%.3f s", ms / 1000)
    if (ms < 3600000) return sprintf("%d min %.3f s", int(ms/60000), (ms % 60000) / 1000)
    h = int(ms / 3600000); m = int((ms - h*3600000) / 60000)
    return sprintf("%d h %d min %.3f s", h, m, (ms - h*3600000 - m*60000) / 1000)
}

# ---- id forgers -------------------------------------------------------------
function uuid4() {
    return sprintf("%04x%04x-%04x-4%03x-%x%03x-%04x%04x%04x",
        rint(65536), rint(65536), rint(65536), rint(4096), 8 + rint(4), rint(4096),
        rint(65536), rint(65536), rint(65536))
}
# The real Session ID is the hex encoding of a 44-char base64 string ending
# "=": 43 alphabet chars + "=" -> 88 lowercase hex chars ending "3d".
function sesshex(   i, s) {
    s = ""
    for (i = 1; i <= 43; i++) s = s sprintf("%02x", B64[rint(64)])
    return s "3d"
}

BEGIN {
    CSET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.@/:,;()[]{}<>!#$%&*+='\" \t"
    for (_i = 1; _i <= length(CSET); _i++) CODE[substr(CSET, _i, 1)] = _i
    # base64 alphabet char codes (A-Z a-z 0-9 + /) for sesshex()
    _n = 0
    for (_i = 65; _i <= 90;  _i++) B64[_n++] = _i
    for (_i = 97; _i <= 122; _i++) B64[_n++] = _i
    for (_i = 48; _i <= 57;  _i++) B64[_n++] = _i
    B64[_n++] = 43; B64[_n++] = 47
}
