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
            # blue = a server-log-only entity (bin/build/seen-in-server-log.sh); a real 4th
            # result value, tinted like green/orange/red.
            if (nr >= 3 && (rmp[3] == "green" || rmp[3] == "orange" || rmp[3] == "red" || rmp[3] == "blue"))
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
            if (ns >= 3 && stp[1] != "" && (stp[3] == "green" || stp[3] == "orange" || stp[3] == "red" || stp[3] == "blue")) {
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
# (escaped, unlinked, visibly carrying its @-prefix).
function ok_class(s)   { return s ~ /^[A-Za-z0-9_ -]+$/ }
function ok_colspan(s) { return s ~ /^[0-9]+$/ }
# link=/alink targets are wrapped as dlink TARGET ".html": site-local
# relative paths only — must start alphanumeric (no leading / or .), no
# path traversal, no scheme colon, no quote/angle/entity characters
function ok_target(s)  { return s ~ /^[A-Za-z0-9][A-Za-z0-9\/_. -]*$/ && index(s, "..") == 0 }
# href= is used verbatim (esc()-quoted): a relative URL, or absolute http(s)
# — never a bare scheme like javascript:/data:, never protocol-relative
function ok_href(s)    { return s !~ /^\/\// && (s !~ /^[A-Za-z][A-Za-z0-9+.\-]*:/ || s ~ /^https?:\/\//) }
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
        if (k == "numsep") thc = "num sep"
        else if (k == "num" || k == "numfailed" || k == "numprocessed" || k == "numwarn" || k == "numerr" || k == "numok") thc = "num"
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
    if (table_sxs) { printf "</div>\n"; table_sxs = 0 }   # close this table's .sxscol column
    table_open = 0
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
              bad, cv) {
    cls = ""; sp = ""; text = ""; cc = ""; link = ""; nolink = 0; rawhref = ""; maskv = ""
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
            }
        }
        # any invalid metadata: the block was data after all — render the
        # whole cell as literal text, nothing from it shapes markup
        if (bad) { cc = ""; sp = ""; link = ""; nolink = 0; rawhref = ""; maskv = ""; text = raw }
    } else text = raw
    if (!total) {
        if (kind == "num") cls = "num"
        else if (kind == "failed") cls = "failed"
        else if (kind == "processed") cls = "processed"
        else if (kind == "numfailed") cls = "num failed"
        else if (kind == "numprocessed") cls = "num processed"
        # tint-only variants: the SAME red/green as failed/processed but
        # WITHOUT those class names, so a row with several Error/OK column
        # pairs (Top view IDs) keeps its drill bound to the one failed/
        # processed pair (report.js binds only when the outcome maps to ONE cell)
        else if (kind == "numerr") cls = "num errc"
        else if (kind == "numok") cls = "num okc"
        else if (kind == "numwarn") cls = "num warn"
        else if (kind == "numsep") cls = "num sep"
        else if (kind == "srv") cls = "srv"
        else if (kind == "file") cls = "file"
        else if (kind == "lines" || kind == "clines") cls = "lines"
        if (kind == "bar") {
            if (text ~ /^[0-9]+$/) { w = int((text + 2) / 5) * 5; if (w > 100) w = 100 }
            else w = 0
            printf "<td class=\"bar w%d\"><span></span></td>", w
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
    if (maskv != "") text = text "<span class=\"mask\">" esc(maskv) "</span>"
    if (!total && kind == "mono") text = "<code>" text "</code>"
    # KIND pre: a raw log LINE, kept verbatim inside <pre> — the logged spacing
    # survives and the line does NOT wrap (see td pre in style.css), so one
    # logged line stays one rendered line and its cell scrolls with the table.
    # Used by the failed-file error pages, whose server-log table shows the
    # message exactly as logged, JSON payload and all, not a truncated one-liner.
    if (!total && kind == "pre") text = "<pre>" text "</pre>"
    # KIND ip: a whitelist IP — mono rendering + the _white.tsv result tint
    if (!total && kind == "ip") {
        text = "<code>" text "</code>"
        r = RESM["white" US toupper(rawtext)]
        if (r != "") cls = (cls != "" ? cls " res-" r : "res-" r)
    }
    # a `lines` cell holds \x1f-separated lines; render each on its own row
    if (kind == "lines") gsub(US, "<br>", text)
    # `clines` = a COLLAPSIBLE lines cell: 3+ lines render collapsed to the
    # first and last line with an ellipsis between (the middle lines sit in a
    # CSS-hidden span.cm, the ellipsis in span.ce); class `clps` on the td is
    # the collapsed state, report.js toggles `open` on click (style.css swaps
    # the two spans). 1-2 lines render like a plain `lines` cell.
    if (!total && kind == "clines") {
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
        # the entity's own RESULT tint (detail pages: resmaps loaded); a
        # server-log-only entity carries result=blue in the base cache
        r = RESM[sd US toupper(rawtext)]
        if (r != "") cls = (cls != "" ? cls " res-" r : "res-" r)
        # the partner-group icon (grouped partners only): an extra anchor after
        # the name — the cell then holds TWO links and drops `cl`.
        gu = ""
        if (kind == "ptn" && (toupper(rawtext) in GRP)) gu = dlink "partner-groups/" GRP[toupper(rawtext)] ".html"
        extra = (gu != "" ? gicon(gu) : "")
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
    else if (!total && link != "") { text = "<a href=\"" dlink link ".html\">" text "</a>"; cls = (cls != "" ? cls " cl" : "cl") }
    # @{href=URL}: an explicit page-relative link, used VERBATIM (no dlink
    # prefix, no .html suffix) — e.g. the Top view date cells -> the per-day
    # pages. Wraps the whole cell like link=.
    # (allowed on TOTAL rows too — the seen-in-server-log matrix links its
    # column totals to their cell pages)
    if (rawhref != "") { text = "<a href=\"" esc(rawhref) "\">" text "</a>"; cls = (cls != "" ? cls " cl" : "cl") }
    # a tinted count cell whose value is 0: show nothing, drop the tint (warn
    # included since 2026-08 — the logons Key failures/Locked ask; an empty
    # warn cell untints via td.warn:empty)
    if ((" " cls " ") ~ / (failed|processed|errc|okc|warn) / && rawtext == "0") { text = ""; cls = cls " z" }
    printf "<td%s%s>%s</td>", sp, (cls != "" ? " class=\"" cls "\"" : ""), text
}

{
    dir = $1
    rest = (NF > 1 ? substr($0, length($1) + 2) : "")

    if (dir == "TITLE")         printf "<h1>%s</h1>\n", esc(rest)
    else if (dir == "SUBTITLE") printf "<p class=\"subtitle\">%s</p>\n", esc(rest)
    else if (dir == "INTRO")    printf "<p class=\"range\">%s</p>\n", prose(rest)
    else if (dir == "ALERT") {
        # optional cells 2+3 append a LINK to the banner (href, text) — the
        # detail pages' after-last-transfer banner points at the page's own
        # "Server log error" section this way. A single-cell ALERT renders
        # exactly as before.
        split_cells()
        if (NCELL >= 3 && CELL[2] != "")
            printf "<p class=\"alert\">%s<a href=\"%s\">%s</a></p>\n", bold(esc(CELL[1])), esc(CELL[2]), esc(CELL[3])
        else printf "<p class=\"alert\">%s</p>\n", bold(esc(rest))
    }
    # WARN is ALERT's amber sibling: same banner, lower severity. ALERT is the
    # RUNTIME register (errors in the server log); WARN is the CONFIGURATION
    # register, so it wears the site's warning colour (orange) rather than red.
    else if (dir == "WARN")     printf "<p class=\"alert warn\">%s</p>\n", bold(esc(rest))
    else if (dir == "LOGCARD") {
        # LOGCARD <date time> <message> — a card holding one raw log line: the
        # server-log evidence under a blue (server-log-only) detail page's INTRO
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
        # per-day payload, and a data-thr box retints); the FIRST plain cell
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
        tclass = ""; tattr = ""; start_empty = 0; this_sxs = 0; this_sxsgrp = "1"; heading_id = ""; keep_heading = 0; heading_period = ""; split("", gsepset)
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
            else if (mi == "totaltop")   tattr = tattr " data-total-top=\"1\""
            else if (mi == "datereset")  tattr = tattr " data-date-reset=\"1\""
            else if (mi == "nofilter")   tattr = tattr " data-nofilter=\"1\""
            else if (index(mi, "pfnoun=") == 1) tattr = tattr " data-pf-noun=\"" esc(substr(mi, 8)) "\""   # the noun setupStatFilter puts in the recomputed total row
            else if (mi == "seenrows")   tattr = tattr " data-seenrows=\"1\""
            else if (mi == "restint")    tattr = tattr " data-restint=\"1\""   # rows tint by their data-res RESULT even when seen (beats the seenrows green)
            else if (mi == "rowlink")    tattr = tattr " data-rowlink=\"1\""   # the WHOLE row opens its target (report.js setupIndexRows): the row's own @data:href, else its first link
            else if (index(mi, "seenmode=") == 1) tattr = tattr " data-seenmode=\"" substr(mi, 10) "\""
            else if (index(mi, "seenword=") == 1) tattr = tattr " data-seenword=\"" substr(mi, 10) "\""
            else if (mi == "heat")       tattr = tattr " data-heat=\"1\""
            else if (mi == "esearch")    tattr = tattr " data-esearch=\"1\""
            else if (index(mi, "noagg=") == 1)    tattr = tattr " data-noagg=\"" substr(mi, 7) "\""
            else if (index(mi, "pct=") == 1)      tattr = tattr " data-pct=\"" substr(mi, 5) "\""
            # gsep=<col,col,...>: 0-based data columns that START a column
            # GROUP — their th/td cells get class "gsep" (a left divider +
            # extra padding, style.css). Pairs with the GHEAD banner row.
            else if (index(mi, "gsep=") == 1)     { n2g = split(substr(mi, 6), GSA, ","); for (g2 = 1; g2 <= n2g; g2++) gsepset[GSA[g2] + 0] = 1 }
            else if (index(mi, "pager=") == 1)    tattr = tattr " data-pager=\"" substr(mi, 7) "\""
            # zerohide=<m>: while the date range is NARROWED, hide a data row
            # whose re-aggregated bucket metric <m> sums to 0 — a "0 of this
            # page's subject in the window" row says nothing (report.js
            # recalcTable; the full-range restore brings every row back)
            else if (index(mi, "zerohide=") == 1) tattr = tattr " data-zerohide=\"" substr(mi, 10) "\""
            # topsel=<N>: a top-N table whose rows are the CANDIDATE set (each
            # with @data:date + @data:val, value-descending; rows past N baked
            # @data:dhide=1) — report.js recalcTopsel re-picks the visible N
            # for the selected date range
            else if (index(mi, "topsel=") == 1)   tattr = tattr " data-topsel=\"" substr(mi, 8) "\""
            # fold=<res>|<label>: rows with that data-res collapse behind one
            # summary row at load (report.js setupRowFold; {n} = folded count)
            else if (index(mi, "fold=") == 1)     tattr = tattr " data-fold=\"" esc(substr(mi, 6)) "\""
            else if (index(mi, "anchor=") == 1)   heading_id = substr(mi, 8)   # id on the <h2> — an in-page link target
            # period=<text>: the DATE PERIOD the table aggregates, appended to
            # the <h2> as a muted span — report.js rewrites every .h2period to
            # the selected From/To on a range change and restores this baked
            # text at the full range
            else if (index(mi, "period=") == 1)   heading_period = substr(mi, 8)
            else if (mi == "keephead")   keep_heading = 1   # keep the heading even on the FIRST table of a report page (droptitle)
        }
        # side-by-side (sxs): open the flex row on the first sxs table, close it
        # when a non-sxs table follows — or when an sxs table carries a
        # DIFFERENT group id (sxs=<id>), which closes the current row and
        # starts a new one (the detail pages' time trio vs Protocol/AV pair);
        # each sxs table's <h2>+wrapper live in one flex column (.sxscol) so
        # the heading stays above its own table.
        if (this_sxs && grp_open && grp_id != this_sxsgrp) { printf "</div>\n"; grp_open = 0 }
        if (this_sxs && !grp_open)      { printf "<div class=\"sxs\">\n"; grp_open = 1; grp_id = this_sxsgrp }
        else if (!this_sxs && grp_open) { printf "</div>\n"; grp_open = 0 }
        if (this_sxs) printf "<div class=\"sxscol\">\n"
        table_sxs = this_sxs
        # report pages (droptitle=1): drop the FIRST table's title (redundant
        # with the page <h1>); detail pages keep every section title, and an
        # sxs table always keeps its heading (it labels one column of a pair)
        if (heading != "" && (droptitle != "1" || ntables != 1 || this_sxs || keep_heading))
            printf "<h2%s>%s%s</h2>\n", (heading_id != "" ? " id=\"" heading_id "\"" : ""), esc(heading), \
                (heading_period != "" ? " <span class=\"h2period\">— " esc(heading_period) "</span>" : "")
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
        attrs = ""; nreal = 0; split("", REAL); rowdrill = 0
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
                # a page with NO date filter (dropbuckets=1: CUR_DATES empty,
                # so no report-dates meta) has no consumer for the buckets
                # re-aggregation payload — drop it instead of shipping it
                if (dropbuckets && nm == "buckets") continue
                attrs = attrs " data-" nm "=\"" esc(vv) "\""
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
        # red failing, orange never seen, blue server-log only — the same tint
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
        # "not seen" (orange) or "server-log only" (blue) tints the WHOLE row —
        # the green/red ones keep just the cell tint. RESM loads on detail pages.
        if (!is_total && HEADC[1] == "Subscription" && attrs !~ / data-res=/ && nreal >= 1) {
            rn = REAL[1]; sub(/^@\{[^}]*\}/, "", rn); rk = "subscriptions" US toupper(rn)
            rr = RESM[rk]
            if (rr == "orange" || rr == "blue") attrs = attrs " data-res=\"" rr "\""
        }
        printf "<tr%s%s>", (is_total ? " class=\"total\"" : ""), attrs
        for (i = 1; i <= nreal; i++) {
            gsephit = 0; if ((i - 1) in gsepset) gsephit = 1
            cell((i <= nkind && KINDS[i] != "" ? KINDS[i] : "text"),
                 (i <= nhead && HEADC[i] == "Direction" ? dirfold(REAL[i]) : REAL[i]), is_total)
        }
        printf "</tr>\n"
    }
    # NOTE/LINK/SUMMARY are FULL-WIDTH blocks: also close an open sxs flex
    # row, or they render as a flex item BESIDE the last side-by-side table
    else if (dir == "NOTE")    { close_table(); if (grp_open) { printf "</div>\n"; grp_open = 0 }; printf "<p class=\"note\">%s</p>\n", prose(rest) }
    else if (dir == "LINK")    { close_table(); if (grp_open) { printf "</div>\n"; grp_open = 0 }; split_cells(); printf "<p class=\"report-link\"><a href=\"%s\" target=\"_blank\" rel=\"noopener\">%s</a></p>\n", esc(CELL[1]), esc(CELL[2]) }
    else if (dir == "SUMMARY") { close_table(); if (grp_open) { printf "</div>\n"; grp_open = 0 }; printf "<div class=\"summary\">%s</div>\n", esc(rest) }
    else if (dir == "FOOT")    close_table()
    # DESC, META and anything unknown: not rendered
}

END { close_table(); if (grp_open) { printf "</div>\n"; grp_open = 0 } }
