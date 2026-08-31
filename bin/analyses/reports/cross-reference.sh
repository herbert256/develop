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
# read the transfer caches and write into data/<env>/transfer/reports/, and
# bin/transfer/publish.sh renders their pages) — they live HERE because their
# pages sit in the ANALYSES menu. The lib resolves every path from its own
# location, so sourcing it across areas is safe by design.
source "$SCRIPT_DIR/../../transfer/lib.sh"
mkdir -p "$REPORTS_DIR"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
skip_if_fresh "$REPORTS_DIR/cross-account.rpt" "${BASH_SOURCE[0]}" \
    "$UNKNOWN_DIR/accounts.tsv" "$UNKNOWN_DIR/logins.tsv" \
    "$UNKNOWN_DIR/sites.tsv" "$UNKNOWN_DIR/hosts.tsv" \
    "$CONFIG_BASE"   # cell tints bake the base RESULT colors — the WHOLE tree: the writers are cmp-guarded per file, so a representative would miss a recolor confined to another file
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
ent_unk()   { case $1 in acct) echo accounts;; login) echo logins;; site) echo sites;; host) echo hosts;; *) echo "";; esac }   # data/unknown sidecar (the fake-file SEED lists) per entity

# One pass: per row, record every unordered entity pair (e1 < e2 in ENTS
# order) that appears — existence only, no counting. Emits TAB lines:
#   e1 e2 v1 v2
agg=$(awk -F'\t' -v SPMAP="$CONFIG_XREF/_subscriptions-partners.tsv" -v APMAP="$CONFIG_XREF/_subscriptions-apps.tsv" \
    -v PLMAP="$CONFIG_XREF/_profiles-logicals.tsv" -v SLMAP="$CONFIG_XREF/_subscriptions-logicals.tsv" \
    -v SBMAP="$CONFIG_XREF/_subscriptions-bl.tsv" '
    function uload(f6, M6,   l6, z6, n6) {
        while ((getline l6 < f6) > 0) { n6 = split(l6, z6, "\t")
            if (n6 >= 2 && z6[1] != "" && z6[2] != "")
                M6[toupper(z6[1])] = M6[toupper(z6[1])] (M6[toupper(z6[1])] == "" ? "" : "\037") z6[2] }
        close(f6) }
    function ujoin(v6, k6, M6,   n6, i6, r6) {
        r6 = v6
        if (k6 != "" && (toupper(k6) in M6)) { n6 = split(M6[toupper(k6)], UZ6, "\037")
            for (i6 = 1; i6 <= n6; i6++) if (index("\037" r6 "\037", "\037" UZ6[i6] "\037") == 0)
                r6 = r6 (r6 == "" ? "" : "\037") UZ6[i6] }
        return r6 }
    BEGIN { split("acct login site host lgc ptn app dom bl", E, " ")
        # UNION attribution (cf. pda-entities.sh): partner = _files col 20 ∪
        # the subscription'\''s configured partner(s) (a both-partner file
        # carries an empty col 20); application = col 18 ∪ the subscription'\''s
        # configured application(s) (the FlowID spine — 2026-08-31, no longer
        # the account'\''s); logical = col 13 through the FlowID map ∪ the
        # subscription'\''s configured logical(s)
        uload(SPMAP, sp); uload(APMAP, ap2); uload(PLMAP, pl); uload(SLMAP, sl); uload(SBMAP, sb) }
    NR == FNR {   # CoreId -> the PDA attribution (both rows inherit) + connection side
        pu6 = ujoin($20, $12, sp); if (pu6 != "") ptn[$1] = pu6
        au6 = ujoin($18, $12, ap2); if (au6 != "") app[$1] = au6
        lg0 = ""; if ($13 != "" && (toupper($13) in pl)) lg0 = pl[toupper($13)]
        lu6 = ujoin(lg0, $12, sl); if (lu6 != "") lgc[$1] = lu6
        bu6 = ujoin("", $12, sb); if (bu6 != "") blv[$1] = bu6
        if ($19 != "") dom[$1] = $19
        cn[$1] = $16
        next }
    {
        # host legs: OUTBOUND endpoints only — an incoming connection'\''s
        # source IP is not a host entity (whitelist/incoming views cover it)
        V["acct"] = $4; V["login"] = $5; V["site"] = $6; V["host"] = (cn[$1] == "out" ? $16 : "")
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
#   awk #2  loads the 9 base result caches + the 4 data/unknown seed lists
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
        # A fake-file SEED (data/unknown sidecars — server-log-only entities,
        # bin/build/seen-in-server-log.sh) with no green/red base result is
        # forced RED: its only "transfer" is the fake Failed row, and an
        # unconfigured seed has no base row at all. A missing file reads empty.
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
    function pfx(r) { return (r == "green" || r == "orange" || r == "red" || r == "blue") ? "@{class=res-" r "}" : "" }
    # tint: the base result of the entity (green/orange/red, or blue for a
    # server-log-only entity); a data/unknown seed with no result of its own
    # is forced red. blue wins (a real base value, never overridden).
    function tint(e, v,   r, k) { k = toupper(v); r = R[e, k]
        if (r != "green" && r != "red" && r != "blue" && ((e, k) in U)) r = "red"
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
        printf 'INTRO\tWhich %s goes with which other entity: every pair seen together on at least one log row, PLUS the configured pairs that never appear (an analysis of relationships — no counts, no dates). The two tab rows pick the pair of entity types; each cell tints by its own entity'\''s status (green = last transfer OK, orange = never seen, red = Error, blue = server-log only).\n' "$xcol"
        cat "$TMP/tables-$x"
        printf 'NOTE\tAn analysis of the cross references, not a traffic report. Each cell is colored by that entity result: **light green** = last transfer OK, **light orange** = configured but never seen, **light red** = last transfer Error, **light blue** = surfaced only by the Server \342\206\222 Transfer step (bin/build/seen-in-server-log.sh) with no real transfer. The entities are per-leg attributes (a leg inherits its File'\''s partner/application/domain/logical/BL attribution); pairs where either value is blacklisted or unattributed are not listed. There is no date filter here — seen means seen anywhere in the loaded logs.\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    count=$((count + 1))
done

echo "Data written to $REPORTS_DIR/cross-*.rpt ($count file(s), 8 crosstabs each)." >&2
