#!/usr/bin/env bash
#
# bin/server/arlist.sh — the shared body of the AR-LINE LIST server reports
# (sourced by bin/server/reports/{could-not-send,publish-failed,
# post-client-action}.sh, never run): one row per matched Advanced Routing
# server-log line, NEWEST FIRST, capped (user rule, 2026-09-12) at
# AR_MAXROWS rows on the report and AR_MAXPER rows per entity — the newest
# ones on both counts — the entity linked to its detail page. The INTRO and
# the TOTAL always say how many lines the log really holds.
#
# An Advanced Routing line reads  AR<code>: [<first>] [<second>]  <body>
# — the first bracket is <account>@<login> on the ARRC (receive) lines and
# SECURETRANSPORT on the routing ones, the second bracket the ROUTE = the
# subscription (empty on some ARRC lines). ar_parse() splits it into B1, B2
# and BODY for the caller's extraction snippet.
#
# The caller (which sourced bin/server/lib.sh) sets, then calls arlist_run:
#   AR_BASENAME    the report basename -> $REPORTS_DIR/<basename>.rpt
#   AR_TITLE  AR_DESC  AR_KEYWORDS
#   AR_INTRO_NONE  the INTRO when no line matched
#   AR_INTRO       printf format, %s x6: lines, entities, days, maxrows, maxper, shown
#   AR_NOTE        printf format, %s x2: maxrows, maxper
#   AR_ENTITY      subscription | account — the second column, its link, the cap
#   AR_FILE        1 = a File column after the entity (else none)
#   AR_MATCH       awk regex the raw message must match (the cheap prefilter)
#   AR_EXTRACT     awk statements run per AR line with m (the message), B1, B2,
#                  BODY set: must set ent (the entity name, "" = skip) and fn
#                  (the File cell, "" = none); basename() and ar_brace() help
#   AR_MAXROWS (1000)  AR_MAXPER (10)   optional
#
arlist_run() {
    local OUT="$REPORTS_DIR/$AR_BASENAME.rpt"
    local MAXROWS=${AR_MAXROWS:-1000} MAXPERSUB=${AR_MAXPER:-10}
    local ROSTER   # the entity roster (transfer .rpt): the names with a detail page
    if [ "$AR_ENTITY" = account ]; then ROSTER="$TRANSFER_REPORTS/account.rpt"; else ROSTER="$TRANSFER_REPORTS/subscription.rpt"; fi

    shopt -s nullglob
    local files=("$INPUT_DIR"/*.csv)
    shopt -u nullglob
    if [ ${#files[@]} -eq 0 ]; then
        echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
        rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
        exit 0
    fi
    ensure_parsed
    skip_if_fresh "$OUT" "${BASH_SOURCE[1]}" "${BASH_SOURCE[0]}" "$ROSTER"   # [1] = the calling report script, [0] = this library
    echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

    # the known-entity roster ("KS<TAB>name", fed in ahead of the cache): a
    # logged name resolves to its detail page — exact, else (subscriptions)
    # the unique known name it prefixes, else the raw name (alink resolves
    # through the comprehensive slugmap at render time, so a miss renders
    # unlinked)
    known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
        [ -f "$2" ] || return 0
        awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
    }
    # One pass over the matching lines. Every matched line comes out as a
    # finished ROW behind a sort prefix (the shell only sorts, caps and cuts —
    # a bash read over TAB fields would collapse empty ones):
    #   LIN <TAB> sortkey <TAB> entity <TAB> ROW …
    #   TOT <TAB> lines <TAB> entities <TAB> days
    local agg
    agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" -v ENT="$AR_ENTITY" -v WITHFILE="${AR_FILE:-0}" -v MATCH="$AR_MATCH" "$RENAMES_AWK"'
        # RENAMES: a server line keeps the name that was current when it was
        # written, so fold it to the CURRENT one before matching the roster
        # (which carries current names) and DISPLAY the folded name
        function entcanon(t,   k, hits, full, c) {
            if (ENT == "account") return t
            sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", t)   # the extended transfer-site spellings
            c = rn_canon_pfx(t)
            if (c in ksite) return c
            hits = 0
            for (k in ksite) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) { hits = 0; break } }
            return hits == 1 ? full : c
        }
        function entlink(t) { return "@{alink=" (ENT == "account" ? "accounts" : "subscriptions") "/" t "}" }
        function ar_parse(m,   p, q, r) {   # AR<code>: [B1] [B2]  BODY -> 1 when the line has the shape
            if (m !~ /^AR[A-Z]*[0-9]*: \[/) return 0
            p = index(m, "["); r = substr(m, p + 1); q = index(r, "]"); if (q == 0) return 0
            B1 = substr(r, 1, q - 1); r = substr(r, q + 1); sub(/^ */, "", r)
            if (substr(r, 1, 1) != "[") return 0
            r = substr(r, 2); q = index(r, "]"); if (q == 0) return 0
            B2 = substr(r, 1, q - 1); BODY = substr(r, q + 1); sub(/^ */, "", BODY)
            return 1 }
        function ar_brace(s) { if (!match(s, /\{[^}]*\}/)) return ""; return substr(s, RSTART + 1, RLENGTH - 2) }
        function basename(p,   n, P) { n = split(p, P, "/"); return (P[n] != "" ? P[n] : p) }
        BEGIN { rn_load(RNF) }
        $1 == "KS" { ksite[$2] = 1; next }                       # the known-entity list (first input)
        $5 !~ MATCH { next }
        {
            m = $5
            if (!ar_parse(m)) next
            ent = ""; fn = ""
            '"$AR_EXTRACT"'
            if (ent == "") next
            d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
            e = entcanon(ent)
            nl++; if (!(e in seen)) { seen[e] = 1; ne++ }
            if (!(d in dseen)) { dseen[d] = 1; nd++ }
            printf "LIN\t%s %s\t%s\tROW\t%s %s\t%s%s%s\n", d, $2, e, d, substr($2, 1, 8), entlink(e), e, (WITHFILE == 1 ? "\t" fn : "")
        }
        END { printf "TOT\t%d\t%d\t%d\n", nl+0, ne+0, nd+0 }
    ' <(known_names KS "$ROSTER") "$PARSED")

    local n_lines n_ents n_days
    IFS=$'\t' read -r _ n_lines n_ents n_days <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t' || printf 'TOT\t0\t0\t0\n')"
    n_lines=${n_lines:-0}; n_ents=${n_ents:-0}; n_days=${n_days:-0}

    # newest first (the sortkey = date + full time), then the two caps in that
    # order: the first MAXPERSUB rows met per entity are its newest, the first
    # MAXROWS overall the newest of all
    local TAB; TAB=$(printf '\t')
    lin_rows() {
        printf '%s\n' "$agg" | grep $'^LIN\t' | sort -t"$TAB" -k2,2r \
            | awk -F'\t' -v PS="$MAXPERSUB" -v MX="$MAXROWS" '{ if (++n[$3] > PS) next; if (++t > MX) exit; print }' | cut -f4-
    }
    local n_shown=0
    if [ "$n_lines" -gt 0 ]; then n_shown=$(lin_rows | grep -c $'^ROW\t' || true); fi

    local ecol ncol
    if [ "$AR_ENTITY" = account ]; then ecol="Account"; else ecol="Subscription"; fi
    ncol=2; [ "${AR_FILE:-0}" = 1 ] && ncol=3
    {
        printf 'TITLE\t%s\n' "$AR_TITLE"
        printf 'DESC\t%s\n' "$AR_DESC"
        printf 'KEYWORDS\t%s\n' "$AR_KEYWORDS"
        if [ "$n_lines" -eq 0 ]; then printf 'INTRO\t%s\n' "$AR_INTRO_NONE"
        else printf "INTRO\t$AR_INTRO\n" "$n_lines" "$n_ents" "$n_days" "$MAXROWS" "$MAXPERSUB" "$n_shown"; fi

        printf 'TABLE\t%s\twide\tpager=100\n' "$AR_TITLE"
        if [ "${AR_FILE:-0}" = 1 ]; then
            printf 'HEAD\tDate & time\t%s\tFile\n' "$ecol"
            printf 'KIND\ttext\tmono\tfile\n'
        else
            printf 'HEAD\tDate & time\t%s\n' "$ecol"
            printf 'KIND\ttext\tmono\n'
        fi
        if [ "$n_lines" -gt 0 ]; then lin_rows
        else printf 'ROW\t@{colspan=%s}No "%s" line in this data window.\n' "$ncol" "$AR_TITLE"; fi
        printf 'TOTAL\t@{colspan=%s}%s row(s) shown — %s line(s) in the log, %s %s(s), %s day(s)\n' "$ncol" "$n_shown" "$n_lines" "$n_ents" "$AR_ENTITY" "$n_days"
        printf "NOTE\t$AR_NOTE\n" "$MAXROWS" "$MAXPERSUB"
        printf 'SUMMARY\tLines: %s  |  %ss: %s  |  Days: %s  |  Shown: %s\n' "$n_lines" "$ecol" "$n_ents" "$n_days" "$n_shown"
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

    echo "Data written to $OUT ($n_lines line(s), $n_ents $AR_ENTITY(s), $n_shown shown)." >&2
}
