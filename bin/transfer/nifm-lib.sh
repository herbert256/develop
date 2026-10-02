#!/usr/bin/env bash
#
# bin/transfer/nifm-lib.sh — THE "NOT IN FLOW MANAGER" CLASSIFIER, shared
# (sourced) by its two users so they can never disagree on which File is an
# entry of which row:
#   bin/transfer/reports/not-in-flow-manager.sh  the report, its per-row pages
#                                                (docs/not-in-fm/<type>_<slug>.html)
#   bin/transfer/filepages.sh                    the File pages of the first 10
#                                                rows of each such page (kind N)
# (one awk program until 2026-10-02 — the per-row pages and their File pages
# came that day, user request).
#
#   nifm_prepare        -> NIFM_V: the awk -v arguments (the configured lists +
#                          the FlowID map + the BL tag map), from the pristine
#                          configured snapshot base/.configured.tsv when there
#                          is one (the base caches carry the logged-but-
#                          unconfigured names result.sh discovered), else the
#                          base caches themselves. Its temp dir: NIFM_TMP
#                          (the caller removes it).
#   NIFM_TWORD_AWK      -> nifm_tword(t): the type word of a page name
#   NIFM_AWK            -> the awk functions: nifm_load() in BEGIN, then
#                          nifm_row() per _files.tsv row, which calls the
#                          CALLER's nifm_hit(t, v) once per unconfigured
#                          (type, value) of the File. Needs $SP_AWK in front
#                          (bin/pda-union.sh: bl_union).
#
# The types, by index (the report's row order):
#   1 Account      _files col 3   vs base/_accounts.tsv        (exact)
#   2 Subscription _files col 12  vs base/_subscriptions.tsv   (configured name PREFIXES the logged value — the showseen rule)
#   3 Login        _files col 14  vs base/_logins.tsv          (exact)
#   4 Host         _files col 15, connection col 16 == out, vs base/_hosts.tsv (exact; hosts are OUTBOUND endpoints)
#   5 Whitelist    _files col 15, connection col 16 == in,  vs base/_white.tsv (exact; the INCOMING source addresses)
#   6 Logical      _files col 13 resolved through the FlowID map vs base/_logicals.tsv
#   7 Partner      _files col 20  vs base/_partners.tsv        (exact)
#   8 Application  _files col 18  vs base/_apps.tsv            (exact)
#   9 Domain       _files col 19  vs base/_domains.tsv         (exact)
#  10 BL           the subscription's tags (bl_union) vs base/_bl.tsv
# All matching is case-insensitive; a File without a start date is no entry.

nifm_prepare() {
    local B="$CONFIG_BASE" _b
    NIFM_TMP=""
    NIFM_V=()
    for _b in _accounts _subscriptions _logins _hosts _white _logicals _partners _apps _domains _bl; do
        eval "local f$_b=\"$B/$_b.tsv\""
    done
    if [ -f "$B/.configured.tsv" ]; then
        NIFM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/axnifm.XXXXXX")
        for _b in _accounts _subscriptions _logins _hosts _white _logicals _partners _apps _domains _bl; do
            awk -F'\t' -v t="$_b" '$1 == t { print $2 }' "$B/.configured.tsv" > "$NIFM_TMP/$_b.tsv"
            eval "f$_b=\"$NIFM_TMP/$_b.tsv\""
        done
    fi
    NIFM_V=(-v "ACC=$f_accounts" -v "SUB=$f_subscriptions" -v "LOG=$f_logins" -v "HST=$f_hosts"
            -v "WHT=$f_white" -v "LGC=$f_logicals" -v "PTN=$f_partners" -v "APP=$f_apps" -v "DOM=$f_domains" -v "BLB=$f_bl"
            -v "PLM=$CONFIG_XREF/_profiles-logicals.tsv")
}

NIFM_AWK='
    function nifm_ld(t, f,   l, a) {
        while ((getline l < f) > 0) { split(l, a, "\t"); if (a[1] != "") NIFMC[t SUBSEP toupper(a[1])] = 1 }
        close(f)
    }
    function nifm_load(   l, a) {
        nifm_ld(1, ACC); nifm_ld(3, LOG); nifm_ld(4, HST); nifm_ld(5, WHT)
        nifm_ld(6, LGC); nifm_ld(7, PTN); nifm_ld(8, APP); nifm_ld(9, DOM); nifm_ld(10, BLB)
        while ((getline l < PLM) > 0) { split(l, a, "\t"); if (a[1] != "" && a[2] != "") NIFMPL[toupper(a[1])] = a[2] }
        close(PLM)
        # configured subscription names as a LIST (prefix matching)
        while ((getline l < SUB) > 0) { split(l, a, "\t"); if (a[1] != "") NIFMSN[++NIFMNS] = toupper(a[1]) }
        close(SUB)
    }
    # is the logged site value covered by a configured subscription? Exact, or
    # the configured name as a prefix ending at a NAME-PART BOUNDARY (a tail
    # the parse did not strip) — never mid-name (2026-08-31 audit: a genuinely
    # unconfigured UC4_X_Y2 was hidden because UC4_X_Y is configured).
    function nifm_subcfg(v,   u, i) {
        u = toupper(v)
        if (u in NIFMPFC) return NIFMPFC[u]
        for (i = 1; i <= NIFMNS; i++) if (u == NIFMSN[i] || (index(u, NIFMSN[i]) == 1 && substr(u, length(NIFMSN[i]) + 1, 1) !~ /[A-Za-z0-9]/)) { NIFMPFC[u] = 1; return 1 }
        NIFMPFC[u] = 0; return 0
    }
    # the current _files.tsv row: one nifm_hit(t, v) per unconfigured value
    function nifm_row(   lg9, nb9, ib9) {
        if ($4 == "") return
        if ($3  != "" && !((1 SUBSEP toupper($3))  in NIFMC)) nifm_hit(1, $3)
        if ($12 != "" && $12 != "Unknown" && !nifm_subcfg($12)) nifm_hit(2, $12)   # "Unknown" = no subscription (2026-09-29): the Unknown transfers report lists it
        if ($14 != "" && !((3 SUBSEP toupper($14)) in NIFMC)) nifm_hit(3, $14)
        if ($15 != "" && $16 == "out" && !((4 SUBSEP toupper($15)) in NIFMC)) nifm_hit(4, $15)
        if ($15 != "" && $16 == "in"  && !((5 SUBSEP toupper($15)) in NIFMC)) nifm_hit(5, $15)
        # logical / partner / application: the File OWN column only, NOT the
        # shared union (bin/pda-union.sh) — on purpose: the union adds the
        # subscription configured values, which come from Flow Manager by
        # definition, so only the File column can name something unconfigured.
        # BL has no File column: its set IS the configured tag map (bl_union).
        if ($13 != "" && (toupper($13) in NIFMPL)) { lg9 = NIFMPL[toupper($13)]
            if (!((6 SUBSEP toupper(lg9)) in NIFMC)) nifm_hit(6, lg9) }
        if ($20 != "" && !((7 SUBSEP toupper($20)) in NIFMC)) nifm_hit(7, $20)
        if ($18 != "" && !((8 SUBSEP toupper($18)) in NIFMC)) nifm_hit(8, $18)
        if ($19 != "" && !((9 SUBSEP toupper($19)) in NIFMC)) nifm_hit(9, $19)
        nb9 = split(bl_union($12), NIFMB9, "\037")
        for (ib9 = 1; ib9 <= nb9; ib9++) if (!((10 SUBSEP toupper(NIFMB9[ib9])) in NIFMC)) nifm_hit(10, NIFMB9[ib9])
    }
'
# the per-row page name: <type>_<slug> (docs/not-in-fm/), the type word
# lowercase — "account", "subscription", … "bl" (its own snippet: a program
# without nifm_hit cannot take NIFM_AWK)
NIFM_TWORD_AWK='
    function nifm_tword(t) { return (t == 1) ? "account" : (t == 2) ? "subscription" : (t == 3) ? "login" : (t == 4) ? "host" : (t == 5) ? "whitelist" : \
                                    (t == 6) ? "logical" : (t == 7) ? "partner" : (t == 8) ? "application" : (t == 9) ? "domain" : "bl" }
'
