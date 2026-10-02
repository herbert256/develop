#!/usr/bin/env bash
#
# bin/transfer/dropped-records.sh — the transfer records bin/transfer/parse.sh
# SETS ASIDE before any File is formed (data/transfer/_skipped.csv, the raw
# input lines), as report rows. Sourced by their two pages (2026-10-02, user
# request: "Rows that are not because of skip.txt must go to
# /transfer/unknown-transfers.html or to /transfer/pirates-details.html" — the
# Skipped page listed them until then, though no skip.txt rule is involved):
#   bin/transfer/reports/unknown-transfers.sh  dropped_rows nosub  — the
#       CoreIds with neither subscription nor account on any leg, or with an
#       http leg (web-UI hand traffic)
#   bin/transfer/reports/pirates.sh            dropped_rows probe  — the EMPTY
#       OUTBOUND SSH PROBES (one lone Outbound ssh record of size 0 whose
#       Application field reads "none" or is empty — no file at all, 2026-09-08)
# They are NOT Files: no page counts them, no colour rests on them, and they
# have no File page (the tables carry no File-page link).
#
#   dropped_rows nosub|probe  -> ROW lines, newest first:
#       nosub  Date & time · Reason · Status · Account · Login · Direction ·
#              Protocol · File · Size · CoreId
#       probe  the same without Reason (always "empty ssh probe")
#   Reason precedence: http, then the empty ssh probe, else no subscription.

DROPPED_CSV="$DATA/transfer/_skipped.csv"
dropped_rows() {   # $1 = nosub | probe
    [ -s "$DROPPED_CSV" ] || return 0
    awk -v want="$1" "$AWKLIB"'
        # (lit() — a raw name kept literal — comes from bin/fmt.awk via $AWKLIB)
        function f(line, want,    n, i, c, q, cur) {
            n = 0; cur = ""; q = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (q) { if (c == "\"") { if (substr(line, i+1, 1) == "\"") { cur = cur "\""; i++ } else q = 0 } else cur = cur c }
                else { if (c == "\"") q = 1
                       else if (c == ",") { n++; if (n == want) return cur; cur = "" }
                       else cur = cur c }
            }
            n++; return (n == want) ? cur : ""
        }
        # pass 1: which CoreIds have an http leg, and how many raw lines each
        # CoreId has; pass 2: one sortable row per raw line of the wanted kind
        FNR == NR { if (f($0, 20) == "http") ht[f($0, 34)] = 1; nl[f($0, 34)]++; next }
        {
            ts = f($0, 23); cid = f($0, 34)
            split(ts, dt, " "); split(dt[1], m, "/")
            iso = (m[3] != "" ? sprintf("%04d-%02d-%02d", m[3], m[1], m[2]) : dt[1])
            app = tolower(f($0, 6))
            probe = (nl[cid] == 1 && f($0, 8) == "Outbound" && f($0, 20) == "ssh" && (f($0, 19) + 0) == 0 && (app == "none" || app == ""))
            reason = (cid in ht) ? "http" : (probe ? "empty ssh probe" : "no subscription")
            if ((want == "probe") != (reason == "empty ssh probe")) next
            printf "%s %s\tROW\t%s %s%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                iso, dt[2], iso, dt[2], (want == "probe" ? "" : "\t" reason), f($0, 1), f($0, 2), f($0, 3), \
                f($0, 8), f($0, 20), lit(f($0, 15)), f($0, 19), cid
        }
    ' "$DROPPED_CSV" "$DROPPED_CSV" | LC_ALL=C sort -r | cut -f2-
}
