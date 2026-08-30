# merge_rpt.sh — sourced by the MERGED report scripts (2026-07 catalog cleanup).
#
# merge_rpt OUT TITLE DESC INTRO KEYWORDS COMP.rpt...
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
# publish then writes an empty-report placeholder).
# _merge_pad NAME -> how many TABLE blocks that component contributes. A
# MISSING component (production skips several server reports) is padded with
# this many empty stub tables, so the merged rpt's TABLE count ALWAYS equals
# the report_tabs tab count — a short rpt would otherwise drop tab pages and
# leave the nav row linking 404s. KEEP IN SYNC with the component reports.
_merge_pad() {
    case $(basename "$1" .rpt) in
        hourly|legs-count|protocol-journey|errors-day|cluster-health|stuck-events|scheduler-overruns) echo 2 ;;
        resubmissions|error-timing|auth-activity|ssh-key-auth|file-cleanup|trend|dwell-time) echo 3 ;;   # resubmissions 2->3 (2026-08: + server-log outcomes)
        attempts|logon) echo 4 ;;         # logon 2->4 (2026-08: + the door-knocker tables)
        volume-src) echo 3 ;;
        size-dist) echo 2 ;;
        inbound-connections|connection-diagnostics|pesit) echo 5 ;;   # connection-diagnostics 3->5, pesit 4->5 (2026-08)
        ssh-crypto) echo 10 ;;            # 8->10 (2026-08: + negotiation failures + PeSIT TLS)
        *) echo 1 ;;
    esac
}
merge_rpt() {
    local out=$1 title=$2 desc=$3 intro=$4 kw=$5; shift 5
    local have=0 c i n
    for c in "$@"; do [ -f "$c" ] && have=1; done
    if [ "$have" = 0 ]; then rm -f "$out"; echo "merge_rpt: no components for $out — skipped." >&2; return 0; fi
    {
        printf 'TITLE\t%s\n' "$title"
        printf 'DESC\t%s\n' "$desc"
        [ -n "$kw" ] && printf 'KEYWORDS\t%s\n' "$kw"
        printf 'INTRO\t%s\n' "$intro"
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
                    printf 'TABLE\t\nNOTE\tThis view has no data in this environment.\n'
                    i=$((i + 1))
                done
            fi
        done
        printf 'FOOT\tGenerated on %s from %s component report(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$#"
    } > "$out.tmp" && mv "$out.tmp" "$out"
    echo "Data written to $out ($(command grep -c '^TABLE' "$out") table(s), $# component slot(s))." >&2
}
