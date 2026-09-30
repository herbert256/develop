# merge_rpt.sh — sourced by the MERGED report scripts (2026-07 catalog cleanup).
#
# merge_rpt OUT TITLE COMP.rpt...
#   (the INTRO and KEYWORDS arguments went 2026-09-29, the DESC argument
#   2026-09-30 — nothing read a DESC any more: a report page renders no
#   INTRO — its help page explains it — and the Report finder, the one
#   KEYWORDS reader, is gone)
#
# Builds one merged .rpt from component .rpt files: the header directives come
# from the arguments, each component contributes its TABLE blocks unchanged and
# keeps feeding whatever else reads its own .rpt (the components stay on disk
# as UNPUBLISHED intermediates, like showseen-*). Component TITLE/DESC/INTRO/
# KEYWORDS/NAV/META/SUMMARY/FOOT are dropped; directives a component emits
# BEFORE its first TABLE (STAT/ALERT/…) are moved into its first table block,
# so they stay with their tables instead of leaking into the shared page header
# (segment_rpt renders pre-first-TABLE directives on every tab page).
# A missing component is skipped; zero present components removes OUT (the
# publish then writes an empty-report placeholder). A component whose tables
# carry the tab=KEY modifier of the component before it (uc3-polling behind
# uc3-status) adds its tables to THAT tab page — see segment_rpt.
# _merge_pad NAME -> how many TABLE blocks that component contributes. A
# MISSING component (production skips several server reports) is padded with
# this many empty stub tables, so the merged rpt's TABLE count ALWAYS equals
# the report_tabs tab count — a short rpt would otherwise drop tab pages and
# leave the nav row linking 404s. KEEP IN SYNC with the component reports.
_merge_pad() {
    case $(basename "$1" .rpt) in
        hourly) echo 2 ;;   # (legs-count and protocol-journey went 2026-09-30 with the Flow patterns group)   # (error-reasons stays 1: its 2026-09-28 second table, Reasons over time, rides its tab — tab=reasons)
        resubmissions) echo 3 ;;   # resubmissions 2->3 (2026-08: + server-log outcomes); dwell-time.sh writes duration-dwell.rpt itself (merge-duration-dwell.sh went 2026-09-30)
        size-profile) echo 2 ;;   # a Sizes component (the Trends components trend / duration-trend went with their page, 2026-09-29)
        # errors-day 2->1 and error-timing 3->1 (2026-09-28: the per-day table = the Top view; hour + weekday folded into the heatmap)
        attempts) echo 4 ;;               # (logon, 2->4 in 2026-08, is merged no more: logon.rpt is pageless since 2026-09-30)
        size-dist) echo 2 ;;
        # (ssh-crypto: merged no more since 2026-09-30 — its tables are
        # APPENDED to Security Parameters, append_rpt_tables -f)
        uc3-polling|uc2-visits|pickups|no-remote-dir|no-remote-files) echo 0 ;;   # ride the UC2 / UC3 tabs (2026-09-29)            # RIDES the UC3 tab (its tables carry tab=uc3, 2026-09-05): a missing one contributes NO tab page
        *) echo 1 ;;
    esac
}
merge_rpt() {
    local out=$1 title=$2; shift 2
    local have=0 c i n
    for c in "$@"; do [ -f "$c" ] && have=1; done
    if [ "$have" = 0 ]; then rm -f "$out"; echo "merge_rpt: no components for $out — skipped." >&2; return 0; fi
    {
        printf 'TITLE\t%s\n' "$title"
        for c in "$@"; do
            if [ -f "$c" ]; then
                awk -F'\t' '
                    FNR == 1 { intable = 0; nbuf = 0 }
                    $1 == "TITLE" || $1 == "DESC" || $1 == "INTRO" || $1 == "KEYWORDS" || \
                    $1 == "NAV" || $1 == "META" || $1 == "SUMMARY" || $1 == "FOOT" { next }
                    $1 == "TABLE" {
                        print
                        if (!intable) { for (i = 1; i <= nbuf; i++) print BUF[i]; nbuf = 0 }
                        intable = 1; next
                    }
                    !intable { BUF[++nbuf] = $0; next }
                    { print }
                ' "$c"
            else
                n=$(_merge_pad "$c"); i=0
                while [ "$i" -lt "$n" ]; do
                    printf 'TABLE\t\n'
                    i=$((i + 1))
                done
            fi
        done
        # The sentinel (2026-09-05): segment_rpt footers a NOTE that directly
        # precedes SUMMARY/FOOT — report-level, repeated on EVERY tab page —
        # which put the LAST component's per-table note on all the other
        # tabs (the UC4 note on the UC1/2/3 pages). Any other directive after
        # that note pins it to its own block; the renderer ignores META.
        printf 'META\tmerged\t%s\n' "$#"
        printf 'FOOT\n'
    } > "$out.tmp" && mv "$out.tmp" "$out"
    echo "Data written to $out ($(command grep -c '^TABLE' "$out") table(s), $# component slot(s))." >&2
}

# append_rpt_tables TARGET COMP.rpt... (2026-09-29) — move the TABLE blocks of
# component reports onto the page of TARGET: every line from a component's
# first TABLE up to its SUMMARY / FOOT / META (its header directives dropped)
# is inserted before TARGET's first SUMMARY or FOOT line, so the tables render
# below TARGET's own on the same page. A missing component is skipped; a
# missing TARGET leaves nothing to do. The components stay on disk as
# unpublished intermediates, like merge_rpt's. With -f first (2026-09-30) the
# tables go before TARGET's FOOT instead — AFTER its SUMMARY, which renders
# where it stands and so stays under TARGET's own table (the Security
# Parameters summary line above the appended SSH tables).
append_rpt_tables() {
    local atfoot=0
    [ "${1:-}" = -f ] && { atfoot=1; shift; }
    local target=$1; shift
    [ -f "$target" ] || return 0
    local have=() c
    for c in "$@"; do [ -f "$c" ] && have+=("$c"); done
    [ "${#have[@]}" -gt 0 ] || return 0
    local blk; blk=$(mktemp "${TMPDIR:-/tmp}/apprpt.XXXXXX")
    awk -F'\t' '
        FNR == 1 { intable = 0 }
        $1 == "TABLE" { intable = 1 }
        !intable { next }
        $1 == "SUMMARY" || $1 == "FOOT" || $1 == "META" || $1 == "TITLE" || $1 == "DESC" || $1 == "KEYWORDS" || $1 == "NAV" { next }
        { print }
    ' "${have[@]}" > "$blk"
    awk -v BLK="$blk" -v ATFOOT="$atfoot" '
        # (the default keeps its 2026-09-29 match — /^FOOT\t/ never meets the
        # bare "FOOT" line, so a TARGET without SUMMARY gets the block at END;
        # -f matches the bare FOOT itself)
        !done && ((!ATFOOT && (/^SUMMARY\t/ || /^FOOT\t/)) || (ATFOOT && /^FOOT(\t|$)/)) { while ((getline l < BLK) > 0) print l; done = 1 }
        { print }
        END { if (!done) while ((getline l < BLK) > 0) print l }
    ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
    rm -f "$blk"
}
