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
CH_PALETTE="$CH_BLUE|$CH_TEAL|$CH_AMBER|$CH_PURPLE|$CH_GREEN|$CH_RED|#5c9ead|#c58a7b"

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

# svg_donut DATA [COLORS]  — DATA = "label:value|label:value|…"; segments coloured
# from COLORS (a comma list, like svg_stack — e.g. green/red for an outcome donut)
# or, when omitted, from the palette in order. Ring with a centred total and a
# right-hand legend. More than 7 segments would clip the legend, so everything
# beyond the top 6 (data assumed largest-first) is rolled into "(other)".
svg_donut() {   # $1 data  $2 colors (optional comma list)
    awk -v data="$1" -v colors="${2:-}" -v pal="$CH_PALETTE" -v track="$CH_TRACK" -v ink="$CH_INK" -v mute="$CH_MUTE" \
        -v cid="${CH_ID:-ch}" -v ctitle="${CH_TITLE:-Chart}" "$CH_AWK_HELPERS"'
    BEGIN{
        if(colors!="") np=split(colors,pc,","); else np=split(pal,pc,"|")
        n=split(data,seg,"|"); tot=0
        for(i=1;i<=n;i++){ split(seg[i],p,":"); lab[i]=p[1]; v[i]=p[2]+0; tot+=v[i] }
        if(n>7){ oth=0; for(i=7;i<=n;i++)oth+=v[i]; if(oth>0){ n=7; lab[7]="(other)"; v[7]=oth } else n=6 }
        if(tot<=0)tot=1
        cx=95; cy=105; r=68; sw=30; C=2*3.14159265359*r
        svgo("0 0 380 220","svg-donut","xMinYMid meet")
        ds=sprintf("Total %s across %d segments:",hn(tot),n)
        for(i=1;i<=n;i++) ds=ds sprintf(" %s %s (%.0f%%)%s",lab[i],hn(v[i]),v[i]*100/tot,(i<n?";":"."))
        svdesc(ds)
        printf "<circle cx=\"%d\" cy=\"%d\" r=\"%d\" fill=\"none\" stroke=\"%s\" stroke-width=\"%d\"/>",cx,cy,r,track,sw
        off=0
        for(i=1;i<=n;i++){ if(v[i]<=0)continue; len=v[i]/tot*C; col=pc[((i-1)%np)+1]
            printf "<circle cx=\"%d\" cy=\"%d\" r=\"%d\" fill=\"none\" stroke=\"%s\" stroke-width=\"%d\" stroke-linecap=\"butt\" stroke-dasharray=\"%.2f %.2f\" stroke-dashoffset=\"%.2f\" transform=\"rotate(-90 %d %d)\"><title>%s: %s</title></circle>",cx,cy,r,col,sw,len,C-len,-off,cx,cy,xesc(lab[i]),hn(v[i])
            off+=len }
        printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" class=\"c-big\" fill=\"%s\">%s</text>",cx,cy-2,ink,hn(tot)
        printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" class=\"c-cap\" fill=\"%s\">total</text>",cx,cy+16,mute
        ly=42
        for(i=1;i<=n;i++){ col=pc[((i-1)%np)+1]; pct=v[i]*100/tot
            dl=lab[i]; if(length(dl)>16)dl=substr(dl,1,15) "\342\200\246"
            printf "<rect x=\"194\" y=\"%d\" width=\"13\" height=\"13\" rx=\"3\" fill=\"%s\"/>",ly,col
            printf "<text x=\"212\" y=\"%d\" class=\"c-lbl\" fill=\"%s\">%s</text>",ly+11,ink,xesc(dl)
            printf "<text x=\"376\" y=\"%d\" text-anchor=\"end\" class=\"c-val\" fill=\"%s\">%s (%.0f%%)</text>",ly+11,mute,hn(v[i]),pct
            ly+=27 }
        dto(); printf "<tr>"; dth("Segment"); dthn("Value"); dthn("Share"); printf "</tr>"
        for(i=1;i<=n;i++){ printf "<tr>"; dtd(lab[i]); dtdn(hn(v[i])); dtdn(sprintf("%.0f%%",v[i]*100/tot)); printf "</tr>" }
        dtc()
    }'
}

# svg_hbar DATA COLOR [VBWIDTH] [FMT]  — horizontal bars, DATA = "label:value|…"
# (ordered). VBWIDTH is the viewBox width (default 380 for a half-width card; pass
# 760 for a full-width span2 card so text/bars keep the same on-screen scale).
# FMT "bytes" formats values as human bytes (hb, %.2f) instead of the count hn().
svg_hbar() {   # $1 data  $2 color  $3 viewbox-width  $4 fmt ("bytes" = byte values)
    awk -v data="$1" -v col="${2:-$CH_BLUE}" -v Wv="${3:-380}" -v fmt="${4:-}" -v track="$CH_TRACK" -v ink="$CH_INK" -v mute="$CH_MUTE" \
        -v cid="${CH_ID:-ch}" -v ctitle="${CH_TITLE:-Chart}" "$CH_AWK_HELPERS"'
    function fv(x){ return (fmt=="bytes")?hb(x):hn(x) }
    BEGIN{
        n=split(data,seg,"|"); mx=1; tot=0; hi=1; lo=1
        for(i=1;i<=n;i++){ split(seg[i],p,":"); lab[i]=p[1]; v[i]=p[2]+0; tot+=v[i]; if(v[i]>mx)mx=v[i]
            if(v[i]>v[hi])hi=i; if(v[i]<v[lo])lo=i }
        W=Wv+0; H=n*30+12; lw=(W>=560)?255:150; maxc=int(lw/7.2); vw=(W>=560)?60:52; if(fmt=="bytes")vw+=16
        bx=lw+6; bw=W-bx-vw
        svgo("0 0 " W " " H,"svg-hbar","xMinYMin meet")
        svdesc(sprintf("%d bars, total %s. Highest: %s (%s); lowest: %s (%s).",n,fv(tot),lab[hi],fv(v[hi]),lab[lo],fv(v[lo])))
        for(i=1;i<=n;i++){ y=10+(i-1)*30; bl=v[i]/mx*bw; if(bl<2 && v[i]>0)bl=2
            lbl=lab[i]; if(length(lbl)>maxc)lbl=substr(lbl,1,maxc-1) "\342\200\246"
            printf "<text x=\"%d\" y=\"%d\" text-anchor=\"end\" class=\"c-lbl\" fill=\"%s\">%s</text>",lw,y+15,ink,xesc(lbl)
            printf "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"18\" rx=\"4\" fill=\"%s\"/>",bx,y+4,bw,track
            printf "<rect x=\"%d\" y=\"%d\" width=\"%.1f\" height=\"18\" rx=\"4\" fill=\"%s\"><title>%s: %s</title></rect>",bx,y+4,bl,col,xesc(lab[i]),fv(v[i])
            printf "<text x=\"%d\" y=\"%d\" class=\"c-val\" fill=\"%s\">%s</text>",bx+bw+6,y+17,mute,fv(v[i]) }
        dto(); printf "<tr>"; dth("Label"); dthn("Value"); printf "</tr>"
        for(i=1;i<=n;i++){ printf "<tr>"; dtd(lab[i]); dtdn(fv(v[i])); printf "</tr>" }
        dtc()
    }'
}

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

# svg_area DATA COLOR [DATA2 COLOR2] [UNIT]  — a time series (line+area) over
# evenly spaced points. DATA = "label:value|…" (label = the x tick, shown thinned).
# Optional second series (e.g. failures) overlaid as a dashed line. Every point
# carries a hover <circle> with a <title> value (like vbar's bars). UNIT is a
# suffix for the y labels and hover values (e.g. " GB" for a volume series).
svg_area() {   # $1 data  $2 color  $3 data2 (opt)  $4 color2 (opt)  $5 unit suffix (opt)  $6 link pattern (opt: {} = the point label -> a clickable column band per point)
    awk -v data="$1" -v col="${2:-$CH_BLUE}" -v data2="${3:-}" -v col2="${4:-$CH_RED}" -v unit="${5:-}" -v linkpat="${6:-}" -v track="$CH_TRACK" -v grid="$CH_GRID" -v ink="$CH_INK" -v mute="$CH_MUTE" \
        -v cid="${CH_ID:-ch}" -v ctitle="${CH_TITLE:-Chart}" "$CH_AWK_HELPERS"'
    function flr(x,  y){ y=int(x); return (y>x)?y-1:y }
    function cl(x,   y){ y=int(x); return (y<x)?y+1:y }
    # y position: linear, or log10 when the unit carried the "log" prefix —
    # a few outlier days must not flatten the typical values (durations)
    function ypos(val,  lv){ if(!lg) return base-val/mx*ih
        lv=(val>0)?log(val)/log(10):lo; if(lv<lo)lv=lo
        return base-(lv-lo)/(hi-lo)*ih }
    BEGIN{
        n=split(data,seg,"|"); mx=1
        for(i=1;i<=n;i++){ split(seg[i],p,":"); lab[i]=p[1]; v[i]=p[2]+0; if(v[i]>mx)mx=v[i] }
        n2=split(data2,seg2,"|"); for(i=1;i<=n2;i++){ split(seg2[i],p2,":"); lab2[i]=p2[1]; v2[i]=p2[2]+0; if(v2[i]>mx)mx=v2[i] }
        lg=0
        if(unit ~ /^log/){ lg=1; sub(/^log/,"",unit)
            mnp=0
            for(i=1;i<=n;i++)  if(v[i]>0  && (mnp==0||v[i]<mnp))  mnp=v[i]
            for(i=1;i<=n2;i++) if(v2[i]>0 && (mnp==0||v2[i]<mnp)) mnp=v2[i]
            if(mnp==0) mnp=1
            lo=flr(log(mnp)/log(10)); hi=cl(log(mx)/log(10)); if(hi<=lo) hi=lo+1 }
        W=760; H=230; L=46; R=46; T=16; B=34; base=H-B; iw=W-L-R; ih=base-T
        if(n<2)n=n; step=(n>1)?iw/(n-1):0
        svgo("0 0 " W " " H,"svg-area","none")
        mnv=v[1]; mni=1; mxv=v[1]; mxi=1
        for(i=1;i<=n;i++){ if(v[i]<mnv){mnv=v[i];mni=i} if(v[i]>mxv){mxv=v[i];mxi=i} }
        ds=sprintf("%d points from %s to %s. Lowest %s on %s; highest %s on %s; latest %s.",n,lab[1],lab[n],hn(mnv,unit),lab[mni],hn(mxv,unit),lab[mxi],hn(v[n],unit))
        if(n2>1){ m2v=v2[1]; m2i=1; for(i=1;i<=n2;i++) if(v2[i]>m2v){m2v=v2[i];m2i=i}
            ds=ds sprintf(" Second series: highest %s on %s; latest %s.",hn(m2v,unit),lab2[m2i],hn(v2[n2],unit)) }
        svdesc(ds)
        # gridlines + y labels (4 linear steps, or one per DECADE on log scale)
        if(lg){ ng=hi-lo
            for(g=0;g<=ng;g++){ yy=T+ih*g/ng; val=exp((hi-g)*log(10))
                printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"%s\"/>",L,yy,W-R,yy,grid
                printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" class=\"c-axis\" fill=\"%s\">%s</text>",L-6,yy+4,mute,hn(val,unit)
                printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"start\" class=\"c-axis\" fill=\"%s\">%s</text>",W-R+6,yy+4,mute,hn(val,unit) }
        } else {
        for(g=0;g<=4;g++){ yy=T+ih*g/4; val=mx*(4-g)/4
            printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"%s\"/>",L,yy,W-R,yy,grid
            printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" class=\"c-axis\" fill=\"%s\">%s</text>",L-6,yy+4,mute,hn(val,unit)
            printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"start\" class=\"c-axis\" fill=\"%s\">%s</text>",W-R+6,yy+4,mute,hn(val,unit) }
        }
        # area polygon
        poly=""; for(i=1;i<=n;i++){ x=L+(i-1)*step; y=ypos(v[i]); poly=poly sprintf("%.1f,%.1f ",x,y) }
        printf "<polygon points=\"%s%.1f,%.1f %.1f,%.1f\" fill=\"%s\" fill-opacity=\"0.14\"/>",poly,L+(n-1)*step,base,L,base,col
        printf "<polyline points=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"2.5\" stroke-linejoin=\"round\"/>",poly,col
        if(n2>1){ pl=""; for(i=1;i<=n2;i++){ x=L+(i-1)*step; y=ypos(v2[i]); pl=pl sprintf("%.1f,%.1f ",x,y) }
            printf "<polyline points=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"2\" stroke-dasharray=\"6 4\"/>",pl,col2 }
        # hover markers: one <circle> per point with a <title> value
        for(i=1;i<=n;i++){ x=L+(i-1)*step; y=ypos(v[i])
            printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"%s\"><title>%s: %s</title></circle>",x,y,col,xesc(lab[i]),hn(v[i],unit) }
        for(i=1;i<=n2;i++){ x=L+(i-1)*step; y=ypos(v2[i])
            printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"2.5\" fill=\"%s\"><title>%s: %s</title></circle>",x,y,col2,xesc(lab2[i]),hn(v2[i],unit) }
        # clickable column bands (linkpat, {} = the label): one transparent
        # rect per point, on top of everything, linking that day/point
        if(linkpat!=""){
            for(i=1;i<=n;i++){
                href=linkpat; sub(/\{\}/,lab[i],href)
                bx=(n>1)?L+(i-1)*step-step/2:L; if(bx<L)bx=L
                bw=(n>1)?step:iw; if(bx+bw>W-R)bw=W-R-bx
                printf "<a href=\"%s\"><rect x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\" fill=\"transparent\"><title>%s: %s — open this day</title></rect></a>",xesc(href),bx,T,bw,base-T,xesc(lab[i]),hn(v[i],unit)
            }
        }
        # x ticks (~6, thinned)
        every=int(n/6); if(every<1)every=1
        for(i=1;i<=n;i++){ if((i-1)%every==0 || i==n){ x=L+(i-1)*step
            printf "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" class=\"c-axis\" fill=\"%s\">%s</text>",x,base+16,mute,xesc(lab[i]) } }
        dto(); printf "<tr>"; dth("Point"); dthn("Value")
        if(n2>1) dthn("Second series")
        printf "</tr>"
        for(i=1;i<=n;i++){ printf "<tr>"; dtd(lab[i]); dtdn(hn(v[i],unit))
            if(n2>1) dtdn(i<=n2?hn(v2[i],unit):"")
            printf "</tr>" }
        dtc()
    }'
}

# (svg_slots lived here until 2026-07: the slot charts are now drawn in the
# BROWSER by docs/assets/slotchart.js — three styles x three intervals meant
# nine baked SVGs per card and a 1.2 MB overview. The publish emits one
# placeholder carrying the series; every other chart type below is still
# rendered here, at publish time.)


# svg_gauge PCT SUBLABEL COLOR  — a 270-degree radial gauge for a percentage.
svg_gauge() {   # $1 pct(0-100)  $2 sublabel  $3 color
    awk -v pct="${1:-0}" -v slbl="${2:-}" -v col="${3:-$CH_BLUE}" -v track="$CH_TRACK" -v ink="$CH_INK" -v mute="$CH_MUTE" \
        -v cid="${CH_ID:-ch}" -v ctitle="${CH_TITLE:-Chart}" "$CH_AWK_HELPERS"'
    BEGIN{
        p=pct+0; if(p<0)p=0; if(p>100)p=100
        cx=120; cy=118; r=82; sw=20; PI=3.14159265359; C=2*PI*r; span=0.75
        svgo("0 0 240 205","svg-gauge","xMidYMid meet")
        svdesc(sprintf("%.1f%%%s.",p,(slbl!=""?(" " slbl):"")))
        printf "<circle cx=\"%d\" cy=\"%d\" r=\"%d\" fill=\"none\" stroke=\"%s\" stroke-width=\"%d\" stroke-linecap=\"round\" stroke-dasharray=\"%.2f %.2f\" transform=\"rotate(135 %d %d)\"/>",cx,cy,r,track,sw,span*C,(1-span)*C,cx,cy
        vlen=p/100*span*C
        printf "<circle cx=\"%d\" cy=\"%d\" r=\"%d\" fill=\"none\" stroke=\"%s\" stroke-width=\"%d\" stroke-linecap=\"round\" stroke-dasharray=\"%.2f %.2f\" transform=\"rotate(135 %d %d)\"/>",cx,cy,r,col,sw,vlen,C-vlen,cx,cy
        printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" class=\"c-gbig\" fill=\"%s\">%.1f%%</text>",cx,cy+2,ink,p
        if(slbl!="")printf "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" class=\"c-cap\" fill=\"%s\">%s</text>",cx,cy+26,mute,xesc(slbl)
        dto(); printf "<tr>"; dth(slbl!=""?slbl:"Value"); printf "</tr><tr>"; dtdn(sprintf("%.1f%%",p)); printf "</tr>"
        dtc()
    }'
}

# svg_stack DATA COLORS LABELS  — stacked vertical bars over categories.
# DATA = "cat:s1,s2,…|…" (segments per category); COLORS/LABELS = comma lists.
svg_stack() {   # $1 data  $2 colors  $3 labels
    awk -v data="$1" -v colors="$2" -v labels="$3" -v track="$CH_TRACK" -v grid="$CH_GRID" -v ink="$CH_INK" -v mute="$CH_MUTE" \
        -v cid="${CH_ID:-ch}" -v ctitle="${CH_TITLE:-Chart}" "$CH_AWK_HELPERS"'
    BEGIN{
        nc=split(colors,cc,","); nl=split(labels,ll,","); n=split(data,seg,"|"); mx=1; ns=0; hi=1; hit=0
        for(i=1;i<=n;i++){ split(seg[i],p,":"); lab[i]=p[1]; m=split(p[2],vv,","); ns=m; t=0
            for(j=1;j<=m;j++){ val[i,j]=vv[j]+0; t+=val[i,j] } ctot[i]=t; if(t>mx)mx=t; if(t>hit){hit=t;hi=i} }
        W=760;H=214;L=46;R=46;top=30;base=H-24;bw=((W-L-R)/n)*0.62
        svgo("0 0 " W " " H,"svg-vbar","none")
        ds=sprintf("%d categories from %s to %s, series: %s. Peak: %s (%s total).",n,lab[1],lab[n],labels,lab[hi],hn(hit))
        svdesc(ds)
        for(g=0;g<=4;g++){ yy=top+(base-top)*g/4; yv=mx*(4-g)/4
            printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"%s\"/>",L,yy,W-R,yy,grid
            printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" class=\"c-axis\" fill=\"%s\">%s</text>",L-6,yy+4,mute,hn(yv)
            printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"start\" class=\"c-axis\" fill=\"%s\">%s</text>",W-R+6,yy+4,mute,hn(yv) }
        printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"%s\"/>",L,base,W-R,base,track
        gw=(W-L-R)/n
        for(i=1;i<=n;i++){ x=L+(i-0.5)*gw; yb=base
            for(j=1;j<=ns;j++){ h=val[i,j]/mx*(base-top); if(h<0.5)h=0
                printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" fill=\"%s\"><title>%s %s: %s</title></rect>",x-bw/2,yb-h,bw,h,cc[((j-1)%nc)+1],xesc(lab[i]),(j<=nl?ll[j]:""),hn(val[i,j]); yb-=h } }
        every=int(n/8); if(every<1)every=1
        for(i=1;i<=n;i++){ if((i-1)%every==0||i==n){ x=L+(i-0.5)*gw
            printf "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\" class=\"c-axis\" fill=\"%s\">%s</text>",x,base+15,mute,xesc(lab[i]) } }
        lx=L
        for(j=1;j<=ns&&j<=nl;j++){ printf "<rect x=\"%d\" y=\"10\" width=\"12\" height=\"12\" rx=\"2\" fill=\"%s\"/>",lx,cc[((j-1)%nc)+1]
            printf "<text x=\"%d\" y=\"20\" class=\"c-lbl\" fill=\"%s\">%s</text>",lx+16,ink,xesc(ll[j]); lx+=16+length(ll[j])*8+22 }
        dto(); printf "<tr>"; dth("Category")
        for(j=1;j<=ns;j++) dthn(j<=nl?ll[j]:"Series " j)
        dthn("Total"); printf "</tr>"
        for(i=1;i<=n;i++){ printf "<tr>"; dtd(lab[i])
            for(j=1;j<=ns;j++) dtdn(hn(val[i,j]))
            dtdn(hn(ctot[i])); printf "</tr>" }
        dtc()
    }'
}

# svg_heat DATA  — an hour x weekday heatmap. DATA = "HH:v0,v1,…,v6|…" (24 rows,
# 7 weekday values Mon..Sun). Cells tinted by value share of the max (blue ramp).
svg_heat() {   # $1 data
    awk -v data="$1" -v ink="$CH_INK" -v mute="$CH_MUTE" -v track="$CH_TRACK" \
        -v cid="${CH_ID:-ch}" -v ctitle="${CH_TITLE:-Chart}" "$CH_AWK_HELPERS"'
    function ramp(f,  a){ if(f<=0)return track; a=int(f*4+0.999); if(a<1)a=1; if(a>4)a=4
        return (a==1)?"#dbe7f6":(a==2)?"#a9c8ea":(a==3)?"#6ea3d8":"#3b74b4" }
    BEGIN{
        split("Mon Tue Wed Thu Fri Sat Sun",wd," ")
        n=split(data,row,"|"); mx=1; bi=1; bj=1
        for(i=1;i<=n;i++){ split(row[i],p,":"); hr[i]=p[1]; m=split(p[2],vv,","); for(j=1;j<=m;j++){ c[i,j]=vv[j]+0; if(c[i,j]>mx){mx=c[i,j];bi=i;bj=j} } }
        L=48; T=24; cw=100; ch=8; gap=1.6
        W=L+7*cw+48; H=T+n*(ch+gap)+8
        svgo("0 0 " W " " sprintf("%.0f",H),"svg-heat","xMidYMin meet")
        svdesc(sprintf("Activity by hour of day (rows) and weekday (columns). Busiest: %s %s:00 (%s).",wd[bj],hr[bi],hn(mx)))
        for(j=1;j<=7;j++) printf "<text x=\"%.1f\" y=\"14\" text-anchor=\"middle\" class=\"c-axis\" fill=\"%s\">%s</text>",L+(j-0.5)*cw,mute,wd[j]
        for(i=1;i<=n;i++){ y=T+(i-1)*(ch+gap)
            if((i-1)%3==0){ printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"end\" class=\"c-axis\" fill=\"%s\">%s:00</text>",L-6,y+ch,mute,hr[i]
                printf "<text x=\"%d\" y=\"%.1f\" text-anchor=\"start\" class=\"c-axis\" fill=\"%s\">%s:00</text>",L+7*cw+6,y+ch,mute,hr[i] }
            for(j=1;j<=7;j++){ x=L+(j-1)*cw; f=c[i,j]/mx
                printf "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" rx=\"1.5\" fill=\"%s\"><title>%s:00 %s: %s</title></rect>",x,y,cw-gap,ch,ramp(f),hr[i],wd[j],hn(c[i,j]) } }
        dto(); printf "<tr>"; dth("Hour")
        for(j=1;j<=7;j++) dthn(wd[j])
        printf "</tr>"
        for(i=1;i<=n;i++){ printf "<tr>"; dtd(hr[i] ":00")
            for(j=1;j<=7;j++) dtdn(hn(c[i,j]))
            printf "</tr>" }
        dtc()
    }'
}
