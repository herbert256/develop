# bin/sample/gen-events.awk — stage 3: estate + calendar -> the EVENT STREAM,
# one row per transfer LEG (T) and one per server-log line (S). Both log
# formatters are pure renderers of this stream, so a transfer leg and the
# server lines of its connection can never disagree about a session id or a
# timestamp. The server message TEXT is final here (wording copied from the
# report matchers — a one-character drift silently empties a report); embedded
# newlines travel as \x01 until the per-day split.
#
#   awk -F'\t' -f prelude.awk -f gen-events.awk \
#       -v EST=..._estate.tsv -v CAL=..._calendar.tsv -v OUT=..._events.tsv
#
# T row: T  absms dur status acct login site dir actby proto fname size host
#           port mode icap sec sid tid cid resub prof sessstart
#    status P|F|S|A -> Processed | Failed | Failed Subtransmission | Failed (aborted)
#    icap  NP|AL|BL|ER|UN     sec  S1|S2|S3|T2|T3|NU
# S row: S  absms level comp sid msg
#
# The UC leg grammars reproduced here are the MEASURED acceptance shapes — see
# the scenario notes in the repo plan: UC1 ok = I/pesit + O/ssh; UC2 ok =
# I/pesit + I/routing + O/routing (one session, routing pair overlapping) +
# O/ssh collect on a NEW session; UC2 staged-only = the 3-leg prefix (Waiting,
# or Expired when the File Maintenance sweep deletes the staged copy ~11 days
# on); UC3 ok = I/ssh poll + O/pesit; UC4 ok = I/ssh + O/pesit; failures are
# retry BURSTS sharing one session with size-0 legs (ssh ~6/13/22/34/47 s,
# pesit ~60 s doubling); a next-day recovery inbound carries sid=UNKNOWN.

function hastag(t) { return ("," TAGS ",") ~ ("," t ",") }
function tagval(t,   s) { s = "," TAGS ","; if (!match(s, "," t "=[^,]*,")) return ""
    s = substr(s, RSTART + length(t) + 2, RLENGTH - length(t) - 3); return s }

# ---- emitters ---------------------------------------------------------------
# NOTE %.0f, never %d, on the absolute-ms values (~2e14): mawk's %d may cast
# through a 32-bit int on some builds; %.0f is exact for integers in doubles.
#
# THE WINDOW CLAMP: any event past the last calendar day's midnight is
# DROPPED — a retry burst, next-day recovery, partner collect or monitor
# tail that would cross the window end simply loses its later legs, exactly
# what a real export cut mid-flight looks like. Without it a handful of
# spilled legs minted a transferLog for the day AFTER the window, and the
# home page's day spine gained a first row no logical File backs (four
# empty cells beside a lone date).
function T(abs, dur, st, af, lf, sf, dir, ab, pr, fn, sz, ho, po, mo, ic, se, sid, resub, prraw, ss) {
    if (abs >= (J1 + 1) * 86400000) { uuid4(); return }   # burn the tid draw: the
                                                          # PRNG stream stays aligned
    printf "T\t%.0f\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.0f\n", \
        abs, dur, st, af, lf, sf, dir, ab, pr, fn, sz, ho, po, mo, ic, se, sid, uuid4(), CID, resub, prraw, ss > OUT
}
function S(abs, lvl, comp, sid, msg) {
    if (abs >= (J1 + 1) * 86400000) return
    gsub(/\t/, " ", msg)
    printf "S\t%.0f\t%s\t%s\t%s\t%s\n", abs, lvl, comp, sid, msg > OUT
}

# ---- field templates --------------------------------------------------------
# the logged Transfer Site: clean name + _SCP_ tail, truncated to a varying
# length like the real exports (never below the _SCP_ marker itself)
function sitefield(   s, keep) {
    # the EXTENDED transfer-site shape (2026-09-01, user report): ST logs some
    # flows as "<subscription>_<PROTO>_SERVER_<partner>" — the parse folds it
    # back onto the subscription, without which the flow is unattributed, its
    # movement empty and every File reads Failed
    if (hastag("extsite")) return LOGSITE "_SFTP_SERVER_" PTOK
    s = LOGSITE "_SCP_" PROF "_" CRED
    keep = 40 + rint(50)
    if (keep < length(LOGSITE) + 14) keep = length(LOGSITE) + 14
    return substr(s, 1, keep)
}
# the full internal spelling the SERVER log uses (truncated at ~80)
function srvsite() { return substr(LOGSITE "_" PROF "_SCP_" PROF "_" CRED, 1, 80) }
function secssh() { return "S" (1 + rint(3)) }
function anyip(   n, a) { n = split(IPS, a, ";"); return a[1 + rint(n)] }
function hostspelled(   h) {
    if (SPELL == "dns") return (rnd() < 0.03) ? anyip() : HOST   # the rare raw-IP row the
                                                                 # ip-hosts endpoint map folds back
    if (SPELL == "ip")  return anyip()
    return (rnd() < 0.5) ? HOST : anyip()          # mixed: both spellings of one endpoint
}
function fname_of(abs,   d, t, ex, i) {
    d = abs_iso(abs); gsub(/-/, "", d)
    t = sprintf("%06d", int((abs % 86400000) / 1000))
    if (hastag("dupfixed")) return APP "_" PTOK ".xml"
    if (hastag("skipbait") && rnd() < 0.02) return "ACMETEST_probe_" d t ".txt"   # skip.txt bait rows
    i = rint(6)
    ex = (i == 0) ? ".zip" : (i == 1) ? ".xml" : (i == 2) ? ".csv" : (i == 3) ? ".pdf.pgp" : (i == 4) ? ".dat" : ".txt.pgp"
    return "Acme" DOM "_" APP "_" PTOK "_" d t "_" sprintf("%06d", rint(999999)) ex
}
function fsize(   s) {
    if (rnd() < 0.012) return 0                    # the zero-byte tail
    s = int(rexp(SIZEM)); if (s < 20) s = 20
    # the BIG-FILE tail (~2.5%): tens of MB — with the size-aware leg
    # durations these alone push a day's p95 toward the minute mark
    if (rnd() < 0.025) s = int(s * (30 + rexp(80)))
    if (s > 400000000) s = 400000000
    return s
}
# a transfer leg's duration grows with the file: bytes / throughput(bytes per
# ms) — ssh ~2-4 MB/s, pesit ~6-10 MB/s, ftp ~1-2 MB/s
function szdur(sz, thr) { return int(sz / thr) }
function sshthr() { return 2000 + rint(2000) }
function pesitthr() { return 6000 + rint(4000) }
# an inter-leg store-and-forward gap: the base few seconds, times the day's
# SLOW-PLATFORM factor (GAPF, from the calendar), plus the occasional
# routing-queue stall — common on a slow day, rare otherwise
function gapms(b,   g) {
    g = b * (GAPF > 1 ? GAPF : 1)
    if (rnd() < (GAPF > 1 ? 0.3 : 0.035)) g += 30000 + rexp(150000)
    return int(g)
}
function fmode() { return (hastag("ascii") && rnd() < 0.4) ? "ASCII" : (rnd() < 0.0005 ? "unknown" : "BINARY") }
function inicap() {
    if (hastag("avblock") && rnd() < 0.06) return "BL"
    if (hastag("averror") && rnd() < 0.04) return "ER"
    return (rnd() < 0.9) ? "AL" : "NP"
}

# ---- server message helpers (wording == the report matchers) ---------------
function s_authok(abs, sid, addr) {
    S(abs, "I", "TM", sid, "[Ssh Default] User with login name \"" LOGIN "\", associated with account \"" ACCT "@" LOGIN "\", successfully authenticated over SSH by local authentication agent. Remote address: " addr ". Connection security parameters: cipher suite: aes128-ctr; Key exchange: curve25519-sha256; HMAC: hmac-sha2-256; Public Key: ssh-rsa.")
}
function s_allowed(abs, sid, addr) {
    S(abs, "I", "TM", sid, "[Ssh Default] Allowed user '" LOGIN "' from address '" addr "', corresponding account '" ACCT "@" LOGIN "' , corresponding policy name 'Generic Whitelisting' (2c9581cc9e849e6e019e8d4a77c80014) , obtained on 'account' level.")
}
function s_initconn(abs, sid) {
    S(abs, "I", "TM", sid, "User with login name \"\", associated with account \"" ACCT "\", had initiated a connection over SSH. Remote address: " anyip() ".")
}
function s_poll(abs, sid, nfound) {
    S(abs, "I", "TM", sid, "Applying the search pattern '*' for transfer site '" srvsite() "': " nfound " file(s) were found of which " nfound " matched the pattern.")
    S(abs - 300 - rint(400), "I", "TM", sid, "Remote files pattern of transfer site: '" srvsite() "' evaluated to: '*'")
}
function s_route(abs, sid, name) { S(abs, "I", "TM", sid, "[Ssh Default] Initializing route: {" name "}") }
function s_arpair(abs, sid, fn) {
    S(abs, "I", "TM", sid, "ARRC0024: [" ACCT "@" LOGIN "] [" ACCT "]  The file {/data/FlowManager/" ACCT "/" fn "} will be submitted for processing.")
    S(abs + 4000 + rint(3000), "I", "TM", sid, "AR0089: [" ACCT "@" LOGIN "] [" ACCT "]  Deleting local file: {/data/FlowManager/" ACCT "/" fn "}.")
}
function s_pesit_ok(abs, sid) {
    if (rnd() < 0.4) S(abs - 200 - rint(300), "I", "PESITD", "", "Establishing PeSIT SSL connection with host 192.0.2.21, using cipher suite: TLS_AES_256_GCM_SHA384 and TLS/SSL protocol: TLSv1.3.")
    S(abs, "I", "PESITD", "", "[Pesit Default] Client logged in (remote address - 192.0.2.20/192.0.2.20, caller id - P00001_CFT01)")
    S(abs + 900 + rint(900), "I", "PESITD", "", "[Pesit Default] Client logged out (remote address - 192.0.2.20/192.0.2.20, caller id - P00001_CFT01)")
    if (rnd() < 0.5) S(abs + 600 + rint(500), "I", "PESITD", "", "transfer completed with diagCode 0(OK)")
}
# the per-reason error line of a failing leg — the FIRST error the flow's
# error page shows, so bin/flip-reason.awk classifies the flow by it
function s_reason_err(abs, sid, fn,   r) {
    r = REASON
    if (r == "connfail")         S(abs, "E", "TM", sid, "Connection failure while " srvsite() " tried to connect to remote host " HOST ":" PORT " as user " ACCT ": com.maverick.ssh.SshException: The connection did not complete")
    else if (r == "fingerprint") S(abs, "E", "TM", sid, "Wrong server fingerprint: got 07, expected 07:83:06:65:ac:c4:5a:97:58:a1:8e:29:df:95:b9:31.")
    else if (r == "nodir")       S(abs, "E", "TM", sid, "Error during transfer operation: Error occurred while listing files from partner " srvsite() " defined in account " ACCT ". No such file: /outbox/incoming")
    else if (r == "listing")     S(abs, "E", "TM", sid, "Error during transfer operation: Error occurred while listing files from partner " srvsite() " defined in account " ACCT ". Connection closed by the remote host")
    else if (r == "authout")     S(abs, "E", "TM", sid, "Authentication failure connecting to remote host " HOST ":" PORT " as user " ACCT ": Permission denied (publickey,password).")
    else if (r == "routestop")   S(abs, "E", "TM", sid, "ARSP0001: [SECURETRANSPORT] [" LOGSITE "_" PROF "]  An error occurred while sending the file {" fn "} to a partner site. Step configuration suggests to stop further route execution.")
    else if (r == "sitemissing") S(abs, "E", "TM", sid, "Transfer site ID is not present in environment. Using host, port and user: " HOST ":" PORT ":" ACCT)
    else if (r == "rfa")         S(abs, "E", "TM", sid, "[Pesit Default] Transfer profile '" PROF "' of account 'SECURETRANSPORT' is used for incoming transfer, but 'Receive File As' field not set.")
    else if (r == "pesitabort")  S(abs, "E", "TM", sid, "Error during transfer operation: Received negative ABORT_IND response: diagCode=312, diagText=312-Transfer aborted")
    else if (r == "pesitrefused")S(abs, "E", "TM", sid, "Error during transfer operation: Received negative SEND_CONF response: diagCode=230, diagText=230-File cannot be delivered")
    else if (r == "stfs")        S(abs, "E", "TM", sid, "Error during transfer operation: /.stfs/objects/2c/" substr(CID, 1, 8) " not found")
    else if (r == "tracking")    S(abs, "E", "TM", sid, "Error during transfer operation: Could not find file tracking entry for transfer " CID)
    else if (r == "unavailable") S(abs, "E", "TM", sid, "Error during transfer operation: 550 File unavailable, not found or busy")
    else if (r == "ftpspull")    S(abs, "E", "TM", sid, "Error during transfer operation: Pull via FTPS failed for transfer site '" srvsite() "': 425 Unable to build data connection")
    else if (r == "postaction")  S(abs, "E", "TM", sid, "Error during post client action execution: post client action failed for file " fn)
    else if (r == "network")     S(abs, "E", "TM", sid, "Network error: Connection reset")
    else if (HOST != "")         S(abs, "E", "TM", sid, "Connection failure while " srvsite() " tried to connect to remote host " HOST ":" PORT " as user " ACCT ": com.maverick.ssh.SshException: Connection timed out")
    else                         S(abs, "E", "TM", sid, "Network error: Connection reset")   # in-side flow: no endpoint to name
}

# ---- per-UC file builders ---------------------------------------------------
function pesit_T(abs, dur, dir, st, sid, fn, sz, mo, ic,   se) {
    se = (dir == "Outbound") ? (rnd() < 0.85 ? "T3" : "T2") : "NU"
    # the REAL file name rides in fn (CSV field 15, Local Filename — what
    # _files.tsv keys on); the formatter puts the profile token in field 10
    # (File) on Inbound pesit rows, the real export's shape
    T(abs, dur, st, "SECURETRANSPORT", "P00001_CFT01", "P00001_CFT01", dir, (dir == "Inbound" ? "User" : "Server"), "pesit", \
      fn, sz, "192.0.2.20", 17627, mo, (dir == "Inbound" ? ic : "NP"), se, sid, "false", PROFRAW(), abs - 200 - rint(2000))
}
function PROFRAW() {
    if (NOPROF) return "UNKNOWN"          # session-join / UCx scenarios: the
                                          # profile must not rescue the group
    if (PDASH != "" && rnd() < 0.5) return PDASH
    return PROF
}
function ssh_T(abs, dur, dir, st, sid, fn, sz, actby, acctf, loginf, sitef, ho, mo, ic, resub) {
    T(abs, dur, st, acctf, loginf, sitef, dir, actby, PROTO, fn, sz, ho, PORT, mo, (dir == "Inbound" ? ic : "NP"), secssh(), sid, resub, "UNKNOWN", abs - 200 - rint(2000))
}
function routing_T(abs, dur, dir, st, sid, fn, sz, mo) {
    T(abs, dur, st, "SECURETRANSPORT", "", sitefield(), dir, "Server", "routing", fn, sz, "", "UNKNOWN", mo, (dir == "Inbound" ? "AL" : "NP"), "NU", sid, "false", PROF, abs - 100 - rint(500))
}

# UC1: CFT delivers over pesit (Inbound), we push to the partner (Outbound ssh)
function uc1_file(t0,   fn, sz, mo, ic, sidp, sids, d1, d2, i, tt, ok, late) {
    fn = fname_of(t0); sz = fsize(); mo = fmode(); ic = inicap()
    sidp = sesshex(); sids = sesshex()
    d1 = 300 + int(rexp(900)) + szdur(sz, pesitthr())
    ok = (rnd() >= FAILP)
    if (hastag("stormy") && STORM) ok = (rnd() < 0.25)
    if (ic == "BL" || ic == "ER") ok = 0
    if (ok) {
        pesit_T(t0, d1, "Inbound", "P", sidp, fn, sz, mo, ic)
        s_pesit_ok(t0, sidp)
        d2 = 500 + int(rexp(2500)) + szdur(sz, sshthr())
        ssh_T(t0 + d1 + gapms(2500 + rexp(2000)), d2, "Outbound", "P", sids, fn, sz, "Server", "SECURETRANSPORT", "UNKNOWN", sitefield(), hostspelled(), mo, "NP", (hastag("resub") && rnd() < 0.12 ? "true" : "false"))
        s_initconn(t0 + d1 + 2000, sids)
    } else if (ic == "BL" || ic == "ER") {
        # the AV verdict kills the file on its inbound leg (one-legged)
        pesit_T(t0, d1, "Inbound", "F", sidp, fn, sz, mo, ic)
        S(t0 + 200, "E", "TM", sidp, "Error during transfer operation: file " fn " was blocked by the ICAP content scan")
    } else {
        pesit_T(t0, d1, "Inbound", "S", sidp, fn, sz, mo, ic)
        tt = t0 + d1 + 2500
        for (i = 1; i <= 6; i++) {                    # the measured ssh retry burst
            ssh_T(tt, 200 + int(rexp(600)), "Outbound", (i == 6 && rnd() < 0.05 ? "A" : "F"), sids, fn, 0, "Server", "SECURETRANSPORT", "UNKNOWN", sitefield(), hostspelled(), mo, "NP", "false")
            if (i <= 2) s_reason_err(tt + 100, sids, fn)
            tt += (5000 + i * i * 1200) + int(rexp(1500))
        }
        late = (rnd() < 0.012)
        if (late) {                                   # next-day recovery, sid UNKNOWN on the late inbound
            pesit_T(t0 + 86400000 + int(rexp(7200000)), 400 + int(rexp(600)), "Inbound", "P", "UNKNOWN", fn, sz, mo, "AL")
            ssh_T(t0 + 86400000 + 7200000 + int(rexp(3600000)), 600 + int(rexp(900)), "Outbound", "P", sesshex(), fn, sz, "Server", "SECURETRANSPORT", "UNKNOWN", sitefield(), hostspelled(), mo, "NP", "false")
        }
    }
}

# UC2: CFT stages over pesit+routing (one session), the partner collects (new session)
function uc2_file(t0,   fn, sz, mo, sidst, sidc, d1, d2, d3, tr, uncol, tc, swj) {
    fn = fname_of(t0); sz = fsize(); mo = fmode()
    sidst = sesshex()
    d1 = 150 + int(rexp(400)) + szdur(sz, pesitthr()); d2 = 40 + int(rexp(120)); d3 = 80 + int(rexp(150))
    pesit_T(t0, d1, "Inbound", "P", sidst, fn, sz, mo, "AL")
    tr = t0 + d1 + gapms(1500 + rexp(1500))
    # the routing pair's timestamps OVERLAP AND INVERT (outbound starts first)
    routing_T(tr + 44, d2, "Inbound",  "P", sidst, fn, sz, mo)
    routing_T(tr,      d3, "Outbound", "P", sidst, fn, sz, mo)
    s_route(tr - 800 - rint(800), sidst, (rnd() < 0.5 ? SITE : ACCT))
    uncol = hastag("expheavy") ? 0.42 : (hastag("waitheavy") ? 0.2 : 0.06)
    if (rnd() < uncol) {
        # staged, never collected: Waiting — or Expired when the sweep can run
        swj = int(t0 / 86400000) + RET_LO + rint(RET_HI - RET_LO + 1)
        if (swj <= J1) EXPQ[++NEXPQ] = ACCT "@" LOGIN "\t" fn "\t" swj
        return
    }
    tc = next_visit(t0 + d3 + 60000)                  # the partner's own poll habit
    if (tc >= (J1 + 1) * 86400000) {                  # collect would fall past the window: still staged
        swj = int(t0 / 86400000) + RET_LO + rint(RET_HI - RET_LO + 1)
        if (swj <= J1) EXPQ[++NEXPQ] = ACCT "@" LOGIN "\t" fn "\t" swj
        return
    }
    sidc = hastag("shareduc4") ? SHARESID : sesshex()
    s_allowed(tc - 1200, sidc, anyip())
    s_authok(tc - 1000, sidc, anyip())
    ssh_T(tc, 90 + int(rexp(400)), "Outbound", "P", sidc, fn, sz, "User", ACCT "@" LOGIN, LOGIN, sitefield(), anyip(), mo, "NP", "false")
}

# UC3: we poll the partner (Inbound ssh/ftp), deliver to CFT (Outbound pesit)
function uc3_file(t0,   fn, sz, mo, ic, sids, sidp, d1, d2, i, tt, ok) {
    fn = fname_of(t0); sz = fsize(); mo = fmode(); ic = inicap()
    sids = sesshex(); sidp = sesshex()
    d1 = 400 + int(rexp(2500)) + szdur(sz, sshthr())
    ok = (rnd() >= FAILP)
    if (ok) {
        s_poll(t0 - 4000 - rint(4000), sids, 1 + rint(3))
        ssh_T(t0, d1, "Inbound", "P", sids, fn, sz, "Server", ACCT, "UNKNOWN", sitefield(), hostspelled(), mo, ic, "false")
        d2 = 300 + int(rexp(700)) + szdur(sz, pesitthr())
        pesit_T(t0 + d1 + gapms(1200 + rexp(1500)), d2, "Outbound", "P", sidp, fn, sz, mo, "NP")
        s_pesit_ok(t0 + d1 + 1200, sidp)
    } else if (hastag("pollfail") || rnd() < 0.35) {
        # the pure poll failure: inbound retries only, no outbound leg at all
        tt = t0
        for (i = 1; i <= 6; i++) {
            ssh_T(tt, 300 + int(rexp(30000)), "Inbound", "F", sids, fn, (i == 6 ? sz : 0), "Server", ACCT, "UNKNOWN", sitefield(), hostspelled(), mo, "NP", "false")
            if (i <= 2) s_reason_err(tt + 150, sids, fn)
            tt += 300000 + int(rexp(240000))
        }
    } else {
        ssh_T(t0, d1, "Inbound", "S", sids, fn, sz, "Server", ACCT, "UNKNOWN", sitefield(), hostspelled(), mo, ic, "false")
        tt = t0 + d1 + 2000
        for (i = 1; i <= 5; i++) {
            pesit_T(tt, 55000 + int(rexp(8000)), "Outbound", "F", sidp, fn, 0, mo, "NP")
            if (i <= 2) s_reason_err(tt + 200, sidp, fn)
            tt += 500000 * i + int(rexp(200000))
        }
    }
}

# UC4: the partner delivers (Inbound ssh), we push to CFT (Outbound pesit)
function uc4_file(t0,   fn, sz, mo, ic, sids, sidp, d1, d2, i, tt, ok, sf) {
    fn = fname_of(t0); sz = fsize(); mo = fmode(); ic = inicap()
    sids = hastag("shareduc4") ? SHARESID : sesshex(); sidp = sesshex()
    d1 = 300 + int(rexp(1800)) + szdur(sz, sshthr())
    ok = (rnd() >= FAILP)
    if (ic == "BL" || ic == "ER") ok = 0
    sf = sitefield(); NOPROF = 0
    if (hastag("ucx")) { sf = "none"; NOPROF = 1 }    # unattributable -> UCx_<account>
    else if (hastag("sessjoin") && rnd() < 0.3) { sf = ""; NOPROF = 1; s_route(t0 + d1 + 800, sids, SITE) }
    s_allowed(t0 - 1400 - rint(600), sids, anyip())
    s_authok(t0 - 1100 - rint(300), sids, anyip())
    if (ok) {
        ssh_T(t0, d1, "Inbound", "P", sids, fn, sz, "User", ACCT "@" LOGIN, LOGIN, sf, hostspelled(), mo, ic, "false")
        d2 = 200 + int(rexp(500)) + szdur(sz, pesitthr())
        pesit_T(t0 + d1 + gapms(900 + rexp(900)), d2, "Outbound", "P", (hastag("ucx") ? sesshex() : sidp), fn, sz, mo, "NP")
        if (!hastag("ucx")) s_pesit_ok(t0 + d1 + 900, sidp)
        s_arpair(t0 + d1 + 500, sids, fn)
        NOPROF = 0
    } else if (ic == "BL" || ic == "ER") {
        ssh_T(t0, d1, "Inbound", "F", sids, fn, sz, "User", ACCT "@" LOGIN, LOGIN, sf, hostspelled(), mo, ic, "false")
        S(t0 + 300, "E", "TM", sids, "Error during transfer operation: file " fn " was blocked by the ICAP content scan")
    } else {
        ssh_T(t0, d1, "Inbound", "S", sids, fn, sz, "User", ACCT "@" LOGIN, LOGIN, sf, hostspelled(), mo, ic, "false")
        tt = t0 + d1 + 2000
        for (i = 1; i <= 11; i++) {                   # the measured pesit burst: ~60 s legs, doubling gaps
            pesit_T(tt, 58000 + int(rexp(5000)), "Outbound", "F", sidp, fn, 0, mo, "NP")
            if (i <= 2) s_reason_err(tt + 250, sidp, fn)
            tt += 180000 * (2 ^ int(i / 3)) + int(rexp(60000))
        }
    }
}

# the CFT end-to-end monitor: one 15-minute cycle through all four UCs — the
# 10-leg cascade of bin/dashboards/reports/monitor.sh's three views
function monitor_cycle(T0, q, dt,   nm, p, drift, c1, c2, c3, c4, s1, s2, s3, s4, \
                        uc1in, uc1out, uc4in, uc4out, uc2in, rout, stg, poll, uc3in, colct, uc3out, \
                        d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, hh) {
    hh = int((T0 % 86400000) / 3600000)
    nm = "monitor_" substr(dt,1,4) substr(dt,6,2) substr(dt,9,2) "_" sprintf("%02d%02d00", hh, (q % 2) * 30) ".txt"
    p = 35000 + rexp(MONP)
    if (rnd() < 0.05)               p += 240000 + rexp(300000)
    if (hh >= 2 && hh <= 3)         p += 30000 + rexp(90000)
    if (MONDEGR)                    p += 180000 + rexp(240000)
    drift = MONDRIFT ? (150000 + rexp(80000)) : 0
    c1 = uuid4(); c2 = uuid4(); c3 = uuid4(); c4 = uuid4()
    s1 = sesshex(); s2 = sesshex(); s3 = sesshex(); s4 = sesshex()
    uc1in = T0 + int(p); d1 = 900 + int(rexp(700))
    CID = c1; mon_T(uc1in, d1, "Inbound", "pesit", "1", s1, nm, "")
    if (rnd() < 0.005) return
    uc1out = uc1in + d1 + 4000 + int(rexp(2500)); d2 = 4500 + int(rexp(1500))
    mon_T(uc1out, d2, "Outbound", "ssh", "1", s1, nm, "filetransfer.acme.example")
    if (MONDEAD) return
    uc4in = uc1out + 300 + int(rexp(300)); d3 = d2 - 200 - int(rexp(200)); if (d3 < 1000) d3 = 1000
    CID = c4; mon_T(uc4in, d3, "Inbound", "ssh", "4", s4, nm, "192.0.2.77")
    uc4out = uc4in + d3 + 700 + int(rexp(400)); d4 = 300 + int(rexp(300))
    mon_T(uc4out, d4, "Outbound", "pesit", "4", s4, nm, "")
    uc2in = uc4out + d4 + 40000 + int(rexp(9000)) + int(drift); d5 = 600 + int(rexp(500))
    CID = c2; mon_T(uc2in, d5, "Inbound", "pesit", "2", s2, nm, "")
    rout = uc2in + d5 + 500 + int(rexp(400)); d6 = 120 + int(rexp(120))
    mon_T(rout, d6, "Outbound", "routing", "2", s2, nm, "")
    stg = rout + d6 + 400 + int(rexp(400)); d7 = 250 + int(rexp(250))
    mon_T(stg, d7, "Inbound", "routing", "2", s2, nm, "")
    if (rnd() < 0.011) return
    if (MONLAST && q >= 94) return
    poll = (int((stg - 300000) / 1800000) + 1) * 1800000 + 300000
    if (MONPOLL2 && hh >= 8 && hh < 20 && rnd() < 0.4) poll += 1800000
    uc3in = poll + 5000 + int(rexp(6000)); d8 = 3500 + int(rexp(1800))
    CID = c3; mon_T(uc3in, d8, "Inbound", "ssh", "3", s3, nm, "filetransfer.acme.example")
    colct = uc3in + 300 + int(rexp(300)); d9 = d8 + 300 + int(rexp(400))
    CID = c2; mon_T(colct, d9, "Outbound", "ssh", "2", s2, nm, "192.0.2.77")
    CID = c3; mon_T(uc3out = uc3in + d8 + 1500 + int(rexp(1200)), d10 = 600 + int(rexp(500)), "Outbound", "pesit", "3", s3, nm, "")
}
function mon_T(abs, dur, dir, proto, uc, sid, nm, host,   ab) {
    ab = (proto == "routing") ? "Server" : (proto == "pesit" ? (dir == "Inbound" ? "User" : "Server") : "User")
    T(abs, dur, "P", "INFRA_ST-MONITOR_INFRA@FE000000", "FE000000", "UC" uc "-INFRA_ST-MONITOR_INFRA", dir, ab, proto, nm, 16, host, \
      (proto == "pesit" ? 17627 : (proto == "routing" ? "UNKNOWN" : 22)), "BINARY", (dir == "Inbound" ? "NP" : "NP"), \
      (proto == "ssh" ? "S1" : "NU"), sid, "false", "INFRA-MONITOR-UC" uc, abs - 8000 - int(rexp(6000)))
}

# ---- the environment-level ambient stream (END pass over the calendar) ------
# Platform chatter tied to no single flow: the nightly sweep start, scanner
# probes, the shared-certificate lists, scheduler overruns, cluster health,
# NOISE-list boilerplate (dropped at parse — realism only), ADMIN records
# (dropped), one multi-line and plenty of doubled-quote records per day.
function env_ambient(   ci, jd, base, i, n, k, sid, lst) {
    for (ci = 1; ci <= NCAL; ci++) {
        jd = CJ[ci] + 0; base = jd * 86400000
        srnd(hash(ENVN "|amb|" jd))
        S(base + 10800000 + rint(30000), "I", "TM", "", "Start File Maintenance")
        # internet scanners knocking (Failed logins report's "no account" rows)
        n = 2 + rint(6)
        for (i = 0; i < n; i++)
            S(base + rint(86400000), "I", "TM", sesshex(), "[Ssh Default] User \"" rpick("user admin test root ftpuser scan") "\" is not associated with any account. Remote address: 203.0.113." (240 + rint(15)))
        # the shared-certificate serial list (ssh-security's detector)
        if (NAL >= 3) {
            lst = AL_A[1] "@" AL_L[1] ", " AL_A[2] "@" AL_L[2] ", " AL_A[3] "@" AL_L[3]
            for (i = 0; i < 1 + rint(3); i++)
                S(base + rint(86400000), "I", "TM", sesshex(), "[Ssh Default] Authentication attempt with certificate with serial number 01 assigned to [" lst "]")
        }
        # scheduler overruns (W, sessionless) on two fixed accounts
        if (NAL >= 2) {
            n = 3 + rint(10)
            for (i = 0; i < n; i++) { k = 1 + rint(2)
                S(base + rint(86400000), "W", "TM", "", "The task \"2c9581cc9e96d2e8019eabc5bfc10448_subscription_PARTNER-IN\"  of account with name: \"" AL_A[k] "\" with subscription folder: \"/${subscription.participant.class.name}/" AL_A[k] "\" is still in progress. Skipping the next scheduled occurrence of this task.") }
        }
        # ADMIN/AUDIT records (dropped at tokenize) + one MULTI-LINE record
        S(base + rint(86400000), "W", "ADMIN", "", "TaskProcessorSynchronizer swallowed an exception.")
        S(base + rint(86400000), "I", "AUDIT", "", "Administrator \"admin\" logged in to the administration UI.")
        S(base + 7200000 + rint(3600000), "I", "TM", "", "releaseConfirmation. \x01 diagCode=0, diagText=OK")
        # NOISE boilerplate (parse drops these; they exercise the filter)
        n = 8 + rint(15)
        for (i = 0; i < n; i++) { sid = sesshex(); k = rint(4)
            if (k == 0)      S(base + rint(86400000), "I", "TM", sid, "[Ssh Default] Current ST internal session count = " (10 + rint(60)))
            else if (k == 1) S(base + rint(86400000), "I", "TM", sid, "Reporting event to Sentinel: TransferEvent")
            else if (k == 2) S(base + rint(86400000), "I", "TM", sid, "AR0076: [SECURETRANSPORT] [route]  Route execution started.")
            else             S(base + rint(86400000), "I", "TM", sid, "Created session information with id " sid ".")
        }
        # weekly-ish singles
        if (jd % 7 == 0 && NAL >= 1)
            S(base + rint(86400000), "I", "TM", sesshex(), "[Ssh Default] User '" AL_L[1 + rint(NAL)] "' locked due to too many failed login attempts.")
        if (jd % 7 == 1 && NAL >= 1) { k = 1 + rint(NAL)
            S(base + rint(86400000), "W", "TM", sesshex(), "[Ssh Default] Disallowed user \"" AL_L[k] "\" from address \"203.0.113." (230 + rint(9)) "\" , corresponding account \"" AL_A[k] "@" AL_L[k] "\" corresponding Login Restriction Policy \"Generic Whitelisting\" (2c9581cc9e849e6e019e8d4a77c80014) obtained on business unit level. [Not matching to ALLOW Login Restriction Policy]") }
        if (jd % 7 == 2 && NAL >= 1) { k = 1 + rint(NAL)
            S(base + rint(86400000), "I", "TM", sesshex(), "[Ssh Default] Authentication failed because no certificate is found for user \"" AL_A[k] "@" AL_L[k] "\" in user certificate store that contains the submitted key. The fingerprint of the submitted key is: MD5:24:ab:9c:" sprintf("%02x:%02x", rint(256), rint(256))) }
        if (jd % 7 == 3) {
            S(base + rint(86400000), "E", "TM", sesshex(), "MAC_CS could not be negotiated from remote algorithms hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com")
            S(base + rint(86400000), "I", "TM", sesshex(), "The remote host identified itself as SSH-2.0-AWS_SFTP_1.2")
        }
        if (jd % 7 == 4) {
            S(base + rint(86400000), "W", "TM", "", "Value of 'Server.ProtocolCommands.batchSize' is too low and may lead to performance degradation.")
            S(base + rint(86400000), "E", "TM", sesshex(), "Error during test connection. Connection refused")
        }
        if (jd % 7 == 5)
            S(base + rint(86400000), "W", "TM", sesshex(), "Transfer site ID is not present in environment. Using host, port and user: sftp-legacy.acme.example:22:C208-MFT")
        if (jd % 11 == 0) {
            S(base + rint(86400000), "W", "TM", "", "Service localhost/127.0.0.1:27617 appears to be unresponsive or stopped")
            S(base + rint(86400000), "W", "TM", "", "2026-07-07 07:09:12.424/105402.104 Oracle Coherence CE 22.06.10 <Warning> (thread=PacketPublisher, member=1): Experienced a 1978 ms communication delay (probable remote GC) with Member(Id=3, Address=192.0.2.76:8090)")
        }
        if (ci == int(NCAL / 3)) {
            S(base + 41000000, "I", "SSHD", "", "Stopping SSH server with name Ssh Default.")
            S(base + 41090000, "I", "SSHD", "", "Starting SSH server with name Ssh Default.")
        }
        # the PeSIT ceiling episode on the storm day
        if (CT[ci] ~ /storm/) {
            n = 25 + rint(30)
            for (i = 0; i < n; i++) {
                S(base + 28800000 + rint(14400000), "E", "TM", sesshex(), "FPDU_RCONNECT diagCode=309. diagText=309-Too many connections for this CT. reason=TRANSFER_ERROR")
                if (i % 5 == 0) S(base + 28800000 + rint(14400000), "W", "PESITD", "", "[Pesit Default] PeSIT server has exceeded the maximum number of allowed connections 100.")
            }
            for (i = 0; i < 10; i++)
                S(base + 28800000 + rint(14400000), "E", "TM", sesshex(), "Network error: Connection reset")
        }
    }
}

# the partner's next visit at/after t, per the org's rhythm
function next_visit(t,   day, step) {
    if (VCLASS == "hourly")   step = 3600000
    else if (VCLASS == "business") step = 7200000
    else if (VCLASS == "daily") step = 86400000
    else if (VCLASS == "night") step = 86400000
    else step = 3600000 * (2 + rint(20))              # erratic
    return t + int(rexp(step * 0.6)) + 60000
}

# ---- ambient, per flow-day --------------------------------------------------
function flow_day_ambient(jd, base,   i, np, tt, sid, poff) {
    # UC3-style polls fire on the CONFIGURED cron grid all day (found-nothing
    # lines) — the Cronjobs page compares this observed firing to the Quartz
    # expression, so the grid must be cron-faithful (the driftcron flow's polls
    # deliberately run ~3.5 h after its configured 06:00)
    if (UC == 3 && VOL > 0 && !hastag("pollfail")) {
        if (SCHED == "c15") {
            for (i = 0; i < 96; i++) if (rnd() < 0.92)
                s_poll(base + i * 900000 + 300000 + rint(20000), sesshex(), 0)
        } else if (substr(SCHED, 1, 3) == "ch:") {
            for (i = 0; i < 24; i++) if (rnd() < 0.92)
                s_poll(base + i * 3600000 + (substr(SCHED, 4) + 0) * 60000 + rint(20000), sesshex(), 0)
        } else {
            tt = base + cd_ms() + rint(30000)
            if (hastag("driftcron")) tt += 12600000
            if (rnd() < 0.95) s_poll(tt, sesshex(), 0)
        }
    }
    # blue / greenpoll flows: server-log-only evidence
    if (hastag("greenpoll") && rnd() < 0.8) s_poll(base + cd_ms() + rint(3600000), sesshex(), 0)
    # blue = a SITE-naming mention shape the unknown-entities seeds extract
    # (poll / listing lines); bluelogon = logon evidence only — the ACCOUNT
    # and LOGIN go blue while the in-side subscription itself stays orange
    if (hastag("blue") && rnd() < 0.25) {
        sid = sesshex(); tt = base + 30000000 + rint(20000000)
        if (UC == 3 || UC == 5) {
            # a blue UC3 must NOT flip green on the clean-poll rule: keep an
            # E-level mention NEWER than its newest successful poll
            s_poll(tt, sid, 0)
            S(tt + 3600000, "E", "TM", sesshex(), "Error during transfer operation: Error occurred while listing files from partner " srvsite() " defined in account " ACCT ". Connection closed by the remote host")
        } else {
            s_initconn(tt, sid)
            S(tt + 3600000, "E", "TM", sesshex(), "Error during transfer operation: Error occurred while listing files from partner " srvsite() " defined in account " ACCT ". Connection closed by the remote host")
        }
    }
    if (hastag("bluelogon") && rnd() < 0.25) {
        sid = sesshex(); tt = base + 30000000 + rint(20000000)
        s_allowed(tt, sid, anyip()); s_authok(tt + 1000, sid, anyip())
    }
    # empty-handed partner visits (UC2 pickup stats' empty visits)
    if (UC == 2 && VOL > 0 && rnd() < 0.5) {
        sid = sesshex()
        s_allowed(base + 20000000 + rint(40000000), sid, anyip())
        s_authok(base + 20001000 + rint(40000000), sid, anyip())
    }
    # the weak-SSH warning family
    if (hastag("weakssh") && rnd() < 0.4)
        S(base + 25000000 + rint(30000000), "W", "TM", "", "Insecure or deprecated SSH connection parameter used: [Cipher: aes128-cbc] by Account \"" ACCT "\" , Transfer site: \"" srvsite() "\", connecting to remote host: " HOST)
}
function cd_ms(   a) { if (substr(SCHED,1,3) != "cd:") return 21600000
    split(substr(SCHED, 4), a, ":"); return (a[1] * 3600 + a[2] * 60) * 1000 }

# ---- main -------------------------------------------------------------------
BEGIN { RET_LO = 10; RET_HI = 12 }
FILENAME == CAL {
    CJ[++NCAL] = $2; CD[NCAL] = $3; CF[NCAL] = $4; CT[NCAL] = $5
    CG[NCAL] = 1
    if (match($5, /slow:[0-9]+/)) CG[NCAL] = substr($5, RSTART + 5, RLENGTH - 5) + 0
    if (NCAL == 1) J0R = $2 + 0
    J1 = $2 + 0
    next
}
{
    # one estate row: generate every day's events for this flow
    if ($3 == "A") next
    FK = $1; ENVN = $2; UC = $3 + 0; SITE = $4; ACCT = $5; LOGIN = $6
    PROF = $7; PDASH = $8; DOM = $9; APP = $10; PTOK = $11
    HOST = $19; IPS = $20; SPELL = $21; PORT = $22
    SCHED = $23; VOL = $24 + 0; FAILP = $25 + 0; SIZEM = $26 + 0
    FROMJ = $27 + 0; TOJ = $28 + 0; CRED = $29; TAGS = $30
    PROTO = (PORT == 21) ? "ftp" : "ssh"
    LOGSITE = SITE
    if (LOGIN != "" && !hastag("blue") && VOL > 0 && NAL < 8) {
        NAL++; AL_A[NAL] = ACCT; AL_L[NAL] = LOGIN
        split(IPS, _aip, ";"); AL_IP[NAL] = _aip[1]
    }
    REASON = tagval("reason")
    OLDNAME = tagval("rename")
    VCLASS = "hourly"
    if (SCHED ~ /^push:/) VCLASS = substr(SCHED, 6)
    SHARESID = ""

    if (hastag("monitor")) { if (UC == 1) monitor_days(); next }   # one pass builds all four UCs' rows

    for (ci = 1; ci <= NCAL; ci++) {
        jd = CJ[ci] + 0
        if (jd < FROMJ || jd > TOJ) continue
        base = jd * 86400000
        srnd(hash(ENVN "|ev|" SITE "|" jd))
        STORM = (CT[ci] ~ /storm/)
        GAPF = CG[ci]
        # a historical rename: the EARLY window logs the old name
        LOGSITE = (OLDNAME != "" && jd < J0R + 14) ? OLDNAME : SITE
        flow_day_ambient(jd, base)
        if (VOL <= 0) continue
        nf = int(VOL * CF[ci] * (0.55 + 0.9 * rnd()) + rnd())
        if (STORM && (hastag("stormy") || hastag("whale"))) nf = int(nf * 1.6 + 2)
        for (fi = 0; fi < nf; fi++) {
            CID = uuid4(); NOPROF = 0
            t0 = base + file_time()
            if (UC == 1) uc1_file(t0)
            else if (UC == 2) { if (hastag("shareduc4")) SHARESID = sesshex(); uc2_file(t0) }
            else if (UC == 3) uc3_file(t0)
            else if (UC == 4) uc4_file(t0)
        }
        # skip-list bait: a couple of rows any skip rule catches
        if (hastag("skipflow") && nf == 0) { CID = uuid4(); uc1_file(base + file_time()) }
    }
    next
}

function file_time(   a, h) {
    if (substr(SCHED, 1, 5) == "scan:") { split(substr(SCHED, 6), a, " "); h = a[1 + rint(3)] + 0
        return h * 3600000 + rint(3600000) }
    if (substr(SCHED, 1, 6) == "stage:") { split(substr(SCHED, 7), a, " "); h = a[1 + rint(2)] + 0
        return h * 3600000 + rint(3600000) }
    if (SCHED == "c15") return rint(96) * 900000 + 300000 + rint(30000)
    if (substr(SCHED, 1, 3) == "ch:") return rint(24) * 3600000 + (substr(SCHED, 4) + 0) * 60000 + rint(30000)
    if (substr(SCHED, 1, 3) == "cd:") return cd_ms() + rint(600000)
    if (VCLASS == "night") return rint(21600000)                       # 00-06h
    if (VCLASS == "business") return 28800000 + rint(32400000)         # 08-17h
    return rint(86400000)
}

# all four monitor flows are generated in ONE pass (the cascade crosses UCs)
function monitor_days(   ci, jd, base, q, dt) {
    for (ci = 1; ci <= NCAL; ci++) {
        jd = CJ[ci] + 0; base = jd * 86400000; dt = CD[ci]
        srnd(hash(ENVN "|mon|" jd))
        MONP = 15000 + rint(12000)
        MONDEGR = (CT[ci] ~ /spike/) && rnd() < 0.5
        MONDRIFT = (ci == int(NCAL / 2))
        MONPOLL2 = (ci == int(NCAL / 2) + 2)
        MONLAST = (ci == NCAL)
        # a 30-minute beat (48 cycles/day; poll grid :05/:35 — cron "0 5/30")
        for (q = 0; q < 48; q++) {
            if (rnd() < 0.03) continue                               # missed beats
            MONDEAD = (CT[ci] ~ /storm/ && q >= 7 && q <= 17)       # the outage hole
            if (MONDEAD && q > 8) continue
            monitor_cycle(base + q * 1800000, q, dt)
        }
    }
}

END {
    env_ambient()
    # UC2 expiry queue -> the sweep's deletion S rows (03:0x, account + basenames)
    for (i = 1; i <= NEXPQ; i++) {
        split(EXPQ[i], a, "\t")
        swabs = a[3] * 86400000 + 10800000 + rint(600000)
        DELS[a[3] "\t" a[1]] = DELS[a[3] "\t" a[1]] ", /data/FlowManager/" substr(a[1], 1, index(a[1] "@", "@") - 1) "/" a[2]
        DELT[a[3] "\t" a[1]] = swabs
    }
    for (k in DELS) {
        split(k, a, "\t")
        S(DELT[k], "I", "TM", "", "File Maintenance for account [" a[2] "] finished. Deleted files [" substr(DELS[k], 3) "].")
    }
}
