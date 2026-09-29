#!/usr/bin/env bash
#
# bin/pda-union.sh — THE ONE implementation of a File's attribution UNION
# (2026-09-29: it lived in bin/transfer/details_lib.sh, and ~11 reports carried
# a hand copy of it). SOURCED, not run; needs ROOT (every area lib and every
# stand-alone script sets it before sourcing this).
#
# ===== partner / application / logical / BL UNION attribution ================
# A File counts for EVERY partner of its subscription (col 12 joined on
# xref/_subscriptions-partners.tsv) UNIONED with the parse-time attribution
# (col 20): a UC5 relay / both-partner file belongs to BOTH organisations,
# and the both-partner case carries an EMPTY col 20 (the account maps to two
# groups, so the parse abstains). Likewise a File counts for every
# application of its SUBSCRIPTION (col 12 joined on xref/_subscriptions-apps.tsv
# — the FlowID spine, 1:1) unioned with col 18.
# NOT the account any more (2026-08-31): a hybrid production account serves
# many flows, so the account union credited every File of it to every
# application the account touches.
# And a File counts for EVERY logical flow group of its profile (col 13
# resolved through xref/_profiles-logicals.tsv — the FlowID map) UNIONED with
# its subscription's logicals (col 12 on xref/_subscriptions-logicals.tsv).
# And a File counts for every BL tag of its SUBSCRIPTION (col 12 on
# xref/_subscriptions-bl.tsv — no direct column of its own).
# Every join is case-folded (toupper on both keys); the values are kept as
# spelled, deduped exactly, the File column FIRST, then the configured values
# in map order.
#
# Exports:
#   SP_MAP AP_MAP PL_MAP SLG_MAP BL_MAP   the five map paths ("" when missing)
#   SP_AWK     the awk helpers: sp_union(col20, col12) / ap_union(col18,
#              col12) / lg_union(col13, col12) / bl_union(col12) return the
#              \037-joined set (callers split and loop); the generic
#              uni_load(file, M) / uni_join(value, key, M) build them (a
#              caller with a map of its own may use them too). Its BEGIN
#              loads the maps it is handed — a map left out stays empty.
#   SP_AWK_V   the five -v assignments, as an array.
# Inject as
#   awk -F'\t' "${SP_AWK_V[@]}" "$SP_AWK"'...'
# or name only the maps a program needs:
#   awk -F'\t' -v SPMAP="$SP_MAP" -v APMAP="$AP_MAP" -v PLMAP="$PL_MAP" -v SLGMAP="$SLG_MAP" -v BLMAP="$BL_MAP" "$SP_AWK"'...'
# Reserved awk names: the six functions above, SPX APX PLX SLGX BLX SPZ6 and
# the -v names SPMAP APMAP PLMAP SLGMAP BLMAP.
_pu_xref="$ROOT/data/flow-manager/xref"
SP_MAP="$_pu_xref/_subscriptions-partners.tsv"
[ -f "$SP_MAP" ] || SP_MAP=""
AP_MAP="$_pu_xref/_subscriptions-apps.tsv"
[ -f "$AP_MAP" ] || AP_MAP=""
PL_MAP="$_pu_xref/_profiles-logicals.tsv"
[ -f "$PL_MAP" ] || PL_MAP=""
SLG_MAP="$_pu_xref/_subscriptions-logicals.tsv"
[ -f "$SLG_MAP" ] || SLG_MAP=""
BL_MAP="$_pu_xref/_subscriptions-bl.tsv"
[ -f "$BL_MAP" ] || BL_MAP=""
unset _pu_xref
SP_AWK_V=(-v "SPMAP=$SP_MAP" -v "APMAP=$AP_MAP" -v "PLMAP=$PL_MAP" -v "SLGMAP=$SLG_MAP" -v "BLMAP=$BL_MAP")
SP_AWK='
    function uni_load(f6, M6,   l6, z6, n6) { if (f6 == "") return
        while ((getline l6 < f6) > 0) { n6 = split(l6, z6, "\t")
            if (n6 >= 2 && z6[1] != "" && z6[2] != "")
                M6[toupper(z6[1])] = M6[toupper(z6[1])] (M6[toupper(z6[1])] == "" ? "" : "\037") z6[2] }
        close(f6) }
    function uni_join(v6, k6, M6,   n6, i6, r6) {
        r6 = v6
        if (k6 != "" && (toupper(k6) in M6)) { n6 = split(M6[toupper(k6)], SPZ6, "\037")
            for (i6 = 1; i6 <= n6; i6++)
                if (index("\037" r6 "\037", "\037" SPZ6[i6] "\037") == 0)
                    r6 = r6 (r6 == "" ? "" : "\037") SPZ6[i6] }
        return r6 }
    function sp_union(p6, s6) { return uni_join(p6, s6, SPX) }
    function ap_union(a6, ac6) { return uni_join(a6, ac6, APX) }
    function lg_union(p6, s6,   b6) { b6 = ""
        if (p6 != "" && (toupper(p6) in PLX)) b6 = PLX[toupper(p6)]
        return uni_join(b6, s6, SLGX) }
    function bl_union(s6) { return uni_join("", s6, BLX) }
    BEGIN { uni_load(SPMAP, SPX); uni_load(APMAP, APX); uni_load(PLMAP, PLX); uni_load(SLGMAP, SLGX); uni_load(BLMAP, BLX) }
'
