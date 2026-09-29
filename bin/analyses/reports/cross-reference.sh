#!/usr/bin/env bash
#
# cross-reference.sh — Entities Cross References: WHICH pairs of the nine
# entities (account, login, subscription, remote host, logical, partner,
# application, domain, BL) belong together — an ANALYSIS
# of the cross references, not a traffic report. Each table lists every (X, Y)
# pair, two columns only: the pairs appearing together in the transfer logs
# plus the pairs configured in the FlowManager exports (the both-ways
# data/flow-manager/xref caches) that never logged. Each CELL is tinted by
# its own entity's RESULT (the base caches' third field — green / orange /
# red). No counts, no drill-downs, and the pages carry no date filter
# (render_report clears CUR_DATES for cross-*). Writes nine
# data files —
#   cross-account.rpt  cross-login.rpt  cross-subscription.rpt
#   cross-host.rpt  cross-logical.rpt
#   cross-partner.rpt  cross-application.rpt  cross-domain.rpt  cross-bl.rpt
# — each holding eight tables (the other eight entities), which publish_lib.sh
# splits into 72 pages. The page's two nav rows are the two selectors: row 1
# (group members) picks the FIRST entity, row 2 (table tabs) the SECOND; each
# row grays out the other row's pick, so a pair is never crossed with itself.
#
# A pair is "seen" when both values appear on ONE technical row; a row
# inherits its File's partner / application / domain / logical / BL
# attribution (cols 20 / 18 / 19 / 13-through-the-FlowID-map /
# 12-through-the-tag-map).
# Pairs where either value is blank (the parse-time blacklist, or a File
# without the attribution) are not listed. The pair data is symmetric, so the
# 36 unordered combinations are computed once and emitted into both
# orientations.
#
# Usage:
#   ./cross-reference.sh    # reads input/*.csv (via the caches), writes data/cross-*.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: these are transfer-DATA reports (they
# read the transfer caches and write into data/transfer/reports/, and
# bin/transfer/publish.sh renders their pages) — they live HERE because their
# pages are analyses/xref/ pages. The lib resolves every path from its own
# location, so sourcing it across areas is safe by design.
source "$SCRIPT_DIR/../../transfer/lib.sh"
source "$ROOT/bin/pda-union.sh"   # SP_AWK: the File attribution UNION (sp_union / ap_union / lg_union / bl_union)
mkdir -p "$REPORTS_DIR"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# Fixed entity order — drives the combos, the table order in each rpt, and
# must match publish_lib.sh's report_tabs labels for the cross-* reports.
ENTS="acct login site host lgc ptn app dom bl"

ent_rpt()   { case $1 in acct) echo cross-account;; login) echo cross-login;; site) echo cross-subscription;; host) echo cross-host;; lgc) echo cross-logical;; ptn) echo cross-partner;; app) echo cross-application;; dom) echo cross-domain;; bl) echo cross-bl;; esac }
ent_tab()   { case $1 in acct) echo "Account";; login) echo "Login";; site) echo "Subscriptions";; host) echo "Hosts";; lgc) echo "Logical";; ptn) echo "Partners";; app) echo "Applications";; dom) echo "Domains";; bl) echo "BL";; esac }
ent_col()   { case $1 in acct) echo "Account";; login) echo "Login";; site) echo "Subscription";; host) echo "Remote Host";; lgc) echo "Logical";; ptn) echo "Partner";; app) echo "Application";; dom) echo "Domain";; bl) echo "BL";; esac }
ent_kind()  { case $1 in acct) echo acct;; login) echo login;; site) echo site;; host) echo host;; lgc) echo lgc;; ptn) echo ptn;; app) echo app;; dom) echo dom;; bl) echo bl;; esac }   # every entity type links to its detail pages
ent_xref()  { case $1 in acct) echo accounts;; login) echo logins;; site) echo subscriptions;; host) echo hosts;; lgc) echo logicals;; ptn) echo partners;; app) echo apps;; dom) echo domains;; bl) echo bl;; esac }   # data/flow-manager/xref item names
ent_base()  { case $1 in acct) echo _accounts;; login) echo _logins;; site) echo _subscriptions;; host) echo _hosts;; lgc) echo _logicals;; ptn) echo _partners;; app) echo _apps;; dom) echo _domains;; bl) echo _bl;; esac }   # base cache (name/direction/result) per entity
ent_unk()   { case $1 in acct) echo accounts;; login) echo logins;; site) echo sites;; host) echo hosts;; *) echo "";; esac }   # data/unknown sidecar (the server-log sighting lists) per entity

# One pass: per row, record every unordered entity pair (e1 < e2 in ENTS
# order) that appears — existence only, no counting. Emits TAB lines:
#   e1 e2 v1 v2
agg=$(awk -F'\t' "${SP_AWK_V[@]}" "$SP_AWK"'
    BEGIN { split("acct login site host lgc ptn app dom bl", E, " ") }
    NR == FNR {   # CoreId -> the PDA attribution (both rows inherit) + connection side
        # the UNION attribution sets (bin/pda-union.sh): partner = col 20 ∪
        # the subscription'\''s configured partner(s), application = col 18 ∪
        # its configured application(s), logical = col 13 through the FlowID
        # map ∪ its configured logical(s), BL = its configured tag(s)
        pu6 = sp_union($20, $12); if (pu6 != "") ptn[$1] = pu6
        au6 = ap_union($18, $12); if (au6 != "") app[$1] = au6
        lu6 = lg_union($13, $12); if (lu6 != "") lgc[$1] = lu6
        bu6 = bl_union($12); if (bu6 != "") blv[$1] = bu6
        if ($19 != "") dom[$1] = $19
        cn[$1] = $16
        next }
    {
        # host legs: OUTBOUND endpoints only — an incoming connection'\''s
        # source IP is not a host entity (whitelist/incoming views cover it)
        hv = (cn[$1] == "out" ? $16 : "")
        # ONE PASS PER DISTINCT ENTITY TUPLE (2026-09-27, speed round 10): the
        # pairs below are a function of these nine values alone, and the legs
        # of a flow nearly all share them — a tuple seen before adds no key
        tk = $4 SUBSEP $5 SUBSEP $6 SUBSEP hv SUBSEP dom[$1] SUBSEP ptn[$1] SUBSEP app[$1] SUBSEP lgc[$1] SUBSEP blv[$1]
        if (tk in TUP) next
        TUP[tk] = 1
        V["acct"] = $4; V["login"] = $5; V["site"] = $6; V["host"] = hv
        V["dom"] = dom[$1]
        # the partner × application sets: one pair-emission pass per member
        # combination (seen[] dedups, so the pairs repeating across
        # iterations are harmless)
        np6 = split(ptn[$1], PT6, "\037"); if (np6 == 0) { PT6[1] = ""; np6 = 1 }
        na6 = split(app[$1], AP6, "\037"); if (na6 == 0) { AP6[1] = ""; na6 = 1 }
        nl6 = split(lgc[$1], LG6, "\037"); if (nl6 == 0) { LG6[1] = ""; nl6 = 1 }
        nb6 = split(blv[$1], BV6, "\037"); if (nb6 == 0) { BV6[1] = ""; nb6 = 1 }
        for (p6 = 1; p6 <= np6; p6++) for (a6 = 1; a6 <= na6; a6++) for (l6 = 1; l6 <= nl6; l6++) for (b6 = 1; b6 <= nb6; b6++) {
            V["ptn"] = PT6[p6]; V["app"] = AP6[a6]; V["lgc"] = LG6[l6]; V["bl"] = BV6[b6]
            for (i = 1; i <= 8; i++) for (j = i + 1; j <= 9; j++) {
                va = V[E[i]]; vb = V[E[j]]
                if (va == "" || vb == "") continue
                seen[E[i] "\t" E[j] "\t" va "\t" vb] = 1
            }
        }
    }
    END { for (k in seen) print k }
' "$FILES" "$PARSED")

# An EMPTY agg (config-only estate: no logs at all) is fine: awk #1's main
# rule is NF-guarded, so the tables render the CONFIGURED pairs alone —
# every row "configured, never seen" — instead of skipping the whole family.

# One table per (X, Y) orientation: every pair — the LOGGED ones (from the
# one-pass agg) plus the CONFIGURED pairs from the both-ways
# data/flow-manager/xref cache (_<x>-<y>.tsv) that never appear in the logs
# — tagged @data:seen (informational). Configured pairs match the logged
# values exactly, case aside.
#
# All 72 tables come out of ONE pass over the agg stream. (The old per-pair
# emit_pair_table shape re-scanned agg 42 times — ~478k re-read lines — and
# forked ~12 $(case-fn) subshells per pair, ~700 forks per run.) The case
# functions above stay as the single source of the per-entity attributes;
# they are called ONCE per entity here, hoisted into the parallel tables the
# bash assembly loop and the awk passes below receive.
RPT_ARR=(); COL_ARR=()
XREFS=""; KINDS=""; BASES=""; TABS=""; COLS=""; UNKS=""
for e in $ENTS; do
    c=$(ent_col "$e")
    RPT_ARR+=("$(ent_rpt "$e")"); COL_ARR+=("$c")
    XREFS="$XREFS $(ent_xref "$e")"; KINDS="$KINDS $(ent_kind "$e")"
    BASES="$BASES $(ent_base "$e")"
    TABS="$TABS|$(ent_tab "$e")"; COLS="$COLS|$c"; UNKS="$UNKS|$(ent_unk "$e")"
done
XREFS=${XREFS# }; KINDS=${KINDS# }; BASES=${BASES# }
TABS=${TABS#|}; COLS=${COLS#|}; UNKS=${UNKS#|}   # |-joined: "Remote Host" has a space, ent_unk is empty for ptn/app/dom

TMP=$(mktemp -d "${TMPDIR:-/tmp}/xref.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Three stages, constant fork count — zero per pair:
#   awk #1  feeds every agg line into BOTH orientations
#           (x-idx ⇥ y-idx ⇥ seen ⇥ v1 ⇥ v2) and appends, per ordered pair,
#           the configured pairs from the xref cache that never logged
#           (dedup + logged-match case aside, first spelling wins — the
#           same merge emit_pair_table ran per pair; a missing pair cache
#           reads empty);
#   sort    ONE C-locale sort orders every table's rows name-first, on the
#           SEPARATOR-FOLDED keys (fields 6/7, cut off straight after) with
#           the raw names as the tiebreak — so FRE-SAPCD-X and FRE_SAPCD_X
#           land next to each other instead of pages apart, the same rule
#           report.js applies when you click the column. The raw names still
#           break every tie, so the order stays total and deterministic;
#   awk #2  loads the 9 base result caches + the 4 data/unknown sighting lists
#           ONCE (not per pair), renders the tinted ROW lines and writes
#           each first entity's six ready table blocks to $TMP/tables-<ent>.
printf '%s\n' "$agg" | awk -F'\t' -v OFS='\t' -v XD="$CONFIG_XREF" -v XREFS="$XREFS" '
    BEGIN { ne = split("acct login site host lgc ptn app dom bl", E, " ")
            split(XREFS, XR, " ")
            for (i = 1; i <= ne; i++) IDX[E[i]] = i }
    # fields 6/7 are SORT KEYS ONLY (cut off before awk #2): the name with _
    # folded onto -, so the two separator spellings of one name sort as
    # neighbours like they do in the client-side sort. Case is left alone.
    function fk(s) { gsub(/_/, "-", s); return s }
    NF {   # agg line: e1 e2 v1 v2 (e1 < e2 in ENTS order) — both orientations
        i = IDX[$1]; j = IDX[$2]
        print i, j, 1, $3, $4, fk($3), fk($4)
        print j, i, 1, $4, $3, fk($4), fk($3)
        L[i, j, toupper($3) SUBSEP toupper($4)] = 1
        L[j, i, toupper($4) SUBSEP toupper($3)] = 1
    }
    END {   # the configured-but-never-logged pairs, per ordered pair
        for (i = 1; i <= ne; i++) for (j = 1; j <= ne; j++) {
            if (i == j) continue
            f = XD "/_" XR[i] "-" XR[j] ".tsv"
            while ((getline l < f) > 0) {
                n = split(l, a, "\t"); if (n < 2) continue
                k = toupper(a[1]) SUBSEP toupper(a[2])
                if (((i, j, k) in L) || ((i, j, k) in C)) continue
                C[i, j, k] = 1
                print i, j, 0, a[1], a[2], fk(a[1]), fk(a[2])
            }
            close(f)
        }
    }
' | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k6,6 -k7,7 -k4,4 -k5,5 \
  | cut -f1-5 \
  | awk -F'\t' -v CB="$CONFIG_BASE" -v UD="$UNKNOWN_DIR" -v TMP="$TMP" \
        -v KINDS="$KINDS" -v BASES="$BASES" -v UNKS="$UNKS" -v COLS="$COLS" -v TABS="$TABS" '
    BEGIN {
        ne = split("acct login site host lgc ptn app dom bl", E, " ")
        split(KINDS, KD, " "); split(BASES, BS, " ")
        split(UNKS, UK, "|"); split(COLS, CL, "|"); split(TABS, TB, "|")
        # each CELL is tinted by ITS OWN entity result (the base caches third
        # field, bin/build/result.sh) — @{class=res-*} per cell, no row tint.
        # A server-log sighting (data/unknown sidecars — names the server log
        # mentions and the transfer log never carries) with NO base row is
        # forced RED: configured nowhere, never transferred. A configured name
        # keeps its own colour. A missing file reads empty.
        for (i = 1; i <= ne; i++) {
            f = CB "/" BS[i] ".tsv"
            while ((getline l < f) > 0) { split(l, a, "\t"); R[i, toupper(a[1])] = a[3] }
            close(f)
            if (UK[i] != "") {
                f = UD "/" UK[i] ".tsv"
                while ((getline l < f) > 0) { split(l, a, "\t"); U[i, toupper(a[1])] = 1 }
                close(f)
            }
        }
    }
    function pfx(r) { return (r == "green" || r == "orange" || r == "red") ? "@{class=res-" r "}" : "" }
    # tint: the base result of the entity (green/orange/red); a data/unknown
    # server-log sighting with NO result of its own (configured nowhere) is
    # forced red. A configured name keeps its own colour.
    function tint(e, v,   r, k) { k = toupper(v); r = ((e, k) in R) ? R[e, k] : ""
        if (r == "" && ((e, k) in U)) r = "red"
        return pfx(r) }
    NF { n = ++cnt[$1, $2]; rows[$1, $2, n] = "ROW\t" tint($1, $4) $4 "\t" tint($2, $5) $5 "\t@data:seen=" $3 }
    END {   # fixed ENTS-order iteration — never awk hash order
        for (x = 1; x <= ne; x++) {
            out = TMP "/tables-" E[x]
            for (y = 1; y <= ne; y++) {
                if (y == x) continue
                print "TABLE\t" TB[x] " × " TB[y] "\tgroup" > out
                print "HEAD\t" CL[x] "\t" CL[y] > out
                print "KIND\t" KD[x] "\t" KD[y] > out
                n = cnt[x, y] + 0
                for (r = 1; r <= n; r++) print rows[x, y, r] > out
                print "TOTAL\t@{colspan=2}Total (" n " pair(s))" > out
            }
            close(out)
        }
    }
'

count=0
for x in $ENTS; do
    OUT="$REPORTS_DIR/${RPT_ARR[$count]}.rpt"
    xcol=${COL_ARR[$count]}
    {
        printf 'TITLE\tCross Reference: %s\n' "$xcol"
        printf 'DESC\tEvery %s pair with each other entity — logged pairs plus the configured-but-never-logged ones; each cell is tinted by that entity'\''s result (green = last transfer OK, orange = never seen, red = Error).\n' "$xcol"
        printf 'INTRO\tWhich %s goes with which other entity: every pair seen together on at least one log row, PLUS the configured pairs that never appear (an analysis of relationships — no counts, no dates). The two tab rows pick the pair of entity types; each cell tints by its own entity'\''s status (green = last transfer OK, orange = never seen, red = Error, or a name the server log mentions and nothing configures).\n' "$xcol"
        cat "$TMP/tables-$x"
        printf 'FOOT\n'
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    count=$((count + 1))
done

echo "Data written to $REPORTS_DIR/cross-*.rpt ($count file(s), 8 crosstabs each)." >&2
