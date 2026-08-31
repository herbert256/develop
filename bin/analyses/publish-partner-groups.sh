#!/usr/bin/env bash
#
# bin/analyses/publish-partner-groups.sh — one page per multi-token partner
# GROUP, explaining WHY those partner codes were merged into one organisation.
#
#   docs/<env>/details/partner-groups/<slug>.html
#
# A "group" partner (a name like GBA_TT_XXLLNC) is several partner tokens —
# the LAST parts of logical flow names — that bin/flow-manager.sh's PDA
# union-find combined (shared host / shared whitelist IP / whitelisted host
# IP / curated alias). That step records the merge EVIDENCE it used into
# these caches (per env):
#   data/<env>/flow-manager/xref/_partner-groups.tsv         group / members / direction
#   data/<env>/flow-manager/xref/_partner-group-why.tsv      group / A / B / rule / evidence line
#   data/<env>/flow-manager/xref/_partner-group-accounts.tsv group / token / account (the
#                                                            accounts behind each code's logical flows)
# This script renders one page per group from them; the slug is the partner's
# own detail-page slug (data/<env>/transfer/reports/details/partners/_slugmap.tsv)
# so the group icon on the Entities Partner pages (render_rpt.awk's grpicons)
# and this page agree. The entity Partner list links each group row to its page.
#
# Runs in the PUBLISH phase (after bin/transfer/publish-details.sh, which only
# clears its OWN details subdirs). No arguments; runs from any directory.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; html_head/esc/slugify/…

XREF="$DATA/flow-manager/xref"
GRPF="$XREF/_partner-groups.tsv"
WHYF="$XREF/_partner-group-why.tsv"
GAF="$XREF/_partner-group-accounts.tsv"       # group / token / account (which name -> the code)
PSLUG="$DATA/transfer/reports/details/partners/_slugmap.tsv"
OUTDIR="$DOCS/details/partner-groups"

STAMP="$PUBLISH_STAMP_DIR/partner-groups.stamp"
# An env with no groups renders no dir at all, so there is no output tree to
# check for — the stamp dir itself stands in as the "did this ever run" marker.
PG_OUT="$OUTDIR"; [ -s "$GRPF" ] || PG_OUT="$PUBLISH_STAMP_DIR"
if publish_is_fresh "$STAMP" "$PG_OUT" "${BASH_SOURCE[0]}" \
       "$GRPF" "$WHYF" "$GAF" "$PSLUG"; then
    echo "docs/$SITE_ENV/details/partner-groups/ is up to date; skipping." >&2
    exit 0
fi

# Nothing configured / no groups this env -> remove any stale pages and stop.
if [ ! -s "$GRPF" ]; then
    rm -rf "$OUTDIR"
    echo "publish-partner-groups: no partner groups in $AXWAY_ENV." >&2
    publish_stamp "$STAMP"   # "nothing to render" is a COMPLETED publish — without
                             # this, an env with no groups (production) never stamps
                             # and re-runs this every build
    exit 0
fi

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.html

n=0
while IFS=$'\t' read -r gname members direction; do
    [ -z "$gname" ] && continue
    # slug = the partner's own detail-page slug (fall back to a plain slugify)
    slug=$(awk -F'\t' -v n="$gname" 'toupper($1)==toupper(n){print $2; exit}' "$PSLUG" 2>/dev/null || true)
    [ -z "$slug" ] && slug=$(slugify "$gname")
    out="$OUTDIR/$slug.html"

    nmembers=$(printf '%s' "$members" | awk -F',' '{print NF}')
    nfacts=$(awk -F'\t' -v g="$gname" '$1==g' "$WHYF" | wc -l | tr -d ' ')
    esc "$gname";     gesc=$ESC
    esc "$direction"; diresc=$ESC

    {
        html_head "Partner group $gname" "../../assets/style.css" "" "" "partner-groups"
        printf '<h1>Partner group <span class="mono">%s</span></h1>\n' "$gesc"
        printf '<p class="subtitle">FlowManager configures these as separate logical flows, but the grouping logic ties them to ONE partner organisation. This page shows the evidence it used. See the <a href="../../../help/partner-groups.html">help page</a> for how partner groups are formed.</p>\n'

        # KPI stat row
        printf '<div>'
        printf '<div class="stat"><span class="stat-v">%s</span><span class="stat-l">Member partners</span></div>' "$nmembers"
        printf '<div class="stat"><span class="stat-v">%s</span><span class="stat-l">Connection</span></div>' "$diresc"
        printf '<div class="stat"><span class="stat-v">%s</span><span class="stat-l">Merge facts</span></div>' "$nfacts"
        printf '</div>\n'

        # Members — each partner code beside the account(s) behind its logical
        # flows, so the derivation is clear.
        printf '<h2>Member partner codes</h2>\n'
        printf '<p class="subtitle">Each partner code is the last part of the logical flow name(s) it derives from; the accounts listed are the accounts behind those flows.</p>\n'
        printf '<div class="tablewrap"><table class="fit">\n<tr><th>Partner code</th><th>Accounts behind the code</th></tr>\n'
        awk -F'\t' -v G="$gname" -v MEMBERS="$members" '
            function e(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); return s }
            $1==G { n[$2]++; if(n[$2]<=8) lst[$2]=lst[$2] (lst[$2]==""?"":", ") e($3) }
            END {
                m=split(MEMBERS, T, ",")
                for(i=1;i<=m;i++){ t=T[i]; a=lst[t]
                    if(n[t]>8) a=a " <span class=\"mask\">(+" (n[t]-8) " more)</span>"
                    if(a=="") a="&ndash;"
                    printf "<tr><td class=\"mono\">%s</td><td class=\"mono\">%s</td></tr>\n", e(t), a } }
        ' "$GAF"
        printf '</table></div>\n'

        # Why combined — aggregated per token pair + rule
        printf '<h2>Why these partners are one group</h2>\n'
        printf '<div class="tablewrap"><table class="fit">\n'
        printf '<tr><th>Partners</th><th>How they are linked</th><th>Evidence</th></tr>\n'
        awk -F'\t' -v G="$gname" '
            function e(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); gsub(/"/,"\\&quot;",s); return s }
            function rlabel(r){
                if(r==1) return "Their logical flows connect to the same configured host"
                if(r==2) return "Their logical flows whitelist the same IP"
                if(r==3) return "One partner\x27s host resolves to an IP the other whitelists"
                if(r==4) return "Curated alias (input/<env>/partner-aliases.tsv)"
                return "Rule " r }
            $1==G {
                key=$2 SUBSEP $3 SUBSEP $4
                if(!(key in cnt)){ ord[++n]=key; A[key]=$2; B[key]=$3; R[key]=$4; first[key]=$5 }
                cnt[key]++ }
            END{
                if(n==0){ print "<tr><td colspan=\"3\">No recorded merge evidence.</td></tr>"; exit }
                for(i=1;i<=n;i++){ k=ord[i]
                    ev=e(first[k]); if(cnt[k]>1) ev=ev " <span class=\"mask\">(+" (cnt[k]-1) " more)</span>"
                    printf "<tr><td class=\"mono\">%s &harr; %s</td><td>%s</td><td>%s</td></tr>\n", e(A[k]), e(B[k]), e(rlabel(R[k])), ev } }
        ' "$WHYF"
        printf '</table></div>\n'

        printf '<p class="range">Partner grouping derives from the logical flow names (the last part is the partner code), merged by shared endpoints, shared whitelist IPs, whitelisted host addresses and curated aliases (see <a href="../../../help/partner-groups.html">help</a>). Back to the <a href="../partners/%s.html">%s partner page</a> or the <a href="../../transfer/entities/partner-seen.html">Partners list</a>.</p>\n' "$slug" "$gesc"
        printf '</body>\n</html>\n'
    } > "$out"
    n=$((n + 1))
done < "$GRPF"

echo "Rendered docs/details/partner-groups/ ($n group page(s))." >&2

publish_stamp "$STAMP"
