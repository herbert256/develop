# charts_lib.sh — self-contained SVG/HTML chart generators for the dashboards.
#
# Sourced by bin/dashboards/publish.sh (which sources bin/publish_lib.sh first, for esc()).
# Every function prints to stdout. NO external libraries and NO inline style= /
# <style> — chart colours are SVG *presentation attributes* (fill/stroke), and all
# layout/typography lives in assets/style.css. Charts scale via viewBox.
#
# Data is passed as a single string of "label:value" items separated by "|"
# (labels must not contain "|" or ":"; callers sanitise). Numbers only for values.
#
# ACCESSIBILITY: every SVG is a named image, not a mute drawing. render_card
# exports CH_ID (unique per chart on its page) and CH_TITLE (the card title);
# each generator emits role="img" aria-labelledby pointing at a root <title>
# (the chart's name) and <desc> (an auto-written textual summary: totals,
# peaks, latest values). The per-bar/point <title> tooltips stay, but they are
# mouse candy — the root pair is what names the chart in the accessibility
# tree. After </svg> each generator also emits a collapsed
# <details class="chart-data"> holding the SAME numbers as a real table, so
# the data is reachable without a pointer (styled in assets/style.css).

# ---- palette (kept in sync with the .kpi-* accents in style.css) ------------
CH_BLUE="#3b82c4"; CH_GREEN="#3f9d52"; CH_RED="#df5a4c"; CH_AMBER="#e8a13a"
CH_PURPLE="#7d63c6"; CH_TEAL="#2ba397"; CH_INK="#33475b"; CH_MUTE="#8a97a4"
CH_GRID="#e9edf2"; CH_TRACK="#eef1f5"

# humannum — 1234567 -> 1.2M etc, COUNTS ONLY (byte values use hbytes2()). hn takes an
# optional unit suffix (e.g. " GB") and keeps one decimal for non-integer values
# < 100, so a gridline over fractional data reads "3.7 GB", not "3".
# hb — human bytes, 1024-based with %.2f like the report tables' humanbytes.
# svgo/svdesc — the accessible svg opener: role="img" + aria-labelledby wired
# to the root <title> (cid/ctitle come in via -v from the CH_ID/CH_TITLE the
# publish render_card exports; see the header comment).
# dto/dth/dtd/dtc — the chart-data <details> table: open, header cell, data
# cell (num = right-aligned), close.
source "$(dirname "${BASH_SOURCE[0]}")/../awklib.sh"   # $AWKLIB (hbytes2 …) — CH_AWK_HELPERS starts with it
CH_AWK_HELPERS="$AWKLIB"'
    function hn(t, u){ t=t+0; if(t>=1e9)return sprintf("%.1fB%s",t/1e9,u); if(t>=1e6)return sprintf("%.1fM%s",t/1e6,u); if(t>=1e3)return sprintf("%.1fk%s",t/1e3,u); if(t!=int(t)&&t<100)return sprintf("%.1f%s",t,u); return sprintf("%d%s",t,u) }
    function xesc(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); return s }
    function svgo(vb, cls, par){
        printf "<svg viewBox=\"%s\" class=\"svg %s\" preserveAspectRatio=\"%s\" role=\"img\" aria-labelledby=\"%s-t %s-d\">", vb, cls, par, cid, cid
        printf "<title id=\"%s-t\">%s</title>", cid, xesc(ctitle) }
    function svdesc(d){ printf "<desc id=\"%s-d\">%s</desc>", cid, xesc(d) }
    function dto(){ printf "</svg><details class=\"chart-data\"><summary>Data table</summary><div class=\"cd-wrap\"><table>" }
    function dth(s){ printf "<th>%s</th>", xesc(s) }
    function dthn(s){ printf "<th class=\"num\">%s</th>", xesc(s) }
    function dtd(s){ printf "<td>%s</td>", xesc(s) }
    function dtdn(s){ printf "<td class=\"num\">%s</td>", xesc(s) }
    function dtc(){ printf "</table></div></details>" }
'

# kpi_card VALUE LABEL SUB ACCENT [HREF]  — a big-number card (HTML, styled by
# style.css). When HREF is given the label links to that report (plain <a>).
kpi_card() {   # $1 value  $2 label  $3 sub (may be empty)  $4 accent (blue|green|red|amber|purple|teal)  $5 href (optional)
    esc "$2"; local lbl=$ESC
    esc "${3:-}"; local sub=$ESC
    if [ -n "${5:-}" ]; then esc "$5"; lbl="<a href=\"$ESC\">$lbl</a>"; fi
    printf '<div class="kpi kpi-%s"><div class="kpi-val">%s</div><div class="kpi-lbl">%s</div>' "${4:-blue}" "$1" "$lbl"
    [ -n "${3:-}" ] && printf '<div class="kpi-sub">%s</div>' "$sub"
    printf '</div>'
}

# card TITLE SUBTITLE [HREF] [CLASS]  — open a chart card; body (the svg) follows,
# then card_end. HREF wraps the title in a plain <a> to the source report; CLASS
# adds an extra card class (e.g. span2 for a full-width card).
card_open() {   # $1 title  $2 subtitle (optional)  $3 href (optional)  $4 extra class (optional)
    esc "$1"; local t=$ESC
    if [ -n "${3:-}" ]; then esc "$3"; t="<a href=\"$ESC\">$t</a>"; fi
    printf '<section class="card%s"><header class="card-h"><h3>%s</h3>' "${4:+ $4}" "$t"
    [ -n "${2:-}" ] && { esc "$2"; printf '<span class="card-sub">%s</span>' "$ESC"; }
    printf '</header><div class="chartbox">'
}
card_end() { printf '</div></section>'; }

# svg_vbar DATA COLOR  — vertical bars, DATA = "label:value|…", with the same
# 4-step labelled gridline band the area chart has.
svg_vbar() {   # $1 data  $2 color  $3 unit (optional y/hover suffix, e.g. " s" / "%"; the word "bytes" = humanize as byte sizes)
    awk -v data="$1" -v col="${2:-$CH_BLUE}" -v unit="${3:-}" -v track="$CH_TRACK" -v grid="$CH_GRID" -v ink="$CH_INK" -v mute="$CH_MUTE" \
        -v cid="${CH_ID:-ch}" -v ctitle="${CH_TITLE:-Chart}" "$CH_AWK_HELPERS"'
    function fv(x){ return unit=="bytes" ? hbytes2(x) : hn(x, unit) }
    BEGIN{
        n=split(data,seg,"|"); mx=1; tot=0; hi=1
        for(i=1;i<=n;i++){ split(seg[i],p,":"); lab[i]=p[1]; v[i]=p[2]+0; tot+=v[i]; if(v[i]>mx)mx=v[i]; if(v[i]>v[hi])hi=i }
        # unit y-labels are wider than plain counts ("612.99 MB" vs "286") — give them margin
        W=760; H=210; L=(unit=="bytes"?88:(unit!=""?58:46)); R=L; top=14; base=H-30; gw=(W-L-R)/n; bw=gw*0.6
        svgo("0 0 " W " " H,"svg-vbar","none")
        svdesc(sprintf("%d bars from %s to %s, total %s. Peak: %s (%s).",n,lab[1],lab[n],fv(tot),lab[hi],fv(v[hi])))
        for(g=0;g<=4;g++){ yy=top+(base-top)*g/4; val=mx*(4-g)/4
            printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"%s\"/>",L,yy,W-R,yy,grid
            printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" class=\"c-axis\" fill=\"%s\">%s</text>",L-6,yy+4,mute,fv(val)
            printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"start\" class=\"c-axis\" fill=\"%s\">%s</text>",W-R+6,yy+4,mute,fv(val) }
        printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"%s\"/>",L,base,W-R,base,track
        for(i=1;i<=n;i++){ x=L+(i-0.5)*gw; h=v[i]/mx*(base-top); if(h<1&&v[i]>0)h=1
            printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" rx=\"3\" fill=\"%s\"><title>%s: %s</title></rect>",x-bw/2,base-h,bw,h,col,xesc(lab[i]),fv(v[i])
            printf "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" class=\"c-axis\" fill=\"%s\">%s</text>",x,base+15,mute,xesc(lab[i]) }
        dto(); printf "<tr>"; dth("Label"); dthn("Value"); printf "</tr>"
        for(i=1;i<=n;i++){ printf "<tr>"; dtd(lab[i]); dtdn(fv(v[i])); printf "</tr>" }
        dtc()
    }'
}

# ---- the ONE card renderer (2026-09-30, lean round 3 B-11: the dashboards and
# the day pages carried ~95 % identical copies) --------------------------------
# The two page kinds differ in two knobs, set by the caller before the calls:
#   RC_BASEIV  the visible default slot resolution in minutes (360 = 6 h on
#              the overview, 30 on a day page; also data-base, the key the
#              interval pick is remembered under)
#   RC_MORE    1 = a non-slots card with a href gets the bottom-right "full
#              report" link (the overview); 0 = never (the day pages)

# swap CH_* palette tokens in a chart arg for their hex values -> RCH
resolve_ch() {
    local s=$1
    s=${s//CH_BLUE/$CH_BLUE}; s=${s//CH_GREEN/$CH_GREEN}; s=${s//CH_RED/$CH_RED}
    s=${s//CH_AMBER/$CH_AMBER}; s=${s//CH_PURPLE/$CH_PURPLE}; s=${s//CH_TEAL/$CH_TEAL}
    RCH=$s   # a variable, not stdout: see render_card (EINTR)
}

# one CARD line -> card html; dispatches the chart type to its generator with
# the trailing-empty args dropped (an EMBEDDED empty arg is passed through;
# only slots and vbar remain since 2026-09-29). $1 is the chart's page-unique
# id: exported with the card title as CH_ID/CH_TITLE so the generator (a $()
# grandchild) can emit the accessible root <title>/<desc> + aria-labelledby
# and the chart-data table.
# render_card -> RC_OUT (2026-09-29): the card HTML goes back in a VARIABLE,
# never through stdout — a caller's $(render_card …) pipe fills with a big
# card, and a SIGCHLD landing on the blocked write made bash 3.2's printf fail
# with "write error: Interrupted system call" (the intermittent build
# failure); resolve_ch -> RCH for the same reason (a series can be large)
render_card() {   # $1 chart id  $2 title  $3 sub  $4 href  $5 span  $6 chart  $7..$14 args
    local cid=$1; shift
    local title=$1 sub=$2 href=$3 span=$4 chart=$5; shift 5
    export CH_ID="$cid" CH_TITLE="$title"
    local args=() a n
    for a in "$@"; do resolve_ch "$a"; args+=("$RCH"); done
    n=${#args[@]}
    while [ "$n" -gt 0 ] && [ -z "${args[n-1]}" ]; do unset "args[$((n-1))]"; n=$((n-1)); done
    local svg=""
    case $chart in
        vbar)  svg=$(svg_vbar  ${args[@]+"${args[@]}"}) ;;
        slots)
            local BASEIV=${RC_BASEIV:-360}   # the visible default resolution, in minutes
            # CLIENT-SIDE since 2026-07: the card is one placeholder carrying
            # the series, and docs/assets/slotchart.js draws the SVG + data
            # table for the picked style/interval.
            # args: a1 KIND, a2 the BASE series, a3 the {} link pattern, then
            # any number of "<minutes>:<series>" EXTRA resolutions (a4..a8).
            # Each becomes data-iv<minutes>; the base takes data-base and its
            # own data-iv<minutes>. The interval row is built from the tags
            # present, ascending — so the overview offers 1h/2h/4h/6h/12h/1 day
            # and a day page 15/30 min/1 hour, from the same code.
            local slink=${args[2]:-}; [ -n "$slink" ] || slink=$href
            esc "$title"; local ctit=$ESC
            esc "$slink"; local clink=$ESC
            local ivlist="$BASEIV" a2 tag ser
            svg="<div class=\"slotchart\" data-kind=\"${args[0]}\" data-cid=\"$cid\" data-title=\"$ctit\" data-link=\"$clink\" data-base=\"$BASEIV\""
            esc "${args[1]:-}"; svg+=" data-iv$BASEIV=\"$ESC\""
            for a2 in "${args[@]:3}"; do
                [ -n "$a2" ] || continue
                tag=${a2%%:*}; ser=${a2#*:}
                [ -n "$ser" ] || continue
                ivlist="$ivlist $tag"
                esc "$ser"; svg+=" data-iv$tag=\"$ESC\""
            done
            svg+="></div>"
            svg+='<div class="chartbtns">'
            if [ "$(printf '%s\n' $ivlist | wc -l)" -gt 1 ]; then
                svg+='<p class="tabs ivbtns">'
                for tag in $(printf '%s\n' $ivlist | sort -n); do
                    case $tag in
                        15) lbl="15 min" ;; 30) lbl="30 min" ;; 60) lbl="1 hour" ;;
                        120) lbl="2 hours" ;; 240) lbl="4 hours" ;; 360) lbl="6 hours" ;; 720) lbl="12 hours" ;;
                        1440) lbl="1 day" ;; *) lbl="$tag min" ;;
                    esac
                    if [ "$tag" = "$BASEIV" ]; then svg+="<span class=\"tab active\" data-civ=\"$tag\">$lbl</span>"
                    else svg+="<span class=\"tab\" data-civ=\"$tag\">$lbl</span>"; fi
                done
                svg+='</p>'
            fi
            # Linear/Log (2026-08): a few series swing over three orders of
            # magnitude and flatten every ordinary slot against the floor on a
            # linear axis. NOT offered on the duration kinds — their ms..h axis
            # is already non-linear, so the toggle would be a dead button.
            case ${args[0]} in
                dur) ;;
                seen) svg+='<p class="tabs scalebtns"><span class="tab active" data-cscale="lin">Linear</span><span class="tab" data-cscale="log">Log</span></p>' ;;   # the seen graphs open LINEAR (2026-09-03, user request; slotchart.js scaleFor)
                *) svg+='<p class="tabs scalebtns"><span class="tab" data-cscale="lin">Linear</span><span class="tab active" data-cscale="log">Log</span></p>' ;;
            esac
            svg+='<p class="tabs stylebtns"><span class="tab" data-cstyle="line">Line</span><span class="tab" data-cstyle="bar">Bar</span><span class="tab active" data-cstyle="solid">Solid</span></p>'
            svg+='</div>'
            ;;
    esac
    # slots cards ALWAYS raise the chartbox above the whole-card stretched
    # title link (style.css .ptlinks): it would otherwise eat the tooltip
    # mousemoves and the style buttons
    local cardcls=$span
    if [ "$chart" = "slots" ]; then cardcls="${cardcls:+$cardcls }ptlinks"; fi
    # the bottom-right "full report" link inside the chart (style.css
    # .card-more, RC_MORE=1 only): the card href surfaced visibly. NOT on
    # slots cards: the linked title covers the report link and the corner
    # belongs to the Line/Bar/Solid switcher.
    local more=""
    if [ "${RC_MORE:-0}" = 1 ] && [ "$chart" != "slots" ] && [ -n "$href" ]; then esc "$href"; more="<a class=\"card-more\" href=\"$ESC\">full report &#8594;</a>"; fi
    if [ -n "$cardcls" ]; then
        RC_OUT="$(card_open "$title" "$sub" "$href" "$cardcls")$svg$more$(card_end)"
    else
        RC_OUT="$(card_open "$title" "$sub" "$href")$svg$more$(card_end)"
    fi
}

# ---- compact slot series (2026-09-30, lean round 3 C-08) ----------------------
# Every slot series is a CONTIGUOUS walk (overview.sh / day reports.sh build:
# for t = tmin .. tmax), so each slot's label and date follow from the
# series start and the interval. rc_cards ships a series as
#   =S<YYYY-MM-DD>T<HHMM>~<fmt>|<values>|<values>|…
# (fmt o = "MM-DD HHh", d = "MM-DD", m = "HHhMM"; <values> = the slot's middle
# fields verbatim, "v1[:v2…]" or the empty no-data form) and slotchart.js
# expandSeries() rebuilds "label:values:date|…" before its parse(). The encoder
# RECOMPUTES every slot's label and date and ships the ORIGINAL string whenever
# one differs (a gap, another label shape) — never a lossy form.
# rc_cards PREFIX RPT — the PREFIX (CARD / CARDALT) lines of RPT, TABs as \037,
# every slots series encoded; the interval of the base series is RC_BASEIV.
CH_SERENC_AWK="$AWKLIB"'
    function enc(S, iv,   n, seg, i, lab, dt, mid, y, mo, dd, hh, mm, M, Mi, d2, h2, m2, want, fmt, out) {
        if (S == "" || iv <= 0) return S
        n = split(S, seg, "|")
        for (i = 1; i <= n; i++) {
            if (!match(seg[i], /^[^:]*:/)) return S
            lab = substr(seg[i], 1, RLENGTH - 1)
            if (!match(seg[i], /:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)) return S
            dt = substr(seg[i], RSTART + 1)
            if (length(seg[i]) < length(lab) + length(dt) + 2) return S
            MID[i] = substr(seg[i], length(lab) + 2, length(seg[i]) - length(lab) - length(dt) - 2)
            if (i == 1) {
                y = substr(dt, 1, 4) + 0; mo = substr(dt, 6, 2) + 0; dd = substr(dt, 9, 2) + 0
                if (lab ~ /^[0-9][0-9]-[0-9][0-9] [0-9][0-9]h$/)  { fmt = "o"; hh = substr(lab, 7, 2) + 0; mm = 0 }
                else if (lab ~ /^[0-9][0-9]-[0-9][0-9]$/)          { fmt = "d"; hh = 0; mm = 0 }
                else if (lab ~ /^[0-9][0-9]h[0-9][0-9]$/)          { fmt = "m"; hh = substr(lab, 1, 2) + 0; mm = substr(lab, 4, 2) + 0 }
                else return S
                M = jdn(y, mo, dd) * 1440 + hh * 60 + mm
            }
            Mi = M + (i - 1) * iv
            d2 = fromjdn(int(Mi / 1440)); h2 = int((Mi % 1440) / 60); m2 = Mi % 60
            if (fmt == "o")      want = (m2 == 0) ? substr(d2, 6) sprintf(" %02dh", h2) : "\001"
            else if (fmt == "d") want = (h2 == 0 && m2 == 0) ? substr(d2, 6) : "\001"
            else                 want = sprintf("%02dh%02d", h2, m2)
            if (want != lab || d2 != dt) return S
        }
        out = sprintf("=S%04d-%02d-%02dT%02d%02d~%s", y, mo, dd, hh, mm, fmt)
        for (i = 1; i <= n; i++) out = out "|" MID[i]
        return out
    }
    BEGIN { FS = OFS = "\t" }
    {
        # CARD: 6 chart, 7 kind, 8 base series, 9 link, 10.. "<min>:<series>";
        # CARDALT carries its button label first, so everything shifts by one
        c = (P == "CARDALT") ? 7 : 6
        if ($c == "slots") {
            $(c + 2) = enc($(c + 2), BASEIV + 0)
            for (f = c + 4; f <= NF; f++) {
                if (!match($f, /^[0-9]+:/)) continue
                tg = substr($f, 1, RLENGTH - 1)
                $f = tg ":" enc(substr($f, RLENGTH + 1), tg + 0)
            }
        }
        gsub(/\t/, "\037"); print
    }'
rc_cards() {   # $1 CARD|CARDALT  $2 rpt
    [ -f "$2" ] || return 0
    grep "^$1"$'\t' "$2" | awk -v P="$1" -v BASEIV="${RC_BASEIV:-360}" "$CH_SERENC_AWK" || true
}
