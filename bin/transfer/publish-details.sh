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
       "$DATA/transfer/reports/details" "$DATA/transfer/reports/latest" "$DATA/flow-manager" \
       "$DATA/transfer/reports/failed-sub-all.rpt" "$DATA/transfer/reports/errors" \
       ${UCRPT[@]+"${UCRPT[@]}"} && [ -d "$DOCS/latest" ]; then
    echo "docs/details/ is up to date; skipping." >&2
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
# (THE LAST-ERROR SPLICE, 2026-08..2026-09-16: a red subscription's error page
# used to be folded into its detail page here — legs table + server log, above
# "Last server log messages". REMOVED on user request: the page now carries a
# Features "Latest Error" row linking that file's own page, so the evidence
# lives in ONE place. failed-sub-all.rpt stays a freshness dep: the row a
# subscription is red for still decides what its detail page says elsewhere.)

render_details() {   # $1 subdir (accounts|subscriptions)  $2 index title
    local sub=$1 title=$2
    local src="$DATA/transfer/reports/details/$sub" outdir="$DOCS/details/$sub"
    [ -d "$src" ] || return 0
    mkdir -p "$outdir"
    rm -f "$outdir"/*.html
    local hslug="details-$sub"
    # Detail pages sit in docs/<env>/details/<sub>/, so acct/site links resolve
    # from one level up ("../accounts/…", "../subscriptions/…").
    # (The per-subdir index.html listing page was REMOVED 2026-07 — nothing
    # linked it; $2 title only labels the call site now.)
    DLINK_BASE="../"
    # THREE STRIPES PER SUBDIR (2026-09-27): the ten subdirs already render in
    # parallel, but each rendered its pages one after another, so the wall
    # clock was the biggest subdir; every page is written by exactly one
    # stripe. (The TITLE lookup per page went too: it only fed render_rpt
    # its right-label argument, which html_head no longer reads.)
    local _files=("$src"/*.rpt) _stp=() _k
    _rd_stripe() {   # $1 = stripe 0..2: every third page from it
    local i f base vf vtmp srcf _skipv
    for ((i = $1; i < ${#_files[@]}; i += 3)); do
        f=${_files[$i]}
        [ -e "$f" ] || continue
        base=${f##*/}; base=${base%.rpt}
        # Subscriptions open with their UCx status verdict, spliced in right
        # after DESC so it renders under the <h1>, above every table — the same
        # slot the errors-after-last-transfer banner uses.
        vf=""; [ "$sub" = subscriptions ] && [ -n "$VERDICT_DIR" ] && vf="$VERDICT_DIR/$base.txt"
        # srcf walks through the optional preprocessing steps, each reading
        # the previous one's output (the LAST-ERROR SPLICE was removed
        # 2026-09-16, user request: a subscription page no longer shows its
        # latest error or its latest OK transfer at all — the Features table's
        # "Latest Error" / "Latest OK" rows link those files' own pages)
        srcf="$f"
        if [ -n "$vf" ] && [ -s "$vf" ]; then
            vtmp=$(mktemp "${TMPDIR:-/tmp}/axdet.XXXXXX")
            # A page whose writer raised the after-last-transfer banner WITH
            # its error line (the server-failing flows: the bare ALERT text,
            # details_writer.awk err_after_transfer_banner) shows NO verdict
            # prose above it (2026-09-12, user request): the "used to work and
            # now fails" headline and its paragraph only paraphrased that
            # line. The fragment's TABLE block (UC2 pickup) still lands after
            # Features.
            _skipv=0
            grep -q $'^ALERT\tERROR IN SERVER LOG AFTER LAST TRANSFER$' "$srcf" && _skipv=1
            # The verdict REPLACES the one-liner the writer emits for the same
            # condition — "Configured — never seen …" — which it now says
            # with the numbers and the report's own word for it. Dropping them
            # HERE rather than in details.sh keeps them as the fallback: a page
            # that gets no verdict (an environment with no server reports, so no
            # uc<n>-status.rpt) still carries its original line.
            # The fragment splits in two (2026-09-05, user request): its PROSE
            # (the verdict INTRO lines, everything before its first TABLE)
            # lands after DESC as before; its TABLE block — the UC2 "Pickup
            # information" table, sxs=feat — lands right after the Features
            # table, which gets the same sxs=feat, so the two render side by
            # side (Features left, Pickup right) above whatever follows.
            awk -F'\t' -v VF="$vf" -v SKIPPROSE="$_skipv" '
                BEGIN { intbl = 0
                        while ((getline l < VF) > 0) {
                            if (index(l, "TABLE\t") == 1) intbl = 1
                            if (intbl) tblk = tblk l "\n"; else pros = pros l "\n" }
                        close(VF) }
                $1 == "INTRO" && index($2, "Configured") == 1 { next }
                infeat && ($1 == "TABLE" || $1 == "NOTE" || $1 == "INTRO" || $1 == "LINK" || $1 == "SUMMARY" || $1 == "FOOT") { printf "%s", tblk; infeat = 0 }
                # the Features table may ALREADY sit in a flex row — the writer
                # pairs it with "Activity per day" (sxs=af, 2026-09-16) — so the
                # Pickup table JOINS that row instead of starting a second one:
                # Activity per day | Features | Pickup information
                $1 == "TABLE" && $2 == "Features" && tblk != "" {
                    sxid = "feat"
                    for (fi = 3; fi <= NF; fi++) if (index($fi, "sxs=") == 1) sxid = substr($fi, 5)
                    if (sxid == "feat") print $0 "\tsxs=feat"; else { print $0; gsub(/\tsxs=feat/, "\tsxs=" sxid, tblk) }
                    infeat = 1; next }
                { print }
                $1 == "DESC" && !d { if (!SKIPPROSE) printf "%s", pros; d = 1 }
                END { if (infeat) printf "%s", tblk }' "$srcf" > "$vtmp"
            render_rpt "$vtmp" "$outdir/$base.html" "../../assets/style.css" "index.html" "TRANSFER" "" "$hslug"
            rm -f "$vtmp"
        else
            render_rpt "$srcf" "$outdir/$base.html" "../../assets/style.css" "index.html" "TRANSFER" "" "$hslug"
        fi
    done
    }
    for _k in 0 1 2; do _rd_stripe "$_k" & _stp+=("$!"); done
    for _k in "${_stp[@]}"; do wait "$_k"; done
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

# ---- the subscription "Latest files" pages (2026-09-16, user request) -------
# docs/latest/<slug>.html, one per subscription that carries Files: the table
# the subscription detail pages used to hold (details_writer.awk diverts
# section 9 into data/transfer/reports/latest/). UNLIKE a detail page these DO
# get the search box and the From/To selectors — which is the point of the
# move — so they render with the transfer date list, not the empty CUR_DATES
# the detail pages use. Cleared wholesale: a subscription that lost its Files
# (or its name) must not keep a page.
#
# THE ROWS SHIP AS DATA (2026-09-27, user request): each page's rendered rows
# move into the sibling docs/latest/<slug>.js (split_table_rows), which the
# page loads before report.js; report.js latestRows() puts them back into the
# table (data-latest="<slug>") before any table setup runs. The payload
# REGISTERS itself — (window.AXWAY_LATEST ||= []).push({s, n, h, r}) = slug,
# subscription name, the HEAD labels (tab-separated; Pickup and Recovered come
# and go per subscription) and the rows — so docs/latest/search.html can load
# every one of them at once (assets/latest-search.js searches them).
render_latest_page() {   # $1 rpt  $2 slug
    local f=$1 b=$2 pro
    # report key per subscription: a remembered search or sort belongs to
    # THAT flow's list, not to every other subscription's page
    render_rpt "$f" "$DOCS/latest/$b.html" "../assets/style.css" "../index.html" "TRANSFER - Latest files" "" "latest" "latest-$b"
    pro=$(awk -F'\t' -v s="$b" '
        function js(x) { gsub(/\\/, "\\\\", x); gsub(/"/, "\\\"", x); return x }
        $1 == "TITLE" && n == "" { n = $2; sub(/^Latest files: /, "", n) }
        $1 == "HEAD" && h == "" { h = js($2); for (i = 3; i <= NF; i++) h = h "\\t" js($i) }
        END { printf "(window.AXWAY_LATEST=window.AXWAY_LATEST||[]).push({s:\"%s\",n:\"%s\",h:\"%s\",r:`", s, js(n), h }' "$f")
    split_table_rows "$DOCS/latest/$b.html" "$DOCS/latest/$b.js" "$pro" '`});' "data-latest=\"$b\""
}
shopt -s nullglob
latp=("$DATA"/transfer/reports/latest/*.rpt)
shopt -u nullglob
mkdir -p "$DOCS/latest"
rm -f "$DOCS"/latest/*.html "$DOCS"/latest/*.js
if [ ${#latp[@]} -gt 0 ]; then
    CUR_DATES=$TRANSFER_DATES; DLINK_BASE="../details/"
    for f in "${latp[@]}"; do
        b=${f##*/}; b=${b%.rpt}
        # search.html is the search page's own name
        if [ "$b" = search ]; then echo "WARNING: subscription slug 'search' collides with docs/latest/search.html — its Latest files page is skipped." >&2; continue; fi
        pub_run render_latest_page "$f" "$b"
    done
    pub_wait
    CUR_DATES=""; DLINK_BASE="../details/"
    echo "Rendered docs/latest/ (${#latp[@]} subscription page(s) + their row payloads)." >&2
fi

# ---- docs/latest/search.html — the Latest files search (2026-09-27) ---------
# ONE page over every subscription's payload: an empty table the dedicated
# docs/assets/latest-search.js fills with the matches of its two fields
# (Subscription, and File name or CoreId), as the user types. Written even
# with no payloads (the finder and the sitemap link it unconditionally). The
# payload tags + the engine go in before report.js (defer order), each with
# its own cksum ?v= — the File search pages' pattern (bin/analyses/publish.sh).
_ls_rpt="$DOCS/latest/.search.rpt.$$"
printf 'TITLE\tLatest files search\nDESC\tFind a File across the latest files of every subscription — by subscription name and by file name or CoreId, the results following each keystroke.\nKEYWORDS\tlatest,file,files,search,find,subscription,filename,file name,coreid\nTABLE\t\twide\trestint\tnosort\tnosearch\tnofilter\trangehook\nHEAD\tSubscription\tStart\tEnd\tState\tDirection\tSize\tDuration\tFile\tCoreId\nKIND\ttext\ttext\ttext\ttext\ttext\tnum\tnum\tmono\tmono\n' > "$_ls_rpt"
# the transfer date list (2026-09-27, user request): the page gets the shared
# From/To selectors — the table is a `rangehook` table, so report.js counts
# it date-aware and hands the range to latest-search.js
CUR_DATES=$TRANSFER_DATES
RPT_NOPROSE=1 render_rpt "$_ls_rpt" "$DOCS/latest/search.html" "../assets/style.css" "../index.html" "TRANSFER - Latest files search" 1 "latest-search" "latest-search"
CUR_DATES=""
rm -f "$_ls_rpt"
shopt -s nullglob
_ls_js=("$DOCS"/latest/*.js)
shopt -u nullglob
_ls_tags=""
if [ ${#_ls_js[@]} -gt 0 ]; then
    # one cksum for the whole set: "crc size path" per payload
    _ls_tags=$(cksum "${_ls_js[@]}" | awk '{ p = $3; sub(/.*\//, "", p); printf "<script src=\"%s?v=%s\" defer></script>\n", p, $1 }')
fi
_ls_jsv=$(cksum < "$DOCS/assets/latest-search.js" 2>/dev/null | awk '{print $1}')
_ls_tags="$_ls_tags"$'\n'"<script src=\"../assets/latest-search.js?v=$_ls_jsv\" defer></script>"
_ls_tags=${_ls_tags#$'\n'}
printf '%s\n' "$_ls_tags" > "$DOCS/latest/.search-tags.$$"
awk -v tags="$DOCS/latest/.search-tags.$$" '/<script src=[^>]*report\.js/ && !done { while ((getline l < tags) > 0) print l; done = 1 } { print }' \
    "$DOCS/latest/search.html" > "$DOCS/latest/search.html.tmp.$$" \
    && mv "$DOCS/latest/search.html.tmp.$$" "$DOCS/latest/search.html"
rm -f "$DOCS/latest/.search-tags.$$"
# the FIRST tab row: Implementation 1 (search/file-search-*.html) | 2 (this page)
_inject_after_h1 "$DOCS/latest/search.html" "$(file_search_impl_row 2)"
unset _ls_rpt _ls_js _ls_tags _ls_jsv
echo "Wrote docs/latest/search.html (the Latest files search)." >&2

# Redirect stubs were REMOVED 2026-07 (no backwards compatibility): the old
# details/transfer-sites/ tree and the IP->hostname stubs are gone — old URLs 404.
rm -rf "$DOCS/details/transfer-sites"

echo "Rendered docs/details/ (per-entity pages)." >&2

publish_stamp "$STAMP"
