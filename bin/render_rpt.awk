# render_rpt.awk — the .rpt -> HTML renderer's hot loop, one awk pass per page.
#
# publish_lib.sh's render_rpt() emits the html_head before and </body></html>
# after this program's output; everything between — the whole .rpt line
# protocol (TITLE/INTRO/ALERT/LOGCARD/NAV/TABLE/HEAD/KIND/RECALC/ROW/TOTAL/NOTE/
# LINK/SUMMARY/FOOT) — is rendered here. This used to be a bash while-read loop
# with a render_cell function per table cell; the per-cell command
# substitutions ($(slug_override), $(slugify)'s tr|tr|sed pipeline) forked
# ~5 processes per entity-linked cell, which put a full transfer publish at
# ~5 minutes. The awk pass renders the same bytes with no per-cell forks.
#
# Variables (awk -v):
#   droptitle  "1" = suppress the FIRST table's <h2> (report pages; the page
#              <h1> already carries it). Detail pages pass "" and keep it.
#   dlink      href base for entity detail links: "../details/" on report
#              pages, "../" on detail pages (DLINK_BASE).
#   slugmaps   space-separated "<sub>=<path>" list of the _slugmap.tsv
#              name->slug override files (colliding entity names; see
#              publish_lib.sh). Paths contain no spaces by construction.
#
# POSIX/mawk awk only — no gawk extensions (see CLAUDE.md portability).
# Invoked with LC_ALL=C so tolower()/regexes stay byte-oriented like the
# tr/sed pipeline they replace.

BEGIN {
    FS = "\t"
    US = "\037"                       # \x1f: the lines/clines separator
    n = split(slugmaps, smf, " ")
    for (i = 1; i <= n; i++) {
        eq = index(smf[i], "=")
        smsub = substr(smf[i], 1, eq - 1); smpath = substr(smf[i], eq + 1)
        HAVEMAP[smsub] = 1            # this dir's map is comprehensive: unmapped name = no page
        while ((getline smline < smpath) > 0) {
            t = index(smline, "\t")
            if (t > 1) SLUG[smsub US substr(smline, 1, t - 1)] = substr(smline, t + 1)
        }
        close(smpath)
    }
    # (the FlowManager deep-link machinery — fmmaps/FMURL/fmh1/fmicon — was
    # REMOVED 2026-07: no rpt emits META fmlink and no caller passes the maps)
    # Entity RESULT tints (resmaps: "<sub>=<path>" like slugmaps, the base
    # caches' name/direction/result files): an entity cell gets class
    # res-green/orange/red from its own result. Passed only for the detail
    # pages. Keys UPPERCASED like the slugmaps.
    n = split(resmaps == "" ? "" : resmaps, rmf, " ")
    for (i = 1; i <= n; i++) {
        eq = index(rmf[i], "=")
        rmsub = substr(rmf[i], 1, eq - 1); rmpath = substr(rmf[i], eq + 1)
        while ((getline rmline < rmpath) > 0) {
            nr = split(rmline, rmp, "\t")
            if (nr >= 3 && (rmp[3] == "green" || rmp[3] == "orange" || rmp[3] == "red"))
                RESM[rmsub US toupper(rmp[1])] = rmp[3]
        }
        close(rmpath)
    }
    # SUBSCRIPTION ROW TINTS (subtint: "<subscriptions cache>[ <accounts cache>]",
    # set by the SERVER publish): with a map loaded, any table holding a
    # Subscription column tints each row in that entity's result colour. Kept
    # in its own array — the detail pages' resmaps also tint entity CELLS, and
    # this must not switch that on for a whole area. Keys "s"/"a" + the
    # uppercased name.
    n = split(subtint == "" ? "" : subtint, stf, " ")
    for (i = 1; i <= n; i++) {
        stpfx = (i == 1) ? "s" : "a"
        while ((getline stline < stf[i]) > 0) {
            ns = split(stline, stp, "\t")
            if (ns >= 3 && stp[1] != "" && (stp[3] == "green" || stp[3] == "orange" || stp[3] == "red")) {
                SUBRES[stpfx US toupper(stp[1])] = stp[3]; nsubres++
            }
        }
        close(stf[i])
    }
    # Partner GROUP icons (grpicons: one file, "<partner-name>\t<slug>"): a
    # multi-token partner (a merged GROUP) gets a small icon after its name that
    # links to details/partner-groups/<slug>.html — the page explaining why those
    # partner tokens were combined. Passed only for the entity Partner pages.
    if (grpicons != "") {
        while ((getline gline < grpicons) > 0) {
            t = index(gline, "\t")
            if (t > 1) GRP[toupper(substr(gline, 1, t - 1))] = substr(gline, t + 1)
        }
        close(grpicons)
    }
    table_open = 0; table_printed = 0; hdr_done = 0
    tclass = ""; tattr = ""; ntables = 0; start_empty = 0
    nhead = 0; nkind = 0
}

# the build id for data-v: build.sh exports AXWAY_BUILD_ID (its start epoch);
# a publish run outside a build falls back to this run's own clock
function buildid(   t) {
    if (BUILDID != "") return BUILDID
    BUILDID = ENVIRON["AXWAY_BUILD_ID"]
    if (BUILDID == "") { srand(); BUILDID = srand() }
    return BUILDID
}
# the first MARK in S replaced by REP, literally (no sub(): an escaped
# attribute value carries "&", which a sub() replacement reads as the match)
function splice(s, mark, rep,   p) {
    p = index(s, mark); if (p == 0) return s
    return substr(s, 1, p - 1) rep substr(s, p + length(mark))
}
function esc(s) {
    gsub(/&/,  "\\&amp;",  s)
    gsub(/</,  "\\&lt;",   s)
    gsub(/>/,  "\\&gt;",   s)
    gsub(/"/,  "\\&quot;", s)
    return s
}

# The @{...}/@data: protocol is IN-BAND with the data: a raw value that
# happens to begin with the prefix (a partner-chosen filename, an entity
# name) reaches the renderer looking like writer metadata. Every parsed
# metadata value is therefore allowlisted before it may shape markup; a cell
# whose block fails any check renders as inert literal text instead
# (escaped, unlinked, visibly carrying its @-prefix). A VALID raw value
# (@data:res=green is a legal file name) passes those checks, so the writers
# mark raw values: lit() puts the EMPTY block @{} in front, and the text after
# any block is literal (2026-09-29 audit F07).
function ok_class(s)   { return s ~ /^[A-Za-z0-9_ -]+$/ }
function ok_colspan(s) { return s ~ /^[0-9]+$/ }
# link=/alink targets are wrapped as dlink TARGET ".html": site-local
# relative paths only — must start alphanumeric (no leading / or .), no
# path traversal, no scheme colon, no quote/angle/entity characters
function ok_target(s)  { return s ~ /^[A-Za-z0-9][A-Za-z0-9\/_. -]*$/ && index(s, "..") == 0 }
# href= is used verbatim (esc()-quoted): a relative URL, or absolute http(s)
# — never a bare scheme like javascript:/data:, never protocol-relative.
# POSITIVE, not just a scheme ban (2026-09-28 audit F01): the browser's URL
# parser TRIMS leading spaces/control characters, DROPS tab/CR/LF anywhere
# and reads a backslash as a slash, so " javascript:x", "java<CR>script:x"
# and "\\host" all slipped past the old scheme test — a relative target must
# START with a path/query/fragment character (no space, slash or backslash:
# protocol-relative is out too), an absolute one is http(s):// + a host
# character, and no target may carry a control character anywhere. Every URL
# sink uses this one test: @{href=}, clinks lines, @data:href row targets,
# ALERT and LINK directives.
function ok_href(s) {
    if (s ~ /[\001-\037\177]/) return 0
    if (s ~ /^https?:\/\/[A-Za-z0-9]/) return 1
    return s ~ /^[A-Za-z0-9._?#]/ && s !~ /^[A-Za-z][A-Za-z0-9+.\-]*:/
}
function ok_dname(s)   { return s ~ /^[A-Za-z0-9_-]+$/ }

# The partner-GROUP icon: a small anchor after a grouped partner's name, linking
# to the page that explains why those partner tokens were merged into one group.
function gicon(u) {
    return " <a class=\"grpicon\" href=\"" u "\" title=\"Why these partners form one group\">&#128279;</a>"
}

# The detail-page link icon, used on ROW-DRILL rows (the whole row toggles a
# click-to-expand): the entity name stays plain (a click there drills) and
# this small anchor after it opens the entity's detail page instead.
function dicon(u) {
    return " <a class=\"dlicon\" href=\"" u "\" title=\"Open the detail page\">&#8599;</a>"
}

# **bold** -> <strong>bold</strong> (INTRO and NOTE), like the old sed.
function bold(s,    out, inner) {
    out = ""
    while (match(s, /\*\*[^*]+\*\*/)) {
        inner = substr(s, RSTART + 2, RLENGTH - 4)
        out = out substr(s, 1, RSTART - 1) "<strong>" inner "</strong>"
        s = substr(s, RSTART + RLENGTH)
    }
    return out s
}

# Prose (INTRO/NOTE) rendering: esc + **bold**, plus [[<sub>/<name>]] — an
# entity detail link inside prose, the alink cell attr's twin: the NAME
# resolves through that sub-dir's comprehensive slugmap at render time; no
# page, no link (the name renders plain). bold() runs LAST, over the
# assembled string, so **…** may wrap a [[…]] token.
function prose(s,    out, i, j, tok, p, sd, nm, slug) {
    out = ""
    while ((i = index(s, "[[")) > 0) {
        j = index(substr(s, i + 2), "]]")
        if (j == 0) break
        tok = substr(s, i + 2, j - 1)
        out = out esc(substr(s, 1, i - 1))
        p = index(tok, "/")
        slug = ""
        if (p > 1) { sd = substr(tok, 1, p - 1); nm = substr(tok, p + 1); slug = slug_for(sd, nm) }
        else nm = tok
        if (slug != "" && ok_target(sd "/" slug)) out = out "<a href=\"" dlink sd "/" slug ".html\">" esc(nm) "</a>"
        else            out = out esc(nm)
        s = substr(s, i + j + 3)
    }
    return bold(out esc(s))
}

# Same result as the old  tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-'
# | sed 's/^-//;s/-$//'  pipeline (C locale: ASCII case folding only).
function slugify(s) {
    s = tolower(s)
    gsub(/[^a-z0-9]+/, "-", s)
    sub(/^-/, "", s); sub(/-$/, "", s)
    return s
}

# Entity name -> detail-page slug. The _slugmap.tsv maps are COMPREHENSIVE
# (details.sh records EVERY page, seen or configured-only, since the slug
# carries the entity's direction suffix) — so a name absent from the map has
# no page: return "" and the caller renders the cell unlinked. The slugify
# fallback only applies when a directory has no map at all (a from-scratch
# run that has not reached details.sh yet).
function slug_for(sd, name,    k) {
    k = sd US name
    if (k in SLUG && SLUG[k] != "") return SLUG[k]
    if (sd in HAVEMAP) return ""
    return slugify(name)
}

# $2..$NF -> CELL[1..NCELL], preserving empty/trailing cells. A directive
# with no payload at all keeps bash split_tsv's one-empty-cell semantics.
function split_cells(    i) {
    split("", CELL)
    if (NF <= 1) { NCELL = 1; CELL[1] = "" }
    else { NCELL = NF - 1; for (i = 2; i <= NF; i++) CELL[i - 1] = $i }
}

function emit_header(    i, k, thc) {
    if (!table_open) return
    if (!table_printed) {   # open the table lazily so a RECALC line can add data-recalc
        # SUBSCRIPTION ROW TINTS (subtint=1, the server publish): a table with a
        # Subscription column paints each row in that subscription's RESULT
        # colour, exactly as an explicit `restint` table does — the header is
        # known by now, so the decision can be made on the way out. A table the
        # report already tinted keeps its own modifier.
        if (nsubres > 0 && subcol > 0 && tattr !~ /data-restint=/)
            tattr = tattr " data-restint=\"1\""
        printf "<div class=\"tablewrap\"><table%s%s>\n", \
               (tclass != "" ? " class=\"" substr(tclass, 2) "\"" : ""), tattr
        table_printed = 1
    }
    if (hdr_done) return
    hdr_done = 1
    # the optional GROUP banner row (GHEAD): cells carry their own
    # @{colspan=N,class=...} prefixes — parsed here, not through cell()
    if (ngh > 0) {
        printf "<tr>"
        for (i = 1; i <= ngh; i++) {
            gtxt = GHC[i]; gsp = ""; gcls = ""
            if (substr(gtxt, 1, 2) == "@{") {
                gp = index(gtxt, "}")
                gbad = (gp == 0)
                if (!gbad) {
                    gattrs = substr(gtxt, 3, gp - 3); gtxt = substr(gtxt, gp + 1)
                    gn = split(gattrs, gkv, ",")
                    for (gj = 1; gj <= gn; gj++) {
                        if (index(gkv[gj], "colspan=") == 1) { gcv = substr(gkv[gj], 9); if (ok_colspan(gcv)) gsp = " colspan=\"" gcv "\""; else gbad = 1 }
                        else if (index(gkv[gj], "class=") == 1) { gcv = substr(gkv[gj], 7); if (ok_class(gcv)) gcls = " class=\"" gcv "\""; else gbad = 1 }
                    }
                }
                if (gbad) { gsp = ""; gcls = ""; gtxt = GHC[i] }
            }
            printf "<th%s%s>%s</th>", gsp, gcls, esc(gtxt)
        }
        printf "</tr>\n"
    }
    printf "<tr>"
    for (i = 1; i <= nhead; i++) {
        k = (i <= nkind && KINDS[i] != "" ? KINDS[i] : "text")
        if (k == "num" || k == "numfailed" || k == "numprocessed" || k == "numwarn" || k == "numerr" || k == "numok") thc = "num"
        else thc = ""
        if ((i - 1) in gsepset) thc = (thc != "" ? thc " gsep" : "gsep")
        printf "<th%s>%s</th>", (thc != "" ? " class=\"" thc "\"" : ""), esc(HEADC[i])
    }
    printf "</tr>\n"
}

function close_table() {
    if (!table_open) return
    emit_header()
    printf "</table></div>\n"
    table_open = 0
    # an open .sxscol column (col_open) is NOT closed here: the next TABLE
    # decides — a switch-group sibling (same switch=KEY, same sxs row) keeps
    # rendering INSIDE this column, so the OK/All pair of a side-by-side
    # histogram occupies one column and its hidden member leaves no gap
    # (2026-09-05); anything else closes it via close_col()
}
function close_col() {
    if (col_open) { printf "</div>\n"; col_open = 0; col_swkey = "" }   # close the .sxscol column
}

# One table cell (the old render_cell): KIND-driven class, @{...} cell
# attributes, entity detail-page links, the \x1f list kinds, bar widths.
# A "Direction" column renders LOWERCASE everywhere on the site — in / out /
# both, inbound / outbound / relay, incoming / outgoing, and the detail pages'
# connection/movement pairs (out/in, in + out). Folding here rather than in the
# ~10 reports that emit one means a NEW report cannot get it wrong, and the raw
# Inbound/Outbound values in _transfers.tsv stay untouched (they are data, and
# awk tests like $2=="Inbound" depend on them).
#
# ONLY those words fold (plus "?", the undecidable-side placeholder in the detail
# pages' XXX/YYY pair): the value must consist entirely of them, separated by
# / or +. A Direction column holding anything else — the server PeSIT report's
# endpoint pairs "ST -> CFT" / "CFT -> ST", which name components, not sides —
# is left exactly as the report wrote it.
function dirfold(v,   pre, body, p, t) {
    if (v == "") return v
    pre = ""; body = v
    if (substr(v, 1, 2) == "@{") {          # keep an @{class=…} prefix verbatim, fold the value after it
        p = index(v, "}")
        if (p == 0) return v
        pre = substr(v, 1, p); body = substr(v, p + 1)
    }
    t = body
    gsub(/[\/+]/, " ", t)
    gsub(/^[ \t]+|[ \t]+$/, "", t)
    if (t == "") return v
    if (toupper(t) !~ /^(IN|OUT|BOTH|INBOUND|OUTBOUND|RELAY|INCOMING|OUTGOING|[?])([ \t]+(IN|OUT|BOTH|INBOUND|OUTBOUND|RELAY|INCOMING|OUTGOING|[?]))*$/) return v
    return pre tolower(body)
}

function cell(kind, raw, total,    cls, sp, text, cc, link, nolink, p, attrs,
              nkv, kva, i, kv, w, rawtext, pout, nseg, segs, pnm, sd, slug,
              av, ap2, asd, anm, aslug, rawhref, maskv, nln, LNS, li, midl,
              bad, cv, sv, tt, alsd, rr, rmix) {
    cls = ""; sp = ""; text = ""; cc = ""; link = ""; nolink = 0; rawhref = ""; maskv = ""; sv = ""; tt = ""; alsd = ""
    if (substr(raw, 1, 2) == "@{") {
        p = index(raw, "}")
        bad = (p == 0)
        if (!bad) {
            attrs = substr(raw, 3, p - 3); text = substr(raw, p + 1)
            nkv = split(attrs, kva, ",")
            for (i = 1; i <= nkv; i++) {
                kv = kva[i]
                if (index(kv, "class=") == 1)        { cc = substr(kv, 7); if (!ok_class(cc)) bad = 1 }
                else if (index(kv, "colspan=") == 1) { cv = substr(kv, 9); if (ok_colspan(cv)) sp = " colspan=\"" cv "\""; else bad = 1 }
                else if (index(kv, "link=") == 1)    { link = substr(kv, 6); if (!ok_target(link)) bad = 1 }
                else if (index(kv, "alink=") == 1) {
                    # alink=<sub>/<name>: resolve the NAME through the sub's
                    # comprehensive slugmap at render time (details.sh's slugs
                    # carry the direction suffix) — no page, no link.
                    av = substr(kv, 7); ap2 = index(av, "/")
                    asd = substr(av, 1, ap2 - 1); anm = substr(av, ap2 + 1)
                    aslug = slug_for(asd, anm)
                    if (aslug != "") link = asd "/" aslug
                    if (link != "" && !ok_target(link)) { link = ""; bad = 1 }
                    r = RESM[asd US toupper(anm)]
                    if (r != "") cc = (cc != "" ? cc " res-" r : "res-" r)
                }
                else if (index(kv, "href=") == 1)    { rawhref = substr(kv, 6); if (!ok_href(rawhref)) bad = 1 }
                else if (index(kv, "nolink=") == 1)  nolink = 1
                # mask=<suffix>: append <suffix> to the cell in a distinct colour
                # (a file filter/mask after its directory) — the location cells
                else if (index(kv, "mask=") == 1)    maskv = substr(kv, 6)
                # sortval=<integer>: the cell's SORT KEY (data-sortval, read by
                # report.js before the text) — a humanized text cell ("5 days")
                # sorts by its number (2026-09-02, the Pickups Oldest waiting)
                else if (index(kv, "sortval=") == 1) { sv = substr(kv, 9); if (sv !~ /^-?[0-9]+$/) bad = 1 }
                # title=<words>: the cell's hover title (2026-09-20, the Polling
                # Active column) — escaped like text; the attr list splits on
                # ",", so the words carry none
                else if (index(kv, "title=") == 1)   tt = substr(kv, 7)
                # alist=<sub> (2026-09-28): the text is a ", "-joined NAME list,
                # each name linked to its <sub> detail page (the Features BL row)
                else if (index(kv, "alist=") == 1)   { alsd = substr(kv, 7); if (!ok_dname(alsd)) bad = 1 }
            }
        }
        # any invalid metadata: the block was data after all — render the
        # whole cell as literal text, nothing from it shapes markup
        if (bad) { cc = ""; sp = ""; link = ""; nolink = 0; rawhref = ""; maskv = ""; sv = ""; tt = ""; alsd = ""; text = raw }
    } else text = raw
    if (!total) {
        if (kind == "num") cls = "num"
        else if (kind == "numfailed") cls = "num failed"
        else if (kind == "numprocessed") cls = "num processed"
        # tint-only variants: the SAME red/green as failed/processed but
        # WITHOUT those class names, so a row with several Error/OK column
        # pairs (Top view IDs) keeps its drill bound to the one failed/
        # processed pair (report.js binds only when the outcome maps to ONE cell)
        else if (kind == "numerr") cls = "num errc"
        else if (kind == "numok") cls = "num okc"
        else if (kind == "numwarn") cls = "num warn"
        else if (kind == "file") cls = "file"
        # prose (2026-09-29 audit): a SENTENCE cell (the Triage Symptoms /
        # Evidence columns) — it wraps inside a readable width instead of
        # stretching the table to thousands of pixels (style.css td.prose)
        else if (kind == "prose") cls = "prose"
        else if (kind == "clines" || kind == "clinks") cls = "lines"
        if (kind == "bar") {
            if (text ~ /^[0-9]+$/) { w = int((text + 2) / 5) * 5; if (w > 100) w = 100 }
            else w = 0
            CELLOUT = sprintf("<td class=\"bar w%d\"><span></span></td>", w); CELLCLS = "bar"
            return
        }
    } else {
        # GENERAL RULE (2026-07): a TOTAL cell aligns like the column it sums —
        # numeric kinds stay right-aligned even without an explicit
        # @{class=num} (tints remain explicit; skip when the author already
        # classed the cell num)
        if (kind ~ /^num/ && (" " cc " ") !~ / num /) cls = "num"
    }
    if (cc != "") cls = (cls != "" ? cls " " cc : cc)
    # gsep: this cell starts a column group (set per call by the ROW/TOTAL
    # loop from the table's gsep= modifier) — left divider + extra padding
    if (gsephit) { cls = (cls != "" ? cls " gsep" : "gsep"); gsephit = 0 }
    rawtext = text
    text = esc(text)
    # `clinks` (2026-09-03) = a clines cell whose every line is a LINK:
    # "href|label" per \x1f line — a relative href (no scheme, no //) becomes
    # <a>, anything else renders as the plain line; folds like clines below
    if (!total && kind == "clinks") {
        nln = split(rawtext, LNS, US); text = ""
        for (li = 1; li <= nln; li++) { p = index(LNS[li], "|")
            if (p > 1 && ok_href(substr(LNS[li], 1, p - 1)) && substr(LNS[li], 1, 1) != "/") lhtml = "<a href=\"" esc(substr(LNS[li], 1, p - 1)) "\">" esc(substr(LNS[li], p + 1)) "</a>"
            else lhtml = esc(LNS[li])
            text = text (li > 1 ? US : "") lhtml }
    }
    # @{alist=SUB}: one link per listed name (slugmap-resolved; no page =
    # plain), ", "-joined. Several anchors, so no whole-cell link; the cell
    # takes the names' result tint only when they all share one.
    if (!total && alsd != "") {
        nln = split(rawtext, LNS, ", "); text = ""; r = ""; rmix = 0
        for (li = 1; li <= nln; li++) {
            slug = slug_for(alsd, LNS[li])
            if (slug != "" && ok_target(alsd "/" slug)) lhtml = "<a href=\"" dlink alsd "/" slug ".html\">" esc(LNS[li]) "</a>"
            else lhtml = esc(LNS[li])
            text = text (li > 1 ? ", " : "") lhtml
            rr = RESM[alsd US toupper(LNS[li])]
            if (li == 1) r = rr; else if (rr != r) rmix = 1
        }
        if (r != "" && !rmix) cls = (cls != "" ? cls " res-" r : "res-" r)
    }
    if (maskv != "") text = text "<span class=\"mask\">" esc(maskv) "</span>"
    if (!total && kind == "mono") text = "<code>" text "</code>"
    # KIND pre: a raw log LINE, kept verbatim inside <pre> — the logged spacing
    # survives and the line does NOT wrap (see td pre in style.css), so one
    # logged line stays one rendered line and its cell scrolls with the table.
    # Used by the failed-file error pages, whose server-log table shows the
    # message exactly as logged, JSON payload and all, not a truncated one-liner.
    if (!total && kind == "pre") text = "<pre>" text "</pre>"
    # `clines` = a COLLAPSIBLE lines cell: 3+ lines render collapsed to the
    # first and last line with an ellipsis between (the middle lines sit in a
    # CSS-hidden span.cm, the ellipsis in span.ce); class `clps` on the td is
    # the collapsed state, report.js toggles `open` on click (style.css swaps
    # the two spans). 1-2 lines render stacked (<br>).
    if (!total && (kind == "clines" || kind == "clinks")) {
        nln = split(text, LNS, US)
        if (nln <= 2) gsub(US, "<br>", text)
        else {
            midl = ""
            for (li = 2; li < nln; li++) midl = midl LNS[li] "<br>"
            text = LNS[1] "<br><span class=\"ce\">&#8943;<br></span><span class=\"cm\">" midl "</span>" LNS[nln]
            cls = (cls != "" ? cls " clps" : "clps")
        }
    }
    # acct/site/login/host/lgc/ptn/app/dom/bl cells link to the entity's
    # detail page; "(pseudo)" values and @{nolink=1} cells stay plain
    if (!total && rawtext != "" && substr(rawtext, 1, 1) != "(" && !nolink && \
        (kind == "acct" || kind == "site" || kind == "login" || kind == "host" || \
         kind == "lgc" || kind == "ptn" || kind == "app" || kind == "dom" || kind == "bl")) {
        if (kind == "acct") sd = "accounts"
        else if (kind == "site") sd = "subscriptions"
        else if (kind == "login") sd = "logins"
        else if (kind == "host") sd = "hosts"
        else if (kind == "lgc") sd = "logicals"
        else if (kind == "ptn") sd = "partners"
        else if (kind == "app") sd = "applications"
        else if (kind == "bl") sd = "bl"
        else sd = "domains"
        slug = slug_for(sd, rawtext)
        # the entity's own RESULT tint (detail pages: resmaps loaded)
        r = RESM[sd US toupper(rawtext)]
        if (r != "") cls = (cls != "" ? cls " res-" r : "res-" r)
        # the partner-group icon (grouped partners only): an extra anchor after
        # the name — the cell then holds TWO links and drops `cl`.
        gu = ""
        if (kind == "ptn" && (toupper(rawtext) in GRP)) gu = dlink "partner-groups/" GRP[toupper(rawtext)] ".html"
        extra = (gu != "" ? gicon(gu) : "")
        # an EXPLICIT link on the cell (@{link=}, @{alink=}, @{href=}) wraps
        # the whole value below: the kind link and the group icon would nest
        # an anchor inside it (2026-09-28 fix) — the tint above stays
        if (link != "" || rawhref != "") { slug = ""; extra = "" }
        if (rowdrill && slug != "") { text = text dicon(dlink sd "/" slug ".html") extra }
        else if (slug != "" && extra == "") { text = "<a href=\"" dlink sd "/" slug ".html\">" text "</a>"; cls = (cls != "" ? cls " cl" : "cl") }
        else if (slug != "")         text = "<a href=\"" dlink sd "/" slug ".html\">" text "</a>" extra
        else if (extra != "")        text = text extra
    }
    # @{link=SUB/SLUG}: an explicit per-row detail-page link. Either way the
    # link wraps the WHOLE cell value, so class `cl` makes the entire cell the
    # click target (style.css moves the td padding onto the block-level <a>).
    # On a ROW-DRILL row (rowdrill, see the ROW branch) the click belongs to
    # the drill — the detail page moves to an ICON after the name instead.
    if (!total && link != "" && rowdrill) text = text dicon(dlink link ".html")
    else if (!total && link != "" && rawhref == "") { text = "<a href=\"" dlink link ".html\">" text "</a>"; cls = (cls != "" ? cls " cl" : "cl") }
    # @{href=URL}: an explicit page-relative link, used VERBATIM (no dlink
    # prefix, no .html suffix) — e.g. the Top view date cells -> the per-day
    # pages. Wraps the whole cell like link=.
    # (allowed on TOTAL rows too)
    if (rawhref != "") { text = "<a href=\"" esc(rawhref) "\">" text "</a>"; cls = (cls != "" ? cls " cl" : "cl") }
    # a tinted count cell whose value is 0: show nothing, drop the tint (warn
    # included since 2026-08 — the logons Key failures/Locked ask; an empty
    # warn cell untints via td.warn:empty)
    if ((" " cls " ") ~ / (failed|processed|errc|okc|warn) / && rawtext == "0") { text = ""; cls = cls " z" }
    # the cell is BUFFERED (CELLOUT, its final class list in CELLCLS): the ROW
    # branch prints the <tr> after its cells, once it knows which Error / OK
    # cells can carry the row's drill lists
    # CONCATENATION, not sprintf (2026-09-29): mawk caps a sprintf result at
    # 8192 bytes ("program limit exceeded: sprintf buffer") — a long cell
    # (a server-log message list, a prose cell) aborted the acceptance render
    CELLOUT = "<td" sp (cls != "" ? " class=\"" cls "\"" : "") (sv != "" ? " data-sortval=\"" sv "\"" : "") (tt != "" ? " title=\"" esc(tt) "\"" : "") ">" text "</td>"
    CELLCLS = cls
}

{
    dir = $1
    rest = (NF > 1 ? substr($0, length($1) + 2) : "")

    if (dir == "TITLE")         printf "<h1>%s</h1>\n", esc(rest)
    else if (dir == "SUBTITLE") printf "<p class=\"subtitle\">%s</p>\n", esc(rest)
    # INTRO is a full-width paragraph like NOTE: a mid-page section intro
    # (the dwell report's Gap-per-day paragraph) closes the open table and
    # any side-by-side row first — it used to print INSIDE the previous
    # table's markup (2026-09-05). An INTRO the no-prose rule suppresses is
    # NO block at all, like a suppressed NOTE: it closes nothing (2026-09-29)
    else if (dir == "INTRO")    { if (!noprose) { close_table(); close_col(); if (grp_open) { printf "</div>\n"; grp_open = 0 }; printf "<p class=\"range\">%s</p>\n", prose(rest) } }
    else if (dir == "ALERT") {
        # optional cells 2+3 append a LINK to the banner (href, text) — the
        # detail pages' after-last-transfer banner points at the page's own
        # "Server log error" section this way. A single-cell ALERT renders
        # exactly as before.
        split_cells()
        if (NCELL >= 3 && CELL[2] != "" && ok_href(CELL[2]))
            printf "<p class=\"alert\">%s<a href=\"%s\">%s</a></p>\n", bold(esc(CELL[1])), esc(CELL[2]), esc(CELL[3])
        else if (NCELL >= 3 && CELL[2] != "")
            printf "<p class=\"alert\">%s%s</p>\n", bold(esc(CELL[1])), esc(CELL[3])
        else printf "<p class=\"alert\">%s</p>\n", bold(esc(rest))
    }
    # WARN is ALERT's amber sibling: same banner, lower severity. ALERT is the
    # RUNTIME register (errors in the server log); WARN is the CONFIGURATION
    # register, so it wears the site's warning colour (orange) rather than red.
    else if (dir == "WARN")     printf "<p class=\"alert warn\">%s</p>\n", bold(esc(rest))
    else if (dir == "LOGCARD") {
        # LOGCARD <date time> <message> — a card holding one raw log line (the
        # detail pages' server-log evidence)
        split_cells()
        printf "<div class=\"logcard\"><span class=\"lc-when\">%s</span><span class=\"lc-msg\">%s</span></div>\n", \
            esc(CELL[1]), esc(CELL[2])
    }
    else if (dir == "STAT") {
        # STAT <class> <value> <label> — an info box (Partner Coverage's
        # Total/Covered/Not covered row); consecutive STATs line up
        # side by side (inline-block, style.css .stat). A \x1f in the label
        # stacks the parts onto their own lines (same convention as the `lines`
        # cell kind) — the twins use-case-pair boxes name both use cases.
        split_cells()
        # "white" is the DEFAULT box — style.css has .stat-green/-orange/-red
        # but deliberately no .stat-white, so emitting the modifier added a
        # class that styled nothing on 48 boxes. Only a colour gets a modifier.
        statcls = (CELL[1] == "" || CELL[1] == "white") ? "stat" : ("stat stat-" esc(CELL[1]))
        statlbl = esc(CELL[3]); gsub(US, "<br>", statlbl)
        # optional cells 4+: a "@data:NAME=VALUE" cell becomes a data-NAME
        # attribute on the box (report.js recalcStats — a data-tok box
        # recomputes its value for the selected date range from its data-sb
        # per-day payload); the FIRST plain cell
        # (present even when empty) keeps its historical meaning as the
        # data-pf row-filter key — report.js setupStatFilter narrows the
        # table to rows whose data-pf lists this key.
        statpf = ""; statpfdone = 0
        for (statci = 4; statci <= NCELL; statci++) {
            if (CELL[statci] ~ /^@data:[A-Za-z][A-Za-z0-9-]*=/) {
                stateq = index(CELL[statci], "=")
                statpf = statpf " data-" substr(CELL[statci], 7, stateq - 7) "=\"" esc(substr(CELL[statci], stateq + 1)) "\""
            } else if (!statpfdone) { statpf = statpf " data-pf=\"" esc(CELL[statci]) "\""; statpfdone = 1 }
        }
        printf "<div class=\"%s\"%s><span class=\"stat-v\">%s</span><span class=\"stat-l\">%s</span></div>\n", \
            statcls, statpf, esc(CELL[2]), statlbl
    }
    else if (dir == "NAV") {
        split_cells()
        printf "<p class=\"tabs\">"
        for (i = 1; i <= NCELL; i++) {
            f = CELL[i]
            if (f == "") continue
            if (f == "@sep") { printf "<span class=\"tabsep\"></span>"; continue }
            # cell = active|label|page  (active: 0 link, 1 current, 2 disabled)
            p = index(f, "|")
            if (p == 0) { a = f; lr = f } else { a = substr(f, 1, p - 1); lr = substr(f, p + 1) }
            p = index(lr, "|")
            if (p == 0) { lbl = lr; file = lr } else { lbl = substr(lr, 1, p - 1); file = substr(lr, p + 1) }
            if (a == "1")      printf "<span class=\"tab active\">%s</span>", esc(lbl)
            else if (a == "2") printf "<span class=\"tab disabled\">%s</span>", esc(lbl)
            else               printf "<a class=\"tab\" href=\"%s\">%s</a>", file, esc(lbl)
        }
        printf "</p>\n"
    }
    else if (dir == "TABLE") {
        close_table()
        ntables++
        split_cells()
        heading = CELL[1]
        tclass = ""; tattr = ""; start_empty = 0; this_sxs = 0; this_sxsgrp = "1"; this_swkey = ""; heading_id = ""; keep_heading = 0; split("", gsepset); split("", DCK)
        for (i = 2; i <= NCELL; i++) {
            mi = CELL[i]
            if (mi == "sxs")             this_sxs = 1   # side-by-side: this table shares a flex row with adjacent sxs tables
            else if (index(mi, "sxs=") == 1) { this_sxs = 1; this_sxsgrp = substr(mi, 5) }   # sxs=<id>: a DIFFERENT id starts a NEW flex row (adjacent runs stay separate rows)
            else if (mi == "wide")       tclass = tclass " wide"
            else if (mi == "group")      tclass = tclass " grouped"
            else if (mi == "nosearch")   tattr = tattr " data-nosearch=\"1\""
            else if (mi == "nosort")     tattr = tattr " data-nosort=\"1\""
            else if (mi == "startempty") { tattr = tattr " data-start-empty=\"1\""; start_empty = 1 }
            else if (index(mi, "drill=") == 1)    tattr = tattr " data-drill-unit=\"" substr(mi, 7) "\""
            else if (index(mi, "sort=") == 1)     tattr = tattr " data-sort-init=\"" substr(mi, 6) "\""
            # switch=KEY:LABEL (2026-09-03): tables sharing KEY form ONE switch
            # group on the page — segment_rpt keeps them on one tab page and
            # report.js (setupSwitches) shows one at a time behind a button
            # row built from the labels, the first table being the default
            else if (index(mi, "switch=") == 1) { sw = substr(mi, 8); p9 = index(sw, ":"); this_swkey = (p9 ? substr(sw, 1, p9 - 1) : sw)
                tattr = tattr " data-switch=\"" esc(this_swkey) "\" data-switch-label=\"" esc(p9 ? substr(sw, p9 + 1) : sw) "\"" }
            # tab=KEY (2026-09-05): publish_lib's segment_rpt keeps consecutive
            # tables sharing KEY on ONE tab page, stacked and all visible (the
            # switch= group shows one at a time) — nothing to render here
            else if (index(mi, "tab=") == 1) { }
            else if (mi == "totaltop")   tattr = tattr " data-total-top=\"1\""
            else if (mi == "datereset")  tattr = tattr " data-date-reset=\"1\""
            else if (mi == "nofilter")   tattr = tattr " data-nofilter=\"1\""
            # rangehook (2026-09-27): a page ENGINE builds the rows and takes the
            # From/To range through a window hook (search/all-files.html) — date-aware
            # for report.js, paired with nofilter so report.js never hides its rows
            # (an engine table gets no cols picker — data-nocolmove: its rows
            # arrive after report.js ordered / hid the columns and would not
            # follow a moved or hidden column)
            else if (mi == "rangehook")  tattr = tattr " data-rangehook=\"1\" data-nocolmove=\"1\""
            # subfiles=<slug> (2026-09-29): the subscription page's Files table,
            # built in the browser (assets/sub-files.js) from the day list
            # docs/search/all/s/<slug>.js; data-v = the build id, that list's
            # cache-buster (it is written after the detail pages render, so no
            # cksum of it exists yet — a new build = a new id)
            else if (index(mi, "subfiles=") == 1) tattr = tattr " data-subfiles=\"" esc(substr(mi, 10)) "\" data-v=\"" buildid() "\" data-nocolmove=\"1\""
            else if (index(mi, "pfnoun=") == 1) tattr = tattr " data-pf-noun=\"" esc(substr(mi, 8)) "\""   # the noun setupStatFilter puts in the recomputed total row
            else if (mi == "seenrows")   tattr = tattr " data-seenrows=\"1\""
            else if (mi == "restint")    tattr = tattr " data-restint=\"1\""   # rows tint by their data-res RESULT even when seen (beats the seenrows green)
            else if (mi == "rowlink")    tattr = tattr " data-rowlink=\"1\""   # the WHOLE row opens its target (report.js setupIndexRows): the row's own @data:href, else its first link
            else if (mi == "heat")       tattr = tattr " data-heat=\"1\""
            else if (mi == "esearch")    tattr = tattr " data-esearch=\"1\""
            else if (index(mi, "noagg=") == 1)    tattr = tattr " data-noagg=\"" substr(mi, 7) "\""
            else if (index(mi, "pct=") == 1)      tattr = tattr " data-pct=\"" substr(mi, 5) "\""
            # gsep=<col,col,...>: 0-based data columns that START a column
            # GROUP — their th/td cells get class "gsep" (a left divider +
            # extra padding, style.css). Pairs with the GHEAD banner row.
            else if (index(mi, "gsep=") == 1)     { n2g = split(substr(mi, 6), GSA, ","); for (g2 = 1; g2 <= n2g; g2++) gsepset[GSA[g2] + 0] = 1 }
            # drillcols=<key:col[:Noun_words],...> (2026-09-13, the Entities2
            # pages): per-CELL drills bound by BUILT column index — a row's
            # :coreids-<key> list opens under the cell at <col>; the
            # optional noun (underscores = spaces) heads the list, else the
            # column label (report.js setupExpandable)
            else if (index(mi, "drillcols=") == 1) { tattr = tattr " data-drill-cols=\"" esc(substr(mi, 11)) "\""
                ndk = split(substr(mi, 11), DKA, ","); for (dk = 1; dk <= ndk; dk++) { dp = index(DKA[dk], ":"); if (dp > 1) DCK[substr(DKA[dk], 1, dp - 1)] = 1 } }
            # autohide=<Group label>;<Group label> (2026-09-13, the Entities
            # pages): a column GROUP (a GHEAD banner cell) whose visible cells
            # are ALL empty is hidden in the browser — after a date-range
            # change or a search — and comes back when it has values again
            # (report.js autoHideGroups)
            else if (index(mi, "autohide=") == 1)  tattr = tattr " data-autohide=\"" esc(substr(mi, 10)) "\""
            else if (index(mi, "pager=") == 1)    tattr = tattr " data-pager=\"" substr(mi, 7) "\""
            # zerohide=<m>: while the date range is NARROWED, hide a data row
            # whose re-aggregated bucket metric <m> sums to 0 — a "0 of this
            # page's subject in the window" row says nothing (report.js
            # recalcTable; the full-range restore brings every row back)
            else if (index(mi, "zerohide=") == 1) tattr = tattr " data-zerohide=\"" substr(mi, 10) "\""
            # fold=<res>|<label>: rows with that data-res collapse behind one
            # summary row at load (report.js setupRowFold; {n} = folded count)
            else if (index(mi, "fold=") == 1)     tattr = tattr " data-fold=\"" esc(substr(mi, 6)) "\""
            else if (index(mi, "anchor=") == 1)   heading_id = substr(mi, 8)   # id on the <h2> — an in-page link target
            else if (mi == "keephead")   keep_heading = 1   # keep the heading even on the FIRST table of a report page (droptitle)
        }
        # side-by-side (sxs): open the flex row on the first sxs table, close it
        # when a non-sxs table follows — or when an sxs table carries a
        # DIFFERENT group id (sxs=<id>), which closes the current row and
        # starts a new one (the detail pages' time trio vs Protocol/AV pair);
        # each sxs table's <h2>+wrapper live in one flex column (.sxscol) so
        # the heading stays above its own table.
        # A switch-group SIBLING (same switch=KEY as the column's current
        # table, same sxs row) continues inside the open column instead of
        # opening a second one — one column per switch group (2026-09-05).
        col_cont = (this_sxs && col_open && this_swkey != "" && this_swkey == col_swkey && grp_open && grp_id == this_sxsgrp)
        if (!col_cont) close_col()
        if (this_sxs && grp_open && grp_id != this_sxsgrp) { printf "</div>\n"; grp_open = 0 }
        if (this_sxs && !grp_open)      { printf "<div class=\"sxs\">\n"; grp_open = 1; grp_id = this_sxsgrp }
        else if (!this_sxs && grp_open) { printf "</div>\n"; grp_open = 0 }
        if (this_sxs && !col_cont) { printf "<div class=\"sxscol\">\n"; col_open = 1; col_swkey = this_swkey }
        # report pages (droptitle=1): drop the FIRST table's title (redundant
        # with the page <h1>); detail pages keep every section title, and an
        # sxs table always keeps its heading (it labels one column of a pair)
        if (heading != "" && (droptitle != "1" || ntables != 1 || this_sxs || keep_heading))
            printf "<h2%s>%s</h2>\n", (heading_id != "" ? " id=\"" heading_id "\"" : ""), esc(heading)
        table_open = 1; table_printed = 0; hdr_done = 0
        subcol = 0; subacc = 0
        nhead = 0; nkind = 0; split("", HEADC); split("", KINDS)
        ngh = 0; split("", GHC)
    }
    else if (dir == "HEAD") {
        split_cells()
        nhead = NCELL
        for (i = 1; i <= NCELL; i++) HEADC[i] = CELL[i]
        # the column holding a SUBSCRIPTION NAME, for the row tints above:
        # "Subscription", "Subscription (as logged by the server)" — but never
        # the plural "Subscriptions", which is a COUNT — plus deploy-errors'
        # mixed column, whose rows name an account or a subscription and are
        # looked up in both caches.
        for (i = 1; subcol == 0 && i <= NCELL; i++) {
            if (HEADC[i] ~ /^Subscription($| \()/) subcol = i
            else if (HEADC[i] == "Account or subscription") { subcol = i; subacc = 1 }
        }
    }
    else if (dir == "GHEAD") {
        # the optional GROUP banner row above HEAD: each cell is a group
        # label, optionally prefixed @{colspan=N,class=...} (Top view IDs)
        split_cells()
        ngh = NCELL
        for (i = 1; i <= NCELL; i++) GHC[i] = CELL[i]
    }
    else if (dir == "KIND") {
        split_cells()
        nkind = NCELL
        for (i = 1; i <= NCELL; i++) KINDS[i] = CELL[i]
    }
    else if (dir == "RECALC") {
        split_cells()
        rct = ""
        for (i = 1; i <= NCELL; i++) rct = rct " " CELL[i]
        tattr = tattr " data-recalc=\"" substr(rct, 2) "\""
    }
    else if (dir == "ROW" || dir == "TOTAL") {
        emit_header()
        split_cells()
        is_total = (dir == "TOTAL")
        # @data:NAME=VALUE cells become data-NAME attrs on the <tr>; the rest
        # are the real cells, matched against KINDS by position
        attrs = ""; nreal = 0; split("", REAL); rowdrill = 0; fattr = ""; pattr = ""
        for (i = 1; i <= NCELL; i++) {
            c = CELL[i]
            if (substr(c, 1, 6) == "@data:") {
                dcell = substr(c, 7)
                p = index(dcell, "=")
                if (p == 0) { nm = dcell; vv = dcell }
                else { nm = substr(dcell, 1, p - 1); vv = substr(dcell, p + 1) }
                # an attribute NAME failing the allowlist means the cell was
                # data wearing the prefix — keep it as a literal real cell
                # (column alignment intact), emit no attribute
                if (!ok_dname(nm)) { REAL[++nreal] = c; continue }
                # data-href is a NAVIGATION target (report.js bindRowlink
                # assigns it to location.href): the same URL test as @{href=}
                # — a raw "@data:href=javascript:…" cell stays a literal cell
                if (nm == "href" && !ok_href(vv)) { REAL[++nreal] = c; continue }
                # a page with NO date filter (dropbuckets=1: CUR_DATES empty,
                # so no report-dates meta) has no consumer for the buckets
                # re-aggregation payload — drop it instead of shipping it
                if (dropbuckets && nm == "buckets") continue
                # an EMPTY drill payload (2026-09-29: the server Top view's
                # SSHD row, no Error/Warning line to show) is no drill — the
                # row looked clickable and expanded nothing
                # — and so is ANY empty drill list (2026-09-29 audit: ~32k empty
                # coreids-* / drill-cell-* attributes, bound by nothing)
                if (vv == "" && (nm == "loglines" || nm == "coreids" || index(nm, "coreids-") == 1 || index(nm, "drill-cell-") == 1)) continue
                # a per-CELL list report.js can never bind (2026-09-29 audit):
                # coreids-<key> binds through the TABLE's drillcols=<key>:<col>
                # (the Entities pages — a group entity_hide_groups dropped
                # took its key with it, the Subscriptions views have no ferr
                # cell) — only failed / processed bind by the cell CLASS (below)
                if (index(nm, "coreids-") == 1 && nm != "coreids-failed" && nm != "coreids-processed" && !(substr(nm, 9) in DCK)) continue
                # srv: failed.sh's .rpt-level marker (publish_lib reads it from
                # the .rpt) — no page reader
                if (nm == "srv") continue
                # seen: the seen / never-seen flag only a SEENROWS table reads
                # (its row tint + the date filter's re-tint); anywhere else it
                # is the writers' own marker (the Entities views, the cross
                # references — 2026-09-29 audit: ~7,700 unread attributes)
                if (nm == "seen" && index(tattr, "data-seenrows=") == 0) continue
                ad = " data-" nm "=\"" esc(vv) "\""
                # coreids-failed / -processed bind only when the row has ONE
                # such cell (report.js setupExpandable) — held apart until the
                # cells are rendered
                if (nm == "coreids-failed")    { fattr = ad; attrs = attrs "\001F"; continue }
                if (nm == "coreids-processed") { pattr = ad; attrs = attrs "\001P"; continue }
                attrs = attrs ad
                # a ROW-LEVEL drill (the whole row is click-to-expand): an
                # entity cell in it renders as plain name + a detail-page
                # link ICON — a whole-cell link would fight the row click.
                # (coreids-failed/-processed bind their Error/OK CELLS only,
                # so those rows keep the normal whole-cell name links.)
                if (nm == "loglines" || nm == "coreids") rowdrill = 1
            } else REAL[++nreal] = c
        }
        # start-empty tables: pre-stamp every data row hidden (data-shide) so
        # the first paint is already empty — see the TABLE startempty modifier
        if (start_empty && !is_total) attrs = attrs " data-shide=\"1\""
        # The server pages' subscription row tints (subtint=1): the row carries
        # the RESULT colour of the subscription it names — green delivering,
        # red failing, orange never seen — the same tint
        # the entity pages give it. A row the report tinted itself is left
        # alone, and a name the base cache does not know (a server-logged name
        # that is not configured) simply stays untinted. The Error/OK CELLS
        # keep their own background: the restint CSS excludes .failed/.processed.
        if (nsubres > 0 && subcol > 0 && !is_total && attrs !~ / data-res=/ && subcol <= nreal) {
            sn = REAL[subcol]; sub(/^@\{[^}]*\}/, "", sn)
            sr = ""
            if (sn != "") {
                sk = toupper(sn)
                sr = (("s" US sk) in SUBRES) ? SUBRES["s" US sk] : ""
                if (sr == "" && subacc && (("a" US sk) in SUBRES)) sr = SUBRES["a" US sk]
            }
            if (sr != "") attrs = attrs " data-res=\"" sr "\""
        }
        # Detail-page Subscription breakdown: a subscription whose RESULT is
        # "not seen" (orange) tints the WHOLE row —
        # the green/red ones keep just the cell tint. RESM loads on detail pages.
        if (!is_total && HEADC[1] == "Subscription" && attrs !~ / data-res=/ && nreal >= 1) {
            rn = REAL[1]; sub(/^@\{[^}]*\}/, "", rn); rk = "subscriptions" US toupper(rn)
            rr = RESM[rk]
            if (rr == "orange") attrs = attrs " data-res=\"" rr "\""
        }
        rowcells = ""; nfc = 0; npc = 0
        for (i = 1; i <= nreal; i++) {
            gsephit = 0; if ((i - 1) in gsepset) gsephit = 1
            cell((i <= nkind && KINDS[i] != "" ? KINDS[i] : "text"),
                 (i <= nhead && HEADC[i] == "Direction" ? dirfold(REAL[i]) : REAL[i]), is_total)
            rowcells = rowcells CELLOUT
            ccl = " " CELLCLS " "
            if (ccl !~ / z /) { if (ccl ~ / failed /) nfc++; if (ccl ~ / processed /) npc++ }
        }
        # the held coreids-failed / -processed lists: kept only when the row
        # has exactly ONE non-blank Error (OK) cell — the one report.js binds;
        # a both-direction row (two Error cells sharing one combined list) or
        # a row whose only Error cell is a blank 0 ships nothing (2026-09-29)
        attrs = splice(attrs, "\001F", (nfc == 1 && !is_total) ? fattr : "")
        attrs = splice(attrs, "\001P", (npc == 1 && !is_total) ? pattr : "")
        printf "<tr%s%s>%s</tr>\n", (is_total ? " class=\"total\"" : ""), attrs, rowcells
    }
    # NOTE/LINK/SUMMARY are FULL-WIDTH blocks: also close an open sxs flex
    # row, or they render as a flex item BESIDE the last side-by-side table
    # (a NOTE the no-prose rule suppresses is NO block at all — 2026-09-29: it
    # still closed the flex row, splitting the failure heatmap's side-by-side
    # By hour / By weekday pair)
    else if (dir == "NOTE")    { if (!noprose) { close_table(); close_col(); if (grp_open) { printf "</div>\n"; grp_open = 0 }; printf "<p class=\"note\">%s</p>\n", prose(rest) } }
    else if (dir == "LINK")    { close_table(); close_col(); if (grp_open) { printf "</div>\n"; grp_open = 0 }; split_cells(); if (ok_href(CELL[1])) printf "<p class=\"report-link\"><a href=\"%s\"%s>%s</a></p>\n", esc(CELL[1]), (CELL[1] ~ /^https?:\/\// ? " target=\"_blank\" rel=\"noopener\"" : ""), esc(CELL[2]); else printf "<p class=\"report-link\">%s</p>\n", esc(CELL[2]) }
    else if (dir == "SUMMARY") { close_table(); close_col(); if (grp_open) { printf "</div>\n"; grp_open = 0 }; printf "<div class=\"summary\">%s</div>\n", esc(rest) }
    else if (dir == "FOOT")    close_table()
    # DESC, META and anything unknown: not rendered
}

END { close_table(); close_col(); if (grp_open) { printf "</div>\n"; grp_open = 0 } }
