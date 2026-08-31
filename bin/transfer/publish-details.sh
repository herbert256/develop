#!/usr/bin/env bash
#
# bin/transfer/publish-details.sh — render the PER-ENTITY DETAIL PAGES:
#   docs/<env>/details/<sub>/<slug>.html   (one per account/subscription/login/
#                                           host/partner/application/domain/
#                                           incoming connection, plus a
#                                           browsable index per subdir)
# plus the host IP->hostname redirect stubs and the details-side
# transfer-sites -> subscriptions rename stubs.
#
# Split out of bin/transfer/publish.sh 2026-07: the ~2500 detail pages are the
# longest publish by far, so bin/build.sh runs them as their OWN step (after
# the transfer report pages; the two write disjoint docs/ subtrees, so the
# order between them is free). bin/transfer/reports/details.sh must have
# written the detail .rpt files first.
#
# Usage:  bin/transfer/publish-details.sh    (run after the details report)
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; defines the renderer

ensure_assets   # ALWAYS — see the note in bin/transfer/publish.sh

# The detail .rpt tree plus the config caches (the res-* cell tints and the
# 🔗 FlowManager deep links come from data/<env>/flow-manager).
STAMP="$PUBLISH_STAMP_DIR/details.stamp"
UCRPT=()
# the UC2 pickup sidecar (uc2-status.sh): subscription-verdict.awk renders it
# as the "Pickup information" table on UC2 pages and the shared-connection
# note on UC4 pages — an input AND a dep. It must be read BEFORE the uc rpts
# (the fragments are built per ROW), so it goes FIRST in the list, with the
# subscription->account map the UC4 note needs to find its account's row.
[ -f "$DATA/flow-manager/xref/_subscriptions-accounts.tsv" ] && UCRPT+=("$DATA/flow-manager/xref/_subscriptions-accounts.tsv")
[ -f "$DATA/server/reports/uc2-pickups.tsv" ] && UCRPT+=("$DATA/server/reports/uc2-pickups.tsv")
# (NB: a DELETED rpt/sidecar drops out of this list and so out of the
# freshness deps — pages keep the stale baked fragments until any other dep
# changes; the full build always regenerates the inputs first, so this only
# matters for hand-pruned data dirs)
for _u in 1 2 3 4; do
    [ -f "$DATA/server/reports/uc$_u-status.rpt" ] && UCRPT+=("$DATA/server/reports/uc$_u-status.rpt")
done
unset _u
if publish_is_fresh "$STAMP" "$DOCS/details" "${BASH_SOURCE[0]}" \
       "$SCRIPT_DIR/subscription-verdict.awk" \
       "$DATA/transfer/reports/details" "$DATA/flow-manager" \
       "$DATA/transfer/reports/failed-sub-all.rpt" "$DATA/transfer/reports/errors" \
       ${UCRPT[@]+"${UCRPT[@]}"}; then
    echo "docs/$SITE_ENV/details/ is up to date; skipping." >&2
    exit 0
fi

# ---- the per-subscription VERDICT fragments ---------------------------------
# Every subscription detail page opens with the verdict its UCx status report
# gives that flow, in prose. The status reports are the single source — this
# only turns a row into a sentence — so a page and its report cannot disagree.
# They are SERVER reports, produced in the report stage; this publish runs after
# it, which is the only reason the lookup is possible here and not in
# bin/transfer/reports/details.sh (which runs before the server reports exist).
# One awk builds one <slug>.txt fragment per subscription; the render loop
# splices it in after the DESC line. An env with no status reports (production
# configures no UC4 at all) simply gets fewer fragments.
VERDICT_DIR=""
_vsm="$DATA/transfer/reports/details/subscriptions/_slugmap.tsv"
if [ ${#UCRPT[@]} -gt 0 ] && [ -s "$_vsm" ]; then
    VERDICT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/axverdict.XXXXXX")
    awk -F'\t' -v OUT="$VERDICT_DIR" -v SLUGMAP="$_vsm" \
        -f "$SCRIPT_DIR/subscription-verdict.awk" "$_vsm" ${UCRPT[@]+"${UCRPT[@]}"} || true
    # The RELAYS (UC5-UC8) have no status report — the four cover UC1-UC4 — so
    # they get their use-case description instead, from the one place that
    # defines it (bin/uc-cases.sh), rather than no message at all.
    source "$SCRIPT_DIR/../uc-cases.sh"
    while IFS=$'\t' read -r _vn _vs; do
        [ -n "$_vs" ] && [ ! -e "$VERDICT_DIR/$_vs.txt" ] || continue
        _vuc=${_vn%%_*}
        case $_vuc in UC[1-4]) continue ;; UC[0-9]*) ;; *) continue ;; esac   # UC1-4 have status verdicts; the relay text would contradict itself
        _vh=$(uc_meta "$_vuc" | cut -f5)
        [ -n "$_vh" ] || continue
        printf 'INTRO\t**%s** — %s. This is a RELAY use case, which the four **UCx status** reports do not cover (they classify UC1-UC4), so there is no one-word verdict for it: the tables below are the whole picture.\n' \
            "$_vuc" "$_vh" > "$VERDICT_DIR/$_vs.txt"
    done < "$_vsm"
    unset _vn _vs _vuc _vh
    echo "Subscription verdicts: $(ls "$VERDICT_DIR" | wc -l | tr -d ' ') flow(s) described." >&2
fi
trap '[ -n "${VERDICT_DIR:-}" ] && rm -rf "$VERDICT_DIR"' EXIT

# ---- per-entity detail pages ------------------------------------------------
# Render every data/<env>/transfer/reports/details/<sub>/*.rpt to
# docs/<env>/details/<sub>/*.html plus a browsable index of that subdir.
# Detail pages sit two levels below the env root, so their asset/home links
# use ../../ (html_head adds the extra ../ to the docs root itself).
# THE LAST-ERROR SPLICE (2026-08): a subscription sitting in a RED row of
# transfer/failed.html gets that row's error page folded into its detail
# page — the legs table (titled "Last error") and the server-log table,
# spliced in above "Last server log messages" at render time. Publish-time,
# not report-time: details.sh runs OVERLAPPING transfer phase 1, so reading
# errors/*.rpt there would race failed.sh rebuilding them; here every
# report is long finished. The map is slug -> newest failed CoreId (the .rpt
# is newest-first, so the first red row of a subscription is its newest). The
# slug comes from the comprehensive _slugmap.tsv, NEVER re-derived (2026-08-31
# audit — CLAUDE.md'\''s rule for _srvsubs applies verbatim): slugify() has no
# collision bump, so the second of a separator-twin pair (FRE-SAPCD-… /
# FRE_SAPCD_…, whose page is …-2) shared the first twin'\''s key — the wrong
# error page spliced onto one page, none onto the other.
LASTERR_MAP=$(mktemp "${TMPDIR:-/tmp}/axlerr.XXXXXX")
trap 'rm -f "$LASTERR_MAP"' EXIT
if [ -f "$DATA/transfer/reports/failed-sub-all.rpt" ]; then
    _lsm="$_vsm"; [ -f "$_lsm" ] || _lsm=/dev/null
    awk -F'\t' -v SM="$_lsm" 'BEGIN { while ((getline l < SM) > 0) { split(l, a, "\t"); if (a[1] != "" && a[2] != "") S[a[1]] = a[2] } close(SM) }
        $1 != "" && ($1 in S) { print S[$1] "\t" $2 }' <<< "$(awk -F'\t' '
        $1 != "ROW" { next }
        # the row is Subscription / Date/time / Reason since 2026-08 — the
        # CoreId lives only in @data:href; @data:srv=1 = a server-failing
        # row, whose page is subscription-named (no legs table to splice)
        { red = 0; srv = 0; pg = ""
          for (i = 2; i <= NF; i++) {
              if ($i == "@data:res=red") red = 1
              if ($i == "@data:srv=1") srv = 1
              if (index($i, "@data:href=../errors/") == 1) pg = substr($i, 22)
          }
          if (!red || srv) next
          site = $2; sub(/^@\{[^}]*\}/, "", site)
          if (site == "" || (site in seen)) next
          seen[site] = 1
          sub(/\.html$/, "", pg)
          if (pg != "") print site "\t" pg }' "$DATA/transfer/reports/failed-sub-all.rpt")" > "$LASTERR_MAP"
fi

render_details() {   # $1 subdir (accounts|subscriptions)  $2 index title
    local sub=$1 title=$2
    local src="$DATA/transfer/reports/details/$sub" outdir="$DOCS/details/$sub"
    [ -d "$src" ] || return 0
    mkdir -p "$outdir"
    rm -f "$outdir"/*.html
    local f base t hslug="details-$sub"
    # Detail pages sit in docs/<env>/details/<sub>/, so acct/site links resolve
    # from one level up ("../accounts/…", "../subscriptions/…").
    # (The per-subdir index.html listing page was REMOVED 2026-07 — nothing
    # linked it; $2 title only labels the call site now.)
    DLINK_BASE="../"
    local vf vtmp
    for f in "$src"/*.rpt; do
        [ -e "$f" ] || continue
        base=$(basename "$f" .rpt)
        t=$(field1 TITLE "$f")
        # Subscriptions open with their UCx status verdict, spliced in right
        # after DESC so it renders under the <h1>, above every table — the same
        # slot the blue and errors-after-last-transfer banners use.
        vf=""; [ "$sub" = subscriptions ] && [ -n "$VERDICT_DIR" ] && vf="$VERDICT_DIR/$base.txt"
        # the Last-error splice (see the map above): srcf walks through the
        # optional preprocessing steps, each reading the previous one's output
        srcf="$f"; etmp=""
        if [ "$sub" = subscriptions ] && [ -s "$LASTERR_MAP" ]; then
            _lecid=$(awk -F'\t' -v B="$base" '$1 == B { print $2; exit }' "$LASTERR_MAP")
            if [ -n "$_lecid" ] && [ -f "$DATA/transfer/reports/errors/$_lecid.rpt" ]; then
                etmp=$(mktemp "${TMPDIR:-/tmp}/axdle.XXXXXX")
                # Buffer tables 2+3 of the error page (the LEGS and the server
                # log — table 1 is the facts block this page already states),
                # retitle the first "Last error - <reason>" (the reason read
                # from the error page own TITLE, which carries it since
                # 2026-08; a page with none keeps the plain heading), and
                # splice the pair in DIRECTLY BELOW the Features table —
                # before the first table that follows it (before "Last server
                # log messages", then the FOOT, when a page lacks one). A LINK
                # to the full error page closes the insert.
                awk -F'\t' -v OFS='\t' -v ERR="$DATA/transfer/reports/errors/$_lecid.rpt" -v CID="$_lecid" '
                    BEGIN {
                        nb = 0; tbl = 0; reason = ""
                        while ((getline l < ERR) > 0) {
                            split(l, a2, "\t")
                            if (a2[1] == "TITLE") { t2 = a2[2]
                                if (sub(/^Failed subscription: [^ ]+ - /, "", t2)) reason = t2 }
                            if (a2[1] == "TABLE") tbl++
                            if (tbl < 2) continue
                            if (a2[1] == "LINK" || a2[1] == "KEYWORDS" || a2[1] == "SUMMARY" || a2[1] == "FOOT") break
                            if (a2[1] == "TABLE" && tbl == 2) {
                                repl = "TABLE\tLast error" (reason != "" ? " - " reason : "")
                                sub(/^TABLE\t[^\t]*/, repl, l) }
                            BUF[++nb] = l
                        }
                        close(ERR)
                        BUF[++nb] = "LINK\t../../errors/" CID ".html\tThe full page of this failed file"
                    }
                    function inject(   i) { if (done || nb == 0) return; for (i = 1; i <= nb; i++) print BUF[i]; done = 1 }
                    afterfeat && $1 == "TABLE" { inject(); afterfeat = 0 }
                    $1 == "TABLE" && $2 == "Features" { afterfeat = 1 }
                    $1 == "TABLE" && $2 == "Last server log messages" { inject() }
                    $1 == "FOOT" { inject() }
                    { print }
                ' "$srcf" > "$etmp"
                srcf="$etmp"
            fi
        fi
        if [ -n "$vf" ] && [ -s "$vf" ]; then
            vtmp=$(mktemp "${TMPDIR:-/tmp}/axdet.XXXXXX")
            # The verdict REPLACES the two one-liners the writer emits for the
            # same conditions — "Only seen in the server log, never in the
            # transfer log" and "Configured — never seen …" — which it now says
            # with the numbers and the report's own word for it. Dropping them
            # HERE rather than in details.sh keeps them as the fallback: a page
            # that gets no verdict (an environment with no server reports, so no
            # uc<n>-status.rpt) still carries its original line.
            awk -F'\t' -v VF="$vf" '
                # (the blue line opens with the "**" of its bold run, so match
                # anywhere in the field rather than at position 1)
                $1 == "INTRO" && (index($2, "Only seen in the server log") > 0 ||
                                  index($2, "Configured") == 1) { next }
                { print }
                $1 == "DESC" && !d { while ((getline l < VF) > 0) print l; close(VF); d = 1 }' "$srcf" > "$vtmp"
            render_rpt "$vtmp" "$outdir/$base.html" "../../assets/style.css" "index.html" "TRANSFER - $t" "" "$hslug"
            rm -f "$vtmp"
        else
            render_rpt "$srcf" "$outdir/$base.html" "../../assets/style.css" "index.html" "TRANSFER - $t" "" "$hslug"
        fi
        [ -n "$etmp" ] && rm -f "$etmp"
    done
    DLINK_BASE="../details/"
}

# (the FlowManager 🔗 deep-link icons were removed 2026-07 — no META fmlink,
# no FMLINK_MAPS; render_rpt.awk's whole fm machinery went with them)
# Entity RESULT tints on the detail pages (render_rpt.awk resmaps): every
# entity cell gets class res-<result> from its base cache — keys are the
# slugmap sub names, plus "white" for the Whitelisted IPs cells (KIND ip).
RESMAP_FILES=""
for _rm in accounts:_accounts subscriptions:_subscriptions logins:_logins hosts:_hosts \
           logicals:_logicals partners:_partners applications:_apps domains:_domains bl:_bl white:_white; do
    [ -s "$DATA/flow-manager/base/${_rm#*:}.tsv" ] && RESMAP_FILES+="${RESMAP_FILES:+ }${_rm%%:*}=$DATA/flow-manager/base/${_rm#*:}.tsv"
done
unset _rm
# (Server-log-only entities carry result=blue in the base caches — render_rpt.awk
# renders res-blue straight from the resmaps above; no separate overlay.)

# The detail pages carry NO From/To date filter (2026-07): they always show
# the complete period. CUR_DATES stays empty, so html_head emits no
# report-dates/report-area meta and report.js never injects the selectors
# (nor restores/persists the shared per-area range from these pages).
CUR_DATES=""

# IN PARALLEL (2026-07): the ten subdirs write disjoint docs/ subtrees and
# every render temp is mktemp-unique, so each call runs in its own background
# subshell (which also isolates the DLINK_BASE mutation). Serially this was
# the slowest publish (~33 s); the wall clock is now the biggest subdir.
dt_pids=()
render_details accounts "Account Details" &
dt_pids+=("$!")
render_details subscriptions "Subscription Details" &
dt_pids+=("$!")
render_details logins "Login Details" &
dt_pids+=("$!")
render_details hosts "Remote Host Details" &
dt_pids+=("$!")
render_details logicals "Logical Details" &
dt_pids+=("$!")
render_details partners "Partner Details" &
dt_pids+=("$!")
render_details applications "Application Details" &
dt_pids+=("$!")
render_details domains "Domain Details" &
dt_pids+=("$!")
render_details bl "BL Details" &
dt_pids+=("$!")
render_details incoming_connections "Incoming Connection Details" &   # the sighted whitelisted IPs
dt_pids+=("$!")
for _p in "${dt_pids[@]}"; do wait "$_p"; done
unset dt_pids _p
RESMAP_FILES=""

# Redirect stubs were REMOVED 2026-07 (no backwards compatibility): the old
# details/transfer-sites/ tree and the IP->hostname stubs are gone — old URLs 404.
rm -rf "$DOCS/details/transfer-sites"

echo "Rendered docs/details/ (per-entity pages)." >&2

publish_stamp "$STAMP"
