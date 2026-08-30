# verdict.awk — one ALERT/INTRO fragment per subscription detail page, saying
# in prose what the UCx status report says about that flow in a table cell.
#
# Reads the subscriptions slugmap first, then the four uc<n>-status.rpt files
# (the SINGLE source of the verdict — this file only turns a row into a
# sentence, so a page and its status report can never disagree). A UC2 page
# additionally gets the "Pickup information" TABLE from the uc2-pickups.tsv
# sidecar (uc2-status.sh: sub, account, first, last, pickups, with-files,
# files-picked, pattern). Writes <OUT>/<slug>.txt, which publish-details.sh
# splices in after the DESC line.
#
# Row layouts (table 1 of each report):
#   UC1  2 status 3 name 4 Files 5 OK 6 Error 7 Last file 8 Route runs 9 Problems 10 Last log
#   UC2  2 status 3 name 4 Expired 5 First 6 Last 7 Pickups 8 Last pickup
#   UC3  2 status 3 name 4 Files 5 OK 6 Error 7 Last file 8 Polls 9 Empty 10 Problems 11 Last log
#   UC4  2 status 3 name 4 Files 5 OK 6 Error 7 Last file 8 Logons 9 Arrivals 10 Problems 11 Last log
function strip(s) { sub(/^@\{[^}]*\}/, "", s); return s }
function dt(s)    { return (s == "" || s == "-" || s == "\342\200\224") ? "" : s }   # "-"/em dash = none
function on(s,   d) { d = dt(s); return d == "" ? "" : (", latest " d) }
function plural(n, one, many) { return (n + 0 == 1) ? one : many }
# emit — ALERT (a problem headline; "" = none) + the INTRO sentence + an
# optional pre-formatted extra block (the UC2 pickup table). NEXTMOVE (set by
# the failing UC1/UC3/UC4 branches from the row's drill log lines, reset per
# ROW) renders as a second INTRO line right after the verdict prose.
function emit(slug, alert, intro, extra,   f) {
    if (slug == "" || (slug in done)) return
    done[slug] = 1
    f = OUT "/" slug ".txt"
    if (alert != "") printf "ALERT\t%s\n", alert > f
    printf "INTRO\t%s\n", intro > f
    if (NEXTMOVE != "") printf "INTRO\t%s\n", NEXTMOVE > f
    if (extra != "") printf "%s", extra > f
    close(f)
}
# getll — the row's @data:loglines drill attribute (the recent server-log
# lines the status report keeps per flow), scanned from the tail because the
# four reports carry it at a different field each (UC1: 11, UC2: 9, UC3/4: 12)
function getll(   i) {
    for (i = NF; i >= 4; i--)
        if (substr($i, 1, 15) == "@data:loglines=") return substr($i, 16)
    return ""
}
# nextmove — ONE sentence saying whose move fixing this is, classified from
# the drill log lines. Priority order is deliberate ("Publickey
# authentication failed" also says "Connection failure" — credentials win);
# an unrecognized log blob gets NO line, never a guess.
function nextmove(ll) {
    if (ll == "") return ""
    if (index(ll, "TRANSFER_REFUSED") || index(ll, "refused") || index(ll, "Refused") || \
        index(ll, "No such file"))
        return "**Next move: the partner** — their side refuses or lacks the path."
    if (index(ll, "Publickey") || index(ll, "publickey") || index(ll, "Authentication failure") || \
        index(ll, "authentication failed") || index(ll, "authentication was cancelled") || \
        index(ll, "Permission denied") || index(ll, "permission denied") || \
        index(ll, "whitelist") || index(ll, "Whitelist"))
        return "**Next move: ours** — credentials/whitelisting."
    if (index(ll, "Connection failure") || index(ll, "timeout") || index(ll, "Timeout") || \
        index(ll, "timed out") || index(ll, "Network error") || index(ll, "network error") || \
        index(ll, "Connection reset") || index(ll, "Connection closed") || \
        index(ll, "Channel is not active"))
        return "**Next move: network** — either side; start with reachability."
    if (index(ll, "CONFIG_PASSWD") || index(ll, "deploy") || index(ll, "Deploy") || \
        index(ll, "cron") || index(ll, "Cron"))
        return "**Next move: ours** — configuration."
    return ""
}
# a sidecar stamp for display: milliseconds off, absent -> em dash
function stamp(s) { return (s == "" || s == "-") ? "\342\200\224" : substr(s, 1, 19) }
# the UC2 "Pickup information" table, from the uc2-pickups.tsv sidecar
function pktable(nm,   k, t) {
    k = toupper(nm)
    if (!(k in pki)) return ""
    t = "TABLE\tPickup information\n"
    t = t "HEAD\tItem\tValue\n"
    t = t "KIND\ttext\ttext\n"
    t = t "ROW\tFirst pickup\t" stamp(pkf[k]) "\n"
    t = t "ROW\tLast pickup\t" stamp(pkl[k]) "\n"
    t = t "ROW\tTotal pickups\t" (pkn[k] + 0) "\n"
    t = t "ROW\tPickups with actual files\t" (pkw[k] + 0) "\n"
    t = t "ROW\tTotal files picked up\t" (pkc[k] + 0) "\n"
    t = t "ROW\tCurrent waiting files\t" (pkwt[k] + 0) "\n"
    t = t "ROW\tExpired files\t" (pkxp[k] + 0) "\n"
    t = t "ROW\tPickup pattern\t" pkp[k] "\n"
    # only when there ARE such logons — a 0 row says nothing on a flow whose
    # partner never delivers (most of them)
    if (pkdl[k] + 0 > 0)
        t = t "ROW\tLogons that only delivered files\t" (pkdl[k] + 0) "\n"
    # OPTIONAL last row — only on same-connection PROOF: at least one
    # technical SSH connection (transfer-log Session ID) in which the account
    # both delivered and collected a file. Deliveries in a separate
    # connection — even seconds apart, same visit — do not fire it (2026-08).
    if (pkvx[k] + 0 > 0)
        t = t "ROW\tConnection shared with UC4 drop\t@{href=../../analyses/uc2-visits.html}yes — " (pkvx[k] + 0) " connection" (pkvx[k] + 0 == 1 ? "" : "s") " both delivered and collected files\n"
    t = t "NOTE\tA **pickup** is a successful SSH logon by this flow's pickup account (server log), shared across that account's UC2 subscriptions; a partner collecting over CFT logs none. A visit in which the account **only delivered** files — its UC4 twin flow handing files over — is not a pickup: its logons are shown on their own row and excluded from every other figure. **Files picked up** counts this subscription's collected Files (transfer log); the page's OK figure also counts staged files still **Waiting**, so OK = picked up + waiting — the two match once nothing is left waiting. **With actual files** counts the pickups that collected at least one of them — each collected file credits the logon that took it (the newest at or before its collect stamp). **Current waiting / Expired files** are this flow's own staged files by outcome, as in the Waiting/Expired table. The **pattern** reads the typical spacing of the pickups. **Connection shared with UC4 drop** appears only on hard proof: one and the same technical SSH connection (the transfer log's Session ID) both delivered and collected a file — a delivery over a separate connection, even seconds apart in the same visit, does not count.\n"
    return t
}

FILENAME == SLUGMAP { if ($1 != "") slug[toupper($1)] = $2; next }
FILENAME ~ /_subscriptions-accounts\.tsv$/ { if ($1 != "" && $2 != "") suac[toupper($1)] = $2; next }   # subscription -> its account (the UC4 note lookup)
FILENAME ~ /uc2-pickups\.tsv$/ {
    k = toupper($1)
    # (a UC2 subscription wired to TWO accounts would last-wins here — the
    # sidecar is one line per (account, sub); 1:1 in practice)
    pki[k] = 1; pkf[k] = $3; pkl[k] = $4; pkn[k] = $5; pkw[k] = $6; pkc[k] = $7; pkp[k] = $8
    pkdl[k] = $9              # logons in delivery-only visits (the UC4 twin) — not pickups
    pkvx[k] = $18             # SHARED SESSIONS: technical connections (transfer-log Session
                              # IDs) that both delivered AND collected — the only
                              # same-connection proof; the time-window visit classes
                              # (cols 13/14) deliberately do NOT fire this row (2026-08)
    pkwt[k] = $16             # this subscription's staged files still Waiting
    pkxp[k] = $17             # … and Expired uncollected
    a9 = toupper($2)
    acv[a9] = $18             # the same shared-session count, keyed by ACCOUNT (the UC4 mirror)
    if (acu2[a9] == "") acu2[a9] = $1   # its (first) UC2 subscription, for the UC4 note's link
    next
}
# the UC4 mirror of the UC2 "Connection shared with UC4 drop" row: an extra
# INTRO line when this UC4 flow's account also COLLECTS UC2 files in the
# SAME technical SSH connection (the shared-session count — sidecar col 18;
# same-connection proof, never the time-window visit classes)
function uc4note(nm4,   a4, n4) {
    a4 = toupper(suac[toupper(nm4)])
    if (a4 == "" || acv[a4] + 0 == 0) return ""
    n4 = acv[a4] + 0
    return sprintf("INTRO\t**Same connection, both directions:** besides delivering here, this partner also **picks up UC2 files** in the very SSH connection that delivers — **%d** connection%s (by transfer-log Session ID) both delivered and collected files, the pickups from [[subscriptions/%s]]. The UC2 pickup visits analysis has the visit breakdown.\n", n4, plural(n4,"","s"), acu2[a4])
}

$1 != "ROW" { next }
{ nm = strip($3); s = slug[toupper(nm)]; st = strip($2); NEXTMOVE = ""; if (s == "") next }

# ---- UC1: we are the client and PUSH the file out to the partner ------------
FILENAME ~ /uc1-status\.rpt$/ {
    n = $4 + 0; ok = $5 + 0; er = $6 + 0; last = dt($7); runs = $8 + 0; prob = $9 + 0; lg = dt($10)
    if (st == "error" || st == "ok -> error" || st == "server - error") NEXTMOVE = nextmove(getll())
    if (st == "ok")
        emit(s, "", sprintf("**Working.** We push files out to this partner: **%d** File%s, the latest delivered on **%s** (%d OK, %d error). **UC1 status** calls this **ok**.", n, plural(n,"","s"), last, ok, er))
    else if (st == "error")
        emit(s, "This flow has never delivered a file", sprintf("Every one of its **%d** File%s failed, the last on **%s**, and not one was ever delivered — so this is not something that broke, it is something that never worked. Advanced Routing started the route **%d** time%s and logged **%d** failure%s%s. **UC1 status** calls this **error**.", n, plural(n,"","s"), last, runs, plural(runs,"","s"), prob, plural(prob,"","s"), on(lg)))
    else if (st == "ok -> error" && er == 0)
        # the after-last-transfer red flip: every File succeeded — the failure
        # evidence is the server log AFTER the last transfer (the red banner),
        # never a failed File, so the prose must not invent one (audit B2)
        emit(s, "This flow used to work and now fails", sprintf("Every one of its **%d** File%s was delivered, the latest on **%s** — but the server log has recorded **errors for this flow after that last transfer** (the banner above carries the evidence), so the latest word is failure. A regression on the connection side rather than a failed File. **UC1 status** calls this **ok -> error**.", n, plural(n,"","s"), last))
    else if (st == "ok -> error")
        emit(s, "This flow used to work and now fails", sprintf("It delivered **%d** of its **%d** File%s, but the latest one failed on **%s** — a regression, so there is a change to find rather than a configuration that was never finished. **UC1 status** calls this **ok -> error**.", ok, n, plural(n,"","s"), last))
    else if (st == "server - error")
        emit(s, "Never transferred a file, and the send is failing", sprintf("No File has ever reached the transfer log. The server log explains why: **%d** failure line%s name%s this flow%s — the send could not be made, or the partner could not be reached at all. **UC1 status** calls this **server - error**.", prob, plural(prob,"","s"), plural(prob,"s",""), on(lg)))
    else if (st == "server - no result")
        emit(s, "Never transferred a file, and nothing explains why", sprintf("No File has ever reached the transfer log, and no failure in the server log names this flow either%s. It may still be blue on a line attributed to its host or account rather than to itself. **UC1 status** calls this **server - no result**.", on(lg)))
    else if (st == "not seen")
        emit(s, "", "**Never used.** This flow is configured but has never been observed in either the transfer log or the server log — an open question rather than a failure: either it is waiting on a partner, or it should not be there. **UC1 status** calls this **not seen**.")
    next
}

# ---- UC2: we are the server, the partner CONNECTS IN AND COLLECTS -----------
FILENAME ~ /uc2-status\.rpt$/ {
    xp = $4 + 0; first = dt($5); last = dt($6); pk = $7 + 0; lpk = dt($8)
    ptbl = pktable(nm)
    # The verdicts stay QUALITATIVE (2026-08): every figure they used to
    # quote — pickup counts, latest stamps, arrival dates, delivery logons —
    # sits in the Pickup information table spliced right below (ptbl), so the
    # prose only names the situation and the report's word for it.
    if (st == "Never collected")
        emit(s, "Partner never collected UC2 waiting files", "We stage files for this partner and **nothing has ever been collected** — every staged file sits until the retention sweep deletes it. The staging side works; the question is for the partner. **UC2 status** calls this **Never collected**; the Pickup information and Waiting/Expired tables below have this flow's own figures.", ptbl)
    else if (st == "No files")
        emit(s, "The partner connects, but nothing is ever staged", "The partner DOES connect to collect, but the application has **never staged a single file** for it. The partner side is fine; the source side is dormant or broken. **UC2 status** calls this **No files**.", ptbl)
    else if (st == "Both")
        emit(s, "", "**Collecting, with losses.** The partner does connect and collect, yet files have still expired uncollected — both outcomes on the one flow, so it works without being healthy. **UC2 status** calls this **Both**; the tables below have the figures.", ptbl)
    else if (st == "OK")
        emit(s, "", "**Healthy.** Files are staged and the partner collects them. **UC2 status** calls this **OK**.", ptbl)
    else if (st == "Nothing")
        emit(s, "", "**Quiet.** Nothing has been collected and nothing has expired. Either there has been nothing to collect, the partner collects over CFT (which cannot be seen from here), or its visits have so far come up empty. **UC2 status** calls this **Nothing**.", ptbl)
    next
}

# ---- UC3: we are the client and POLL the partner for files ------------------
FILENAME ~ /uc3-status\.rpt$/ {
    n = $4 + 0; ok = $5 + 0; er = $6 + 0; last = dt($7); poll = $8 + 0; emp = $9 + 0; prob = $10 + 0; lg = dt($11)
    if (st == "error" || st == "ok -> error" || st == "server - error") NEXTMOVE = nextmove(getll())
    if (st == "ok" && n == 0)
        # the CLEAN-POLL cohort (blue/_greenpoll.tsv): verified polling, no
        # file ever there to fetch — no last-file date exists, so this branch
        # must not interpolate one (an empty **%s** breaks the bold pairing)
        emit(s, "", sprintf("**Working, nothing to fetch.** We poll this partner on schedule and the connection, the credentials and the remote directory are all fine — **%d** poll%s so far — but no file has ever been there to collect, so nothing has reached the transfer log. **UC3 status** calls this **ok** (the clean-poll rule: a verified working poll is green).", poll, plural(poll,"","s")))
    else if (st == "ok")
        emit(s, "", sprintf("**Working.** We poll this partner and pull what is waiting: **%d** File%s, the latest on **%s** (%d OK, %d error), from **%d** poll%s. A high empty-poll count (**%d**) is normal — a schedule fires far more often than a file appears. **UC3 status** calls this **ok**.", n, plural(n,"","s"), last, ok, er, poll, plural(poll,"","s"), emp))
    else if (st == "error")
        emit(s, "This flow has never pulled a file successfully", sprintf("Every one of its **%d** File%s failed, the last on **%s**, with no successful pull at all — not something that broke, something that never worked. **UC3 status** calls this **error**.", n, plural(n,"","s"), last))
    else if (st == "ok -> error" && er == 0)
        emit(s, "This flow used to work and now fails", sprintf("Every one of its **%d** File%s was pulled successfully, the latest on **%s** — but the server log has recorded **errors for this flow after that last transfer** (the banner above carries the evidence), so the latest word is failure. A regression on the connection side rather than a failed File. **UC3 status** calls this **ok -> error**.", n, plural(n,"","s"), last))
    else if (st == "ok -> error")
        emit(s, "This flow used to work and now fails", sprintf("It pulled **%d** of its **%d** File%s successfully, but the latest attempt failed on **%s** — a regression, so there is a change to find. **UC3 status** calls this **ok -> error**.", ok, n, plural(n,"","s"), last))
    else if (st == "server - no files")
        emit(s, "", sprintf("**Polling faultlessly, finding nothing.** The connection, the credentials and the remote directory are all fine — **%d** poll%s, the last one reporting zero files — but no file has ever been there to fetch, so nothing has ever reached the transfer log. Every slot spent here is a connection and a listing for no data. **UC3 status** calls this **server - no files**.", poll, plural(poll,"","s")))
    else if (st == "server - error")
        emit(s, "Never pulled a file, and the poll is failing", sprintf("No File has ever reached the transfer log, and the server log's latest word is that we could not retrieve: **%d** failure line%s%s — a connection failure, or a directory listing that failed once connected. **UC3 status** calls this **server - error**.", prob, plural(prob,"","s"), on(lg)))
    else if (st == "server - no result")
        emit(s, "Never pulled a file, and nothing explains why", "No File has ever reached the transfer log. The server log only ever PREPARES a poll for this flow — the \"Remote folder … evaluated to …\" lines — and then records neither a result nor an error. **UC3 status** calls this **server - no result**.")
    else if (st == "not seen")
        emit(s, "", "**Never used.** Configured, but never observed in either log. **UC3 status** calls this **not seen**.")
    next
}

# ---- UC4: we are the server, the partner CONNECTS IN AND DELIVERS -----------
FILENAME ~ /uc4-status\.rpt$/ {
    n = $4 + 0; ok = $5 + 0; er = $6 + 0; last = dt($7); lgn = $8 + 0; arr = $9 + 0; prob = $10 + 0; lg = dt($11)
    if (st == "error" || st == "ok -> error") NEXTMOVE = nextmove(getll())
    # a UC4 "server - error" is BY DEFINITION whitelist refusals (the only way
    # this flow breaks before a file exists — see that branch's prose), so the
    # move is hard-wired rather than classified
    else if (st == "server - error") NEXTMOVE = "**Next move: ours** — credentials/whitelisting."
    u4x = uc4note(nm)
    if (st == "ok")
        emit(s, "", sprintf("**Working.** The partner connects in and delivers: **%d** File%s, the latest on **%s** (%d OK, %d error), across **%d** handover%s. **UC4 status** calls this **ok**.", n, plural(n,"","s"), last, ok, er, arr, plural(arr,"","s")), u4x)
    else if (st == "error")
        emit(s, "This flow has never received a file successfully", sprintf("Every one of its **%d** File%s failed, the last on **%s** — not something that broke, something that never worked. **UC4 status** calls this **error**.", n, plural(n,"","s"), last), u4x)
    else if (st == "ok -> error" && er == 0)
        emit(s, "This flow used to work and now fails", sprintf("Every one of its **%d** File%s was received, the latest on **%s** — but the server log has recorded **errors for this flow after that last transfer** (the banner above carries the evidence), so the latest word is failure. A regression on the connection side rather than a failed File. **UC4 status** calls this **ok -> error**.", n, plural(n,"","s"), last), u4x)
    else if (st == "ok -> error")
        emit(s, "This flow used to work and now fails", sprintf("It received **%d** of its **%d** File%s, but the latest failed on **%s** — a regression, so there is a change to find. **UC4 status** calls this **ok -> error**.", ok, n, plural(n,"","s"), last), u4x)
    else if (st == "server - no files")
        emit(s, "The partner connects, but never sends anything", sprintf("The credentials work and the partner reaches us — **%d** successful logon%s — but it has **never handed over a single file**, so nothing has ever reached the transfer log. The flow is configured correctly; the question is for the partner. **UC4 status** calls this **server - no files**.", lgn, plural(lgn,"","s")), u4x)
    else if (st == "server - error")
        emit(s, "The partner is turned away at the door", sprintf("No File has ever reached the transfer log, and the partner never got in: its only attempts were **refused by the account whitelist** (**%d** rejection%s%s). Because we are the server here, that is the only way this flow can break before a file exists. **UC4 status** calls this **server - error**.", prob, plural(prob,"","s"), on(lg)), u4x)
    else if (st == "server - no result")
        emit(s, "Never received a file, and nothing explains why", "No File has ever reached the transfer log, and the server log says nothing either way about this flow. **UC4 status** calls this **server - no result**.", u4x)
    else if (st == "not seen")
        emit(s, "", "**Never used.** Configured, but never observed in either log — a flow set up and never used, or one whose partner side was never finished. **UC4 status** calls this **not seen**.", u4x)
    next
}

# ---- fallback: the Pickup information table WITHOUT a verdict row -----------
# The uc2-status table is ACCOUNT-keyed — one row per pickup account, its
# subscription cell the account's first UC2 flow. An account owning MANY UC2
# subscriptions (the production hybrid estate: one account, 350 derived-UC2
# flows) therefore carries one verdict row while the uc2-pickups.tsv sidecar
# holds every flow. Any UC2 subscription with sidecar figures but no verdict
# of its own still gets its Pickup information table.
END {
    for (k in pki) {
        s = slug[k]
        if (s == "" || (s in done)) continue
        done[s] = 1
        f = OUT "/" s ".txt"
        printf "%s", pktable(k) > f
        close(f)
    }
}
