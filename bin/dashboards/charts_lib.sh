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

# humannum — 1234567 -> 1.2M etc, COUNTS ONLY (byte values use hb()). hn takes an
# optional unit suffix (e.g. " GB") and keeps one decimal for non-integer values
# < 100, so a gridline over fractional data reads "3.7 GB", not "3".
# hb — human bytes, 1024-based with %.2f like the report tables' humanbytes.
# svgo/svdesc — the accessible svg opener: role="img" + aria-labelledby wired
# to the root <title> (cid/ctitle come in via -v from the CH_ID/CH_TITLE the
# publish render_card exports; see the header comment).
# dto/dth/dtd/dtc — the chart-data <details> table: open, header cell, data
# cell (num = right-aligned), close.
CH_AWK_HELPERS='
    function hn(t, u){ t=t+0; if(t>=1e9)return sprintf("%.1fB%s",t/1e9,u); if(t>=1e6)return sprintf("%.1fM%s",t/1e6,u); if(t>=1e3)return sprintf("%.1fk%s",t/1e3,u); if(t!=int(t)&&t<100)return sprintf("%.1f%s",t,u); return sprintf("%d%s",t,u) }
    function hb(b,  hbu,hbi,hbv){ split("B KB MB GB TB PB",hbu," "); hbi=1; hbv=b+0; while(hbv>=1024&&hbi<6){hbv/=1024;hbi++} return (hbi==1)?sprintf("%d %s",hbv,hbu[hbi]):sprintf("%.2f %s",hbv,hbu[hbi]) }
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
    function fv(x){ return unit=="bytes" ? hb(x) : hn(x, unit) }
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

