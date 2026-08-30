#!/usr/bin/env bash
#
# bin/make-monitor-example.sh — (re)generate the PRODUCTION example data for
# the CFT end-to-end monitor flow:
#
#   -> input/production/transfer/transferLog_monitor.csv
#
# Production input is the hand-crafted EXAMPLE dataset; this script writes the
# monitor slice of it — one 15-minute cycle through all four UCs (the exact
# 10-leg shape of the real windows/monitor flow, 4 CoreIds per cycle) over the
# SAME 7-day window as the other production exports (2026-07-03 .. 2026-07-09).
# DETERMINISTIC (fixed srand seed): re-running reproduces the identical file.
#
# The point is a LIVELY PULSE, not a long calendar — wide monitor times so the
# Monitor dashboard's three views have texture:
#   * missed beats       ~3% of the 15-minute drops simply never happen, plus
#                        a scheduler stall on 07-08 10:00-11:15 (6 beats gone)
#   * slow CFT pickups   a heavy tail everywhere (~5% of pickups take 4-15
#                        min), a nightly backup bump 02-04h, business-hours
#                        noise, and a degraded afternoon on 07-04 (P98 ~10 min)
#   * staging drift      07-05: ST-internal delivery creeps to ~6 min mid-day
#                        and recovers — the STAGING view's story
#   * outage             07-06: three cycles die inside ST (1-hour penalty
#                        bars), a ~6 h hole, then 20-40 min catch-up pickups
#   * second polls       07-07 08-20h: ~40% of cycles miss the :05 poll — the
#                        DURATION view jumps ~15 min while staging stays flat
#   * sporadic losses    ~1/90 cycles lose the loop after staging, ~1/200 die
#                        right after entering ST; the last two cycles stay
#                        in flight (the young-tail skip rule)
#
# The CSV mirrors the real transferLog export: same 41 columns, fake
# TEST-NET addresses and *.example.test hosts like the rest of the example
# set. After regenerating: bin/build.sh prd (the changed input forces the
# production reparse).
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source bin/fastawk.sh

OUT="input/production/transfer/transferLog_monitor.csv"
mkdir -p "$(dirname "$OUT")"

awk '
function jdn(y, m, d,   a) { a = int((14-m)/12); y = y+4800-a; m = m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
function fromjdn(j,   a,b,c,dd,e,mm,day,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day) }
function rexp(mean) { return -mean * log(1 - rand()) }        # exponential noise
# absolute ms (from the window start) -> "MM/DD/YYYY HH:MM:SS.mmm"
function fmt(abs,   j, ms, d) {
    j = J0 + int(abs / 86400000); ms = abs % 86400000
    d = fromjdn(j)
    return sprintf("%s/%s/%s %02d:%02d:%02d.%03d", substr(d,6,2), substr(d,9,2), substr(d,1,4), int(ms/3600000), int(ms/60000)%60, int(ms/1000)%60, ms%1000)
}
# one CSV row in the exact export shape (41 fields)
function emit(uc, dir, actby, proto, start, dur, cid, sid, host, port, sec, srv,   nm) {
    nm = name
    printf "\"Processed\",\"INFRA_ST-MONITOR_INFRA@FE000000\",\"FE000000\",\"VirtClass\",\"Virtual\",\"FlowManagerApplication\",\"UC%s-INFRA_ST-MONITOR_INFRA\",\"%s\",\"%s\",\"%s\",\"UNKNOWN\",\"INFRA-MONITOR-UC%s\",\"FILE\",\"UNKNOWN\",\"%s\",\"/\",\"Scanning was not performed\",\"/data/FlowManager/INFRA_ST-MONITOR_INFRA/%s\",16,\"%s\",\"true\",\"BINARY\",\"%s\",\"%s\",\"%d ms\",\"%s\",\"%s\",\"UNKNOWN\",\"ac1e1000-0000-4000-8000-%012d\",\"ac1e%060d\",\"%s\",\"UNKNOWN\",\"UNKNOWN\",\"ac1e0000-0000-4000-8000-%012d\",\"false\",\"UNKNOWN\",\"UNKNOWN\",\"%s\",\"%s\",\"UNKNOWN\",\"192.0.2.76\"\n", \
        uc, dir, actby, nm, uc, nm, nm, proto, fmt(start), fmt(start + dur), dur, host, port, ++tid, sid, fmt(start - 8000 - int(rexp(6000))), cid, sec, srv
}
BEGIN {
    srand(42)
    J0 = jdn(2026, 7, 3)                                   # window: 2026-07-03 ..
    NDAYS = 7                                              # .. 2026-07-09
    SSH = "Cipher: aes128-gcm@openssh.com, MAC: <implicit>, Key Exchange: diffie-hellman-group-exchange-sha256, Public Key: rsa-sha2-256."
    print "Status, Account, Login, UserClass, UserType, Application, Transfer Site, Direction, Action By, File, Remote Partner, Transfer Profile, Transfer Content Type, Remote Folder, Local Filename, Local Folder, ICAP Details, Local File, Size, Protocol, Secure, Mode, Start Time, End Time, Duration, Remote Host, Remote Port, Proxy Host, Transfer ID, Session ID, Session Start Time, Operation Index, Pesit Message, CoreId, Resubmitted, Additional info, X-Forwarded-For, SecurityParameters, Server Name, Alternated Addresses, Server Address"
    # per-day baseline pickup mean (ms of exponential tail on top of 35 s):
    # good / normal / drifty / outage-day / normal / SLUGGISH / good
    split("15000 22000 18000 16000 20000 60000 14000", PMEAN, " ")
    for (day = 0; day < NDAYS; day++) {
        dt = fromjdn(J0 + day)
        wknd = ((J0 + day) % 7 >= 5)
        for (q = 0; q < 96; q++) {
            T = day * 86400000 + q * 900000                # the drop moment
            hh = int(q / 4)
            cyc++
            # ---- missed beats: the drop simply never happens ---------------
            if (rand() < 0.03) continue                    # ~3% skipped beats
            if (dt == "2026-07-08" && q >= 40 && q <= 45) continue   # scheduler stall 10:00-11:15
            # ---- the outage hole (2026-07-06): 03:15-08:45 nothing at all --
            if (dt == "2026-07-06" && q >= 13 && q <= 35) continue
            name = sprintf("monitor_%04d%02d%02d_%02d%02d00.txt", substr(dt,1,4), substr(dt,6,2), substr(dt,9,2), hh, (q%4)*15)
            # ---- pickup latency (CFT drop -> UC1 inbound start) ------------
            p = 35000 + rexp(PMEAN[day + 1] * (wknd ? 0.6 : 1))
            if (rand() < 0.05)                    p += 240000 + rexp(300000)   # the heavy tail: 4-15 min
            if (hh >= 2 && hh <= 3)               p += 30000 + rexp(90000)     # nightly backup window
            if (!wknd && hh >= 8 && hh < 18)      p += rexp(12000)             # business-hours noise
            if (dt == "2026-07-04" && hh >= 12 && hh < 19) p += 180000 + rexp(240000)   # degraded afternoon
            if (dt == "2026-07-06" && (q == 36 || q == 37)) p += 1200000 + rexp(600000) # post-outage catch-up
            # ---- staging drift (2026-07-05): up mid-day, gone by evening ---
            drift = 0
            if (dt == "2026-07-05") {
                f = (q < 40) ? q / 40 : (q < 72 ? 1 : (96 - q) / 24)
                drift = f * (250000 + rexp(80000))
            }
            # ---- the four per-cycle ids ------------------------------------
            c1 = ++cid; c2 = ++cid; c3 = ++cid; c4 = ++cid   # UC1 UC2 UC3 UC4
            s1 = ++sid; s2 = ++sid; s3 = ++sid; s4 = ++sid
            # ---- the cascade -----------------------------------------------
            uc1in  = T + int(p);            d1 = 900  + int(rexp(700))
            emit("1", "Inbound",  "User",   "pesit",   uc1in, d1, c1, s1, "", "17627", "UNKNOWN", "Pesit Default")
            # ~1/200: dies right after entering ST (both penalties)
            if (cyc % 200 == 141) continue
            # outage edge (2026-07-06 02:30-03:00): entered ST, then nothing
            dead = (dt == "2026-07-06" && q >= 10 && q <= 12)
            uc1out = uc1in + d1 + 4000 + int(rexp(2500)); d2 = 4500 + int(rexp(1500))
            emit("1", "Outbound", "User",   "ssh",     uc1out, d2, c1, s1, "filetransfer.example.test", "UNKNOWN", SSH, "Ssh Default")
            if (dead) continue
            uc4in  = uc1out + 300 + int(rexp(300));  d3 = d2 - 200 - int(rexp(200)); if (d3 < 1000) d3 = 1000
            emit("4", "Inbound",  "User",   "ssh",     uc4in, d3, c4, s4, "192.0.2.77", "UNKNOWN", SSH, "Ssh Default")
            uc4out = uc4in + d3 + 700 + int(rexp(400)); d4 = 300 + int(rexp(300))
            emit("4", "Outbound", "Server", "pesit",   uc4out, d4, c4, s4, "", "17627", "UNKNOWN", "Pesit Default")
            uc2in  = uc4out + d4 + 40000 + int(rexp(9000)) + int(drift); d5 = 600 + int(rexp(500))
            emit("2", "Inbound",  "User",   "pesit",   uc2in, d5, c2, s2, "", "17627", "UNKNOWN", "Pesit Default")
            rout   = uc2in + d5 + 500 + int(rexp(400)); d6 = 120 + int(rexp(120))
            emit("2", "Outbound", "Server", "routing", rout, d6, c2, s2, "", "UNKNOWN", "UNKNOWN", "UNKNOWN")
            stg    = rout + d6 + 400 + int(rexp(400)); d7 = 250 + int(rexp(250))
            emit("2", "Inbound",  "Server", "routing", stg, d7, c2, s2, "", "UNKNOWN", "UNKNOWN", "UNKNOWN")
            # ~1/90: staged but the loop never closes (duration penalty only);
            # the last two cycles stay in flight (young tail, skipped not penalized)
            if (cyc % 90 == 47) continue
            if (day == NDAYS - 1 && q >= 94) continue
            # ---- the :05-grid poll (UC3 cron), optionally missing one window
            poll = (int((stg - 300000) / 900000) + 1) * 900000 + 300000
            if (dt == "2026-07-07" && hh >= 8 && hh < 20 && rand() < 0.4) poll += 900000   # second poll
            uc3in  = poll + 5000 + int(rexp(6000)); d8 = 3500 + int(rexp(1800))
            emit("3", "Inbound",  "User",   "ssh",     uc3in, d8, c3, s3, "filetransfer.example.test", "UNKNOWN", SSH, "Ssh Default")
            colct  = uc3in + 300 + int(rexp(300)); d9 = d8 + 300 + int(rexp(400))
            emit("2", "Outbound", "User",   "ssh",     colct, d9, c2, s2, "192.0.2.77", "UNKNOWN", SSH, "Ssh Default")
            uc3out = uc3in + d8 + 1500 + int(rexp(1200)); d10 = 600 + int(rexp(500))
            emit("3", "Outbound", "Server", "pesit",   uc3out, d10, c3, s3, "", "17627", "UNKNOWN", "Pesit Default")
        }
    }
}' > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
n=$(wc -l < "$OUT")
echo "Wrote $OUT ($((n - 1)) rows)" >&2
