# bin/sample/estate.awk — stage 1: expand the seed tables into the ESTATE SPEC,
# the single identity store every later stage formats from. Nothing downstream
# invents an identity: the JSONs, the renames/ip sidecars and both log
# generators all read these rows.
#
#   awk -f prelude.awk -f estate.awk -v ENV=acceptance \
#       -v KNOBS=bin/sample/seed/knobs.tsv -v PARTNERS=bin/sample/seed/partners.tsv \
#       -v OUTDIR=input/acceptance/.sample
#
# Writes OUTDIR/_estate.tsv (one row per flow — plus uc "A" account-only rows),
# OUTDIR/_calendar.tsv (one row per window day) and OUTDIR/_expected.tsv (the
# invariant figures bin/sample/verify.sh asserts after a build).
#
# _estate.tsv columns (TAB):
#  1 flowkey     stable slug (site lowercased) — the per-flow PRNG seed
#  2 env         acceptance|production
#  3 uc          1..8 | A (account-only row: orphan account, no subscription)
#  4 site        clean configured subscription name ("" on uc=A rows)
#  5 account     DOMAIN_APP_PARTNER (UC1/3) | DOMAIN-APP-PARTNER (UC2/4)
#  6 login       FE###### on in-side accounts, "" otherwise
#  7 profile     site minus the UC<n>_ prefix (always underscores)
#  8 profdash    dashed profile twin logged on part of the rows ("" = none)
#  9 domain     10 app     11 ptoken     (the PDA expectation)
# 12 flowid     13 subbiz  14 comprof    (uuid4, per-flow stream)
# 15 acctbiz    (uuid4, per-ACCOUNT stream — flows of one account agree)
# 16 pattern    patternName (satisfies the reverse-fallback pesit regexes)
# 17 fdirkey    scan|work|hybt|hybs|relay  (which JSON parameter says flowdir)
# 18 flowdir    out|in|relay
# 19 host       out-side DNS endpoint ("" on in-side)
# 20 ips        ";"-list (out-side: the endpoint's addresses; in-side: the
#               partner's source addresses)
# 21 hostspell  dns|ip|mixed  (how the transfer log spells the endpoint)
# 22 port       22|21|17627
# 23 sched      scan:H H H | stage:H H | push:CLASS | c15 | ch:MM | cd:HH:MM | grid15
# 24 volclass   mean files per weekday
# 25 failpct    base failure probability
# 26 sizemean   mean file size (bytes)
# 27 fromjdn    first active day (transfers)   28 tojdn  last active day
# 29 credtail   PWD|KEY (the _SCP_ tail + comm-profile name)
# 30 tags       comma list — see gen-events.awk for every consumer
# 31 allowips   ";"-list for customAttributes.AllowIPn ("" = none)

function hastag(tags, t) { return ("," tags ",") ~ ("," t ",") }

function knob(k) { return KN[k] }

# ---- per-account derivations (flows of one account must agree) --------------
function acct_login(acct) {
    srnd(hash(ENV "|login|" acct))
    return sprintf("FE%06d", 100 + rint(899000))
}
function acct_biz(acct) { srnd(hash(ENV "|acct|" acct)); return uuid4() }

# ---- the flow emitter --------------------------------------------------------
# addf(uc, dom, app, ptn, sfx, vol, fail, tags [, acctover])
#   sfx      appended to the site name ("" = none), e.g. "2", "_D"
#   acctover overrides the derived account name (twins, shared accounts)
function addf(uc, dom, app, ptn, sfx, vol, fail, tags, acctover,
              site, acct, sep, prof, login, host, ips, spell, port, sched,
              pat, fdk, fdir, size, f0, f1, cred, allow, pd, base, i, n, oi) {
    base = dom "_" app (ptn == "" ? "" : "_" ptn)
    site = "UC" uc "_" base sfx
    prof = base sfx
    sep  = (uc == 2 || uc == 4) ? "-" : "_"
    if (acctover != "") acct = acctover
    else { acct = base sfx; gsub(/_/, sep, acct) }

    srnd(hash(ENV "|flow|" site))
    # pattern + flowdir per UC; production uses the HYBRID parameter keys
    if (uc == 1)      { pat = "APP_CFT_PESIT_PUSH_ST_HYBRID_PUSH_PARTNER";       fdir = "out" }
    else if (uc == 2) { pat = "APP_CFT_PESIT_PUSH_ST_HYBRID_PULL_PARTNER";       fdir = "out" }
    else if (uc == 3) { pat = "C0002_HYBRID_PULL_PARTNER_ST_CFT_PESIT_PUSH_APP"; fdir = "in" }
    else if (uc == 4) { pat = "C0003_HYBRID_PUSH_PARTNER_ST_CFT_PESIT_PUSH_APP"; fdir = "in" }
    else if (uc == 5) { pat = "PARTNER_PULL_ST_PARTNER_PUSH";                    fdir = "relay" }
    else              { pat = "PARTNER_PUSH_ST_PARTNER_PUSH";                    fdir = "relay" }
    if (fdir == "relay")            fdk = "relay"
    else if (ENV == "production")   fdk = (fdir == "out") ? "hybt" : "hybs"
    else                            fdk = (fdir == "out") ? "scan" : "work"

    # endpoint / sources from the partner org seed
    oi = (ptn in PORG) ? ptn : "GLOBEX"
    if (uc == 1 || uc == 3 || uc == 5) {                     # we connect OUT
        host = PHOST[oi]; spell = "dns"
        n = PNIPS[oi]; ips = ""
        for (i = 0; i < n; i++) ips = ips (i ? ";" : "") PBASE[oi] "." (POCT[oi] + i)
        port = (site ~ /CREDITREG|CD_QUOTES_STARK/) ? 21 : 22
        login = ""
    } else {                                                  # the partner connects IN
        host = ""; spell = "ip"
        n = PNIPS[oi]; ips = ""
        for (i = 0; i < n; i++) ips = ips (i ? ";" : "") PBASE[oi] "." (POCT[oi] + i)
        port = 22
        login = acct_login(acct)
    }
    if (hastag(tags, "mixedspell")) spell = "mixed"
    # one login serving several accounts (the Account-sharing report's rows)
    if (hastag(tags, "sharelogin")) login = "FE001111"
    # a flow with its OWN login on a shared account (the production MULTI-FE
    # shape, 2026-08-31): the account carries several FE logins, one per flow
    if (hastag(tags, "ownlogin")) login = acct_login(acct "|" site)
    # the VDN org is deliberately absent from partners.tsv (a partner-less
    # 2-token account exercising the PDA fallbacks) — dedicated addresses, so
    # the whitelist union-find can never merge it into a seeded org
    if (hastag(tags, "vdn")) { host = ""; spell = "ip"; ips = "203.0.113.160;203.0.113.161" }

    # schedule
    if (uc == 1)      sched = "scan:" (6 + rint(4)) " " (11 + rint(4)) " " (16 + rint(6))
    else if (uc == 2) sched = "stage:" (7 + rint(4)) " " (14 + rint(5))
    else if (uc == 3) { i = rint(3)
        sched = (i == 0) ? "c15" : (i == 1 ? "ch:" sprintf("%02d", rint(60)) : "cd:" sprintf("%02d:%02d", 5 + rint(4), 5 * rint(12))) }
    else if (uc == 4) sched = "push:" PCLASS[oi]
    else              sched = "cd:06:00"
    if (hastag(tags, "grid15")) sched = "grid15"

    size = 2000 + int(rexp(300000))
    f0 = J0; f1 = J1
    if (hastag(tags, "late"))  f0 = J0 + int(NDAYS * 0.55)
    if (hastag(tags, "late2")) f0 = J0 + int(NDAYS * 0.8)
    if (hastag(tags, "quiet")) f1 = J1 - 12 - rint(8)
    cred = (rnd() < 0.3) ? "KEY" : "PWD"

    # whitelist: in-side accounts carry the partner's live sources + this org's
    # UNSEEN region (per-org unique — a shared IP would union-merge two orgs;
    # the org-less VDN gets its own region for the same reason)
    allow = ""
    if (uc == 2 || uc == 4) {
        allow = ips
        if (hastag(tags, "vdn")) allow = allow ";203.0.113.162;203.0.113.163"
        else for (i = 0; i < 2; i++) allow = allow ";" PBASE[oi] "." (PUNSEEN[oi] + i)
    }

    pd = ""
    if ((uc == 2 || uc == 4) && rnd() < 0.35) { pd = prof; gsub(/_/, "-", pd) }

    NF_++
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        tolower(site), ENV, uc, site, acct, login, prof, pd, dom, app, ptn, \
        uuid4(), uuid4(), uuid4(), acct_biz(acct), pat, fdk, fdir, host, ips, spell, port, \
        sched, vol, fail, size, f0, f1, cred, tags, allow > EST
    # tallies for _expected.tsv
    T["subs"]++; T["subs_uc" uc]++
    if (hastag(tags, "noxfer")) T["orange"]++
    else if (hastag(tags, "blue")) T["blue"]++
    else if (hastag(tags, "bluelogon")) { T["blue"]++; T["bluelogon"]++ }   # the xref enrich
                                        # walks the logon sighting to the account's single
                                        # subscription, so these come out BLUE too
    else if (hastag(tags, "greenpoll")) T["greenpoll"]++
    else T["seen"]++
    if (hastag(tags, "nocron")) T["nocron"]++
    if (tags ~ /reason=/) T["reasons"]++
}

# account-only row (an orphaned account: config residue with no flows).
# Same 31 columns as a flow row; only 1 key, 2 env, 3 "A", 5 account,
# 11 partner token, 15 acctbiz, 30 tags are filled.
function addacct(acct, ptn, tags,   i, row) {
    NF_++
    row = tolower("acct-" acct) "\t" ENV "\tA\t\t" acct "\t\t\t\t\t\t" ptn \
          "\t\t\t\t" acct_biz(acct)
    for (i = 16; i <= 29; i++) row = row "\t"
    row = row "\t" tags "\t"
    print row > EST
    T["orphans"]++
}

BEGIN {
    # ---- seeds --------------------------------------------------------------
    while ((getline l < KNOBS) > 0) {
        if (l ~ /^[ \t]*#/ || l ~ /^[ \t]*$/) continue
        split(l, a, "\t"); KN[a[1]] = a[2]
    }
    close(KNOBS)
    NP = 0
    while ((getline l < PARTNERS) > 0) {
        if (l ~ /^[ \t]*#/ || l ~ /^[ \t]*$/) continue
        n = split(l, a, "\t")
        t = a[1]; PORG[t] = ++NP
        PHOST[t] = a[2]
        split(a[3], q, ".")
        PBASE[t] = q[1] "." q[2] "." q[3]; POCT[t] = q[4] + 0
        PNIPS[t] = a[4] + 0; PCLASS[t] = a[5]
        # unseen whitelist region: unique per org (see addf)
        PUNSEEN[t] = 170 + ((NP - 1) % 15) * 5
    }
    close(PARTNERS)

    pfx = (ENV == "production") ? "prd" : "acc"
    J0 = iso2jdn(knob(pfx "_start")); NDAYS = knob(pfx "_days") + 0; J1 = J0 + NDAYS - 1
    EST = OUTDIR "/_estate.tsv"; CAL = OUTDIR "/_calendar.tsv"; EXP = OUTDIR "/_expected.tsv"

    # ---- the calendar -------------------------------------------------------
    ns = split(knob(pfx "_spikes"), SPK, " ")
    storm = knob(pfx "_storm")
    srnd(hash(ENV "|calendar"))
    for (j = J0; j <= J1; j++) {
        d = fromjdn(j); dow = j % 7                    # jdn%7: 5,6 = Sat,Sun
        f = (dow >= 5) ? knob("weekend_factor") + 0 : 1.0
        flags = ""
        for (i = 1; i <= ns; i++) if (SPK[i] == d) { f *= 2.6; flags = "spike" }
        if (d == storm) flags = flags (flags == "" ? "" : ",") "storm"
        # SLOW PLATFORM days (~1 in 14): the store-and-forward gaps stretch by
        # the given factor, pushing that day's Duration percentiles into
        # minutes — the extremes the day tables and the anomalies report feed
        # on. One is PINNED into the newest fortnight so the home page's
        # default 14-day view always shows a minutes-scale row.
        sl = rnd()
        if (flags == "" && (sl < 0.07 || j == J1 - 5)) flags = "slow:" (8 + rint(18))
        printf "%s\t%d\t%s\t%.3f\t%s\n", ENV, j, d, f, flags > CAL
    }

    # ---- the roster ---------------------------------------------------------
    if (ENV == "acceptance") build_acceptance()
    else                     build_production()

    # ---- expectations -------------------------------------------------------
    for (k in T) printf "%s\t%s\t%d\n", ENV, k, T[k] > EXP
}

function build_acceptance() {
    # ======== UC1 — we push to the partner (Inbound pesit + Outbound ssh) ====
    addf(1, "FIN", "BILLING",  "GLOBEX",   "", 55, 0.04, "whale")
    addf(1, "FIN", "LEDGER",   "GLOBEX",   "",  4, 0.03, "twinb")
    addf(1, "FIN", "BILLING",  "GLOBEXX",  "",  1, 0.05, "")            # alias misspelling
    addf(1, "CD",  "PRINTMGMT","WONKA",    "", 12, 0.06, "")
    addf(1, "CD",  "COSMOS",   "WONKA",    "", 26, 0.03, "rename=UC1_CD_COSMOS_WONKA_CD_COSMOS_WONKA")
    addf(1, "IT",  "ARCHIVE",  "INITECH",  "",  5, 0.04, "")
    addf(1, "HR",  "PAYROLL",  "INITECH",  "",  4, 0.05, "avblock")
    addf(1, "AB",  "CLAIMS",   "UMBRELLA", "",  5, 0.04, "skipbait")
    addf(1, "AB",  "POLIS",    "UMBRELLA", "",  1.5, 0.03, "")
    addf(1, "ZG",  "PENSION",  "HOOLI",    "",  4, 0.04, "")
    addf(1, "IT",  "CRM",      "STARK",    "",  1.5, 0.2, "reason=fingerprint")
    addf(1, "APS", "RISK",     "TYRELL",   "",  4, 0.15, "reason=connfail,g2r")
    addf(1, "CD",  "INVOICE",  "VANDELAY", "",  1.5, 0.2, "reason=routestop")
    addf(1, "SI",  "PORTAL",   "OSCORP",   "",  1.2, 0.2, "reason=sitemissing")
    addf(1, "WA",  "BATCH",    "WAYNE",    "",  1.5, 0.03, "")
    addf(1, "FS",  "MORTGAGE", "SABRE",    "",  4, 0.03, "")
    addf(1, "DPL", "AUDITLOG", "DUNDER",   "",  1.5, 0.03, "quiet")
    addf(1, "CB",  "MARKETING","WNK",      "",  1.2, 0.04, "")          # alias star member
    addf(1, "ODV", "DMS",      "CYBERDYNE","",  4, 0.04, "ascii")
    addf(1, "IT",  "LEDGER",   "HOOLI",    "",  1.5, 0.03, "rename=UC1_IT_GENLEDGER_HOOLI")
    addf(1, "APS", "STREAM",   "SOYLENT",  "",  4, 0.18, "reason=pesitrefused")
    addf(1, "AB",  "HRDATA",   "WEYLAND",  "",  1.2, 0.2, "reason=stfs")
    addf(1, "SYNT","ITP",      "APERTURE", "",  1.2, 0.2, "reason=postaction")
    addf(1, "FIN", "TREASURY", "GEKKO",    "",  4, 0.05, "stormy")
    addf(1, "ZK",  "CLAIMS",   "BLACKMESA","",  0.5, 0.1, "resub")
    addf(1, "AIM", "SAPPO",    "WONKA-PUO","",  1.2, 0.04, "")          # alias star member
    addf(1, "CDV", "STREAM",   "DUFF",     "",  1.5, 0.03, "")
    addf(1, "IT",  "HEARTBEAT","INITECH",  "",  1.5, 0.02, "skipflow")  # skip-listed wholesale
    addf(1, "APS", "TELEM",    "GEKKO",    "",  2, 0.05, "late,firstseen")
    # configured, never seen (orange)
    addf(1, "FIN", "CLAIMS",   "MONARCH",  "", 0, 0, "noxfer")
    addf(1, "HR",  "ARCHIVE",  "ZORG",     "", 0, 0, "noxfer")
    addf(1, "IT",  "BILLING",  "BLUTH",    "", 0, 0, "noxfer")
    addf(1, "ZG",  "DMS",      "PRIMATECH","", 0, 0, "noxfer")
    addf(1, "AB",  "PORTAL",   "ABSTERGO", "", 0, 0, "noxfer")
    addf(1, "CD",  "BATCH",    "MASSIVE",  "", 0, 0, "noxfer")
    addf(1, "WA",  "CRM",      "PIEDPIPER","", 0, 0, "noxfer")
    addf(1, "FS",  "PENSION",  "DUNDER",   "", 0, 0, "noxfer,credexp")
    # server-log-only (blue)
    addf(1, "APS", "INVOICE",  "STARK",    "", 0, 0, "blue")
    addf(1, "ODV", "RISK",     "TYRELL",   "", 0, 0, "blue")

    # ======== UC2 — the partner collects from us (4-leg / staged) ===========
    addf(2, "APS", "VIDA",     "UMBRELLA", "",  9, 0.02, "waitheavy,expheavy")
    addf(2, "IT",  "SAPBHP",   "GEKKO",    "",  4, 0.02, "expheavy")
    addf(2, "WA",  "VDN",      "",         "",  3, 0.02, "vdn")          # 2-token site
    addf(2, "SI",  "VPS",      "VDN",      "",  1.5, 0.02, "vdn")
    addf(2, "IT",  "EKDSI",    "CYBERDYNE","",  5, 0.02, "twinc")        # UC2+UC4 one account
    addf(2, "CD",  "ARIVA",    "BLUTH",    "",  0.4, 0.02, "")
    addf(2, "CD",  "ARIVA",    "DUNDER",   "",  0.4, 0.02, "")
    addf(2, "CD",  "ARIVA",    "SABRE",    "",  0.3, 0.02, "")
    addf(2, "ODV", "MAIA",     "PIEDPIPER","",  1.5, 0.03, "")
    addf(2, "ZG",  "MATCH",    "HOOLI",    "",  1.5, 0.02, "")
    addf(2, "DPL", "POLIS",    "TYRELL",   "",  1.2, 0.02, "waitheavy,rename=UC2_DPL_POLIS_TYRELL2")
    addf(2, "FS",  "STMT",     "APERTURE", "",  2, 0.02, "shareduc4")    # shared-session UC4 drop
    # orange
    addf(2, "CB",  "VIDA",     "WAYNE",    "", 0, 0, "noxfer")
    addf(2, "IT",  "MAIA",     "SOYLENT",  "", 0, 0, "noxfer")
    addf(2, "AB",  "EKDSI",    "STARK",    "", 0, 0, "noxfer")
    addf(2, "ZK",  "ARIVA",    "OSCORP",   "", 0, 0, "noxfer")
    addf(2, "HR",  "MATCH",    "VANDELAY", "", 0, 0, "noxfer")
    # blue
    addf(2, "SI",  "SAPBHP",   "APERTURE", "", 0, 0, "bluelogon")

    # ======== UC3 — we poll the partner (Inbound ssh/ftp + Outbound pesit) ===
    addf(3, "APS", "FMGENLOG", "CYBERDYNE","", 14, 0.05, "")
    addf(3, "AB",  "NAS",      "GLOBEX",   "",  8, 0.04, "rename=UC3_AB_NAS2_GLOBEX")
    addf(3, "APS", "SYSHUB",   "SOYLENT",  "",  4, 0.04, "")
    addf(3, "FIN", "LEDGER",   "GLOBEX",   "",  2, 0.03, "twinb")        # UC1 twin (rule B)
    addf(3, "APS", "SETTLE",   "P2P",      "1", 1.5, 0.03, "p2p")
    addf(3, "APS", "SETTLE",   "P2P",      "2", 1.2, 0.03, "p2p")
    addf(3, "FIN", "FACTS",    "MASSIVE",  "",  1.5, 0.25, "reason=nodir")
    addf(3, "ZG",  "PGBMATCH", "APERTURE", "",  1.2, 0.25, "reason=listing")
    addf(3, "SI",  "TELEMETRY","STARK",    "",  2, 0.3, "reason=authout,g2r,pollfail")
    addf(3, "ODV", "MERLIJN",  "SABRE",    "_D", 1.5, 0.03, "")
    addf(3, "ODV", "MERLIJN",  "SABRE",    "_I", 1.2, 0.03, "")
    addf(3, "ZK",  "IKAZ",     "BLACKMESA","",  1.2, 0.05, "weakssh")
    addf(3, "CDV", "STREAM",   "DUFF",     "_I", 1.2, 0.03, "nocron")
    addf(3, "AB",  "CREDITREG","WEYLAND",  "",  1.5, 0.06, "ftp")
    addf(3, "HR",  "AFAS",     "GEKKO",    "",  1.2, 0.04, "nocron")
    addf(3, "IT",  "DISPATCH", "INITECH",  "",  1.5, 0.04, "driftcron")
    addf(3, "WA",  "TELEMATICS","MONARCH", "",  1.2, 0.25, "reason=tracking")
    addf(3, "CB",  "QUOTES",   "GEKKO",    "",  1.2, 0.25, "reason=unavailable")
    addf(3, "CD",  "QUOTES",   "STARK",    "",  1.2, 0.25, "reason=ftpspull")
    addf(3, "IT",  "RECON",    "HOOLI",    "",  2, 0.05, "recover")
    # clean-poll greens (poll works, nothing to fetch — no transfers ever)
    addf(3, "FS",  "SAPBODS",  "PRIMATECH","_D", 0, 0, "greenpoll")
    addf(3, "FS",  "SAPBODS",  "PRIMATECH","_I", 0, 0, "greenpoll")
    addf(3, "FS",  "SAPBODS",  "PRIMATECH","_M", 0, 0, "greenpoll")
    addf(3, "CDV", "STREAM",   "ABSTERGO", "",  0, 0, "greenpoll")
    addf(3, "APS", "FMREPLERR","CYBERDYNE","",  0, 0, "greenpoll")
    addf(3, "ODV", "EMIS",     "ZORG",     "",  0, 0, "greenpoll")
    # orange
    addf(3, "ZG",  "IKAZ",     "BLUTH",    "", 0, 0, "noxfer")
    addf(3, "AB",  "EXPORT",   "WAYNE",    "", 0, 0, "noxfer")
    addf(3, "IT",  "FACTS",    "HOOLI",    "", 0, 0, "noxfer,nocron")
    addf(3, "DPL", "STREAM",   "UMBRELLA", "", 0, 0, "noxfer")
    addf(3, "SYNT","NAS",      "TYRELL",   "", 0, 0, "noxfer")
    # blue
    addf(3, "AIM", "QUOTES",   "WONKA",    "", 0, 0, "blue")
    addf(3, "FIN", "NAS",      "VANDELAY", "", 0, 0, "blue")

    # ======== UC4 — the partner delivers to us (Inbound ssh + Outbound pesit)
    addf(4, "APS", "COSMOS",   "GLOBEX",   "", 38, 0.01, "rename=UC4_APS_COSMOS-GLOBEX")
    addf(4, "CDV", "KRP-TDI",  "WONKA",    "", 10, 0.01, "")
    addf(4, "IT",  "EKDSI",    "CYBERDYNE","",  5, 0.01, "twinc", "IT-EKDSI-CYBERDYNE")
    addf(4, "AIM", "LAKE",     "PIEDPIPER","",  4, 0.01, "")
    addf(4, "ZG",  "ZKA",      "HOOLI",    "",  4, 0.01, "")
    addf(4, "ODV", "ARE",      "APERTURE", "",  1.5, 0.02, "sessjoin", "ODV-ARE-APERTURE")
    addf(4, "ODV", "ARE",      "APERTURE", "2", 1.2, 0.02, "sessjoin", "ODV-ARE-APERTURE")
    addf(4, "ZK",  "MIAZ",     "INITECH",  "",  1.5, 0.01, "")
    addf(4, "WA",  "SENSOR",   "STARK",    "",  2, 0.02, "mixedspell")
    addf(4, "CD",  "INVOICE",  "VANDELAY", "",  1.2, 0.02, "twina")      # rule-A pair w/ UC1
    addf(4, "SI",  "ROS",      "SABRE",    "",  1.5, 0.3, "reason=rfa")
    addf(4, "HR",  "PENSION",  "OSCORP",   "",  1.2, 0.3, "reason=pesitabort")
    addf(4, "IT",  "TDRS",     "BLUTH",    "",  1.5, 0.3, "reason=network")
    addf(4, "ZG",  "CIVIL",    "DUNDER",   "",  1.5, 0.01, "sharelogin", "ZG-CIVIL-DUNDER")
    addf(4, "ZG",  "BULK",     "DUNDER",   "",  1.2, 0.01, "sharelogin", "ZG-BULK-DUNDER")
    addf(4, "AB",  "SCAN",     "MONARCH",  "",  2, 0.05, "avblock,averror")
    addf(4, "CB",  "ISOLATED", "SOYLENT",  "",  1.2, 0.02, "ucx", "CB-ISOLATED-SOYLENT")
    addf(4, "CB",  "ISOLATED", "SOYLENT",  "2", 1.0, 0.02, "ucx", "CB-ISOLATED-SOYLENT")
    addf(4, "FS",  "STMT",     "APERTURE", "_IN", 1.5, 0.01, "shareduc4", "FS-STMT-APERTURE")
    addf(4, "DPL", "RENSEI",   "SOYLENT",  "",  1.2, 0.02, "late2,firstseen")
    # orange
    addf(4, "CD",  "ZIBA",     "GEKKO",    "", 0, 0, "noxfer")
    addf(4, "FS",  "IFRS",     "WAYNE",    "", 0, 0, "noxfer")
    addf(4, "AB",  "TDRS",     "PRIMATECH","", 0, 0, "noxfer")
    addf(4, "ZK",  "SENSOR",   "SOYLENT",  "", 0, 0, "noxfer,credexp")
    addf(4, "HR",  "LAKE",     "BLACKMESA","", 0, 0, "noxfer")
    addf(4, "WA",  "ZKA",      "ABSTERGO", "", 0, 0, "noxfer")
    # blue
    addf(4, "DPL", "SCAN",     "CYBERDYNE","", 0, 0, "bluelogon")
    addf(4, "IT",  "ARCHIVE",  "ZORG",     "", 0, 0, "bluelogon")
    addf(4, "FIN", "PORTAL",   "DUFF",     "", 0, 0, "bluelogon")

    # ======== the relays + the monitor ======================================
    addf(5, "CB",  "STARK",    "WAYNE",    "", 0, 0, "blue,relay")
    addf(8, "ZG",  "HOOLI",    "GEKKO",    "", 0, 0, "noxfer,relay")
    monitor_flows()

    # the orphaned account (config residue: no subscriptions at all)
    addacct("OLD-MIGRATION-GLOBEX", "GLOBEX", "orphan")
}

# The CFT end-to-end monitor: four sites UC<n>-INFRA_ST-MONITOR_INFRA (note
# the DASH after the UC number — the real monitor's spelling, matched by
# bin/dashboards/reports/monitor.sh as ^UC1[-_]INFRA_ST-MONITOR_INFRA$),
# one account, one file every 15 minutes through all four UCs.
function monitor_flows(   u) {
    for (u = 1; u <= 4; u++) {
        NF_++
        srnd(hash(ENV "|flow|UC" u "-INFRA_ST-MONITOR_INFRA"))
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            tolower("uc" u "-infra_st-monitor_infra"), ENV, u, \
            "UC" u "-INFRA_ST-MONITOR_INFRA", "INFRA_ST-MONITOR_INFRA", "FE000000", \
            "INFRA-MONITOR-UC" u, "", "INFRA", "ST-MONITOR", "INFRA", \
            uuid4(), uuid4(), uuid4(), acct_biz("INFRA_ST-MONITOR_INFRA"), \
            (u <= 2 ? "APP_CFT_PESIT_PUSH_ST_HYBRID_" (u == 1 ? "PUSH" : "PULL") "_PARTNER" \
                    : "C000" u "_HYBRID_" (u == 4 ? "PUSH" : "PULL") "_PARTNER_ST_CFT_PESIT_PUSH_APP"), \
            (u == 1 || u == 2) ? "scan" : "work", (u <= 2 ? "out" : "in"), \
            ((u == 2 || u == 4) ? "" : "filetransfer.acme.example"), "192.0.2.77", "dns", 22, \
            "grid15", 90, 0.01, 16, J0, J1, "PWD", "monitor,grid15", \
            (u == 2 || u == 4 ? "192.0.2.77" : "") > EST
        T["subs"]++; T["subs_uc" u]++; T["seen"]++
    }
    T["monitor"] = 4
}

function build_production() {
    # shared-name flows (acc-vs-prod comparability), HYBRID parameter style
    addf(1, "FIN", "BILLING",  "GLOBEX",   "", 30, 0.03, "whale")
    addf(1, "CD",  "COSMOS",   "WONKA",    "", 20, 0.02, "")
    addf(1, "CD",  "PRINTMGMT","WONKA",    "", 10, 0.04, "")
    addf(1, "IT",  "ARCHIVE",  "INITECH",  "",  4, 0.03, "")
    addf(1, "AB",  "CLAIMS",   "UMBRELLA", "",  4, 0.03, "")
    addf(1, "ZG",  "PENSION",  "HOOLI",    "",  3, 0.03, "")
    addf(1, "FS",  "MORTGAGE", "SABRE",    "",  3, 0.03, "")
    addf(2, "APS", "VIDA",     "UMBRELLA", "",  7, 0.02, "waitheavy,expheavy")
    addf(2, "IT",  "SAPBHP",   "GEKKO",    "",  3, 0.02, "expheavy")
    addf(2, "IT",  "EKDSI",    "CYBERDYNE","",  4, 0.02, "twinc")
    addf(2, "ZG",  "MATCH",    "HOOLI",    "",  1.5, 0.02, "")
    # the MULTI-FE ACCOUNT (2026-08-31, user report): one account, TWO FE
    # logins — flow A active on the account login, flow B on its OWN login
    # and never used. uc2-status must read flow B as "Nothing", never
    # "No files": the other login's logons are no pickup evidence for it.
    addf(2, "CD",  "PARCEL",   "BLUTH",    "",  3, 0.02, "")
    addf(2, "CD",  "PARCEL2",  "BLUTH",    "",  0, 0, "noxfer,ownlogin", "CD-PARCEL-BLUTH")
    addf(3, "APS", "FMGENLOG", "CYBERDYNE","", 12, 0.04, "")
    addf(3, "AB",  "NAS",      "GLOBEX",   "",  6, 0.03, "")
    addf(3, "APS", "SYSHUB",   "SOYLENT",  "",  3, 0.03, "")
    addf(3, "ODV", "MERLIJN",  "SABRE",    "_D", 1.5, 0.03, "")
    addf(3, "IT",  "RECON",    "HOOLI",    "",  2, 0.05, "")
    addf(4, "APS", "COSMOS",   "GLOBEX",   "", 20, 0.01, "")
    addf(4, "CDV", "KRP-TDI",  "WONKA",    "",  8, 0.01, "")
    addf(4, "AIM", "LAKE",     "PIEDPIPER","",  3, 0.01, "")
    addf(4, "ZG",  "ZKA",      "HOOLI",    "",  3, 0.01, "")
    addf(4, "ZK",  "MIAZ",     "INITECH",  "",  1.5, 0.01, "")
    # production-only, NON-UC-NAMED (the hybrid generation): the blacklist
    # blanks their logged site (keep ^UC), so the reverse profile fallback
    # must attribute them — and the "Use case" row derives from the pattern.
    nonuc(2, "STMT",  "EXPORT",  "GLOBEX", 8)          # one account, MANY UC2-derived flows
    nonuc1("INV_PAYMENTS_HOOLI",  4, 3, 0.02)          # in+push  -> UC4-derived
    nonuc1("REC_FEEDS_SOYLENT",   3, 2, 0.03)          # in+pull  -> UC3-derived
    nonuc1("GL_POSTINGS_GEKKO",   1, 2, 0.02)          # out+push -> UC1-derived
    nonuc1("CRM_SYNC_INITECH",    4, 2, 0.02)
    nonuc1("HR_ROSTER_UMBRELLA",  1, 1.5, 0.03)
    # orange + blue
    addf(1, "FIN", "CLAIMS",   "MONARCH",  "", 0, 0, "noxfer")
    addf(3, "ZG",  "IKAZ",     "BLUTH",    "", 0, 0, "noxfer")
    addf(4, "CD",  "ZIBA",     "GEKKO",    "", 0, 0, "noxfer")
    addf(2, "CB",  "VIDA",     "WAYNE",    "", 0, 0, "noxfer")
    addf(1, "HR",  "ARCHIVE",  "ZORG",     "", 0, 0, "noxfer")
    addf(3, "APS", "FMREPLERR","CYBERDYNE","", 0, 0, "greenpoll")
    addf(4, "DPL", "SCAN",     "CYBERDYNE","", 0, 0, "bluelogon")
    addf(1, "APS", "INVOICE",  "STARK",    "", 0, 0, "blue")
    monitor_flows()
}

# a production non-UC-named flow: site carries NO UC prefix; profile == site.
function nonuc1(name, uc, vol, fail,   dom, app, ptn, a) {
    split(name, a, "_"); dom = a[1]; app = a[2]; ptn = a[3]
    nonuc_row(name, uc, dom, app, ptn, vol, fail, "nonuc", "")
}
# one account owning MANY derived flows of one UC (the production shape)
function nonuc(uc, w1, w2, ptn, n,   i, acct) {
    acct = w1 "-" w2 "-" ptn
    for (i = 1; i <= n; i++)
        nonuc_row(w1 "_" w2 "_" ptn "_" sprintf("%02d", i), uc, w1, w2, ptn, 1.2, 0.02, "nonuc,manyuc2", acct)
}
function nonuc_row(name, uc, dom, app, ptn, vol, fail, tags, acctover,
                   site, acct, prof, login, host, ips, spell, port, sched, pat, fdk, fdir, oi, i, n) {
    site = name; prof = name
    if (acctover != "") acct = acctover
    else { acct = name; gsub(/_/, (uc == 2 || uc == 4) ? "-" : "_", acct) }
    srnd(hash(ENV "|flow|" site))
    if (uc == 1)      { pat = "APP_CFT_PESIT_PUSH_ST_HYBRID_PUSH_PARTNER";       fdir = "out"; fdk = "hybt" }
    else if (uc == 2) { pat = "APP_CFT_PESIT_PUSH_ST_HYBRID_PULL_PARTNER";       fdir = "out"; fdk = "hybt" }
    else if (uc == 3) { pat = "C0002_HYBRID_PULL_PARTNER_ST_CFT_PESIT_PUSH_APP"; fdir = "in";  fdk = "hybs" }
    else              { pat = "C0003_HYBRID_PUSH_PARTNER_ST_CFT_PESIT_PUSH_APP"; fdir = "in";  fdk = "hybs" }
    oi = (ptn in PORG) ? ptn : "GLOBEX"
    n = PNIPS[oi]; ips = ""
    for (i = 0; i < n; i++) ips = ips (i ? ";" : "") PBASE[oi] "." (POCT[oi] + i)
    if (uc == 1 || uc == 3) { host = PHOST[oi]; spell = "dns"; login = "" }
    else                    { host = ""; spell = "ip"; login = acct_login(acct) }
    if (uc == 1)      sched = "scan:" (6 + rint(4)) " " (13 + rint(6))
    else if (uc == 2) sched = "stage:" (7 + rint(4)) " " (14 + rint(5))
    else if (uc == 3) sched = "ch:" sprintf("%02d", rint(60))
    else              sched = "push:" PCLASS[oi]
    NF_++
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        tolower(site), ENV, uc, site, acct, login, prof, "", dom, app, ptn, \
        uuid4(), uuid4(), uuid4(), acct_biz(acct), pat, fdk, fdir, host, ips, spell, 22, \
        sched, vol, fail, 2000 + int(rexp(200000)), J0, J1, "PWD", tags, \
        (uc == 2 || uc == 4 ? ips ";" PBASE[oi] "." (PUNSEEN[oi]) : "") > EST
    T["subs"]++; T["subs_uc" uc]++; T["seen"]++; T["nonuc"]++
}
