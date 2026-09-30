#!/usr/bin/env bash
#
# waiting-expired.sh — "Waiting & Expired" (2026-09-30, user request: ONE
# report replacing transfer/waiting.html and transfer/expired.html). The UC2
# staged Files: a File whose last leg is the (Processed) staging leg reads
# WAITING in _files.tsv — arrived and staged, the partner has not collected it
# yet; once the nightly File Maintenance retention sweep (~11 days) deletes the
# staged copy before any pickup, bin/expire-files.sh flips it to EXPIRED
# (col 22 = the deletion timestamp). Two side-by-side tables:
#   Summary        per START day (the File's start, col 4 — the site's date
#                  axis, so From/To narrows it and its totals equal the
#                  outcome counts): Date · Waiting · Expired; every dated
#                  Waiting / Expired File, the "Unknown" subscription's too;
#                  the counts drill to the day's 10 newest such Files.
#   Subscriptions  Subscription · Waiting · Expired · Collected · Oldest
#                  Waiting · Last Expired — the state at the data's end
#                  (nofilter), one row per subscription with a Waiting or
#                  Expired File ("Unknown" and siteless Files get no row);
#                  Collected = its delivered Files with a pickup wait (col 21
#                  set, Processed — the rule both old pages used); Oldest
#                  Waiting = the STAGING time of its oldest still-waiting File;
#                  Last Expired = its newest deletion (col 22). Rows tint by the
#                  subscription's result colour; the Waiting / Expired counts
#                  open the subscription File lists below.
#
# THE SUBSCRIPTION FILE LISTS (kept from waiting.sh / expired.sh, 2026-09-21):
#   data/transfer/reports/waiting/<slug>.rpt  -> transfer/waiting/<slug>.html
#     the subscription's Files still staged (Start · Waiting for · File name ·
#     CoreId, longest waiting first; Waiting for runs to the data's last record)
#   data/transfer/reports/expired/<slug>.rpt  -> transfer/expired/<slug>.html
#     its Expired Files (Start · Expired · File name · CoreId, last expired first)
#   rendered by bin/transfer/publish.sh. (The dropped tables of the two old
#   pages — pickup waits, the backlog curve, the retention curve, the sweep
#   nights, the staging weekday … — went with them, 2026-09-30.)
#
# Reads data/transfer/cache/_files.tsv (1 coreid, 2 outcome, 3 account,
# 4 date, 5 time, 6 sortkey, 8 size, 11 file, 12 subscription, 21 wait_ms,
# 22 expired-at) + the base subscription colours.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/waiting-expired.rpt"
WSUB="$REPORTS_DIR/waiting"
XSUB="$REPORTS_DIR/expired"
SUBRES="$CONFIG_BASE/_subscriptions.tsv"; [ -f "$SUBRES" ] || SUBRES=/dev/null
# hdur() — a wait in seconds as d h / h m / min / s (the Waiting for cells)
WT_HDUR_AWK='function hdur(s){ s=int(s); if (s<0) s=0
    if (s>=86400) return int(s/86400) "d " int(s%86400/3600) "h"
    if (s>=3600)  return int(s/3600) "h " int(s%3600/60) "m"
    if (s>=60)    return int(s/60) " min"
    return s " s" }'

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/axwe.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# ONE pass over _files.tsv. Emits (pipe-separated; file names go LAST):
#   D|date|nwait|nexp|waitdrill|expdrill          per start day (every File)
#   S|site|nwait|nexp|ncoll|oldest_age|lastexp_age  per subscription (W or X > 0);
#                                                 the ages in seconds, -1 = none
#   F|stagesec|staged_dt|site|acct|bytes|size|wait_for|wait_sec|coreid|file
#                                                 each Waiting File (its list page)
#   X|site|staged|expired|coreid|file             each Expired File (its list page)
#   TOT|lastdt
awk -F'\t' "$COREIDS_AWK$AWKLIB$WT_HDUR_AWK"'
    function tsec(d,t){ split(d,p,"-"); return jdn(p[1]+0,p[2]+0,p[3]+0)*86400 + substr(t,1,2)*3600 + substr(t,4,2)*60 + substr(t,7,2) }
    $2 == "Waiting" || $2 == "Expired" {
        if ($4 != "") {   # the Summary: every dated Waiting / Expired File
            d = $4
            if (!(d in DW) && !(d in DX)) DL[++nd] = d
            if ($2 == "Waiting") { DW[d]++; addtop("W" SUBSEP d, $6, $4 " " $5, $1) }
            else                 { DX[d]++; addtop("X" SUBSEP d, $6, $4 " " $5, $1) }
        }
    }
    $12 == "" || $12 == "Unknown" || $4 == "" { next }   # no subscription (2026-09-29): no row, no list page
    {
        s = $12
        if ($6 > g_lastsk) { g_lastsk = $6; g_lastsec = tsec($4, $5); g_lastdt = $4 " " substr($5, 1, 8) }
        if ($2 == "Waiting") {
            if (!(s in SW) && !(s in SX)) SL[++ns] = s
            SW[s]++
            if (!(s in OSK) || $6 < OSK[s]) { OSK[s] = $6; OSEC[s] = tsec($4, $5) }
            FL[++nf] = tsec($4, $5) "|" $4 " " substr($5, 1, 8) "|" s "|" $3 "|" ($8 + 0) "|" hbytes1($8 + 0) "|" $1 "|" $11
        } else if ($2 == "Expired") {
            if (!(s in SW) && !(s in SX)) SL[++ns] = s
            SX[s]++
            if (substr($22, 1, 19) > LX[s]) LX[s] = substr($22, 1, 19)
            printf "X|%s|%s %s|%s|%s|%s\n", s, $4, substr($5, 1, 8), substr($22, 1, 19), $1, $11
        } else if ($21 != "" && $2 == "Processed") {   # COLLECTED: a delivered File with a pickup wait
            SC[s]++
        }
    }
    END {
        for (i = 1; i <= nd; i++) { d = DL[i]
            printf "D|%s|%d|%d|%s|%s\n", d, DW[d] + 0, DX[d] + 0, buildlist(top["W" SUBSEP d]), buildlist(top["X" SUBSEP d]) }
        for (i = 1; i <= ns; i++) { s = SL[i]
            # the two ages to the last record of the data (-1 = none): the wait
            # of the oldest still-waiting File (the longest Waiting for of its list
            # page) and the time since the newest deletion
            oa = (s in OSEC) ? g_lastsec - OSEC[s] : -1; if (s in OSEC && oa < 0) oa = 0
            xa = (LX[s] != "") ? g_lastsec - tsec(substr(LX[s], 1, 10), substr(LX[s], 12, 8)) : -1; if (LX[s] != "" && xa < 0) xa = 0
            printf "S|%s|%d|%d|%d|%d|%d\n", s, SW[s] + 0, SX[s] + 0, SC[s] + 0, oa, xa }
        for (i = 1; i <= nf; i++) {
            m = split(FL[i], a, "|")
            fn = a[8]; for (j = 9; j <= m; j++) fn = fn "|" a[j]   # a file name may hold "|"
            ws = int(g_lastsec - a[1]); if (ws < 0) ws = 0
            printf "F|%s|%s|%s|%s|%s|%s|%s|%d|%s|%s\n", a[1], a[2], a[3], a[4], a[5], a[6], hdur(ws), ws, a[7], fn
        }
        printf "TOT|%s\n", g_lastdt
    }
' "$FILES" > "$TMPD/agg"

last_dt=$(awk -F'|' '$1 == "TOT" { print $2 }' "$TMPD/agg")

# ---- the slugs (the site-wide slugify over the C-SORTED names, so a separator
# twin's numeric bump is stable) — one map per list family ---------------------
mkslugs() { LC_ALL=C sort -u | awk "$AWKLIB"'
    { base = slugof($0); if (base == "") base = "subscription"
      slug = base; n = 1
      while (slug in used) { n++; slug = base "-" n }
      used[slug] = 1
      printf "%s\t%s\n", $0, slug }'; }
awk -F'|' '$1 == "S" && $3 + 0 > 0 { print $2 }' "$TMPD/agg" | mkslugs > "$TMPD/wslugs"
awk -F'|' '$1 == "S" && $4 + 0 > 0 { print $2 }' "$TMPD/agg" | mkslugs > "$TMPD/xslugs"

# ---- the Waiting File lists: longest waiting first (the page's declared sort
# on the Waiting for sortval), ties by CoreId; every row ORANGE (a Waiting
# File's colour). Staged in waiting.new/ and swapped in before the main .rpt.
rm -rf "$WSUB.new"; mkdir -p "$WSUB.new"
cp "$TMPD/wslugs" "$WSUB.new/_slugmap.tsv"
awk -F'|' '$1 == "F"' "$TMPD/agg" | LC_ALL=C sort -t'|' -k4,4 -k2,2n -k10,10 | awk -F'|' \
    -v slugs="$TMPD/wslugs" -v dir="$WSUB.new" -v lastdt="$last_dt" "$AWKLIB"'
    BEGIN { while ((getline l < slugs) > 0) { split(l, a, "\t"); SL[a[1]] = a[2] } close(slugs) }
    function clean(s) { gsub(/[\t\r]/, " ", s); return s }
    function finish() { if (out == "") return; printf "FOOT\n" > out; close(out) }
    ($4 "") != cur {
        finish(); cur = $4; out = ""
        if (!($4 in SL)) next
        out = dir "/" SL[$4] ".rpt"
        printf "TITLE\tWaiting Files: %s\n", $4 > out
        printf "INTRO\tThe staged File(s) of subscription [[subscriptions/%s]] the partner has not collected yet — still collectable until the nightly File Maintenance retention sweep (~11 days) deletes them. **Waiting for** counts from the staging moment to the last record of the data (%s). Longest waiting first.\n", $4, lastdt > out
        printf "TABLE\tWaiting Files\twide\tnofilter\tsort=1:-1\tpager=25\trestint\n" > out
        printf "HEAD\tStart\tWaiting for\tFile name\tCoreId\n" > out
        printf "KIND\ttext\ttext\tmono\tmono\n" > out
    }
    out != "" {
        fn = $11; for (j = 12; j <= NF; j++) fn = fn "|" $j
        printf "ROW\t%s\t@{sortval=%d}%s\t%s\t%s\t@data:res=orange\n", $3, $9, $8, lit(clean(fn)), $10 > out
    }
    END { finish() }'
rm -rf "$WSUB"; mv "$WSUB.new" "$WSUB"

# ---- the Expired File lists: last expired first (the page's declared sort on
# the Expired column), ties by Start descending then CoreId; every row RED.
rm -rf "$XSUB.new"; mkdir -p "$XSUB.new"
awk -F'|' -v OFS='\t' '$1 == "X" { fn = $6; for (j = 7; j <= NF; j++) fn = fn "|" $j; print $2, $3, $4, fn, $5 }' "$TMPD/agg" \
    | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k3,3r -k2,2r -k5,5 | awk -F'\t' \
    -v slugs="$TMPD/xslugs" -v dir="$XSUB.new" "$AWKLIB"'
    BEGIN { while ((getline l < slugs) > 0) { split(l, a, "\t"); SL[a[1]] = a[2] } close(slugs) }
    function finish() { if (out == "") return; printf "FOOT\n" > out; close(out) }
    ($1 "") != cur {
        finish(); cur = $1; out = ""
        if (!($1 in SL)) next
        out = dir "/" SL[$1] ".rpt"
        printf "TITLE\tExpired Files: %s\n", $1 > out
        printf "INTRO\tThe staged File(s) of subscription [[subscriptions/%s]] that the nightly File Maintenance retention sweep deleted before the partner collected them — never delivered. Last expired first.\n", $1 > out
        printf "TABLE\tExpired Files\twide\tnofilter\tsort=1:-1\tpager=25\trestint\n" > out
        printf "HEAD\tStart\tExpired\tFile name\tCoreId\n" > out
        printf "KIND\ttext\ttext\tmono\tmono\n" > out
    }
    out != "" { printf "ROW\t%s\t%s\t%s\t%s\t@data:res=red\n", $2, $3, lit($4), $5 > out }
    END { finish() }'
rm -rf "$XSUB"; mv "$XSUB.new" "$XSUB"

# ---- the report ---------------------------------------------------------------
{
    printf 'TITLE\tWaiting & Expired\n'   # = its Reports menu label
    printf 'DESC\tUC2 Files staged for pickup: per day how many are still waiting and how many the retention sweep deleted before any pickup, and per subscription its waiting, expired and collected Files.\n'

    # Summary — per START day, newest first; the counts drill to the day's Files
    # (an Expired 0 goes out as "0": the renderer z-blanks it, so a day without an
    # Expired File shows no red — an EMPTY errc cell would keep the pink, 2026-09-30)
    printf 'TABLE\tSummary\tkeephead\tsxs\tdrillcols=wait:1:Waiting_Files,exp:2:Expired_Files\n'
    printf 'HEAD\tDate\tWaiting\tExpired\n'
    printf 'KIND\ttext\tnumwarn\tnumerr\n'
    awk -F'|' '$1 == "D"' "$TMPD/agg" | LC_ALL=C sort -t'|' -k2,2r | awk -F'|' '
        { tw += $3; tx += $4; n++
          printf "ROW\t@{href=../day/%s.html}%s\t%s\t%s\t@data:coreids-wait=%s\t@data:coreids-exp=%s\n", \
              $2, $2, ($3 > 0 ? $3 : ""), $4 + 0, ($3 > 0 ? $5 : ""), ($4 > 0 ? $6 : "") }
        END { if (n == 0) printf "ROW\t@{colspan=3}No Waiting or Expired Files in this data window.\n"
              printf "TOTAL\tTotal (%d day(s))\t@{class=num warn}%s\t@{class=num errc}%s\n", n, (tw > 0 ? tw : ""), tx + 0 }'

    # Subscriptions — the state at the data's end; Waiting first, then Expired
    # (2026-09-30, user request: Oldest Waiting / Last Expired as one-unit ages
    # "5d" / "16h" / "14m" with the seconds as sortval, the Expired counts red
    # — numfailed keeps its tint on a tinted row — and the default sort Oldest
    # Waiting descending, baked the same way)
    printf 'TABLE\tSubscriptions\tnofilter\trestint\tsxs\tsort=4:-1\n'
    printf 'HEAD\tSubscription\tWaiting\tExpired\tCollected\tOldest Waiting\tLast Expired\n'
    printf 'KIND\tsite\tnumwarn\tnumfailed\tnumok\ttext\ttext\n'
    awk -F'|' '$1 == "S"' "$TMPD/agg" | LC_ALL=C sort -t'|' -k6,6nr -k4,4nr -k2,2 | awk -F'|' \
        -v ws="$TMPD/wslugs" -v xs="$TMPD/xslugs" -v subres="$SUBRES" "$AWKLIB"'
        BEGIN { while ((getline l < ws) > 0) { split(l, a, "\t"); WSL[a[1]] = a[2] } close(ws)
                while ((getline l < xs) > 0) { split(l, a, "\t"); XSL[a[1]] = a[2] } close(xs)
                while ((getline l < subres) > 0) { n9 = split(l, a, "\t"); if (n9 >= 3 && a[1] != "") RES[toupper(a[1])] = a[3] } close(subres) }
        {
            s = $2; w = $3 + 0; x = $4 + 0; c = $5 + 0
            wc = (w > 0 ? ((s in WSL) ? "@{href=waiting/" WSL[s] ".html}" : "") w : "")
            xc = (x > 0 ? ((s in XSL) ? "@{href=expired/" XSL[s] ".html}" : "") x : "")
            r = RES[toupper(s)]; tint = (r == "green" || r == "orange" || r == "red") ? "\t@data:res=" r : ""
            oc = ($6 >= 0) ? "@{sortval=" $6 "}" hage1($6) : ""; ec = ($7 >= 0) ? "@{sortval=" $7 "}" hage1($7) : ""
            printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s%s\n", s, wc, xc, (c > 0 ? c : ""), oc, ec, tint
            n++; tw += w; tx += x; tc += c
        }
        END { if (n == 0) printf "ROW\t@{colspan=6}No subscription has a Waiting or Expired File in this data window.\n"
              printf "TOTAL\tTotal (%d subscription(s))\t@{class=num warn}%s\t@{class=num failed}%s\t@{class=num okc}%s\t\t\n", n, (tw > 0 ? tw : ""), (tx > 0 ? tx : ""), (tc > 0 ? tc : "") }'
    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT (+ $(ls "$WSUB" | grep -c '\.rpt$' || true) waiting / $(ls "$XSUB" | grep -c '\.rpt$' || true) expired list page(s))." >&2
