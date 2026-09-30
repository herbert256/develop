# uc-status-lib.sh — SOURCED by uc1-status.sh / uc3-status.sh / uc4-status.sh
# (2026-09-30, the lean round: the three carried the same ~120-line skeleton).
# What differs per use case stays in each script: the server SIGNAL block
# (which lines count, and as what), the A / TOT columns and the table spec.
# Shared here:
#   ucs_setup UCn   the paths (OUT, SUBB, FILESC, RFLIP, SLOTS_OUT, UCDF),
#                   LINK_AWK, the input-file banner; RFLIP -> /dev/null on a
#                   first build (result.sh not run yet — no flips)
#   UCS_AWK         awk text injected in front of each program (pass -v UC=UCn
#                   and the sb / tf / rfv / ucdf file variables): the derived
#                   use-case map, clean() / span() / drill() / key(), the
#                   roster, red-flip and Files rules, ucs_stc() and the
#                   per-HOUR sidecar walker ucs_walk()
#   ucs_rows NC     the A lines (sorted) -> ROW lines; NC = the count columns
#                   between "Last file" and "Last log"
#   ucs_none UCn    the "no subscriptions configured" exit
#   ucs_stats UCn   the five STAT boxes
#   nz0             a count cell shows blank, never 0

ucs_setup() {   # $1 = UC1 | UC3 | UC4
    local uc=$1 lc
    lc=$(printf '%s' "$uc" | tr 'A-Z' 'a-z')
    mkdir -p "$REPORTS_DIR"
    OUT="$REPORTS_DIR/$lc-status.rpt"
    SUBB="$CONFIG_BASE/_subscriptions.tsv"            # name <TAB> direction <TAB> result
    FILESC="$TRANSFER_CACHE/_files.tsv"               # col 12 = subscription, 2 = outcome
    # result.sh's red-flip sidecar: subscriptions flipped green -> red by ring
    # Error/Warn evidence newer than their last transfer (or the UC3
    # cannot-connect red), name + evidence stamp + SINCE. The per-hour walker
    # applies the same flip so its last row matches the STATs.
    RFLIP="$DATA/colour/_redflip.tsv"
    # The per-HOUR status sidecar for the Overview's UCn status card — written
    # HERE because the classification lives here; the Overview must never
    # re-derive it (cf. pesit-slots.tsv). date <TAB> hour <TAB> the FOUR
    # statuses in STACK order: ok, ok-error, error, not-seen. One hour divides
    # 4/6/12/24 exactly, so the Overview re-buckets by taking the LAST hour of
    # each — a status is a STATE, carried forward, never summed.
    SLOTS_OUT="$REPORTS_DIR/$lc-slots.tsv"
    # the DERIVED use case map (bin/flow-manager.sh): a subscription with no UC
    # name prefix whose pattern + movement say UCn (the production hybrid
    # flows) is a UCn flow here exactly like a UCn_-named one (2026-08-31
    # audit — the roster read the name alone and silently dropped them)
    UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
    # sublink() prefixes an @{alink=subscriptions/<name>} UNCONDITIONALLY — the
    # renderer resolves it through the details slugmap and drops the link when
    # the name has no page, so a never-seen subscription still links.
    LINK_AWK="$SRV_SUBLINK_AWK"   # bin/server/lib.sh (2026-09-30)
    shopt -s nullglob
    files=("$INPUT_DIR"/*.csv)
    shopt -u nullglob
    if [ ${#files[@]} -eq 0 ]; then
        echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
    fi
    [ -f "$RFLIP" ] || RFLIP=/dev/null   # first build: result.sh not run yet — no flips
    echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2
}

UCS_AWK='
    BEGIN { while ((getline ucl < ucdf) > 0) { nuc = split(ucl, uca, "\t"); if (nuc >= 2 && uca[2] == UC) ucd[toupper(uca[1])] = 1 } close(ucdf) }
    # the logged site -> the clean subscription name (as the transfer parser does)
    function clean(s) { sub(/_(SS?|C)CP_.*$|_[A-Za-z0-9]+_(SERVER|CLIENT)_.*$/, "", s); return s }
    function span(h) { if (hmin == "" || h < hmin) hmin = h; if (h > hmax) hmax = h }
    # the row drill: its problem lines (E) newest first, then its other lines
    # (L) newest first, 10 in all — so the failures a verdict classifies
    # (subscription-verdict.awk nextmove) always lead, never crowded out by
    # routine lines
    function drill(k,   e, l, ne, nl, a9, i9, s9) {
        e = lastlines("E" SUBSEP k); l = lastlines("L" SUBSEP k)
        if (e == "" || l == "") return e l
        ne = split(e, a9, _US); s9 = e; nl = split(l, a9, _US)
        for (i9 = 1; i9 <= nl && ne < 10; i9++) { s9 = s9 _US a9[i9]; ne++ }
        return s9
    }
    # a SERVER-LOG name -> the configured roster key. EXACT first — what nearly
    # every line actually is — then, purely defensively (the server truncates
    # long site names), the roster entry it prefixes or is prefixed by, and ONLY
    # when exactly one matches: an ambiguous truncation must attribute to
    # nothing rather than to whichever entry comes first. Memoized. _files.tsv
    # never goes through this: its col 12 joins EXACTLY. (UC4 is account-keyed
    # and does not use it.)
    function key(u,   i, hit, c) {
        if (u in res) return u
        if (u in memo) return memo[u]
        hit = ""; c = 0
        for (i = 1; i <= nr; i++) if (index(u, R[i]) == 1 || index(R[i], u) == 1) { hit = R[i]; c++ }
        return memo[u] = (c == 1) ? hit : ""
    }
    FILENAME == rfv { if ($1 != "" && $2 != "") rfd[toupper($1)] = ($3 != "") ? $3 : $2; next }   # red-flip sidecar: name -> RED SINCE (col 3; col 2 = the newest evidence)
    FILENAME == sb {                                         # the configured roster (UCn-named or derived)
        if ($1 == "" || (substr($1, 1, 3) != UC && !(toupper($1) in ucd))) next
        u = toupper($1); res[u] = $3; nm[u] = $1; R[++nr] = u
        next
    }
    FILENAME == tf {                                         # transfer Files, joined EXACTLY (as result.sh)
        if ($12 == "") next
        k = toupper($12); if (!(k in res)) next
        files[k]++
        if ($2 == "Failed" || $2 == "Expired") err[k]++; else ok[k]++
        if ($6 > lsk[k]) { lsk[k] = $6; lfd[k] = $4 }        # col 6 sortkey, col 4 date
        # per-HOUR state for the sidecar: the outcome of the LATEST File in this
        # hour (by sortkey — the cache is CoreId-sorted, not chronological) and
        # whether any OK landed in it. "F" Failed (red), "X" Expired (ORANGE —
        # the result colour of an Expired-last flow, not red), "" OK
        if ($5 ~ /^[0-9][0-9]:/) {
            hs = $7 * 24 + int(substr($5, 1, 2)); span(hs); hk = k SUBSEP hs
            if (!(hk in tsk) || $6 > tsk[hk]) { tsk[hk] = $6; tbad[hk] = ($2 == "Failed") ? "F" : ($2 == "Expired") ? "X" : "" }
            if ($2 != "Failed" && $2 != "Expired") thok[hk] = 1
        }
        next
    }
    # the server line date (yyyy-mm-dd, "" when not a date) and the hours it
    # widens for the per-HOUR sidecar walk
    function ucs_day(   d) { d = substr($1, 1, 10); return (d ~ /^[0-9][0-9][0-9][0-9]-/) ? d : "" }
    function ucs_span(d) {
        if (d != "" && $2 ~ /^[0-9][0-9]:/)
            span(jdn(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0) * 24 + int(substr($2,1,2)))
    }
    # statuses, worst first — the row sort is on this number
    #   0 error             red,  no OK File ever
    #   1 ok -> error       red,  OK Files before it went red
    #   2 ok                green
    #   3 not seen          orange (or unfilled) — never in the transfer log
    function ucs_stc(k,   r) {
        r = res[k]
        if (r == "green") return 2
        if (r == "red")   return (ok[k]+0 > 0) ? 1 : 0
        return 3
    }
    # ---- the per-HOUR sidecar (the Overview UCn status card) -------------
    # The hours walked forward carrying each subscription\047s state, counting the
    # four statuses at each. The rules mirror the snapshot with the result
    # COLOUR re-derived from the evidence so far (result.sh\047s subscription
    # rule: green/red by the LAST transfer outcome — INCLUDING the red flip read
    # from _redflip — orange = nothing yet, and an Expired last File is ORANGE,
    # reading "not seen"), so the LAST hour reproduces the n[] figures of the
    # snapshot — that equality is the regression test. The red flip applies from
    # the hour it went red (the sidecar SINCE column), clamped into the walked
    # span; hash order here only FILLS a map. The FOUR-column shape is ONE
    # Overview chart kind for all three UC1/UC3/UC4 cards.
    function ucs_walk(   k9, fh, h, i, k, hk, col, sc) {
        if (hmin == "" || SL == "") return
        for (k9 in rfd) if (k9 in res) {
            fh = ""
            if (rfd[k9] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:/)
                fh = jdn(substr(rfd[k9],1,4)+0, substr(rfd[k9],6,2)+0, substr(rfd[k9],9,2)+0) * 24 + substr(rfd[k9],12,2) + 0
            if (fh == "") fh = hmax
            if (fh > hmax) fh = hmax
            if (fh < hmin) fh = hmin
            RFH[k9] = fh
        }
        for (h = hmin; h <= hmax; h++) {
            delete cnt
            for (i = 1; i <= nr; i++) {
                k = R[i]; hk = k SUBSEP h
                if (hk in tsk) { HF[k] = 1; LST[k] = tbad[hk] }
                if (hk in thok) EOK[k] = 1
                col = !HF[k] ? "o" : (LST[k] == "") ? "g" : (LST[k] == "X") ? "o" : "r"
                if ((k in RFH) && h >= RFH[k]) col = "r"
                sc = (col == "g") ? 2 : (col == "o") ? 3 : (EOK[k] ? 1 : 0)
                cnt[sc]++
            }
            printf "%s\t%d\t%d\t%d\t%d\t%d\n", fromjdn(int(h/24)), h%24, \
                cnt[2]+0, cnt[1]+0, cnt[0]+0, cnt[3]+0 > SL
        }
        close(SL)
    }
'

# The A lines -> ROW lines. Rows ordered by status (stc 0..3), within a status
# by Error desc, Files desc, then name — the noisiest subscription of a status
# first. The A lines reach sort(1) UNCHANGED: its last-resort compare is the
# WHOLE line, which is what breaks the remaining ties, so nothing may be added
# to or moved within them before the sort. ONE awk then turns each sorted A
# line into its ROW — the status label (ok -> error RED like its row and its
# STAT box, 2026-09-29), an em-dash for an absent date, the loglines attribute.
# A line: A stc sub-cell files ok err last-file <NC counts> last-log loglines
ucs_rows() {   # $1 = NC; stdin = the agg stream
    { grep $'^A\t' || true; } | LC_ALL=C sort -t$'\t' -k2,2n -k6,6nr -k4,4nr -k3,3 | awk -F'\t' -v NC="$1" '
    function z(v) { return (v + 0 == 0) ? "" : v }   # a count cell shows blank, never 0
    $3 == "" { next }          # no subscription (and the blank line an empty stream feeds in)
    {
        st = ($2 == 0) ? "@{class=failed}error" : \
             ($2 == 1) ? "@{class=failed}ok -> error" : \
             ($2 == 2) ? "@{class=processed}ok" : "not seen"
        line = "ROW\t" st "\t" $3 "\t" z($4) "\t" z($5) "\t" z($6) "\t" ($7 == "-" ? "—" : $7)
        for (i = 8; i < 8 + NC; i++) line = line "\t" z($i)
        j = 8 + NC
        print line "\t" ($j == "-" ? "—" : $j) "\t@data:loglines=" $(j + 1)
    }'
}

ucs_none() {   # $1 = UCn — no roster: no page, no sidecar
    echo "No $1 subscriptions configured." >&2
    rm -f "$OUT" "$SLOTS_OUT"   # no data for this ENV — page not published
}

nz0() { [ "${1:-0}" = 0 ] || printf '%s' "$1"; }   # a count cell shows blank, never 0

ucs_stats() {   # $1 = UCn; reads n_all n_ok n_err n_okerr n_notseen
    printf 'STAT\twhite\t%s\t%s subscriptions\n' "$n_all" "$1"
    printf 'STAT\tgreen\t%s\tok\n' "$n_ok"
    printf 'STAT\tred\t%s\terror\n' "$n_err"
    printf 'STAT\tred\t%s\tok -> error\n' "$n_okerr"   # red like its rows (the result colour), 2026-09-29
    printf 'STAT\torange\t%s\tnot seen\n' "$n_notseen"
}
