# details_writer.awk — the per-entity detail-page WRITER, one entity TYPE per
# invocation (2026-07: the byte-identical awk port of details_lib.sh's former
# bash writer — run_detail_writer and every emit helper it called).
#
# Why awk: the bash loop forked $(printf …) per dimension row, ran ~11
# cat/sort/awk processes per page for the "Last server log messages" table and
# reopened the output file for every printf >> — details.sh spent more time in
# the kernel than in user space. This program holds each page in memory and
# writes it with ONE open/write/close.
#
# Invocation (details.sh, one background job per type over the writer pool):
#   LC_ALL=C awk -F'\t' -v TYPE=ACC -v ANN=<streams/a.ACC> -v OUTDIR=<dir> \
#       -v SRV=<server cache> -v FWD=<input/<env>/ip/ip-hosts.tsv> -v BLUE=<blue dir> \
#       -v UCF=<ucmeta dump> -v UCDF=<derived-uc dump> -v UNCF=<uncollected dump> -v OKF=<last-ok sidecar> \
#       -v NOW="YYYY-mm-dd HH:MM:SS" -v NFILES=<n input csvs> \
#       -f details_writer.awk <streams/s.ACC>
#
# The stream slice (s.TYPE) is the sorted per-type agg stream (see details.sh
# for the section protocol); ANN is the matching annotation slice, read
# SEQUENTIALLY — one line per entity in first-seen stream order, \x1e-separated
# fields (the list in details.sh's ANNOTATION PASS comment).
#
# BYTE-IDENTITY notes (the port is verified against the bash writer's output):
# - bash `IFS=$'\t' read -a F` collapsed TAB runs; the producers emit "-"
#   sentinels precisely so no empty middle field exists, so $i == F[i-1]
#   everywhere. The "-" -> blank conversions are kept.
# - `sort -t\t -k1,1r -k2,2r` under LC_ALL=C = key1 desc, key2 desc, then the
#   LAST-RESORT whole-line ASCENDING byte compare — srv_sort() reproduces
#   exactly that (and srt1() the -k1,1r variant for the uncollected table).
# - the dwell share keeps the bash truncate-then-round: int(dc*1e8/dt)/1e6
#   through printf %.1f (same libc as the bash builtin).

# ===== small helpers =========================================================
function emitl(s) { PG[++npg] = s }

function wdname(d) {
    if (d == 0) return "Monday";   if (d == 1) return "Tuesday"
    if (d == 2) return "Wednesday"; if (d == 3) return "Thursday"
    if (d == 4) return "Friday";   if (d == 5) return "Saturday"
    if (d == 6) return "Sunday";   return d
}

# first getline succeeds = the bash [ -s file ] test (caches never hold a
# lone empty line, so the size-vs-line nuance cannot bite)
    # endpoint -> its address(es), from input/<env>/ip/ip-hosts.tsv (keyed on its
# HOST column). Loaded once on first use; replaced a fwd/<name>.txt per endpoint.
function fwd_ips(h,   l, a, k) {
    if (!FWDL) {
        FWDL = 1
        if (FWD != "") { while ((getline l < FWD) > 0) { split(l, a, "\t")
                if (a[1] != "" && a[2] != "") FWDM[tolower(a[2])] = FWDM[tolower(a[2])] "\037" a[1] }
            close(FWD) }
    }
    k = tolower(h); return (k in FWDM) ? substr(FWDM[k], 2) : ""
}
function nonempty(f,   l, r) { r = 0; if ((getline l < f) > 0) r = 1; close(f); return r }

# split a \x1f-joined annotation list into arr[1..n]; "" -> 0 entries
function usplit(s, arr,   n) { if (s == "") { split("", arr); return 0 } n = split(s, arr, "\037"); return n }

# ===== the sort engines (emit_srv_lines_table / uncollected) =================
# comparator: field1 desc, field2 desc, whole line asc (srv_sort);
# field1 desc, whole line asc (srt1). Insertion sort — page inputs are small.
function keyf(l, which,   i1, i2, r) {
    i1 = index(l, "\t")
    if (i1 == 0) return (which == 1) ? l : ""
    if (which == 1) return substr(l, 1, i1 - 1)
    r = substr(l, i1 + 1)
    i2 = index(r, "\t")
    return (i2 == 0) ? r : substr(r, 1, i2 - 1)
}
function srv_before(a, b,   a1, b1, a2, b2) {   # does a sort before b?
    a1 = keyf(a, 1); b1 = keyf(b, 1)
    if (a1 != b1) return (a1 > b1)
    a2 = keyf(a, 2); b2 = keyf(b, 2)
    if (a2 != b2) return (a2 > b2)
    return (a < b)
}
function srv_sort(L, n,   i, j, t) {
    for (i = 2; i <= n; i++) { t = L[i]; j = i - 1
        while (j >= 1 && srv_before(t, L[j])) { L[j+1] = L[j]; j-- }
        L[j+1] = t }
}
function srt1_before(a, b,   a1, b1) {
    a1 = keyf(a, 1); b1 = keyf(b, 1)
    if (a1 != b1) return (a1 > b1)
    return (a < b)
}
function srt1_sort(L, n,   i, j, t) {
    for (i = 2; i <= n; i++) { t = L[i]; j = i - 1
        while (j >= 1 && srt1_before(t, L[j])) { L[j+1] = L[j]; j-- }
        L[j+1] = t }
}
# read every line of file f into L[++n]; returns the new n
function slurp(f, L, n,   l) { while ((getline l < f) > 0) L[++n] = l; close(f); return n }

# sort L[1..n], dedup on fields 1-5 (first survivor wins), keep at most cap;
# result in D[1..nd], returns nd
function dedup_cap(L, n, cap, D,   i, k, nd, m, C5) {
    srv_sort(L, n)
    split("", _dseen); nd = 0
    for (i = 1; i <= n; i++) {
        m = split(L[i], C5, "\t")
        k = C5[1] SUBSEP C5[2] SUBSEP C5[3] SUBSEP C5[4] SUBSEP C5[5]
        if (k in _dseen) continue
        _dseen[k] = 1
        nd++
        if (nd <= cap) D[nd] = L[i]
    }
    return (nd < cap) ? nd : cap
}

# ===== emit_srv_lines_table ==================================================
# REC[1..nrec] = the recent-source cache files, CN2[1..nconn] = the connected
# base files (their _err_warn siblings are derived here), st_cutoff = the
# "only Error/Warn after this" timestamp ("" = no connected merge).
function emit_srv_table(title, cutoff,   i, f, ewf, nA, nB, nC, nda, ndb, nall, k, m, C5, lvl, cmp, body, nrows, l) {
    if (nrec == 0 && nconn == 0) return
    # per-source pools: recent lines (cap 25), their _err_warn rings (cap 10),
    # the connected _err_warn lines after the cutoff (no dedup, no cap) — the
    # three-stage order is load-bearing, then everything merges, re-sorts and
    # dedups first-wins.
    split("", SA); nA = 0
    for (i = 1; i <= nrec; i++) nA = slurp(REC[i], SA, nA)
    nda = dedup_cap(SA, nA, 25, DA)
    split("", SB); nB = 0
    for (i = 1; i <= nrec; i++) { ewf = REC[i]; sub(/\.tsv$/, "_err_warn.tsv", ewf); if (nonempty(ewf)) nB = slurp(ewf, SB, nB) }
    ndb = dedup_cap(SB, nB, 10, DB)
    split("", SC); nC = 0
    if (cutoff != "") for (i = 1; i <= nconn; i++) {
        ewf = CN2[i]; sub(/\.tsv$/, "_err_warn.tsv", ewf)
        if (!nonempty(ewf)) continue
        while ((getline l < ewf) > 0) { if (keyf(l, 1) " " keyf(l, 2) > cutoff) SC[++nC] = l }
        close(ewf)
    }
    srv_sort(SC, nC)
    # merge and finalize
    split("", ALL); nall = 0
    for (i = 1; i <= nda; i++) ALL[++nall] = DA[i]
    for (i = 1; i <= ndb; i++) ALL[++nall] = DB[i]
    for (i = 1; i <= nC;  i++) ALL[++nall] = SC[i]
    srv_sort(ALL, nall)
    split("", _fseen); body = ""; nrows = 0
    for (i = 1; i <= nall; i++) {
        m = split(ALL[i], C5, "\t")
        k = C5[1] SUBSEP C5[2] SUBSEP C5[3] SUBSEP C5[4] SUBSEP C5[5]
        if (k in _fseen) continue
        _fseen[k] = 1
        # a SITE page suppresses the lines already told elsewhere on it: the
        # Last OK transfer section lines (S) and the last-error session lines
        # (X — shown on the error page the Last error row links). Keyed on the
        # PRE-fold field 5 — the sidecar carries the bare message field, while
        # the fold below appends the trailing SESSION column into the display
        if (pend_t == "SITE" && ((toupper(pend_e) SUBSEP C5[1] " " C5[2] SUBSEP C5[5]) in SUP)) continue
        # a literal TAB inside the message text splits into extra fields — fold
        # them back so the ROW keeps exactly five cells (the .rpt protocol
        # forbids TAB inside a cell)
        for (_tj = 6; _tj <= m; _tj++) C5[5] = C5[5] " " C5[_tj]
        lvl = (C5[3] == "I") ? "Info" : (C5[3] == "W") ? "@{class=warn}Warning" : (C5[3] == "E") ? "@{class=failed}Error" : C5[3]
        cmp = (C5[4] == "T") ? "TM" : (C5[4] == "P") ? "PESITD" : (C5[4] == "S") ? "SSHD" : C5[4]
        nrows++
        body = body (body == "" ? "" : "\n") sprintf("ROW\t%s\t%s\t%s\t%s\t%s", C5[1], C5[2], lvl, cmp, substr(C5[5], 1, 300))
    }
    if (body == "") return
    emitl("TABLE\t" title "\twide\tnofilter")
    emitl("HEAD\tDate\tTime\tLevel\tComponent\tMessage")
    emitl("KIND\ttext\ttext\ttext\ttext\ttext")
    emitl(sprintf("TOTAL\tTotal (%d line(s))\t\t\t\t", nrows))
    npg++; PG[npg] = body   # pre-joined rows, one buffer slot
}
# srv_lines_for SUBDIR NAME TITLE — one entity's recent (+ Error/Warn) lines,
# no connected sources (cutoff empty)
function srv_lines_for(sub2, name2, title2) {
    nrec = 1; REC[1] = SRV "/" sub2 "/" name2 ".tsv"; nconn = 0
    emit_srv_table(title2, "")
}

# ===== per-page helper tables ================================================
# blue evidence box: INTRO + LOGCARD from data/<env>/blue/<bt>/<name>.txt;
# sets bluebox so the generic banner is skipped
function blue_box(   f, line, i1, bmsg) {
    bluebox = 0
    f = BLUE "/" bt "/" pend_e ".txt"
    if ((getline line < f) > 0) {
        close(f)
        i1 = index(line, "\t")
        bmsg = (i1 ? substr(line, i1 + 1) : line); gsub(/\t/, " ", bmsg)   # a TAB inside the message must not add LOGCARD cells
        emitl("INTRO\t**Only seen in the server log**, never in the transfer log")
        emitl("LOGCARD\t" (i1 ? substr(line, 1, i1 - 1) : line) "\t" bmsg)
        bluebox = 1
    } else close(f)
}

function err_after_transfer_banner() {
    if (have_tot != 1 || tot_last == "" || a_bannerdt == "") return
    if (a_bannerdt > tot_last) {
        # when the page carries its own "Server log error" section (the flow
        # is in the server-failing set), the banner links straight to it;
        # otherwise the log still sits at the bottom and the old text holds
        if (pend_t == "SITE" && (toupper(pend_e) in SLG))
            emitl("ALERT\tERROR IN SERVER LOG AFTER LAST TRANSFER - SEE \t#srv-log-error\t'Server log error'")
        else
            emitl("ALERT\tERRORS IN SERVER LOG AFTER LAST TRANSFER - SEE LOG AT BOTTOM OF THIS PAGE")
    }
}

# ACCOUNT pages only: the account is configured but NO subscription references
# it (annotation field 31), so nothing can ever route a file through it. That is
# also why such a page's title prefix carries "?" as its movement side — with no
# subscription there is no flow direction to read. A config defect, not a
# runtime one, so it is a WARN (amber) rather than an ALERT (red).
function no_subscription_banner() {
    if (pend_t != "ACC" || a_nosub != "1") return
    emitl("WARN\tNOT CONNECTED TO ANY SUBSCRIPTION - this account is configured, but no subscription references it, so it can never transfer a file")
}

# ===== ensure_file / intro / summary =========================================
function ensure_file(   dirtok, xdisp, tpfx) {
    if (cur_path != "") return
    if (pend_t == "") return
    dirtok = (dirv == "in") ? "IN" : (dirv == "out") ? "OUT" : (dirv == "both") ? "BOTH" : "UNKNOWN"
    BOTHMODE = (dirv == "both") ? 1 : 0
    cur_path = OUTDIR "/" a_slug ".rpt"
    print pend_e "\t" a_slug > SM
    xdisp = (dirtok == "UNKNOWN") ? "?" : dirtok
    tpfx = ""
    if (xdisp != "?" || a_mv != "") tpfx = xdisp "/" (a_mv == "" ? "?" : a_mv) ": "
    emitl("TITLE\t" tpfx label ": " pend_e)
    emitl("DESC\t" desc)
    err_after_transfer_banner()
    no_subscription_banner()
    blue_box()
    if (IS_BLUE && pend_t != "SITE" && !bluebox)
        emitl("INTRO\tConfigured — **never seen** in the transfer log - **seen in the server log**")
    if (have_tot != 1) emit_intro()
}

# one Summary ROW per folded entity value (\x1f-joined), alink'd
function sum_ent(lbl, sub2, vals,   n, i, V) {
    n = usplit(vals, V)
    for (i = 1; i <= n; i++) if (V[i] != "") emitl("ROW\t" lbl "\t@{alink=" sub2 "/" V[i] "}" V[i])
}
# the Domain / Application / Logical / Partner group rows ("Label\tName" \x1f-joined)
function sum_groups(rows,   n, i, V, i1, gt, gn, gs) {
    n = usplit(rows, V)
    for (i = 1; i <= n; i++) {
        i1 = index(V[i], "\t"); if (i1 == 0) continue
        gt = substr(V[i], 1, i1 - 1); gn = substr(V[i], i1 + 1)
        if (gn == "") continue
        gs = (gt == "Domain") ? "domains" : (gt == "Application") ? "applications" : (gt == "Logical") ? "logicals" : (gt == "Partner") ? "partners" : "bl"
        emitl("ROW\t" gt "\t@{alink=" gs "/" gn "}" gn)
    }
}
function sum_loc(lbl, d, mask,   sep) {
    if (d == "") { emitl("ROW\t" lbl "\t-"); return }
    if (mask != "") {
        if (d ~ /[\\\/]$/) sep = ""
        else if (index(d, "\\")) sep = "\\"
        else sep = "/"
        emitl("ROW\t" lbl "\t@{mask=" sep mask "}" d)
    } else emitl("ROW\t" lbl "\t" d)
}
function sum_locations() {
    if (a_flowdir == "in") { sum_loc("From", a_remote, a_rmask); sum_loc("To", a_local, a_lmask) }
    else                   { sum_loc("From", a_local, a_lmask);  sum_loc("To", a_remote, a_rmask) }
}
function sum_config(   c) {
    sum_ent("Remote host", "hosts", a_sdh)
    # Login ABOVE Account (2026-07): the two name the same participant at
    # different levels — the login is what actually authenticates, the account
    # is what it belongs to — so the row order reads inward, endpoint to owner.
    sum_ent("Login", "logins", a_sdl)
    sum_ent("Account", "accounts", a_sda)
    sum_groups(a_grp)
    if (a_cron != "") {
        c = a_cron; gsub(/\037/, "/", c)
        emitl("ROW\tCron\t" c)
        emitl("ROW\tSchedule\t" a_cronh)
    }
}
function uc_desc(name,   uc) {
    if (match(name, /^UC[0-9]+/) == 0) {
        # no UC prefix in the name: fall back to the use case details.sh
        # DERIVED from the configured pattern + movement direction (UCDF);
        # absent there too (a relay, an unknown pattern shape) -> no row
        if ((name in DUC) && (DUC[name] in UCH) && UCH[DUC[name]] != "")
            return DUC[name] " - " UCH[DUC[name]] " (derived from the configured pattern and direction)"
        return ""
    }
    uc = substr(name, 1, RLENGTH)
    if (!(uc in UCH) || UCH[uc] == "") return ""
    return uc " - " UCH[uc]
}
# The TWIN row (annotation field 32), on ACCOUNT and SUBSCRIPTION pages alike —
# the entity this one is easiest to mistake for. On an ACCOUNT that is the same
# name spelled with the other separator (FRE-SAPCD-X against FRE_SAPCD_X); on a
# SUBSCRIPTION it is the same flow configured in the opposite file direction
# (see details.sh for the two rules that find it). They are DIFFERENT entities
# and are never merged, but each is worth naming on the other page. The alink
# resolves through that type OWN slugmap, and render_rpt.awk tints an alink cell
# by the LINKED entity own result, so the twin carries its own colour, not this
# page one.
function twin_features_rows(   n, i, V, sd) {
    n = usplit(a_twin, V)
    if (n == 0) return
    sd = (pend_t == "SITE") ? "subscriptions" : "accounts"
    for (i = 1; i <= n; i++) if (V[i] != "") emitl("ROW\tTwin\t@{alink=" sd "/" V[i] "}" V[i])
}
# ACCOUNT pages only: the configured FE login / host Features rows.
function acct_features_rows(   n, i, V) {
    n = usplit(a_acl, V)
    for (i = 1; i <= n; i++) if (V[i] != "") emitl("ROW\tLogin\t@{alink=logins/" V[i] "}" V[i])
    n = usplit(a_ach, V)
    for (i = 1; i <= n; i++) if (V[i] != "") emitl("ROW\tHost\t@{alink=hosts/" V[i] "}" V[i])
}

# The Last error(s) table (2026-08), first thing on every NON-subscription page
# that has one: for each subscription this entity moves files with and that has
# an error, that subscription's newest one — newest first, one row each. The
# WHOLE row opens the file's error page (rowlink + @data:href), the subscription
# name included: @{nolink=1} keeps its `site` KIND from linking to the detail
# page instead, exactly as on the Last-failed list. The CoreId a row points at
# is a subscription's newest error, which failed.sh guarantees a page for
# — linkcheck is the net if that ever stops being true.
# A SUBSCRIPTION page gets its own "Last error" section instead, placed
# directly ABOVE the "Last OK transfer" section (2026-08; it replaced the
# Features "Last error" row). Since 2026-08 it is the REAL CONTENT of the
# newest failed File's error page errors/<coreid>.rpt — the legs table and
# the server-log table spliced verbatim (the srv_log_error_section shape;
# the facts table stays out: the page already knows its subscription, and
# the file name goes into the heading like Last OK transfer's) — never a
# mere link row. The spliced server lines join the suppression set so Last
# server log messages does not repeat them, and a LINK below the section
# still opens the full error page. failed.sh guarantees the .rpt for a
# subscription's newest error; if it is missing anyway, the old one-row
# link table is the fallback.
function last_error_section(   k9, f9, l9, n9a, C9a, st9, legs9, srv9, nl9, ns9, F9, cid9) {
    if (pend_t != "SITE" || nle == 0) return
    k9 = toupper(pend_e)
    split(LE[nle], F9, "\t")
    cid9 = F9[4]
    f9 = ERRD "/" cid9 ".rpt"
    st9 = 0; legs9 = ""; srv9 = ""; nl9 = 0; ns9 = 0
    while ((getline l9 < f9) > 0) {
        if (index(l9, "HEAD\tStatus\tDirection\t") == 1) { st9 = 1; continue }
        if (index(l9, "HEAD\tDate & time\tLevel\tLine") == 1) { st9 = 2; continue }
        if (st9 == 0) continue
        if (index(l9, "ROW\t") != 1) {
            if (l9 ~ /^(TABLE|TOTAL|LINK|FOOT|NOTE)\t/ || l9 ~ /^(TABLE|TOTAL|LINK|FOOT)$/) st9 = 0
            continue
        }
        if (st9 == 1) { legs9 = legs9 l9 "\n"; nl9++ }
        else {
            n9a = split(l9, C9a, "\t")
            if (n9a < 4) continue
            srv9 = srv9 l9 "\n"; ns9++
            SUP[k9 SUBSEP C9a[2] SUBSEP C9a[4]] = 1
        }
    }
    close(f9)
    if (nl9 == 0) {
        emitl("TABLE\tLast error\trowlink\trestint\tnosort\tnosearch")
        emitl("HEAD\tDate & time\tFile")
        emitl("KIND\ttext\tmono")
        emitl("ROW\t@{href=../../errors/" cid9 ".html}" F9[1] \
              "\t@{href=../../errors/" cid9 ".html}" F9[3] \
              "\t@data:href=../../errors/" cid9 ".html\t@data:res=red")
        return
    }
    emitl("TABLE\tLast error — " F9[3] "\twide\tnosearch")
    emitl("HEAD\tStatus\tDirection\tProtocol\tSize\tDate & time\tDuration\tRemote host\tTransfer ID")
    emitl("KIND\ttext\ttext\ttext\tnum\ttext\tnum\thost\tmono")
    n9a = split(legs9, C9a, "\n")
    for (l9 = 1; l9 <= n9a; l9++) if (C9a[l9] != "") emitl(C9a[l9])
    if (ns9 > 0) {
        emitl("TABLE\t\twide\trestint\tnosort\tnosearch")
        emitl("HEAD\tDate & time\tLevel\tLine")
        emitl("KIND\ttext\ttext\tpre")
        n9a = split(srv9, C9a, "\n")
        for (l9 = 1; l9 <= n9a; l9++) if (C9a[l9] != "") emitl(C9a[l9])
    }
    emitl("LINK\t../../errors/" cid9 ".html\tOpen this error's page")
}
function last_error_table(   i, F9, cid, res) {
    if (pend_t == "SITE" || nle == 0) return
    emitl("TABLE\tLast error(s)\trowlink\trestint\tnosort\tnosearch")
    emitl("HEAD\tDate & time\tSubscription\tFile")
    emitl("KIND\ttext\tsite\tmono")
    # the rows arrive oldest-first (SORTKEY = the File sortkey) — walk back
    for (i = nle; i >= 1; i--) {
        split(LE[i], F9, "\t")
        cid = F9[4]
        res = "\t@data:res=red"   # every row is a FAILED file (expiries are out, 2026-08)
        emitl("ROW\t@{href=../../errors/" cid ".html}" F9[1] \
              "\t@{href=../../errors/" cid ".html,nolink=1}" F9[2] \
              "\t@{href=../../errors/" cid ".html}" F9[3] \
              "\t@data:href=../../errors/" cid ".html" res)
    }
    emitl("TOTAL\tTotal (" nle " subscription(s))\t\t")
}
function emit_intro(   ucd, nca, i, CA, dupacct) {
    if (intro_done == 1) return
    intro_done = 1
    ensure_file()
    last_error_table()
    ucd = (pend_t == "SITE") ? uc_desc(pend_e) : ""
    nca = (pend_t == "LOGIN") ? usplit(a_cfgacct, CA) : 0
    if (have_tot != 1) {
        # never-seen (and blue) pages: the config banner + the config-only
        # Features table
        if (IS_BLUE && pend_t != "SITE") { }   # banner already at file open
        else if (x_blue != "") {
            if (!bluebox) emitl("INTRO\tConfigured — **never seen** in the transfer log - **seen in the server log**")
        }
        else if (pend_t == "SITE") emitl("INTRO\tConfigured — **never seen** in the loaded transfer logs.")
        else emitl("INTRO\tConfigured (direction: **" dirv "**) — **never seen** in the loaded transfer logs.")
        if (pend_t == "SITE") {
            emitl("TABLE\tFeatures"); emitl("HEAD\tItem\tValue"); emitl("KIND\ttext\ttext")
            if (ucd != "") emitl("ROW\tUse case\t@{href=../../analyses/use-cases.html}" ucd)
            twin_features_rows()
            sum_config()
            sum_locations()
        } else if (pend_t == "ACC" || x_grpfold != "" || nca > 0) {
            emitl("TABLE\tFeatures"); emitl("HEAD\tItem\tValue"); emitl("KIND\ttext\ttext")
            for (i = 1; i <= nca; i++) if (CA[i] != "") emitl("ROW\tAccount\t@{alink=accounts/" CA[i] "}" CA[i])
            twin_features_rows()
            acct_features_rows()
            if (x_grpfold != "") { npg++; PG[npg] = x_grpfold }
        }
        return
    }
    # seen pages: the Features table (configuration only), suppressed when it
    # would carry nothing
    if (pend_t == "SITE" || pend_t == "ACC" || x_ip != "" || x_oneacct != "" || x_onedom != "" || x_oneapp != "" || x_onelgc != "" || x_oneptn != "" || x_onebl != "" || nca > 0) {
        emitl("TABLE\tFeatures"); emitl("HEAD\tItem\tValue"); emitl("KIND\ttext\ttext")
        if (ucd != "") emitl("ROW\tUse case\t@{href=../../analyses/use-cases.html}" ucd)
        dupacct = 0
        for (i = 1; i <= nca; i++) if (CA[i] != "") {
            emitl("ROW\tAccount\t@{alink=accounts/" CA[i] "}" CA[i])
            if (toupper(CA[i]) == toupper(x_oneacct)) dupacct = 1
        }
        if (x_oneacct != "" && !dupacct) emitl("ROW\tAccount\t@{alink=accounts/" x_oneacct "}" x_oneacct)
        if (x_ip != "") emitl("ROW\tIP\t" x_ip)
        twin_features_rows()
        acct_features_rows()
        if (pend_t == "SITE") sum_config()
        if (x_onedom != "") emitl("ROW\tDomain\t@{alink=domains/" x_onedom "}" x_onedom)
        if (x_oneapp != "") emitl("ROW\tApplication\t@{alink=applications/" x_oneapp "}" x_oneapp)
        if (x_onelgc != "") emitl("ROW\tLogical\t@{alink=logicals/" x_onelgc "}" x_onelgc)
        if (x_oneptn != "") emitl("ROW\tPartner\t@{alink=partners/" x_oneptn "}" x_oneptn)
        if (x_onebl != "") emitl("ROW\tBL\t@{alink=bl/" x_onebl "}" x_onebl)
        if (pend_t == "SITE") sum_locations()
    }
}

# the Duration / Size / Date / Ranking sxs=4 quartet (seen, non-blue pages)
# 2026-08: the rank rows link the RANKING report (retired 2026-07, back with
# the sidecars): that entity TYPE's page, sorted on this metric's own position
# column and scrolled to THIS entity's row (?axway_row), so a click lands on
# the very number the row shows with the neighbours around it. The position
# columns are 1/3/5/7/9 — each metric is a (#position, value) pair after the
# name column. ?axway_row also makes the page open at the FULL range, which is
# the period these positions were computed over.
function rlink(col, txt) {
    return "@{href=../../transfer/ranking-" rk ".html?axway_sort=" col ":1&axway_row=" uenc(rank_name) "}" txt
}
# percent-encode a name for the query string (the ORD table is built in BEGIN);
# a byte the table does not know — a non-ASCII one — is passed through.
function uenc(s,   i, c, o) {
    o = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c ~ /[A-Za-z0-9._~-]/) o = o c
        else if (c in ORD) o = o sprintf("%%%02X", ORD[c])
        else o = o c
    }
    return o
}
function emit_perf_tables(   P, np, pmin, pavg, p50, p95, p99, pmax, pthr, D5, dr5, tr5, drc, trc) {
    if (perf_done == 1) return
    perf_done = 1
    if (have_tot != 1) return
    if (IS_BLUE) return
    pmin = "-"; pavg = "-"; p50 = "-"; p95 = "-"; p99 = "-"; pmax = "-"; pthr = "-"
    if (x_perf != "") { np = split(x_perf, P, "|"); pmin = P[2]; pavg = P[3]; p50 = P[4]; p95 = P[5]; p99 = P[6]; pmax = P[7]; pthr = P[8] }
    emitl("TABLE\tDuration\tsxs=4\tnosearch"); emitl("HEAD\tMetric\tValue"); emitl("KIND\ttext\ttext")
    emitl("ROW\tmin\t" pmin); emitl("ROW\tavg\t" pavg); emitl("ROW\tmax\t" pmax)
    emitl("ROW\tp50\t" p50); emitl("ROW\tp95\t" p95); emitl("ROW\tp99\t" p99)
    emitl("TABLE\tSize\tsxs=4\tnosearch"); emitl("HEAD\tMetric\tValue"); emitl("KIND\ttext\ttext")
    emitl("ROW\tVolume\t" tot_h); emitl("ROW\tThroughput\t" pthr)
    emitl("ROW\tAverage\t" tot_avg); emitl("ROW\tLargest\t" tot_largest)
    emitl("TABLE\tDate\tsxs=4\tnosearch"); emitl("HEAD\tMetric\tValue"); emitl("KIND\ttext\ttext")
    emitl("ROW\tFirst seen\t" tot_first); emitl("ROW\tLast seen\t" tot_last)
    emitl("ROW\tBusiest day\t" busy_day)
    emitl("ROW\tActive\t" tot_act " day(s), idle " tot_idle " day(s)")
    dr5 = ""; tr5 = ""
    if (x_dtrank != "") { split(x_dtrank, D5, "|"); dr5 = D5[1]; tr5 = D5[2] }
    drc = (dr5 != "") ? "#" dr5 : "-"
    trc = (tr5 != "") ? "#" tr5 : "-"
    emitl("TABLE\tRanking - " tot_n " " typenoun "\tsxs=4\tnosearch")
    emitl("HEAD\tType\tPosition\tUnit"); emitl("KIND\ttext\tnum\tnum")
    emitl("ROW\t" rlink(1, "Files") "\t#" tot_rank "\t" tot_recs " - " tot_share "%")
    emitl("ROW\t" rlink(3, "Volume") "\t#" tot_srank "\t" tot_h " - " tot_sshare "%")
    emitl("ROW\t" rlink(5, "Errors") "\t#" tot_erank "\t" tot_pct "%")
    emitl("ROW\t" rlink(7, "Duration") "\t" drc "\t" pavg)
    emitl("ROW\t" rlink(9, "Throughput") "\t" trc "\t" pthr)
    # the RANKING report's sidecar (2026-08): the same five positions, one line
    # per entity, so the standalone report and this table are the same numbers
    # by construction. One file per TYPE — the writers run in parallel — and
    # awk's first `>` truncates it, so a re-run never appends to stale rows.
    # Only the entities that reach here are ranked: seen, non-blue, with totals.
    if (RANKOUT != "")
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            rank_name, tot_n, tot_recs, tot_rank, tot_h, tot_srank, tot_pct, tot_erank, \
            pavg, dr5, pthr, tr5, rank_buckets() > RANKOUT
}

# The Ranking report's @data:buckets payload for this entity:
# "date:files:errors:bytes:timed:ms:timedbytes" per active day. Files/Errors/
# Volume come from the per-day rows, the last three from the 0/7 line — the
# TIMED population the Duration and Throughput averages are taken over, which
# is a subset of the Files (an untimed or failed transfer is not in it).
function rank_buckets(   i, d, np, P, j, s, tn, tm, tb) {
    if (nbk == 0) return ""
    if (x_pday != "") {
        np = split(x_pday, P, "|")
        for (j = 1; j <= np; j++) {
            i = index(P[j], ":"); if (i == 0) continue
            d = substr(P[j], 1, i - 1)
            split(substr(P[j], i + 1), Q, ":")
            pd_n[d] = Q[1] + 0; pd_m[d] = Q[2] + 0; pd_b[d] = Q[3] + 0
        }
    }
    s = ""
    for (i = 1; i <= nbk; i++) {
        d = bk_ord[i]
        tn = (d in pd_n) ? pd_n[d] : 0; tm = (d in pd_m) ? pd_m[d] : 0; tb = (d in pd_b) ? pd_b[d] : 0
        s = s (s == "" ? "" : ",") d ":" bk_f[d] ":" bk_e[d] ":" bk_b[d] ":" tn ":" tm ":" tb
    }
    split("", pd_n); split("", pd_m); split("", pd_b)
    return s
}

# ===== the section table heads ===============================================
# the Logical+PDA quad pages (their dimension tables always render, restint'd)
function quadp() { return (pend_t == "PTN" || pend_t == "APP" || pend_t == "DOM" || pend_t == "LGC" || pend_t == "BL") }
function dim_table(lbl, kind, mods, title) {
    emitl("TABLE\t" title (mods != "" ? "\t" mods : ""))
    if (TMODE == 1) {
        emitl("HEAD\t" lbl "\t" cntlabel "\tIn - Error\tIn - OK\tOut - Error\tOut - OK\tVolume")
        emitl("KIND\t" kind "\tnum\tnumfailed\tnumprocessed\tnumfailed\tnumprocessed\tnum")
    } else {
        emitl("HEAD\t" lbl "\t" cntlabel "\tError\tOK\tVolume")
        emitl("KIND\t" kind "\tnum\tnumfailed\tnumprocessed\tnum")
    }
}
function time_table(title, lbl, mods) {
    emitl(mods != "" ? "TABLE\t" title "\t" mods : "TABLE\t" title)
    if (TMODE == 1) {
        emitl("HEAD\t" lbl "\t" cntlabel "\tIn - Error\tIn - OK\tOut - Error\tOut - OK\tVolume")
        emitl("KIND\ttext\tnum\tnumfailed\tnumprocessed\tnumfailed\tnumprocessed\tnum")
    } else {
        emitl("HEAD\t" lbl "\t" cntlabel "\tError\tOK\tVolume")
        emitl("KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum")
    }
}
function start_table(s,   WEH, WEK) {
    WEH = ""; WEK = ""
    if (HAS_WE == 1) { WEH = "\tWaiting\tExpired"; WEK = "\tnumwarn\tnumfailed" }
    if (s == "1") {
        emitl("TABLE\tActivity per day\tpager=10")
        if (TMODE == 1) { emitl("HEAD\tDate\t" cntlabel "\tIn - Error\tIn - OK\tOut - Error\tOut - OK\tVolume\tDuration"); emitl("KIND\ttext\tnum\tnumfailed\tnumprocessed\tnumfailed\tnumprocessed\tnum\tnum") }
        # SITE pages carry RECOVERED between Error and OK (2026-08-29):
        # Files of that day that had a FAILED leg but still finished OK
        else if (pend_t == "SITE") { emitl("HEAD\tDate\t" cntlabel "\tError\tRecovered\tOK\tVolume\tDuration"); emitl("KIND\ttext\tnum\tnumfailed\tnumwarn\tnumprocessed\tnum\tnum") }
        else            { emitl("HEAD\tDate\t" cntlabel "\tError\tOK\tVolume\tDuration"); emitl("KIND\ttext\tnum\tnumfailed\tnumprocessed\tnum\tnum") }
    } else if (s == "2") {
        # every type titles its breakdowns like the other tables (2026-08)
        emitl("TABLE\tSubscriptions\tseenrows\trestint")
        if (TMODE == 1) {
            emitl("HEAD\tSubscription\tDirection\t" cntlabel "\tIn - Error\tIn - OK\tOut - Error\tOut - OK" WEH "\tVolume")
            emitl("KIND\tsite\ttext\tnum\tnumfailed\tnumprocessed\tnumfailed\tnumprocessed" WEK "\tnum")
        } else {
            emitl("HEAD\tSubscription\tDirection\t" cntlabel "\tError\tOK" WEH "\tVolume")
            emitl("KIND\tsite\ttext\tnum\tnumfailed\tnumprocessed" WEK "\tnum")
        }
    }
    else if (s == "10") time_table("Load by weekday", "Weekday", "sxs")
    else if (s == "11") time_table("Load by hour", "Hour", "sxs")
    else if (s == "12.6") { emitl("TABLE\tDwell\tsxs=4"); emitl("HEAD\tDwell\tFiles\tShare"); emitl("KIND\ttext\tnum\tnum") }
    else if (s == "0.9") { emitl("TABLE\tWaiting/Expired\trestint\tnosearch"); emitl("HEAD\tState\tFiles\tFirst staged\tLast staged"); emitl("KIND\ttext\tnum\ttext\ttext") }
    else if (s == "9") { emitl("TABLE\tLatest " ((TYPE == "SITE") ? "500" : "100") " " cntlabel "\twide\tpager=" ((TYPE == "SITE") ? "20" : "10") "\trestint"); emitl("HEAD\tDate\tState\tDirection\tSize\tThroughput\tDuration\t" big_col "\tCoreId"); emitl("KIND\ttext\ttext\ttext\tnum\tnum\tnum\t" big_kind "\tmono") }
    else if (s == "2.6") { emitl("TABLE\tIncoming connections\tsxs=3\tfold=orange|{n} IPs in whitelist without traffic"); emitl("HEAD\tIP\tIn\tOut"); emitl("KIND\tmono\tnum\tnum") }   # no Name column: incoming addresses are the partner's own and never resolve to a configured endpoint (verified 0 of 30k rows)
    else if (s == "2.7") { emitl("TABLE\tOutgoing connections\tsxs=3\tfold=orange|{n} hosts configured without traffic"); emitl("HEAD\tIP\tIn\tOut\tName"); emitl("KIND\tmono\tnum\tnum\tmono") }
    else if (s == "2.8") {
        emitl("TABLE\tAccounts\tseenrows")
        if (TMODE == 1) { emitl("HEAD\tAccount\tLogin\tHost\t" cntlabel "\tIn - Error\tIn - OK\tOut - Error\tOut - OK\tVolume"); emitl("KIND\tacct\tlogin\thost\tnum\tnumfailed\tnumprocessed\tnumfailed\tnumprocessed\tnum") }
        else            { emitl("HEAD\tAccount\tLogin\tHost\t" cntlabel "\tError\tOK\tVolume"); emitl("KIND\tacct\tlogin\thost\tnum\tnumfailed\tnumprocessed\tnum") }
    }
    else if (s == "2.81") dim_table("Domain", "dom", quadp() ? "seenrows\tsxs=5\trestint" : "seenrows\tsxs=5", "Domains")
    else if (s == "2.82") dim_table("Application", "app", quadp() ? "seenrows\tsxs=5\trestint" : "seenrows\tsxs=5", "Applications")
    else if (s == "2.83") dim_table("Logical", "lgc", quadp() ? "seenrows\tsxs=5\trestint" : "seenrows\tsxs=5", "Logical")
    else if (s == "2.84") dim_table("Partner", "ptn", quadp() ? "seenrows\trestint" : "seenrows", "Partners")
    else if (s == "2.85") dim_table("BL", "bl", quadp() ? "seenrows\tsxs=5\trestint" : "seenrows\tsxs=5", "BL")
    # the Logical+PDA pages' Logins (3) and Hosts (4) tables (2026-08-29): sxs=5
    # joins them into the Domains/Applications flex row; no restint — these
    # rows carry no result payload, seenrows tints green/red alone
    else if (s == "3") dim_table("Login", "login", "seenrows\tsxs=5", "Logins")
    else if (s == "4") dim_table("Remote Host", "host", "seenrows\tsxs=5", "Hosts")
}

# ===== section buffering (BOTHMODE) ==========================================
function push_row(rb, rp, ic, oc) {
    nbb++; BB[nbb] = rb; BP[nbb] = rp
    if (ic > 0) sec_in = 1
    if (oc > 0) sec_out = 1
}
function day_total(mode) {
    if (have_tot != 1) return
    if (mode == 1)
        emitl(sprintf("TOTAL\tTotal (%s day(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num}%s", day_rows, tot_recs, tot_fi, tot_pi, tot_fo, tot_po, tot_h, tot_duravg))
    else if (pend_t == "SITE")
        emitl(sprintf("TOTAL\tTotal (%s day(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num warn}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num}%s", day_rows, tot_recs, tot_f, (tot_rv + 0 > 0 ? tot_rv : ""), tot_p, tot_h, tot_duravg))
    else
        emitl(sprintf("TOTAL\tTotal (%s day(s))\t@{class=num}%s\t@{class=num failed}%s\t@{class=num processed}%s\t@{class=num}%s\t@{class=num}%s", day_rows, tot_recs, tot_f, tot_p, tot_h, tot_duravg))
}
function finish_section(   i) {
    if (buf_sec != "") {
        TMODE = 0
        if (sec_in == 1 && sec_out == 1) TMODE = 1
        start_table(buf_sec)
        for (i = 1; i <= nbb; i++) emitl(TMODE == 1 ? BB[i] : BP[i])
        if (buf_sec == "1") day_total(TMODE)
        nbb = 0; buf_sec = ""; sec_in = 0; sec_out = 0
    } else if (cur_sec == "1") day_total(0)
}

# ===== the closing tables ====================================================
function uncollected_files_table(   u, n, i, L, nrows) {
    u = toupper(pend_e)
    if (!(u in UNL)) return
    n = split(UNL[u], L, "\n")
    srt1_sort(L, n)
    nrows = (n < 100) ? n : 100
    if (nrows == 0) return
    emitl("TABLE\tFiles not picked up\twide\tnofilter\tpager=10")
    emitl("HEAD\tExpired\tFile")
    emitl("KIND\ttext\tmono")
    for (i = 1; i <= nrows; i++) emitl("ROW\t" L[i])
    emitl(sprintf("TOTAL\tTotal (%d file(s))\t", nrows))
}
# blue SITE fallback: the connected accounts' (else logins') and hosts' lines
function srv_lines_enriched(   n, i, V, any_acct, fw, ip) {
    if (pend_t != "SITE") return
    any_acct = 0
    n = usplit(a_suba, V)
    for (i = 1; i <= n; i++) {
        if (!nonempty(SRV "/accounts/" V[i] ".tsv")) continue
        srv_lines_for("accounts", V[i], "Last server log messages — account " V[i]); any_acct = 1
    }
    if (!any_acct) {
        n = usplit(a_subl, V)
        for (i = 1; i <= n; i++) if (V[i] != "") srv_lines_for("logins", V[i], "Last server log messages — login " V[i])
    }
    n = usplit(a_subh, V)
    for (i = 1; i <= n; i++) {
        if (V[i] == "") continue
        srv_lines_for("hosts", V[i], "Last server log messages — host " V[i])
        nfw = split(fwd_ips(V[i]), afw, "\037")
        for (fi = 1; fi <= nfw; fi++) if (afw[fi] != "") srv_lines_for("hosts", afw[fi], "Last server log messages — host " V[i] " (" afw[fi] ")")
    }
}
function page_srv_log(   f, n, i, V, fw, ip, nc, C9) {
    if (sdir == "") return
    nrec = 0; nconn = 0
    f = SRV "/" sdir "/" pend_e ".tsv"
    if (nonempty(f)) REC[++nrec] = f
    if (pend_t == "ACC") {
        n = usplit(a_acl, V)
        for (i = 1; i <= n; i++) { f = SRV "/logins/" V[i] ".tsv"; if (nonempty(f)) REC[++nrec] = f }
        n = usplit(a_ach, V)
        for (i = 1; i <= n; i++) {
            f = SRV "/hosts/" V[i] ".tsv"; if (nonempty(f)) REC[++nrec] = f
            nfw = split(fwd_ips(V[i]), afw, "\037")
            for (fi = 1; fi <= nfw; fi++) if (afw[fi] != "") { f = SRV "/hosts/" afw[fi] ".tsv"; if (nonempty(f)) REC[++nrec] = f }
        }
    }
    if (have_tot == 1) { nc = usplit(a_conn, C9); for (i = 1; i <= nc; i++) CN2[++nconn] = C9[i] }
    if (nrec == 0) {
        if (x_blue != "" || IS_BLUE) srv_lines_enriched()
        # a never-seen login still gets its Logons table — "Never" is a fact
        if (have_tot != 1) { logons_section(); host_logons_section(); return }
    }
    logons_section()
    host_logons_section()
    srv_log_error_section()
    last_error_section()
    last_ok_section()
    emit_srv_table("Last server log messages", tot_last)
}

# The "Logons" table (LOGIN pages, 2026-08): first/last successful
# authentication of this login in the server log (any protocol daemon), the
# raw logon count and the cadence label — the Pickup-pattern vocabulary —
# plus the seven [Ssh Default] screening-funnel counts, the same figures as
# the server Logon report's Incoming columns (bin/logons.sh computes both
# consumers' file). A zero funnel count emits NO row; a login the server
# log never saw authenticate shows em-dash stamps, 0 and "Never".
function logons_section(   k9, F9, i9, n9, FL) {
    if (pend_t != "LOGIN") return
    k9 = toupper(pend_e)
    # no logons AND no funnel activity: no table at all (2026-08 — the
    # em-dash/0/Never placeholder rows said nothing)
    if (LGO[k9] == "") return
    split(LGO[k9], F9, "\t")
    emitl("TABLE\tLogons\trestint\tnosearch")
    emitl("HEAD\tItem\tValue\tLast")
    emitl("KIND\ttext\ttext\ttext")
    # the summary rows only for a login that ever LOGGED ON: on a
    # never-authenticated login (pattern Never) they carried only dashes
    # and zeros, so its table is just the screening-funnel rows (2026-08).
    # The last logon rides the Number-of-logons row's Last column
    # (2026-08 — it replaced the separate "Last logon" row).
    if (F9[3] + 0 > 0) {
        emitl("ROW\tFirst logon\t" (F9[1] == "-" ? "\342\200\224" : substr(F9[1], 1, 19)) "\t")
        emitl("ROW\tPattern\t" F9[4] "\t")
        emitl("ROW\tNumber of logons\t" F9[3] "\t" (F9[2] == "-" ? "" : substr(F9[2], 1, 19)))
    }
    n9 = split("Allowed\037Disallowed\037Authenticated\037No account\037Bad key\037Key failures\037Locked\037Auth failed", FL, "\037")
    for (i9 = 1; i9 <= n9; i9++) {
        # Authenticated (SSH-only) duplicates the any-protocol logon
        # count on an SSH-only login — the usual case; show the row
        # only when the two differ (2026-08)
        if (i9 == 3 && F9[4 + i9] + 0 == F9[3] + 0) continue
        # the failure rows tint RED (restint): Disallowed (2), Bad key (5),
        # Key failures (6), Locked (7), Auth failed (8). The Last column is
        # the family's newest stamp (sidecar fields 14-21, stored 12 behind
        # the counts in F9).
        if (F9[4 + i9] + 0 > 0)
            emitl("ROW\t" FL[i9] "\t" F9[4 + i9] "\t" (F9[12 + i9] == "-" ? "" : substr(F9[12 + i9], 1, 19)) ((i9 == 2 || i9 >= 5) ? "\t@data:res=red" : ""))
    }
}

# LOGIN pages (2026-08): one flex row "Activity per day | Logons | Incoming
# connections". The Logons table (emitted at the server-log point) and the
# Incoming connections table (stream section 2.6 — the section-2 breakdown
# separates it from section 1) are RELOCATED to directly after the Activity
# per day table, and all three take sxs=9 so the renderer lays them side by
# side. A page WITHOUT an Activity per day table — the blue and never-seen
# logins — anchors the row on the Features table instead: Features |
# Logons | Incoming connections (2026-08). Outgoing connections (the few
# logins with one) stays in place, a flex row of its own.
function blk_end(s,   j) {
    for (j = s + 1; j <= npg; j++)
        if (index(PG[j], "TABLE\t") == 1 || PG[j] ~ /^(FOOT|META)\t/) return j - 1
    return npg
}
function login_sxs_row(   i, act0, act1, lg0, lg1, ic0, ic1, n2) {
    act0 = 0; lg0 = 0; ic0 = 0
    for (i = 1; i <= npg; i++) {
        if      (act0 == 0 && index(PG[i], "TABLE\tActivity per day") == 1) act0 = i
        else if (lg0 == 0 && index(PG[i], "TABLE\tLogons") == 1) lg0 = i
        else if (ic0 == 0 && index(PG[i], "TABLE\tIncoming connections") == 1) ic0 = i
    }
    if (act0 == 0)
        for (i = 1; i <= npg; i++) if (index(PG[i], "TABLE\tFeatures") == 1) { act0 = i; break }
    # a page can lack the Logons table (no logon evidence at all, 2026-08) —
    # the row still forms from the anchor plus whatever of the two exists
    if (act0 == 0 || (lg0 == 0 && ic0 == 0)) return
    # the anchor must precede the tables it pulls up (Features always does;
    # a stray later anchor would splice a block into itself)
    if ((lg0 > 0 && act0 >= lg0) || (ic0 > 0 && act0 >= ic0)) return
    act1 = blk_end(act0); lg1 = (lg0 > 0) ? blk_end(lg0) : 0; ic1 = (ic0 > 0) ? blk_end(ic0) : 0
    PG[act0] = PG[act0] "\tsxs=9"
    if (lg0 > 0) PG[lg0] = PG[lg0] "\tsxs=9"
    if (ic0 > 0 && !sub(/\tsxs=3/, "\tsxs=9", PG[ic0])) PG[ic0] = PG[ic0] "\tsxs=9"
    n2 = 0
    for (i = 1; i <= act1; i++) PG2[++n2] = PG[i]
    if (lg0 > 0) for (i = lg0; i <= lg1; i++) PG2[++n2] = PG[i]
    if (ic0 > 0) for (i = ic0; i <= ic1; i++) PG2[++n2] = PG[i]
    for (i = act1 + 1; i <= npg; i++) {
        if ((lg0 > 0 && i >= lg0 && i <= lg1) || (ic0 > 0 && i >= ic0 && i <= ic1)) continue
        PG2[++n2] = PG[i]
    }
    for (i = 1; i <= n2; i++) PG[i] = PG2[i]
    npg = n2
}

# ALL detail pages (2026-08): a Partner / Application / Domain breakdown
# holding exactly ONE row says nothing a Features row cannot — the table is
# removed and its name joins Features as a Partner/Application/Domain row,
# the cell keeping its alink and result-class tint. Identified by the HEAD's
# first column (the dim_table shapes); the sxs pair partner of a folded
# table simply renders alone. Up to three folds per page.
function fold_single_dims(   pass9, i, j, t0, t1, hl, lbl, nr9, name9, fe0, fe1, n2, C3, trio9, d0) {
    trio9 = (pend_t == "PTN" || pend_t == "APP" || pend_t == "DOM" || pend_t == "LGC" || pend_t == "BL")
    for (pass9 = 1; pass9 <= 6; pass9++) {   # a quad page can fold up to 5 dims + slack
        t0 = 0; lbl = ""
        for (i = 1; i < npg; i++) {
            if (index(PG[i], "TABLE\t") != 1) continue
            hl = PG[i + 1] "\t"   # trailing TAB: a strip_page()d never-seen table is name-column-only (HEAD\tDomain, no tab), and the match must cover both shapes
            if      (index(hl, "HEAD\tDomain\t") == 1)      lbl = "Domain"
            else if (index(hl, "HEAD\tApplication\t") == 1) lbl = "Application"
            else if (index(hl, "HEAD\tLogical\t") == 1)     lbl = "Logical"
            else if (index(hl, "HEAD\tPartner\t") == 1)     lbl = "Partner"
            else if (index(hl, "HEAD\tBL\t") == 1)          lbl = "BL"
            else if (trio9 && index(hl, "HEAD\tLogin\t") == 1)       lbl = "Login"   # the trio pages' Logins/Hosts tables (2026-08-29)
            else if (trio9 && index(hl, "HEAD\tRemote Host\t") == 1) lbl = "Host"
            else continue
            t1 = blk_end(i)
            nr9 = 0; name9 = ""
            for (j = i + 1; j <= t1; j++) if (index(PG[j], "ROW\t") == 1) { nr9++; if (nr9 == 1) { split(PG[j], C3, "\t"); name9 = C3[2] } }
            if (nr9 == 1) { t0 = i; break }
            lbl = ""
        }
        if (t0 == 0 || name9 == "") return
        # the dim column linked via its KIND; the Features cell links via
        # alink instead (slugmap-resolved — no entry, no link)
        if (index(name9, "@{") != 1)
            name9 = "@{alink=" ((lbl == "Domain") ? "domains" : (lbl == "Application") ? "applications" : (lbl == "Logical") ? "logicals" : (lbl == "Login") ? "logins" : (lbl == "Host") ? "hosts" : "partners") "/" name9 "}" name9
        fe0 = 0
        for (i = 1; i <= npg; i++) if (index(PG[i], "TABLE\tFeatures") == 1) { fe0 = i; break }
        if (fe0 == 0) {
            if (!trio9) return
            # the trio pages carry NO Features table — CREATE one as the
            # FIRST element of the sxs=5 flex row (2026-08-29): the skeleton
            # goes directly before the row's first table, the fold below
            # appends the row(s)
            d0 = 0
            for (i = 1; i <= npg; i++) if (index(PG[i], "TABLE\t") == 1 && index(PG[i], "\tsxs=5") > 0) { d0 = i; break }
            if (d0 == 0) return
            n2 = 0
            for (i = 1; i <= npg; i++) {
                if (i == d0) { PG2[++n2] = "TABLE\tFeatures\tsxs=5\tnosearch"; PG2[++n2] = "HEAD\tItem\tValue"; PG2[++n2] = "KIND\ttext\ttext" }
                PG2[++n2] = PG[i]
            }
            for (i = 1; i <= n2; i++) PG[i] = PG2[i]
            npg = n2
            if (t0 >= d0) { t0 += 3; t1 += 3 }   # the fold target shifted by the skeleton
            fe0 = d0
        }
        fe1 = blk_end(fe0)
        n2 = 0
        for (i = 1; i <= npg; i++) {
            if (i >= t0 && i <= t1) continue
            PG2[++n2] = PG[i]
            if (i == fe1) PG2[++n2] = "ROW\t" lbl "\t" name9
        }
        for (i = 1; i <= n2; i++) PG[i] = PG2[i]
        npg = n2
    }
}

# HOST pages (2026-08): the Logons table, the LOGIN pages' shape over the
# ADDRESS evidence — the auth and screening lines carry the client's
# address, so a host page sums them over ITS addresses (the endpoint's
# forward-resolved IPs, plus the page's own name when it IS an address).
# Only the families that carry an address exist here: the logon summary,
# Allowed and Disallowed. Several addresses merge — counts sum, stamps
# min/max — and the pattern is the busiest address's own.
function host_logons_section(   V9, na9, i9, F9, cnt9, fst9, lst9, pat9, patc9, alw9, dis9, la9, ld9, seen9, nfw9, afw9, fi9, oc9, ofst9, olst9, opat9, opatc9, xf9, xl9, XC9, XL9, ci9, CLBL9, ncl9, to9, CC9, CL9, CN9, ncc9) {
    if (pend_t != "HOST") return
    na9 = 0
    V9[++na9] = pend_e
    nfw9 = split(fwd_ips(pend_e), afw9, "\037")
    for (fi9 = 1; fi9 <= nfw9; fi9++) if (afw9[fi9] != "") V9[++na9] = afw9[fi9]
    cnt9 = 0; fst9 = ""; lst9 = ""; pat9 = ""; patc9 = -1; alw9 = 0; dis9 = 0; la9 = ""; ld9 = ""; seen9 = 0
    oc9 = 0; ofst9 = ""; olst9 = ""; opat9 = ""; opatc9 = -1; xf9 = 0; xl9 = ""
    for (i9 = 1; i9 <= na9; i9++) {
        if (LGH[V9[i9]] == "") continue
        seen9 = 1
        split(LGH[V9[i9]], F9, "\t")
        if (F9[1] != "-" && (fst9 == "" || F9[1] < fst9)) fst9 = F9[1]
        if (F9[2] != "-" && (lst9 == "" || F9[2] > lst9)) lst9 = F9[2]
        if (F9[3] + 0 > patc9) { patc9 = F9[3] + 0; pat9 = F9[4] }
        cnt9 += F9[3] + 0
        alw9 += F9[5] + 0; dis9 += F9[6] + 0
        if (F9[7] != "-" && F9[7] > la9) la9 = F9[7]
        if (F9[8] != "-" && F9[8] > ld9) ld9 = F9[8]
        # the OUTBOUND side (fields 9-14 here: sidecar 10-15)
        if (F9[10] != "-" && (ofst9 == "" || F9[10] < ofst9)) ofst9 = F9[10]
        if (F9[11] != "-" && (olst9 == "" || F9[11] > olst9)) olst9 = F9[11]
        if (F9[9] + 0 > opatc9) { opatc9 = F9[9] + 0; opat9 = F9[12] }
        oc9 += F9[9] + 0
        xf9 += F9[13] + 0
        if (F9[14] != "-" && F9[14] > xl9) xl9 = F9[14]
        # the failure classes (sidecar 16-23 = F9 15-22): Password / Key /
        # Certificate / Other, count + last stamp each
        for (ci9 = 1; ci9 <= 4; ci9++) {
            XC9[ci9] += F9[13 + 2 * ci9] + 0
            if (F9[14 + 2 * ci9] != "-" && F9[14 + 2 * ci9] > XL9[ci9]) XL9[ci9] = F9[14 + 2 * ci9]
        }
        # the connection-error classes (sidecar 24-37 = F9 23-36): Timeouts /
        # SSH / Network / TLS handshake / Too many / Negotiation / Proxy
        for (ci9 = 1; ci9 <= 7; ci9++) {
            CC9[ci9] += F9[21 + 2 * ci9] + 0
            if (F9[22 + 2 * ci9] != "-" && F9[22 + 2 * ci9] > CL9[ci9]) CL9[ci9] = F9[22 + 2 * ci9]
        }
    }
    to9 = 0
    for (ci9 = 1; ci9 <= 7; ci9++) to9 += CC9[ci9] + 0
    if (!seen9 || (cnt9 == 0 && alw9 == 0 && dis9 == 0 && oc9 == 0 && xf9 == 0 && to9 == 0)) return
    emitl("TABLE\tLogons\trestint\tnosearch")
    emitl("HEAD\tItem\tValue\tLast")
    emitl("KIND\ttext\ttext\ttext")
    if (cnt9 > 0) {
        emitl("ROW\tFirst logon\t" substr(fst9, 1, 19) "\t")
        emitl("ROW\tPattern\t" pat9 "\t")
        emitl("ROW\tNumber of logons\t" cnt9 "\t" substr(lst9, 1, 19))
    }
    if (alw9 > 0) emitl("ROW\tAllowed\t" alw9 "\t" (la9 == "" ? "" : substr(la9, 1, 19)))
    if (dis9 > 0) emitl("ROW\tDisallowed\t" dis9 "\t" (ld9 == "" ? "" : substr(ld9, 1, 19)) "\t@data:res=red")
    # the OUTBOUND story — an endpoint WE connect to: one "had initiated a
    # connection" line per connection ST opens toward it, and our auth
    # failures at it (the Logon report's Outgoing family, by hostname)
    if (oc9 > 0) {
        emitl("ROW\tFirst connection\t" substr(ofst9, 1, 19) "\t")
        emitl("ROW\tPattern\t" opat9 "\t")
        emitl("ROW\tConnections\t" oc9 "\t" substr(olst9, 1, 19))
    }
    # the connection-error rows, zeros omitted (to9 = their sum)
    ncc9 = split("Timeouts\037SSH errors\037Network errors\037TLS handshake\037Too many connections\037SSH negotiation\037Proxy errors", CN9, "\037")
    for (ci9 = 1; ci9 <= ncc9; ci9++)
        if (CC9[ci9] + 0 > 0)
            emitl("ROW\t" CN9[ci9] "\t" CC9[ci9] "\t" (CL9[ci9] == "" ? "" : substr(CL9[ci9], 1, 19)) "\t@data:res=red")
    if (xf9 > 0) {
        emitl("ROW\tAuth failures\t" xf9 "\t" (xl9 == "" ? "" : substr(xl9, 1, 19)) "\t@data:res=red")
        # the class rows — the Logon report Outgoing tab's columns, zeros
        # omitted like everywhere else in this table
        ncl9 = split("Password\037Key\037Certificate\037Other", CLBL9, "\037")
        for (ci9 = 1; ci9 <= ncl9; ci9++)
            if (XC9[ci9] + 0 > 0)
                emitl("ROW\t" CLBL9[ci9] "\t" XC9[ci9] "\t" (XL9[ci9] == "" ? "" : substr(XL9[ci9], 1, 19)) "\t@data:res=red")
    }
}

# LOGIN pages (2026-08): Features and Waiting/Expired sit side by side —
# Waiting/Expired is relocated to directly after the Features block and
# both take sxs=10. A page without a Waiting/Expired table keeps Features
# standalone; the never-seen pages' Features instead anchors the sxs=9 row
# — no conflict, Waiting/Expired is transfer data those pages lack.
function login_feat_row(   i, fe0, fe1, we0, we1, n2) {
    fe0 = 0; we0 = 0
    for (i = 1; i <= npg; i++) {
        if (fe0 == 0 && index(PG[i], "TABLE\tFeatures") == 1) fe0 = i
        else if (we0 == 0 && index(PG[i], "TABLE\tWaiting/Expired") == 1) we0 = i
    }
    if (fe0 == 0 || we0 == 0 || we0 < fe0) return
    fe1 = blk_end(fe0); we1 = blk_end(we0)
    PG[fe0] = PG[fe0] "\tsxs=10"
    PG[we0] = PG[we0] "\tsxs=10"
    n2 = 0
    for (i = 1; i <= fe1; i++) PG2[++n2] = PG[i]
    for (i = we0; i <= we1; i++) PG2[++n2] = PG[i]
    for (i = fe1 + 1; i <= npg; i++) { if (i >= we0 && i <= we1) continue; PG2[++n2] = PG[i] }
    for (i = 1; i <= n2; i++) PG[i] = PG2[i]
    npg = n2
}

# HOST pages (2026-08): one flex row "Features | Activity per day |
# Logons" — Activity and Logons relocate to directly after the Features
# block, all tagged sxs=11. Whichever of the two a page lacks (a
# never-seen host has no Activity; a host without connection evidence
# has no Logons) simply leaves the row shorter; anything that sat
# between (Waiting/Expired) follows the row.
function host_sxs_row(   i, j, ins9, fe0, fe1, act0, act1, lg0, lg1, n2) {
    fe0 = 0; act0 = 0; lg0 = 0
    for (i = 1; i <= npg; i++) {
        if      (fe0 == 0 && index(PG[i], "TABLE\tFeatures") == 1) fe0 = i
        else if (act0 == 0 && index(PG[i], "TABLE\tActivity per day") == 1) act0 = i
        else if (lg0 == 0 && index(PG[i], "TABLE\tLogons") == 1) lg0 = i
    }
    if (fe0 == 0 || (act0 == 0 && lg0 == 0)) return
    fe1 = blk_end(fe0); act1 = (act0 > 0) ? blk_end(act0) : 0; lg1 = (lg0 > 0) ? blk_end(lg0) : 0
    PG[fe0] = PG[fe0] "\tsxs=11"
    if (act0 > 0) PG[act0] = PG[act0] "\tsxs=11"
    if (lg0 > 0) PG[lg0] = PG[lg0] "\tsxs=11"
    # the row assembles at the EARLIEST of the blocks (the intro can emit
    # Features after the section tables on some pages), in canonical order
    # Activity | Logons | Features (Features third, 2026-08)
    ins9 = fe0
    if (act0 > 0 && act0 < ins9) ins9 = act0
    if (lg0 > 0 && lg0 < ins9) ins9 = lg0
    n2 = 0
    for (i = 1; i <= npg; i++) {
        if (i == ins9) {
            if (act0 > 0) for (j = act0; j <= act1; j++) PG2[++n2] = PG[j]
            if (lg0 > 0) for (j = lg0; j <= lg1; j++) PG2[++n2] = PG[j]
            for (j = fe0; j <= fe1; j++) PG2[++n2] = PG[j]
        }
        if ((i >= fe0 && i <= fe1) || (act0 > 0 && i >= act0 && i <= act1) || (lg0 > 0 && i >= lg0 && i <= lg1)) continue
        PG2[++n2] = PG[i]
    }
    for (i = 1; i <= n2; i++) PG[i] = PG2[i]
    npg = n2
}

# LOGIN pages (2026-08): the "Last error(s)" table moves from the page top
# to directly AFTER the subscription breakdown (the heading-less seenrows
# table whose HEAD leads with Subscription) — the errors ARE those
# subscriptions', so they read beside that table, not above Features. A
# page missing either table (never-seen: no errors, no breakdown) is left
# alone. Runs after login_sxs_row, on the renumbered buffer.
function login_lasterr_move(   i, le0, le1, sub0, sub1, n2) {
    le0 = 0; sub0 = 0
    for (i = 1; i < npg; i++) {
        if (le0 == 0 && index(PG[i], "TABLE\tLast error(s)") == 1) le0 = i
        else if (sub0 == 0 && index(PG[i], "TABLE\t") == 1 && index(PG[i + 1], "HEAD\tSubscription\t") == 1) sub0 = i
    }
    if (le0 == 0 || sub0 == 0 || le0 > sub0) return
    le1 = blk_end(le0); sub1 = blk_end(sub0)
    n2 = 0
    for (i = 1; i <= sub1; i++) { if (i >= le0 && i <= le1) continue; PG2[++n2] = PG[i] }
    for (i = le0; i <= le1; i++) PG2[++n2] = PG[i]
    for (i = sub1 + 1; i <= npg; i++) PG2[++n2] = PG[i]
    for (i = 1; i <= n2; i++) PG[i] = PG2[i]
    npg = n2
}

# The "Server log error" section (SITE pages, 2026-08): a subscription that
# is red for what the SERVER log shows has its own error page
# errors/<slug>.html (failed.sh, the _srvsubs.tsv map) — this re-emits that
# page's server-log table VERBATIM above Last error, and adds its lines to
# the suppression set so Last server log messages does not repeat them (the
# same rule as the Last OK transfer and last-error session lines).
function srv_log_error_section(   k9, f9, l9, n9a, C9a, intab9, body9, nb9) {
    if (pend_t != "SITE") return
    k9 = toupper(pend_e)
    if (!(k9 in SLG)) return
    f9 = ERRD "/" SLG[k9] ".rpt"
    intab9 = 0; body9 = ""; nb9 = 0
    while ((getline l9 < f9) > 0) {
        if (index(l9, "HEAD\tDate & time\tLevel\tLine") == 1) { intab9 = 1; continue }
        if (!intab9) continue
        if (index(l9, "ROW\t") != 1) {
            if (l9 ~ /^(TABLE|TOTAL|LINK|FOOT|NOTE)\t/ || l9 ~ /^(TABLE|TOTAL|LINK|FOOT)$/) break
            continue
        }
        n9a = split(l9, C9a, "\t")
        if (n9a < 4) continue
        body9 = body9 l9 "\n"; nb9++
        SUP[k9 SUBSEP C9a[2] SUBSEP C9a[4]] = 1
    }
    close(f9)
    if (nb9 == 0) return
    emitl("TABLE\tServer log error\twide\trestint\tnosort\tnosearch\tanchor=srv-log-error")
    emitl("HEAD\tDate & time\tLevel\tLine")
    emitl("KIND\ttext\ttext\tpre")
    n9a = split(body9, C9a, "\n")
    for (l9 = 1; l9 <= n9a; l9++) if (C9a[l9] != "") emitl(C9a[l9])
}

# The "Last OK transfer" section (SITE pages, details.sh OKTF sidecar): the
# newest PROCESSED File of this flow (never a Waiting one — a UC2 staging
# without the collect leg is not a complete transfer) — its transfer legs and
# the server log of their connections, the errors/ drill-page shape —
# directly above the Last server log messages table. A flow with no
# Processed File emits nothing.
function last_ok_section(   k9, nls, i9, LL) {
    if (pend_t != "SITE") return
    k9 = toupper(pend_e)
    if (!(k9 in OKL)) return
    emitl("TABLE\tLast OK transfer" (((k9 in OKN) && OKN[k9] != "") ? " — " OKN[k9] : "") "\twide\tnosearch")
    emitl("HEAD\tStatus\tDirection\tProtocol\tSize\tDate & time\tDuration\tRemote host\tTransfer ID")
    emitl("KIND\ttext\ttext\ttext\tnum\ttext\tnum\thost\tmono")
    nls = split(OKL[k9], LL, "\n")
    for (i9 = 1; i9 <= nls; i9++) if (LL[i9] != "") emitl(LL[i9])
    if (k9 in OKS) {
        emitl("TABLE\t\twide\trestint\tnosort\tnosearch")
        emitl("HEAD\tDate & time\tLevel\tLine")
        emitl("KIND\ttext\ttext\tpre")
        nls = split(OKS[k9], LL, "\n")
        for (i9 = 1; i9 <= nls; i9++) if (LL[i9] != "") emitl(LL[i9])
    }
}

# strip_notseen_counts: a never-seen/blue page's dimension tables keep only
# their name column (+ the Subscription Direction cell); @data: cells survive
function strip_page(   i, n2, keep, dir3, line, m, C, out, j) {
    n2 = 0; keep = 0; dir3 = 0
    for (i = 1; i <= npg; i++) {
        line = PG[i]
        m = split(line, C, "\t")
        if (C[1] == "TABLE") {
            keep = (C[2] == "Features" || index(C[2], "Last server log messages") == 1 || C[2] == "Incoming connections" || C[2] == "Outgoing connections" || C[2] == "Groups" || C[2] == "Logons") ? 1 : 0
            dir3 = 0
            PG2[++n2] = line; continue
        }
        if (keep) { PG2[++n2] = line; continue }
        if (C[1] == "HEAD" || C[1] == "KIND") {
            if (C[1] == "HEAD") dir3 = (C[3] == "Direction") ? 1 : 0
            PG2[++n2] = dir3 ? C[1] "\t" C[2] "\t" C[3] : C[1] "\t" C[2]
            continue
        }
        if (C[1] == "TOTAL") { PG2[++n2] = C[1] "\t" C[2]; continue }
        if (C[1] == "ROW") {
            out = C[1] "\t" C[2]; if (dir3) out = out "\t" C[3]
            for (j = (dir3 ? 4 : 3); j <= m; j++) if (substr(C[j], 1, 6) == "@data:") out = out "\t" C[j]
            PG2[++n2] = out; continue
        }
        PG2[++n2] = line
    }
    for (i = 1; i <= n2; i++) PG[i] = PG2[i]
    npg = n2
}

# The Incoming (2.6) / Outgoing (2.7) connection tables render as a PAIR
# (2026-07): when a page has one side but not the other, the missing side is
# synthesized as a titled empty-state table so the two sit side by side in one
# sxs row. The placeholder ROW is a data row, so report.js's hideEmptyTables
# leaves the section standing. A side is only synthesized when the entity's
# CONNECTION direction says it is POSSIBLE — Incoming needs dirv in/both,
# Outgoing needs out/both — so a one-way entity shows just its own side and an
# unknown-direction entity only what was actually observed; a section with
# REAL rows always renders regardless (a section only enters the stream with
# data, and observed data beats the configured direction).
function inject_conn_placeholder(s) {
    if (s == "2.6") {
        emitl("TABLE\tIncoming connections\tsxs=3")
        emitl("HEAD\tIP\tIn\tOut")
        emitl("KIND\tmono\tnum\tnum")
        emitl("ROW\t@{colspan=3}No whitelisted or observed incoming addresses\t\t")
        had26 = 1
    } else {
        emitl("TABLE\tOutgoing connections\tsxs=3")
        emitl("HEAD\tIP\tIn\tOut\tName")
        emitl("KIND\tmono\tnum\tnum\tmono")
        emitl("ROW\t@{colspan=4}No configured endpoints or observed outgoing connections\t\t\t")
        had27 = 1
    }
}
function close_file(   dircls, resv, out, i) {
    if (pend_t == "") return
    ensure_file()
    finish_section()
    if (cur_sec == "2.6" && !had27 && (dirv == "out" || dirv == "both")) inject_conn_placeholder("2.7")   # 2.6 was the page's last section
    emit_intro()
    emit_perf_tables()
    dircls = (dirv == "in" || dirv == "out") ? dirv : "x"
    resv = (a_res == "green" || a_res == "orange" || a_res == "red" || a_res == "blue") ? a_res : ""
    if (pend_t == "ACC") uncollected_files_table()
    page_srv_log()
    emitl("FOOT\tGenerated on " NOW " from " NFILES " file(s)")
    emitl("META\tseen\t" (have_tot == 1 ? 1 : 0))
    if (resv != "") emitl("META\tdirclass\tres-" resv)
    else emitl("META\tdirclass\tdir-" (have_tot == 1 ? "seen" : "notseen") "-" dircls)
    # never-seen AND blue pages reduce their breakdown tables to the name column
    if (have_tot != 1 || IS_BLUE) strip_page()
    fold_single_dims()
    if (pend_t == "LOGIN") { login_feat_row(); login_sxs_row(); login_lasterr_move() }
    if (pend_t == "HOST") host_sxs_row()
    out = ""
    for (i = 1; i <= npg; i++) out = out PG[i] "\n"
    printf "%s", out > cur_path
    close(cur_path)
    npg = 0
}

# ===== per-entity reset + the stream loop ====================================
function reset_entity() {
    npg = 0; cur_path = ""; cur_sec = ""; had26 = 0; had27 = 0
    have_tot = 0; rank_name = ""; day_rows = 0; intro_done = 0; IS_BLUE = 0; HAS_WE = 0; bluebox = 0
    x_perf = ""; x_ip = ""; x_dtrank = ""; x_pday = ""; dirv = "unknown"; BOTHMODE = 0; perf_done = 0
    split("", bk_f); split("", bk_e); split("", bk_b); split("", bk_ord); nbk = 0
    split("", LE); nle = 0
    busy_day = "-"; busy_cnt = 0
    x_blue = ""; x_grpfold = ""
    x_oneacct = ""; x_onedom = ""; x_oneapp = ""; x_oneptn = ""; x_onelgc = ""; x_onebl = ""
    tot_recs = ""; tot_f = ""; tot_p = ""; tot_h = ""; tot_first = ""; tot_last = ""; tot_pct = ""
    tot_share = ""; tot_rank = ""; tot_n = ""; tot_act = ""; tot_idle = ""
    tot_largest = ""; tot_avg = ""; tot_srank = ""; tot_erank = ""; tot_duravg = "-"; tot_sshare = ""
    tot_fi = 0; tot_pi = 0; tot_fo = 0; tot_po = 0; tot_rv = 0
    TMODE = 0; buf_sec = ""; sec_in = 0; sec_out = 0; nbb = 0
}

BEGIN {
    for (oi = 32; oi < 127; oi++) ORD[sprintf("%c", oi)] = oi   # uenc()'s char -> code table
    cntlabel = "Files"; big_col = "File"; big_kind = "mono"
    if      (TYPE == "ACC")   { label = "Account";      typenoun = "accounts";      sdir = "accounts";      bt = "account";      rk = "accounts" }
    else if (TYPE == "SITE")  { label = "Subscription"; typenoun = "subscriptions"; sdir = "subscriptions"; bt = "subscription"; rk = "subscriptions" }
    else if (TYPE == "LOGIN") { label = "Login";        typenoun = "logins";        sdir = "logins";        bt = "login";        rk = "logins" }
    else if (TYPE == "HOST")  { label = "Remote Host";  typenoun = "remote hosts";  sdir = "hosts";         bt = "host";         rk = "hosts" }
    else if (TYPE == "LGC")   { label = "Logical";      typenoun = "logical flows"; sdir = "";              bt = "logical";      rk = "logical" }
    else if (TYPE == "PTN")   { label = "Partner";      typenoun = "partners";      sdir = "";              bt = "partner";      rk = "partners" }
    else if (TYPE == "APP")   { label = "Application";  typenoun = "applications";  sdir = "";              bt = "application";  rk = "applications" }
    else if (TYPE == "DOM")   { label = "Domain";       typenoun = "domains";       sdir = "";              bt = "domain";       rk = "domains" }
    else                      { label = "BL";           typenoun = "BL tags";       sdir = "";              bt = "bl";           rk = "bl" }
    desc = cntlabel " per day for this " label ", plus load, every other dimension and the largest " cntlabel " seen for it."
    SM = OUTDIR "/_slugmap.tsv"
    # the shared UC descriptions (bin/uc-cases.sh, dumped by details.sh so the
    # single source of truth stays bash): token \t From..trigger — field 6 = Human
    while ((getline l < UCF) > 0) { n = split(l, A, "\t"); if (n >= 6) UCH[A[1]] = A[6] }
    close(UCF)
    # the derived use case per non-UC-named subscription (details.sh UCDER:
    # "name \t UC<n>", from the pattern + flowdir caches)
    while ((getline l < UCDF) > 0) { n = split(l, A, "\t"); if (n >= 2) DUC[A[1]] = A[2] }
    close(UCDF)
    # the "Last OK transfer" sidecar (details.sh OKTF; SITE pages only): per
    # subscription the newest Processed File — F = file + stamp, L = one transfer
    # leg (the errors/ drill-page columns), S = one server-log line of the
    # legs connections (session join), Error/Warning rows tinted like there
    if (TYPE == "SITE") {
        while ((getline l < OKF) > 0) {
            n = split(l, A, "\t")
            if (n < 4) continue
            k = toupper(A[2])
            if (A[1] == "F")               { OKN[k] = A[3]; OKD[k] = A[4] }
            else if (A[1] == "L") { r = A[3]; for (i = 4; i <= n; i++) r = r "\t" A[i]
                                    OKL[k] = OKL[k] "ROW\t" r "\n" }
            else if (A[1] == "S" && n >= 5) {
                r = (A[4] == "Error") ? "\t@data:res=red" : ((A[4] == "Warning") ? "\t@data:res=orange" : "")
                OKS[k] = OKS[k] "ROW\t" A[3] "\t" A[4] "\t" A[5] r "\n"
                SUP[k SUBSEP A[3] SUBSEP A[5]] = 1 }
            # X = the newest FAILED File session lines: shown on the error
            # page the Last error row links, so they (with the S lines) are
            # SUPPRESSED from the Last server log messages table, never shown
            else if (A[1] == "X" && n >= 5) SUP[k SUBSEP A[3] SUBSEP A[5]] = 1
        }
        close(OKF)
        # the server-failing subscriptions map (failed.sh _srvsubs.tsv): a
        # SITE page in it re-emits its errors/<slug>.rpt server-log table as
        # the "Server log error" section (srv_log_error_section)
        while ((getline l < SSF) > 0) { n = split(l, A, "\t"); if (n >= 2) SLG[toupper(A[1])] = A[2] }
        close(SSF)
    }
    # LOGIN pages: the "Logons" sidecar (bin/logons.sh via details.sh) — per
    # login the first/last successful authentication, the raw count, the
    # cadence label (the Pickup-pattern vocabulary) and the seven
    # screening-funnel counts (the server Logon report's Incoming columns)
    if (TYPE == "LOGIN") {
        while ((getline l < LGF) > 0) {
            n = split(l, A, "\t")
            if (n >= 21) { r = A[2]; for (i = 3; i <= 21; i++) r = r "\t" A[i]; LGO[A[1]] = r }
        }
        close(LGF)
    }
    # HOST pages: the per-ADDRESS logon summary (bin/logons.sh second file:
    # ADDR ⇥ first ⇥ last ⇥ count ⇥ pattern ⇥ allowed ⇥ disallowed ⇥ lastA ⇥ lastD
    #      ⇥ out-count ⇥ out-first ⇥ out-last ⇥ out-pattern ⇥ outfail ⇥ outfail-last
    #      ⇥ pw ⇥ lastPw ⇥ key ⇥ lastKey ⇥ cert ⇥ lastCert ⇥ other ⇥ lastOther
    #      ⇥ 7 connection-error class pairs: Timeouts / SSH / Network /
    #        TLS handshake / Too many connections / Negotiation / Proxy)
    if (TYPE == "HOST") {
        while ((getline l < LGHF) > 0) {
            n = split(l, A, "\t")
            if (n >= 37) { r = A[2]; for (i = 3; i <= 37; i++) r = r "\t" A[i]; LGH[A[1]] = r }
        }
        close(LGHF)
    }
    # ACCOUNT pages: the uncollected-files map, "ACCT(upper) \t file \t expiry"
    # stored as "expiry \t file" rows per account (the table's column order).
    # NOTE the emptiness test, NOT `in`: mawk instantiates the LHS subscript
    # BEFORE evaluating the RHS, so `A[1] in UNL` would be true on the very
    # first insert and prepend a spurious "\n" (an empty table row).
    if (TYPE == "ACC") {
        while ((getline l < UNCF) > 0) { n = split(l, A, "\t"); if (n >= 3) { k = A[1]; UNL[k] = (UNL[k] != "" ? UNL[k] "\n" : "") A[3] "\t" A[2] } }
        close(UNCF)
    }
    cur_key = ""; pend_t = ""; pend_e = ""
    reset_entity()
}

NF < 4 { next }
{
    t = $1; e = $2; sec = $3
    if (t "|" e != cur_key) {
        close_file()
        cur_key = t "|" e; pend_t = t; pend_e = e
        reset_entity()
        # SEQUENTIAL annotation read — same first-seen order as this stream
        if ((getline aline < ANN) <= 0) aline = ""
        split(aline, A, "\036")
        if (A[1] != t || A[2] != e) {
            print "details_writer.awk: annotation stream out of sync (" A[1] "|" A[2] " vs " t "|" e ")" | "cat 1>&2"
            close("cat 1>&2")
            died = 1
            exit 1
        }
        a_slug = A[3]; a_mv = A[4]; a_res = A[5]
        IS_BLUE = (A[6] == "1") ? 1 : 0
        a_cfgacct = A[22]; a_acl = A[23]; a_ach = A[24]; a_conn = A[25]; a_bannerdt = A[26]; a_grp = A[27]
        a_suba = A[28]; a_subl = A[29]; a_subh = A[30]; a_nosub = A[31]; a_twin = A[32]
        x_oneacct = A[8]; x_onedom = A[9]; x_oneapp = A[10]; x_oneptn = A[11]; x_onelgc = A[33]; x_onebl = A[34]
        if (t == "SITE") {
            a_sdh = A[12]; a_sda = A[13]; a_sdl = A[14]
            a_cron = A[15]; a_cronh = A[16]
            a_flowdir = A[17]; a_local = A[18]; a_lmask = A[19]; a_remote = A[20]; a_rmask = A[21]
            x_blue = (A[7] == "1") ? "1" : ""
        } else {
            a_sdh = ""; a_sda = ""; a_sdl = ""; a_cron = ""; a_cronh = ""
            a_flowdir = ""; a_local = ""; a_lmask = ""; a_remote = ""; a_rmask = ""
            x_blue = ""
        }
        # config Domain/Application/Logical/Partner groups: SITE folds them
        # via sum_config; the LGC/PDA quad renders them as own tables; every
        # other type folds them into Features via x_grpfold
        x_grpfold = ""
        if (t != "SITE" && t != "PTN" && t != "APP" && t != "DOM" && t != "LGC" && t != "BL" && a_grp != "") {
            ng = usplit(a_grp, GV)
            for (gi = 1; gi <= ng; gi++) {
                i1 = index(GV[gi], "\t"); if (i1 == 0) continue
                gt = substr(GV[gi], 1, i1 - 1); gn = substr(GV[gi], i1 + 1)
                if (gn == "") continue
                gs = (gt == "Domain") ? "domains" : (gt == "Application") ? "applications" : (gt == "Logical") ? "logicals" : (gt == "Partner") ? "partners" : "bl"
                x_grpfold = x_grpfold (x_grpfold == "" ? "" : "\n") "ROW\t" gt "\t@{alink=" gs "/" gn "}" gn
            }
        }
    }
    if (sec == "-1") { dirv = ($5 != "") ? $5 : "unknown"; BOTHMODE = (dirv == "both") ? 1 : 0; next }
    if (sec == "0") {
        if ($4 == "0") {
            tot_recs = $5; tot_f = $6; tot_p = $7; tot_h = $8; tot_first = $9; tot_last = $10; tot_pct = $11
            tot_share = $12; tot_rank = $13; tot_n = $14; tot_act = $15; tot_idle = $17
            tot_fi = ($18 != "") ? $18 : 0; tot_pi = ($19 != "") ? $19 : 0; tot_fo = ($20 != "") ? $20 : 0; tot_po = ($21 != "") ? $21 : 0
            tot_largest = $22; tot_avg = $23; tot_srank = $24; tot_erank = $25
            tot_duravg = ($26 != "") ? $26 : "-"; tot_sshare = $27
            have_tot = 1
            rank_name = $2   # the entity these totals belong to — the stream
                             # variable `e` has moved on by the time the page
                             # (and the ranking sidecar) is flushed
        }
        else if ($4 == "1") x_perf = $5
        else if ($4 == "3") x_ip = $5
        else if ($4 == "6") x_dtrank = $5
        else if ($4 == "7") x_pday = $5   # per-day timed triple, for the Ranking sidecar's buckets
        next
    }
    # section 0.4 — one Last error(s) row per connected subscription (see
    # last_error_table). Held, not rendered here: the table belongs ABOVE the
    # Features table, which emit_intro writes.
    if (sec == "0.4") {
        nle++; LE[nle] = $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9
        next
    }
    ensure_file()
    if (sec != cur_sec) {
        finish_section()
        # keep the connection tables a PAIR where both are POSSIBLE: entering
        # 2.7 without a 2.6, or leaving 2.6 for anything other than 2.7,
        # synthesizes the missing side — but only for the entity's direction
        if (cur_sec == "2.6" && sec != "2.7" && !had27 && (dirv == "out" || dirv == "both")) inject_conn_placeholder("2.7")
        if (sec != "1" && sec != "2") emit_intro()
        if (sec == "2.7" && !had26 && (dirv == "in" || dirv == "both")) inject_conn_placeholder("2.6")
        if (sec == "2.6") had26 = 1
        if (sec == "2.7") had27 = 1
        cur_sec = sec
        if (sec == "0.9" || sec == "2.6" || sec == "2.7" || sec == "9" || sec == "12.6") { TMODE = 0; start_table(sec) }
        else if (BOTHMODE == 1) { buf_sec = sec; sec_in = 0; sec_out = 0 }
        else { TMODE = 0; start_table(sec) }
    }
    if (sec == "1") {
        day_rows++
        # the Ranking sidecar's per-day payload: Files, Errors and Volume come
        # from this row (fields 16/17 are the RAW bytes/ms the humanized cells
        # cannot give back), the timed triple from the 0/7 line above
        if (RANKOUT != "" && $4 != "") {
            if (!($4 in bk_f)) { nbk++; bk_ord[nbk] = $4 }
            bk_f[$4] = ($6 + 0) + ($7 + 0); bk_e[$4] = $6 + 0; bk_b[$4] = $16 + 0
        }
        ccf = $9; ccp = $10
        if (ccf == "-") ccf = ""
        if (ccp == "-") ccp = ""
        dcnt = ($6 + 0) + ($7 + 0)
        if (dcnt > busy_cnt) { busy_cnt = dcnt; busy_day = $5 }
        ddur = ($15 != "") ? $15 : "-"
        if (BOTHMODE == 1) {
            rb = sprintf("ROW\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s", $5, dcnt, ($11 != "" ? $11 : 0), ($12 != "" ? $12 : 0), ($13 != "" ? $13 : 0), ($14 != "" ? $14 : 0), $8, ddur, ccf, ccp)
            rp = sprintf("ROW\t%s\t%d\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s", $5, dcnt, $6, $7, $8, ddur, ccf, ccp)
            push_row(rb, rp, ($11 + 0) + ($12 + 0), ($13 + 0) + ($14 + 0))
        } else if (pend_t == "SITE") {
            # Recovered between Error and OK (blank on 0, like the topview)
            tot_rv += $18 + 0
            emitl(sprintf("ROW\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s", $5, dcnt, $6, ($18 + 0 > 0 ? $18 : ""), $7, $8, ddur, ccf, ccp))
        } else {
            emitl(sprintf("ROW\t%s\t%d\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s", $5, dcnt, $6, $7, $8, ddur, ccf, ccp))
        }
    }
    else if (sec == "10" || sec == "11") {
        lbl = (sec == "10") ? wdname($5) : $5
        if (BOTHMODE == 1) {
            rb = sprintf("ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s", lbl, $6, ($10 != "" ? $10 : 0), ($11 != "" ? $11 : 0), ($12 != "" ? $12 : 0), ($13 != "" ? $13 : 0), $9)
            rp = sprintf("ROW\t%s\t%s\t%s\t%s\t%s", lbl, $6, $7, $8, $9)
            push_row(rb, rp, ($10 + 0) + ($11 + 0), ($12 + 0) + ($13 + 0))
        } else {
            emitl(sprintf("ROW\t%s\t%s\t%s\t%s\t%s", lbl, $6, $7, $8, $9))
        }
    }
    else if (sec == "0.9") {
        split($5, W9, "|")
        res = (W9[1] == "Expired") ? "red" : "orange"
        HAS_WE = 1
        emitl(sprintf("ROW\t%s files\t%s\t%s\t%s\t@data:res=%s", W9[1], W9[2], W9[3], W9[4], res))
    }
    else if (sec == "9") {
        split($5, B9, "|")
        res = "green"
        if (B9[8] == "Errored" || B9[8] == "Expired") res = "red"
        else if (B9[8] == "Waiting") res = "orange"
        emitl(sprintf("ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:res=%s", B9[1], B9[8], B9[7], B9[4], B9[6], B9[5], B9[2], B9[3], res))
    }
    else if (sec == "2.6" || sec == "2.7") {
        win = $6; wout = $7; wrev = $8
        if (win == "-") win = ""
        if (wout == "-") wout = ""
        if (wrev == "-") wrev = ""
        ipdisp = $5; ipval = $5
        if (ipval == "-") ipval = ""
        ipcell = ipdisp; namecell = wrev
        if (sec == "2.6") {
            if (ipval != "") ipcell = "@{alink=incoming_connections/" ipval "}" ipdisp
        } else {
            if (wrev != "") namecell = "@{alink=hosts/" wrev "}" wrev
            else if (ipval != "") ipcell = "@{alink=hosts/" ipval "}" ipdisp
        }
        if (sec == "2.6") emitl(sprintf("ROW\t%s\t%s\t%s\t@data:res=%s", ipcell, win, wout, ($9 != "" ? $9 : "orange")))
        else emitl(sprintf("ROW\t%s\t%s\t%s\t%s\t@data:res=%s", ipcell, win, wout, namecell, ($9 != "" ? $9 : "orange")))
    }
    else if (sec == "2" || sec == "2.8" || sec == "2.81" || sec == "2.82" || sec == "2.83" || sec == "2.84" || sec == "2.85") {
        resm = ""; extra = ""
        if ($4 == "green" || $4 == "orange" || $4 == "red" || $4 == "blue") resm = "\t@data:res=" $4
        if (sec == "2") {
            if (substr($4, 1, 2) == "S|") {
                split($4, S4, "|")
                extra = "\t" S4[2]
                resm = (S4[3] == "green" || S4[3] == "orange" || S4[3] == "red" || S4[3] == "blue") ? "\t@data:res=" S4[3] : ""
            } else extra = "\t?/?"
        }
        if (sec == "2.8") {
            aresv = ""; alog = ""; ahost = ""
            if (substr($4, 1, 2) == "A|") { split($4, S4, "|"); aresv = S4[2]; alog = S4[3]; ahost = S4[4] }
            extra = "\t" alog "\t" ahost
            resm = (aresv == "green" || aresv == "orange" || aresv == "red" || aresv == "blue") ? "\t@data:res=" aresv : ""
        }
        # the Subscription table's Waiting / Expired cells (zeros render blank)
        wecells = ""
        if (sec == "2" && HAS_WE == 1) {
            w2 = ($16 != "") ? $16 : 0; e2 = ($17 != "") ? $17 : 0
            if (w2 == 0) w2 = ""
            if (e2 == 0) e2 = ""
            wecells = "\t" w2 "\t" e2
        }
        if ($6 == "") {   # 5-field config row from insert_config_rows
            if (wecells != "") wecells = "\t\t"
            if (BOTHMODE == 1) {
                rb = sprintf("ROW\t%s%s\t\t0\t0\t0\t0%s\t\t@data:seen=0%s", $5, extra, wecells, resm)
                rp = sprintf("ROW\t%s%s\t\t0\t0%s\t\t@data:seen=0%s", $5, extra, wecells, resm)
                push_row(rb, rp, 0, 0)
            } else {
                emitl(sprintf("ROW\t%s%s\t\t0\t0%s\t\t@data:seen=0%s", $5, extra, wecells, resm))
            }
        } else {
            cf = $14; cp = $15
            if (cf == "-") cf = ""
            if (cp == "-") cp = ""
            if (BOTHMODE == 1) {
                rb = sprintf("ROW\t%s%s\t%s\t%s\t%s\t%s\t%s%s\t%s\t@data:seen=1\t@data:coreids-failed=%s\t@data:coreids-processed=%s%s", $5, extra, $6, ($10 != "" ? $10 : 0), ($11 != "" ? $11 : 0), ($12 != "" ? $12 : 0), ($13 != "" ? $13 : 0), wecells, $9, cf, cp, resm)
                rp = sprintf("ROW\t%s%s\t%s\t%s\t%s%s\t%s\t@data:seen=1\t@data:coreids-failed=%s\t@data:coreids-processed=%s%s", $5, extra, $6, $7, $8, wecells, $9, cf, cp, resm)
                push_row(rb, rp, ($10 + 0) + ($11 + 0), ($12 + 0) + ($13 + 0))
            } else {
                emitl(sprintf("ROW\t%s%s\t%s\t%s\t%s%s\t%s\t@data:seen=1\t@data:coreids-failed=%s\t@data:coreids-processed=%s%s", $5, extra, $6, $7, $8, wecells, $9, cf, cp, resm))
            }
        }
    }
    else if (sec == "12.6") {
        dc = $6 + 0; dt = $7 + 0
        if (dt > 0) dwsh = sprintf("%.1f", int(dc * 100000000 / dt) / 1000000)
        else dwsh = "0.0"
        emitl(sprintf("ROW\t%s\t%s\t%s%%", $5, $6, dwsh))
    }
    else {   # dimension breakdowns: value count failed processed volume fi pi fo po coreidsF coreidsP
        cf = $14; cp = $15
        if (cf == "-") cf = ""
        if (cp == "-") cp = ""
        if (BOTHMODE == 1) {
            rb = sprintf("ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s", $5, $6, ($10 != "" ? $10 : 0), ($11 != "" ? $11 : 0), ($12 != "" ? $12 : 0), ($13 != "" ? $13 : 0), $9, cf, cp)
            rp = sprintf("ROW\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s", $5, $6, $7, $8, $9, cf, cp)
            push_row(rb, rp, ($10 + 0) + ($11 + 0), ($12 + 0) + ($13 + 0))
        } else {
            emitl(sprintf("ROW\t%s\t%s\t%s\t%s\t%s\t@data:coreids-failed=%s\t@data:coreids-processed=%s", $5, $6, $7, $8, $9, cf, cp))
        }
    }
}

END {
    if (died) exit 1
    close_file()
    close(SM)
    close(ANN)
}
